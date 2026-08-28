package coroutine

import "base:runtime"
import "base:intrinsics"
import "core:fmt"
import "core:time"

// ============================================================================
// Scheduler Lifecycle
// ============================================================================

scheduler_init :: proc(
    sched: ^Scheduler,
    stack_size: uint = DEFAULT_STACK_SIZE,
    stacks_per_slab: int = 32,
    alloc_mode: Stack_Allocation_Mode = .Standard_Slab,
    allocator := context.allocator,
) {
    sched.ready_queue = make([dynamic]^Fiber, allocator)
    sched.timer_heap = make([dynamic]^Fiber, allocator)
    sched.real_timer_heap = make([dynamic]^Fiber, allocator)
    sched.tick_waiters = make([dynamic]^Fiber, allocator)
    sched.frame_waiters = make([dynamic]^Fiber, allocator)
    sched.condition_waiters = make([dynamic]^Fiber, allocator)
    fiber_pool_init(&sched.fiber_pool, stack_size, stacks_per_slab, alloc_mode, allocator)

    sched.clock = Scheduler_Clock{
        time_scale   = 1.0,
        tick_rate_hz = 1000,
    }

    sched.scheduler_sp = nil
    sched.current_fiber = nil
    sched.watchdog_enabled = ODIN_DEBUG
    sched.watchdog_max_slice_ms = 100.0
}

scheduler_init_config :: proc(sched: ^Scheduler, config: Fiber_Pool_Config) {
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    sched.ready_queue = make([dynamic]^Fiber, allocator)
    sched.timer_heap = make([dynamic]^Fiber, allocator)
    sched.real_timer_heap = make([dynamic]^Fiber, allocator)
    sched.tick_waiters = make([dynamic]^Fiber, allocator)
    sched.frame_waiters = make([dynamic]^Fiber, allocator)
    sched.condition_waiters = make([dynamic]^Fiber, allocator)
    fiber_pool_init_config(&sched.fiber_pool, config)

    sched.clock = Scheduler_Clock{
        time_scale   = 1.0,
        tick_rate_hz = 1000,
    }

    sched.scheduler_sp = nil
    sched.current_fiber = nil
    sched.watchdog_enabled = ODIN_DEBUG
    sched.watchdog_max_slice_ms = 100.0
}

scheduler_destroy :: proc(sched: ^Scheduler, allocator := context.allocator) {
    // Abort all active fibers
    for fiber in sched.fiber_pool.all_fibers {
        if fiber.status != .Unused {
            if fiber.cleanup_proc != nil {
                fiber.cleanup_proc(fiber.user_data)
                fiber.cleanup_proc = nil
            }
        }
    }

    delete(sched.ready_queue)
    delete(sched.timer_heap)
    delete(sched.real_timer_heap)
    delete(sched.tick_waiters)
    delete(sched.frame_waiters)
    delete(sched.condition_waiters)
    fiber_pool_destroy(&sched.fiber_pool, allocator)
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

timer_heap_push :: proc(sched: ^Scheduler, fiber: ^Fiber) {
    idx := len(sched.timer_heap)
    fiber.heap_index = idx
    append(&sched.timer_heap, fiber)
    heap_sift_up(&sched.timer_heap, idx)
}

timer_heap_pop :: proc(sched: ^Scheduler) -> ^Fiber {
    count := len(sched.timer_heap)
    if count == 0 do return nil

    root := sched.timer_heap[0]
    root.heap_index = -1

    last := pop(&sched.timer_heap)
    if count > 1 {
        last.heap_index = 0
        sched.timer_heap[0] = last
        heap_sift_down(&sched.timer_heap, 0)
    }

    return root
}

timer_heap_remove :: proc(sched: ^Scheduler, index: int) {
    count := len(sched.timer_heap)
    if index < 0 || index >= count do return

    target := sched.timer_heap[index]
    target.heap_index = -1

    if index == count - 1 {
        pop(&sched.timer_heap)
        return
    }

    last := pop(&sched.timer_heap)
    last.heap_index = index
    sched.timer_heap[index] = last

    // Rebalance
    parent := (index - 1) / 2
    if index > 0 && sched.timer_heap[index].wake_time < sched.timer_heap[parent].wake_time {
        heap_sift_up(&sched.timer_heap, index)
    } else {
        heap_sift_down(&sched.timer_heap, index)
    }
}

real_timer_heap_push :: proc(sched: ^Scheduler, fiber: ^Fiber) {
    idx := len(sched.real_timer_heap)
    fiber.heap_index = idx
    append(&sched.real_timer_heap, fiber)
    heap_sift_up(&sched.real_timer_heap, idx)
}

real_timer_heap_pop :: proc(sched: ^Scheduler) -> ^Fiber {
    count := len(sched.real_timer_heap)
    if count == 0 do return nil

    root := sched.real_timer_heap[0]
    root.heap_index = -1

    last := pop(&sched.real_timer_heap)
    if count > 1 {
        last.heap_index = 0
        sched.real_timer_heap[0] = last
        heap_sift_down(&sched.real_timer_heap, 0)
    }

    return root
}

real_timer_heap_remove :: proc(sched: ^Scheduler, index: int) {
    count := len(sched.real_timer_heap)
    if index < 0 || index >= count do return

    target := sched.real_timer_heap[index]
    target.heap_index = -1

    if index == count - 1 {
        pop(&sched.real_timer_heap)
        return
    }

    last := pop(&sched.real_timer_heap)
    last.heap_index = index
    sched.real_timer_heap[index] = last

    // Rebalance
    parent := (index - 1) / 2
    if index > 0 && sched.real_timer_heap[index].wake_time < sched.real_timer_heap[parent].wake_time {
        heap_sift_up(&sched.real_timer_heap, index)
    } else {
        heap_sift_down(&sched.real_timer_heap, index)
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

scheduler_step :: proc(sched: ^Scheduler, dt: f32) {
    if sched.clock.is_paused {
        scheduler_advance_real(sched, dt)
        return
    }

    real_dt := dt
    sim_dt := f64(dt * sched.clock.time_scale)
    sim_ticks := u64(sim_dt * f64(sched.clock.tick_rate_hz))

    scheduler_advance(sched, real_dt, sim_dt, sim_ticks)
}

scheduler_single_step :: proc(sched: ^Scheduler, dt: f32) {
    real_dt := dt
    sim_dt := f64(dt * sched.clock.time_scale)
    if sim_dt == 0.0 do sim_dt = f64(dt)
    sim_ticks := u64(sim_dt * f64(sched.clock.tick_rate_hz))
    if sim_ticks == 0 && dt > 0.0 do sim_ticks = 1

    scheduler_advance(sched, real_dt, sim_dt, sim_ticks)
}

scheduler_step_ticks :: proc(sched: ^Scheduler, ticks: u64) {
    if sched.clock.is_paused {
        rate := sched.clock.tick_rate_hz > 0 ? sched.clock.tick_rate_hz : 1000
        sec := f32(ticks) / f32(rate)
        scheduler_advance_real(sched, sec)
        return
    }

    rate := sched.clock.tick_rate_hz > 0 ? sched.clock.tick_rate_hz : 1000
    sec := f64(ticks) / f64(rate)
    real_dt := f32(sec)
    sim_dt := sec
    sim_ticks := ticks

    scheduler_advance(sched, real_dt, sim_dt, sim_ticks)
}

scheduler_step_dual :: proc(sched: ^Scheduler, real_dt: f32, sim_dt: f32) {
    if sched.clock.is_paused {
        scheduler_advance_real(sched, real_dt)
        return
    }

    scaled_sim_dt := f64(sim_dt * sched.clock.time_scale)
    sim_ticks := u64(scaled_sim_dt * f64(sched.clock.tick_rate_hz))

    scheduler_advance(sched, real_dt, scaled_sim_dt, sim_ticks)
}

scheduler_advance_real :: proc(sched: ^Scheduler, real_dt: f32) {
    // Advance Real / Wall Clock
    sched.clock.real_delta = real_dt
    sched.clock.real_time += f64(real_dt)
    sched.clock.real_ticks += u64(f64(real_dt) * 1000.0)

    // Wake Real-Time Timers from Real-Timer Min-Heap
    for len(sched.real_timer_heap) > 0 {
        root := sched.real_timer_heap[0]
        if root.wake_time <= sched.clock.real_time {
            f := real_timer_heap_pop(sched)
            if f != nil && f.status == .Sleeping_Real_Time {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        } else {
            break
        }
    }

    // Execute only real-time fibers in ready queue
    queue_len := len(sched.ready_queue)
    for _ in 0 ..< queue_len {
        if len(sched.ready_queue) == 0 do break
        f := pop_front(&sched.ready_queue)
        if f.status != .Ready do continue

        if f.wake_clock != .Real_Time {
            // Keep simulation fibers deferred until unpaused or stepped
            append(&sched.ready_queue, f)
            continue
        }

        f.status = .Running
        sched.current_fiber = f

        // Context switch into the fiber
        fiber_context_switch(&sched.scheduler_sp, f.saved_sp)

        sched.current_fiber = nil

        // Post-execution check
        status := intrinsics.volatile_load(&f.status)
        if status == .Completed || status == .Failed || status == .Aborted {
            fiber_cleanup_and_recycle(sched, f)
        }
    }
}

scheduler_advance :: proc(sched: ^Scheduler, real_dt: f32, sim_dt: f64, sim_ticks: u64) {
    // 1. Advance Real / Wall Clock
    sched.clock.real_delta = real_dt
    sched.clock.real_time += f64(real_dt)
    sched.clock.real_ticks += u64(f64(real_dt) * 1000.0)

    // 2. Advance Scaled Simulation Clock & Discrete Ticks
    sched.clock.sim_delta = f32(sim_dt)
    sched.clock.sim_time += sim_dt
    sched.clock.sim_ticks += sim_ticks
    sched.clock.frame_count += 1

    // 3. Wake Real-Time Timers from Real-Timer Min-Heap
    for len(sched.real_timer_heap) > 0 {
        root := sched.real_timer_heap[0]
        if root.wake_time <= sched.clock.real_time {
            f := real_timer_heap_pop(sched)
            if f != nil && f.status == .Sleeping_Real_Time {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        } else {
            break
        }
    }

    // 4. Wake Scaled-Sim Timers from Timer Min-Heap
    for len(sched.timer_heap) > 0 {
        root := sched.timer_heap[0]
        if root.wake_time <= sched.clock.sim_time {
            f := timer_heap_pop(sched)
            if f != nil && f.status == .Sleeping_Time {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        } else {
            break
        }
    }

    // 5. Wake Discrete Tick Waiters (Linear In-Place Partition)
    if sim_ticks > 0 && len(sched.tick_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(sched.tick_waiters); i += 1 {
            f := sched.tick_waiters[i]
            if f.wake_ticks <= sched.clock.sim_ticks {
                if f.status == .Sleeping_Ticks {
                    f.status = .Ready
                    append(&sched.ready_queue, f)
                }
            } else {
                sched.tick_waiters[write_idx] = f
                write_idx += 1
            }
        }
        resize(&sched.tick_waiters, write_idx)
    }

    // 6. Wake Frame Waiters (Linear In-Place Partition)
    if len(sched.frame_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(sched.frame_waiters); i += 1 {
            f := sched.frame_waiters[i]
            if f.wake_frame <= sched.clock.frame_count {
                if f.status == .Sleeping_Frames {
                    f.status = .Ready
                    append(&sched.ready_queue, f)
                }
            } else {
                sched.frame_waiters[write_idx] = f
                write_idx += 1
            }
        }
        resize(&sched.frame_waiters, write_idx)
    }

    // 7. Poll Condition Waiters (Linear In-Place Partition)
    if len(sched.condition_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(sched.condition_waiters); i += 1 {
            f := sched.condition_waiters[i]
            if f.condition_fn != nil && f.condition_fn(f.condition_data) {
                if f.status == .Waiting_Condition {
                    f.status = .Ready
                    append(&sched.ready_queue, f)
                }
            } else {
                sched.condition_waiters[write_idx] = f
                write_idx += 1
            }
        }
        resize(&sched.condition_waiters, write_idx)
    }

    // 8. Execute Ready Queue (Zero-Shift O(N) Sequential Cursor)
    for i := 0; i < len(sched.ready_queue); i += 1 {
        f := sched.ready_queue[i]
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
                fmt.panicf("[WATCHDOG PANIC] Runaway non-yielding fiber detected! Fiber [#%d] '%s' executed for %.2f ms without yielding! Did you write an infinite loop without wait() or yield_frame()?", f.handle, f.debug_name, elapsed_ms)
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

// ============================================================================
// Completion & Cancellation
// ============================================================================

fiber_on_finish :: proc(fiber: ^Fiber) {
    if fiber.join_coord != nil {
        coord := fiber.join_coord
        coord.active_branches -= 1

        if coord.kind == .Race {
            if fiber.status != .Aborted && !coord.completed {
                coord.completed = true
                coord.winner = fiber
                coord.winner_index = fiber.branch_index

                // Abort sibling branches immediately
                parent := coord.parent
                if parent != nil {
                    child := parent.first_child
                    for child != nil {
                        next := child.next_sibling
                        if child != fiber {
                            fiber_abort_tree(fiber.sched, child)
                        }
                        child = next
                    }

                    // Wake up parent
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent)
                }
            } else if coord.active_branches <= 0 && !coord.completed {
                coord.completed = true
                coord.winner = nil
                coord.winner_index = -1
                parent := coord.parent
                if parent != nil {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent)
                }
            }
        } else if coord.kind == .Rush {
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
                        if child != fiber {
                            fiber_abort_tree(fiber.sched, child)
                        }
                        child = next
                    }

                    // Wake up parent
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent)
                }
            } else if coord.active_branches <= 0 && !coord.completed {
                // All branches finished without any success
                coord.completed = true
                coord.winner = nil
                coord.winner_index = -1
                parent := coord.parent
                if parent != nil {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent)
                }
            }
        } else if coord.kind == .Sync {
            if fiber.status == .Failed || fiber.status == .Aborted do coord.has_failed = true
            if coord.active_branches <= 0 && !coord.completed {
                coord.completed = true
                parent := coord.parent
                if parent != nil {
                    parent.status = .Ready
                    append(&fiber.sched.ready_queue, parent)
                }
            }
        }
    }
}

fiber_cleanup_and_recycle :: proc(sched: ^Scheduler, fiber: ^Fiber) {
    // 1. Run cleanup procedure if registered
    if fiber.cleanup_proc != nil {
        fiber.cleanup_proc(fiber.user_data)
        fiber.cleanup_proc = nil
    }

    // 2. Unlink from parent
    if fiber.parent != nil {
        fiber_unlink_child(fiber.parent, fiber)
    }

    // 3. Remove from scope if attached
    if fiber.scope != nil {
        for i in 0 ..< len(fiber.scope.handles) {
            if fiber.scope.handles[i] == fiber.handle {
                unordered_remove(&fiber.scope.handles, i)
                break
            }
        }
        fiber.scope = nil
    }

    // 4. Record status in history before recycling
    if fiber.handle != 0 {
        sched.fiber_pool.handle_history[u32(fiber.handle) % FIBER_HANDLE_HISTORY_CAPACITY].status = fiber.status
    }

    // 5. Return to pool
    fiber_pool_recycle(&sched.fiber_pool, fiber)
}

fiber_abort_tree :: proc(sched: ^Scheduler, root: ^Fiber) {
    if root == nil || root.status == .Unused do return

    // 1. Recursively abort all children bottom-up
    child := root.first_child
    for child != nil {
        next := child.next_sibling
        fiber_abort_tree(sched, child)
        child = next
    }

    // 2. Remove root from scheduler queues
    switch root.status {
    case .Ready:
        root.status = .Aborted
    case .Sleeping_Time:
        if root.heap_index >= 0 {
            timer_heap_remove(sched, root.heap_index)
        }
    case .Sleeping_Real_Time:
        if root.heap_index >= 0 {
            real_timer_heap_remove(sched, root.heap_index)
        }
    case .Sleeping_Ticks:
        for i in 0 ..< len(sched.tick_waiters) {
            if sched.tick_waiters[i] == root {
                unordered_remove(&sched.tick_waiters, i)
                break
            }
        }
    case .Sleeping_Frames:
        for i in 0 ..< len(sched.frame_waiters) {
            if sched.frame_waiters[i] == root {
                unordered_remove(&sched.frame_waiters, i)
                break
            }
        }
    case .Waiting_Condition:
        for i in 0 ..< len(sched.condition_waiters) {
            if sched.condition_waiters[i] == root {
                unordered_remove(&sched.condition_waiters, i)
                break
            }
        }
    case .Suspended_Join, .Running, .Completed, .Failed, .Aborted, .Unused:
        // No queue removal required
    }

    root.status = .Aborted
    fiber_on_finish(root)
    fiber_cleanup_and_recycle(sched, root)
}

fiber_find_by_handle :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> ^Fiber {
    if handle == 0 do return nil
    for fiber in sched.fiber_pool.all_fibers {
        if fiber.handle == handle && fiber.status != .Unused {
            return fiber
        }
    }
    return nil
}

fiber_cancel :: proc(sched: ^Scheduler, handle: Fiber_Handle) {
    if fiber := fiber_find_by_handle(sched, handle); fiber != nil {
        fiber_abort_tree(sched, fiber)
    }
}

scope_cancel :: proc(sched: ^Scheduler, scope: ^Fiber_Scope) {
    if scope == nil do return
    for len(scope.handles) > 0 {
        handle := pop(&scope.handles)
        fiber_cancel(sched, handle)
    }
}

scope_destroy :: proc(sched: ^Scheduler, scope: ^Fiber_Scope) {
    if scope == nil do return
    scope_cancel(sched, scope)
    delete(scope.handles)
    scope.handles = nil
}

scope_active_count :: proc(scope: ^Fiber_Scope) -> int {
    if scope == nil do return 0
    return len(scope.handles)
}

scope_is_busy :: proc(scope: ^Fiber_Scope) -> bool {
    return scope_active_count(scope) > 0
}

scope_is_empty :: proc(scope: ^Fiber_Scope) -> bool {
    return scope_active_count(scope) == 0
}

// ============================================================================
// Clock & Time Controls
// ============================================================================

scheduler_set_paused :: proc(sched: ^Scheduler, paused: bool) {
    if sched == nil do return
    sched.clock.is_paused = paused
}

scheduler_is_paused :: #force_inline proc(sched: ^Scheduler) -> bool {
    return sched != nil && sched.clock.is_paused
}

scheduler_set_time_scale :: proc(sched: ^Scheduler, scale: f32) {
    if sched == nil do return
    sched.clock.time_scale = scale
}

scheduler_time_scale :: #force_inline proc(sched: ^Scheduler) -> f32 {
    return sched != nil ? sched.clock.time_scale : 1.0
}

scheduler_sim_time :: #force_inline proc(sched: ^Scheduler) -> f64 {
    return sched != nil ? sched.clock.sim_time : 0.0
}

scheduler_real_time :: #force_inline proc(sched: ^Scheduler) -> f64 {
    return sched != nil ? sched.clock.real_time : 0.0
}

scheduler_sim_ticks :: #force_inline proc(sched: ^Scheduler) -> u64 {
    return sched != nil ? sched.clock.sim_ticks : 0
}

scheduler_frame_count :: #force_inline proc(sched: ^Scheduler) -> u64 {
    return sched != nil ? sched.clock.frame_count : 0
}

scheduler_delta_time :: #force_inline proc(sched: ^Scheduler) -> f32 {
    return sched != nil ? sched.clock.sim_delta : 0.0
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
