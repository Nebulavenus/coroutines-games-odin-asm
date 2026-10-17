# Tutorial 9: Headless CI/CD Gameplay Testing — Fast-Forward Automated Simulation

One of the greatest superpowers of deterministic coroutines is the ability to write headless, lightning-fast integration tests for complex gameplay scenarios without opening a graphics window.

---

## 1. The Headless Simulation Advantage

Testing complex game timelines manually (such as "Does the boss cast spells, transition to Phase 2 when HP drops below 50%, and enter rage mode?") requires human playtesting for several minutes.

With coroutines, you can simulate **60 seconds of complex AI combat in 5 milliseconds** inside `odin test`!

```
 Manual In-Game Testing                   Headless Coroutine Testing
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
            for b.hp > 50 {
                coroutine.yield(f)
            }
        }, boss, name = "HP Trigger"),
    )

    // Phase 2: Enter Enrage Phase
    boss.phase = 2
}

// Helper: step scheduler until condition or timeout
simulate_until :: proc(sched: ^coroutine.Scheduler, dt: f32, max_duration: f32, condition: proc(rawptr) -> bool, user_data: rawptr) -> bool {
    for elapsed: f32 = 0; elapsed < max_duration; elapsed += dt {
        if condition(user_data) do return true
        coroutine.scheduler_step(sched, dt)
    }
    return condition(user_data)
}

@(test)
test_boss_phase_transition_simulation :: proc(t: ^testing.T) {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    boss := Boss_Combat_State{hp = 100, phase = 1}
    coroutine.spawn_ptr(&sched, boss_ai_timeline, &boss)

    // 1. Simulate up to 4.0 seconds with dt = 0.1s headlessly
    is_phase_2 :: proc(data: rawptr) -> bool {
        return ((^Boss_Combat_State)(data)).phase == 2
    }

    met := simulate_until(&sched, 0.1, 4.0, is_phase_2, &boss)
    testing.expect_value(t, met, false)       // Condition not met yet
    testing.expect_value(t, boss.phase, 1)    // Still in Phase 1

    // 2. Player deals damage dropping HP to 40%
    boss.hp = 40

    // 3. Fast-forward until phase 2 condition is satisfied:
    met = simulate_until(&sched, 0.1, 5.0, is_phase_2, &boss)

    // 4. Assert Phase 2 triggered deterministically!
    testing.expect_value(t, met, true)
    testing.expect_value(t, boss.phase, 2)
}
```

---

## 3. Running Headless Tests in CI/CD and Multi-ISA Emulation

To run these tests locally, in CI pipelines, or under cross-architecture QEMU emulation:

```powershell
# Run all 182 unit tests on native host (133 core + 49 sync)
.\build.ps1 test

# Cross-check all 7 multi-ISA & Wasm targets
.\build.ps1 check-all

# Execute all unit tests under Linux ARM64 and RISC-V 64 via QEMU in WSL2
.\run_wsl_qemu.ps1 test
```

Because simulation does not require window creation or GPU contexts, all 182 unit tests execute in under 350 milliseconds on native host.

---

## Summary of the Tutorial Series

Congratulations! You have completed the 9-stage tutorial series:
1. **[Tutorial 1: Hello Coroutines & Basic Yields](01_hello_coroutines.md)**
2. **[Tutorial 2: State & Parameter Passing](02_parameter_passing.md)**
3. **[Tutorial 3: Structured Concurrency (`sync` & `race`)](03_structured_concurrency.md)**
4. **[Tutorial 4: Advanced Decision Trees (`rush`, `fallback`, `with_timeout`, `ticker_wait`)](04_advanced_control_flow.md)**
5. **[Tutorial 5: Synchronization & Communication (`Signal`, `Event(T)`, `coroutine/sync`)](05_synchronization.md)**
6. **[Tutorial 6: Offloading Heavy Compute (`await_async` & `fiber_join`)](06_async_background_jobs.md)**
7. **[Tutorial 7: Procedural Generators & Streaming Sequences](07_stateful_generators.md)**
8. **[Tutorial 8: Multi-Domain Clocks & Time Dilation](08_multi_domain_clocks.md)**
9. **[Tutorial 9: Headless Simulation Testing in CI/CD](09_headless_ci_testing.md)**
