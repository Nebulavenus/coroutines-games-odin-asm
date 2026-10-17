package coroutine_sync

import "base:intrinsics"
import coro ".."

// ============================================================================
// Cooperative Synchronization & CSP Primitives (Optional Subpackage)
// ============================================================================

Fiber_Mutex :: struct {
    locked:  bool,
    owner:   coro.Fiber_Handle,
    waiters: coro.Wait_Queue,
}

Fiber_Semaphore :: struct {
    permits:     int,
    max_permits: int,
    waiters:     coro.Wait_Queue,
}

Channel :: struct($T: typeid) {
    buffer:       []T,              // Fixed circular ring buffer slice
    head:         int,              // Pop/read index
    tail:         int,              // Push/write index
    count:        int,              // Number of active items in ring buffer
    capacity:     int,              // Configured capacity (0 for unbuffered rendezvous)
    send_waiters: coro.Wait_Queue,  // Fibers blocked on chan_send
    recv_waiters: coro.Wait_Queue,  // Fibers blocked on chan_recv
    is_closed:    bool,             // Closed state flag
    allocator:    intrinsics.type_field_type(coro.Scheduler, "allocator"),
}

// ============================================================================
// Fiber Mutex (Cooperative Resource Lock)
// ============================================================================

mutex_init :: proc(m: ^Fiber_Mutex) {
    if m == nil do return
    m^ = {}
}

mutex_destroy :: proc(m: ^Fiber_Mutex) {
    if m == nil do return
    m.owner = 0
    m.locked = false
    coro.wait_queue_destroy(&m.waiters)
}

mutex_try_lock :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex) -> bool {
    if m == nil do return false
    if !m.locked {
        m.locked = true
        if f != nil do m.owner = f.handle
        return true
    }
    return false
}

mutex_lock :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
    if f == nil || m == nil || f.sched == nil do return

    if !m.locked {
        m.locked = true
        m.owner = f.handle
        return
    }

    // Already locked: suspend this fiber until unlock
    coro.wait_queue_push_back(&m.waiters, f)
    coro.fiber_suspend(f)
    m.owner = f.handle
}

mutex_unlock_sched :: proc(sched: ^coro.Scheduler, m: ^Fiber_Mutex) {
    if sched == nil || m == nil do return

    for {
        next_fiber, ok := coro.wait_queue_pop_front(&m.waiters)
        if !ok do break
        if next_fiber != nil && coro.fiber_wake(sched, next_fiber) {
            m.owner = next_fiber.handle
            return
        }
    }

    m.owner = 0
    m.locked = false
}

mutex_unlock_fiber :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
    if f == nil || f.sched == nil do return
    mutex_unlock_sched(f.sched, m)
}

mutex_unlock :: proc{
    mutex_unlock_sched,
    mutex_unlock_fiber,
}

mutex_owner :: #force_inline proc "contextless" (m: ^Fiber_Mutex) -> coro.Fiber_Handle {
    return m != nil ? m.owner : 0
}

mutex_is_locked :: #force_inline proc "contextless" (m: ^Fiber_Mutex) -> bool {
    return m != nil && m.locked
}

mutex_waiter_count :: #force_inline proc "contextless" (m: ^Fiber_Mutex) -> int {
    return m != nil ? coro.wait_queue_count(&m.waiters) : 0
}

@(private="file")
Scoped_Mutex_Cleanup_Ctx :: struct {
    sched: ^coro.Scheduler,
    m:     ^Fiber_Mutex,
}

@(private="file")
cleanup_mutex_hook :: proc(user_data: rawptr) {
    ctx := (^Scoped_Mutex_Cleanup_Ctx)(user_data)
    if ctx != nil && ctx.sched != nil && ctx.m != nil {
        mutex_unlock(ctx.sched, ctx.m)
    }
}

with_mutex_ptr :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex, body: proc(f: ^coro.Fiber, data: ^$T), data: ^T) {
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    ctx := Scoped_Mutex_Cleanup_Ctx{
        sched = f.sched,
        m     = m,
    }
    coro.fiber_defer(f, cleanup_mutex_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        mutex_unlock(f.sched, m)
    }
    body(f, data)
}

with_mutex_val :: proc(
    f: ^coro.Fiber,
    m: ^Fiber_Mutex,
    body: proc(f: ^coro.Fiber, data: $T),
    data: T,
) where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= coro.FIBER_PAYLOAD_SIZE, "with_mutex_val: payload exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    ctx := Scoped_Mutex_Cleanup_Ctx{
        sched = f.sched,
        m     = m,
    }
    coro.fiber_defer(f, cleanup_mutex_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        mutex_unlock(f.sched, m)
    }
    body(f, data)
}

with_mutex_nil :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex, body: proc(f: ^coro.Fiber)) {
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    ctx := Scoped_Mutex_Cleanup_Ctx{
        sched = f.sched,
        m     = m,
    }
    coro.fiber_defer(f, cleanup_mutex_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        mutex_unlock(f.sched, m)
    }
    body(f)
}

with_mutex :: proc{with_mutex_ptr, with_mutex_val, with_mutex_nil}

// ============================================================================
// Fiber Semaphore (Counting Semaphore with Up to N Concurrent Permits)
// ============================================================================

semaphore_init :: proc(sem: ^Fiber_Semaphore, initial_permits: int, max_permits: int = -1) {
    if sem == nil do return
    sem.permits = initial_permits
    sem.max_permits = max_permits > 0 ? max_permits : initial_permits
    sem.waiters = {}
}

semaphore_destroy :: proc(sem: ^Fiber_Semaphore) {
    if sem == nil do return
    coro.wait_queue_destroy(&sem.waiters)
}

semaphore_try_acquire :: proc(sem: ^Fiber_Semaphore) -> bool {
    if sem == nil do return false
    if sem.permits > 0 {
        sem.permits -= 1
        return true
    }
    return false
}

semaphore_acquire :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore) {
    if f == nil || sem == nil || f.sched == nil do return

    if sem.permits > 0 {
        sem.permits -= 1
        return
    }

    coro.wait_queue_push_back(&sem.waiters, f)
    coro.fiber_suspend(f)
}

semaphore_release_sched :: proc(sched: ^coro.Scheduler, sem: ^Fiber_Semaphore, count: int = 1) {
    if sched == nil || sem == nil || count <= 0 do return

    if sem.max_permits > 0 {
        sem.permits = min(sem.permits + count, sem.max_permits)
    } else {
        sem.permits += count
    }

    for sem.permits > 0 {
        next_fiber, ok := coro.wait_queue_pop_front(&sem.waiters)
        if !ok do break
        if next_fiber != nil && coro.fiber_wake(sched, next_fiber) {
            sem.permits -= 1
        }
    }
}

semaphore_release_fiber :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, count: int = 1) {
    if f == nil || f.sched == nil do return
    semaphore_release_sched(f.sched, sem, count)
}

semaphore_release :: proc{
    semaphore_release_sched,
    semaphore_release_fiber,
}

semaphore_available_permits :: #force_inline proc(sem: ^Fiber_Semaphore) -> int {
    return sem != nil ? sem.permits : 0
}

semaphore_waiter_count :: #force_inline proc "contextless" (sem: ^Fiber_Semaphore) -> int {
    return sem != nil ? coro.wait_queue_count(&sem.waiters) : 0
}

@(private="file")
Scoped_Sem_Cleanup_Ctx :: struct {
    sched: ^coro.Scheduler,
    sem:   ^Fiber_Semaphore,
}

@(private="file")
cleanup_sem_hook :: proc(user_data: rawptr) {
    ctx := (^Scoped_Sem_Cleanup_Ctx)(user_data)
    if ctx != nil && ctx.sched != nil && ctx.sem != nil {
        semaphore_release(ctx.sched, ctx.sem)
    }
}

with_semaphore_ptr :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, body: proc(f: ^coro.Fiber, data: ^$T), data: ^T) {
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    ctx := Scoped_Sem_Cleanup_Ctx{
        sched = f.sched,
        sem   = sem,
    }
    coro.fiber_defer(f, cleanup_sem_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        semaphore_release(f.sched, sem)
    }
    body(f, data)
}

with_semaphore_val :: proc(
    f: ^coro.Fiber,
    sem: ^Fiber_Semaphore,
    body: proc(f: ^coro.Fiber, data: $T),
    data: T,
) where !intrinsics.type_is_pointer(T) {
    #assert(size_of(T) <= coro.FIBER_PAYLOAD_SIZE, "with_semaphore_val: payload exceeds FIBER_PAYLOAD_SIZE (128 bytes)")
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    ctx := Scoped_Sem_Cleanup_Ctx{
        sched = f.sched,
        sem   = sem,
    }
    coro.fiber_defer(f, cleanup_sem_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        semaphore_release(f.sched, sem)
    }
    body(f, data)
}

with_semaphore_nil :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, body: proc(f: ^coro.Fiber)) {
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    ctx := Scoped_Sem_Cleanup_Ctx{
        sched = f.sched,
        sem   = sem,
    }
    coro.fiber_defer(f, cleanup_sem_hook, rawptr(&ctx))
    defer {
        coro.fiber_cleanup_pop(f)
        semaphore_release(f.sched, sem)
    }
    body(f)
}

with_semaphore :: proc{with_semaphore_ptr, with_semaphore_val, with_semaphore_nil}

// ============================================================================
// CSP Typed Channels (Channel(T))
// ============================================================================

chan_init :: proc(ch: ^Channel($T), capacity: int = 0, allocator := context.allocator) {
    if ch.buffer != nil {
        chan_destroy(ch)
    }
    ch.capacity = max(0, capacity)
    buf_size := ch.capacity > 0 ? ch.capacity : 1
    ch.buffer = make([]T, buf_size, allocator)
    ch.head = 0
    ch.tail = 0
    ch.count = 0
    coro.wait_queue_init(&ch.send_waiters)
    coro.wait_queue_init(&ch.recv_waiters)
    ch.is_closed = false
    ch.allocator = allocator
}

chan_destroy :: proc(ch: ^Channel($T)) {
    if ch == nil do return
    if !ch.is_closed {
        chan_close(ch)
    }
    delete(ch.buffer, ch.allocator)
    ch.buffer = nil
    coro.wait_queue_destroy(&ch.send_waiters)
    coro.wait_queue_destroy(&ch.recv_waiters)
    ch.head = 0
    ch.tail = 0
    ch.count = 0
    ch.capacity = 0
}

chan_count :: #force_inline proc "contextless" (ch: ^Channel($T)) -> int {
    return ch != nil ? ch.count : 0
}

chan_cap :: #force_inline proc "contextless" (ch: ^Channel($T)) -> int {
    return ch != nil ? ch.capacity : 0
}

chan_is_empty :: #force_inline proc "contextless" (ch: ^Channel($T)) -> bool {
    return ch == nil || ch.count == 0
}

chan_is_full :: #force_inline proc "contextless" (ch: ^Channel($T)) -> bool {
    return ch != nil && ch.capacity > 0 && ch.count >= ch.capacity
}

chan_send_waiter_count :: #force_inline proc "contextless" (ch: ^Channel($T)) -> int {
    return ch != nil ? coro.wait_queue_count(&ch.send_waiters) : 0
}

chan_recv_waiter_count :: #force_inline proc "contextless" (ch: ^Channel($T)) -> int {
    return ch != nil ? coro.wait_queue_count(&ch.recv_waiters) : 0
}

chan_close :: proc(ch: ^Channel($T)) {
    if ch == nil || ch.is_closed do return
    ch.is_closed = true

    for {
        f, ok := coro.wait_queue_pop_front(&ch.recv_waiters)
        if !ok do break
        if f != nil {
            coro.fiber_wake(f.sched, f)
        }
    }

    for {
        f, ok := coro.wait_queue_pop_front(&ch.send_waiters)
        if !ok do break
        if f != nil {
            coro.fiber_wake(f.sched, f)
        }
    }
}

chan_try_send :: proc(ch: ^Channel($T), value: T) -> (ok: bool) {
    if ch == nil || ch.is_closed do return false

    if ch.capacity == 0 {
        for {
            receiver, popped := coro.wait_queue_pop_front(&ch.recv_waiters)
            if !popped do break
            if receiver != nil && coro.fiber_wake(receiver.sched, receiver) {
                ch.buffer[0] = value
                ch.count = 1
                return true
            }
        }
        return false
    }

    if ch.count >= ch.capacity {
        return false
    }

    ch.buffer[ch.tail] = value
    ch.tail = (ch.tail + 1) % len(ch.buffer)
    ch.count += 1

    for {
        receiver, popped := coro.wait_queue_pop_front(&ch.recv_waiters)
        if !popped do break
        if receiver != nil && coro.fiber_wake(receiver.sched, receiver) {
            break
        }
    }
    return true
}

chan_try_recv :: proc(ch: ^Channel($T)) -> (value: T, ok: bool) {
    if ch == nil || ch.count == 0 do return {}, false

    val := ch.buffer[ch.head]
    if ch.capacity > 0 {
        ch.head = (ch.head + 1) % len(ch.buffer)
        ch.count -= 1
    } else {
        ch.head = 0
        ch.tail = 0
        ch.count = 0
    }

    for {
        sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
        if !popped do break
        if sender != nil && coro.fiber_wake(sender.sched, sender) {
            break
        }
    }
    return val, true
}

chan_send :: proc(f: ^coro.Fiber, ch: ^Channel($T), value: T) -> (ok: bool) {
    if f == nil || ch == nil || f.sched == nil do return false
    if ch.is_closed do return false

    for {
        if ch.is_closed do return false

        if ch.capacity == 0 {
            if ch.count == 0 {
                for {
                    receiver, popped := coro.wait_queue_pop_front(&ch.recv_waiters)
                    if !popped do break
                    if receiver != nil && coro.fiber_wake(receiver.sched, receiver) {
                        ch.buffer[0] = value
                        ch.count = 1
                        return true
                    }
                }

                // Unbuffered rendezvous: store value in buffer[0], set count = 1, and wait for receiver
                ch.buffer[0] = value
                ch.count = 1

                cleanup_unbuf_sender :: proc(user_data: rawptr) {
                    ch := (^Channel(T))(user_data)
                    if ch != nil && ch.capacity == 0 && ch.count > 0 {
                        ch.count = 0
                    }
                }
                coro.fiber_defer(f, cleanup_unbuf_sender, ch)

                coro.wait_queue_push_back(&ch.send_waiters, f)
                coro.fiber_suspend(f)

                coro.fiber_cleanup_pop(f)

                // If other unbuffered senders are queued, wake the next one to take its turn
                for {
                    next_sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
                    if !popped do break
                    if next_sender != nil && coro.fiber_wake(next_sender.sched, next_sender) {
                        break
                    }
                }

                if ch.is_closed && ch.count > 0 do return false
                return true
            }

            // Another unbuffered sender is already waiting in rendezvous; wait in send_waiters
            coro.wait_queue_push_back(&ch.send_waiters, f)
            coro.fiber_suspend(f)
            continue
        } else if ch.count < ch.capacity {
            ch.buffer[ch.tail] = value
            ch.tail = (ch.tail + 1) % len(ch.buffer)
            ch.count += 1

            for {
                receiver, popped := coro.wait_queue_pop_front(&ch.recv_waiters)
                if !popped do break
                if receiver != nil && coro.fiber_wake(receiver.sched, receiver) {
                    break
                }
            }
            return true
        }

        coro.wait_queue_push_back(&ch.send_waiters, f)
        coro.fiber_suspend(f)
    }
}

chan_recv :: proc(f: ^coro.Fiber, ch: ^Channel($T)) -> (value: T, ok: bool) {
    if f == nil || ch == nil || f.sched == nil do return {}, false

    for {
        if ch.count > 0 {
            val := ch.buffer[ch.head]
            if ch.capacity > 0 {
                ch.head = (ch.head + 1) % len(ch.buffer)
                ch.count -= 1
            } else {
                ch.head = 0
                ch.tail = 0
                ch.count = 0
            }

            for {
                sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
                if !popped do break
                if sender != nil && coro.fiber_wake(sender.sched, sender) {
                    break
                }
            }
            return val, true
        }

        if ch.is_closed {
            return {}, false
        }

        coro.wait_queue_push_back(&ch.recv_waiters, f)
        coro.fiber_suspend(f)
    }
}

chan_recv_timeout :: proc(f: ^coro.Fiber, ch: ^Channel($T), timeout_seconds: f32) -> (value: T, ok: bool, timed_out: bool) {
    if f == nil || ch == nil do return {}, false, false

    if ch.count > 0 {
        val, ok_recv := chan_try_recv(ch)
        if ok_recv do return val, true, false
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

    winner := coro.race(f,
        coro.branch(proc(f: ^coro.Fiber, p: ^Chan_Recv_Pair) {
            v, ok_recv := chan_recv(f, p.ch)
            p.res.val = v
            p.res.ok = ok_recv
            p.res.timed_out = false
        }, &pair, name = "Chan Recv Branch"),

        coro.branch(proc(f: ^coro.Fiber, p: ^Chan_Recv_Pair) {
            coro.wait(f, p.timeout_seconds)
            p.res.timed_out = true
            p.res.ok = false
        }, &pair, name = "Chan Timeout Branch"),
    )

    if winner == 1 {
        return {}, false, true
    }
    return res.val, res.ok, res.timed_out
}

chan_send_timeout :: proc(f: ^coro.Fiber, ch: ^Channel($T), value: T, timeout_seconds: f32) -> (ok: bool, timed_out: bool) {
    if f == nil || ch == nil do return false, false

    if chan_try_send(ch, value) {
        return true, false
    }

    if ch.is_closed {
        return false, false
    }

    if timeout_seconds <= 0.0 {
        return false, true
    }

    Send_Result :: struct {
        ok:        bool,
        timed_out: bool,
    }
    res := Send_Result{}

    Chan_Send_Pair :: struct {
        ch:              ^Channel(T),
        val:             T,
        res:             ^Send_Result,
        timeout_seconds: f32,
    }
    pair := Chan_Send_Pair{ch = ch, val = value, res = &res, timeout_seconds = timeout_seconds}

    winner := coro.race(f,
        coro.branch(proc(f: ^coro.Fiber, p: ^Chan_Send_Pair) {
            ok_send := chan_send(f, p.ch, p.val)
            p.res.ok = ok_send
            p.res.timed_out = false
        }, &pair, name = "Chan Send Branch"),

        coro.branch(proc(f: ^coro.Fiber, p: ^Chan_Send_Pair) {
            coro.wait(f, p.timeout_seconds)
            p.res.timed_out = true
            p.res.ok = false
        }, &pair, name = "Chan Send Timeout Branch"),
    )

    if winner == 1 {
        return false, true
    }
    return res.ok, res.timed_out
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

chan_select_recv :: proc(f: ^coro.Fiber, channels: []^Channel($T)) -> (ready_index: int, value: T, ok: bool) {
    if f == nil || f.sched == nil || len(channels) == 0 do return -1, {}, false

    for {
        all_closed := true

        for ch, i in channels {
            if ch != nil {
                if chan_count(ch) > 0 {
                    val, popped := chan_try_recv(ch)
                    if popped do return i, val, true
                }
                if !ch.is_closed {
                    all_closed = false
                }
            }
        }

        if all_closed do return -1, {}, false

        for ch, i in channels {
            if ch != nil && ch.is_closed {
                return i, {}, false
            }
        }

        coro.yield(f)
    }
}
