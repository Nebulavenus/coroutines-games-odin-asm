# Tutorial 2: State & Parameter Passing — Pointers vs. 128B Inline Payloads

Coroutines often require parameters from the caller—such as references to enemy entities, player coordinates, or transient spell configurations. This chapter explains how to pass data safely without memory leaks, dangling pointers, or heap allocation overhead.

---

## 1. The Asynchronous Pointer Dilemma

In synchronous programming, passing a pointer to a local variable is completely safe because the caller's stack frame remains alive until the callee returns.

In **asynchronous coroutines**, a procedure spawns a fiber and returns immediately. If you pass a pointer to a local variable on the caller's stack, the caller function returns, pops its stack frame, and leaves the coroutine pointing to garbage memory:

```odin
// DANGEROUS ANTI-PATTERN:
trigger_fireball :: proc(sched: ^coroutine.Scheduler) {
    origin := [2]f32{100.0, 200.0} // Local variable on stack

    // BUG: 'origin' will be destroyed when trigger_fireball returns!
    coroutine.spawn_ptr(sched, proc(f: ^coroutine.Fiber, pos: ^[2]f32) {
        coroutine.wait(f, 1.0)
        fmt.println("Position:", pos^) // CRASH: Reads corrupted stack memory!
    }, &origin)
}
```

To solve this problem elegantly, the engine provides two distinct parameter-passing strategies, unified under Odin's overloaded **`coroutine.spawn`** procedure group (`proc{spawn_ptr, spawn_val, spawn_nil}`):
1. **Strategy A: Pointer Passing (`spawn_ptr` / `spawn`)** for long-lived entities.
2. **Strategy B: By-Value 128-Byte Inline Copy (`spawn_val` / `spawn`)** for transient parameters.

---

## 2. Strategy A: Pointer Passing (`spawn_ptr` / `spawn`)

Use pointer passing when the target entity is long-lived and guaranteed to outlive the coroutine (for example, a `Boss`, `Player`, or `Game_World` allocated on the heap or in a global arena):

```odin
package main

import "core:fmt"
import "coroutine"

Boss :: struct {
    name:     string,
    hp:       int,
    position: [2]f32,
}

boss_ai_timeline :: proc(f: ^coroutine.Fiber, boss: ^Boss) {
    fmt.printf("[AI] %s initialized at (%.1f, %.1f) with %d HP\n",
        boss.name, boss.position.x, boss.position.y, boss.hp)

    for boss.hp > 0 {
        coroutine.wait(f, 0.5)
        boss.hp -= 20
        fmt.printf("[AI] %s took damage! Current HP: %d\n", boss.name, boss.hp)
    }

    fmt.printf("[AI] %s has been defeated!\n", boss.name)
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // Boss entity allocated in main
    dragon := Boss{
        name     = "Ancient Red Dragon",
        hp       = 60,
        position = {500.0, 300.0},
    }

    // Spawn fiber with long-lived pointer
    coroutine.spawn_ptr(&sched, boss_ai_timeline, &dragon)

    // Step scheduler until dragon dies
    for dragon.hp > 0 {
        coroutine.scheduler_step(&sched, 0.25)
    }
}
```

---

## 3. Strategy B: By-Value 128-Byte Inline Copy (`spawn_val`)

For fire-and-forget events, temporary coordinates, or transient spell configurations, use `spawn_val`.

### How It Works Internally
Every `Fiber` structure in the engine pre-allocates an embedded 128-byte raw buffer:
```odin
FIBER_PAYLOAD_SIZE :: 128
payload: [FIBER_PAYLOAD_SIZE]u8
```

When you call `spawn_val(sched, entry_proc, my_struct)`:
1. The compiler checks that `size_of(T) <= 128`.
2. The entire struct is copied by value directly into `fiber.payload`.
3. When the fiber executes, the entry procedure receives an internal pointer pointing to its own private payload buffer.
4. **Result:** Zero heap allocations, zero garbage collection, and 100% immune to caller stack destruction!

```odin
package main

import "core:fmt"
import "coroutine"

Particle_Burst :: struct {
    origin:   [2]f32,
    count:    int,
    color:    [4]f32,
    tag:      string,
}

spawn_particles :: proc(f: ^coroutine.Fiber, cfg: Particle_Burst) {
    fmt.printf("[FX] Spawning %d '%s' particles at (%.1f, %.1f)!\n",
        cfg.count, cfg.tag, cfg.origin.x, cfg.origin.y)

    coroutine.wait(f, 0.5)

    fmt.printf("[FX] Particle burst '%s' completed.\n", cfg.tag)
}

trigger_fx :: proc(sched: ^coroutine.Scheduler) {
    // Local stack struct in transient function
    config := Particle_Burst{
        origin = {120.0, 450.0},
        count  = 100,
        color  = {1.0, 0.5, 0.0, 1.0},
        tag    = "Sparks",
    }

    // 100% Safe: Copied by-value into the fiber's 128B payload!
    coroutine.spawn_val(sched, spawn_particles, config)
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    trigger_fx(&sched) // 'config' stack frame dies here

    // Coroutine continues running safely!
    coroutine.scheduler_step(&sched, 0.1)
    coroutine.scheduler_step(&sched, 0.5)
}
```

---

## 4. Decision Matrix: Which One Should I Use?

```
                      Do you need to pass data to a fiber?
                                       │
                    Is the data an entity that outlives the fiber?
                                       │
                      ┌────────────────┴────────────────┐
                     YES                                NO
                      │                                 │
                      ▼                                 ▼
             Use `spawn_ptr`                    Is size <= 128 bytes?
      (Passes ^Boss, ^Player, etc.)                     │
                                               ┌────────┴────────┐
                                              YES                NO
                                               │                 │
                                               ▼                 ▼
                                        Use `spawn_val`    Allocate on Heap
                                     (Zero heap overhead!)   (or Arena)
```

---

## Next Steps
In [Tutorial 3: Structured Concurrency](03_structured_concurrency.md), you will learn how to coordinate parallel branches using `sync` and preemption using `race`.
