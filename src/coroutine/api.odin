package coroutine

import "base:runtime"
import "base:intrinsics"
import "core:math"
import "core:mem"

// ============================================================================
// Spawning Coroutines
// ============================================================================

spawn_ptr :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    tag: u32 = 0,
) -> Fiber_Handle {
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.debug_name = name
    fiber.user_tag = tag
    fiber.stored_context = context
    fiber.start_time = sched.clock.sim_time
    fiber.user_data = rawptr(data)
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = cast(proc(f: ^Fiber, user_data: rawptr))entry

    if scope != nil {
        fiber.scope = scope
        append(&scope.handles, fiber.handle)
    }

    append(&sched.ready_queue, fiber)
    return fiber.handle
}

spawn_val :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    tag: u32 = 0,
) -> Fiber_Handle where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "spawn_val: payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")

    wrapper :: proc(f: ^Fiber, user_data: rawptr) {
        fn := cast(proc(f: ^Fiber, data: T))f.user_fn
        if fn != nil && user_data != nil {
            val := (^T)(user_data)^
            fn(f, val)
        }
    }

    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.debug_name = name
    fiber.user_tag = tag
    fiber.stored_context = context
    fiber.start_time = sched.clock.sim_time

    data_copy := data
    mem.copy(&fiber.payload_storage[0], &data_copy, size_of(T))
    fiber.user_data = &fiber.payload_storage[0]
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = wrapper

    if scope != nil {
        fiber.scope = scope
        append(&scope.handles, fiber.handle)
    }

    append(&sched.ready_queue, fiber)
    return fiber.handle
}

spawn_nil :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber),
    scope: ^Fiber_Scope = nil,
    name: string = "",
    tag: u32 = 0,
) -> Fiber_Handle {
    wrapper := proc(f: ^Fiber, user_data: rawptr) {
        real_entry := cast(proc(f: ^Fiber))user_data
        if real_entry != nil {
            real_entry(f)
        }
    }

    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.debug_name = name
    fiber.user_tag = tag
    fiber.stored_context = context
    fiber.start_time = sched.clock.sim_time
    fiber.user_data = rawptr(entry)
    fiber.user_fn = rawptr(entry)
    fiber.entry_proc = wrapper

    if scope != nil {
        fiber.scope = scope
        append(&scope.handles, fiber.handle)
    }

    append(&sched.ready_queue, fiber)
    return fiber.handle
}

// Unified overloaded entry point
spawn :: proc{spawn_ptr, spawn_val, spawn_nil}

spawn_real_nil :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber),
    scope: ^Fiber_Scope = nil,
    name: string = "",
    tag: u32 = 0,
) -> Fiber_Handle {
    h := spawn_nil(sched, entry, scope, name, tag)
    if f := fiber_find_by_handle(sched, h); f != nil {
        f.wake_clock = .Real_Time
    }
    return h
}

spawn_real_ptr :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
    tag: u32 = 0,
) -> Fiber_Handle {
    h := spawn_ptr(sched, entry, data, scope, name, tag)
    if f := fiber_find_by_handle(sched, h); f != nil {
        f.wake_clock = .Real_Time
    }
    return h
}

spawn_real :: proc{spawn_real_ptr, spawn_real_nil}

// --- Category Tag Filtering & Mass Cancellation ---

scheduler_cancel_by_tag :: proc(sched: ^Scheduler, tag: u32) -> (cancelled_count: int) {
    if sched == nil || tag == 0 do return 0

    handles_to_cancel: [dynamic]Fiber_Handle
    defer delete(handles_to_cancel)

    for f in sched.fiber_pool.all_fibers {
        if f.status != .Unused && f.user_tag == tag && f.handle != 0 {
            append(&handles_to_cancel, f.handle)
        }
    }

    for h in handles_to_cancel {
        fiber_cancel(sched, h)
        cancelled_count += 1
    }
    return cancelled_count
}

scheduler_count_by_tag :: proc(sched: ^Scheduler, tag: u32) -> int {
    if sched == nil || tag == 0 do return 0
    count := 0
    for f in sched.fiber_pool.all_fibers {
        if f.status != .Unused && f.user_tag == tag {
            count += 1
        }
    }
    return count
}

// ============================================================================
// Suspension & Waiting Primitives
// ============================================================================

wait :: proc(f: ^Fiber, seconds: f32) {
    if f == nil || f.sched == nil do return
    if seconds <= 0.0 {
        yield_frame(f)
        return
    }

    f.wake_time = f.sched.clock.sim_time + f64(seconds)
    f.wake_clock = .Sim_Scaled
    f.status = .Sleeping_Time
    timer_heap_push(f.sched, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_real :: proc(f: ^Fiber, seconds: f32) {
    if f == nil || f.sched == nil do return
    if seconds <= 0.0 {
        yield_frame(f)
        return
    }

    f.wake_time = f.sched.clock.real_time + f64(seconds)
    f.wake_clock = .Real_Time
    f.status = .Sleeping_Real_Time
    real_timer_heap_push(f.sched, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_ticks :: proc(f: ^Fiber, ticks: u64) {
    if f == nil || f.sched == nil do return
    if ticks == 0 {
        yield_frame(f)
        return
    }

    f.wake_ticks = f.sched.clock.sim_ticks + ticks
    f.wake_clock = .Fixed_Tick
    f.status = .Sleeping_Ticks
    append(&f.sched.tick_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

fail :: proc(f: ^Fiber) {
    if f == nil || f.sched == nil do return
    f.status = .Failed
    fiber_on_finish(f)
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

delta_time :: #force_inline proc "contextless" (f: ^Fiber) -> f32 {
    return f != nil && f.sched != nil ? f.sched.clock.sim_delta : 0.0
}

delta_real :: #force_inline proc "contextless" (f: ^Fiber) -> f32 {
    return f != nil && f.sched != nil ? f.sched.clock.real_delta : 0.0
}

current_time :: #force_inline proc "contextless" (f: ^Fiber) -> f64 {
    return f != nil && f.sched != nil ? f.sched.clock.sim_time : 0.0
}

real_time :: #force_inline proc "contextless" (f: ^Fiber) -> f64 {
    return f != nil && f.sched != nil ? f.sched.clock.real_time : 0.0
}

current_ticks :: #force_inline proc "contextless" (f: ^Fiber) -> u64 {
    return f != nil && f.sched != nil ? f.sched.clock.sim_ticks : 0
}

current_frame :: #force_inline proc "contextless" (f: ^Fiber) -> u64 {
    return f != nil && f.sched != nil ? f.sched.clock.frame_count : 0
}

scope_wait :: proc(f: ^Fiber, scope: ^Fiber_Scope) {
    if f == nil || f.sched == nil || scope == nil do return
    wait_until(f, proc(s: ^Fiber_Scope) -> bool {
        return s == nil || len(s.handles) == 0
    }, scope)
}

fiber_is_alive :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> bool {
    if sched == nil || handle == 0 do return false
    for f in sched.fiber_pool.all_fibers {
        if f.handle == handle && f.status != .Unused {
            return f.status != .Completed && f.status != .Aborted && f.status != .Failed
        }
    }
    return false
}

fiber_status :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> (status: Fiber_Status, ok: bool) {
    if sched == nil || handle == 0 do return .Completed, false
    // 1. Check active fibers
    for f in sched.fiber_pool.all_fibers {
        if f.handle == handle && f.status != .Unused {
            return f.status, true
        }
    }
    // 2. Check historical record
    entry := sched.fiber_pool.handle_history[handle % 256]
    if entry.handle == handle {
        return entry.status, true
    }
    return .Completed, false
}

fiber_join :: proc(f: ^Fiber, target_handle: Fiber_Handle) -> (ok: bool) {
    if f == nil || f.sched == nil || target_handle == 0 do return false

    // If target is already dead/finished
    if !fiber_is_alive(f.sched, target_handle) {
        status, found := fiber_status(f.sched, target_handle)
        return found ? (status == .Completed) : true
    }

    Join_Data :: struct {
        sched:  ^Scheduler,
        handle: Fiber_Handle,
    }
    data := Join_Data{sched = f.sched, handle = target_handle}

    wait_until_val(f, proc(d: Join_Data) -> bool {
        return !fiber_is_alive(d.sched, d.handle)
    }, data)

    status, found := fiber_status(f.sched, target_handle)
    return found ? (status == .Completed) : true
}

wait_ptr :: proc(f: ^Fiber, seconds_ptr: ^f32) {
    if seconds_ptr == nil {
        yield_frame(f)
        return
    }
    wait(f, seconds_ptr^)
}

wait_frames :: proc(f: ^Fiber, frames: int) {
    if f == nil || f.sched == nil do return

    target_frames := max(frames, 1)
    f.wake_frame = f.sched.clock.frame_count + u64(target_frames)
    f.status = .Sleeping_Frames
    append(&f.sched.frame_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

yield_frame :: proc(f: ^Fiber) {
    wait_frames(f, 1)
}

fiber_set_cleanup :: proc(f: ^Fiber, cleanup_proc: proc(user_data: rawptr), user_data: rawptr = nil) {
    if f == nil do return
    f.cleanup_proc = cleanup_proc
    if user_data != nil {
        f.user_data = user_data
    }
}

scheduler_set_watchdog :: proc(sched: ^Scheduler, enabled: bool, max_slice_ms: f64 = 100.0) {
    if sched == nil do return
    sched.watchdog_enabled = enabled
    sched.watchdog_max_slice_ms = max_slice_ms
}

wait_until_ptr :: proc(f: ^Fiber, condition: proc(data: ^$T) -> bool, data: ^T) {
    if f == nil || f.sched == nil do return

    // If condition is already met, return immediately
    if condition != nil && condition(data) {
        return
    }

    f.condition_fn = cast(proc(user_data: rawptr) -> bool)condition
    f.condition_data = rawptr(data)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_until_val :: proc(f: ^Fiber, condition: proc(data: $T) -> bool, data: T) where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "wait_until_val: payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || f.sched == nil do return

    if condition != nil && condition(data) {
        return
    }

    wrapper :: proc(user_data: rawptr) -> bool {
        fiber := (^Fiber)(user_data)
        fn := cast(proc(data: T) -> bool)fiber.user_fn
        if fn == nil do return true
        val := (^T)(&fiber.payload_storage[0])^
        return fn(val)
    }

    data_copy := data
    mem.copy(&f.payload_storage[0], &data_copy, size_of(T))
    f.condition_fn = wrapper
    f.condition_data = rawptr(f)
    f.user_fn = rawptr(condition)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_until_nil :: proc(f: ^Fiber, condition: proc() -> bool) {
    if f == nil || f.sched == nil do return

    if condition != nil && condition() {
        return
    }

    wrapper := proc(user_data: rawptr) -> bool {
        cond := cast(proc() -> bool)user_data
        if cond == nil do return true
        return cond()
    }

    f.condition_fn = wrapper
    f.condition_data = rawptr(condition)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

// Unified overloaded entry point
wait_until :: proc{wait_until_ptr, wait_until_val, wait_until_nil}

wait_while_ptr :: proc(f: ^Fiber, condition: proc(data: ^$T) -> bool, data: ^T) {
    if f == nil || f.sched == nil do return
    if condition == nil || !condition(data) do return

    wrapper :: proc(user_data: rawptr) -> bool {
        fiber := (^Fiber)(user_data)
        fn := cast(proc(data: ^T) -> bool)fiber.user_fn
        if fn == nil do return true
        return !fn((^T)(fiber.user_data))
    }

    f.condition_fn = wrapper
    f.condition_data = rawptr(f)
    f.user_data = rawptr(data)
    f.user_fn = rawptr(condition)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_while_val :: proc(f: ^Fiber, condition: proc(data: $T) -> bool, data: T) where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= FIBER_PAYLOAD_SIZE, "wait_while_val: payload size exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || f.sched == nil do return
    if condition == nil || !condition(data) do return

    wrapper :: proc(user_data: rawptr) -> bool {
        fiber := (^Fiber)(user_data)
        fn := cast(proc(data: T) -> bool)fiber.user_fn
        if fn == nil do return true
        val := (^T)(&fiber.payload_storage[0])^
        return !fn(val)
    }

    data_copy := data
    mem.copy(&f.payload_storage[0], &data_copy, size_of(T))
    f.condition_fn = wrapper
    f.condition_data = rawptr(f)
    f.user_fn = rawptr(condition)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

wait_while_nil :: proc(f: ^Fiber, condition: proc() -> bool) {
    if f == nil || f.sched == nil do return
    if condition == nil || !condition() do return

    wrapper := proc(user_data: rawptr) -> bool {
        cond := cast(proc() -> bool)user_data
        if cond == nil do return true
        return !cond()
    }

    f.condition_fn = wrapper
    f.condition_data = rawptr(condition)
    f.status = .Waiting_Condition
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

// Unified overloaded entry point
wait_while :: proc{wait_while_ptr, wait_while_val, wait_while_nil}

// ============================================================================
// Structured Concurrency: Branch, Sync, and Race
// ============================================================================

branch_ptr :: proc(
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
    tag: u32 = 0,
) -> Branch_Desc {
    return Branch_Desc{
        entry_proc  = cast(proc(f: ^Fiber, user_data: rawptr))entry,
        user_data   = rawptr(data),
        user_fn     = rawptr(entry),
        has_payload = false,
        tag         = tag,
        name        = name,
    }
}

branch_val :: proc(
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
    tag: u32 = 0,
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
        tag         = tag,
        name        = name,
    }
    data_copy := data
    mem.copy(&desc.payload_storage[0], &data_copy, size_of(T))
    return desc
}

branch_nil :: proc(entry: proc(f: ^Fiber), name: string = "", tag: u32 = 0) -> Branch_Desc {
    wrapper := proc(f: ^Fiber, user_data: rawptr) {
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
        tag         = tag,
        name        = name,
    }
}

// Unified overloaded entry point
branch :: proc{branch_ptr, branch_val, branch_nil}

sync :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (all_succeeded: bool) {
    if f == nil || f.sched == nil || len(branches) == 0 do return true

    f.active_coord = Join_Coordinator{
        kind            = .Sync,
        parent          = f,
        total_branches  = len(branches),
        active_branches = len(branches),
        winner          = nil,
        winner_index    = -1,
        has_failed      = false,
        completed       = false,
    }

    for b, i in branches {
        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.debug_name = b.name
        child.user_tag = b.tag != 0 ? b.tag : f.user_tag
        child.stored_context = context
        child.start_time = f.sched.clock.sim_time
        if b.has_payload {
            child.payload_storage = b.payload_storage
            child.user_data = &child.payload_storage[0]
        } else {
            child.user_data = b.user_data
        }
        child.user_fn = b.user_fn
        child.entry_proc = b.entry_proc
        child.join_coord = &f.active_coord
        child.branch_index = i

        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child)
    }

    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context

    return !f.active_coord.has_failed
}

race :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1

    f.active_coord = Join_Coordinator{
        kind            = .Race,
        parent          = f,
        total_branches  = len(branches),
        active_branches = len(branches),
        winner          = nil,
        winner_index    = -1,
        has_failed      = false,
        completed       = false,
    }

    for b, i in branches {
        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.debug_name = b.name
        child.user_tag = b.tag != 0 ? b.tag : f.user_tag
        child.stored_context = context
        child.start_time = f.sched.clock.sim_time
        if b.has_payload {
            child.payload_storage = b.payload_storage
            child.user_data = &child.payload_storage[0]
        } else {
            child.user_data = b.user_data
        }
        child.user_fn = b.user_fn
        child.entry_proc = b.entry_proc
        child.join_coord = &f.active_coord
        child.branch_index = i

        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child)
    }

    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context

    return f.active_coord.winner_index
}

rush :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return -1

    f.active_coord = Join_Coordinator{
        kind            = .Rush,
        parent          = f,
        total_branches  = len(branches),
        active_branches = len(branches),
        winner          = nil,
        winner_index    = -1,
        has_failed      = false,
        completed       = false,
    }

    for b, i in branches {
        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.debug_name = b.name
        child.user_tag = b.tag != 0 ? b.tag : f.user_tag
        child.stored_context = context
        child.start_time = f.sched.clock.sim_time
        if b.has_payload {
            child.payload_storage = b.payload_storage
            child.user_data = &child.payload_storage[0]
        } else {
            child.user_data = b.user_data
        }
        child.user_fn = b.user_fn
        child.entry_proc = b.entry_proc
        child.join_coord = &f.active_coord
        child.branch_index = i

        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child)
    }

    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context

    return f.active_coord.winner_index
}

fallback :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (succeeded: bool, winning_index: int) {
    if f == nil || f.sched == nil || len(branches) == 0 do return false, -1

    for b, i in branches {
        ok := sync(f, b)
        if ok {
            return true, i
        }
    }
    return false, -1
}

// ============================================================================
// Tween Interpolator & Easing
// ============================================================================

Ease_Proc :: #type proc(t: f32) -> f32

ease_linear :: proc(t: f32) -> f32 {
    return t
}

ease_in_quad :: proc(t: f32) -> f32 {
    return t * t
}

ease_out_quad :: proc(t: f32) -> f32 {
    return t * (2.0 - t)
}

ease_in_out_quad :: proc(t: f32) -> f32 {
    if t < 0.5 {
        return 2.0 * t * t
    }
    return -1.0 + (4.0 - 2.0 * t) * t
}

ease_in_out_cubic :: proc(t: f32) -> f32 {
    if t < 0.5 {
        return 4.0 * t * t * t
    }
    f := (2.0 * t) - 2.0
    return 0.5 * f * f * f + 1.0
}

ease_out_bounce :: proc(t: f32) -> f32 {
    n1: f32 = 7.5625
    d1: f32 = 2.75
    x := t
    if x < 1.0 / d1 {
        return n1 * x * x
    } else if x < 2.0 / d1 {
        x -= 1.5 / d1
        return n1 * x * x + 0.75
    } else if x < 2.5 / d1 {
        x -= 2.25 / d1
        return n1 * x * x + 0.9375
    } else {
        x -= 2.625 / d1
        return n1 * x * x + 0.984375
    }
}

ease_out_back :: proc(t: f32) -> f32 {
    c1: f32 = 1.70158
    c3: f32 = c1 + 1.0
    x := t - 1.0
    return 1.0 + c3 * x * x * x + c1 * x * x
}

ease_out_elastic :: proc(t: f32) -> f32 {
    if t <= 0.0 do return 0.0
    if t >= 1.0 do return 1.0
    c4: f32 = (2.0 * math.PI) / 3.0
    return math.pow(2.0, -10.0 * t) * math.sin((t * 10.0 - 0.75) * c4) + 1.0
}

tween_f32 :: proc(
    f: ^Fiber,
    output: ^f32,
    start, target: f32,
    duration: f32,
    ease: Ease_Proc = nil,
) {
    if f == nil || output == nil do return
    if duration <= 0.0 {
        output^ = target
        return
    }

    ease_fn: Ease_Proc = ease_linear
    if ease != nil {
        ease_fn = ease
    }

    elapsed: f32 = 0.0
    output^ = start

    for elapsed < duration {
        yield_frame(f)
        elapsed += delta_time(f)
        t := math.clamp(elapsed / duration, 0.0, 1.0)
        eased_t := ease_fn(t)
        output^ = start + (target - start) * eased_t
    }

    output^ = target
}

tween_vec2 :: proc(
    f: ^Fiber,
    output: ^[2]f32,
    start, target: [2]f32,
    duration: f32,
    ease: Ease_Proc = nil,
) {
    if f == nil || output == nil do return
    if duration <= 0.0 {
        output^ = target
        return
    }

    ease_fn: Ease_Proc = ease_linear
    if ease != nil {
        ease_fn = ease
    }

    elapsed: f32 = 0.0
    output^ = start

    for elapsed < duration {
        yield_frame(f)
        elapsed += delta_time(f)
        t := math.clamp(elapsed / duration, 0.0, 1.0)
        eased_t := ease_fn(t)
        output.x = start.x + (target.x - start.x) * eased_t
        output.y = start.y + (target.y - start.y) * eased_t
    }

    output^ = target
}

tween_vec3 :: proc(
    f: ^Fiber,
    output: ^[3]f32,
    start, target: [3]f32,
    duration: f32,
    ease: Ease_Proc = nil,
) {
    if f == nil || output == nil do return
    if duration <= 0.0 {
        output^ = target
        return
    }

    ease_fn: Ease_Proc = ease_linear
    if ease != nil {
        ease_fn = ease
    }

    elapsed: f32 = 0.0
    output^ = start

    for elapsed < duration {
        yield_frame(f)
        elapsed += delta_time(f)
        t := math.clamp(elapsed / duration, 0.0, 1.0)
        eased_t := ease_fn(t)
        output.x = start.x + (target.x - start.x) * eased_t
        output.y = start.y + (target.y - start.y) * eased_t
        output.z = start.z + (target.z - start.z) * eased_t
    }

    output^ = target
}

tween_vec4 :: proc(
    f: ^Fiber,
    output: ^[4]f32,
    start, target: [4]f32,
    duration: f32,
    ease: Ease_Proc = nil,
) {
    if f == nil || output == nil do return
    if duration <= 0.0 {
        output^ = target
        return
    }

    ease_fn: Ease_Proc = ease_linear
    if ease != nil {
        ease_fn = ease
    }

    elapsed: f32 = 0.0
    output^ = start

    for elapsed < duration {
        yield_frame(f)
        elapsed += delta_time(f)
        t := math.clamp(elapsed / duration, 0.0, 1.0)
        eased_t := ease_fn(t)
        output.x = start.x + (target.x - start.x) * eased_t
        output.y = start.y + (target.y - start.y) * eased_t
        output.z = start.z + (target.z - start.z) * eased_t
        output.w = start.w + (target.w - start.w) * eased_t
    }

    output^ = target
}

// Unified overloaded entry point
tween :: proc{tween_f32, tween_vec2, tween_vec3, tween_vec4}

// ============================================================================
// with_timeout Helper
// ============================================================================

with_timeout_branch :: proc(f: ^Fiber, seconds: f32, task: Branch_Desc) -> (timed_out: bool) {
    if f == nil || f.sched == nil do return false

    Timeout_Data :: struct {
        seconds: f32,
    }

    tdata := Timeout_Data{seconds = seconds}

    winner := race(f,
        task,
        branch(proc(f: ^Fiber, d: ^Timeout_Data) {
            wait(f, d.seconds)
        }, &tdata, "with_timeout_timer"),
    )

    return winner == 1
}

with_timeout_ptr :: proc(f: ^Fiber, seconds: f32, entry: proc(f: ^Fiber, data: ^$T), data: ^T, name: string = "") -> (timed_out: bool) {
    return with_timeout_branch(f, seconds, branch_ptr(entry, data, name))
}

with_timeout_val :: proc(f: ^Fiber, seconds: f32, entry: proc(f: ^Fiber, data: $T), data: T, name: string = "") -> (timed_out: bool) where !intrinsics.type_is_pointer(T) {
    return with_timeout_branch(f, seconds, branch_val(entry, data, name))
}

with_timeout_nil :: proc(f: ^Fiber, seconds: f32, entry: proc(f: ^Fiber), name: string = "") -> (timed_out: bool) {
    return with_timeout_branch(f, seconds, branch_nil(entry, name))
}

// Unified overloaded entry point
with_timeout :: proc{with_timeout_branch, with_timeout_ptr, with_timeout_val, with_timeout_nil}

// ============================================================================
// Signal (Event Broadcast)
// ============================================================================

signal_init :: proc(sig: ^Signal, allocator := context.allocator) {
    sig.waiters = make([dynamic]^Fiber, allocator)
}

signal_destroy :: proc(sig: ^Signal) {
    delete(sig.waiters)
}

signal_wait :: proc(f: ^Fiber, sig: ^Signal) {
    if f == nil || sig == nil || f.sched == nil do return

    append(&sig.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

signal_emit :: proc(sched: ^Scheduler, sig: ^Signal) {
    if sched == nil || sig == nil do return

    for f in sig.waiters {
        if f.status == .Suspended_Join {
            f.status = .Ready
            append(&sched.ready_queue, f)
        }
    }
    clear(&sig.waiters)
}

// ============================================================================
// Fiber Mutex (Cooperative Resource Lock)
// ============================================================================

mutex_init :: proc(m: ^Fiber_Mutex, allocator := context.allocator) {
    m.locked = false
    m.waiters = make([dynamic]^Fiber, allocator)
}

mutex_destroy :: proc(m: ^Fiber_Mutex) {
    delete(m.waiters)
}

mutex_try_lock :: proc(f: ^Fiber, m: ^Fiber_Mutex) -> bool {
    if m == nil do return false
    if !m.locked {
        m.locked = true
        return true
    }
    return false
}

mutex_lock :: proc(f: ^Fiber, m: ^Fiber_Mutex) {
    if f == nil || m == nil || f.sched == nil do return

    if !m.locked {
        m.locked = true
        return
    }

    // Already locked: suspend this fiber until unlock
    append(&m.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

mutex_unlock :: proc(sched: ^Scheduler, m: ^Fiber_Mutex) {
    if sched == nil || m == nil do return

    for len(m.waiters) > 0 {
        next_fiber := pop_front(&m.waiters)
        if next_fiber.status == .Suspended_Join {
            next_fiber.status = .Ready
            append(&sched.ready_queue, next_fiber)
            return
        }
    }

    m.locked = false
}

// ============================================================================
// Event(T) (1-to-Many Typed Multicast Broadcast)
// ============================================================================

event_init :: proc(ev: ^Event($T), allocator := context.allocator) {
    ev.waiters = make([dynamic]^Fiber, allocator)
    ev.allocator = allocator
}

event_destroy :: proc(ev: ^Event($T)) {
    delete(ev.waiters)
}

event_wait :: proc(f: ^Fiber, ev: ^Event($T)) -> (payload: T, ok: bool) {
    if f == nil || ev == nil || f.sched == nil do return {}, false

    append(&ev.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context

    if size_of(T) <= FIBER_PAYLOAD_SIZE {
        payload = (cast(^T)&f.payload_storage[0])^
        return payload, true
    }
    return {}, true
}

event_emit :: proc(sched: ^Scheduler, ev: ^Event($T), payload: T) {
    if sched == nil || ev == nil do return

    for f in ev.waiters {
        if f.status == .Suspended_Join {
            if size_of(T) <= FIBER_PAYLOAD_SIZE {
                (cast(^T)&f.payload_storage[0])^ = payload
            }
            f.status = .Ready
            append(&sched.ready_queue, f)
        }
    }
    clear(&ev.waiters)
}

event_waiter_count :: #force_inline proc(ev: ^Event($T)) -> int {
    return ev != nil ? len(ev.waiters) : 0
}

event_has_waiters :: #force_inline proc(ev: ^Event($T)) -> bool {
    return ev != nil && len(ev.waiters) > 0
}

// ============================================================================
// Fiber Semaphore (Counting Semaphore with Up to N Concurrent Permits)
// ============================================================================

semaphore_init :: proc(sem: ^Fiber_Semaphore, initial_permits: int, max_permits: int = -1, allocator := context.allocator) {
    sem.permits = initial_permits
    sem.max_permits = max_permits > 0 ? max_permits : initial_permits
    sem.waiters = make([dynamic]^Fiber, allocator)
    sem.allocator = allocator
}

semaphore_destroy :: proc(sem: ^Fiber_Semaphore) {
    delete(sem.waiters)
}

semaphore_try_acquire :: proc(sem: ^Fiber_Semaphore) -> bool {
    if sem == nil do return false
    if sem.permits > 0 {
        sem.permits -= 1
        return true
    }
    return false
}

semaphore_acquire :: proc(f: ^Fiber, sem: ^Fiber_Semaphore) {
    if f == nil || sem == nil || f.sched == nil do return

    if sem.permits > 0 {
        sem.permits -= 1
        return
    }

    append(&sem.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

semaphore_release :: proc(sched: ^Scheduler, sem: ^Fiber_Semaphore, count: int = 1) {
    if sched == nil || sem == nil do return

    sem.permits = min(sem.permits + count, sem.max_permits)

    for sem.permits > 0 && len(sem.waiters) > 0 {
        next_fiber := pop_front(&sem.waiters)
        if next_fiber.status == .Suspended_Join {
            sem.permits -= 1
            next_fiber.status = .Ready
            append(&sched.ready_queue, next_fiber)
        }
    }
}

semaphore_available_permits :: #force_inline proc(sem: ^Fiber_Semaphore) -> int {
    return sem != nil ? sem.permits : 0
}

// ============================================================================
// Fiber Latch (Countdown Rendezvous Barrier)
// ============================================================================

latch_init :: proc(latch: ^Fiber_Latch, initial_count: int, allocator := context.allocator) {
    latch.count = initial_count
    latch.waiters = make([dynamic]^Fiber, allocator)
    latch.allocator = allocator
}

latch_destroy :: proc(latch: ^Fiber_Latch) {
    delete(latch.waiters)
}

latch_count_down :: proc(sched: ^Scheduler, latch: ^Fiber_Latch, n: int = 1) {
    if sched == nil || latch == nil do return

    latch.count = max(0, latch.count - n)
    if latch.count == 0 {
        for f in latch.waiters {
            if f.status == .Suspended_Join {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        }
        clear(&latch.waiters)
    }
}

latch_wait :: proc(f: ^Fiber, latch: ^Fiber_Latch) {
    if f == nil || latch == nil || f.sched == nil do return
    if latch.count <= 0 do return

    append(&latch.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

latch_get_count :: #force_inline proc(latch: ^Fiber_Latch) -> int {
    return latch != nil ? latch.count : 0
}

latch_is_ready :: #force_inline proc(latch: ^Fiber_Latch) -> bool {
    return latch != nil && latch.count <= 0
}

// ============================================================================
// Explicit Cancellation Token (Cancel_Token)
// ============================================================================

cancel_token_init :: proc(tok: ^Cancel_Token, allocator := context.allocator) {
    if tok == nil do return
    tok.is_cancelled = false
    tok.waiters = make([dynamic]^Fiber, allocator)
    tok.allocator = allocator
}

cancel_token_destroy :: proc(tok: ^Cancel_Token) {
    if tok == nil do return
    delete(tok.waiters)
}

cancel_token_is_cancelled :: #force_inline proc(tok: ^Cancel_Token) -> bool {
    return tok != nil && tok.is_cancelled
}

cancel_token_cancel :: proc(sched: ^Scheduler, tok: ^Cancel_Token) {
    if tok == nil || tok.is_cancelled do return
    tok.is_cancelled = true
    if sched != nil {
        for f in tok.waiters {
            if f.status == .Suspended_Join {
                f.status = .Ready
                append(&sched.ready_queue, f)
            }
        }
    }
    clear(&tok.waiters)
}

cancel_token_wait :: proc(f: ^Fiber, tok: ^Cancel_Token) {
    if f == nil || tok == nil || f.sched == nil do return
    if tok.is_cancelled do return

    append(&tok.waiters, f)
    f.status = .Suspended_Join
    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

// ============================================================================
// Async Job Integration (await_async / Async_Token)
// ============================================================================

async_token_init :: proc(token: ^Async_Token) {
    token.state = .Pending
    token.waiter_fiber = nil
}

async_token_complete :: proc(token: ^Async_Token, success := true) {
    intrinsics.atomic_store(&token.state, success ? .Completed : .Failed)
}

await_async :: proc(f: ^Fiber, token: ^Async_Token) -> (success: bool) {
    if f == nil || token == nil || f.sched == nil do return false

    if intrinsics.atomic_load(&token.state) != .Pending {
        return intrinsics.atomic_load(&token.state) == .Completed
    }

    token.waiter_fiber = f
    f.status = .Waiting_Condition
    f.condition_fn = proc(data: rawptr) -> bool {
        tok := (^Async_Token)(data)
        return intrinsics.atomic_load(&tok.state) != .Pending
    }
    f.condition_data = token
    append(&f.sched.condition_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context

    return intrinsics.atomic_load(&token.state) == .Completed
}

// ============================================================================
// CSP Typed Channels (Channel(T))
// ============================================================================

chan_init :: proc(ch: ^Channel($T), capacity: int = 0, allocator := context.allocator) {
    ch.capacity = max(0, capacity)
    buf_size := ch.capacity > 0 ? ch.capacity : 1
    ch.buffer = make([]T, buf_size, allocator)
    ch.head = 0
    ch.tail = 0
    ch.count = 0
    ch.send_waiters = make([dynamic]^Fiber, allocator)
    ch.recv_waiters = make([dynamic]^Fiber, allocator)
    ch.is_closed = false
    ch.allocator = allocator
}

chan_destroy :: proc(ch: ^Channel($T)) {
    if ch == nil do return
    if !ch.is_closed {
        chan_close(ch)
    }
    delete(ch.buffer, ch.allocator)
    delete(ch.send_waiters)
    delete(ch.recv_waiters)
    ch.head = 0
    ch.tail = 0
    ch.count = 0
    ch.capacity = 0
}

chan_count :: #force_inline proc "contextless" (ch: ^Channel($T)) -> int {
    return ch != nil ? ch.count : 0
}

chan_is_empty :: #force_inline proc "contextless" (ch: ^Channel($T)) -> bool {
    return ch == nil || ch.count == 0
}

chan_is_full :: #force_inline proc "contextless" (ch: ^Channel($T)) -> bool {
    return ch != nil && ch.capacity > 0 && ch.count >= ch.capacity
}

chan_close :: proc(ch: ^Channel($T)) {
    if ch == nil || ch.is_closed do return
    ch.is_closed = true

    for f in ch.recv_waiters {
        if f.status == .Suspended_Join {
            f.status = .Ready
            append(&f.sched.ready_queue, f)
        }
    }
    clear(&ch.recv_waiters)

    for f in ch.send_waiters {
        if f.status == .Suspended_Join {
            f.status = .Ready
            append(&f.sched.ready_queue, f)
        }
    }
    clear(&ch.send_waiters)
}

chan_try_send :: proc(ch: ^Channel($T), value: T) -> (ok: bool) {
    if ch == nil || ch.is_closed do return false

    if ch.capacity == 0 {
        if len(ch.recv_waiters) > 0 {
            ch.buffer[0] = value
            ch.count = 1
            receiver := pop_front(&ch.recv_waiters)
            if receiver.status == .Suspended_Join {
                receiver.status = .Ready
                append(&receiver.sched.ready_queue, receiver)
            }
            return true
        }
        return false
    }

    if ch.count >= ch.capacity {
        return false
    }

    ch.buffer[ch.tail] = value
    ch.tail = (ch.tail + 1) % len(ch.buffer)
    ch.count += 1

    if len(ch.recv_waiters) > 0 {
        receiver := pop_front(&ch.recv_waiters)
        if receiver.status == .Suspended_Join {
            receiver.status = .Ready
            append(&receiver.sched.ready_queue, receiver)
        }
    }
    return true
}

chan_try_recv :: proc(ch: ^Channel($T)) -> (value: T, ok: bool) {
    if ch == nil || ch.count == 0 do return {}, false

    val := ch.buffer[ch.head]
    ch.head = (ch.head + 1) % len(ch.buffer)
    ch.count -= 1

    if len(ch.send_waiters) > 0 {
        sender := pop_front(&ch.send_waiters)
        if sender.status == .Suspended_Join {
            sender.status = .Ready
            append(&sender.sched.ready_queue, sender)
        }
    }
    return val, true
}

chan_send :: proc(f: ^Fiber, ch: ^Channel($T), value: T) -> (ok: bool) {
    if f == nil || ch == nil || f.sched == nil do return false
    if ch.is_closed do return false

    for {
        if ch.is_closed do return false

        if ch.capacity == 0 {
            if len(ch.recv_waiters) > 0 {
                ch.buffer[0] = value
                ch.count = 1
                receiver := pop_front(&ch.recv_waiters)
                if receiver.status == .Suspended_Join {
                    receiver.status = .Ready
                    append(&receiver.sched.ready_queue, receiver)
                }
                return true
            }
        } else if ch.count < ch.capacity {
            ch.buffer[ch.tail] = value
            ch.tail = (ch.tail + 1) % len(ch.buffer)
            ch.count += 1

            if len(ch.recv_waiters) > 0 {
                receiver := pop_front(&ch.recv_waiters)
                if receiver.status == .Suspended_Join {
                    receiver.status = .Ready
                    append(&receiver.sched.ready_queue, receiver)
                }
            }
            return true
        }

        append(&ch.send_waiters, f)
        f.status = .Suspended_Join
        f.stored_context = context
        fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
        context = f.stored_context
    }
}

chan_recv :: proc(f: ^Fiber, ch: ^Channel($T)) -> (value: T, ok: bool) {
    if f == nil || ch == nil || f.sched == nil do return {}, false

    for {
        if ch.count > 0 {
            val := ch.buffer[ch.head]
            ch.head = (ch.head + 1) % len(ch.buffer)
            ch.count -= 1

            if len(ch.send_waiters) > 0 {
                sender := pop_front(&ch.send_waiters)
                if sender.status == .Suspended_Join {
                    sender.status = .Ready
                    append(&sender.sched.ready_queue, sender)
                }
            }
            return val, true
        }

        if ch.is_closed {
            return {}, false
        }

        append(&ch.recv_waiters, f)
        f.status = .Suspended_Join
        f.stored_context = context
        fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
        context = f.stored_context
    }
}

chan_recv_timeout :: proc(f: ^Fiber, ch: ^Channel($T), timeout_seconds: f32) -> (value: T, ok: bool, timed_out: bool) {
    if f == nil || ch == nil do return {}, false, false

    // Fast-path: if items are already available in buffer
    if ch.count > 0 || (ch.capacity == 0 && len(ch.send_waiters) > 0) {
        val, ok_recv := chan_recv(f, ch)
        return val, ok_recv, false
    }

    if ch.is_closed {
        return {}, false, false
    }

    if timeout_seconds <= 0.0 {
        val, ok_recv := chan_try_recv(ch)
        return val, ok_recv, !ok_recv
    }

    Recv_Result :: struct {
        val:       T,
        ok:        bool,
        timed_out: bool,
    }
    res := Recv_Result{}

    Chan_Recv_Pair :: struct {
        ch:              ^Channel(T),
        res:             ^Recv_Result,
        timeout_seconds: f32,
    }
    pair := Chan_Recv_Pair{ch = ch, res = &res, timeout_seconds = timeout_seconds}

    winner := race(f,
        branch(proc(f: ^Fiber, p: ^Chan_Recv_Pair) {
            v, ok_recv := chan_recv(f, p.ch)
            p.res.val = v
            p.res.ok = ok_recv
            p.res.timed_out = false
        }, &pair, name = "Chan Recv Branch"),

        branch(proc(f: ^Fiber, p: ^Chan_Recv_Pair) {
            wait(f, p.timeout_seconds)
            p.res.timed_out = true
            p.res.ok = false
        }, &pair, name = "Chan Timeout Branch"),
    )

    if winner == 1 {
        return {}, false, true
    }
    return res.val, res.ok, res.timed_out
}

// --- Multi-Channel Select (CSP Multiplexer) ---

chan_try_select_recv :: proc(channels: []^Channel($T)) -> (ready_index: int, value: T, ok: bool) {
    for ch, i in channels {
        if ch != nil {
            val, popped := chan_try_recv(ch)
            if popped {
                return i, val, true
            }
        }
    }
    return -1, {}, false
}

chan_select_recv :: proc(f: ^Fiber, channels: []^Channel($T)) -> (ready_index: int, value: T, ok: bool) {
    if f == nil || f.sched == nil || len(channels) == 0 do return -1, {}, false

    for {
        // 1. Check if any channel has a message or is closed
        for ch, i in channels {
            if ch != nil {
                val, popped := chan_try_recv(ch)
                if popped {
                    return i, val, true
                }
                if ch.is_closed {
                    return i, {}, false
                }
            }
        }

        // 2. Yield frame to wait for messages
        yield_frame(f)
    }
}

// ============================================================================
// Stateful Pull-Based Generators (Generator(T))
// ============================================================================

generator_init :: proc(
    gen: ^Generator($T),
    entry: proc(f: ^Fiber, g: ^Generator(T)),
    user_data: rawptr = nil,
    allocator := context.allocator,
) {
    // Allocate 1 single 16KB stack slab rather than 32x32KB (1MB)
    scheduler_init(&gen.sched, stack_size = 16 * 1024, stacks_per_slab = 1, allocator = allocator)
    gen.current_value = {}
    gen.has_value = false
    gen.is_done = false
    gen.entry = entry
    gen.user_data = user_data

    gen.handle = spawn(&gen.sched, proc(f: ^Fiber, g: ^Generator(T)) {
        g.entry(f, g)
        g.is_done = true
    }, gen)
}

generator_destroy :: proc(gen: ^Generator($T)) {
    scheduler_destroy(&gen.sched)
    gen.handle = 0
    gen.is_done = true
}

yield_value :: proc(f: ^Fiber, g: ^Generator($T), value: T) {
    if f == nil || g == nil do return
    g.current_value = value
    g.has_value = true
    f.status = .Suspended_Join // Suspended until consumer calls generator_next

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

generator_next :: proc(gen: ^Generator($T)) -> (val: T, ok: bool) {
    if gen == nil || gen.is_done do return {}, false

    gen.has_value = false

    // Resume generator fiber by pushing to ready queue
    for f in gen.sched.fiber_pool.all_fibers {
        if f.handle == gen.handle && (f.status == .Suspended_Join || f.status == .Ready) {
            f.status = .Ready
            append(&gen.sched.ready_queue, f)
            break
        }
    }

    scheduler_step(&gen.sched, 0.0)

    if gen.has_value {
        return gen.current_value, true
    }

    gen.is_done = true
    return {}, false
}

// ============================================================================
// Phase Director (State Machines on Top of Coroutines)
// ============================================================================

phase_director_init :: proc(director: ^Phase_Director, sched: ^Scheduler) {
    if director == nil do return
    director.sched = sched
    director.current_phase = 0
    director.phase_name = ""
    director.current_scope.handles = nil
}

phase_director_destroy :: proc(director: ^Phase_Director) {
    if director == nil || director.sched == nil do return
    scope_destroy(director.sched, &director.current_scope)
    director.current_phase = 0
    director.phase_name = ""
}

phase_switch_ptr :: proc(
    director: ^Phase_Director,
    phase_id: int,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
) -> Fiber_Handle {
    if director == nil || director.sched == nil do return 0
    scope_cancel(director.sched, &director.current_scope)
    director.current_phase = phase_id
    director.phase_name = name
    return spawn(director.sched, entry, data, scope = &director.current_scope, name = name)
}

phase_switch_val :: proc(
    director: ^Phase_Director,
    phase_id: int,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
) -> Fiber_Handle where !intrinsics.type_is_pointer(T) {
    if director == nil || director.sched == nil do return 0
    scope_cancel(director.sched, &director.current_scope)
    director.current_phase = phase_id
    director.phase_name = name
    return spawn(director.sched, entry, data, scope = &director.current_scope, name = name)
}

phase_switch_nil :: proc(
    director: ^Phase_Director,
    phase_id: int,
    entry: proc(f: ^Fiber),
    name: string = "",
) -> Fiber_Handle {
    if director == nil || director.sched == nil do return 0
    scope_cancel(director.sched, &director.current_scope)
    director.current_phase = phase_id
    director.phase_name = name
    return spawn(director.sched, entry, scope = &director.current_scope, name = name)
}

// Unified overloaded entry point
phase_switch :: proc{phase_switch_ptr, phase_switch_val, phase_switch_nil}

phase_current :: #force_inline proc "contextless" (director: ^Phase_Director) -> int {
    return director != nil ? director.current_phase : 0
}

phase_name :: #force_inline proc "contextless" (director: ^Phase_Director) -> string {
    return director != nil ? director.phase_name : ""
}

phase_is_busy :: #force_inline proc (director: ^Phase_Director) -> bool {
    return director != nil && scope_is_busy(&director.current_scope)
}

// ============================================================================
// Headless Simulation Runner (CI/CD Testing Harness)
// ============================================================================

simulate_until_ptr :: proc(
    sched: ^Scheduler,
    step_dt: f32,
    max_sim_seconds: f64,
    condition: proc(user_data: ^$T) -> bool,
    data: ^T,
) -> (condition_met: bool, elapsed_sim_time: f64) {
    if sched == nil do return false, 0.0
    dt := step_dt > 0.0 ? step_dt : 0.016
    start_time := sched.clock.sim_time

    for {
        if condition != nil && condition(data) {
            return true, sched.clock.sim_time - start_time
        }
        if sched.clock.sim_time - start_time >= max_sim_seconds {
            return false, sched.clock.sim_time - start_time
        }
        if len(sched.ready_queue) == 0 && len(sched.timer_heap) == 0 && len(sched.frame_waiters) == 0 && len(sched.condition_waiters) == 0 {
            return (condition != nil && condition(data)), sched.clock.sim_time - start_time
        }
        scheduler_step(sched, dt)
    }
}

simulate_until_nil :: proc(
    sched: ^Scheduler,
    step_dt: f32,
    max_sim_seconds: f64,
    condition: proc() -> bool,
) -> (condition_met: bool, elapsed_sim_time: f64) {
    if sched == nil do return false, 0.0
    dt := step_dt > 0.0 ? step_dt : 0.016
    start_time := sched.clock.sim_time

    for {
        if condition != nil && condition() {
            return true, sched.clock.sim_time - start_time
        }
        if sched.clock.sim_time - start_time >= max_sim_seconds {
            return false, sched.clock.sim_time - start_time
        }
        if len(sched.ready_queue) == 0 && len(sched.timer_heap) == 0 && len(sched.frame_waiters) == 0 && len(sched.condition_waiters) == 0 {
            return (condition != nil && condition()), sched.clock.sim_time - start_time
        }
        scheduler_step(sched, dt)
    }
}

// Unified overloaded entry point
simulate_until :: proc{simulate_until_ptr, simulate_until_nil}
