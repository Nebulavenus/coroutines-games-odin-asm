package coroutine

import "base:runtime"
import "core:math"

// ============================================================================
// Spawning Coroutines
// ============================================================================

spawn :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
) -> Fiber_Handle {
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.debug_name = name
    fiber.stored_context = context
    fiber.start_time = sched.current_time
    fiber.user_data = rawptr(data)
    fiber.entry_proc = cast(proc(f: ^Fiber, user_data: rawptr))entry

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
    fiber.stored_context = context
    fiber.start_time = sched.current_time
    fiber.user_data = rawptr(entry)
    fiber.entry_proc = wrapper

    if scope != nil {
        fiber.scope = scope
        append(&scope.handles, fiber.handle)
    }

    append(&sched.ready_queue, fiber)
    return fiber.handle
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

    f.wake_time = f.sched.current_time + f64(seconds)
    f.status = .Sleeping_Time
    timer_heap_push(f.sched, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
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
    f.wake_frame = f.sched.current_frame + u64(target_frames)
    f.status = .Sleeping_Frames
    append(&f.sched.frame_waiters, f)

    f.stored_context = context
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
    context = f.stored_context
}

yield_frame :: proc(f: ^Fiber) {
    wait_frames(f, 1)
}

wait_until :: proc(f: ^Fiber, condition: proc(data: ^$T) -> bool, data: ^T) {
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

wait_cond :: proc(f: ^Fiber, condition: proc() -> bool) {
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

// ============================================================================
// Structured Concurrency: Branch, Sync, and Race
// ============================================================================

branch :: proc(
    entry: proc(f: ^Fiber, data: ^$T),
    data: ^T,
    name: string = "",
) -> Branch_Desc {
    return Branch_Desc{
        entry_proc = cast(proc(f: ^Fiber, user_data: rawptr))entry,
        user_data  = rawptr(data),
        name       = name,
    }
}

branch_nil :: proc(entry: proc(f: ^Fiber), name: string = "") -> Branch_Desc {
    wrapper := proc(f: ^Fiber, user_data: rawptr) {
        real_entry := cast(proc(f: ^Fiber))user_data
        if real_entry != nil {
            real_entry(f)
        }
    }
    return Branch_Desc{
        entry_proc = wrapper,
        user_data  = rawptr(entry),
        name       = name,
    }
}

sync :: proc(f: ^Fiber, branches: ..Branch_Desc) {
    if f == nil || f.sched == nil || len(branches) == 0 do return

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
        child.stored_context = context
        child.start_time = f.sched.current_time
        child.user_data = b.user_data
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
        child.stored_context = context
        child.start_time = f.sched.current_time
        child.user_data = b.user_data
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

tween :: proc(
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
        elapsed += f.sched.delta_time
        t := clamp(elapsed / duration, 0.0, 1.0)
        eased_t := ease_fn(t)
        output^ = start + (target - start) * eased_t
    }

    output^ = target
}
