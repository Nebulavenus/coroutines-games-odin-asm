package coroutine

import "base:intrinsics"
import "core:fmt"
import "core:time"

// ============================================================================
// Scheduler Lifecycle
// ============================================================================

scheduler_init :: proc(
    sched: ^Scheduler,
    stack_size: uint = DEFAULT_STACK_SIZE,
    stacks_per_slab: int = STACKS_PER_SLAB,
    alloc_mode: Stack_Allocation_Mode = DEFAULT_ALLOC_MODE,
    allocator := context.allocator,
) {
    if sched.ready_queue != nil || sched.fiber_pool.all_fibers != nil {
        scheduler_destroy(sched)
    }
    sched.allocator = allocator.procedure != nil ? allocator : context.allocator
    sched.ready_queue = make([dynamic]Fiber_Handle, sched.allocator)
    for i in 0 ..< MAX_CLOCKS {
        sched.clocks[i] = Clock_Domain{
            timer_heap   = make([dynamic]^Fiber, sched.allocator),
            step_waiters = make([dynamic]^Fiber, sched.allocator),
        }
    }
    fiber_pool_init(&sched.fiber_pool, stack_size, stacks_per_slab, alloc_mode, sched.allocator)

    sched.scheduler_sp = nil
    sched.current_fiber = nil
    sched.watchdog_enabled = WATCHDOG_ENABLED
    sched.watchdog_max_slice_ms = WATCHDOG_MAX_SLICE_MS
}

scheduler_init_config :: proc(sched: ^Scheduler, config: Fiber_Pool_Config) {
    if sched.ready_queue != nil || sched.fiber_pool.all_fibers != nil {
        scheduler_destroy(sched)
    }
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    sched.allocator = allocator
    sched.ready_queue = make([dynamic]Fiber_Handle, sched.allocator)
    for i in 0 ..< MAX_CLOCKS {
        sched.clocks[i] = Clock_Domain{
            timer_heap   = make([dynamic]^Fiber, sched.allocator),
            step_waiters = make([dynamic]^Fiber, sched.allocator),
        }
    }
    fiber_pool_init_config(&sched.fiber_pool, config)

    sched.scheduler_sp = nil
    sched.current_fiber = nil
    sched.watchdog_enabled = WATCHDOG_ENABLED
    sched.watchdog_max_slice_ms = WATCHDOG_MAX_SLICE_MS
}

scheduler_destroy :: proc(sched: ^Scheduler) {
    if sched == nil do return
    // Abort and unlink all active fibers
    for fiber in sched.fiber_pool.all_fibers {
        if fiber.status != .Unused {
            if fiber.current_wait_queue != nil {
                wait_queue_remove(fiber.current_wait_queue, fiber)
                fiber.current_wait_queue = nil
            }
            if fiber.scope != nil {
                fiber_scope_detach(fiber)
            }
            if fiber.cleanup_proc != nil {
                fiber.cleanup_proc(fiber.cleanup_data != nil ? fiber.cleanup_data : fiber.user_data)
                fiber.cleanup_proc = nil
                fiber.cleanup_data = nil
            }
        }
    }

    delete(sched.ready_queue)
    sched.ready_queue = nil
    for i in 0 ..< MAX_CLOCKS {
        delete(sched.clocks[i].timer_heap)
        delete(sched.clocks[i].step_waiters)
        sched.clocks[i] = {}
    }
    fiber_pool_destroy(&sched.fiber_pool)
}

// ============================================================================
// Timer Min-Heap Implementation (O(log N) operations with cached index)
// ============================================================================

@(private="file")
heap_swap :: proc(heap: ^[dynamic]^Fiber, i, j: int) {
    tmp := heap[i]
    heap[i] = heap[j]
    heap[j] = tmp
    heap[i].heap_index = i
    heap[j].heap_index = j
}

@(private="file")
heap_sift_up :: proc(heap: ^[dynamic]^Fiber, start_idx: int) {
    child := start_idx
    for child > 0 {
        parent := (child - 1) / 2
        if heap[child].wake_time < heap[parent].wake_time {
            heap_swap(heap, child, parent)
            child = parent
        } else {
            break
        }
    }
}

@(private="file")
heap_sift_down :: proc(heap: ^[dynamic]^Fiber, start_idx: int) {
    parent := start_idx
    count := len(heap)
    for {
        smallest := parent
        left := 2 * parent + 1
        right := 2 * parent + 2

        if left < count && heap[left].wake_time < heap[smallest].wake_time {
            smallest = left
        }
        if right < count && heap[right].wake_time < heap[smallest].wake_time {
            smallest = right
        }

        if smallest != parent {
            heap_swap(heap, parent, smallest)
            parent = smallest
        } else {
            break
        }
    }
}

clock_heap_push :: proc(clock: ^Clock_Domain, fiber: ^Fiber) {
    idx := len(clock.timer_heap)
    fiber.heap_index = idx
    append(&clock.timer_heap, fiber)
    heap_sift_up(&clock.timer_heap, idx)
}

clock_heap_pop :: proc(clock: ^Clock_Domain) -> ^Fiber {
    count := len(clock.timer_heap)
    if count == 0 do return nil

    root := clock.timer_heap[0]
    root.heap_index = -1

    last := pop(&clock.timer_heap)
    if count > 1 {
        last.heap_index = 0
        clock.timer_heap[0] = last
        heap_sift_down(&clock.timer_heap, 0)
    }

    return root
}

clock_heap_remove :: proc(clock: ^Clock_Domain, index: int) {
    count := len(clock.timer_heap)
    if index < 0 || index >= count do return

    target := clock.timer_heap[index]
    target.heap_index = -1

    if index == count - 1 {
        pop(&clock.timer_heap)
        return
    }

    last := pop(&clock.timer_heap)
    last.heap_index = index
    clock.timer_heap[index] = last

    // Rebalance
    parent := (index - 1) / 2
    if index > 0 && clock.timer_heap[index].wake_time < clock.timer_heap[parent].wake_time {
        heap_sift_up(&clock.timer_heap, index)
    } else {
        heap_sift_down(&clock.timer_heap, index)
    }
}

// ============================================================================
// Tree Hierarchy Utilities
// ============================================================================

fiber_link_child :: proc(parent: ^Fiber, child: ^Fiber) {
    child.parent = parent
    child.next_sibling = nil
    child.prev_sibling = parent.last_child
    if parent.last_child != nil {
        parent.last_child.next_sibling = child
    } else {
        parent.first_child = child
    }
    parent.last_child = child
    parent.child_count += 1
}

fiber_unlink_child :: proc(parent: ^Fiber, child: ^Fiber) {
    if parent == nil || child == nil || child.parent != parent do return

    if child.prev_sibling != nil {
        child.prev_sibling.next_sibling = child.next_sibling
    } else if parent.first_child == child {
        parent.first_child = child.next_sibling
    }

    if child.next_sibling != nil {
        child.next_sibling.prev_sibling = child.prev_sibling
    } else if parent.last_child == child {
        parent.last_child = child.prev_sibling
    }

    child.parent = nil
    child.next_sibling = nil
    child.prev_sibling = nil
    parent.child_count -= 1
}

// ============================================================================
// Multi-Domain Dispatch Loop & Pluggable Drivers
// ============================================================================

clock_advance :: proc(sched: ^Scheduler, clock_id: Clock_ID, dt: f32, steps: u64 = 1) {
    if sched == nil do return
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    c := &sched.clocks[cid]

    safe_dt := dt
    if safe_dt != safe_dt || safe_dt < 0.0 {
        safe_dt = 0.0
    }

    // 1. Advance Clock Domain Timeline
    c.delta = safe_dt
    c.time += f64(safe_dt)
    c.steps += steps

    // 2. Wake Timers from Clock Domain Min-Heap
    for len(c.timer_heap) > 0 {
        root := c.timer_heap[0]
        if root.wake_time <= c.time {
            f := clock_heap_pop(c)
            if f != nil && f.status == .Sleeping_Time {
                f.status = .Ready
                append(&sched.ready_queue, f.handle)
            }
        } else {
            break
        }
    }

    // 3. Wake Step Waiters (Linear In-Place Partition)
    if steps > 0 && len(c.step_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(c.step_waiters); i += 1 {
            f := c.step_waiters[i]
            if f.wake_step <= c.steps {
                if f.status == .Sleeping_Steps {
                    f.status = .Ready
                    append(&sched.ready_queue, f.handle)
                }
            } else {
                c.step_waiters[write_idx] = f
                write_idx += 1
            }
        }
        resize(&c.step_waiters, write_idx)
    }
}

scheduler_run :: proc(sched: ^Scheduler) {
    if sched == nil do return

    // Execute Ready Queue (Zero-Shift O(N) Sequential Cursor with Generational Handle Guard)
    for i := 0; i < len(sched.ready_queue); i += 1 {
        h := sched.ready_queue[i]
        f := fiber_find_by_handle(sched, h)
        if f == nil || f.status != .Ready do continue

        f.status = .Running
        sched.current_fiber = f

        // Context switch into the fiber
        if sched.watchdog_enabled {
            t0 := time.tick_now()
            fiber_context_switch(&sched.scheduler_sp, f.saved_sp)
            elapsed := time.tick_since(t0)
            elapsed_ms := time.duration_milliseconds(elapsed)
            if elapsed_ms > sched.watchdog_max_slice_ms {
                fmt.panicf("[WATCHDOG PANIC] Runaway non-yielding fiber detected! Fiber [#%d] '%s' executed for %.2f ms without yielding! Did you write an infinite loop without wait() or yield()?", f.handle, f.debug_name, elapsed_ms)
            }
        } else {
            fiber_context_switch(&sched.scheduler_sp, f.saved_sp)
        }

        sched.current_fiber = nil

        // Post-execution check: reload status with volatile semantics to prevent compiler SSA caching across ASM switch
        status := intrinsics.volatile_load(&f.status)
        if status == .Completed || status == .Failed || status == .Aborted {
            fiber_cleanup_and_recycle(sched, f)
        }
    }
    clear(&sched.ready_queue)
}

scheduler_step :: proc(sched: ^Scheduler, dt: f32, clock_id: Clock_ID = CLOCK_SIM) {
    clock_advance(sched, clock_id, dt, 1)
    scheduler_run(sched)
}

scheduler_single_step :: proc(sched: ^Scheduler, dt: f32, clock_id: Clock_ID = CLOCK_SIM) {
    clock_advance(sched, clock_id, dt, 1)
    scheduler_run(sched)
}

// ============================================================================
// Completion & Cancellation
// ============================================================================

fiber_on_finish :: proc(fiber: ^Fiber) {
    if fiber.join_coord != nil {
        coord := fiber.join_coord
        coord.active_branches -= 1

        if coord.kind == .Race {
            if fiber.status == .Completed && !coord.completed {
                // First SUCCESS wins!
                coord.completed = true
                coord.winner = fiber
                coord.winner_index = fiber.branch_index

                // Abort sibling branches immediately
                parent := coord.parent
                if parent != nil {
                    child := parent.first_child
                    for child != nil {
                        next := child.next_sibling
                        if child != fiber && child.join_coord == coord {
                            fiber_abort_tree(fiber.sched, child)
                        }
                        child = next
                    }

                    // Wake up parent if waiting
                    if parent.status == .Suspended_Join {
                        parent.status = .Ready
                        append(&fiber.sched.ready_queue, parent.handle)
                    }
                }
            } else if coord.active_branches <= 0 && !coord.completed {
                // All branches finished without any success (or all failed/aborted)
                coord.completed = true
                coord.winner = nil
                coord.winner_index = -1
                parent := coord.parent
                if parent != nil && parent.status == .Suspended_Join {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent.handle)
                }
            }
        } else if coord.kind == .Rush {
            if fiber.status == .Completed && !coord.completed {
                // Verse rush: first SUCCESS wins; losers continue in background!
                coord.completed = true
                coord.winner = fiber
                coord.winner_index = fiber.branch_index

                // Detach remaining branches from join_coord so parent can reuse active_coord
                parent := coord.parent
                if parent != nil {
                    child := parent.first_child
                    for child != nil {
                        next := child.next_sibling
                        if child != fiber && child.join_coord == coord {
                            child.join_coord = nil
                        }
                        child = next
                    }

                    // Wake up parent if waiting
                    if parent.status == .Suspended_Join {
                        parent.status = .Ready
                        append(&fiber.sched.ready_queue, parent.handle)
                    }
                }
            } else if coord.active_branches <= 0 && !coord.completed {
                // All branches finished without any success
                coord.completed = true
                coord.winner = nil
                coord.winner_index = -1
                parent := coord.parent
                if parent != nil && parent.status == .Suspended_Join {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent.handle)
                }
            }
        } else if coord.kind == .Sync {
            if fiber.status == .Failed || fiber.status == .Aborted do coord.has_failed = true
            if coord.active_branches <= 0 && !coord.completed {
                coord.completed = true
                parent := coord.parent
                if parent != nil && parent.status == .Suspended_Join {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent.handle)
                }
            }
        }
    }
}

// ============================================================================
// Fiber Recycling & Memory Lifecycle
// ============================================================================

fiber_cleanup_and_recycle :: proc(sched: ^Scheduler, fiber: ^Fiber) {
    // 0. Auto-cancel any remaining child fibers (e.g. branch_scoped or rush background tasks)
    for fiber.first_child != nil {
        fiber_abort_tree(sched, fiber.first_child)
    }

    // 1. Run cleanup procedure if registered
    if fiber.cleanup_proc != nil {
        fiber.cleanup_proc(fiber.cleanup_data != nil ? fiber.cleanup_data : fiber.user_data)
        fiber.cleanup_proc = nil
        fiber.cleanup_data = nil
    }

    // 2. Unlink from intrusive Wait_Queue if still attached
    if fiber.current_wait_queue != nil {
        wait_queue_remove(fiber.current_wait_queue, fiber)
        fiber.current_wait_queue = nil
    }

    // 3. Unlink from parent
    if fiber.parent != nil {
        fiber_unlink_child(fiber.parent, fiber)
    }

    // 4. Remove from scope if attached (O(1) in-place unlinking)
    if fiber.scope != nil {
        fiber_scope_detach(fiber)
    }

    // 5. Record status in history before recycling
    if fiber.handle != 0 {
        sched.fiber_pool.handle_history[u32(fiber.handle) % FIBER_HANDLE_HISTORY_CAPACITY].status = fiber.status
    }

    // 6. Return to pool
    fiber_pool_recycle(&sched.fiber_pool, fiber)
}

fiber_abort_tree :: proc(sched: ^Scheduler, root: ^Fiber) {
    if root == nil || root.status == .Unused || root.status == .Aborted do return

    prev_status := root.status
    root.status = .Aborted

    // 1. Recursively abort all children bottom-up (clean in-place drain)
    for root.first_child != nil {
        fiber_abort_tree(sched, root.first_child)
    }

    // 2. Remove root from scheduler clock domain queues
    cid := int(root.clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    c := &sched.clocks[cid]

    switch prev_status {
    case .Ready:
        // Already marked aborted
    case .Sleeping_Time:
        if root.heap_index >= 0 {
            clock_heap_remove(c, root.heap_index)
        }
    case .Sleeping_Steps:
        for i in 0 ..< len(c.step_waiters) {
            if c.step_waiters[i] == root {
                unordered_remove(&c.step_waiters, i)
                break
            }
        }
    case .Suspended_Join, .Running, .Completed, .Failed, .Aborted, .Unused:
        // No queue removal required
    }

    // 3. If fiber is sitting in an intrusive synchronization Wait_Queue, safely unlink it in O(1)
    if root.current_wait_queue != nil {
        wait_queue_remove(root.current_wait_queue, root)
        root.current_wait_queue = nil
    }

    fiber_on_finish(root)
    fiber_cleanup_and_recycle(sched, root)
}

fiber_find_by_handle :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> ^Fiber {
    if handle == 0 || sched == nil do return nil
    idx := int(fiber_handle_index(handle))
    if idx >= len(sched.fiber_pool.all_fibers) do return nil

    fiber := sched.fiber_pool.all_fibers[idx]
    if fiber.handle == handle && fiber.status != .Unused {
        return fiber
    }
    return nil
}

fiber_cancel_sched :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> bool {
    if fiber := fiber_find_by_handle(sched, handle); fiber != nil {
        fiber_abort_tree(sched, fiber)
        return true
    }
    return false
}

fiber_cancel_fiber :: #force_inline proc(f: ^Fiber, handle: Fiber_Handle) -> bool {
    if f == nil do return false
    return fiber_cancel_sched(f.sched, handle)
}

fiber_cancel :: proc{fiber_cancel_sched, fiber_cancel_fiber}

fiber_scope_attach :: #force_inline proc "contextless" (scope: ^Fiber_Scope, fiber: ^Fiber) {
    if scope == nil || fiber == nil do return
    fiber.scope = scope
    fiber.prev_in_scope = scope.tail
    fiber.next_in_scope = nil
    if scope.tail != nil {
        scope.tail.next_in_scope = fiber
    } else {
        scope.head = fiber
    }
    scope.tail = fiber
    scope.count += 1
}

fiber_scope_detach :: #force_inline proc "contextless" (fiber: ^Fiber) {
    if fiber == nil || fiber.scope == nil do return
    scope := fiber.scope
    if fiber.prev_in_scope != nil {
        fiber.prev_in_scope.next_in_scope = fiber.next_in_scope
    } else if scope.head == fiber {
        scope.head = fiber.next_in_scope
    }
    if fiber.next_in_scope != nil {
        fiber.next_in_scope.prev_in_scope = fiber.prev_in_scope
    } else if scope.tail == fiber {
        scope.tail = fiber.prev_in_scope
    }
    scope.count -= 1
    fiber.prev_in_scope = nil
    fiber.next_in_scope = nil
    fiber.scope = nil
}

scope_cancel_sched :: proc(sched: ^Scheduler, scope: ^Fiber_Scope) -> (cancelled_count: int) {
    if scope == nil || sched == nil do return 0
    for scope.head != nil {
        fiber := scope.head
        if fiber_cancel_sched(sched, fiber.handle) {
            cancelled_count += 1
        } else {
            // Fallback: if fiber_cancel did not detach, detach manually to prevent infinite loop
            fiber_scope_detach(fiber)
        }
    }
    return cancelled_count
}

scope_cancel_fiber :: #force_inline proc(f: ^Fiber, scope: ^Fiber_Scope) -> (cancelled_count: int) {
    if f == nil do return 0
    return scope_cancel_sched(f.sched, scope)
}

scope_cancel :: proc{scope_cancel_sched, scope_cancel_fiber}

scope_destroy_sched :: proc(sched: ^Scheduler, scope: ^Fiber_Scope) {
    if scope == nil do return
    scope_cancel_sched(sched, scope)
    scope.head = nil
    scope.tail = nil
    scope.count = 0
}

scope_destroy_fiber :: #force_inline proc(f: ^Fiber, scope: ^Fiber_Scope) {
    if f == nil do return
    scope_destroy_sched(f.sched, scope)
}

scope_destroy :: proc{scope_destroy_sched, scope_destroy_fiber}

scope_active_count :: #force_inline proc "contextless" (scope: ^Fiber_Scope) -> int {
    return scope != nil ? scope.count : 0
}

scope_is_busy :: #force_inline proc "contextless" (scope: ^Fiber_Scope) -> bool {
    return scope != nil && scope.head != nil
}

scope_is_empty :: #force_inline proc "contextless" (scope: ^Fiber_Scope) -> bool {
    return scope == nil || scope.head == nil
}

// ============================================================================
// Clock Domain Queries & Low-Level Suspend/Wake Primitives
// ============================================================================

scheduler_time :: #force_inline proc "contextless" (sched: ^Scheduler, clock_id: Clock_ID = CLOCK_SIM) -> f64 {
    if sched == nil do return 0.0
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    return sched.clocks[cid].time
}

scheduler_delta_time :: #force_inline proc "contextless" (sched: ^Scheduler, clock_id: Clock_ID = CLOCK_SIM) -> f32 {
    if sched == nil do return 0.0
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    return sched.clocks[cid].delta
}

scheduler_steps :: #force_inline proc "contextless" (sched: ^Scheduler, clock_id: Clock_ID = CLOCK_SIM) -> u64 {
    if sched == nil do return 0
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    return sched.clocks[cid].steps
}

scheduler_sim_time    :: scheduler_time
scheduler_frame_count :: scheduler_steps

fiber_suspend :: proc(f: ^Fiber) {
    if f == nil || f.sched == nil do return
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

fiber_wake :: proc(sched: ^Scheduler, f: ^Fiber) -> bool {
    if sched == nil || f == nil do return false
    if f.status == .Suspended_Join && fiber_is_alive(sched, f.handle) {
        f.status = .Ready
        append(&sched.ready_queue, f.handle)
        return true
    }
    return false
}

scheduler_prewarm :: proc(sched: ^Scheduler, fiber_count: int, allocator := context.allocator) {
    if sched == nil do return
    fiber_pool_prewarm(&sched.fiber_pool, fiber_count, allocator)
}

scheduler_pool_stats :: proc(sched: ^Scheduler) -> Pool_Stats {
    if sched == nil do return {}
    return fiber_pool_stats(&sched.fiber_pool)
}

// ============================================================================
// Tree Traversal & Diagnostics Utility
// ============================================================================

scheduler_walk_tree :: proc(sched: ^Scheduler, visitor: Fiber_Visitor, user_data: rawptr = nil) {
    if sched == nil || visitor == nil do return

    walk_node :: proc(f: ^Fiber, depth: int, visitor: Fiber_Visitor, user_data: rawptr) {
        if f == nil do return
        visitor(f, depth, user_data)
        child := f.first_child
        for child != nil {
            walk_node(child, depth + 1, visitor, user_data)
            child = child.next_sibling
        }
    }

    for f in sched.fiber_pool.all_fibers {
        if f.status != .Unused && f.parent == nil {
            walk_node(f, 0, visitor, user_data)
        }
    }
}
