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
    fmt.Printf("[AI] %s started decision loop.\n", npc.name)

    for {
        // Fallback executes sequentially until the FIRST successful branch!
        coroutine.fallback(f, {
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

                fmt.Printf("[AI] %s executing Heavy Melee Slam!\n", n.name)
                coroutine.wait(f, 0.5)
            }, npc),

            // Priority 2: Ranged Snipe
            coroutine.branch(proc(f: ^coroutine.Fiber, n: ^NPC) {
                if !n.has_los {
                    // Obstacle in the way! Cascade to next branch!
                    coroutine.fail(f)
                    return
                }

                fmt.Printf("[AI] %s executing Ranged Sniper Shot!\n", n.name)
                coroutine.wait(f, 0.8)
            }, npc),

            // Priority 3: Fallback Patrol
            coroutine.branch(proc(f: ^coroutine.Fiber, n: ^NPC) {
                fmt.Printf("[AI] %s patrolling to waypoint %d.\n", n.name, n.patrol_index)
                n.patrol_index = (n.patrol_index + 1) % 4
                coroutine.wait(f, 1.0)
            }, npc),
        })
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
coroutine.rush(f, {
    coroutine.branch(proc(f: ^coroutine.Fiber, d: rawptr) {
        coroutine.wait(f, 0.5)
        fmt.println("[Scout North] Dead end!")
        coroutine.fail(f) // Ignored by rush!
    }, nil),

    coroutine.branch(proc(f: ^coroutine.Fiber, d: rawptr) {
        coroutine.wait(f, 1.0)
        fmt.println("[Scout East] Found the secret dungeon entrance!")
        // Finishes successfully! Wins the rush!
    }, nil),
})
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

## 4. 1-Line Cancellation with `with_cancel_token`

Easily run any task while racing it against a cancellation token:

```odin
interrupted := coroutine.with_cancel_token(f, &g_lockdown_token, coroutine.branch(proc(f: ^coroutine.Fiber, c: ^Chest) {
    coroutine.wait(f, 3.0)
    c.is_unlocked = true
}, &chest, name = "Lockpicking"))

if interrupted {
    fmt.println("Lockpicking interrupted by emergency lockdown!")
}
```

---

## 5. Zero-Drift Loops with `Ticker`

When running periodic actions, replace naive `wait()` loops with `Ticker` to eliminate cumulative floating-point drift:

```odin
ticker: coroutine.Ticker
coroutine.ticker_init(&ticker, interval_seconds = 0.5)

for _ in 0 ..< 10 { // Exactly 10 ticks over 5.0 seconds
    coroutine.ticker_wait(f, &ticker)
    fmt.println("Heartbeat pulse!")
}
```

---

## Next Steps
In [Tutorial 5: Synchronization & Communication](05_synchronization.md), you will learn how to synchronize independent fibers using `with_mutex`, `Fiber_Semaphore`, `Event(T)`, and `Channel(T)`.
