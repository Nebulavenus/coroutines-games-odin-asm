# Tutorial 3: Structured Concurrency — Building a Boss Fight with `sync` and `race`

Structured concurrency guarantees that concurrent branches are strictly bounded by lexical scope. A parent fiber spawning child branches cannot complete or leave its execution scope until all child branches have terminated.

In this chapter, you will build a complete multi-phase Boss encounter using `sync` (parallel fork-join) and `race` (first-to-succeed preemption).

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

    // Fork-join 3 concurrent laser beams using direct procedures or sync_with
    coroutine.sync(f,
        proc(f: ^coroutine.Fiber) { laser_beam(f, 1) },
        proc(f: ^coroutine.Fiber) { laser_beam(f, 2) },
        proc(f: ^coroutine.Fiber) { laser_beam(f, 3) },
    )

    // Resumes ONLY when all 3 lasers finish!
    fmt.println("All lasers completed. Boss returning to idle.")
}
```

*Tip:* When all branches share a common data pointer, use `coroutine.sync_with(f, data, ...)` to eliminate closure boilerplate!

---

## 2. Preemptive Cancellation with `race`

Use `race` (or `race_with`) when multiple branches compete, and the parent wants to resume as soon as the **first** branch completes successfully (`.Completed`)—automatically aborting and cleaning up the losing branches. If an arm calls `fail(f)`, it drops out of the competition without winning:

```
                           [ Parent Fiber ]
                           coroutine.race()
                                  │
         ┌────────────────────────┼────────────────────────┐
         ▼                        ▼                        ▼
  [ Attack Loop ]          [ HP <= 50% Watcher ]      [ 5s Enrage Timer ]
  (Runs indefinitely)      (Triggers when HP drops)   (Timer countdown)
                                  │
                                  ▼
                         (Winner Triggered!)
                                  │
         ┌────────────────────────┴────────────────────────┐
         ▼                                                 ▼
  [ ABORT Attack Loop ]                         [ ABORT 5s Timer ]
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

    // Using race_with to pass ^Boss_Entity to all branches cleanly,
    // combined with the pre-built branch_wait timer:
    winner := coroutine.race_with(f, boss,
        // Branch 0: Continuous Attack Loop
        proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            for {
                fmt.println("  -> Boss casts Void Bolt!")
                coroutine.wait(f, 1.0)
            }
        },

        // Branch 1: Health Threshold Trigger
        proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            for b.hp > 50 {
                coroutine.yield(f)
            }
            fmt.println("  >>> TRIGGER: Boss HP dropped to <= 50%! <<<")
        },

        // Branch 2: Enrage Timer using pre-built primitive
        coroutine.branch_wait(5.0, name = "Enrage Timer"),
    )

    fmt.printf("[PHASE 1 COMPLETE] Winning branch index: %d\n", winner)
    fmt.println("Transitioning to Phase 2: All Phase 1 attacks automatically aborted!")

    // ==========================================
    // PHASE 2: Parallel Super-Attack (sync_with)
    // ==========================================
    boss.phase = 2
    fmt.println("\n[PHASE 2] Boss casts ultimate synchronized nova!")

    coroutine.sync_with(f, boss,
        proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            fmt.println("  [Shield] Charging invulnerability barrier...")
            coroutine.wait(f, 1.5)
            fmt.println("  [Shield] Barrier fully charged!")
        },

        proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
            fmt.println("  [Nova] Expanding fiery explosion ring...")
            coroutine.wait(f, 1.5)
            fmt.println("  [Nova] Fiery ring reached boundary!")
        },
    )

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
1. The engine recursively traverses the losing fiber's child hierarchy bottom-up (`fiber_abort_tree`).
2. Any sleeping child fibers are immediately removed from their clock domain's `timer_heap` or `step_waiters`.
3. Registered cleanup callbacks registered via `coroutine.fiber_defer` execute in strict LIFO order.
4. Stacks are returned to the slab pool for $O(1)$ recycling.

> [!WARNING]
> Because suspended stackful fibers are cancelled externally without resuming execution on the CPU, **native Odin `defer` statements do not run on abort**. Always use `coroutine.fiber_defer` when managing external resources or reversible state (see [Guide: Footguns & Traps](file:///E:/OdinLang/Projects/coroutines_asm/docs/guides/GUIDE_FOOTGUNS.md#footgun-15-relying-on-native-odin-defer-for-external-fiber-cancellation--abort)).

---

## Next Steps
In [Tutorial 4: Advanced Decision Trees](04_advanced_control_flow.md), you will learn how to build AI behavior trees using `rush`, `fallback`, and `with_timeout`.
