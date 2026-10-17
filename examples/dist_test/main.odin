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

	fmt.printf("[dist_test] SUCCESS: Amalgamated coroutine.odin verified! (received %d)\n", received_val)
}
