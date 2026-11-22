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
    sched.async_waiters = make([dynamic]^Fiber, sched.allocator)
    for i in 0 ..< MAX_CLOCKS {
        sched.clocks[i] = Clock_Domain{
            timer_heap   = make([dynamic]^Fiber, sched.allocator),
            step_waiters = make([dynamic]^Fiber, sched.allocator),
        }
    }
    fiber_pool_init(&sched.fiber_pool, stack_size, stacks_per_slab, alloc_mode, sched.allocator)

    sched.scheduler_sp = nil
    sched.current_fiber = nil
    sched.pending_abort_root = nil
    sched.watchdog_enabled = WATCHDOG_ENABLED
    sched.watchdog_max_slice_ms = WATCHDOG_MAX_SLICE_MS
    sched.trace_hook = nil
    sched.trace_user_data = nil
}

scheduler_set_trace_hook :: proc(sched: ^Scheduler, hook: Trace_Hook, user_data: rawptr = nil) {
    if sched == nil do return
    sched.trace_hook = hook
    sched.trace_user_data = user_data
}

@(private="package")
scheduler_emit_trace :: #force_inline proc(sched: ^Scheduler, event: Trace_Event, f: ^Fiber) {
    if sched != nil && sched.trace_hook != nil {
        sched.trace_hook(event, f, sched.trace_user_data)
    }
}

scheduler_init_config :: proc(sched: ^Scheduler, config: Fiber_Pool_Config) {
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    scheduler_init(
        sched,
        config.stack_size == 0 ? DEFAULT_STACK_SIZE : config.stack_size,
        config.stacks_per_slab == 0 ? STACKS_PER_SLAB : config.stacks_per_slab,
        config.alloc_mode,
        allocator,
    )
}

scheduler_destroy :: proc(sched: ^Scheduler) {
    if sched == nil do return
    for fiber in sched.fiber_pool.all_fibers {
        if fiber.status != .Unused {
            if fiber.current_wait_queue != nil {
                wait_queue_remove(fiber.current_wait_queue, fiber)
                fiber.current_wait_queue = nil
            }
            wait_queue_clear(&fiber.join_waiters)
            if fiber.scope != nil {
                fiber_scope_detach(fiber)
            }
            if fiber.async_header != nil {
                if fiber.async_cancel_on_abort {
                    intrinsics.atomic_store_explicit(&fiber.async_header.cancelled, true, .Release)
                }
                fiber.async_header = nil
                fiber.async_index = -1
                fiber.async_cancel_on_abort = false
            }
            for i := fiber.cleanup_count - 1; i >= 0; i -= 1 {
                hook := fiber.cleanups[i]
                if hook.proc_ptr != nil {
                    hook.proc_ptr(hook.user_data != nil ? hook.user_data : fiber.user_data)
                }
            }
            fiber.cleanup_count = 0
        }
    }

    delete(sched.ready_queue)
    sched.ready_queue = nil
    delete(sched.async_waiters)
    sched.async_waiters = nil
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

@(private="package")
clock_heap_push :: proc(clock: ^Clock_Domain, fiber: ^Fiber) {
    idx := len(clock.timer_heap)
    fiber.heap_index = idx
    append(&clock.timer_heap, fiber)
    heap_sift_up(&clock.timer_heap, idx)
}

@(private="package")
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

@(private="package")
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

@(private="package")
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

@(private="package")
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

clock_set_paused :: proc(sched: ^Scheduler, clock_id: Clock_ID, paused: bool) {
    if sched == nil do return
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    sched.clocks[cid].paused = paused
}

clock_is_paused :: #force_inline proc "contextless" (sched: ^Scheduler, clock_id: Clock_ID) -> bool {
    if sched == nil do return false
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    return sched.clocks[cid].paused
}

clock_advance :: proc(sched: ^Scheduler, clock_id: Clock_ID, dt: f32, steps: u64 = 1) {
    if sched == nil do return
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    c := &sched.clocks[cid]
    if c.paused do return

    safe_dt := dt
    if safe_dt != safe_dt || safe_dt < 0.0 {
        safe_dt = 0.0
    }

    c.delta = safe_dt
    c.time += f64(safe_dt)
    c.steps += steps

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

    if steps > 0 && len(c.step_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(c.step_waiters); i += 1 {
            f := c.step_waiters[i]
            if f.wake_step <= c.steps {
                f.step_index = -1
                if f.status == .Sleeping_Steps {
                    f.status = .Ready
                    append(&sched.ready_queue, f.handle)
                }
            } else {
                c.step_waiters[write_idx] = f
                f.step_index = write_idx
                write_idx += 1
            }
        }
        resize(&c.step_waiters, write_idx)
    }
}

@(private="file")
scheduler_run_impl :: proc(sched: ^Scheduler, max_resumes: int) -> (resumed: int, has_more_ready: bool) {
    if sched == nil do return 0, false

    if len(sched.async_waiters) > 0 {
        write_idx := 0
        for i := 0; i < len(sched.async_waiters); i += 1 {
            f := sched.async_waiters[i]
            if f == nil || f.status != .Suspended_Join || f.async_header == nil {
                if f != nil {
                    f.async_index = -1
                    f.async_header = nil
                    f.async_cancel_on_abort = false
                }
                continue
            }
            if intrinsics.atomic_load_explicit(&f.async_header.state, .Acquire) != .Pending {
                f.async_index = -1
                f.async_header = nil
                f.async_cancel_on_abort = false
                f.status = .Ready
                append(&sched.ready_queue, f.handle)
            } else {
                sched.async_waiters[write_idx] = f
                f.async_index = write_idx
                write_idx += 1
            }
        }
        resize(&sched.async_waiters, write_idx)
    }

    write_idx := 0
    for i := 0; i < len(sched.ready_queue); i += 1 {
        h := sched.ready_queue[i]
        f := fiber_find_by_handle(sched, h)
        if f == nil || f.status != .Ready do continue

        cid := int(f.clock_id)
        if cid < 0 || cid >= MAX_CLOCKS do cid = 0
        if sched.clocks[cid].paused {
            sched.ready_queue[write_idx] = h
            write_idx += 1
            continue
        }

        if max_resumes >= 0 && resumed >= max_resumes {
            sched.ready_queue[write_idx] = h
            write_idx += 1
            has_more_ready = true
            continue
        }

        resumed += 1
        f.status = .Running
        f.resume_count += 1
        sched.current_fiber = f
        scheduler_emit_trace(sched, .Resume, f)

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

        if sched.pending_abort_root != nil {
            abort_root := sched.pending_abort_root
            sched.pending_abort_root = nil
            fiber_abort_tree(sched, abort_root)
            continue
        }

        // Reload status with volatile semantics to prevent compiler SSA caching across ASM switch
        status := intrinsics.volatile_load(&f.status)
        if status == .Completed || status == .Failed || status == .Aborted {
            if status == .Completed {
                scheduler_emit_trace(sched, .Complete, f)
            } else if status == .Failed {
                scheduler_emit_trace(sched, .Fail, f)
            } else {
                scheduler_emit_trace(sched, .Abort, f)
            }
            fiber_cleanup_and_recycle(sched, f)
        } else {
            scheduler_emit_trace(sched, .Suspend, f)
        }
    }
    resize(&sched.ready_queue, write_idx)
    return resumed, has_more_ready
}

scheduler_run :: proc(sched: ^Scheduler) {
    _, _ = scheduler_run_impl(sched, -1)
}

scheduler_run_budget :: proc(sched: ^Scheduler, max_resumes: int) -> (resumed: int, has_more_ready: bool) {
    limit := max_resumes < 0 ? 0 : max_resumes
    return scheduler_run_impl(sched, limit)
}

scheduler_next_wake_time :: proc "contextless" (sched: ^Scheduler, clock_id: Clock_ID = CLOCK_SIM) -> (dt_seconds: f64, ok: bool) {
    if sched == nil do return 0.0, false
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    clk := &sched.clocks[cid]
    if clk.paused || len(clk.timer_heap) == 0 do return 0.0, false
    next_f := clk.timer_heap[0]
    if next_f == nil do return 0.0, false
    rem := next_f.wake_time - clk.time
    return rem > 0.0 ? rem : 0.0, true
}

scheduler_has_active :: #force_inline proc "contextless" (sched: ^Scheduler) -> bool {
    if sched == nil do return false
    return len(sched.fiber_pool.all_fibers) > len(sched.fiber_pool.free_fibers)
}

scheduler_step :: proc(sched: ^Scheduler, dt: f32, clock_id: Clock_ID = CLOCK_SIM) -> (has_active: bool) {
    clock_advance(sched, clock_id, dt, 1)
    scheduler_run(sched)
    return scheduler_has_active(sched)
}

// ============================================================================
// Completion & Cancellation
// ============================================================================

@(private="file")
abort_coord_siblings :: proc(sched: ^Scheduler, parent: ^Fiber, winner: ^Fiber, coord: ^Join_Coordinator) {
    if parent == nil do return
    for {
        victim: ^Fiber = nil
        child := parent.first_child
        for child != nil {
            if child != winner && child.join_coord == coord && child.join_coord_id == coord.id {
                victim = child
                break
            }
            child = child.next_sibling
        }
        if victim == nil do break
        fiber_abort_tree(sched, victim)
    }
}

@(private="file")
fiber_is_ancestor_or_self :: proc "contextless" (ancestor: ^Fiber, node: ^Fiber) -> bool {
    cur := node
    for cur != nil {
        if cur == ancestor do return true
        cur = cur.parent
    }
    return false
}

@(private="package")
fiber_on_finish :: proc(fiber: ^Fiber) {
    if fiber.join_coord != nil {
        coord := fiber.join_coord
        if fiber.join_coord_id == coord.id {
            coord.active_branches -= 1

            if coord.kind == .Race {
                if fiber.status == .Completed && !coord.completed {
                    coord.completed = true
                    coord.winner = fiber
                    coord.winner_index = fiber.branch_index

                    parent := coord.parent
                    if parent != nil {
                        abort_coord_siblings(fiber.sched, parent, fiber, coord)

                        if parent.status == .Suspended_Join {
                            parent.status = .Ready
                            append(&fiber.sched.ready_queue, parent.handle)
                        }
                    }
                } else if coord.active_branches <= 0 && !coord.completed {
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
                    coord.completed = true
                    coord.winner = fiber
                    coord.winner_index = fiber.branch_index

                    // Detach remaining branches from join_coord so parent can reuse active_coord
                    parent := coord.parent
                    if parent != nil {
                        child := parent.first_child
                        for child != nil {
                            next := child.next_sibling
                            if child.join_coord == coord && child.join_coord_id == coord.id {
                                child.join_coord = nil
                                child.join_coord_id = 0
                            }
                            child = next
                        }

                        if parent.status == .Suspended_Join {
                            parent.status = .Ready
                            append(&fiber.sched.ready_queue, parent.handle)
                        }
                    }
                } else if coord.active_branches <= 0 && !coord.completed {
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
            } else if coord.kind == .Guard {
                if !coord.completed {
                    if fiber.branch_index == 0 {
                        coord.completed = true
                        coord.winner = fiber
                        coord.winner_index = 0
                        coord.has_failed = (fiber.status != .Completed)

                        parent := coord.parent
                        if parent != nil {
                            abort_coord_siblings(fiber.sched, parent, fiber, coord)

                            if parent.status == .Suspended_Join {
                                parent.status = .Ready
                                append(&fiber.sched.ready_queue, parent.handle)
                            }
                        }
                    } else if fiber.status == .Completed {
                        coord.completed = true
                        coord.winner = fiber
                        coord.winner_index = fiber.branch_index

                        parent := coord.parent
                        if parent != nil {
                            abort_coord_siblings(fiber.sched, parent, fiber, coord)

                            if parent.status == .Suspended_Join {
                                parent.status = .Ready
                                append(&fiber.sched.ready_queue, parent.handle)
                            }
                        }
                    } else if coord.active_branches <= 0 {
                        coord.completed = true
                        coord.winner = nil
                        coord.winner_index = -1
                        parent := coord.parent
                        if parent != nil && parent.status == .Suspended_Join {
                            parent.status = .Ready
                            append(&fiber.sched.ready_queue, parent.handle)
                        }
                    }
                }
            }
        }
        fiber.join_coord = nil
        fiber.join_coord_id = 0
    }
}

// ============================================================================
// Fiber Recycling & Memory Lifecycle
// ============================================================================

@(private="package")
fiber_cleanup_and_recycle :: proc(sched: ^Scheduler, fiber: ^Fiber) {
    for fiber.first_child != nil {
        fiber_abort_tree(sched, fiber.first_child)
    }

    for i := fiber.cleanup_count - 1; i >= 0; i -= 1 {
        hook := fiber.cleanups[i]
        if hook.proc_ptr != nil {
            hook.proc_ptr(hook.user_data != nil ? hook.user_data : fiber.user_data)
        }
    }
    fiber.cleanup_count = 0

    if fiber.current_wait_queue != nil {
        wait_queue_remove(fiber.current_wait_queue, fiber)
        fiber.current_wait_queue = nil
    }

    if fiber.parent != nil {
        fiber_unlink_child(fiber.parent, fiber)
    }

    if fiber.scope != nil {
        scope := fiber.scope
        fiber_scope_detach(fiber)
        if scope.head == nil {
            scope_wake_waiters(scope)
        }
    }

    if fiber.handle != 0 {
        sched.fiber_pool.handle_history[fiber_handle_history_slot(fiber.handle)] = Handle_Entry{
            handle = fiber.handle,
            status = fiber.status,
        }
    }

    for {
        waiter, popped := wait_queue_pop_front(&fiber.join_waiters)
        if !popped do break
        if waiter != nil {
            fiber_wake(waiter.sched, waiter)
        }
    }

    fiber_pool_recycle(&sched.fiber_pool, fiber)
}

@(private="package")
fiber_abort_tree :: proc(sched: ^Scheduler, root: ^Fiber) {
    if root == nil || root.status == .Unused || root.status == .Aborted do return

    if sched.current_fiber != nil && fiber_is_ancestor_or_self(root, sched.current_fiber) {
        cur := sched.current_fiber
        sched.pending_abort_root = root
        cur.stored_context = context
        fiber_context_switch(&cur.saved_sp, sched.scheduler_sp)
        context = cur.stored_context
        return
    }

    prev_status := root.status
    root.status = .Aborted
    scheduler_emit_trace(sched, .Abort, root)

    for root.first_child != nil {
        fiber_abort_tree(sched, root.first_child)
    }

    cid := int(root.clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do cid = 0
    c := &sched.clocks[cid]

    switch prev_status {
    case .Ready:
    case .Sleeping_Time:
        if root.heap_index >= 0 {
            clock_heap_remove(c, root.heap_index)
        }
    case .Sleeping_Steps:
        idx := root.step_index
        if idx >= 0 && idx < len(c.step_waiters) && c.step_waiters[idx] == root {
            last := len(c.step_waiters) - 1
            if idx != last {
                moved := c.step_waiters[last]
                c.step_waiters[idx] = moved
                moved.step_index = idx
            }
            pop(&c.step_waiters)
            root.step_index = -1
        }
    case .Suspended_Join, .Running, .Completed, .Failed, .Aborted, .Unused:
    }

    if root.async_header != nil {
        if root.async_cancel_on_abort {
            intrinsics.atomic_store_explicit(&root.async_header.cancelled, true, .Release)
        }
        if root.async_index >= 0 {
            idx := root.async_index
            if idx < len(sched.async_waiters) && sched.async_waiters[idx] == root {
                last := len(sched.async_waiters) - 1
                if idx != last {
                    moved := sched.async_waiters[last]
                    sched.async_waiters[idx] = moved
                    moved.async_index = idx
                }
                pop(&sched.async_waiters)
            }
            root.async_index = -1
        }
        root.async_header = nil
        root.async_cancel_on_abort = false
    }
    root.event_dest = nil

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

@(private="package")
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

@(private="package")
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

@(private="package")
scope_wake_waiters :: proc(scope: ^Fiber_Scope) {
    if scope == nil do return
    for {
        waiter, popped := wait_queue_pop_front(&scope.waiters)
        if !popped do break
        if waiter != nil {
            fiber_wake(waiter.sched, waiter)
        }
    }
}

scope_cancel_sched :: proc(sched: ^Scheduler, scope: ^Fiber_Scope) -> (cancelled_count: int) {
    if scope == nil || sched == nil do return 0
    deferred_self: ^Fiber = nil
    for {
        target: ^Fiber = nil
        cur := scope.head
        for cur != nil {
            if sched.current_fiber != nil && fiber_is_ancestor_or_self(cur, sched.current_fiber) {
                if deferred_self == nil || fiber_is_ancestor_or_self(cur, deferred_self) {
                    deferred_self = cur
                }
                cur = cur.next_in_scope
                continue
            }
            target = cur
            break
        }
        if target == nil do break
        if fiber_cancel_sched(sched, target.handle) {
            cancelled_count += 1
        } else {
            fiber_scope_detach(target)
        }
    }
    if deferred_self != nil && deferred_self.scope == scope {
        if fiber_cancel_sched(sched, deferred_self.handle) {
            cancelled_count += 1
        }
    }
    scope_wake_waiters(scope)
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
