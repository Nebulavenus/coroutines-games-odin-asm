# Tutorial 4: Advanced Decision Trees — `rush`, `fallback` & `with_timeout`

This chapter explores advanced control-flow combinators for modeling intelligent NPC behavior trees, opportunistic multi-objective scouting, and time-bounded actions.

---

## 1. Behavior Decision Trees with `fallback`

In traditional game development, AI behavior trees require complex node hierarchies (Selectors, Sequences, Decorators). With stackful coroutines, you can build a priority behavior tree directly using `fallback` and `coroutine.fail(f)`:

```
                            [ AI Decision Loop ]
                                     │
                             coroutine.fallback()
                                     │
         ┌───────────────────────────┼───────────────────────────┐
         ▼                           ▼                           ▼
  [ 1. Melee Attack ]         [ 2. Ranged Snipe ]          [ 3. Patrol Area ]
  (Fails if dist > 50px)      (Fails if no line-of-sight) (Guaranteed fallback)
         │                           │                           │
  (Calls fail(f))             (Calls fail(f))                    │
         └───────────────────────────┴───────────────────────────┘
                                     ▼
                             (Executes Patrol!)
```

### Complete Runnable AI Behavior Example

```odin
package main

import "core:fmt"
import "core:math"
import "coroutine"

NPC :: struct {
    name:         string,
    pos:          [2]f32,
    player_pos:   [2]f32,
    has_los:      bool,
    patrol_index: int,
}

npc_ai_decision_tree :: proc(f: ^coroutine.Fiber, npc: ^NPC) {
    fmt.printf("[AI] %s started decision loop.\n", npc.name)

    for {
        // Fallback executes sequentially until the FIRST successful branch!
        coroutine.fallback(f,
            // Priority 1: Melee Slam
            coroutine.branch(proc(f: ^coroutine.Fiber, n: ^NPC) {
                dx := n.pos.x - n.player_pos.x
                dy := n.pos.y - n.player_pos.y
                dist := math.sqrt(dx * dx + dy * dy)

                if dist > 60.0 {
                    // Out of melee range! Cascade to next branch!
                    coroutine.fail(f)
                    return
                }

                fmt.printf("[AI] %s executing Heavy Melee Slam!\n", n.name)
                coroutine.wait(f, 0.5)
            }, npc, name = "Melee Priority"),

            // Priority 2: Ranged Snipe
            coroutine.branch(proc(f: ^coroutine.Fiber, n: ^NPC) {
                if !n.has_los {
                    // Obstacle in the way! Cascade to next branch!
                    coroutine.fail(f)
                    return
                }

                fmt.printf("[AI] %s executing Ranged Sniper Shot!\n", n.name)
                coroutine.wait(f, 0.8)
            }, npc, name = "Ranged Priority"),

            // Priority 3: Fallback Patrol
            coroutine.branch(proc(f: ^coroutine.Fiber, n: ^NPC) {
                fmt.printf("[AI] %s patrolling to waypoint %d.\n", n.name, n.patrol_index)
                n.patrol_index = (n.patrol_index + 1) % 4
                coroutine.wait(f, 1.0)
            }, npc, name = "Patrol Fallback"),
        )
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    guard := NPC{
        name        = "Sentry Guard",
        pos         = {100.0, 100.0},
        player_pos  = {500.0, 500.0}, // Far away
        has_los     = false,          // No line of sight
    }

    coroutine.spawn_ptr(&sched, npc_ai_decision_tree, &guard)

    // Tick 1: Out of range, no LOS -> Executes Patrol
    fmt.println("\n--- Turn 1: Player far away behind wall ---")
    coroutine.scheduler_step(&sched, 0.1)

    // Tick 2: Player steps into Line of Sight
    fmt.println("\n--- Turn 2: Player steps into Line of Sight ---")
    guard.has_los = true
    coroutine.scheduler_step(&sched, 1.0)

    // Tick 3: Player charges into melee range
    fmt.println("\n--- Turn 3: Player charges into melee range ---")
    guard.player_pos = {120.0, 110.0} // Close range!
    coroutine.scheduler_step(&sched, 1.0)
}
```

---

## 2. Parallel First-to-Succeed with `rush`

Unlike `race` (which aborts as soon as *any* branch finishes or fails), `rush` runs branches in parallel and resumes on the **first successful** branch, safely ignoring early branch failures:

```odin
// 3 Scouts search different cave entrances concurrently
coroutine.rush(f,
    coroutine.branch(proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 0.5)
        fmt.println("[Scout North] Dead end!")
        coroutine.fail(f) // Ignored by rush!
    }, name = "Scout North"),

    coroutine.branch(proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 1.0)
        fmt.println("[Scout East] Found the secret dungeon entrance!")
        // Finishes successfully! Wins the rush!
    }, name = "Scout East"),
)
```

---

## 3. Scoped Timeouts with `with_timeout`

Ensure asynchronous actions do not hang indefinitely:

```odin
Chest :: struct { is_unlocked: bool }

chest := Chest{is_unlocked = false}

success := coroutine.with_timeout(f, 2.0, proc(f: ^coroutine.Fiber, c: ^Chest) {
    fmt.println("Lockpicking chest...")
    coroutine.wait(f, 1.5) // Takes 1.5 seconds
    c.is_unlocked = true
}, &chest)

if success {
    fmt.println("Chest unlocked successfully!")
} else {
    fmt.println("Lockpicking timed out! Alarm triggered!")
}
```

---

## 4. Structured Task Preemption with `race` & `Signal`

Easily run any task while racing it against a cancellation signal:

```odin
winner := coroutine.race(f,
    coroutine.branch(proc(f: ^coroutine.Fiber, c: ^Chest) {
        coroutine.wait(f, 3.0)
        c.is_unlocked = true
    }, &chest, name = "Lockpicking"),

    coroutine.branch(proc(f: ^coroutine.Fiber, sig: ^coroutine.Signal) {
        coroutine.signal_wait(f, sig)
    }, &g_lockdown_signal, name = "Lockdown Watcher"),
)

if winner == 1 {
    fmt.println("Lockpicking interrupted by emergency lockdown signal!")
}
```

---

## 5. Zero-Drift Loops with Fiber-Owned Tickers (`ticker_wait`)

When running periodic actions, avoid naive `wait()` loops which accumulate frame quantization error. Instead, use the built-in fiber-owned ticker to eliminate cumulative timing drift:

```odin
for _ in 0 ..< 10 { // Exactly 10 ticks over 5.0 seconds with zero cumulative drift
    coroutine.ticker_wait(f, interval_seconds = 0.5)
    fmt.println("Heartbeat pulse!")
}
```

- **Zero Allocations & True ZII**: Timestamps (`ticker_interval`, `ticker_next_wake`) live directly on the `Fiber` struct in memory.
- **WebAssembly Hardened**: Fully immune to Asyncify shadow-stack clobbering across yields.
- **Interruption Rebase**: If a fiber is stunned or paused, call `coroutine.ticker_rebase(f)` to reset schedule timestamps cleanly.

---

## 6. Time-Bounded Actions with `with_timeout`

In structured concurrency, bounding any action by a deadline is done cleanly using `coroutine.with_timeout`:

```odin
Elevator :: struct {
    floor:     int,
    door_open: bool,
}

elevator_wait_task :: proc(f: ^coroutine.Fiber, e: ^Elevator) {
    fmt.println("Calling elevator to floor 5...")

    // Runs the branch with a 4.0 second deadline:
    arrived := coroutine.with_timeout(f, 4.0, coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Elevator) {
        for !(e.floor == 5 && e.door_open) {
            coroutine.yield(f)
        }
    }, e))

    if arrived {
        fmt.println("Elevator arrived on time! Boarding...")
    } else {
        fmt.println("Elevator timed out! Taking the stairs!")
    }
}
```

- **Zero Leaks**: Automatically cancels and prunes the workload branch if the timeout expires first.
- **Cross-Clock Timeouts**: An optional `timeout_clock` parameter allows racing simulation workloads against unpaused wall-clock time (`coroutine.with_timeout(f, 5.0, task, coroutine.CLOCK_REAL)`).

---

## Next Steps
In [Tutorial 5: Synchronization & Communication](05_synchronization.md), you will learn how to synchronize independent fibers using `with_mutex`, `Fiber_Semaphore`, `Event(T)`, and `Channel(T)`.
