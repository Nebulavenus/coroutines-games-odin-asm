# Tutorial 6: Offloading Heavy Compute — Bridging OS Threads with `await_async`

In high-performance game development, heavy computational workloads (such as A* pathfinding across 100,000 nodes, procedural terrain mesh generation, or asset decompression) will cause severe frame drops if executed on the main rendering thread.

This chapter explains how to bridge multi-core OS background threads to main-thread coroutines using `await_async` and `Async_Token`.

---

## 1. The Multi-Threaded Coroutine Bridge

```
 Main Thread (Scheduler & 144 FPS Render Loop)    OS Worker Thread Pool (core:thread)
┌───────────────────────────────────────────┐   ┌────────────────────────────────────┐
│ 1. Coroutine AI decides to pathfind       │   │                                    │
│ 2. Dispatches task to worker pool         │ ─►│ 3. Computes 50,000 A* Nodes        │
│ 4. Calls coroutine.await_async(f, &token) │   │    (Takes 15ms of CPU time)        │
│    (Fiber suspends!)                      │   │                                    │
│ 5. (Main thread continues rendering!)     │   │ 6. Writes result into token        │
│ 7. Scheduler detects token.done == true   │ ◄─│ 8. atomic_store(&token.done, true) │
│ 9. Resumes AI Fiber on Main Thread!       │   └────────────────────────────────────┘
└───────────────────────────────────────────┘
```

---

## 2. Complete Runnable Example

```odin
package main

import "core:fmt"
import "core:thread"
import "core:time"
import "coroutine"

Path_Result :: struct {
    waypoints: [4][2]f32,
    count:     int,
}

Pathfind_Job :: struct {
    token:  coroutine.Async_Token,
    start:  [2]f32,
    goal:   [2]f32,
    result: Path_Result,
}

// Background Worker Thread Procedure (Runs on OS Thread)
pathfinder_worker_thread :: proc(raw_data: rawptr) {
    job := cast(^Pathfind_Job)raw_data

    // Simulate heavy compute (e.g. 50ms of intense graph exploration)
    time.sleep(50 * time.Millisecond)

    job.result.count = 3
    job.result.waypoints[0] = job.start
    job.result.waypoints[1] = { (job.start.x + job.goal.x) / 2.0, job.start.y + 50.0 }
    job.result.waypoints[2] = job.goal

    // Mark completed atomically!
    coroutine.async_token_complete(&job.token, &job.result)
}

// Main-Thread Coroutine Procedure
unit_ai_behavior :: proc(f: ^coroutine.Fiber, job: ^Pathfind_Job) {
    fmt.Println("[AI] Unit reached obstacle. Dispatching background A* pathfinder...")

    // Dispatch OS worker thread
    t := thread.create_and_start_with_data(job, pathfinder_worker_thread)
    defer thread.destroy(t)

    // Suspends fiber until background worker completes!
    coroutine.await_async(f, &job.token)

    fmt.Printf("[AI] Path calculated! Found %d waypoints. Resuming unit movement!\n", job.result.count)
    for i := 0; i < job.result.count; i += 1 {
        fmt.printf("  Waypoint %d: (%.1f, %.1f)\n", i, job.result.waypoints[i].x, job.result.waypoints[i].y)
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    job := Pathfind_Job{
        start = {0.0, 0.0},
        goal  = {500.0, 300.0},
    }

    coroutine.spawn_ptr(&sched, unit_ai_behavior, &job)

    // Simulate 10 frames of main thread rendering while worker runs in background
    for i := 0; i < 10; i += 1 {
        coroutine.scheduler_step(&sched, 0.016)
        time.sleep(10 * time.Millisecond)
    }
}
```

---

## 3. Why This Is Superior to Callbacks

1. **Local State Preservation:** All local variables, current loops, and execution stack frames remain valid across the suspension point.
2. **Zero OS Thread Contention:** Fibers run cooperatively on the main thread; worker threads run in background pools. No mutex locks required during frame rendering.
3. **No Garbage Collection:** `Async_Token` is allocated in the entity or job struct with zero heap fragmentation.

---

## Next Steps
In [Tutorial 7: Stateful Iterators](07_stateful_generators.md), you will learn how to build lazy procedural iterators using `Generator(T)`.
