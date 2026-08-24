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
) -> Fiber_Handle {
    fiber := fiber_pool_acquire(&sched.fiber_pool)
    fiber.sched = sched
    fiber.debug_name = name
    fiber.stored_context = context
    fiber.start_time = sched.current_time
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

spawn_typed :: spawn_ptr

spawn_val :: proc(
    sched: ^Scheduler,
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    scope: ^Fiber_Scope = nil,
    name: string = "",
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
    fiber.stored_context = context
    fiber.start_time = sched.current_time

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

delta_time :: #force_inline proc "contextless" (f: ^Fiber) -> f32 {
    return f != nil && f.sched != nil ? f.sched.delta_time : 0.0
}

current_time :: #force_inline proc "contextless" (f: ^Fiber) -> f64 {
    return f != nil && f.sched != nil ? f.sched.current_time : 0.0
}

current_frame :: #force_inline proc "contextless" (f: ^Fiber) -> u64 {
    return f != nil && f.sched != nil ? f.sched.current_frame : 0
}

scope_wait :: proc(f: ^Fiber, scope: ^Fiber_Scope) {
    if f == nil || f.sched == nil || scope == nil do return
    wait_until(f, proc(s: ^Fiber_Scope) -> bool {
        return s == nil || len(s.handles) == 0
    }, scope)
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

wait_until_typed :: wait_until_ptr

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
wait_cond  :: wait_until_nil

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
) -> Branch_Desc {
    return Branch_Desc{
        entry_proc  = cast(proc(f: ^Fiber, user_data: rawptr))entry,
        user_data   = rawptr(data),
        user_fn     = rawptr(entry),
        has_payload = false,
        name        = name,
    }
}

branch_typed :: branch_ptr

branch_val :: proc(
    entry: proc(f: ^Fiber, data: $T),
    data: T,
    name: string = "",
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
    }
    data_copy := data
    mem.copy(&desc.payload_storage[0], &data_copy, size_of(T))
    return desc
}

branch_nil :: proc(entry: proc(f: ^Fiber), name: string = "") -> Branch_Desc {
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
        child.stored_context = context
        child.start_time = f.sched.current_time
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
        child.stored_context = context
        child.start_time = f.sched.current_time
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
        elapsed += f.sched.delta_time
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
        elapsed += f.sched.delta_time
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
        elapsed += f.sched.delta_time
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
        elapsed += f.sched.delta_time
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

    if len(m.waiters) > 0 {
        next_fiber := pop_front(&m.waiters)
        if next_fiber.status == .Suspended_Join {
            next_fiber.status = .Ready
            append(&sched.ready_queue, next_fiber)
        }
    } else {
        m.locked = false
    }
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
