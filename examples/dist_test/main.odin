package main

import "core:fmt"
import coroutine "../../dist"
import sync "../../dist/sync"

main :: proc() {
	fmt.println("[dist_test] Initializing scheduler from amalgamated dist/coroutine.odin...")
	sched: coroutine.Scheduler
	coroutine.scheduler_init(&sched)
	defer coroutine.scheduler_destroy(&sched)

	ev: coroutine.Event(int)
	coroutine.event_init(&ev)
	defer coroutine.event_destroy(&ev)

	executed := false
	received_val := 0

	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ev_ptr: ^coroutine.Event(int)) {
		coroutine.yield(f)
		coroutine.event_emit(f.sched, ev_ptr, 42)
	}, &ev)

	Consumer_Data :: struct {
		ev: ^coroutine.Event(int),
		executed: ^bool,
		val: ^int,
	}

	consumer_data := Consumer_Data{&ev, &executed, &received_val}

	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, data: ^Consumer_Data) {
		v, ok := coroutine.event_wait(f, data.ev)
		if ok {
			data.val^ = v
			data.executed^ = true
		}
	}, &consumer_data)

	for _ in 0..<10 {
		coroutine.scheduler_step(&sched, 0.016)
		if executed do break
	}

	assert(executed, "Consumer fiber did not complete")
	assert(received_val == 42, "Received unexpected value from event")

	sticky_sig: coroutine.Sticky_Signal
	coroutine.sticky_signal_emit(&sched, &sticky_sig)

	scoped_ran := false
	Scoped_Data :: struct {
		sig: ^coroutine.Sticky_Signal,
		ran: ^bool,
	}
	scoped_data := Scoped_Data{&sticky_sig, &scoped_ran}

	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, d: ^Scoped_Data) {
		coroutine.sticky_signal_wait(f, d.sig)
		coroutine.branch_scoped(f, proc(child: ^coroutine.Fiber, ran: ^bool) {
			ran^ = true
		}, d.ran)
		coroutine.yield(f)
	}, &scoped_data)

	for _ in 0..<5 {
		coroutine.scheduler_step(&sched, 0.016)
	}
	assert(scoped_ran, "branch_scoped and Sticky_Signal must work in amalgamated dist")

	task: coroutine.Task(int)
	task_res := 0
	Task_Ctx :: struct {
		task: ^coroutine.Task(int),
		res:  ^int,
	}
	t_ctx := Task_Ctx{&task, &task_res}
	coroutine.spawn_task(&sched, &task, proc(f: ^coroutine.Fiber) -> int {
		coroutine.yield(f)
		return 100
	})
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ctx: ^Task_Ctx) {
		val, ok := coroutine.task_await(f, ctx.task)
		if ok do ctx.res^ = val
	}, &t_ctx)

	sync_a, sync_b := false, false
	Sync_Pair :: struct { a: ^bool, b: ^bool }
	sp := Sync_Pair{&sync_a, &sync_b}
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, sp: ^Sync_Pair) {
		coroutine.sync_with(f, sp,
			proc(child: ^coroutine.Fiber, sp: ^Sync_Pair) { sp.a^ = true },
			proc(child: ^coroutine.Fiber, sp: ^Sync_Pair) { sp.b^ = true },
		)
	}, &sp)

	for _ in 0..<5 {
		coroutine.scheduler_step(&sched, 0.016)
	}
	assert(task_res == 100, "spawn_task and task_await must work in amalgamated dist")
	assert(sync_a && sync_b, "sync_with must work in amalgamated dist")

	ch_int: sync.Channel(int)
	ch_str: sync.Channel(string)
	sync.chan_init(&ch_int, 2)
	sync.chan_init(&ch_str, 2)
	defer {
		sync.chan_destroy(&ch_int)
		sync.chan_destroy(&ch_str)
	}

	Hetero_Ctx :: struct {
		ch_int:  ^sync.Channel(int),
		ch_str:  ^sync.Channel(string),
		got_str: string,
		winner:  int,
	}
	h_ctx := Hetero_Ctx{ch_int = &ch_int, ch_str = &ch_str, winner = -1}
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, c: ^Hetero_Ctx) {
		local_int := 0
		local_str := ""
		c.winner = coroutine.race(f,
			sync.branch_chan_recv(c.ch_int, &local_int),
			sync.branch_chan_recv(c.ch_str, &local_str),
			coroutine.branch_wait(1.0),
		)
		c.got_str = local_str
	}, &h_ctx)

	coroutine.scheduler_step(&sched, 0.016)
	sync.chan_try_send(&ch_str, "hello-dist-sync")
	coroutine.scheduler_step(&sched, 0.016)
	assert(h_ctx.winner == 1 && h_ctx.got_str == "hello-dist-sync", "dist/sync heterogeneous branch_chan_recv must work")

	paused_ran := false
	coroutine.clock_set_paused(&sched, coroutine.CLOCK_SIM, true)
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ran: ^bool) {
		ran^ = true
	}, &paused_ran)
	coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, 0.016)
	coroutine.scheduler_run(&sched)
	assert(!paused_ran, "Paused CLOCK_SIM must not run while CLOCK_REAL runs")
	coroutine.clock_set_paused(&sched, coroutine.CLOCK_SIM, false)
	coroutine.scheduler_step(&sched, 0.016)
	assert(paused_ran, "Unpaused CLOCK_SIM fiber must run cleanly")

	trace_spawns := 0
	coroutine.scheduler_set_trace_hook(&sched, proc(ev: coroutine.Trace_Event, f: ^coroutine.Fiber, ud: rawptr) {
		if f != nil && ev == .Spawn {
			(^int)(ud)^ += 1
		}
	}, &trace_spawns)
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
		coroutine.yield(f)
	})
	coroutine.scheduler_step(&sched, 0.016)
	coroutine.scheduler_step(&sched, 0.016)
	coroutine.scheduler_set_trace_hook(&sched, nil, nil)
	assert(trace_spawns == 1, "Trace hook must fire in amalgamated dist")

	fut: coroutine.Async_Future(int)
	fut_cancel: coroutine.Async_Future(int)
	coroutine.async_init(&fut)
	coroutine.async_init(&fut_cancel)
	fut_val := 0
	child_task_val := 0
	child_aborted := 0
	scoped_from_fiber_ran := false
	m: sync.Fiber_Mutex
	sync.mutex_init(&m)
	defer sync.mutex_destroy(&m)
	sem: sync.Fiber_Semaphore
	sync.semaphore_init(&sem, 1, 1)
	defer sync.semaphore_destroy(&sem)
	fiber_scope: coroutine.Fiber_Scope
	defer coroutine.scope_destroy(&sched, &fiber_scope)

	Fut_Ctx :: struct {
		fut:        ^coroutine.Async_Future(int),
		fut_cancel: ^coroutine.Async_Future(int),
		out:        ^int,
		task_out:   ^int,
		aborted:    ^int,
		scope:      ^coroutine.Fiber_Scope,
		scoped_ran: ^bool,
		m:          ^sync.Fiber_Mutex,
		sem:        ^sync.Fiber_Semaphore,
		m_expired:  bool,
		s_expired:  bool,
	}
	f_ctx := Fut_Ctx{
		fut        = &fut,
		fut_cancel = &fut_cancel,
		out        = &fut_val,
		task_out   = &child_task_val,
		aborted    = &child_aborted,
		scope      = &fiber_scope,
		scoped_ran = &scoped_from_fiber_ran,
		m          = &m,
		sem        = &sem,
		m_expired  = true,
		s_expired  = true,
	}
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, c: ^Fut_Ctx) {
		coroutine.fiber_defer(f, proc() {})
		v, ok := coroutine.await_async(f, c.fut)
		if ok do c.out^ = v

		dummy := 0
		w := coroutine.race(f,
			coroutine.branch_async(c.fut_cancel, &dummy),
			coroutine.branch_wait(0.02),
		)
		assert(w == 1 && coroutine.async_is_cancelled(c.fut_cancel), "Async_Future cancel must propagate in dist")

		local_tk: coroutine.Task(int)
		coroutine.spawn_task(f, &local_tk, proc(child: ^coroutine.Fiber) -> int {
			coroutine.yield(child)
			return 222
		})
		tv, tok := coroutine.task_await(f, &local_tk)
		if tok do c.task_out^ = tv

		coroutine.spawn(f, proc(child: ^coroutine.Fiber, flag: ^bool) {
			flag^ = true
		}, c.scoped_ran, c.scope)

		assert(sync.mutex_try_lock(f, c.m), "Hold mutex in dist")
		assert(sync.semaphore_try_acquire(c.sem), "Hold sem in dist")
		c.m_expired = sync.mutex_lock_timeout(f, c.m, 0.02)
		c.s_expired = sync.semaphore_acquire_timeout(f, c.sem, 0.02)
		sync.mutex_unlock(c.m)
		sync.semaphore_release(c.sem)
	}, &f_ctx)

	h_abort := coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, c: ^Fut_Ctx) {
		local_tk: coroutine.Task(int)
		coroutine.spawn_task(f, &local_tk, proc(child: ^coroutine.Fiber, c: ^Fut_Ctx) -> int {
			coroutine.fiber_defer(child, proc(c: ^Fut_Ctx) {
				c.aborted^ += 1
			}, c)
			coroutine.wait(child, 5.0)
			return 0
		}, c)
		_, _ = coroutine.task_await(f, &local_tk)
	}, &f_ctx)

	coroutine.scheduler_step(&sched, 0.016)
	coroutine.fiber_cancel(&sched, h_abort)
	assert(child_aborted == 1, "Child-scoped Task(int) must abort when parent cancels in dist")

	coroutine.async_complete(&fut, 777)
	for _ in 0 ..< 10 {
		coroutine.scheduler_step(&sched, 0.016)
	}
	assert(fut_val == 777, "Async_Future(T) must deliver typed value in dist")
	assert(child_task_val == 222, "Child-scoped stack-local Task(int) must complete in dist")
	assert(scoped_from_fiber_ran, "spawn(f, ..., scope) must run in dist")
	assert(!f_ctx.m_expired && !f_ctx.s_expired, "mutex/sem timeouts must expire cleanly in dist")

	tch: sync.Thread_Channel(int)
	sync.thread_chan_init(&tch, 4)
	defer sync.thread_chan_destroy(&tch)
	tch_val := 0
	Tch_Ctx :: struct {
		ch:     ^sync.Thread_Channel(int),
		out:    ^int,
		winner: int,
	}
	tc_ctx := Tch_Ctx{ch = &tch, out = &tch_val, winner = -1}
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, c: ^Tch_Ctx) {
		local_v := 0
		c.winner = coroutine.race(f,
			sync.branch_thread_chan_recv(c.ch, &local_v),
			coroutine.branch_wait(1.0),
		)
		c.out^ = local_v
	}, &tc_ctx)
	coroutine.scheduler_step(&sched, 0.016)
	assert(sync.thread_chan_try_send(&tch, 888), "thread_chan_try_send must succeed")
	coroutine.scheduler_step(&sched, 0.016)
	assert(tc_ctx.winner == 0 && tch_val == 888, "branch_thread_chan_recv must wake fiber and deliver value in dist")

	fmt.printf("[dist_test] SUCCESS: Amalgamated dist/coroutine.odin + dist/sync/sync.odin verified! (received %d, scoped: %t, task: %d, sync: %t, hetero: %s, async: %d, tchan: %d)\n", received_val, scoped_ran, task_res, sync_a && sync_b, h_ctx.got_str, fut_val, tch_val)
}
