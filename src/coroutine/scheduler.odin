package coroutine

import "base:runtime"
import "base:intrinsics"

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
    sched.frame_waiters = make([dynamic]^Fiber, allocator)
    sched.condition_waiters = make([dynamic]^Fiber, allocator)
    fiber_pool_init(&sched.fiber_pool, stack_size, stacks_per_slab, alloc_mode, allocator)

    sched.current_time = 0.0
    sched.current_frame = 0
    sched.delta_time = 0.0
    sched.time_scale = 1.0
    sched.is_paused = false
    sched.scheduler_sp = nil
    sched.current_fiber = nil
}

scheduler_init_config :: proc(sched: ^Scheduler, config: Fiber_Pool_Config) {
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    sched.ready_queue = make([dynamic]^Fiber, allocator)
    sched.timer_heap = make([dynamic]^Fiber, allocator)
    sched.frame_waiters = make([dynamic]^Fiber, allocator)
    sched.condition_waiters = make([dynamic]^Fiber, allocator)
    fiber_pool_init_config(&sched.fiber_pool, config)

    sched.current_time = 0.0
    sched.current_frame = 0
    sched.delta_time = 0.0
    sched.time_scale = 1.0
    sched.is_paused = false
    sched.scheduler_sp = nil
    sched.current_fiber = nil
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
// Dispatch Loop
// ============================================================================

scheduler_step :: proc(sched: ^Scheduler, dt: f32) {
    if sched.is_paused do return

    // 1. Advance Time
    sched.delta_time = dt
    effective_dt := f64(dt * sched.time_scale)
    sched.current_time += effective_dt
    sched.current_frame += 1

    // 2. Wake Timers from Min-Heap
    for len(sched.timer_heap) > 0 {
        root := sched.timer_heap[0]
        if root.wake_time <= sched.current_time {
            f := timer_heap_pop(sched)
            if f != nil && f.status == .Sleeping_Time {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        } else {
            break
        }
    }

    // 3. Wake Frame Waiters
    for i := len(sched.frame_waiters) - 1; i >= 0; i -= 1 {
        f := sched.frame_waiters[i]
        if f.wake_frame <= sched.current_frame {
            unordered_remove(&sched.frame_waiters, i)
            if f.status == .Sleeping_Frames {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        }
    }

    // 4. Poll Condition Waiters
    for i := len(sched.condition_waiters) - 1; i >= 0; i -= 1 {
        f := sched.condition_waiters[i]
        if f.condition_fn != nil && f.condition_fn(f.condition_data) {
            unordered_remove(&sched.condition_waiters, i)
            if f.status == .Waiting_Condition {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        }
    }

    // 5. Execute Ready Queue
    for len(sched.ready_queue) > 0 {
        f := pop_front(&sched.ready_queue)
        if f.status != .Ready do continue

        f.status = .Running
        sched.current_fiber = f

        // Context switch into the fiber
        fiber_context_switch(&sched.scheduler_sp, f.saved_sp)

        sched.current_fiber = nil

        // Post-execution check: reload status with volatile semantics to prevent compiler SSA caching across ASM switch
        status := intrinsics.volatile_load(&f.status)
        if status == .Completed || status == .Failed || status == .Aborted {
            fiber_cleanup_and_recycle(sched, f)
        }
    }
}

// ============================================================================
// Completion & Cancellation
// ============================================================================

fiber_on_finish :: proc(fiber: ^Fiber) {
    if fiber.join_coord != nil {
        coord := fiber.join_coord
        coord.active_branches -= 1

        if coord.kind == .Race {
            if !coord.completed {
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
            }
        } else if coord.kind == .Sync {
            if fiber.status == .Failed do coord.has_failed = true
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
    // fmt.println("DEBUG: cleanup_and_recycle fiber status =", fiber.status)
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

    // 4. Return to pool
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
        for i in 0 ..< len(sched.ready_queue) {
            if sched.ready_queue[i] == root {
                ordered_remove(&sched.ready_queue, i)
                break
            }
        }
    case .Sleeping_Time:
        if root.heap_index >= 0 {
            timer_heap_remove(sched, root.heap_index)
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
