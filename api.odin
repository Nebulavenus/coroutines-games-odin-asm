package coroutine

import "base:intrinsics"
import "core:mem"

// ============================================================================
// Public Spawning & Yielding API
// ============================================================================

@(private="file")
clamp_clock_id :: #force_inline proc "contextless" (clock_id: Clock_ID) -> Clock_ID {
    cid := int(clock_id)
    if cid < 0 || cid >= MAX_CLOCKS do return CLOCK_SIM
    return Clock_ID(cid)
}

spawn_ptr :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle {
    cid := clamp_clock_id(clock)
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.clock_id = cid
    fiber.debug_name = name
    fiber.start_time = sched.clocks[int(cid)].time
    fiber.user_data = rawptr(data)
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = cast(proc(f: ^Fiber, user_data: rawptr))entry

    if scope != nil {
        fiber_scope_attach(scope, fiber)
    }

    append(&sched.ready_queue, fiber.handle)
    return fiber.handle
}

spawn_val :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "spawn_val: payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")

    wrapper :: proc(f: ^Fiber, user_data: rawptr) {
        fn := cast(proc(f: ^Fiber, data: T))f.user_fn
        if fn != nil && user_data != nil {
            val := (^T)(user_data)^
            fn(f, val)
        }
    }

    cid := clamp_clock_id(clock)
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.clock_id = cid
    fiber.debug_name = name
    fiber.start_time = sched.clocks[int(cid)].time

    data_copy := data
    mem.copy(&fiber.payload_storage[0], &data_copy, size_of(T))
    fiber.user_data = &fiber.payload_storage[0]
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = wrapper

    if scope != nil {
        fiber_scope_attach(scope, fiber)
    }

    append(&sched.ready_queue, fiber.handle)
    return fiber.handle
}

spawn_nil :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber),
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle {
    wrapper :: proc(f: ^Fiber, user_data: rawptr) {
        real_entry := cast(proc(f: ^Fiber))user_data
        if real_entry != nil {
            real_entry(f)
        }
    }

    cid := clamp_clock_id(clock)
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.clock_id = cid
    fiber.debug_name = name
    fiber.start_time = sched.clocks[int(cid)].time
    fiber.user_data = rawptr(entry)
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = wrapper

    if scope != nil {
        fiber_scope_attach(scope, fiber)
    }

    append(&sched.ready_queue, fiber.handle)
    return fiber.handle
}

spawn :: proc{spawn_ptr, spawn_val, spawn_nil}

// ============================================================================
// Clock Domain Selection & Time Queries
// ============================================================================

fiber_set_clock :: #force_inline proc "contextless" (f: ^Fiber, clock: Clock_ID) {
    if f != nil {
        f.clock_id = clamp_clock_id(clock)
    }
}

fiber_clock :: #force_inline proc "contextless" (f: ^Fiber) -> Clock_ID {
    return f != nil ? f.clock_id : CLOCK_SIM
}

delta_time :: #force_inline proc "contextless" (f: ^Fiber) -> f32 {
    if f == nil || f.sched == nil do return 0.0
    cid := int(clamp_clock_id(f.clock_id))
    return f.sched.clocks[cid].delta
}

current_time :: #force_inline proc "contextless" (f: ^Fiber) -> f64 {
    if f == nil || f.sched == nil do return 0.0
    cid := int(clamp_clock_id(f.clock_id))
    return f.sched.clocks[cid].time
}

current_steps :: #force_inline proc "contextless" (f: ^Fiber) -> u64 {
    if f == nil || f.sched == nil do return 0
    cid := int(clamp_clock_id(f.clock_id))
    return f.sched.clocks[cid].steps
}

// ============================================================================
// Yielding & Timing Primitives
// ============================================================================

wait_steps :: proc(f: ^Fiber, steps: int = 1) {
    if f == nil || f.sched == nil do return

    cid := int(clamp_clock_id(f.clock_id))
    c := &f.sched.clocks[cid]
    target_steps := max(steps, 1)
    f.wake_step = c.steps + u64(target_steps)
    f.status = .Sleeping_Steps
    f.step_index = len(c.step_waiters)
    append(&c.step_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

yield :: proc(f: ^Fiber) {
    wait_steps(f, 1)
}

yield_now :: proc(f: ^Fiber) {
    if f == nil || f.sched == nil do return
    f.status = .Ready
    append(&f.sched.ready_queue, f.handle)
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait :: proc(f: ^Fiber, seconds: f32) {
    if f == nil || f.sched == nil do return
    if seconds <= 0.0 {
        yield(f)
        return
    }

    cid := int(clamp_clock_id(f.clock_id))
    c := &f.sched.clocks[cid]
    f.wake_time = c.time + f64(seconds)
    f.status = .Sleeping_Time
    clock_heap_push(c, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

ticker_wait :: proc(f: ^Fiber, interval_seconds: f32) {
    if f == nil || f.sched == nil do return
    interval := max(0.0001, interval_seconds)
    cid := int(clamp_clock_id(f.clock_id))
    c := &f.sched.clocks[cid]
    now := c.time

    if f.ticker_interval != interval || f.ticker_next_wake <= 0.0 {
        f.ticker_interval = interval
        f.ticker_next_wake = now + f64(interval)
    } else {
        f.ticker_next_wake += f64(interval)
        // If system fell severely behind, clamp forward to prevent cascade burst
        if f.ticker_next_wake < now {
            f.ticker_next_wake = now + f64(interval)
        }
    }

    if f.ticker_next_wake > now {
        f.wake_time = f.ticker_next_wake
        f.status = .Sleeping_Time
        clock_heap_push(c, f)

        f.stored_context = context
        fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
        context = f.stored_context
    } else {
        yield(f)
    }
}

ticker_rebase :: proc(f: ^Fiber) {
    if f == nil do return
    f.ticker_next_wake = 0.0
}

// ============================================================================
// Lifecycle, Status, Scopes & Cleanup Hooks
// ============================================================================

fail :: proc(f: ^Fiber) {
    if f == nil || f.sched == nil do return
    f.status = .Failed
    for i := f.cleanup_count - 1; i >= 0; i -= 1 {
        hook := f.cleanups[i]
        if hook.proc_ptr != nil {
            hook.proc_ptr(hook.user_data != nil ? hook.user_data : f.user_data)
        }
    }
    f.cleanup_count = 0
    fiber_on_finish(f)
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

scope_wait :: proc(f: ^Fiber, scope: ^Fiber_Scope) {
    if f == nil || f.sched == nil || scope == nil do return
    for scope.head != nil {
        wait_queue_push_back(&scope.waiters, f)
        fiber_suspend(f)
    }
}

fiber_is_alive_sched :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> bool {
    if sched == nil || handle == 0 do return false
    idx := int(fiber_handle_index(handle))
    if idx < len(sched.fiber_pool.all_fibers) {
        f := sched.fiber_pool.all_fibers[idx]
        if f.handle == handle && f.status != .Unused {
            return f.status != .Completed && f.status != .Aborted && f.status != .Failed
        }
    }
    return false
}

fiber_is_alive_fiber :: proc(f: ^Fiber, handle: Fiber_Handle) -> bool {
    if f == nil || f.sched == nil do return false
    return fiber_is_alive_sched(f.sched, handle)
}

fiber_is_alive :: proc{
    fiber_is_alive_sched,
    fiber_is_alive_fiber,
}

fiber_status_sched :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> (status: Fiber_Status, ok: bool) {
    if sched == nil || handle == 0 do return .Completed, false
    idx := int(fiber_handle_index(handle))
    if idx < len(sched.fiber_pool.all_fibers) {
        f := sched.fiber_pool.all_fibers[idx]
        if f.handle == handle && f.status != .Unused {
            return f.status, true
        }
    }
    entry := sched.fiber_pool.handle_history[fiber_handle_history_slot(handle)]
    if entry.handle == handle {
        return entry.status, true
    }
    return .Completed, false
}

fiber_status_fiber :: proc(f: ^Fiber, handle: Fiber_Handle) -> (status: Fiber_Status, ok: bool) {
    if f == nil || f.sched == nil do return .Completed, false
    return fiber_status_sched(f.sched, handle)
}

fiber_status :: proc{
    fiber_status_sched,
    fiber_status_fiber,
}

fiber_join :: proc(f: ^Fiber, target_handle: Fiber_Handle) -> (ok: bool) {
    if f == nil || f.sched == nil || target_handle == 0 || target_handle == f.handle do return false

    for {
        target := fiber_find_by_handle(f.sched, target_handle)
        if target == nil || target.status == .Completed || target.status == .Failed || target.status == .Aborted || target.status == .Unused {
            break
        }
        wait_queue_push_back(&target.join_waiters, f)
        fiber_suspend(f)
    }

    status, found := fiber_status(f.sched, target_handle)
    return found && status == .Completed
}

fiber_set_name :: #force_inline proc(f: ^Fiber, name: string) {
    if f != nil {
        f.debug_name = name
    }
}

fiber_name :: #force_inline proc "contextless" (f: ^Fiber) -> string {
    return f != nil ? f.debug_name : ""
}

fiber_defer_raw :: proc(f: ^Fiber, cleanup_proc: proc(user_data: rawptr), user_data: rawptr = nil) {
    if f == nil || cleanup_proc == nil do return
    if f.cleanup_count < MAX_FIBER_CLEANUPS {
        f.cleanups[f.cleanup_count] = Fiber_Cleanup{
            proc_ptr  = cleanup_proc,
            user_data = user_data,
        }
        f.cleanup_count += 1
    } else {
        panic("fiber_defer: exceeded MAX_FIBER_CLEANUPS (8)")
    }
}

fiber_defer_ptr :: proc(f: ^Fiber, cleanup_proc: proc(user_data: ^$T), user_data: ^T) {
    fiber_defer_raw(f, cast(proc(rawptr))cleanup_proc, rawptr(user_data))
}

fiber_defer :: proc{
    fiber_defer_raw,
    fiber_defer_ptr,
}

fiber_defer_cancel :: proc(f: ^Fiber) {
    if f != nil && f.cleanup_count > 0 {
        f.cleanup_count -= 1
        f.cleanups[f.cleanup_count] = {}
    }
}

fiber_defer_run_top :: proc(f: ^Fiber) {
    if f != nil && f.cleanup_count > 0 {
        f.cleanup_count -= 1
        hook := f.cleanups[f.cleanup_count]
        f.cleanups[f.cleanup_count] = {}
        if hook.proc_ptr != nil {
            hook.proc_ptr(hook.user_data != nil ? hook.user_data : f.user_data)
        }
    }
}

scheduler_set_watchdog :: proc(sched: ^Scheduler, enabled: bool, max_slice_ms: f64 = 100.0) {
    if sched == nil do return
    sched.watchdog_enabled = enabled
    sched.watchdog_max_slice_ms = max_slice_ms
}

// ============================================================================
// Structured Concurrency Combinators (sync, race, rush, fallback, with_timeout)
// ============================================================================

branch_ptr :: proc(
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Branch_Desc {
    return Branch_Desc{
        entry_proc  = cast(proc(f: ^Fiber, user_data: rawptr))entry,
        user_data   = rawptr(data),
        user_fn     = rawptr(entry),
        has_payload = false,
        name        = name,
        clock_id    = clock,
    }
}

branch_val :: proc(
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Branch_Desc where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "branch_val: payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")

    wrapper :: proc(f: ^Fiber, user_data: rawptr) {
        fn := cast(proc(f: ^Fiber, data: T))f.user_fn
        if fn != nil && user_data != nil {
            val := (^T)(user_data)^
            fn(f, val)
        }
    }

    desc := Branch_Desc{
        entry_proc  = wrapper,
        user_fn     = rawptr(entry),
        has_payload = true,
        name        = name,
        clock_id    = clock,
    }
    data_copy := data
    mem.copy(&desc.payload_storage[0], &data_copy, size_of(T))
    return desc
}

branch_nil :: proc(entry: proc(f: ^Fiber), name: string = "", clock: Clock_ID = CLOCK_INHERIT) -> Branch_Desc {
    wrapper :: proc(f: ^Fiber, user_data: rawptr) {
        real_entry := cast(proc(f: ^Fiber))user_data
        if real_entry != nil {
            real_entry(f)
        }
    }
    return Branch_Desc{
        entry_proc  = wrapper,
        user_data   = rawptr(entry),
        user_fn     = rawptr(entry),
        has_payload = false,
        name        = name,
        clock_id    = clock,
    }
}

branch :: proc{branch_ptr, branch_val, branch_nil}

branch_signal :: proc(sig: ^Signal, name := "signal_wait") -> Branch_Desc {
    return branch_ptr(signal_wait, sig, name)
}

branch_sticky_signal :: proc(sig: ^Sticky_Signal, name := "sticky_signal_wait") -> Branch_Desc {
    return branch_ptr(sticky_signal_wait, sig, name)
}

branch_wait :: proc(seconds: f32, name := "timer_wait", clock: Clock_ID = CLOCK_INHERIT) -> Branch_Desc {
    return branch_val(wait, seconds, name, clock)
}

// ============================================================================
// Scoped Fire-and-Forget Subtasks (Verse branch:)
// ============================================================================

branch_scoped_desc :: proc(f: ^Fiber, b: Branch_Desc) -> Fiber_Handle {
    if f == nil || f.sched == nil do return 0

    child_clock := b.clock_id == CLOCK_INHERIT ? f.clock_id : b.clock_id
    cid := clamp_clock_id(child_clock)

    child := fiber_pool_acquire(&f.sched.fiber_pool)
    child.sched = f.sched
    child.clock_id = cid
    child.debug_name = b.name
    child.start_time = f.sched.clocks[int(cid)].time
    if b.has_payload {
        child.payload_storage = b.payload_storage
        child.user_data = &child.payload_storage[0]
    } else {
        child.user_data = b.user_data
    }
    child.user_fn = b.user_fn
    child.entry_proc = b.entry_proc
    child.join_coord = nil
    child.branch_index = -1

    fiber_link_child(f, child)
    append(&f.sched.ready_queue, child.handle)
    return child.handle
}

branch_scoped_ptr :: proc(
    f: ^Fiber,
    entry: proc(child: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle {
    return branch_scoped_desc(f, branch_ptr(entry, data, name, clock))
}

branch_scoped_val :: proc(
    f: ^Fiber,
    entry: proc(child: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle where !intrinsics.type_is_pointer(T) {
    return branch_scoped_desc(f, branch_val(entry, data, name, clock))
}

branch_scoped_nil :: proc(
    f: ^Fiber,
    entry: proc(child: ^Fiber),
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle {
    return branch_scoped_desc(f, branch_nil(entry, name, clock))
}

branch_scoped :: proc{
    branch_scoped_desc,
    branch_scoped_ptr,
    branch_scoped_val,
    branch_scoped_nil,
}

fiber_begin_join :: proc(f: ^Fiber, kind: Join_Kind, branch_count: int) {
    f.sched.next_coord_id += 1
    coord_id := f.sched.next_coord_id

    f.active_coord = Join_Coordinator{
        id              = coord_id,
        kind            = kind,
        parent          = f,
        total_branches  = branch_count,
        active_branches = branch_count,
        winner          = nil,
        winner_index    = -1,
        has_failed      = false,
        completed       = false,
    }
}

fiber_spawn_join_child :: proc(f: ^Fiber, index: int, b: ^Branch_Desc) {
    child_clock := b.clock_id == CLOCK_INHERIT ? f.clock_id : b.clock_id
    cid := clamp_clock_id(child_clock)

    child := fiber_pool_acquire(&f.sched.fiber_pool)
    child.sched = f.sched
    child.clock_id = cid
    child.debug_name = b.name
    child.start_time = f.sched.clocks[int(cid)].time
    if b.has_payload {
        child.payload_storage = b.payload_storage
        child.user_data = &child.payload_storage[0]
    } else {
        child.user_data = b.user_data
    }
    child.user_fn = b.user_fn
    child.entry_proc = b.entry_proc
    child.join_coord = &f.active_coord
    child.join_coord_id = f.active_coord.id
    child.branch_index = index

    fiber_link_child(f, child)
    append(&f.sched.ready_queue, child.handle)
}

fiber_wait_join :: proc(f: ^Fiber) {
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

@(private="file")
fiber_setup_branches :: proc(f: ^Fiber, kind: Join_Kind, branches: []Branch_Desc) {
    fiber_begin_join(f, kind, len(branches))
    for &b, i in branches {
        fiber_spawn_join_child(f, i, &b)
    }
    fiber_wait_join(f)
}

sync_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(branches) == 0 do return true
    fiber_setup_branches(f, .Sync, branches)
    return !f.active_coord.has_failed
}

sync_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(procs) == 0 do return true
    fiber_begin_join(f, .Sync, len(procs))
    for p, i in procs {
        desc := branch_nil(p)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return !f.active_coord.has_failed
}

sync :: proc{
    sync_branches,
    sync_procs,
}

sync_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(procs) == 0 do return true
    fiber_begin_join(f, .Sync, len(procs))
    for p, i in procs {
        desc := branch_ptr(p, ctx)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return !f.active_coord.has_failed
}

race_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1
    fiber_setup_branches(f, .Race, branches)
    return f.active_coord.winner_index
}

race_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    fiber_begin_join(f, .Race, len(procs))
    for p, i in procs {
        desc := branch_nil(p)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return f.active_coord.winner_index
}

race :: proc{
    race_branches,
    race_procs,
}

race_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    fiber_begin_join(f, .Race, len(procs))
    for p, i in procs {
        desc := branch_ptr(p, ctx)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return f.active_coord.winner_index
}

rush_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1
    fiber_setup_branches(f, .Rush, branches)
    return f.active_coord.winner_index
}

rush_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    fiber_begin_join(f, .Rush, len(procs))
    for p, i in procs {
        desc := branch_nil(p)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return f.active_coord.winner_index
}

rush :: proc{
    rush_branches,
    rush_procs,
}

rush_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    fiber_begin_join(f, .Rush, len(procs))
    for p, i in procs {
        desc := branch_ptr(p, ctx)
        fiber_spawn_join_child(f, i, &desc)
    }
    fiber_wait_join(f)
    return f.active_coord.winner_index
}

fallback_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (succeeded: bool, winning_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return false, -1

    for b, i in branches {
        ok := sync_branches(f, b)
        if ok {
            return true, i
        }
    }
    return false, -1
}

fallback_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (succeeded: bool, winning_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return false, -1

    for p, i in procs {
        ok := sync_procs(f, p)
        if ok {
            return true, i
        }
    }
    return false, -1
}

fallback :: proc{
    fallback_branches,
    fallback_procs,
}

fallback_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (succeeded: bool, winning_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return false, -1

    for p, i in procs {
        ok := sync_branches(f, branch_ptr(p, ctx))
        if ok {
            return true, i
        }
    }
    return false, -1
}

// ============================================================================
// with_timeout Helper (Supports Cross-Clock Timeouts via timeout_clock)
// ============================================================================

with_timeout_branch :: proc(
    f: ^Fiber,
    seconds: f32,
    task: Branch_Desc,
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Timeout_Outcome) {
    if f == nil || f.sched == nil do return .Failed

    t_desc := task
    w_desc := branch_wait(seconds, "with_timeout_timer", timeout_clock)
    fiber_begin_join(f, .Guard, 2)
    fiber_spawn_join_child(f, 0, &t_desc)
    fiber_spawn_join_child(f, 1, &w_desc)
    fiber_wait_join(f)

    if f.active_coord.winner_index == 1 {
        return .Timed_Out
    }
    if f.active_coord.winner_index == 0 && !f.active_coord.has_failed {
        return .Completed
    }
    return .Failed
}

with_timeout_ptr :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Timeout_Outcome) {
    return with_timeout_branch(f, seconds, branch_ptr(entry, data, name), timeout_clock)
}

with_timeout_val :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Timeout_Outcome) where !intrinsics.type_is_pointer(T) {
    return with_timeout_branch(f, seconds, branch_val(entry, data, name), timeout_clock)
}

with_timeout_nil :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber),
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Timeout_Outcome) {
    return with_timeout_branch(f, seconds, branch_nil(entry, name), timeout_clock)
}

with_timeout :: proc{with_timeout_branch, with_timeout_ptr, with_timeout_val, with_timeout_nil}

// ============================================================================
// with_signal & with_sticky_signal Combinators (Interruptible Tasks)
// ============================================================================

with_signal_branch :: proc(f: ^Fiber, sig: ^Signal, task: Branch_Desc) -> (outcome: Signal_Outcome) {
    if f == nil || f.sched == nil || sig == nil do return .Failed

    t_desc := task
    s_desc := branch_signal(sig, "with_signal_watcher")
    fiber_begin_join(f, .Guard, 2)
    fiber_spawn_join_child(f, 0, &t_desc)
    fiber_spawn_join_child(f, 1, &s_desc)
    fiber_wait_join(f)

    if f.active_coord.winner_index == 1 {
        return .Interrupted
    }
    if f.active_coord.winner_index == 0 && !f.active_coord.has_failed {
        return .Completed
    }
    return .Failed
}

with_signal_ptr :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) {
    return with_signal_branch(f, sig, branch_ptr(entry, data, name, clock))
}

with_signal_val :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) where !intrinsics.type_is_pointer(T) {
    return with_signal_branch(f, sig, branch_val(entry, data, name, clock))
}

with_signal_nil :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber),
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) {
    return with_signal_branch(f, sig, branch_nil(entry, name, clock))
}

with_signal :: proc{
    with_signal_branch,
    with_signal_ptr,
    with_signal_val,
    with_signal_nil,
}

with_sticky_signal_branch :: proc(f: ^Fiber, sig: ^Sticky_Signal, task: Branch_Desc) -> (outcome: Signal_Outcome) {
    if f == nil || f.sched == nil || sig == nil do return .Failed

    t_desc := task
    s_desc := branch_sticky_signal(sig, "with_sticky_signal_watcher")
    fiber_begin_join(f, .Guard, 2)
    fiber_spawn_join_child(f, 0, &t_desc)
    fiber_spawn_join_child(f, 1, &s_desc)
    fiber_wait_join(f)

    if f.active_coord.winner_index == 1 {
        return .Interrupted
    }
    if f.active_coord.winner_index == 0 && !f.active_coord.has_failed {
        return .Completed
    }
    return .Failed
}

with_sticky_signal_ptr :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) {
    return with_sticky_signal_branch(f, sig, branch_ptr(entry, data, name, clock))
}

with_sticky_signal_val :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) where !intrinsics.type_is_pointer(T) {
    return with_sticky_signal_branch(f, sig, branch_val(entry, data, name, clock))
}

with_sticky_signal_nil :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber),
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (outcome: Signal_Outcome) {
    return with_sticky_signal_branch(f, sig, branch_nil(entry, name, clock))
}

with_sticky_signal :: proc{
    with_sticky_signal_branch,
    with_sticky_signal_ptr,
    with_sticky_signal_val,
    with_sticky_signal_nil,
}

// ============================================================================
// Unified Event(T) & Signal (1-to-Many Zero-Allocation Broadcast)
// ============================================================================

event_init :: proc(ev: ^Event($T)) {
    if ev == nil do return
    ev^ = {}
}

event_destroy :: proc(ev: ^Event($T)) {
    if ev == nil do return
    wait_queue_destroy(&ev.waiters)
}

event_wait :: proc(f: ^Fiber, ev: ^Event($T)) -> (payload: T, ok: bool) {
    if f == nil || ev == nil || f.sched == nil do return {}, false

    if size_of(T) == 0 {
        wait_queue_push_back(&ev.waiters, f)
        fiber_suspend(f)
        return {}, true
    }

    arena_avail := len(f.temp_arena.data) - f.temp_arena.offset
    use_heap := arena_avail < size_of(T) + 64

    if use_heap {
        Event_Heap_Box :: struct {
            alloc: mem.Allocator,
            val:   T,
        }
        box := new(Event_Heap_Box, f.sched.allocator)
        box.alloc = f.sched.allocator
        fiber_defer(f, proc(raw: rawptr) {
            b := (^Event_Heap_Box)(raw)
            if b != nil do free(b, b.alloc)
        }, rawptr(box))

        f.event_dest = rawptr(&box.val)
        wait_queue_push_back(&ev.waiters, f)
        fiber_suspend(f)

        f.event_dest = nil
        payload = box.val
        fiber_defer_run_top(f)
        return payload, true
    }

    arena_tmp := mem.begin_arena_temp_memory(&f.temp_arena)
    defer mem.end_arena_temp_memory(arena_tmp)

    dst := new(T, mem.arena_allocator(&f.temp_arena))
    f.event_dest = rawptr(dst)
    wait_queue_push_back(&ev.waiters, f)
    fiber_suspend(f)

    f.event_dest = nil
    return dst^, true
}

event_emit_sched :: proc(sched: ^Scheduler, ev: ^Event($T), payload: T) {
    if sched == nil || ev == nil || wait_queue_is_empty(&ev.waiters) do return

    for {
        f, ok := wait_queue_pop_front(&ev.waiters)
        if !ok do break
        if f != nil && f.status == .Suspended_Join && fiber_is_alive(sched, f.handle) {
            if size_of(T) > 0 && f.event_dest != nil {
                (cast(^T)f.event_dest)^ = payload
                f.event_dest = nil
            }
            f.status = .Ready
            append(&sched.ready_queue, f.handle)
        }
    }
}

event_emit_fiber :: proc(f: ^Fiber, ev: ^Event($T), payload: T) {
    if f == nil || f.sched == nil do return
    event_emit_sched(f.sched, ev, payload)
}

signal_emit_sched :: proc(sched: ^Scheduler, sig: ^Signal) {
    event_emit_sched(sched, sig, struct{}{})
}

signal_emit_fiber :: proc(f: ^Fiber, sig: ^Signal) {
    if f == nil || f.sched == nil do return
    event_emit_sched(f.sched, sig, struct{}{})
}

event_emit :: proc{
    event_emit_sched,
    event_emit_fiber,
    signal_emit_sched,
    signal_emit_fiber,
}

event_waiter_count :: #force_inline proc "contextless" (ev: ^Event($T)) -> int {
    return ev != nil ? wait_queue_count(&ev.waiters) : 0
}

event_has_waiters :: #force_inline proc "contextless" (ev: ^Event($T)) -> bool {
    return ev != nil && !wait_queue_is_empty(&ev.waiters)
}

signal_init :: event_init
signal_destroy :: event_destroy
signal_waiter_count :: event_waiter_count
signal_has_waiters :: event_has_waiters
signal_emit :: proc{
    signal_emit_sched,
    signal_emit_fiber,
}

signal_wait :: proc(f: ^Fiber, sig: ^Signal) {
    _, _ = event_wait(f, sig)
}

// ============================================================================
// Sticky_Event(T) & Sticky_Signal (Latched State Broadcast Primitives)
// ============================================================================

sticky_event_init :: proc(ev: ^Sticky_Event($T)) {
    if ev == nil do return
    ev^ = {}
}

sticky_event_destroy :: proc(ev: ^Sticky_Event($T)) {
    if ev == nil do return
    wait_queue_destroy(&ev.waiters)
}

sticky_event_reset :: proc(ev: ^Sticky_Event($T)) {
    if ev == nil do return
    ev.has_value = false
    ev.value = {}
}

sticky_event_is_set :: proc "contextless" (ev: ^Sticky_Event($T)) -> bool {
    return ev != nil && ev.has_value
}

sticky_event_peek :: proc "contextless" (ev: ^Sticky_Event($T)) -> (val: T, ok: bool) {
    if ev != nil && ev.has_value {
        return ev.value, true
    }
    return {}, false
}

sticky_event_waiter_count :: #force_inline proc "contextless" (ev: ^Sticky_Event($T)) -> int {
    return ev != nil ? wait_queue_count(&ev.waiters) : 0
}

sticky_event_has_waiters :: #force_inline proc "contextless" (ev: ^Sticky_Event($T)) -> bool {
    return ev != nil && !wait_queue_is_empty(&ev.waiters)
}

sticky_event_wait :: proc(f: ^Fiber, ev: ^Sticky_Event($T)) -> (payload: T, ok: bool) {
    if f == nil || ev == nil || f.sched == nil do return {}, false

    for !ev.has_value {
        wait_queue_push_back(&ev.waiters, f)
        fiber_suspend(f)
    }

    return ev.value, true
}

sticky_event_emit_sched :: proc(sched: ^Scheduler, ev: ^Sticky_Event($T), payload: T) {
    if ev == nil do return

    ev.has_value = true
    ev.value = payload

    if sched == nil || wait_queue_is_empty(&ev.waiters) do return

    for {
        f, ok := wait_queue_pop_front(&ev.waiters)
        if !ok do break
        if f != nil && f.status == .Suspended_Join && fiber_is_alive(sched, f.handle) {
            f.status = .Ready
            append(&sched.ready_queue, f.handle)
        }
    }
}

sticky_event_emit_fiber :: proc(f: ^Fiber, ev: ^Sticky_Event($T), payload: T) {
    if f == nil || f.sched == nil do return
    sticky_event_emit_sched(f.sched, ev, payload)
}

sticky_signal_init         :: sticky_event_init
sticky_signal_destroy      :: sticky_event_destroy
sticky_signal_reset        :: sticky_event_reset
sticky_signal_is_set       :: sticky_event_is_set
sticky_signal_waiter_count :: sticky_event_waiter_count
sticky_signal_has_waiters  :: sticky_event_has_waiters

sticky_signal_wait :: proc(f: ^Fiber, sig: ^Sticky_Signal) {
    _, _ = sticky_event_wait(f, sig)
}

sticky_signal_emit_sched :: proc(sched: ^Scheduler, sig: ^Sticky_Signal) {
    sticky_event_emit_sched(sched, sig, struct{}{})
}

sticky_signal_emit_fiber :: proc(f: ^Fiber, sig: ^Sticky_Signal) {
    if f == nil || f.sched == nil do return
    sticky_event_emit_sched(f.sched, sig, struct{}{})
}

sticky_event_emit :: proc{
    sticky_event_emit_sched,
    sticky_event_emit_fiber,
}

sticky_signal_emit :: proc{
    sticky_signal_emit_sched,
    sticky_signal_emit_fiber,
}

sticky_emit :: proc{
    sticky_event_emit_sched,
    sticky_event_emit_fiber,
    sticky_signal_emit_sched,
    sticky_signal_emit_fiber,
}

sticky_wait :: proc{
    sticky_event_wait,
    sticky_signal_wait,
}

// ============================================================================
// Async Job Integration (await_async / Async_Token)
// ============================================================================

async_token_init :: proc(token: ^Async_Token) {
    if token == nil do return
    token.state = .Pending
}

async_token_complete :: proc(token: ^Async_Token, success := true) {
    if token == nil do return
    intrinsics.atomic_store(&token.state, success ? .Completed : .Failed)
}

await_async :: proc(f: ^Fiber, token: ^Async_Token) -> (success: bool) {
    if f == nil || token == nil || f.sched == nil do return false

    if intrinsics.atomic_load(&token.state) == .Pending {
        f.async_token = token
        f.async_index = len(f.sched.async_waiters)
        append(&f.sched.async_waiters, f)
        fiber_suspend(f)
    }

    return intrinsics.atomic_load(&token.state) == .Completed
}

// ============================================================================
// Verse-Style Task(T) Futures (Backed by Zero-Alloc Sticky_Event(T))
// ============================================================================

task_init :: proc(task: ^Task($T), handle: Fiber_Handle = 0) {
    if task == nil do return
    task^ = {}
    task.handle = handle
}

task_complete_sched :: proc(sched: ^Scheduler, task: ^Task($T), value: T) {
    if task == nil do return
    task.state = .Completed
    sticky_event_emit(sched, &task.result, value)
}

task_complete_fiber :: proc(f: ^Fiber, task: ^Task($T), value: T) {
    if task == nil || f == nil do return
    task.state = .Completed
    sticky_event_emit(f, &task.result, value)
}

task_complete :: proc{
    task_complete_sched,
    task_complete_fiber,
}

task_fail_sched :: proc(sched: ^Scheduler, task: ^Task($T)) {
    if task == nil || task.state != .Pending do return
    task.state = .Failed
    for {
        w, ok := wait_queue_pop_front(&task.result.waiters)
        if !ok do break
        if w != nil {
            fiber_wake(sched != nil ? sched : w.sched, w)
        }
    }
}

task_fail_fiber :: proc(f: ^Fiber, task: ^Task($T)) {
    if task == nil || f == nil do return
    task_fail_sched(f.sched, task)
}

task_fail :: proc{
    task_fail_sched,
    task_fail_fiber,
}

task_await :: proc(f: ^Fiber, task: ^Task($T)) -> (val: T, ok: bool) {
    if f == nil || task == nil || f.sched == nil do return {}, false

    for task.state == .Pending && !task.result.has_value {
        wait_queue_push_back(&task.result.waiters, f)
        fiber_suspend(f)
    }

    if task.state == .Failed {
        return {}, false
    }
    return task.result.value, true
}

task_is_ready :: proc(task: ^Task($T)) -> bool {
    return task != nil && (task.state != .Pending || task.result.has_value)
}

task_state :: proc "contextless" (task: ^Task($T)) -> Task_State {
    return task != nil ? task.state : .Failed
}

spawn_task_sched_nil :: proc(
    sched: ^Scheduler,
    task: ^Task($R),
    entry: proc(f: ^Fiber) -> R,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle {
    Task_Wrapper_Payload :: struct {
        task: ^Task(R),
        fn:   proc(f: ^Fiber) -> R,
    }
    task_init(task)
    h := spawn_val(sched, proc(f: ^Fiber, p: Task_Wrapper_Payload) {
        fiber_defer(f, proc(raw: rawptr) {
            tk := (^Task(R))(raw)
            task_fail_sched(nil, tk)
        }, rawptr(p.task))
        res := p.fn(f)
        fiber_defer_cancel(f)
        task_complete(f, p.task, res)
    }, Task_Wrapper_Payload{task = task, fn = entry}, scope, name, clock)
    task.handle = h
    return h
}

spawn_task_sched_ptr :: proc(
    sched: ^Scheduler,
    task: ^Task($R),
    entry: proc(f: ^Fiber, data: ^$D) -> R,
    data: ^D,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle {
    Task_Wrapper_Payload :: struct {
        task: ^Task(R),
        fn:   proc(f: ^Fiber, data: ^D) -> R,
        data: ^D,
    }
    task_init(task)
    h := spawn_val(sched, proc(f: ^Fiber, p: Task_Wrapper_Payload) {
        fiber_defer(f, proc(raw: rawptr) {
            tk := (^Task(R))(raw)
            task_fail_sched(nil, tk)
        }, rawptr(p.task))
        res := p.fn(f, p.data)
        fiber_defer_cancel(f)
        task_complete(f, p.task, res)
    }, Task_Wrapper_Payload{task = task, fn = entry, data = data}, scope, name, clock)
    task.handle = h
    return h
}

spawn_task_sched_val :: proc(
    sched: ^Scheduler,
    task: ^Task($R),
    entry: proc(f: ^Fiber, data: $D) -> R,
    data: D,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_SIM,
) -> Fiber_Handle where !intrinsics.type_is_pointer(D) {
    Task_Wrapper_Payload :: struct {
        task: ^Task(R),
        fn:   proc(f: ^Fiber, data: D) -> R,
        data: D,
    }
    #assert(size_of(Task_Wrapper_Payload) <= FIBER_PAYLOAD_SIZE, "spawn_task_sched_val: payload exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    task_init(task)
    h := spawn_val(sched, proc(f: ^Fiber, p: Task_Wrapper_Payload) {
        fiber_defer(f, proc(raw: rawptr) {
            tk := (^Task(R))(raw)
            task_fail_sched(nil, tk)
        }, rawptr(p.task))
        res := p.fn(f, p.data)
        fiber_defer_cancel(f)
        task_complete(f, p.task, res)
    }, Task_Wrapper_Payload{task = task, fn = entry, data = data}, scope, name, clock)
    task.handle = h
    return h
}

spawn_task_fiber_nil :: proc(
    f: ^Fiber,
    task: ^Task($R),
    entry: proc(child: ^Fiber) -> R,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle {
    if f == nil || f.sched == nil do return 0
    c := clock == CLOCK_INHERIT ? f.clock_id : clock
    return spawn_task_sched_nil(f.sched, task, entry, scope, name, c)
}

spawn_task_fiber_ptr :: proc(
    f: ^Fiber,
    task: ^Task($R),
    entry: proc(child: ^Fiber, data: ^$D) -> R,
    data: ^D,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle {
    if f == nil || f.sched == nil do return 0
    c := clock == CLOCK_INHERIT ? f.clock_id : clock
    return spawn_task_sched_ptr(f.sched, task, entry, data, scope, name, c)
}

spawn_task_fiber_val :: proc(
    f: ^Fiber,
    task: ^Task($R),
    entry: proc(child: ^Fiber, data: $D) -> R,
    data: D,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> Fiber_Handle where !intrinsics.type_is_pointer(D) {
    if f == nil || f.sched == nil do return 0
    c := clock == CLOCK_INHERIT ? f.clock_id : clock
    return spawn_task_sched_val(f.sched, task, entry, data, scope, name, c)
}

spawn_task :: proc{
    spawn_task_sched_nil,
    spawn_task_sched_ptr,
    spawn_task_sched_val,
    spawn_task_fiber_nil,
    spawn_task_fiber_ptr,
    spawn_task_fiber_val,
}

