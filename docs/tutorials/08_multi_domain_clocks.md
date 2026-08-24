# Tutorial 8: The 3-Tier Clock in Practice — Pausing, Bullet-Time & Fixed Ticks

Commercial games require managing multiple clock domains simultaneously: pausing the gameplay world while animating UI menus, executing bullet-time slow motion during critical hits, and running deterministic fixed-rate physics.

This chapter walks through practical implementations of all 3 temporal domains.

---

## 1. Domain 1 vs Domain 2: Pausing the World while Animating UI

When a player hits ESC to open the pause menu:
1. Set `sched.is_paused = true`.
2. All gameplay coroutines using `wait(f, seconds)` **stop advancing**.
3. UI menu coroutines using `wait_real(f, seconds)` **continue animating smoothly**!

```odin
package main

import "core:fmt"
import "coroutine"

// Gameplay Combat Fiber (Simulation Domain)
boss_flame_breath :: proc(f: ^coroutine.Fiber) {
    for {
        fmt.Println("  [Combat] Dragon casting Flame Breath!")
        coroutine.wait(f, 1.0) // FROZEN while sched.is_paused == true!
    }
}

// Pause Menu Banner Fiber (Real-Time Domain)
ui_pause_banner :: proc(f: ^coroutine.Fiber) {
    for {
        fmt.Println("  [UI Menu] Blinking '=== PAUSED ===' banner on screen...")
        coroutine.wait_real(f, 0.5) // STILL ADVANCES while sched.is_paused == true!
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, boss_flame_breath)
    coroutine.spawn_real(&sched, ui_pause_banner)

    fmt.Println("--- Normal Gameplay (Unpaused) ---")
    for i := 0; i < 2; i += 1 {
        coroutine.scheduler_step(&sched, 0.5)
    }

    fmt.Println("\n>>> PLAYER OPENS PAUSE MENU (is_paused = true) <<<")
    coroutine.scheduler_set_paused(&sched, true)

    for i := 0; i < 3; i += 1 {
        fmt.Printf("\n[Paused Tick %d] real_time: %.2fs, sim_time: %.2fs\n",
            i, sched.real_time, sched.sim_time)
        coroutine.scheduler_step(&sched, 0.5)
    }

    fmt.Println("\n>>> PLAYER CLOSES PAUSE MENU (is_paused = false) <<<")
    coroutine.scheduler_set_paused(&sched, false)

    coroutine.scheduler_step(&sched, 0.5)
}
```

---

## 2. Bullet-Time Slow Motion with `time_scale`

You can create cinematic Matrix-style slow-motion effects by setting `sched.time_scale`:

```odin
// Normal Speed
sched.time_scale = 1.0

// Trigger 20% Speed Bullet-Time (e.g. during a sniper headshot)
sched.time_scale = 0.20

// A coroutine calling coroutine.wait(f, 1.0) will now take 5.0 real seconds to complete!
// UI animations using wait_real remain at full 100% real-time speed!
```

---

## 3. Domain 3: Deterministic Physics with `wait_ticks`

For fighting games, rollback netcode, or deterministic physics engines:

```odin
physics_sim_proc :: proc(f: ^coroutine.Fiber) {
    for {
        // Wait exactly 1 discrete integer tick
        coroutine.wait_ticks(f, 1)
        fmt.Println("Fixed 60 Hz physics integration step!")
    }
}

// In Fixed-Tick Game Loop:
coroutine.scheduler_step_ticks(&sched, 1)
```

---

## 4. Category User Tags & Mass Cancellation (`user_tag`)

In addition to entity-scoped cancellations, you can tag fibers by category (e.g. `TAG_COMBAT_AI`, `TAG_PARTICLE_FX`, `TAG_AMBIENT_AUDIO`) to perform selective mass cancellations:

```odin
package main

import "core:fmt"
import "coroutine"

Behavior_Tag :: enum u32 {
    Unspecified = 0,
    Combat_AI   = 1,
    Movement    = 2,
    Particles   = 3,
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // Spawn combat AI fibers with Combat_AI tag
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.Println("[Combat AI] Charging laser cannon...")
        coroutine.wait(f, 2.0)
    }, tag = u32(Behavior_Tag.Combat_AI))

    // Spawn movement fiber with Movement tag
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.Println("[Movement] Patrolling perimeter...")
        coroutine.wait(f, 5.0)
    }, tag = u32(Behavior_Tag.Movement))

    coroutine.scheduler_step(&sched, 0.1)

    // Inspect active counts by tag:
    combat_count := coroutine.scheduler_count_by_tag(&sched, u32(Behavior_Tag.Combat_AI))
    fmt.printf("Active Combat AI fibers: %d\n", combat_count)

    // EMP Blast: Cancel ALL combat fibers across all entities!
    fmt.Println("\n>>> EMP BLAST DETONATES: Cancelling all Combat AI! <<<")
    cancelled := coroutine.scheduler_cancel_by_tag(&sched, u32(Behavior_Tag.Combat_AI))
    fmt.printf("Cancelled %d combat fibers. Movement fibers continue!\n", cancelled)

    coroutine.scheduler_step(&sched, 0.1)
}
```

---

## Next Steps
In [Tutorial 9: Headless CI/CD Testing](09_headless_ci_testing.md), you will learn how to write automated gameplay tests that simulate minutes of combat in milliseconds using `simulate_until`.
