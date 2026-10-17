# Tutorial 4: Advanced Decision Trees — `rush`, `fallback`, `branch_scoped` & `with_timeout`

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
        // Using fallback_with passes ^NPC directly to all arms:
        coroutine.fallback_with(f, npc,
            // Priority 1: Melee Slam
            proc(f: ^coroutine.Fiber, n: ^NPC) {
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
            },

            // Priority 2: Ranged Snipe
            proc(f: ^coroutine.Fiber, n: ^NPC) {
                if !n.has_los {
                    // Obstacle in the way! Cascade to next branch!
                    coroutine.fail(f)
                    return
                }

                fmt.printf("[AI] %s executing Ranged Sniper Shot!\n", n.name)
                coroutine.wait(f, 0.8)
            },

            // Priority 3: Fallback Patrol
            proc(f: ^coroutine.Fiber, n: ^NPC) {
                fmt.printf("[AI] %s patrolling to waypoint %d.\n", n.name, n.patrol_index)
                n.patrol_index = (n.patrol_index + 1) % 4
                coroutine.wait(f, 1.0)
            },
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

## 2. Parallel First-to-Succeed Partial Join with `rush`

In Epic Verse semantics, `rush` runs arms in parallel and resumes the parent as soon as the **first branch succeeds** (`.Completed`), safely ignoring early branch failures (`fail(f)`).

**Crucially, unlike `race`, `rush` does NOT cancel losing branches!** Losing branches have their join coordinator detached and continue running concurrently in the background as scoped children of the parent:

```odin
// 3 Scouts search different cave entrances concurrently using direct procedures:
coroutine.rush(f,
    proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 0.5)
        fmt.println("[Scout North] Dead end!")
        coroutine.fail(f) // Dropped out! Ignored by rush.
    },

    proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 1.0)
        fmt.println("[Scout East] Found the secret dungeon entrance!")
        // Finishes successfully! Wins rush and unblocks the parent!
    },

    proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 2.5)
        fmt.println("[Scout West] Mapped underground treasure room!")
        // Loses rush, BUT NOT CANCELLED! Keeps running in background!
    },
)

// Parent resumes immediately when Scout East succeeds at 1.0s.
// Scout West continues mapping in the background.
// If the parent exits or is cancelled, background children are safely aborted bottom-up!
```

*Tip:* When all arms operate on shared data, `coroutine.rush_with(f, data, ...)` passes your context pointer without closures!

---

## 3. Parent-Bound Fire-and-Forget with `branch_scoped`

In Epic's Verse language, `branch:` launches a concurrent subtask without suspending the parent. If the parent function finishes, fails, or is cancelled, the branched task is automatically aborted.

The library provides `coroutine.branch_scoped` for this exact pattern:

```odin
// Launch an ambient visual aura tied to this entity's spellcast:
coroutine.branch_scoped(f, proc(child: ^coroutine.Fiber, c: ^Chest) {
    for !c.is_unlocked {
        fmt.println("Casting glowing runes aura...")
        coroutine.wait(child, 0.2)
    }
}, &chest, name = "Chest Glow FX")

// Parent continues immediately without suspending!
coroutine.wait(f, 1.0)
// When parent finishes or aborts, all scoped branches are cleanly recycled!
```

---

## 4. Structured Task Preemption with `with_signal` & `race`

In pure Verse semantics, `race` executes arms concurrently. The **first arm to succeed** (`.Completed`) wins and immediately cancels and cleans up all competing sibling subtrees.

For preemption triggered by external events, `coroutine.with_signal` wraps this pattern concisely:

```odin
// Preempt lockpicking if an alarm signal fires:
completed := coroutine.with_signal(f, &g_lockdown_signal, proc(f: ^coroutine.Fiber, c: ^Chest) {
    coroutine.wait(f, 3.0)
    c.is_unlocked = true
}, &chest)

if !completed {
    fmt.println("Lockpicking interrupted by emergency lockdown signal!")
}
```

You can also use `coroutine.race` or `coroutine.race_with` with the pre-built `coroutine.branch_signal(&g_lockdown_signal)` primitive when competing against multiple conditions:

```odin
winner := coroutine.race(f,
    coroutine.branch(proc(f: ^coroutine.Fiber, c: ^Chest) {
        coroutine.wait(f, 3.0)
        c.is_unlocked = true
    }, &chest, name = "Lockpicking"),

    coroutine.branch_signal(&g_lockdown_signal, name = "Lockdown Watcher"),
)
```

---

## 5. In-Frame Cooperative Yields with `yield_now`

Verse distinguishes between advancing the clock (`NextTick()`) and yielding within the current frame (`Sleep(0.0)`).

- `coroutine.yield(f)`: Yields and targets the next clock step boundary ($t + 1$).
- `coroutine.yield_now(f)`: Cooperatively relinquishes the CPU timeslice to other ready fibers in the **current** frame, resuming before the tick ends without advancing the clock.

```odin
// Distribute heavy computation cooperatively within the same frame:
for chunk in world_chunks {
    process_chunk(chunk)
    coroutine.yield_now(f) // Lets other fibers run in this same tick
}
```

> [!WARNING] **Scripting Rule: `yield_now` vs `yield` in Gameplay Loops**
> Never use `yield_now(f)` inside a game state polling loop:
> ```odin
> // DANGEROUS: Busy-spins within the current frame!
> for !enemy.is_dead {
>     coroutine.yield_now(f)
> }
> ```
> If `enemy.is_dead` is updated by an animation or physics tick in a future frame, `yield_now` will continuously re-enqueue in the same frame without letting simulation time advance.
> 
> **The Rule:**
> - **Use `yield_now(f)`** to distribute heavy CPU computation (e.g., pathfinding node slicing, procedural generation) across fibers within the current frame.
> - **Use `yield(f)`** (or `wait(f, 0.0)`) when waiting for game state that updates across frame boundaries.

---

## 6. Zero-Drift Loops with Fiber-Owned Tickers (`ticker_wait`)

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

## 7. Time-Bounded Actions with `with_timeout`

In structured concurrency, bounding any action by a deadline is done cleanly using `coroutine.with_timeout`:

```odin
Elevator :: struct {
    floor:     int,
    door_open: bool,
}

elevator_wait_task :: proc(f: ^coroutine.Fiber, e: ^Elevator) {
    fmt.println("Calling elevator to floor 5...")

    // Runs the branch with a 4.0 second deadline directly:
    arrived := coroutine.with_timeout(f, 4.0, proc(f: ^coroutine.Fiber, e: ^Elevator) {
        for !(e.floor == 5 && e.door_open) {
            coroutine.yield(f)
        }
    }, e)

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
In [Tutorial 5: Synchronization & Communication](05_synchronization.md), you will learn how to synchronize independent fibers using `with_mutex`, `Fiber_Semaphore`, `Event(T)`, `Sticky_Event(T)`, and `Channel(T)`.
