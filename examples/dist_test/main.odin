package main

import "core:fmt"
import coroutine "../../dist"

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

	// Producer fiber
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

	// Consumer fiber
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, data: ^Consumer_Data) {
		v, ok := coroutine.event_wait(f, data.ev)
		if ok {
			data.val^ = v
			data.executed^ = true
		}
	}, &consumer_data)

	for step in 0..<10 {
		coroutine.scheduler_step(&sched, 0.016)
		if executed do break
	}

	assert(executed, "Consumer fiber did not complete")
	assert(received_val == 42, "Received unexpected value from event")

	// Validate branch_scoped and Sticky_Signal in amalgamated dist:
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

	// Validate Verse Task(T), spawn_task, and task_await in amalgamated dist:
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

	// Validate sync_with in amalgamated dist:
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

	fmt.printf("[dist_test] SUCCESS: Amalgamated coroutine.odin verified! (received %d, scoped: %t, task: %d, sync: %t)\n", received_val, scoped_ran, task_res, sync_a && sync_b)
}
