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

// Spawn with typed pointer (Zero allocations)
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
    fiber.stored_context = context
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

// Spawn with value / struct copy (Zero heap allocation; copied into 128-byte payload_storage)
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
    fiber.stored_context = context
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

// Spawn with no user data
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
    fiber.stored_context = context
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

// Unified overloaded entry point
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

current_frame :: current_steps

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
    append(&c.step_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_frames :: wait_steps

yield :: proc(f: ^Fiber) {
    wait_steps(f, 1)
}

yield_frame :: yield

// Cooperative timeslice yield within current tick/frame (Verse Sleep(0.0))
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

// Built-in fiber-owned zero-drift ticker wait.
// Stores interval and next wake timestamp directly on the Fiber struct in persistent memory.
// 100% immune to WebAssembly Asyncify shadow-stack corruption across interleaved yields.
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

// Reset/rebase the fiber-owned ticker to cleanly start next interval from now + interval
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
    fiber_on_finish(f)
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

scope_wait :: proc(f: ^Fiber, scope: ^Fiber_Scope) {
    if f == nil || f.sched == nil || scope == nil do return
    for scope.head != nil {
        yield(f)
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
    // 1. O(1) Check active fiber slot
    idx := int(fiber_handle_index(handle))
    if idx < len(sched.fiber_pool.all_fibers) {
        f := sched.fiber_pool.all_fibers[idx]
        if f.handle == handle && f.status != .Unused {
            return f.status, true
        }
    }
    // 2. Check historical record
    entry := sched.fiber_pool.handle_history[u32(handle) % FIBER_HANDLE_HISTORY_CAPACITY]
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

    for fiber_is_alive(f.sched, target_handle) {
        yield(f)
    }

    status, found := fiber_status(f.sched, target_handle)
    return found ? (status == .Completed) : true
}

fiber_set_name :: #force_inline proc(f: ^Fiber, name: string) {
    if f != nil {
        f.debug_name = name
    }
}

fiber_name :: #force_inline proc "contextless" (f: ^Fiber) -> string {
    return f != nil ? f.debug_name : ""
}

// Register a cleanup procedure executed in LIFO order when this fiber finishes, fails, or is cancelled.
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

// Pop the most recently registered cleanup hook (used by scoped RAII guards on normal exit)
fiber_cleanup_pop :: proc(f: ^Fiber) {
    if f != nil && f.cleanup_count > 0 {
        f.cleanup_count -= 1
        f.cleanups[f.cleanup_count] = {}
    }
}

// Aliases for backwards compatibility
fiber_set_cleanup_raw :: fiber_defer_raw
fiber_set_cleanup_ptr :: fiber_defer_ptr
fiber_set_cleanup     :: fiber_defer

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

// Unified overloaded entry point
branch :: proc{branch_ptr, branch_val, branch_nil}

// Built-in Branch_Desc factories for synchronization primitives
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
    child.stored_context = context
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

MAX_STACK_BRANCHES :: 16

@(private="file")
fiber_setup_branches :: proc(f: ^Fiber, kind: Join_Kind, branches: []Branch_Desc) {
    f.sched.next_coord_id += 1
    coord_id := f.sched.next_coord_id

    f.active_coord = Join_Coordinator{
        id              = coord_id,
        kind            = kind,
        parent          = f,
        total_branches  = len(branches),
        active_branches = len(branches),
        winner          = nil,
        winner_index    = -1,
        has_failed      = false,
        completed       = false,
    }

    for b, i in branches {
        child_clock := b.clock_id == CLOCK_INHERIT ? f.clock_id : b.clock_id
        cid := clamp_clock_id(child_clock)

        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.clock_id = cid
        child.debug_name = b.name
        child.stored_context = context
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
        child.join_coord_id = coord_id
        child.branch_index = i

        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child.handle)
    }

    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

sync_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(branches) == 0 do return true
    fiber_setup_branches(f, .Sync, branches)
    return !f.active_coord.has_failed
}

sync_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(procs) == 0 do return true
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_nil(p)
        }
        return sync_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_nil(p)
    }
    return sync_branches(f, ..descs)
}

sync :: proc{
    sync_branches,
    sync_procs,
}

sync_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(procs) == 0 do return true
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_ptr(p, ctx)
        }
        return sync_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_ptr(p, ctx)
    }
    return sync_branches(f, ..descs)
}

race_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1
    fiber_setup_branches(f, .Race, branches)
    return f.active_coord.winner_index
}

race_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_nil(p)
        }
        return race_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_nil(p)
    }
    return race_branches(f, ..descs)
}

race :: proc{
    race_branches,
    race_procs,
}

race_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_ptr(p, ctx)
        }
        return race_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_ptr(p, ctx)
    }
    return race_branches(f, ..descs)
}

rush_branches :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1
    fiber_setup_branches(f, .Rush, branches)
    return f.active_coord.winner_index
}

rush_procs :: proc(f: ^Fiber, procs: ..proc(f: ^Fiber)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_nil(p)
        }
        return rush_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_nil(p)
    }
    return rush_branches(f, ..descs)
}

rush :: proc{
    rush_branches,
    rush_procs,
}

rush_with :: proc(f: ^Fiber, ctx: ^$T, procs: ..proc(f: ^Fiber, ctx: ^T)) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(procs) == 0 do return -1
    if len(procs) <= MAX_STACK_BRANCHES {
        stack_descs: [MAX_STACK_BRANCHES]Branch_Desc
        for p, i in procs {
            stack_descs[i] = branch_ptr(p, ctx)
        }
        return rush_branches(f, ..stack_descs[:len(procs)])
    }
    descs := make([]Branch_Desc, len(procs), context.temp_allocator)
    for p, i in procs {
        descs[i] = branch_ptr(p, ctx)
    }
    return rush_branches(f, ..descs)
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
) -> (timed_out: bool) {
    if f == nil || f.sched == nil do return false

    winner := race(f,
        task,
        branch(proc(f: ^Fiber, sec: f32) {
            wait(f, sec)
        }, seconds, "with_timeout_timer", timeout_clock),
    )

    return winner == 1
}

with_timeout_ptr :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (timed_out: bool) {
    return with_timeout_branch(f, seconds, branch_ptr(entry, data, name), timeout_clock)
}

with_timeout_val :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (timed_out: bool) where !intrinsics.type_is_pointer(T) {
    return with_timeout_branch(f, seconds, branch_val(entry, data, name), timeout_clock)
}

with_timeout_nil :: proc(
    f: ^Fiber,
    seconds: f32,
    entry: proc(f: ^Fiber),
    name: string = "",
    timeout_clock: Clock_ID = CLOCK_INHERIT,
) -> (timed_out: bool) {
    return with_timeout_branch(f, seconds, branch_nil(entry, name), timeout_clock)
}

with_timeout :: proc{with_timeout_branch, with_timeout_ptr, with_timeout_val, with_timeout_nil}

// ============================================================================
// with_signal & with_sticky_signal Combinators (Interruptible Tasks)
// ============================================================================

with_signal_branch :: proc(f: ^Fiber, sig: ^Signal, task: Branch_Desc) -> (interrupted: bool) {
    if f == nil || f.sched == nil || sig == nil do return false
    winner := race(f, task, branch_signal(sig, "with_signal_watcher"))
    return winner == 1
}

with_signal_ptr :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) {
    return with_signal_branch(f, sig, branch_ptr(entry, data, name, clock))
}

with_signal_val :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) where !intrinsics.type_is_pointer(T) {
    return with_signal_branch(f, sig, branch_val(entry, data, name, clock))
}

with_signal_nil :: proc(
    f: ^Fiber,
    sig: ^Signal,
    entry: proc(f: ^Fiber),
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) {
    return with_signal_branch(f, sig, branch_nil(entry, name, clock))
}

with_signal :: proc{
    with_signal_branch,
    with_signal_ptr,
    with_signal_val,
    with_signal_nil,
}

with_sticky_signal_branch :: proc(f: ^Fiber, sig: ^Sticky_Signal, task: Branch_Desc) -> (interrupted: bool) {
    if f == nil || f.sched == nil || sig == nil do return false
    winner := race(f, task, branch_sticky_signal(sig, "with_sticky_signal_watcher"))
    return winner == 1
}

with_sticky_signal_ptr :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) {
    return with_sticky_signal_branch(f, sig, branch_ptr(entry, data, name, clock))
}

with_sticky_signal_val :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) where !intrinsics.type_is_pointer(T) {
    return with_sticky_signal_branch(f, sig, branch_val(entry, data, name, clock))
}

with_sticky_signal_nil :: proc(
    f: ^Fiber,
    sig: ^Sticky_Signal,
    entry: proc(f: ^Fiber),
    name: string = "",
    clock: Clock_ID = CLOCK_INHERIT,
) -> (interrupted: bool) {
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
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if ev == nil do return
    ev^ = {}
}

event_destroy :: proc(ev: ^Event($T)) {
    if ev == nil do return
    wait_queue_destroy(&ev.waiters)
}

event_wait :: proc(f: ^Fiber, ev: ^Event($T)) -> (payload: T, ok: bool) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || ev == nil || f.sched == nil do return {}, false

    wait_queue_push_back(&ev.waiters, f)
    fiber_suspend(f)

    if size_of(T) > 0 {
        payload = (cast(^T)&f.payload_storage[0])^
    }
    return payload, true
}

event_emit_sched :: proc(sched: ^Scheduler, ev: ^Event($T), payload: T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if sched == nil || ev == nil || wait_queue_is_empty(&ev.waiters) do return

    for {
        f, ok := wait_queue_pop_front(&ev.waiters)
        if !ok do break
        if f != nil && f.status == .Suspended_Join && fiber_is_alive(sched, f.handle) {
            if size_of(T) > 0 {
                (cast(^T)&f.payload_storage[0])^ = payload
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

// Signal Aliases (0-byte Event)
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
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Sticky_Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
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
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Sticky_Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || ev == nil || f.sched == nil do return {}, false

    if ev.has_value {
        return ev.value, true
    }

    wait_queue_push_back(&ev.waiters, f)
    fiber_suspend(f)

    if size_of(T) > 0 {
        payload = (cast(^T)&f.payload_storage[0])^
    }
    return payload, true
}

sticky_event_emit_sched :: proc(sched: ^Scheduler, ev: ^Sticky_Event($T), payload: T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "Sticky_Event(T): payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if ev == nil do return

    ev.has_value = true
    ev.value = payload

    if sched == nil || wait_queue_is_empty(&ev.waiters) do return

    for {
        f, ok := wait_queue_pop_front(&ev.waiters)
        if !ok do break
        if f != nil && f.status == .Suspended_Join && fiber_is_alive(sched, f.handle) {
            if size_of(T) > 0 {
                (cast(^T)&f.payload_storage[0])^ = payload
            }
            f.status = .Ready
            append(&sched.ready_queue, f.handle)
        }
    }
}

sticky_event_emit_fiber :: proc(f: ^Fiber, ev: ^Sticky_Event($T), payload: T) {
    if f == nil || f.sched == nil do return
    sticky_event_emit_sched(f.sched, ev, payload)
}

// Sticky_Signal Aliases (0-byte Sticky_Event)
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

    for intrinsics.atomic_load(&token.state) == .Pending {
        yield(f)
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
    sticky_event_emit(sched, &task.result, value)
}

task_complete_fiber :: proc(f: ^Fiber, task: ^Task($T), value: T) {
    if task == nil || f == nil do return
    sticky_event_emit(f, &task.result, value)
}

task_complete :: proc{
    task_complete_sched,
    task_complete_fiber,
}

task_await :: proc(f: ^Fiber, task: ^Task($T)) -> (val: T, ok: bool) {
    if f == nil || task == nil do return {}, false
    return sticky_event_wait(f, &task.result)
}

task_is_ready :: proc(task: ^Task($T)) -> bool {
    return task != nil && task.result.has_value
}

// Spawn a worker fiber that computes a value and automatically completes the Task(R)
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
        res := p.fn(f)
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
        res := p.fn(f, p.data)
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
        res := p.fn(f, p.data)
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

