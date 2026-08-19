package main

import "core:fmt"
import "coroutine"

main :: proc() {
    fmt.println("1: Initializing scheduler")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    ran := false
    fmt.println("2: Spawning fiber")
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, p: ^bool) {
        fmt.println("3: Inside fiber!")
        p^ = true
        fmt.println("4: Fiber exiting")
    }, &ran)

    fmt.println("5: Calling scheduler_step")
    coroutine.scheduler_step(&sched, 0.016)
    fmt.println("6: Finished scheduler_step, ran =", ran)
}