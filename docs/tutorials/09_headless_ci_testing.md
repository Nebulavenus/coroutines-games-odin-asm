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
    // Phase 1: Fight for up to 10 seconds or until HP < 50
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

    // 1. Simulate 4.0 seconds headlessly
    coroutine.simulate_until(&sched, 4.0, dt = 0.1)
    testing.expect_value(t, boss.phase, 1) // Still in Phase 1

    // 2. Player deals damage dropping HP to 40%
    boss.hp = 40

    // 3. Step single frame (0.1s)
    coroutine.scheduler_step(&sched, 0.1)

    // 4. Assert Phase 2 triggered immediately!
    testing.expect_value(t, boss.phase, 2)
}
```

---

## 3. Running Headless Tests in CI/CD

To run these tests in GitHub Actions, GitLab CI, or local command line:

```powershell
# Run all unit tests
.\build.ps1 test
```

Because simulation does not require window creation or GPU contexts, hundreds of gameplay tests execute in under 300 milliseconds.

---

## Summary of the Tutorial Series

Congratulations! You have completed the 9-stage tutorial series:
1. **[Tutorial 1: Hello Coroutines & Basic Yields](01_hello_coroutines.md)**
2. **[Tutorial 2: State & Parameter Passing](02_parameter_passing.md)**
3. **[Tutorial 3: Structured Concurrency (`sync` & `race`)](03_structured_concurrency.md)**
4. **[Tutorial 4: Advanced Decision Trees (`rush`, `fallback`, `with_timeout`, `Ticker`, `with_cancel_token`)](04_advanced_control_flow.md)**
5. **[Tutorial 5: Synchronization & Communication (`with_mutex`, `with_semaphore`, `Event`, `Latch`, `Channel`)](05_synchronization.md)**
6. **[Tutorial 6: Offloading Heavy Compute (`await_async` & `fiber_join`)](06_async_background_jobs.md)**
7. **[Tutorial 7: Stateful Iterators (`Generator(T)`)](07_stateful_generators.md)**
8. **[Tutorial 8: The 3-Tier Multi-Domain Clock Architecture](08_multi_domain_clocks.md)**
9. **[Tutorial 9: Headless CI/CD Gameplay Testing (`simulate_until`)](09_headless_ci_testing.md)**
