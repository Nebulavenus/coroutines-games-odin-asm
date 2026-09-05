package main

import "core:fmt"
import coroutine "../../dist"

main :: proc() {
	fmt.println("[dist_test] Initializing scheduler from amalgamated dist/coroutine.odin...")
	sched: coroutine.Scheduler
	coroutine.scheduler_init(&sched)
	defer coroutine.scheduler_destroy(&sched)

	ch: coroutine.Channel(int)
	coroutine.chan_init(&ch, 2)
	defer coroutine.chan_destroy(&ch)

	executed := false
	received_val := 0

	// Producer fiber
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ch_ptr: ^coroutine.Channel(int)) {
		coroutine.yield_frame(f)
		coroutine.chan_send(f, ch_ptr, 42)
	}, &ch)

	Consumer_Data :: struct {
		ch: ^coroutine.Channel(int),
		executed: ^bool,
		val: ^int,
	}

	consumer_data := Consumer_Data{&ch, &executed, &received_val}

	// Consumer fiber
	coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, data: ^Consumer_Data) {
		v, ok := coroutine.chan_recv(f, data.ch)
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
	assert(received_val == 42, "Received unexpected value from channel")

	fmt.printf("[dist_test] SUCCESS: Amalgamated coroutine.odin verified! (received %d)\n", received_val)
}
