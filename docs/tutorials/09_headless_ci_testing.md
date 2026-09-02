# Tutorial 9: Headless CI/CD Gameplay Testing — Automated Simulation with `simulate_until`

One of the greatest superpowers of deterministic coroutines is the ability to write headless, lightning-fast integration tests for complex gameplay scenarios without opening a graphics window.

---

## 1. The Headless Simulation Advantage

Testing complex game timelines manually (such as "Does the boss cast 3 spells, transition to Phase 2 at 50% HP, and enter rage mode if player deals 500 damage?") requires playing the game for several minutes.

With `simulate_until`, you can simulate **60 seconds of complex AI combat in 5 milliseconds** inside `odin test`!

```
 Manual In-Game Testing                   Headless Coroutine Testing (simulate_until)
┌───────────────────────────┐            ┌───────────────────────────────────────────┐
│ • Launch 3D/2D Window     │            │ • Zero Window / GPU initialization        │
│ • Play combat for 2 mins  │ ◄─ VS ──►  │ • Simulates 60.0s in 5 milliseconds       │
│ • Prone to human error    │            │ • 100% Deterministic & Assertable in CI   │
│ • Cannot run in headless CI│           │ • Seamlessly integrated into `odin test`  │
└───────────────────────────┘            └───────────────────────────────────────────┘
```

---

## 2. Complete Runnable Test Case

```odin
package main

import "core:testing"
import "coroutine"

Boss_Combat_State :: struct {
    hp:    int,
    phase: int,
}

boss_ai_timeline :: proc(f: ^coroutine.Fiber, boss: ^Boss_Combat_State) {
    // Phase 1: Fight for up to 10 seconds or until HP <= 50
    coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Combat_State) {
            coroutine.wait(f, 10.0) // 10s timer
        }, boss, name = "10s Timer"),
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss_Combat_State) {
            coroutine.wait_until(f, proc(b: ^Boss_Combat_State) -> bool { return b.hp <= 50 }, boss)
        }, boss, name = "HP Trigger"),
    )

    // Phase 2: Enter Enrage Phase
    boss.phase = 2
}

@(test)
test_boss_phase_transition_simulation :: proc(t: ^testing.T) {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    boss := Boss_Combat_State{hp = 100, phase = 1}
    coroutine.spawn_ptr(&sched, boss_ai_timeline, &boss)

    // 1. Simulate up to 4.0 seconds with dt = 0.1s headlessly
    met, elapsed := coroutine.simulate_until(&sched, 0.1, 4.0, proc(b: ^Boss_Combat_State) -> bool {
        return b.phase == 2
    }, &boss)
    testing.expect_value(t, met, false)       // Condition not met yet
    testing.expect_value(t, boss.phase, 1)    // Still in Phase 1

    // 2. Player deals damage dropping HP to 40%
    boss.hp = 40

    // 3. Fast-forward until phase 2 condition is satisfied:
    met, elapsed = coroutine.simulate_until(&sched, 0.1, 5.0, proc(b: ^Boss_Combat_State) -> bool {
        return b.phase == 2
    }, &boss)

    // 4. Assert Phase 2 triggered deterministically!
    testing.expect_value(t, met, true)
    testing.expect_value(t, boss.phase, 2)
}
```

---

## 3. Pause-Immune & Watchdog-Safe Mechanics

When running automated headless test pipelines:
1. **Automatic Pause Override:** If the scheduler starts in a paused state (`clock.is_paused == true`), `simulate_until` temporarily forces simulation time advancement (`sched.clock.is_paused = false`) and restores the initial pause state upon exit via `defer`.
2. **Watchdog Suppression & Restoration:** In debug builds, `simulate_until` temporarily suppresses the runtime slice watchdog (`sched.watchdog_enabled = false`) so that continuous simulation loops running thousands of iterations do not trip runaway watchdog panics.

---

## 4. Running Headless Tests in CI/CD and QEMU Emulation

To run these tests locally, in CI pipelines, or under cross-architecture QEMU emulation:

```powershell
# Run all 188 unit tests on native host
.\build.ps1 test

# Cross-check all 6 multi-ISA targets
.\build.ps1 check-all

# Execute all 188 unit tests under Linux ARM64 and RISC-V 64 via QEMU in WSL2
.\run_wsl_qemu.ps1 test
```

Because simulation does not require window creation or GPU contexts, all 188 unit tests execute in under 400 milliseconds on native host.

---

## Summary of the Tutorial Series

Congratulations! You have completed the 9-stage tutorial series:
1. **[Tutorial 1: Hello Coroutines & Basic Yields](01_hello_coroutines.md)**
2. **[Tutorial 2: State & Parameter Passing](02_parameter_passing.md)**
3. **[Tutorial 3: Structured Concurrency (`sync` & `race`)](03_structured_concurrency.md)**
4. **[Tutorial 4: Advanced Decision Trees (`rush`, `fallback`, `with_timeout`, `Ticker`)](04_advanced_control_flow.md)**
5. **[Tutorial 5: Synchronization & Communication (`with_mutex`, `with_semaphore`, `Event`, `Latch`, `Channel`)](05_synchronization.md)**
6. **[Tutorial 6: Offloading Heavy Compute (`await_async` & `fiber_join`)](06_async_background_jobs.md)**
7. **[Tutorial 7: Stateful Iterators (`Generator(T)`)](07_stateful_generators.md)**
8. **[Tutorial 8: The 3-Tier Multi-Domain Clock Architecture](08_multi_domain_clocks.md)**
9. **[Tutorial 9: Headless CI/CD Gameplay Testing (`simulate_until`)](09_headless_ci_testing.md)**
