#+build !js
package coroutine_sync

import "core:testing"
import coro ".."

@(test)
test_fiber_mutex_contention :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    order := make([dynamic]int)
    defer delete(order)

    Worker_Data :: struct {
        m:     ^Fiber_Mutex,
        order: ^[dynamic]int,
        id:    int,
    }

    d1 := Worker_Data{m = &m, order = &order, id = 1}
    d2 := Worker_Data{m = &m, order = &order, id = 2}

    coro.spawn(&sched, proc(f: ^coro.Fiber, d: ^Worker_Data) {
        mutex_lock(f, d.m)
        append(d.order, d.id)
        coro.wait(f, 0.03)
        append(d.order, d.id + 10)
        mutex_unlock(f, d.m)
    }, &d1)

    coro.spawn(&sched, proc(f: ^coro.Fiber, d: ^Worker_Data) {
        mutex_lock(f, d.m)
        append(d.order, d.id)
        coro.wait(f, 0.01)
        append(d.order, d.id + 10)
        mutex_unlock(f, d.m)
    }, &d2)

    for _ in 0 ..< 10 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, len(order), 4)
    testing.expect_value(t, order[0], 1)
    testing.expect_value(t, order[1], 11)
    testing.expect_value(t, order[2], 2)
    testing.expect_value(t, order[3], 12)
}

@(test)
test_with_mutex_and_abort_cleanup :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    user_cleanup_called := false
    Ctx :: struct {
        m:       ^Fiber_Mutex,
        cleaned: ^bool,
    }
    ctx := Ctx{m = &m, cleaned = &user_cleanup_called}

    h := coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Ctx) {
        with_mutex(f, c.m, proc(f: ^coro.Fiber, c: ^Ctx) {
            coro.fiber_set_cleanup(f, proc(cleaned: ^bool) {
                cleaned^ = true
            }, c.cleaned)
            coro.wait(f, 1.0)
        }, c)
    }, &ctx)

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, mutex_is_locked(&m))
    testing.expect_value(t, mutex_owner(&m), h)

    // Cancel while holding lock inside with_mutex: both mutex unlock and chained cleanup must fire
    coro.fiber_cancel(&sched, h)
    testing.expect(t, !mutex_is_locked(&m))
    testing.expect(t, user_cleanup_called)
}

@(test)
test_fiber_semaphore_concurrency_and_abort :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 2, max_permits = 2)
    defer semaphore_destroy(&sem)

    active := 0
    max_obs := 0
    completed := 0

    Worker :: struct {
        sem:       ^Fiber_Semaphore,
        active:    ^int,
        max_obs:   ^int,
        completed: ^int,
    }
    w := Worker{sem = &sem, active = &active, max_obs = &max_obs, completed = &completed}

    for _ in 0 ..< 5 {
        coro.spawn_val(&sched, proc(f: ^coro.Fiber, w: Worker) {
            with_semaphore(f, w.sem, proc(f: ^coro.Fiber, w: Worker) {
                w.active^ += 1
                if w.active^ > w.max_obs^ do w.max_obs^ = w.active^
                coro.wait(f, 0.02)
                w.active^ -= 1
                w.completed^ += 1
            }, w)
        }, w)
    }

    for _ in 0 ..< 15 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, completed, 5)
    testing.expect_value(t, max_obs, 2)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)
}

@(test)
test_channel_rendezvous_and_buffered :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    // 1. Unbuffered Rendezvous (Sender before Receiver)
    unbuf: Channel(int)
    chan_init(&unbuf, 0)
    defer chan_destroy(&unbuf)

    got_unbuf := 0
    Pair :: struct {
        ch:  ^Channel(int),
        out: ^int,
    }
    p := Pair{ch = &unbuf, out = &got_unbuf}

    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Pair) {
        chan_send(f, p.ch, 42)
    }, &p)

    coro.scheduler_step(&sched, 0.01)

    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Pair) {
        v, ok := chan_recv(f, p.ch)
        if ok do p.out^ = v
    }, &p)

    coro.scheduler_step(&sched, 0.01)
    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, got_unbuf, 42)

    // 2. Buffered Ring Wrap-around
    buf: Channel(int)
    chan_init(&buf, 3)
    defer chan_destroy(&buf)

    testing.expect(t, chan_try_send(&buf, 10))
    testing.expect(t, chan_try_send(&buf, 20))
    testing.expect(t, chan_try_send(&buf, 30))
    testing.expect(t, !chan_try_send(&buf, 40))

    v1, ok1 := chan_try_recv(&buf)
    testing.expect(t, ok1 && v1 == 10)
    testing.expect(t, chan_try_send(&buf, 40))

    chan_close(&buf)
    v2, ok2 := chan_try_recv(&buf)
    v3, ok3 := chan_try_recv(&buf)
    v4, ok4 := chan_try_recv(&buf)
    _, ok5 := chan_try_recv(&buf)
    testing.expect(t, ok2 && v2 == 20)
    testing.expect(t, ok3 && v3 == 30)
    testing.expect(t, ok4 && v4 == 40)
    testing.expect(t, !ok5)
}

@(test)
test_channel_timeouts_and_select :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch1, ch2: Channel(int)
    chan_init(&ch1, 2)
    chan_init(&ch2, 2)
    defer chan_destroy(&ch1)
    defer chan_destroy(&ch2)

    timed_out_flag := false
    Pair :: struct {
        ch1: ^Channel(int),
        ch2: ^Channel(int),
        to:  ^bool,
        val: int,
        idx: int,
    }
    state := Pair{ch1 = &ch1, ch2 = &ch2, to = &timed_out_flag}

    coro.spawn(&sched, proc(f: ^coro.Fiber, s: ^Pair) {
        _, _, to := chan_recv_timeout(f, s.ch1, 0.03)
        s.to^ = to

        chs := [2]^Channel(int){s.ch1, s.ch2}
        idx, val, ok := chan_select_recv(f, chs[:])
        if ok {
            s.idx = idx
            s.val = val
        }
    }, &state)

    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect(t, timed_out_flag)

    chan_try_send(&ch2, 99)
    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, state.idx, 1)
    testing.expect_value(t, state.val, 99)
}


@(test)
test_channel_synchronous_rendezvous :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    received_val := 0

    Payload :: struct {
        ch:  ^Channel(int),
        out: ^int,
    }
    payload := Payload{ch = &ch, out = &received_val}

    // Receiver fiber waits on channel
    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Payload) {
        val, ok := chan_recv(f, p.ch)
        if ok {
            p.out^ = val
        }
    }, &payload)

    // Sender fiber sends value
    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Payload) {
        chan_send(f, p.ch, 777)
    }, &payload)

    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, received_val, 777)
}

@(test)
test_channel_buffered_fifo :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 3)
    defer chan_destroy(&ch)

    results: [dynamic]int
    results = make([dynamic]int)
    defer delete(results)

    Payload :: struct {
        ch:  ^Channel(int),
        res: ^[dynamic]int,
    }
    p := Payload{ch = &ch, res = &results}

    // Producer sends 3 items
    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Payload) {
        chan_send(f, p.ch, 10)
        chan_send(f, p.ch, 20)
        chan_send(f, p.ch, 30)
    }, &p)

    // Consumer reads 3 items
    coro.spawn(&sched, proc(f: ^coro.Fiber, p: ^Payload) {
        for _ in 0 ..< 3 {
            val, ok := chan_recv(f, p.ch)
            if ok {
                append(p.res, val)
            }
        }
    }, &p)

    coro.scheduler_step(&sched, 0.016)

    testing.expect_value(t, len(results), 3)
    testing.expect_value(t, results[0], 10)
    testing.expect_value(t, results[1], 20)
    testing.expect_value(t, results[2], 30)
}

@(test)
test_channel_close_and_drain :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(string)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    chan_try_send(&ch, "alpha")
    chan_try_send(&ch, "beta")
    chan_close(&ch)

    // Cannot send to closed channel
    testing.expect_value(t, chan_try_send(&ch, "gamma"), false)

    // Can still drain buffered values
    val1, ok1 := chan_try_recv(&ch)
    testing.expect_value(t, ok1, true)
    testing.expect_value(t, val1, "alpha")

    val2, ok2 := chan_try_recv(&ch)
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, val2, "beta")

    // Empty and closed
    _, ok3 := chan_try_recv(&ch)
    testing.expect_value(t, ok3, false)
}

@(test)
test_channel_ring_buffer_wraparound :: proc(t: ^testing.T) {
    ch: Channel(int)
    chan_init(&ch, capacity = 4)
    defer chan_destroy(&ch)

    testing.expect_value(t, chan_is_empty(&ch), true)
    testing.expect_value(t, chan_is_full(&ch), false)
    testing.expect_value(t, chan_count(&ch), 0)

    // Push 4 items (fills buffer)
    for i in 0 ..< 4 {
        ok := chan_try_send(&ch, (i + 1) * 10)
        testing.expect_value(t, ok, true)
    }

    testing.expect_value(t, chan_is_full(&ch), true)
    testing.expect_value(t, chan_count(&ch), 4)

    // Cannot push into full channel
    testing.expect_value(t, chan_try_send(&ch, 999), false)

    // Stream 1,000 items continuously through 4-slot ring buffer
    for i in 4 ..< 1000 {
        // Pop oldest item
        val, ok := chan_try_recv(&ch)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, (i - 3) * 10)

        // Push new item
        send_ok := chan_try_send(&ch, (i + 1) * 10)
        testing.expect_value(t, send_ok, true)
    }

    // Drain final 4 items
    for i in 996 ..< 1000 {
        val, ok := chan_try_recv(&ch)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, (i + 1) * 10)
    }

    testing.expect_value(t, chan_is_empty(&ch), true)
    testing.expect_value(t, chan_count(&ch), 0)
}

@(test)
test_fiber_semaphore_concurrency_limit :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 2, max_permits = 2)
    defer semaphore_destroy(&sem)

    active_count := 0
    max_observed := 0
    total_completed := 0

    Sem_Worker :: struct {
        sem:             ^Fiber_Semaphore,
        active:          ^int,
        max_obs:         ^int,
        total_comp:      ^int,
    }

    worker_data := Sem_Worker{
        sem        = &sem,
        active     = &active_count,
        max_obs    = &max_observed,
        total_comp = &total_completed,
    }

    for _ in 0 ..< 6 {
        coro.spawn_val(&sched, proc(f: ^coro.Fiber, data: Sem_Worker) {
            semaphore_acquire(f, data.sem)
            data.active^ += 1
            if data.active^ > data.max_obs^ {
                data.max_obs^ = data.active^
            }

            coro.wait(f, 0.02)

            data.active^ -= 1
            semaphore_release(f.sched, data.sem)
            data.total_comp^ += 1
        }, worker_data)
    }

    for _ in 0 ..< 15 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, total_completed, 6)
    testing.expect_value(t, max_observed, 2)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)
}

@(test)
test_fiber_semaphore_try_acquire :: proc(t: ^testing.T) {
    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 1, max_permits = 1)
    defer semaphore_destroy(&sem)

    testing.expect(t, semaphore_try_acquire(&sem))
    testing.expect_value(t, semaphore_available_permits(&sem), 0)
    testing.expect(t, !semaphore_try_acquire(&sem)) // Depleted

    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    semaphore_release(&sched, &sem)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
    testing.expect(t, semaphore_try_acquire(&sem))
}

@(test)
test_chan_try_select_recv :: proc(t: ^testing.T) {
    ch1, ch2, ch3: Channel(int)
    chan_init(&ch1, capacity = 4)
    chan_init(&ch2, capacity = 4)
    chan_init(&ch3, capacity = 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
        chan_destroy(&ch3)
    }

    ch_list := []^Channel(int){&ch1, &ch2, &ch3}

    // All empty -> returns ok = false, ready_index = -1
    idx, val, ok := chan_try_select_recv(ch_list)
    testing.expect(t, !ok)
    testing.expect_value(t, idx, -1)

    // Send item to ch2
    chan_try_send(&ch2, 42)

    idx, val, ok = chan_try_select_recv(ch_list)
    testing.expect(t, ok)
    testing.expect_value(t, idx, 1)
    testing.expect_value(t, val, 42)

    // Now empty again
    idx, val, ok = chan_try_select_recv(ch_list)
    testing.expect(t, !ok)
}

@(test)
test_chan_select_recv_blocking :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch_a, ch_b: Channel(string)
    chan_init(&ch_a, capacity = 4)
    chan_init(&ch_b, capacity = 4)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
    }

    received_idx := -1
    received_val := ""
    received_ok := false

    Select_Env :: struct {
        ch_a: ^Channel(string),
        ch_b: ^Channel(string),
        out_idx: ^int,
        out_val: ^string,
        out_ok:  ^bool,
    }

    env := Select_Env{
        ch_a = &ch_a,
        ch_b = &ch_b,
        out_idx = &received_idx,
        out_val = &received_val,
        out_ok  = &received_ok,
    }

    // Consumer fiber waits on select
    coro.spawn_val(&sched, proc(f: ^coro.Fiber, env: Select_Env) {
        idx, val, ok := chan_select_recv(f, []^Channel(string){env.ch_a, env.ch_b})
        env.out_idx^ = idx
        env.out_val^ = val
        env.out_ok^  = ok
    }, env)

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, !received_ok)

    // Send to ch_b from another fiber
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(string)) {
        coro.wait(f, 0.05)
        chan_send(f, ch, "hello from channel B")
    }, &ch_b)

    for _ in 0 ..< 10 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect(t, received_ok)
    testing.expect_value(t, received_idx, 1)
    testing.expect_value(t, received_val, "hello from channel B")
}

@(test)
test_chan_select_closed_channel :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch1, ch2: Channel(int)
    chan_init(&ch1, capacity = 4)
    chan_init(&ch2, capacity = 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
    }

    received_idx := -1
    received_ok := true

    Select_Close_Env :: struct {
        ch1: ^Channel(int),
        ch2: ^Channel(int),
        out_idx: ^int,
        out_ok:  ^bool,
    }

    env := Select_Close_Env{
        ch1 = &ch1,
        ch2 = &ch2,
        out_idx = &received_idx,
        out_ok  = &received_ok,
    }

    coro.spawn_val(&sched, proc(f: ^coro.Fiber, env: Select_Close_Env) {
        idx, _, ok := chan_select_recv(f, []^Channel(int){env.ch1, env.ch2})
        env.out_idx^ = idx
        env.out_ok^  = ok
    }, env)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, received_idx, -1)

    // Close ch2
    chan_close(&ch2)

    coro.scheduler_step(&sched, 0.01)
    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, received_idx, 1)
    testing.expect(t, !received_ok)
}

@(test)
test_cancel_fiber_waiting_on_semaphore :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 0, max_permits = 2)
    defer semaphore_destroy(&sem)

    acquired := false
    h := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, sem: ^Fiber_Semaphore) {
        semaphore_acquire(f, sem)
    }, &sem)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_waiter_count(&sem), 1)

    // Abort the waiting fiber
    coro.fiber_cancel(&sched, h)

    // Releasing permit should skip the aborted fiber and retain available permits
    semaphore_release(&sched, &sem, 1)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

@(test)
test_cancel_fiber_holding_semaphore_with_cleanup :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 1, max_permits = 1)
    defer semaphore_destroy(&sem)

    Sem_Cleanup_Ctx :: struct { sched: ^coro.Scheduler, sem: ^Fiber_Semaphore }; ctx := Sem_Cleanup_Ctx{sched = &sched, sem = &sem}

    h := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ctx: ^Sem_Cleanup_Ctx) {
        semaphore_acquire(f, ctx.sem)
        coro.fiber_set_cleanup(f, proc(user_data: rawptr) {
            c := (^Sem_Cleanup_Ctx)(user_data)
            semaphore_release(c.sched, c.sem)
        }, ctx)
        coro.wait(f, 5.0)
    }, &ctx)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    // Abort the fiber while holding the permit -> cleanup_proc runs and restores permit!
    coro.fiber_cancel(&sched, h)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

@(test)
test_cancel_fiber_waiting_on_mutex :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    // Holder locks the mutex
    holder := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
        coro.wait(f, 1.0)
        mutex_unlock(f.sched, m)
    }, &m)

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    // Waiter queues on the mutex
    waiter := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
        coro.wait(f, 0.1)
        mutex_unlock(f.sched, m)
    }, &m)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel the waiter
    coro.fiber_cancel(&sched, waiter)

    // Unlock by holder -> should not panic or wake cancelled fiber
    mutex_unlock(&sched, &m)
    testing.expect(t, !m.locked)
}

@(test)
test_multi_channel_select_stress_with_producer_cancellation :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    producer_a_scope: coro.Fiber_Scope
    defer coro.scope_cancel(&sched, &producer_a_scope)

    ch_a, ch_b: Channel(int)
    chan_init(&ch_a, capacity = 10)
    chan_init(&ch_b, capacity = 10)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
    }

    // Producer A: sends 1, 2, 3...
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        for i := 1; i <= 20; i += 1 {
            chan_send(f, ch, i)
            coro.wait(f, 0.02)
        }
    }, &ch_a, scope = &producer_a_scope)

    // Producer B: sends 100, 200, 300...
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        for i := 1; i <= 20; i += 1 {
            chan_send(f, ch, i * 100)
            coro.wait(f, 0.02)
        }
    }, &ch_b)

    Select_Consumer_Ctx :: struct {
        chans:        []^Channel(int),
        items_recv:   int,
        last_val:     int,
    }

    ctx := Select_Consumer_Ctx{
        chans = []^Channel(int){&ch_a, &ch_b},
        items_recv = 0,
        last_val = 0,
    }

    // Consumer fiber selects from both
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Select_Consumer_Ctx) {
        for {
            idx, val, ok := chan_select_recv(f, c.chans)
            if ok {
                c.items_recv += 1
                c.last_val = val
            }
        }
    }, &ctx)

    // Step a few frames
    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.02)
    }
    testing.expect(t, ctx.items_recv >= 2)

    // Cancel Producer A via Scope
    cancelled_a := coro.scope_cancel(&sched, &producer_a_scope)
    testing.expect_value(t, cancelled_a, 1)

    // Consumer should continue receiving from Producer B
    prev_count := ctx.items_recv
    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.02)
    }
    testing.expect(t, ctx.items_recv > prev_count)
}

@(test)
test_semaphore_high_contention_random_cancellations :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 3, max_permits = 3)
    defer semaphore_destroy(&sem)

    completed := 0
    handles: [12]coro.Fiber_Handle

    Sem_Worker_Ctx :: struct {
        sem:       ^Fiber_Semaphore,
        completed: ^int,
        sched:     ^coro.Scheduler,
    }

    ctx := Sem_Worker_Ctx{sem = &sem, completed = &completed, sched = &sched}

    for i in 0 ..< 12 {
        handles[i] = coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Sem_Worker_Ctx) {
            semaphore_acquire(f, c.sem)
            coro.fiber_set_cleanup(f, proc(user_data: rawptr) {
                ctx := (^Sem_Worker_Ctx)(user_data)
                semaphore_release(ctx.sched, ctx.sem)
            }, c)
            coro.wait(f, 0.05)
            semaphore_release(c.sched, c.sem)
            coro.fiber_cleanup_pop(f) // Clear cleanup since released normally
            c.completed^ += 1
        }, &ctx)
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    // Cancel 4 queued/active fibers
    coro.fiber_cancel(&sched, handles[2])
    coro.fiber_cancel(&sched, handles[5])
    coro.fiber_cancel(&sched, handles[7])
    coro.fiber_cancel(&sched, handles[9])

    // Step until all remaining fibers finish
    for _ in 0 ..< 25 {
        coro.scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, completed, 8)
    testing.expect_value(t, semaphore_available_permits(&sem), 3)
}

@(test)
test_mutex_lock_unlock_cancellation_churn :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    completed := 0
    handles: [10]coro.Fiber_Handle

    Mutex_Worker_Ctx :: struct {
        m:         ^Fiber_Mutex,
        completed: ^int,
        sched:     ^coro.Scheduler,
    }

    ctx := Mutex_Worker_Ctx{m = &m, completed = &completed, sched = &sched}

    for i in 0 ..< 10 {
        handles[i] = coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Mutex_Worker_Ctx) {
            mutex_lock(f, c.m)
            coro.fiber_set_cleanup(f, proc(user_data: rawptr) {
                ctx := (^Mutex_Worker_Ctx)(user_data)
                mutex_unlock(ctx.sched, ctx.m)
            }, c)
            coro.wait(f, 0.03)
            mutex_unlock(c.sched, c.m)
            coro.fiber_cleanup_pop(f)
            c.completed^ += 1
        }, &ctx)
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    // Cancel 3 queued waiters
    coro.fiber_cancel(&sched, handles[3])
    coro.fiber_cancel(&sched, handles[6])
    coro.fiber_cancel(&sched, handles[8])

    for _ in 0 ..< 30 {
        coro.scheduler_step(&sched, 0.03)
    }

    testing.expect_value(t, completed, 7)
    testing.expect(t, !m.locked)
}

@(test)
test_chan_destroy_auto_wakes_blocked_receivers :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch := new(Channel(int))
    chan_init(ch, capacity = 0) // Unbuffered rendezvous

    woken_count := 0
    ok_count := 0

    Chan_Unblock_Ctx :: struct {
        ch:    ^Channel(int),
        woken: ^int,
        ok_c:  ^int,
    }

    ctx := Chan_Unblock_Ctx{ch = ch, woken = &woken_count, ok_c = &ok_count}

    for _ in 0 ..< 4 {
        coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Chan_Unblock_Ctx) {
            val, ok := chan_recv(f, c.ch)
            c.woken^ += 1
            if ok do c.ok_c^ += 1
        }, &ctx)
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(ch), 4)

    // Destroying the channel must auto-close and wake all 4 receivers with ok = false
    chan_destroy(ch)
    free(ch)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 4)
    testing.expect_value(t, ok_count, 0)
}

@(test)
test_chan_destroy_auto_wakes_blocked_senders :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch := new(Channel(int))
    chan_init(ch, capacity = 1)

    woken_count := 0
    ok_count := 0

    Chan_Send_Unblock_Ctx :: struct {
        ch:    ^Channel(int),
        woken: ^int,
        ok_c:  ^int,
    }

    ctx := Chan_Send_Unblock_Ctx{ch = ch, woken = &woken_count, ok_c = &ok_count}

    // Fill the buffer
    chan_try_send(ch, 42)

    // Spawn senders that will block
    for _ in 0 ..< 3 {
        coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Chan_Send_Unblock_Ctx) {
            ok := chan_send(f, c.ch, 99)
            c.woken^ += 1
            if ok do c.ok_c^ += 1
        }, &ctx)
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_send_waiter_count(ch), 3)

    // Destroy channel
    chan_destroy(ch)
    free(ch)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 3)
    testing.expect_value(t, ok_count, 0)
}

@(test)
test_chan_recv_timeout_success :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Timeout_Test_Ctx :: struct {
        ch:        ^Channel(int),
        val:       int,
        ok:        bool,
        timed_out: bool,
    }

    ctx := Recv_Timeout_Test_Ctx{ch = &ch}

    // Receiver with 0.5s timeout
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Recv_Timeout_Test_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 0.5)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
    }, &ctx)

    // Delayed producer sends after 0.05s
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        coro.wait(f, 0.05)
        chan_send(f, ch, 777)
    }, &ch)

    for _ in 0 ..< 10 {
        coro.scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, ctx.val, 777)
    testing.expect(t, ctx.ok)
    testing.expect(t, !ctx.timed_out)
}

@(test)
test_chan_recv_timeout_expires :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Timeout_Expire_Ctx :: struct {
        ch:        ^Channel(int),
        val:       int,
        ok:        bool,
        timed_out: bool,
        finished:  bool,
    }

    ctx := Recv_Timeout_Expire_Ctx{ch = &ch}

    // Receiver with 0.05s timeout
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Recv_Timeout_Expire_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 0.05)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
        c.finished = true
    }, &ctx)

    // Step scheduler past 0.05s deadline
    for _ in 0 ..< 8 {
        coro.scheduler_step(&sched, 0.02)
    }

    testing.expect(t, ctx.finished)
    testing.expect(t, !ctx.ok)
    testing.expect(t, ctx.timed_out)
}

@(test)
test_chan_recv_timeout_closed_channel :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(string)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Closed_Ctx :: struct {
        ch:        ^Channel(string),
        val:       string,
        ok:        bool,
        timed_out: bool,
    }

    ctx := Recv_Closed_Ctx{ch = &ch}

    // Receiver waiting with 1.0s timeout
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Recv_Closed_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 1.0)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
    }, &ctx)

    coro.scheduler_step(&sched, 0.01)

    // Close channel mid-coro.wait
    chan_close(&ch)
    coro.scheduler_step(&sched, 0.01)

    testing.expect(t, !ctx.ok)
    testing.expect(t, !ctx.timed_out)
}

@(test)
test_channel_close_multicast_with_interleaved_receivers :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    Chan_Close_Multi_Ctx :: struct {
        ch:    ^Channel(int),
        count: ^int,
    }

    woken_count := 0
    ctxs: [5]Chan_Close_Multi_Ctx

    for i in 0 ..< 5 {
        ctxs[i] = Chan_Close_Multi_Ctx{ch = &ch, count = &woken_count}
        coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Chan_Close_Multi_Ctx) {
            chan_recv(f, c.ch)
            c.count^ += 1
        }, &ctxs[i])
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 5)

    chan_close(&ch)
    coro.scheduler_step(&sched, 0.01)

    testing.expect_value(t, woken_count, 5)
}

@(test)
test_chan_recv_timeout_concurrent_producers :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Chan_Recv_Val_Ctx :: struct {
        ch:  ^Channel(int),
        val: ^int,
    }

    received_val := 0
    ctx := Chan_Recv_Val_Ctx{ch = &ch, val = &received_val}

    // Fast receiver with timeout
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Chan_Recv_Val_Ctx) {
        v, ok, timed_out := chan_recv_timeout(f, c.ch, 0.5)
        if ok do c.val^ = v
    }, &ctx)

    // Producer 1 (0.04s delay)
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        coro.wait(f, 0.04)
        chan_send(f, ch, 111)
    }, &ch)

    // Producer 2 (0.08s delay)
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        coro.wait(f, 0.08)
        chan_send(f, ch, 222)
    }, &ch)

    for _ in 0 ..< 8 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, received_val, 111)
}

@(test)
test_mutex_stale_waiter_abort_immunity :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    F1_Ctx :: struct {
        m:    ^Fiber_Mutex,
        done: bool,
    }
    f1_ctx := F1_Ctx{ m = &m, done = false }

    f2_handle: coro.Fiber_Handle

    F3_Ctx :: struct {
        done: bool,
    }
    f3_ctx := F3_Ctx{ done = false }

    // coro.Fiber 1 holds lock
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, p: ^F1_Ctx) {
        mutex_lock(f, p.m)
        coro.wait(f, 0.04)
        mutex_unlock(f.sched, p.m)
        p.done = true
    }, &f1_ctx)

    // coro.Fiber 2 blocks waiting for lock
    f2_handle = coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
    }, &m)

    // Run 1 frame so f1 locks and f2 suspends into m.waiters
    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel fiber 2 externally while in waiters queue
    coro.fiber_cancel(&sched, f2_handle)
    testing.expect(t, !coro.fiber_is_alive(&sched, f2_handle))

    // coro.Fiber 3 is spawned (recycles fiber slot) and sleeps for 0.10s
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, p: ^F3_Ctx) {
        coro.wait(f, 0.10)
        p.done = true
    }, &f3_ctx)

    // Step past f1's release (0.04s + 0.01s initial = 0.05s)
    for _ in 0 ..< 6 {
        coro.scheduler_step(&sched, 0.01)
    }

    // coro.Fiber 1 finished and unlocked
    testing.expect(t, f1_ctx.done)
    // coro.Fiber 3 should NOT have finished yet (needs 0.10s, only ~0.07s elapsed)
    testing.expect(t, !f3_ctx.done)

    // Step until coro.Fiber 3 completes naturally
    for _ in 0 ..< 8 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect(t, f3_ctx.done)
}

@(test)
test_scoped_mutex_and_semaphore :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 1, 1)
    defer semaphore_destroy(&sem)

    Mutex_Test_Data :: struct {
        m:       ^Fiber_Mutex,
        counter: int,
    }
    m_data := Mutex_Test_Data{ m = &m, counter = 0 }

    // Spawn 2 fibers updating counter via with_mutex
    for _ in 0 ..< 2 {
        coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, d: ^Mutex_Test_Data) {
            with_mutex(f, d.m, proc(f: ^coro.Fiber, data: ^Mutex_Test_Data) {
                coro.wait(f, 0.02)
                data.counter += 1
            }, d)
        }, &m_data)
    }

    // Run until mutex tasks finish
    for _ in 0 ..< 6 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect_value(t, m_data.counter, 2)
    testing.expect(t, !m.locked)

    // Test with_semaphore
    sem_executed := false
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, p: ^struct { sem: ^Fiber_Semaphore, done: ^bool }) {
        with_semaphore(f, p.sem, proc(f: ^coro.Fiber, done: ^bool) {
            coro.wait(f, 0.02)
            done^ = true
        }, p.done)
    }, &struct { sem: ^Fiber_Semaphore, done: ^bool }{ &sem, &sem_executed })

    for _ in 0 ..< 4 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect(t, sem_executed)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

@(test)
test_multi_channel_select :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch1, ch2, ch3: Channel(int)
    chan_init(&ch1, 4)
    chan_init(&ch2, 4)
    chan_init(&ch3, 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
        chan_destroy(&ch3)
    }

    channels := [3]^Channel(int){&ch1, &ch2, &ch3}

    // 1. Try-select on empty channels
    idx, val, ok := chan_try_select_recv(channels[:])
    testing.expect_value(t, ok, false)
    testing.expect_value(t, idx, -1)

    // Push into channel 2
    chan_try_send(&ch2, 42)
    idx, val, ok = chan_try_select_recv(channels[:])
    testing.expect_value(t, ok, true)
    testing.expect_value(t, idx, 1)
    testing.expect_value(t, val, 42)

    // 2. Blocking chan_select_recv in a fiber
    Select_Context :: struct {
        channels:       []^Channel(int),
        received_idx:   int,
        received_val:   int,
        received_ok:    bool,
    }
    ctx := Select_Context{
        channels     = channels[:],
        received_idx = -1,
        received_val = 0,
        received_ok  = false,
    }

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Select_Context) {
        idx, v, ok_recv := chan_select_recv(f, c.channels)
        c.received_idx = idx
        c.received_val = v
        c.received_ok = ok_recv
    }, &ctx)

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, !ctx.received_ok)

    // Producer sends to ch3
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        coro.wait(f, 0.02)
        chan_send(f, ch, 999)
    }, &ch3)

    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect(t, ctx.received_ok)
    testing.expect_value(t, ctx.received_idx, 2)
    testing.expect_value(t, ctx.received_val, 999)
}

@(test)
test_channel_stale_waiter_abort_immunity :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, 0) // Rendezvous
    defer chan_destroy(&ch)

    f_recv_handle := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Channel(int)) {
        chan_recv(f, c)
    }, &ch)

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 1)

    // Cancel receiver while waiting in recv_waiters
    coro.fiber_cancel(&sched, f_recv_handle)

    // Send value to channel - should skip dead waiter and not panic/hang
    sent := chan_try_send(&ch, 100)
    testing.expect(t, !sent)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 0)
}

@(test)
test_with_mutex_val :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    Value_Payload :: struct {
        m:     ^Fiber_Mutex,
        tag:   int,
        delta: f32,
    }

    coro.spawn_val(&sched, proc(f: ^coro.Fiber, p: Value_Payload) {
        with_mutex(f, p.m, proc(f: ^coro.Fiber, val: Value_Payload) {
            coro.wait(f, 0.02)
        }, p)
    }, Value_Payload{m = &m, tag = 10, delta = 5.5})

    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    for _ in 0 ..< 4 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !m.locked)
}

@(test)
test_with_semaphore_val :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 2, 2)
    defer semaphore_destroy(&sem)

    Value_Payload :: struct {
        sem: ^Fiber_Semaphore,
        id:  int,
    }

    // Spawn 2 fibers using with_semaphore_val
    for i in 0 ..< 2 {
        coro.spawn_val(&sched, proc(f: ^coro.Fiber, p: Value_Payload) {
            with_semaphore(f, p.sem, proc(f: ^coro.Fiber, val: Value_Payload) {
                coro.wait(f, 0.02)
            }, p)
        }, Value_Payload{sem = &sem, id = i})
    }

    coro.scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    for _ in 0 ..< 4 {
        coro.scheduler_step(&sched, 0.01)
    }
    testing.expect_value(t, semaphore_available_permits(&sem), 2)
}

@(test)
test_chan_select_recv_multiplexing :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch_a, ch_b, ch_c: Channel(int)
    chan_init(&ch_a, 1)
    chan_init(&ch_b, 1)
    chan_init(&ch_c, 1)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
        chan_destroy(&ch_c)
    }

    Select_Result :: struct {
        idx: int,
        val: int,
        ok:  bool,
    }
    res := Select_Result{idx = -1, val = -1, ok = false}
    channels := [3]^Channel(int){&ch_a, &ch_b, &ch_c}

    // Receiver fiber selects across all 3 channels
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, p: ^struct { chs: []^Channel(int), r: ^Select_Result }) {
        idx, val, ok_recv := chan_select_recv(f, p.chs)
        p.r.idx = idx
        p.r.val = val
        p.r.ok = ok_recv
    }, &struct { chs: []^Channel(int), r: ^Select_Result }{ channels[:], &res })

    // Step 1: coro.Fiber runs and yields since all channels are empty
    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, !res.ok)

    // Producer sends to ch_b
    chan_try_send(&ch_b, 777)

    // Step 2: Receiver receives from ch_b
    coro.scheduler_step(&sched, 0.01)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.idx, 1)
    testing.expect_value(t, res.val, 777)
}

@(test)
test_chan_cap_inspection :: proc(t: ^testing.T) {
    // Unbuffered channel (rendezvous)
    ch_unbuf: Channel(int)
    chan_init(&ch_unbuf, 0)
    defer chan_destroy(&ch_unbuf)

    testing.expect_value(t, chan_cap(&ch_unbuf), 0)
    testing.expect_value(t, chan_count(&ch_unbuf), 0)

    // Buffered channel (capacity 16)
    ch_buf: Channel(f32)
    chan_init(&ch_buf, 16)
    defer chan_destroy(&ch_buf)

    testing.expect_value(t, chan_cap(&ch_buf), 16)
    testing.expect_value(t, chan_count(&ch_buf), 0)
    testing.expect(t, chan_is_empty(&ch_buf))
    testing.expect(t, !chan_is_full(&ch_buf))
}

@(test)
test_chan_recv_timeout_unbuffered_safety :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0) // Unbuffered rendezvous
    defer chan_destroy(&ch)

    timed_out := false
    val_received := 0

    Recv_Ctx :: struct {
        ch:           ^Channel(int),
        timed_out:    ^bool,
        val_received: ^int,
    }
    ctx := Recv_Ctx{ch = &ch, timed_out = &timed_out, val_received = &val_received}

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Recv_Ctx) {
        val, ok, to := chan_recv_timeout(f, c.ch, 0.05)
        c.timed_out^ = to
        if ok do c.val_received^ = val
    }, &ctx)

    // Step scheduler past timeout without providing any sender
    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.02)
    }

    // Must cleanly time out and not hang
    testing.expect(t, timed_out)
    testing.expect_value(t, val_received, 0)
}

@(test)
test_chan_unbuffered_sender_before_receiver :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    Sender_Ctx :: struct {
        ch:   ^Channel(int),
        sent: ^bool,
    }
    sent_flag := false

    // Spawn Sender FIRST (suspends waiting for receiver)
    coro.spawn_val(&sched, proc(f: ^coro.Fiber, ctx: Sender_Ctx) {
        ok := chan_send(f, ctx.ch, 999)
        if ok do ctx.sent^ = true
    }, Sender_Ctx{ch = &ch, sent = &sent_flag})

    // Step once: sender runs and suspends in send_waiters
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, sent_flag, false)
    testing.expect_value(t, chan_count(&ch), 1)

    Recv_Ctx :: struct {
        ch:       ^Channel(int),
        received: int,
        ok:       bool,
    }
    r_ctx := Recv_Ctx{ch = &ch, received = 0, ok = false}

    // Spawn Receiver SECOND
    coro.spawn(&sched, proc(f: ^coro.Fiber, ctx: ^Recv_Ctx) {
        val, ok := chan_recv(f, ctx.ch)
        ctx.received = val
        ctx.ok = ok
    }, &r_ctx)

    // Step scheduler: receiver runs, consumes value, unblocks sender
    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, r_ctx.ok, true)
    testing.expect_value(t, r_ctx.received, 999)
    testing.expect_value(t, chan_count(&ch), 0)
}

@(test)
test_chan_select_unbuffered_with_sender :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch1, ch2: Channel(int)
    chan_init(&ch1, capacity = 0)
    defer chan_destroy(&ch1)
    chan_init(&ch2, capacity = 0)
    defer chan_destroy(&ch2)

    // Sender queues message into unbuffered ch2
    coro.spawn(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 777)
    }, &ch2)

    // Step scheduler so sender pushes into ch2
    coro.scheduler_step(&sched, 0.016)

    // Receiver selects across [ch1, ch2]
    Select_Ctx :: struct {
        channels: [2]^Channel(int),
        idx:      int,
        val:      int,
        ok:       bool,
    }
    ctx := Select_Ctx{channels = {&ch1, &ch2}, idx = -1, val = 0, ok = false}

    coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Select_Ctx) {
        idx, val, ok := chan_select_recv(f, c.channels[:])
        c.idx = idx
        c.val = val
        c.ok = ok
    }, &ctx)

    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ctx.ok, true)
    testing.expect_value(t, ctx.idx, 1)
    testing.expect_value(t, ctx.val, 777)
}

@(test)
test_defensive_semaphore_and_latch_non_positive :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    // Semaphore defensive checks
    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 2, max_permits = 5)
    defer semaphore_destroy(&sem)

    semaphore_release(&sched, &sem, 0)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)

    semaphore_release(&sched, &sem, -3)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)

    // removed latch_count_down
    // removed latch_get_count
}

@(test)
test_chan_unbuffered_multi_sender_rendezvous :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    results: [dynamic]int
    defer delete(results)

    Send_Context :: struct {
        ch:  ^Channel(int),
        val: int,
    }
    s1 := Send_Context{ch = &ch, val = 100}
    s2 := Send_Context{ch = &ch, val = 200}
    s3 := Send_Context{ch = &ch, val = 300}

    // Spawn 3 concurrent senders on unbuffered channel
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s1, name = "Sender 1")

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s2, name = "Sender 2")

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s3, name = "Sender 3")

    Recv_Context :: struct {
        ch:      ^Channel(int),
        results: ^[dynamic]int,
    }
    rctx := Recv_Context{ch = &ch, results = &results}

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ctx: ^Recv_Context) {
        for i := 0; i < 3; i += 1 {
            val, ok := chan_recv(f, ctx.ch)
            if ok {
                append(ctx.results, val)
            }
        }
    }, &rctx, name = "Receiver")

    coro.scheduler_step(&sched, 0.016)

    testing.expect_value(t, len(results), 3)
    if len(results) == 3 {
        testing.expect_value(t, results[0], 100)
        testing.expect_value(t, results[1], 200)
        testing.expect_value(t, results[2], 300)
    }
    testing.expect_value(t, chan_count(&ch), 0)
}

@(test)
test_chan_unbuffered_sender_abort_cleanup :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    sender_h := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 999) // Will suspend waiting for receiver
    }, &ch, name = "Aborting Sender")

    // Step scheduler: sender puts 999 into buffer[0], count = 1, and suspends in send_waiters
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, chan_count(&ch), 1)
    testing.expect_value(t, chan_send_waiter_count(&ch), 1)

    // Abort the sender while waiting in rendezvous
    cancelled := coro.fiber_cancel(&sched, sender_h)
    testing.expect_value(t, cancelled, true)
    // Cleanup proc must reset ch.count = 0 and remove from send_waiters
    testing.expect_value(t, chan_count(&ch), 0)
    testing.expect_value(t, chan_send_waiter_count(&ch), 0)

    // Now coro.spawn a valid sender with 42
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 42)
    }, &ch, name = "Valid Sender")

    received_val := 0
    Recv_Target :: struct {
        ch:  ^Channel(int),
        out: ^int,
    }
    target := Recv_Target{ch = &ch, out = &received_val}
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, t: ^Recv_Target) {
        val, ok := chan_recv(f, t.ch)
        if ok {
            t.out^ = val
        }
    }, &target, name = "Actual Receiver")

    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, received_val, 42)
    testing.expect_value(t, chan_count(&ch), 0)
}

@(test)
test_with_mutex_automatic_abort_cleanup :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    worker2_completed := false

    Worker_Ctx :: struct {
        m:     ^Fiber_Mutex,
        comp:  ^bool,
    }
    ctx := Worker_Ctx{m = &m, comp = &worker2_completed}

    // coro.Fiber 1: Enters with_mutex and sleeps
    h1 := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Worker_Ctx) {
        with_mutex(f, c.m, proc(f: ^coro.Fiber, c: ^Worker_Ctx) {
            coro.wait(f, 10.0) // Long sleep while holding lock
        }, c)
    }, &ctx, name = "Lock Holder")

    // coro.Fiber 2: Waits for the mutex
    h2 := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Worker_Ctx) {
        with_mutex(f, c.m, proc(f: ^coro.Fiber, c: ^Worker_Ctx) {
            c.comp^ = true
        }, c)
    }, &ctx, name = "Lock Waiter")

    coro.scheduler_step(&sched, 0.016)
    testing.expect(t, m.locked)
    testing.expect_value(t, worker2_completed, false)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel fiber 1 while it is holding with_mutex
    // Automatic abort cleanup must unlock m and hand it over to fiber 2!
    coro.fiber_cancel(&sched, h1)
    testing.expect(t, m.locked) // Transferred to fiber 2

    // Step scheduler so fiber 2 executes
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, worker2_completed, true)
    testing.expect_value(t, m.locked, false)
}

@(test)
test_with_semaphore_automatic_abort_cleanup :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 1, 1)
    defer semaphore_destroy(&sem)

    worker2_completed := false

    Sem_Ctx :: struct {
        sem:   ^Fiber_Semaphore,
        comp:  ^bool,
    }
    ctx := Sem_Ctx{sem = &sem, comp = &worker2_completed}

    // coro.Fiber 1 acquires permit via with_semaphore and sleeps
    h1 := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Sem_Ctx) {
        with_semaphore(f, c.sem, proc(f: ^coro.Fiber, c: ^Sem_Ctx) {
            coro.wait(f, 10.0)
        }, c)
    }, &ctx, name = "Permit Holder")

    // coro.Fiber 2 tries to acquire permit via with_semaphore
    h2 := coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Sem_Ctx) {
        with_semaphore(f, c.sem, proc(f: ^coro.Fiber, c: ^Sem_Ctx) {
            c.comp^ = true
        }, c)
    }, &ctx, name = "Permit Waiter")

    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)
    testing.expect_value(t, worker2_completed, false)
    testing.expect_value(t, semaphore_waiter_count(&sem), 1)

    // Abort fiber 1: automatic cleanup hook must restore permit and wake fiber 2
    coro.fiber_cancel(&sched, h1)

    // Step scheduler so fiber 2 acquires permit and completes
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, worker2_completed, true)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

@(test)
test_chan_select_recv_buffered_priority_over_closed :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch_closed: Channel(int)
    chan_init(&ch_closed, 4)
    defer chan_destroy(&ch_closed)

    ch_data: Channel(int)
    chan_init(&ch_data, 4)
    defer chan_destroy(&ch_data)

    // Preload ch_data with values
    chan_try_send(&ch_data, 42)
    chan_try_send(&ch_data, 99)

    // Close ch_closed (empty closed channel)
    chan_close(&ch_closed)

    received_values := make([dynamic]int, context.allocator)
    defer delete(received_values)

    Select_Ctx :: struct {
        chans:    [2]^Channel(int),
        received: ^[dynamic]int,
    }
    ctx := Select_Ctx{
        chans    = {&ch_closed, &ch_data},
        received = &received_values,
    }

    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Select_Ctx) {
        for {
            idx, val, ok := chan_select_recv(f, c.chans[:])
            if !ok {
                break // EOF / closed
            }
            append(c.received, val)
        }
    }, &ctx, name = "Select Consumer")

    // Run until select consumer consumes all buffered messages and exits
    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, len(received_values), 2)
    testing.expect_value(t, received_values[0], 42)
    testing.expect_value(t, received_values[1], 99)
}

@(test)
test_unbuffered_chan_sender_first_rendezvous :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, 0)
    defer chan_destroy(&ch)

    sender_completed := false
    receiver_value := 0
    receiver_ok := false

    Unbuf_Ctx :: struct {
        ch:               ^Channel(int),
        sender_completed: ^bool,
        recv_val:         ^int,
        recv_ok:          ^bool,
    }
    ctx := Unbuf_Ctx{
        ch               = &ch,
        sender_completed = &sender_completed,
        recv_val         = &receiver_value,
        recv_ok          = &receiver_ok,
    }

    // Step 1: Sender runs FIRST before receiver even exists
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Unbuf_Ctx) {
        ok := chan_send(f, c.ch, 777)
        c.sender_completed^ = ok
    }, &ctx, name = "Sender First")

    coro.scheduler_step(&sched, 0.016)

    // Sender should be blocked waiting for receiver rendezvous
    testing.expect_value(t, sender_completed, false)
    testing.expect_value(t, chan_send_waiter_count(&ch), 1)

    // Step 2: Receiver spawns and consumes the rendezvous value
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Unbuf_Ctx) {
        val, ok := chan_recv(f, c.ch)
        c.recv_val^ = val
        c.recv_ok^ = ok
    }, &ctx, name = "Receiver Second")

    coro.scheduler_step(&sched, 0.016)

    // Both sender and receiver must have completed the symmetrical exchange
    testing.expect_value(t, receiver_ok, true)
    testing.expect_value(t, receiver_value, 777)
    testing.expect_value(t, sender_completed, true)
    testing.expect_value(t, chan_send_waiter_count(&ch), 0)
}

@(test)
test_unbuffered_chan_multi_sender_fifo_rendezvous :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, 0)
    defer chan_destroy(&ch)

    received: [dynamic]int
    defer delete(received)

    Multi_Ctx :: struct {
        ch:       ^Channel(int),
        received: ^[dynamic]int,
    }
    ctx := Multi_Ctx{ch = &ch, received = &received}

    Sender_Arg :: struct {
        ch:  ^Channel(int),
        val: int,
    }

    // Spawn 3 senders in order: 100, 200, 300
    vals := [3]int{100, 200, 300}
    for val in vals {
        v := val
        coro.spawn_val(&sched, proc(f: ^coro.Fiber, arg: Sender_Arg) {
            chan_send(f, arg.ch, arg.val)
        }, Sender_Arg{ch = &ch, val = v}, name = "FIFO Sender")
        // Step to let each sender queue up in send_waiters
        coro.scheduler_step(&sched, 0.016)
    }

    // Now coro.spawn receiver that consumes 3 items
    coro.spawn_ptr(&sched, proc(f: ^coro.Fiber, c: ^Multi_Ctx) {
        for _ in 0 ..< 3 {
            v, ok := chan_recv(f, c.ch)
            if ok {
                append(c.received, v)
            }
        }
    }, &ctx, name = "FIFO Receiver")

    for _ in 0 ..< 5 {
        coro.scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, len(received), 3)
    if len(received) == 3 {
        testing.expect_value(t, received[0], 100)
        testing.expect_value(t, received[1], 200)
        testing.expect_value(t, received[2], 300)
    }
}

@(test)
test_semaphore_true_zii_unbounded_permits :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    // True ZII: 0 permits, max_permits = 0 (unbounded mode)
    sem: Fiber_Semaphore
    acquired_count := 0

    Acquire_Ctx :: struct {
        sem:   ^Fiber_Semaphore,
        count: ^int,
    }
    ctx := Acquire_Ctx{sem = &sem, count = &acquired_count}

    for i in 0 ..< 5 {
        coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Acquire_Ctx) {
            semaphore_acquire(f, c.sem)
            c.count^ += 1
        }, &ctx, name = "ZII Sem Consumer")
    }

    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, acquired_count, 0)
    testing.expect_value(t, coro.wait_queue_count(&sem.waiters), 5)

    // Release 3 permits
    semaphore_release(&sched, &sem, 3)
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, acquired_count, 3)
    testing.expect_value(t, coro.wait_queue_count(&sem.waiters), 2)

    // Release 2 more permits
    semaphore_release(&sched, &sem, 2)
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, acquired_count, 5)
    testing.expect_value(t, coro.wait_queue_count(&sem.waiters), 0)
}

@(test)
test_mutex_owner_tracking_and_unlock_safety :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    m: Fiber_Mutex
    testing.expect_value(t, mutex_owner(&m), 0)
    testing.expect_value(t, mutex_is_locked(&m), false)

    step_log: [dynamic]int
    step_log = make([dynamic]int, context.allocator)
    defer delete(step_log)

    Mutex_Test_Ctx :: struct {
        m:        ^Fiber_Mutex,
        step_log: ^[dynamic]int,
        id:       int,
    }

    ctx1 := Mutex_Test_Ctx{m = &m, step_log = &step_log, id = 1}
    ctx2 := Mutex_Test_Ctx{m = &m, step_log = &step_log, id = 2}

    h1 := coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Mutex_Test_Ctx) {
        mutex_lock(f, c.m)
        append(c.step_log, c.id * 10 + 1)
        coro.yield(f)
        append(c.step_log, c.id * 10 + 2)
        mutex_unlock(f.sched, c.m)
    }, &ctx1, name = "Mutex Owner 1")

    h2 := coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Mutex_Test_Ctx) {
        mutex_lock(f, c.m)
        append(c.step_log, c.id * 10 + 1)
        coro.yield(f)
        append(c.step_log, c.id * 10 + 2)
        mutex_unlock(f.sched, c.m)
    }, &ctx2, name = "Mutex Owner 2")

    // Frame 1: coro.Fiber 1 locks mutex and yields
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, mutex_is_locked(&m), true)
    testing.expect_value(t, mutex_owner(&m), h1)
    testing.expect_value(t, len(step_log), 1)
    testing.expect_value(t, step_log[0], 11)

    // Frame 2: coro.Fiber 1 finishes and unlocks; lock passes to coro.Fiber 2
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, mutex_is_locked(&m), true)
    testing.expect_value(t, mutex_owner(&m), h2)

    // Frame 3: coro.Fiber 2 finishes and unlocks
    coro.scheduler_step(&sched, 0.016)
    testing.expect_value(t, mutex_is_locked(&m), false)
    testing.expect_value(t, mutex_owner(&m), 0)
    testing.expect_value(t, len(step_log), 4)
    testing.expect_value(t, step_log[0], 11)
    testing.expect_value(t, step_log[1], 12)
    testing.expect_value(t, step_log[2], 21)
    testing.expect_value(t, step_log[3], 22)
}

@(test)
test_chan_send_timeout_success_and_expiry :: proc(t: ^testing.T) {
    sched: coro.Scheduler
    coro.scheduler_init(&sched)
    defer coro.scheduler_destroy(&sched)

    // Unbuffered channel with no receiver -> send must time out after 0.05s
    ch: Channel(int)
    chan_init(&ch, 0)
    defer chan_destroy(&ch)

    timed_out_flag := false
    send_ok_flag := true

    Send_Ctx :: struct {
        ch:        ^Channel(int),
        timed_out: ^bool,
        send_ok:   ^bool,
    }
    ctx := Send_Ctx{ch = &ch, timed_out = &timed_out_flag, send_ok = &send_ok_flag}

    coro.spawn(&sched, proc(f: ^coro.Fiber, c: ^Send_Ctx) {
        ok, timed_out := chan_send_timeout(f, c.ch, 42, 0.05)
        c.send_ok^ = ok
        c.timed_out^ = timed_out
    }, &ctx, name = "Timeout Sender")

    // Run past 0.05s timeout
    for _ in 0 ..< 10 {
        coro.scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, timed_out_flag, true)
    testing.expect_value(t, send_ok_flag, false)
}


