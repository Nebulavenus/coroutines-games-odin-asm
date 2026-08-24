# Changelog

All notable changes to this project will be documented in this file.

## [Pure Systems Enhancements & POSIX Parity] - 2026-08-24

### Added
- **Multi-Channel Select (`chan_select_recv` / `chan_try_select_recv`)**:
  - Go-style CSP multiplexer allowing fibers to await whichever channel has a message available first (`chan_select_recv`) or inspect channels non-blockingly (`chan_try_select_recv`).
- **Explicit Cancellation Token (`Cancel_Token`)**:
  - Decoupled, lightweight cancellation handle (`cancel_token_init`, `cancel_token_destroy`, `cancel_token_cancel`, `cancel_token_is_cancelled`, `cancel_token_wait`).
  - Allows multiple independent fibers across different entity scopes to coordinate cancellation without sharing an intrusive `Fiber_Scope`.
- **Category User Tags & Mass Cancellation (`user_tag`, `scheduler_cancel_by_tag`, `scheduler_count_by_tag`)**:
  - Added 4-byte `user_tag: u32` to `Fiber` and `tag: u32 = 0` to all `spawn` procedures.
  - Added `scheduler_cancel_by_tag(sched, tag)` and `scheduler_count_by_tag(sched, tag)` for category mass cancellations (e.g. aborting all combat AI upon EMP).
- **POSIX Hardware Guard Page Parity (`mmap` + `mprotect(PROT_NONE)`)**:
  - `pool.odin` now implements hardware MMU crash trapping on Linux, macOS, and BSD systems via `posix.mmap` and `posix.mprotect(PROT_NONE)`.
- **Unit Tests 82–90 (`src/coroutine/coroutine_test.odin`)**:
  - 9 new unit tests covering multi-channel select, closed channel select handling, cancellation tokens, user tags, and tagged mass cancellations.
  - Test suite expanded to **90 / 90 unit tests passing** (100%).

## [Pure Concurrency Primitives & Telemetry] - 2026-08-24

### Added
- **Dynamic Task Joining (`fiber_join(f, handle)`)**:
  - Allows fibers to await the completion of independent fiber handles across different scopes or root tasks.
  - Returns `true` if target completed with `.Completed`, and `false` if aborted/failed.
- **Typed Multicast Event (`Event(T)`)**:
  - 1-to-Many publish-subscribe synchronization primitive (`event_init`, `event_destroy`, `event_wait`, `event_emit`, `event_waiter_count`, `event_has_waiters`).
  - Zero polling; delivers typed payloads to all active listeners in a single broadcast frame.
- **Counting Semaphore (`Fiber_Semaphore`)**:
  - Cooperative Dijkstra counting semaphore allowing up to $N$ concurrent permits (`semaphore_init`, `semaphore_destroy`, `semaphore_try_acquire`, `semaphore_acquire`, `semaphore_release`, `semaphore_available_permits`).
- **Countdown Latch / Barrier (`Fiber_Latch`)**:
  - Rendezvous barrier unblocking waiting fibers once counted down $N$ times (`latch_init`, `latch_destroy`, `latch_count_down`, `latch_wait`, `latch_get_count`, `latch_is_ready`).
- **Loading-Screen Memory Pre-Warming (`scheduler_prewarm` / `fiber_pool_prewarm`)**:
  - Allows games to pre-allocate slabs during level loads to eliminate runtime frame hitches.
- **Handle Introspection & Memory Telemetry (`fiber_is_alive`, `fiber_status`, `Pool_Stats`)**:
  - Safe handle querying via circular `handle_history` and real-time pool memory statistics (`scheduler_pool_stats`).
- **RTS Unit Action Queue Recipe (`COOKBOOK.md`)**:
  - Added Recipe 9 demonstrating unit command queuing with `Fiber_Scope` and preemption.
- **Unit Tests 71–81 (`src/coroutine/coroutine_test.odin`)**:
  - 11 new tests covering task join, multicast events, counting semaphores, countdown latches, pool pre-warming, and handle introspection. 81 / 81 unit tests passing (100%).

## [Documentation Suite, Technical Deep-Dives & Tutorials] - 2026-08-24

### Added
- **Complete Technical Documentation Suite (`docs/tech/`)**:
  - `TECH_ASM.md`: Low-level AMD64 context switching mechanics, Windows x64 vs System V ABI register preservation, call/ret trampoline, `#volatile` compiler clobbers, and 16-byte stack alignment invariants.
  - `TECH_CLOCK.md`: The physics and mathematics of game clocks ($f32$ vs $f64$ vs $u64$), the 3 clock domains, pluggable engine time drivers, and dual min-heap design.
  - `TECH_MEMORY.md`: Slab allocation strategy, 3-tier safety invariants (canaries, $0xAA$ profiling, OS `PAGE_GUARD`), per-fiber 4KB isolated temp arenas, and 128B inline payload storage.
  - `TECH_CONCURRENCY.md`: Structured concurrency matrix (`sync`, `race`, `rush`, `fallback`, `with_timeout`), `Join_Coordinator` intrusive tree topology, and bottom-up hierarchical cancellation.
  - `TECH_PRIMITIVES.md`: CSP typed channels (`Channel(T)`), stateful pull generators (`Generator(T)`), async background job bridge (`await_async`), and cooperative mutexes/signals.
- **Progressive 9-Stage Tutorial Series (`docs/tutorials/`)**:
  - `01_hello_coroutines.md`: Getting started, scheduler lifecycle, and straight-line yields (`wait`, `wait_frames`, `yield_frame`, `wait_until`).
  - `02_parameter_passing.md`: Entity pointers (`spawn_ptr`) vs 128-byte by-value payloads (`spawn_val`).
  - `03_structured_concurrency.md`: Multi-branch coordination with `sync` and preemption with `race`.
  - `04_advanced_control_flow.md`: Behavior trees with `fallback`, parallel quest racing with `rush`, and time constraints with `with_timeout`.
  - `05_synchronization.md`: Decoupled game systems using `Signal`, `Fiber_Mutex`, and `Channel(T)`.
  - `06_async_background_jobs.md`: Offloading heavy calculations via `await_async` without dropping frames.
  - `07_stateful_generators.md`: Lazy sequence streams and loot drop rolling with `Generator(T)`.
  - `08_multi_domain_clocks.md`: Real-time UI menus during paused simulation, bullet-time `time_scale`, fixed-tick physics.
  - `09_headless_ci_testing.md`: Blazing fast headless gameplay testing with `simulate_until` and zero-leak tracking.
- **Game Engine Integration & Architecture Guides (`docs/guides/`)**:
  - `GUIDE_INTEGRATION.md`: Integration blueprints for Raylib, Sokol, GLFW, SDL, and custom fixed/variable loops.
  - `GUIDE_SCHEDULERS.md`: Multi-scheduler setups (World vs UI) and scene lifecycle management.
  - `GUIDE_DETERMINISM.md`: Deterministic lockstep ticking, cross-architecture float safety, replays, and rollback netcode.
  - `GUIDE_MIGRATION.md`: Rosetta stone migration guide from Unity C# `IEnumerator`, Unreal Latent Actions, and stackless AST coroutines.
  - `GUIDE_DEBUGGER.md`: Visual fiber hierarchy inspector, live stack telemetry, freeze-frame stepping, and slow-motion controls.
- **Root Document Modernization**:
  - Synchronized `README.md`, `ARCHITECTURE.md`, `REPORTS.md` (70-test matrix), and `COOKBOOK.md` (8 production gameplay recipes).

## [3-Tier Engine Clock Architecture] - 2026-08-24

### Added
- **3-Tier Multi-Domain Engine Clock (`Scheduler_Clock` & `Time_Clock`)**:
  - **1. Real / Wall Clock (`real_time: f64`, `real_delta: f32`, `real_ticks: u64`)**: Unscaled and unpaused clock for UI, pause menus, network timeouts, and diagnostics (`wait_real`, `spawn_real`, `delta_real`, `real_time`).
  - **2. Scaled Simulation Clock (`sim_time: f64`, `sim_delta: f32`, `time_scale: f32`, `is_paused: bool`)**: Scaled gameplay clock for AI, combat, tweens, and timers (`wait`, `delta_time`, `current_time`).
  - **3. Discrete Simulation Ticks (`sim_ticks: u64`, `tick_rate_hz: u32`, `frame_count: u64`)**: Zero-drift integer ticking for deterministic physics, replay systems, and rollback netcode (`wait_ticks`, `current_ticks`, `scheduler_step_ticks`).
- **Engine-Agnostic Pluggable Time Drivers**:
  - `scheduler_step(sched, dt)`: Variable frame delta step.
  - `scheduler_single_step(sched, dt)`: Forced simulation step during debugger pause.
  - `scheduler_step_ticks(sched, ticks)`: Integer tick driver for fixed physics and headless testing.
  - `scheduler_step_dual(sched, real_dt, sim_dt)`: Dual real/simulation delta driver.
- **Dual Min-Heap & Multi-Queue Synchronization**:
  - `real_timer_heap`: Dedicated $O(\log N)$ min-heap for real-time timers.
  - `timer_heap`: Scaled simulation timer min-heap.
  - `tick_waiters`: Discrete integer tick waiting queue.
- **Unit Tests 67–70 (`src/coroutine/coroutine_test.odin`)**:
  - Tests covering real-time execution while paused (`test_real_time_clock_while_paused`), fixed integer discrete ticks (`test_fixed_integer_tick_clock`), dual-clock slow-mo / fast-forward scaling (`test_dual_clock_time_scaling`), and multi-clock heap integrity (`test_multi_clock_heap_integrity`). 70 / 70 unit tests passing (100%).

## [Gameplay Control Flow, Phase Director & Headless Runner] - 2026-08-24

### Added
- **`fallback` & `rush` Advanced Concurrency Operators**:
  - `fallback(f, ..branches)`: Sequential branch priority fallback ($A \rightarrow B \rightarrow C$), executing until the first successful branch.
  - `rush(f, ..branches)`: Parallel success preemption ($A \parallel B \parallel C$), ignoring early failures and aborting remaining siblings upon the first `.Completed` branch.
  - `fail(f)`: First-class failure primitive setting fiber status to `.Failed` and notifying parent coordinators.
- **`Phase_Director` Finite State Machine**:
  - Structured FSM driver for boss phases, dialogue trees, and cutscenes (`phase_director_init`, `phase_director_destroy`, `phase_switch`, `phase_current`, `phase_name`, `phase_is_busy`).
  - Automatically cancels and cleans up all active coroutines belonging to old phases upon state transition.
- **Headless Simulation Runner (`simulate_until`)**:
  - CI/CD automated test harness stepping the scheduler in virtual delta-time without real-time delay or window creation (`simulate_until :: proc{simulate_until_ptr, simulate_until_nil}`).
- **Interactive Debugger Freeze-Step & Slow-Motion Engine**:
  - `[F3]`: Unified Simulation Freeze / Pause (`sched.is_paused`) halting coroutines, world time, and entity physics in unison.
  - `scheduler_single_step(sched, dt)`: Dedicated stepping procedure to force execution forward while `is_paused` is active.
  - **Input Latching While Paused**: Action keys (`[1]`–`[6]`, `[E]`, `[Space]`, `[LMB]`, `[3]`, `[T]`) pressed while paused are latched and executed on the next step frame.
  - `[F4]`: Single-Frame Step ($1\text{ frame} = 0.016s$).
  - `[F5]` / `[Shift+F4]`: Multi-Frame Jump ($10\text{ frames} = 0.160s$) for rapid progression through sleeps and tweens.
  - **Hold `[F4]`**: Continuous Slow-Motion Stepping at 15 FPS for smooth frame-by-frame inspection.
  - Live HUD step badge with step count, step delta ($+0.016s$), simulation timestamp, and green flash confirmation pulse.
  - Visualizer overlay supports `Sync`, `Race`, `Rush`, and `Fallback` branch descriptors.
- **Gameplay Cookbook (`COOKBOOK.md`)**:
  - 5 complete, production-ready gameplay architecture patterns (Ability Channeling, Dialogue Trees, Multi-Wave Spawners, Behavior Fallbacks, and Damped Spring Followers).
- **Unit Tests 56–66 (`src/coroutine/coroutine_test.odin`)**:
  - Automated tests covering `fallback`, `rush`, `Phase_Director`, `simulate_until`, `fail` primitive error propagation, all-failing edge cases, 5-branch rushes, rapid multi-phase transitions, headless channel pipelines, deeply nested combinators, and paused single-stepping execution (`test_scheduler_step_while_paused`).
- **Quest & AI Interactive Showcase (`examples/quest_ai`)**:
  - 4-zone interactive Raylib showcase featuring AI Behavior Decision Trees (`fallback`), Competitive Objective Quests (`rush`), Void Sentinel Boss FSM (`Phase_Director`), and On-Screen Simulation Benchmarks (`simulate_until`).
  - Added `.\build.ps1 quest` and `.\build.ps1 run-quest` build automation.
- **Main Boss Game Refactor (`src/main.odin`)**:
  - Integrated `coroutine.Phase_Director` into `Boss` struct and game lifecycle.
