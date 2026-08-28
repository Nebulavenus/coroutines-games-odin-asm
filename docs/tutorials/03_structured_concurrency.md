# Tutorial 3: Structured Concurrency — Building a Boss Fight with `sync` and `race`

Structured concurrency guarantees that concurrent branches are strictly bounded by lexical scope. A parent fiber spawning child branches cannot complete or leave its execution scope until all child branches have terminated.

In this chapter, you will build a complete multi-phase Boss encounter using `sync` (parallel fork-join) and `race` (first-to-finish preemption).

---

## 1. Parallel Fork-Join with `sync`

Use `sync` when multiple tasks must execute in parallel and the parent coroutine must suspend until **all** branches have completed:

```
                           [ Parent Fiber ]
                           coroutine.sync()
                                  │
         ┌────────────────────────┼────────────────────────┐
         ▼                        ▼                        ▼
   [ Laser 1: 1.0s ]        [ Laser 2: 1.5s ]        [ Laser 3: 0.8s ]
         │                        │                        │
         └────────────────────────┼────────────────────────┘
                                  ▼
                       (All branches finished!)
                       [ Parent Fiber Resumes ]
```

### Code Example: Triple Laser Beam
```odin
laser_beam :: proc(f: ^coroutine.Fiber, id: int) {
    fmt.printf("[Laser %d] Charging energy...\n", id)
    coroutine.wait(f, 0.5)
    fmt.printf("[Laser %d] FIRING BEAM!\n", id)
    coroutine.wait(f, 0.5)
    fmt.printf("[Laser %d] Cooldown finished.\n", id)
}

boss_laser_barrage :: proc(f: ^coroutine.Fiber) {
    fmt.println("Boss preparing simultaneous 3-laser barrage!")

    // Fork-join 3 concurrent laser beams
    coroutine.sync(f, {
        coroutine.branch(proc(f: ^coroutine.Fiber, d: rawptr) { laser_beam(f, 1) }, nil),
        coroutine.branch(proc(f: ^coroutine.Fiber, d: rawptr) { laser_beam(f, 2) }, nil),
        coroutine.branch(proc(f: ^coroutine.Fiber, d: rawptr) { laser_beam(f, 3) }, nil),
    })

    // Resumes ONLY when all 3 lasers finish!
    fmt.println("All lasers completed. Boss returning to idle.")
}
```

---

## 2. Preemptive Cancellation with `race`

Use `race` when multiple branches compete, and the parent wants to resume as soon as the **first** branch completes—automatically aborting and cleaning up the losing branches:

```
                           [ Parent Fiber ]
                           coroutine.race()
                                  │
         ┌────────────────────────┼────────────────────────┐
         ▼                        ▼                        ▼
  [ Attack Loop ]          [ HP <= 50% Watcher ]      [ 10s Enrage Timer ]
  (Runs indefinitely)      (Triggers when HP drops)   (Timer countdown)
                                  │
                                  ▼
                         (Winner Triggered!)
                                  │
         ┌────────────────────────┴────────────────────────┐
         ▼                                                 ▼
  [ ABORT Attack Loop ]                         [ ABORT 10s Timer ]
```

### Complete Boss Phase Simulation Example

```odin
package main

import "core:fmt"
import "coroutine"

Boss_Entity :: struct {
    hp:    int,
    phase: int,
}

boss_combat_timeline :: proc(f: ^coroutine.Fiber, boss: ^Boss_Entity) {
    fmt.println("=== BOSS ENCOUNTER COMMENCING ===")

    // ==========================================
    // PHASE 1: Attack until HP drops or 5s timer
    // ==========================================
    fmt.println("\n[PHASE 1] Boss engages player!")

    winner := coroutine.race(f, {
        // Branch 0: Continuous Attack Loop
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            for {
                fmt.println("  -> Boss casts Void Bolt!")
                coroutine.wait(f, 1.0)
            }
        }, boss),

        // Branch 1: Health Threshold Trigger
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            coroutine.wait_until(f, proc(b: ^Boss_Entity) -> bool { return b.hp <= 50 }, boss)
            fmt.println("  >>> TRIGGER: Boss HP dropped to <= 50%! <<<")
        }, boss),

        // Branch 2: Enrage Timer
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            coroutine.wait(f, 5.0)
            fmt.println("  >>> TRIGGER: 5-Second Enrage Timer Expired! <<<")
        }, boss),
    })

    fmt.printf("[PHASE 1 COMPLETE] Winning branch index: %d\n", winner)
    fmt.println("Transitioning to Phase 2: All Phase 1 attacks automatically aborted!")

    // ==========================================
    // PHASE 2: Parallel Super-Attack (sync)
    // ==========================================
    boss.phase = 2
    fmt.println("\n[PHASE 2] Boss casts ultimate synchronized nova!")

    coroutine.sync(f, {
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            fmt.println("  [Shield] Charging invulnerability barrier...")
            coroutine.wait(f, 1.5)
            fmt.println("  [Shield] Barrier fully charged!")
        }, boss),

        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            fmt.println("  [Nova] Expanding fiery explosion ring...")
            coroutine.wait(f, 1.5)
            fmt.println("  [Nova] Fiery ring reached boundary!")
        }, boss),
    })

    fmt.println("\n=== BOSS ENCOUNTER VICTORY ===")
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    boss := Boss_Entity{hp = 100, phase = 1}
    coroutine.spawn_ptr(&sched, boss_combat_timeline, &boss)

    // Simulate 2 seconds of combat
    for i := 0; i < 2; i += 1 {
        coroutine.scheduler_step(&sched, 1.0)
    }

    // Player deals heavy damage!
    fmt.println("\n>>> [Player casts Meteor Strike dealing 60 damage!] <<<")
    boss.hp = 40

    // Step scheduler: Race detects HP drop, cancels attacks, enters Phase 2!
    for i := 0; i < 4; i += 1 {
        coroutine.scheduler_step(&sched, 1.0)
    }
}
```

---

## 3. What Happens to Child Subtrees on Cancel?

When a branch loses a `race` or is cancelled:
1. The engine recursively traverses the losing fiber's child hierarchy bottom-up.
2. Any sleeping child fibers are immediately removed from `timer_heap`, `real_timer_heap`, and `frame_waiters`.
3. Stacks are returned to the slab pool for $O(1)$ recycling.
4. Native `defer` blocks execute cleanly.

---

## Next Steps
In [Tutorial 4: Advanced Decision Trees](04_advanced_control_flow.md), you will learn how to build AI behavior trees using `rush`, `fallback`, and `with_timeout`.
