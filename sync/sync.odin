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

Chan_Outcome :: enum u8 {
    Ok,
    Closed,
    Timed_Out,
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

@(private="file")
Mutex_Wait_Relay :: struct {
    m:      ^Fiber_Mutex,
    handle: coro.Fiber_Handle,
}

@(private="file")
relay_mutex_wait_hook :: proc(raw: rawptr) {
    r := (^Mutex_Wait_Relay)(raw)
    if r == nil || r.m == nil do return
    if r.m.locked && r.m.owner == r.handle {
        mutex_unlock(r.m)
    }
}

mutex_lock :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
    if f == nil || m == nil || f.sched == nil do return

    if !m.locked {
        m.locked = true
        m.owner = f.handle
        return
    }

    relay := Mutex_Wait_Relay{m = m, handle = f.handle}
    coro.fiber_defer(f, relay_mutex_wait_hook, rawptr(&relay))
    coro.wait_queue_push_back(&m.waiters, f)
    coro.fiber_suspend(f)
    coro.fiber_defer_cancel(f)
    m.owner = f.handle
}

mutex_unlock :: proc(m: ^Fiber_Mutex) {
    if m == nil do return

    for {
        next_fiber, ok := coro.wait_queue_pop_front(&m.waiters)
        if !ok do break
        if next_fiber != nil && coro.fiber_wake(next_fiber.sched, next_fiber) {
            m.owner = next_fiber.handle
            return
        }
    }

    m.owner = 0
    m.locked = false
}

mutex_lock_timeout :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex, timeout_seconds: f32) -> (acquired: bool) {
    if f == nil || m == nil || f.sched == nil do return false
    if mutex_try_lock(f, m) do return true
    if timeout_seconds <= 0 do return false

    Lock_Timeout_State :: struct {
        m:        ^Fiber_Mutex,
        owner:    coro.Fiber_Handle,
        acquired: bool,
    }
    st := Lock_Timeout_State{m = m, owner = f.handle, acquired = false}
    coro.fiber_defer(f, proc(s: ^Lock_Timeout_State) {
        if s != nil && s.acquired {
            mutex_unlock(s.m)
        }
    }, &st)

    outcome := coro.with_timeout(f, timeout_seconds, proc(child: ^coro.Fiber, s: ^Lock_Timeout_State) {
        mutex_lock(child, s.m)
        s.m.owner = s.owner
        s.acquired = true
    }, &st, name = "mutex_lock_timeout")

    coro.fiber_defer_cancel(f)
    if outcome == .Completed && st.acquired {
        return true
    }
    if st.acquired {
        mutex_unlock(m)
    }
    return false
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

with_mutex_ptr :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex, body: proc(f: ^coro.Fiber, data: ^$T), data: ^T) {
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    coro.fiber_defer(f, mutex_unlock, m)
    defer {
        coro.fiber_defer_cancel(f)
        mutex_unlock(m)
    }
    body(f, data)
}

with_mutex_val :: proc(
    f: ^coro.Fiber,
    m: ^Fiber_Mutex,
    body: proc(f: ^coro.Fiber, data: $T),
    data: T,
) where !intrinsics.type_is_pointer(T) {
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    coro.fiber_defer(f, mutex_unlock, m)
    defer {
        coro.fiber_defer_cancel(f)
        mutex_unlock(m)
    }
    body(f, data)
}

with_mutex_nil :: proc(f: ^coro.Fiber, m: ^Fiber_Mutex, body: proc(f: ^coro.Fiber)) {
    if f == nil || m == nil || f.sched == nil || body == nil do return
    mutex_lock(f, m)
    coro.fiber_defer(f, mutex_unlock, m)
    defer {
        coro.fiber_defer_cancel(f)
        mutex_unlock(m)
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

@(private="file")
relay_sem_wait_hook :: proc(sem: ^Fiber_Semaphore) {
    if sem == nil || sem.permits <= 0 do return
    for {
        next_fiber, ok := coro.wait_queue_pop_front(&sem.waiters)
        if !ok do break
        if next_fiber != nil && coro.fiber_wake(next_fiber.sched, next_fiber) {
            return
        }
    }
}

semaphore_acquire :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore) {
    if f == nil || sem == nil || f.sched == nil do return

    for sem.permits <= 0 {
        coro.fiber_defer(f, relay_sem_wait_hook, sem)
        coro.wait_queue_push_back(&sem.waiters, f)
        coro.fiber_suspend(f)
        coro.fiber_defer_cancel(f)
    }
    sem.permits -= 1
}

semaphore_release :: proc(sem: ^Fiber_Semaphore, count: int = 1) {
    if sem == nil || count <= 0 do return

    if sem.max_permits > 0 {
        sem.permits = min(sem.permits + count, sem.max_permits)
    } else {
        sem.permits += count
    }

    woken := 0
    for woken < sem.permits {
        next_fiber, ok := coro.wait_queue_pop_front(&sem.waiters)
        if !ok do break
        if next_fiber != nil && coro.fiber_wake(next_fiber.sched, next_fiber) {
            woken += 1
        }
    }
}

semaphore_acquire_timeout :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, timeout_seconds: f32) -> (acquired: bool) {
    if f == nil || sem == nil || f.sched == nil do return false
    if semaphore_try_acquire(sem) do return true
    if timeout_seconds <= 0 do return false

    Sem_Timeout_State :: struct {
        sem:      ^Fiber_Semaphore,
        acquired: bool,
    }
    st := Sem_Timeout_State{sem = sem, acquired = false}
    coro.fiber_defer(f, proc(s: ^Sem_Timeout_State) {
        if s != nil && s.acquired {
            semaphore_release(s.sem, 1)
        }
    }, &st)

    outcome := coro.with_timeout(f, timeout_seconds, proc(child: ^coro.Fiber, s: ^Sem_Timeout_State) {
        semaphore_acquire(child, s.sem)
        s.acquired = true
    }, &st, name = "semaphore_acquire_timeout")

    coro.fiber_defer_cancel(f)
    if outcome == .Completed && st.acquired {
        return true
    }
    if st.acquired {
        semaphore_release(sem, 1)
    }
    return false
}

semaphore_available_permits :: #force_inline proc(sem: ^Fiber_Semaphore) -> int {
    return sem != nil ? sem.permits : 0
}

semaphore_waiter_count :: #force_inline proc "contextless" (sem: ^Fiber_Semaphore) -> int {
    return sem != nil ? coro.wait_queue_count(&sem.waiters) : 0
}

@(private="file")
cleanup_sem_hook :: proc(sem: ^Fiber_Semaphore) {
    semaphore_release(sem, 1)
}

with_semaphore_ptr :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, body: proc(f: ^coro.Fiber, data: ^$T), data: ^T) {
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    coro.fiber_defer(f, cleanup_sem_hook, sem)
    defer {
        coro.fiber_defer_cancel(f)
        semaphore_release(sem)
    }
    body(f, data)
}

with_semaphore_val :: proc(
    f: ^coro.Fiber,
    sem: ^Fiber_Semaphore,
    body: proc(f: ^coro.Fiber, data: $T),
    data: T,
) where !intrinsics.type_is_pointer(T) {
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    coro.fiber_defer(f, cleanup_sem_hook, sem)
    defer {
        coro.fiber_defer_cancel(f)
        semaphore_release(sem)
    }
    body(f, data)
}

with_semaphore_nil :: proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore, body: proc(f: ^coro.Fiber)) {
    if f == nil || sem == nil || f.sched == nil || body == nil do return
    semaphore_acquire(f, sem)
    coro.fiber_defer(f, cleanup_sem_hook, sem)
    defer {
        coro.fiber_defer_cancel(f)
        semaphore_release(sem)
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

chan_is_closed :: #force_inline proc "contextless" (ch: ^Channel($T)) -> bool {
    return ch == nil || ch.is_closed
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
        if ch.count > 0 do return false
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
                        for {
                            next_sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
                            if !popped do break
                            if next_sender != nil && coro.fiber_wake(next_sender.sched, next_sender) {
                                break
                            }
                        }
                    }
                }
                coro.fiber_defer(f, cleanup_unbuf_sender, ch)

                coro.wait_queue_push_back(&ch.send_waiters, f)
                coro.fiber_suspend(f)

                coro.fiber_defer_cancel(f)

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
            cleanup_queued_sender :: proc(user_data: rawptr) {
                ch := (^Channel(T))(user_data)
                if ch != nil && !ch.is_closed && ch.count == 0 {
                    for {
                        next_sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
                        if !popped do break
                        if next_sender != nil && coro.fiber_wake(next_sender.sched, next_sender) {
                            break
                        }
                    }
                }
            }
            coro.fiber_defer(f, cleanup_queued_sender, ch)
            coro.wait_queue_push_back(&ch.send_waiters, f)
            coro.fiber_suspend(f)
            coro.fiber_defer_cancel(f)
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

        cleanup_buf_sender :: proc(user_data: rawptr) {
            ch := (^Channel(T))(user_data)
            if ch != nil && !ch.is_closed && ch.count < ch.capacity {
                for {
                    next_sender, popped := coro.wait_queue_pop_front(&ch.send_waiters)
                    if !popped do break
                    if next_sender != nil && coro.fiber_wake(next_sender.sched, next_sender) {
                        break
                    }
                }
            }
        }
        coro.fiber_defer(f, cleanup_buf_sender, ch)
        coro.wait_queue_push_back(&ch.send_waiters, f)
        coro.fiber_suspend(f)
        coro.fiber_defer_cancel(f)
    }
}

chan_recv :: proc(f: ^coro.Fiber, ch: ^Channel($T)) -> (value: T, ok: bool) {
    if f == nil || ch == nil || f.sched == nil do return {}, false

    cleanup_recv_relay :: proc(user_data: rawptr) {
        ch := (^Channel(T))(user_data)
        if ch != nil && (ch.count > 0 || ch.is_closed) {
            for {
                next_recv, popped := coro.wait_queue_pop_front(&ch.recv_waiters)
                if !popped do break
                if next_recv != nil && coro.fiber_wake(next_recv.sched, next_recv) {
                    break
                }
            }
        }
    }

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

        coro.fiber_defer(f, cleanup_recv_relay, ch)
        coro.wait_queue_push_back(&ch.recv_waiters, f)
        coro.fiber_suspend(f)
        coro.fiber_defer_cancel(f)
    }
}

chan_recv_timeout :: proc(f: ^coro.Fiber, ch: ^Channel($T), timeout_seconds: f32) -> (value: T, outcome: Chan_Outcome) {
    if f == nil || ch == nil || f.sched == nil do return value, .Closed

    if ch.count > 0 {
        ok_recv: bool
        value, ok_recv = chan_try_recv(ch)
        if ok_recv do return value, .Ok
    }

    if ch.is_closed {
        return value, .Closed
    }

    if timeout_seconds <= 0.0 {
        ok_recv: bool
        value, ok_recv = chan_try_recv(ch)
        return value, ok_recv ? .Ok : .Timed_Out
    }

    Recv_State :: struct {
        ch:  ^Channel(T),
        out: ^T,
        ok:  bool,
    }
    state := Recv_State{ch = ch, out = &value}

    winner := coro.race(f,
        coro.branch(proc(f: ^coro.Fiber, s: ^Recv_State) {
            v, ok_recv := chan_recv(f, s.ch)
            if ok_recv {
                s.out^ = v
            }
            s.ok = ok_recv
        }, &state, name = "Chan Recv Branch"),

        coro.branch_wait(timeout_seconds, name = "Chan Timeout Branch"),
    )

    if winner == 1 {
        return value, .Timed_Out
    }
    return value, state.ok ? .Ok : .Closed
}

chan_send_timeout :: proc(f: ^coro.Fiber, ch: ^Channel($T), value: T, timeout_seconds: f32) -> (outcome: Chan_Outcome) {
    if f == nil || ch == nil || f.sched == nil do return .Closed

    if chan_try_send(ch, value) {
        return .Ok
    }

    if ch.is_closed {
        return .Closed
    }

    if timeout_seconds <= 0.0 {
        return .Timed_Out
    }

    Send_State :: struct {
        ch:      ^Channel(T),
        val_ptr: ^T,
        ok:      bool,
    }
    val_local := value
    state := Send_State{ch = ch, val_ptr = &val_local}

    winner := coro.race(f,
        coro.branch(proc(f: ^coro.Fiber, s: ^Send_State) {
            s.ok = chan_send(f, s.ch, s.val_ptr^)
        }, &state, name = "Chan Send Branch"),

        coro.branch_wait(timeout_seconds, name = "Chan Send Timeout Branch"),
    )

    if winner == 1 {
        return .Timed_Out
    }
    return state.ok ? .Ok : .Closed
}

// --- Multi-Channel Select (CSP Multiplexer) ---

chan_try_select_recv :: proc(channels: []^Channel($T)) -> (ready_index: int, value: T, ok: bool) {
    for ch, i in channels {
        if ch != nil {
            popped: bool
            value, popped = chan_try_recv(ch)
            if popped {
                return i, value, true
            }
        }
    }
    return -1, value, false
}

chan_select_recv :: proc(f: ^coro.Fiber, channels: []^Channel($T)) -> (ready_index: int, value: T, ok: bool) {
    if f == nil || f.sched == nil || len(channels) == 0 do return -1, value, false

    n := len(channels)
    start := int(f.sched.select_cursor % u32(n))
    f.sched.select_cursor += 1

    open_count := 0
    for offset in 0 ..< n {
        i := (start + offset) % n
        ch := channels[i]
        if ch != nil {
            if chan_count(ch) > 0 {
                popped: bool
                value, popped = chan_try_recv(ch)
                if popped do return i, value, true
            }
            if !ch.is_closed {
                open_count += 1
            }
        }
    }

    if open_count == 0 do return -1, value, false

    Select_State :: struct {
        ready_index: int,
        out:         ^T,
        ok:          bool,
    }

    Select_Entry :: struct {
        ch:       ^Channel(T),
        orig_idx: int,
        state:    ^Select_State,
    }

    state := Select_State{ready_index = -1, out = &value}

    coro.fiber_begin_join(f, .Race, open_count)
    b_idx := 0
    for offset in 0 ..< n {
        i := (start + offset) % n
        ch := channels[i]
        if ch != nil && !ch.is_closed {
            entry := Select_Entry{
                ch       = ch,
                orig_idx = i,
                state    = &state,
            }
            desc := coro.branch_val(proc(child: ^coro.Fiber, e: Select_Entry) {
                v, recv_ok := chan_recv(child, e.ch)
                if !recv_ok {
                    coro.fail(child)
                    return
                }
                e.state.ready_index = e.orig_idx
                e.state.out^ = v
                e.state.ok = true
            }, entry, name = "Chan Select Watcher")
            coro.fiber_spawn_join_child(f, b_idx, &desc)
            b_idx += 1
        }
    }
    coro.fiber_wait_join(f)

    winner := f.active_coord.winner_index
    if winner < 0 || !state.ok {
        return -1, value, false
    }
    return state.ready_index, value, true
}

branch_chan_recv :: proc(ch: ^Channel($T), out: ^T, fail_on_close: bool = true, name := "chan_recv") -> coro.Branch_Desc {
    Payload :: struct {
        ch:            ^Channel(T),
        out:           ^T,
        fail_on_close: bool,
    }
    return coro.branch_val(proc(f: ^coro.Fiber, p: Payload) {
        val, ok := chan_recv(f, p.ch)
        if !ok {
            if p.fail_on_close {
                coro.fail(f)
            }
            return
        }
        if p.out != nil {
            p.out^ = val
        }
    }, Payload{ch = ch, out = out, fail_on_close = fail_on_close}, name)
}

branch_chan_send :: proc(ch: ^Channel($T), val_ptr: ^T, fail_on_close: bool = true, name := "chan_send") -> coro.Branch_Desc {
    Payload :: struct {
        ch:            ^Channel(T),
        val_ptr:       ^T,
        fail_on_close: bool,
    }
    return coro.branch_val(proc(f: ^coro.Fiber, p: Payload) {
        if p.val_ptr == nil {
            coro.fail(f)
            return
        }
        ok := chan_send(f, p.ch, p.val_ptr^)
        if !ok && p.fail_on_close {
            coro.fail(f)
        }
    }, Payload{ch = ch, val_ptr = val_ptr, fail_on_close = fail_on_close}, name)
}

Thread_Channel :: struct($T: typeid) {
    lock:         b32,
    buffer:       []T,
    head:         int,
    tail:         int,
    count:        int,
    capacity:     int,
    is_closed:    bool,
    ready_header: coro.Async_Header,
    allocator:    intrinsics.type_field_type(coro.Scheduler, "allocator"),
}

@(private="file")
thread_chan_lock :: #force_inline proc "contextless" (ch: ^Thread_Channel($T)) {
    for intrinsics.atomic_exchange_explicit(&ch.lock, true, .Acquire) {
        intrinsics.cpu_relax()
    }
}

@(private="file")
thread_chan_unlock :: #force_inline proc "contextless" (ch: ^Thread_Channel($T)) {
    intrinsics.atomic_store_explicit(&ch.lock, false, .Release)
}

thread_chan_init :: proc(ch: ^Thread_Channel($T), capacity: int = 16, allocator := context.allocator) {
    if ch == nil do return
    buf_cap := max(capacity, 1)
    alloc := allocator.procedure != nil ? allocator : context.allocator
    ch^ = Thread_Channel(T){
        buffer    = make([]T, buf_cap, alloc),
        capacity  = buf_cap,
        allocator = alloc,
    }
    intrinsics.atomic_store_explicit(&ch.ready_header.state, .Pending, .Release)
}

thread_chan_destroy :: proc(ch: ^Thread_Channel($T)) {
    if ch == nil do return
    thread_chan_close(ch)
    if ch.buffer != nil {
        alloc := ch.allocator.procedure != nil ? ch.allocator : context.allocator
        delete(ch.buffer, alloc)
        ch.buffer = nil
    }
    ch.head = 0
    ch.tail = 0
    ch.count = 0
    ch.capacity = 0
}

thread_chan_close :: proc(ch: ^Thread_Channel($T)) {
    if ch == nil do return
    thread_chan_lock(ch)
    ch.is_closed = true
    intrinsics.atomic_store_explicit(&ch.ready_header.state, .Completed, .Release)
    thread_chan_unlock(ch)
}

thread_chan_is_closed :: proc "contextless" (ch: ^Thread_Channel($T)) -> bool {
    if ch == nil do return true
    thread_chan_lock(ch)
    closed := ch.is_closed
    thread_chan_unlock(ch)
    return closed
}

thread_chan_count :: proc "contextless" (ch: ^Thread_Channel($T)) -> int {
    if ch == nil do return 0
    thread_chan_lock(ch)
    c := ch.count
    thread_chan_unlock(ch)
    return c
}

thread_chan_cap :: #force_inline proc "contextless" (ch: ^Thread_Channel($T)) -> int {
    return ch != nil ? ch.capacity : 0
}

thread_chan_try_send :: proc "contextless" (ch: ^Thread_Channel($T), value: T) -> (ok: bool) {
    if ch == nil || ch.buffer == nil do return false
    thread_chan_lock(ch)
    if ch.is_closed || ch.count >= ch.capacity {
        thread_chan_unlock(ch)
        return false
    }
    ch.buffer[ch.tail] = value
    ch.tail = (ch.tail + 1) % ch.capacity
    ch.count += 1
    intrinsics.atomic_store_explicit(&ch.ready_header.state, .Completed, .Release)
    thread_chan_unlock(ch)
    return true
}

thread_chan_try_recv :: proc "contextless" (ch: ^Thread_Channel($T)) -> (value: T, ok: bool) {
    if ch == nil || ch.buffer == nil do return {}, false
    thread_chan_lock(ch)
    if ch.count == 0 {
        thread_chan_unlock(ch)
        return {}, false
    }
    value = ch.buffer[ch.head]
    ch.head = (ch.head + 1) % ch.capacity
    ch.count -= 1
    if ch.count == 0 && !ch.is_closed {
        intrinsics.atomic_store_explicit(&ch.ready_header.state, .Pending, .Release)
    }
    thread_chan_unlock(ch)
    return value, true
}

thread_chan_recv :: proc(f: ^coro.Fiber, ch: ^Thread_Channel($T)) -> (value: T, ok: bool) {
    if f == nil || ch == nil || f.sched == nil || ch.buffer == nil do return {}, false

    for {
        thread_chan_lock(ch)
        if ch.count > 0 {
            value = ch.buffer[ch.head]
            ch.head = (ch.head + 1) % ch.capacity
            ch.count -= 1
            if ch.count == 0 && !ch.is_closed {
                intrinsics.atomic_store_explicit(&ch.ready_header.state, .Pending, .Release)
            }
            thread_chan_unlock(ch)
            return value, true
        }
        if ch.is_closed {
            thread_chan_unlock(ch)
            return {}, false
        }
        intrinsics.atomic_store_explicit(&ch.ready_header.state, .Pending, .Release)
        thread_chan_unlock(ch)

        coro.fiber_await_async_header(f, &ch.ready_header, false)
    }
}

branch_thread_chan_recv :: proc(ch: ^Thread_Channel($T), out: ^T, fail_on_close: bool = true, name := "thread_chan_recv") -> coro.Branch_Desc {
    Payload :: struct {
        ch:            ^Thread_Channel(T),
        out:           ^T,
        fail_on_close: bool,
    }
    return coro.branch_val(proc(f: ^coro.Fiber, p: Payload) {
        val, ok := thread_chan_recv(f, p.ch)
        if !ok {
            if p.fail_on_close {
                coro.fail(f)
            }
            return
        }
        if p.out != nil {
            p.out^ = val
        }
    }, Payload{ch = ch, out = out, fail_on_close = fail_on_close}, name)
}
