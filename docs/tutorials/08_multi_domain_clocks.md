# Tutorial 8: Indexed Multi-Domain Clocks — Pausing, Bullet-Time & Fixed Ticks

Commercial games require managing multiple clock domains simultaneously: pausing the gameplay simulation while animating UI menus, executing bullet-time slow motion during critical hits, and running deterministic fixed-rate physics.

Rather than maintaining duplicate APIs (`spawn_real`, `wait_real`, `wait_ticks`), the engine uses an **Indexed `Clock_Domain` Architecture**:
- `Scheduler` holds an array of independent timelines: `clocks: [MAX_CLOCKS]Clock_Domain`.
- Every `Fiber` carries a `clock_id: Clock_ID` (`CLOCK_SIM`, `CLOCK_REAL`, `CLOCK_PHYS`, or custom).
- Yielding calls (`wait`, `wait_steps`, `yield`, `ticker_wait`) evaluate automatically against the fiber's assigned clock domain.
- Child branches in `sync()`, `race()`, and `rush()` automatically inherit `parent.clock_id` (`CLOCK_INHERIT`).

---

## 1. Predefined Clock Domains

| Clock ID | Name | Description | Typical Use Case |
| :--- | :--- | :--- | :--- |
| **`coroutine.CLOCK_SIM`** (0) | Simulation Clock | Default pausable gameplay timeline. | Enemy AI, combat cooldowns, character animations. |
| **`coroutine.CLOCK_REAL`** (1) | Real / Wall Clock | Unpaused, unscaled real-time timeline. | Pause menus, HUD animations, network timeouts. |
| **`coroutine.CLOCK_PHYS`** (2) | Fixed Physics Steps | Discrete integer step timeline. | 60 Hz physics sub-stepping, lockstep netcode, replays. |

---

## 2. Stepping the Scheduler with Multiple Clocks

In your main loop, advance each active clock domain with its respective delta, then dispatch all awakened fibers via `scheduler_run`:

```odin
package main

import "core:fmt"
import "coroutine"

// Gameplay Combat Fiber (Simulation Domain)
boss_flame_breath :: proc(f: ^coroutine.Fiber) {
    for {
        fmt.println("  [Combat] Dragon casting Flame Breath!")
        coroutine.wait(f, 1.0) // FROZEN while CLOCK_SIM is not advanced!
    }
}

// Pause Menu Banner Fiber (Real-Time Domain)
ui_pause_banner :: proc(f: ^coroutine.Fiber) {
    for {
        fmt.println("  [UI Menu] Blinking '=== PAUSED ===' banner on screen...")
        coroutine.wait(f, 0.5) // Advances whenever CLOCK_REAL is advanced!
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // Spawn combat fiber on default CLOCK_SIM:
    coroutine.spawn(&sched, boss_flame_breath)

    // Spawn UI fiber explicitly on CLOCK_REAL:
    coroutine.spawn(&sched, ui_pause_banner, clock = coroutine.CLOCK_REAL)

    is_paused := false

    fmt.println("--- Normal Gameplay (Unpaused) ---")
    for frame := 0; frame < 2; frame += 1 {
        dt: f32 = 0.5
        coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, dt)
        coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, dt)
        coroutine.scheduler_run(&sched)
    }

    fmt.println("\n>>> PLAYER OPENS PAUSE MENU (Simulation Frozen) <<<")
    is_paused = true

    for frame := 0; frame < 3; frame += 1 {
        dt: f32 = 0.5
        // ONLY advance CLOCK_REAL while paused:
        coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, dt)
        if !is_paused {
            coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, dt)
        }
        coroutine.scheduler_run(&sched)
    }

    fmt.println("\n>>> PLAYER RESUMES GAME <<<")
    is_paused = false

    dt: f32 = 0.5
    coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, dt)
    coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, dt)
    coroutine.scheduler_run(&sched)
}
```

---

## 3. Bullet-Time Slow Motion

To create Matrix-style slow-motion effects, scale `dt` before advancing `CLOCK_SIM`:

```odin
sim_time_scale: f32 = 0.20 // 20% speed bullet-time

// Advance Real-Time UI at normal 100% speed:
coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, raw_dt)

// Advance Simulation with bullet-time scaling:
if !is_paused {
    coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, raw_dt * sim_time_scale)
}

// Dispatch ready fibers:
coroutine.scheduler_run(&sched)
```

A fiber executing `coroutine.wait(f, 1.0)` on `CLOCK_SIM` will now take 5.0 real-world seconds to complete, while UI animations on `CLOCK_REAL` remain fluid at full speed.

---

## 4. Deterministic Fixed-Rate Physics Steps (`CLOCK_PHYS`)

For fixed-timestep simulations (such as 60 Hz physics or rollback netcode), advance `CLOCK_PHYS` using fixed-delta slices:

```odin
FIXED_DT :: 1.0 / 60.0

physics_car_sim :: proc(f: ^coroutine.Fiber) {
    for {
        // Suspends until exactly 1 fixed physics tick passes:
        coroutine.wait_steps(f, 1)
        fmt.println("Fixed 60 Hz physics integration step!")
    }
}

// Spawning on fixed physics domain:
coroutine.spawn(&sched, physics_car_sim, clock = coroutine.CLOCK_PHYS)

// In Fixed-Tick Game Loop:
accumulator += frame_dt
for accumulator >= FIXED_DT {
    coroutine.clock_advance(&sched, coroutine.CLOCK_PHYS, FIXED_DT, steps = 1)
    accumulator -= FIXED_DT
}
coroutine.scheduler_run(&sched)
```

---

## 5. Child Clock Inheritance & Cross-Clock Races

When creating structured branches with `sync`, `race`, or `rush`:
1. **Clock Inheritance**: Child fibers inherit the parent's `clock_id` automatically (`CLOCK_INHERIT`).
2. **Cross-Clock Racing**: An individual branch can override its clock domain, enabling cross-clock evaluations:

```odin
// Parent fiber runs on CLOCK_SIM
winner := coroutine.race(f,
    // Branch 0 inherits CLOCK_SIM (pauses when game is paused)
    coroutine.branch(boss_combat_routine, boss),

    // Branch 1 runs on CLOCK_REAL (unpausable real-time 10.0s deadline)
    coroutine.branch(proc(f: ^coroutine.Fiber) {
        coroutine.wait(f, 10.0)
    }, clock = coroutine.CLOCK_REAL),
)
```

If the player pauses the game, the boss combat loop freezes, but the real-time timeout branch continues ticking!

---

## Next Steps
In [Tutorial 9: Headless Simulation Testing](09_headless_ci_testing.md), you will learn how to automate end-to-end gameplay tests in headless CI environments.
