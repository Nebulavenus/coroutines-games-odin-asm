# Tutorial 1: Getting Started — Hello Coroutines & Basic Yields

Welcome to the **Odin Stackful Coroutine Tutorial Series**! This foundational chapter walks you step-by-step through the concepts, memory model, and primitives required to write straight-line asynchronous gameplay code using native stackful coroutines in [Odin](https://odin-lang.org/).

---

## 1. The Core Mental Model

In traditional game development, asynchronous sequences (such as opening a door, playing an animation, waiting 2 seconds, and spawning an enemy) are written using:
1. **Callback spaghetti:** Chained procedures that destroy readability.
2. **State machines:** Enums with large `switch` statements updated each frame.
3. **Timer polling:** Checking `timer += dt` manually in entity update loops.

With **stackful coroutines**, you write code that reads sequentially from top to bottom. When you call a yield primitive (like `coroutine.wait`), execution seamlessly pauses and returns control to the engine loop. When the timer expires, the fiber resumes execution at the exact line it paused, preserving all local variables and call stacks.

```
       Engine Frame Loop                             Coroutine Fiber
 ┌───────────────────────────┐                 ┌───────────────────────────┐
 │ 1. Process Input          │                 │                           │
 │ 2. scheduler_step(&sched) │ ──────────────► │ fmt.println("Opening...") │
 │                           │                 │ coroutine.wait(f, 2.0)    │
 │ 3. Render Frame           │ ◄────────────── │ (Suspends execution)      │
 │ 4. (Frames pass by...)    │                 │                           │
 │ 5. (After 2.0s elapsed)   │                 │                           │
 │ 6. scheduler_step(&sched) │ ──────────────► │ fmt.println("Resumed!")   │
 └───────────────────────────┘                 └───────────────────────────┘
```

---

## 2. Complete Runnable Example

Here is a complete, copy-pasteable program demonstrating the engine lifecycle:

```odin
package main

import "core:fmt"
import "coroutine"

main :: proc() {
    // 1. Initialize the Scheduler
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // 2. Spawn a Root Coroutine Fiber
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.println("[Step 1] Fiber started execution!")

        // Delay for 1.0 simulation seconds
        coroutine.wait(f, 1.0)
        fmt.println("[Step 2] Resumed after 1.0s of simulation time!")

        // Yield for 3 consecutive engine frames
        coroutine.wait_frames(f, 3)
        fmt.println("[Step 3] Resumed after waiting 3 frames!")

        // Yield for a single frame
        coroutine.yield_frame(f)
        fmt.println("[Step 4] Final step executed! Fiber finishing naturally.")
    })

    // 3. Drive the Game Loop with Delta Time
    dt: f32 = 0.5
    for i := 0; i < 6; i += 1 {
        fmt.printf("\n--- Engine Tick %d (sim_time: %.2fs) ---\n", i, sched.clock.sim_time)
        coroutine.scheduler_step(&sched, dt)
    }
}
```

### Expected Output Breakdown
```
--- Engine Tick 0 (sim_time: 0.00s) ---
[Step 1] Fiber started execution!

--- Engine Tick 1 (sim_time: 0.50s) ---

--- Engine Tick 2 (sim_time: 1.00s) ---
[Step 2] Resumed after 1.0s of simulation time!

--- Engine Tick 3 (sim_time: 1.50s) ---

--- Engine Tick 4 (sim_time: 2.00s) ---

--- Engine Tick 5 (sim_time: 2.50s) ---
[Step 3] Resumed after waiting 3 frames!
[Step 4] Final step executed! Fiber finishing naturally.
```

---

## 3. Comprehensive Suspension Primitives Reference

The engine provides 6 fundamental yield primitives to pause execution:

| Primitive | Description | Typical Use Case |
| :--- | :--- | :--- |
| **`coroutine.wait(f, seconds: f64)`** | Sleeps for $N$ seconds in **simulation time**. Halts if `sched.is_paused = true`. | Combat cooldowns, spell casting, entity timelines. |
| **`coroutine.wait_real(f, seconds: f64)`** | Sleeps for $N$ seconds in **unpaused wall-clock time**. Continues ticking when paused. | Pause menu animations, UI banners, HUD notifications. |
| **`coroutine.yield_frame(f)`** | Suspends execution until the next scheduler step. | Per-frame physics updates, continuous motion loops. |
| **`coroutine.wait_frames(f, count: u64)`** | Suspends execution for exactly $N$ consecutive engine frames. | Frame-accurate invulnerability windows, hit-stop. |
| **`coroutine.wait_until(f, cond_proc, data)`** | Suspends and re-evaluates the boolean predicate every frame until `true`. | Waiting for player health drop, objective triggers. |
| **`coroutine.wait_while(f, cond_proc, data)`** | Suspends and continues waiting as long as the predicate remains `true`. | Waiting while enemy is stunned or frozen. |

---

## 4. Local Variables & Stack Isolation

Because every fiber has a real 32 KB stack (not an emulated state machine), local variables, nested loops, recursion, and stack allocations remain fully preserved across yields:

```odin
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
    // Standard local variables on the fiber's stack
    counter := 0
    names := [3]string{"Warrior", "Mage", "Rogue"}

    for name in names {
        fmt.printf("Spawning hero %d: %s\n", counter, name)
        counter += 1
        
        // Pauses execution inside the loop!
        coroutine.wait(f, 0.5)

        // Resumes with all variables ('counter', 'name', 'names') 100% intact!
        fmt.printf("Hero %s is ready for battle!\n", name)
    }
})
```

---

## 5. Isolated Temporary Allocator (`context.temp_allocator`)

In standard Odin, `context.temp_allocator` is a global ring buffer reset at the end of every frame. In a coroutine engine, yielding across frames would normally overwrite temporary memory.

### The Engine's Embedded Arena Solution
- Every `Fiber` contains an embedded 4KB `mem.Arena`.
- When a fiber is scheduled, `context.temp_allocator` is automatically bound to the fiber's isolated arena.
- Temporary allocations created within a fiber survive across multiple `yield_frame`, `wait`, or `sync` suspensions!

```odin
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
    // Allocated on the fiber's private 4KB temporary arena
    buffer := make([]int, 32, context.temp_allocator)
    buffer[0] = 1337

    coroutine.wait(f, 1.0)

    // Perfectly safe! No cross-coroutine memory corruption!
    fmt.println("buffer[0] survived the yield:", buffer[0])
})
```

---

## 6. Common Pitfalls & Best Practices

> [!CAUTION]
> **Infinite Loop Without Yield:**
> Never write `for { /* heavy work */ }` without calling a yield primitive (`coroutine.yield_frame` or `coroutine.wait`). Because coroutines are cooperative, a fiber that never yields will hang the main thread permanently.

> [!TIP]
> **Stack Size Awareness:**
> The default stack size is 32 KB per fiber. Avoid allocating huge stack buffers like `large_buffer: [100000]f32`. For large datasets, allocate on the heap or pass pointers.

---

## Next Steps
In [Tutorial 2: State & Parameter Passing](02_parameter_passing.md), you will learn how to pass data to coroutines safely using entity pointers and the 128-byte inline payload buffer.
