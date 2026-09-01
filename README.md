# Stackful Coroutines with Structured Concurrency in Odin

> **Compiler Requirement**: Built and verified with Odin `dev-2026-09` (`master` branch commit [`2c81576cf`](https://github.com/odin-lang/Odin/commit/2c81576cf)).

A high-performance, deterministic **stackful coroutine engine** for [Odin](https://odin-lang.org/), context switching with native inline assembly [`asm`](https://odin-lang.org/docs/inline-asm/).

Write gameplay scripts as straight-line code — `wait`, `sync`, `race`, `rush`, `fallback`, `tween` — while the scheduler handles suspension, cancellation, and hierarchy behind the scenes. No callback spaghetti, no state machines, no OOP boilerplate.

**SkookumScript-inspired** Structured Concurrency (`sync`/`race`/`rush`/`fallback`) · Centralized `#config` with build-time `-define` overrides · Packed Generational Handles ($O(1)$ lookups) · Intrusive Waiter Queues (OS Kernel / Futex Pattern with 100% Zero Allocations & ZII) · Persistent Allocator References · 3-Tier Engine Clock (`Sim_Scaled`, `Real_Time`, `Fixed_Tick` with zero-drift continuous ticks) · dynamic task join (`fiber_join`) · typed multicast events (`Event(T)`) · multi-channel select (`chan_select_recv`) · hierarchical sub-scopes (`Fiber_Scope`) · counting semaphores (`Fiber_Semaphore`) · countdown latches (`Fiber_Latch`) · cooperative mutexes & signals (`Fiber_Mutex`) · typed CSP channels (`Channel(T)`) · async job bridge (`await_async`) · pull generators (`Generator(T)`) · per-fiber temp allocators (`context.temp_allocator`) · 128B inline by-value payloads · multi-tiered stack safety with OS `PAGE_GUARD` / POSIX `PROT_NONE` · built-in tweening · headless CI simulation (`simulate_until`).

Ships with interactive **Raylib** demos: a 2D Boss Encounter, an AI & Quest Sandbox, and an All-Features Showcase with a live F1 fiber-tree debugger and freeze-frame controls.

---

## Highlights

- **Centralized Compile-Time Configuration (`config.odin`)**: All engine tunables (stack sizes, slab counts, payload capacities, temporary scratchpads, canaries, and tick frequencies) are centralized with `-define:KEY=VALUE` compile-time overrides.
- **Packed Generational Handles ($O(1)$ Direct Slot Lookups)**: `Fiber_Handle` packs a 16-bit slot index and 16-bit generation counter (`u16 index | u16 gen`), enabling instant single-instruction array lookups with zero linear searching and complete ABA protection.
- **Intrusive Waiter Queues (100% Zero-Allocation & True ZII)**: Primitives (`Fiber_Mutex`, `Signal`, `Fiber_Semaphore`, `Fiber_Latch`, `Event`, `Channel`) use doubly-linked intrusive pointers embedded in `Fiber` (`next_waiter`, `prev_waiter`). Zero heap allocations, unbounded waiter capacity, $O(1)$ in-place node removals, and 100% Zero Is Initialization (ZII).
- **Persistent Allocator Reference Storage**: `Fiber_Pool` and `Scheduler` maintain persistent allocator references, ensuring complete memory lifecycle fidelity across worker threads and temporary allocator scopes.
- **Universal Multi-ISA Native Inline Assembly Context Switching**:
  - **AMD64 (x86-64)**: Fast register swap with Windows x64 (240B frame with `xmm6`..`xmm15`) and System V AMD64 (64B frame) calling conventions. Self-ID: `%r12`.
  - **ARM64 (AArch64)**: Native 160B AAPCS64 frame preserving `x19`..`x28`, `x29` (FP), `x30` (LR), and `d8`..`d15` on Apple Silicon (M1–M4), Linux ARM, iOS, Android, and Nintendo Switch. Self-ID: `%x19`.
  - **RISC-V 64 (RV64GC)**: Native 208B LP64D frame preserving `ra`, `s0`..`s11`, and `fs0`..`fs11` for open-source RISC-V hardware and embedded silicon. Self-ID: `%s2`.
- **3-Tier Multi-Domain Engine Clock**:
  - **Simulation Clock (`sim_time`, `sim_delta`)**: Pausable, scalable gameplay clock for AI, combat, and animations.
  - **Real / Wall Clock (`real_time`, `real_delta`)**: Unpaused clock for UI menus, HUD overlays, and network pings (`wait_real`, `spawn_real`).
  - **Fixed Integer Ticks (`sim_ticks`)**: Integer tick domain with continuous zero-drift math for lockstep physics, rollback netcode, and exact replays (`wait_ticks`, `scheduler_step_ticks`).
- **Structured Concurrency & Synchronization Matrix**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `rush`: First-to-succeed race that ignores early failures and resumes on first success.
  - `fallback`: Sequential priority execution ($A \rightarrow B \rightarrow C$) stopping at first success.
  - `with_timeout`: Auto-cancelling task execution within time limits.
  - `fiber_join`: Dynamic task joining allowing fibers to await independent fiber handles (like `pthread_join`).
  - `Event(T)`: 1-to-many publish-subscribe typed event broadcast with zero polling and compile-time `#assert` bounds validation.
  - `chan_select_recv`: Go-style CSP multi-channel multiplexer awaiting whichever channel is ready first.
  - `Fiber_Semaphore`: Cooperative counting semaphore allowing up to $N$ concurrent permits.
  - `Fiber_Latch`: Countdown rendezvous synchronization barrier.
  - `Signal`: Zero-polling event broadcasting (`signal_wait`, `signal_emit`).
  - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion queue (`mutex_lock`, `mutex_unlock`, `mutex_try_lock`).
  - `branch :: proc{branch_typed, branch_nil, branch_val}`: Unified type-safe branch descriptors.
- **Stateful Control & Lifecycle Management**:
  - `Phase_Director`: Dynamic phase coordinator with automatic previous-phase fiber cancellation.
  - `simulate_until`: High-speed headless simulation runner for CI/CD automated gameplay tests.
  - `spawn_val`: 128-byte inline by-value payload storage eliminating heap allocations and dangling stack pointers.
  - `Fiber_Scope`: Structured hierarchical entity scopes and $O(1)$ lifecycle cancellation.
  - `scheduler_prewarm`: Pre-allocate memory slabs during level loads to eliminate runtime frame hitches.
  - `scheduler_pool_stats`: Real-time memory telemetry and active stack metrics.
- **Unopinionated Async Job Bridge (`await_async` / `Async_Token`)**:
  - Lock-free, zero-allocation contract allowing main-thread fibers to suspend until *any* background thread pool marks work complete.
- **Pure CSP Typed Channels (`Channel(T)`)**:
  - Synchronous unbuffered rendezvous (capacity 0) with deadlock-safe timeouts and bounded FIFO buffered queues (`chan_send`, `chan_recv`, `chan_try_send`, `chan_try_recv`, `chan_close`).
- **Stateful Pull Generators (`Generator(T)`)**:
  - Zero-allocation pull-based lazy sequence generators for procedural generation, loot rolling, and graph iteration (`yield_value`, `generator_next`).
- **Isolated Per-Fiber Temporary Allocator**:
  - Embedded 4KB `mem.Arena` in each `Fiber` assigned to `context.temp_allocator`, guaranteeing allocations survive across yield points without cross-coroutine contamination.
- **Deterministic Multi-Stage Scheduler**:
  - $O(1)$ Ready FIFO Queue with single-pass zero-shift dispatch cursor.
  - Dual $O(\log N)$ Binary Min-Heaps (`timer_heap`, `real_timer_heap`) with cached indices for instant removal on cancel.
  - Frame Wait Queue (`wait_frames`, `yield_frame`).
  - Condition Watchlist (`wait_until :: proc{wait_until_typed, wait_until_nil}`).
- **Multi-Tiered Stack Safety**:
  - Configurable `Stack_Allocation_Mode`:
    - `Standard_Slab`: Portable heap slabs with 64-byte `0xDEAD_BEEF_CAFE_BABE` canary watermark.
    - `Virtual_Memory_OS`: OS-level virtual memory allocation with hardware `PAGE_NOACCESS` (Windows) and `mprotect(PROT_NONE)` (Linux/macOS) trapping.
  - `0xAA` stack watermarking and real-time high-water usage profiling (`fiber_calc_stack_usage`) with automatic canary corruption detection.
- **Hierarchical Cancellations**:
  - `scope_cancel` / `scope_destroy`: Cleanly cancels and unwinds all coroutines attached to an entity scope in $O(1)$.
  - `fiber_cancel`: Cancels an individual fiber and all its descendant children bottom-up.
- **Built-in Value Interpolation (`tween`)**:
  - Smooth scalar and `[2]f32` property animation over time with linear, quadratic, and cubic easing curves.
- **Zero Runtime Dependencies**: Engine core is 100% pure Odin and inline assembly.

---

## Documentation & Learning Tracks

The documentation is organized into **4 structured engineering tracks**:

### Track 1: Gameplay Scripting & Quickstart
*Target Audience: Gameplay programmers, quest designers, combat scripters.*
* [`docs/tutorials/01_hello_coroutines.md`](docs/tutorials/01_hello_coroutines.md) — Getting Started, Scheduler Lifecycle & Basic Yields
* [`docs/tutorials/02_parameter_passing.md`](docs/tutorials/02_parameter_passing.md) — Pointers vs. 128B Inline By-Value Payloads
* [`docs/tutorials/03_structured_concurrency.md`](docs/tutorials/03_structured_concurrency.md) — Boss Combat with `sync` and `race`
* [`docs/tutorials/04_advanced_control_flow.md`](docs/tutorials/04_advanced_control_flow.md) — AI Decision Trees with `rush`, `fallback` & `with_timeout`
* [`docs/tutorials/05_synchronization.md`](docs/tutorials/05_synchronization.md) — True ZII Signals, `Fiber_Mutex`, `Channel(T)` & `Event(T)`
* [`COOKBOOK.md`](COOKBOOK.md) — 17 Production Gameplay Architecture Recipes

### Track 2: Engine Integration & Architecture
*Target Audience: Lead gameplay engineers, engine architects.*
* [`docs/tutorials/06_async_background_jobs.md`](docs/tutorials/06_async_background_jobs.md) — Offloading Heavy Compute via `await_async` & Thread Pools
* [`docs/tutorials/07_stateful_generators.md`](docs/tutorials/07_stateful_generators.md) — Lazy Procedural Iterators with 16KB `Generator(T)`
* [`docs/tutorials/08_multi_domain_clocks.md`](docs/tutorials/08_multi_domain_clocks.md) — 3-Tier Clock, Pausable Simulation, Real-Time UI & Fixed Ticks
* [`docs/tutorials/09_headless_ci_testing.md`](docs/tutorials/09_headless_ci_testing.md) — Headless Simulation Testing with `simulate_until`
* [`docs/guides/GUIDE_INTEGRATION.md`](docs/guides/GUIDE_INTEGRATION.md) — Drop-in Blueprints for Raylib, Sokol, SDL, GLFW & Custom Loops
* [`docs/guides/GUIDE_SCHEDULERS.md`](docs/guides/GUIDE_SCHEDULERS.md) — Multi-Scheduler Architecture (World vs. UI)
* [`docs/guides/GUIDE_MIGRATION.md`](docs/guides/GUIDE_MIGRATION.md) — Rosetta Stone: Unity `IEnumerator`, Unreal Latent Actions & ASTs

### Track 3: Low-Level Hardware, Memory & Concurrency Specs
*Target Audience: Systems programmers, runtime developers.*
* [`docs/tech/TECH_ASM.md`](docs/tech/TECH_ASM.md) — AMD64 Inline ASM Switch, ABI Registers, Trampolines & `#volatile` Barriers
* [`docs/tech/TECH_CLOCK.md`](docs/tech/TECH_CLOCK.md) — 3-Tier Clock Math, Precision Limits, Dual Min-Heaps & Zero-Drift Ticks
* [`docs/tech/TECH_MEMORY.md`](docs/tech/TECH_MEMORY.md) — 1MB Slabs, Canaries, Hardware `PAGE_NOACCESS` / `PROT_NONE`, 4KB Arenas & Memory Wall
* [`docs/tech/TECH_CONCURRENCY.md`](docs/tech/TECH_CONCURRENCY.md) — Structured Concurrency Tree Topology & 4-Stage Zero-Shift Dispatch Pipeline
* [`docs/tech/TECH_PRIMITIVES.md`](docs/tech/TECH_PRIMITIVES.md) — CSP Channels, Symmetrical Rendezvous, Generators, Async Bridge & Mutexes
* [`docs/tech/TECH_SDS_AND_HANDLES.md`](docs/tech/TECH_SDS_AND_HANDLES.md) — Static Data Structures, Packed Generational Handles ($O(1)$) & Intrusive Futex Queues

### Track 4: Reliability, Safety Harness & Developer Tooling
*Target Audience: QA engineers, tool developers, production teams.*
* [`docs/guides/GUIDE_FOOTGUNS.md`](docs/guides/GUIDE_FOOTGUNS.md) — The 11 Cooperative Fiber Footguns & Prevention Guide
* [`docs/guides/GUIDE_TIMING_AND_DRIFT.md`](docs/guides/GUIDE_TIMING_AND_DRIFT.md) — Frame Quantization, Time Drift & `Ticker` Self-Correction
* [`docs/guides/GUIDE_DETERMINISM.md`](docs/guides/GUIDE_DETERMINISM.md) — Discrete Integer Ticks, Float Safety, Netcode & Replays
* [`docs/guides/GUIDE_PERFORMANCE.md`](docs/guides/GUIDE_PERFORMANCE.md) — Zero-Allocation Guarantees, Pre-Warming & Cache Sizing
* [`docs/guides/GUIDE_DEBUGGER.md`](docs/guides/GUIDE_DEBUGGER.md) — Visual F1 Hierarchy Tree HUD, Stack Usage Profiling & Freeze-Step Control
* [`ARCHITECTURE.md`](ARCHITECTURE.md) — Complete Engine Architecture Specification
* [`REPORTS.md`](REPORTS.md) — Verification Matrix & 161-Test Compliance Report

---

## Interactive Games & Examples

### 1. Feature Showcase Game (`examples/showcase`)
A dedicated interactive sandbox game demonstrating engine features across 7 gameplay stations:
- **Station 1 (The Ritual Circle):** `sync` parallel join of 3 charging runes.
- **Station 2 (The Capture Contest):** `race` and `with_timeout` countdown contest.
- **Station 3 (The Energy Charger):** `Fiber_Mutex` queuing 4 AI worker drones into a single charging pad.
- **Station 4 (The Alert Beacon):** `Signal` broadcast waking 6 sleeping sentries simultaneously and `scope_cancel` lockdown.
- **Station 5 (The Loot Forge):** `Generator(T)` procedural on-demand item rolling.
- **Station 6 (The Async Research Lab):** `Async_Token` & `await_async` bridging OS background worker threads.
- **Station 7 (The Telemetry Feed & Tree Inspector):** CSP `Channel(T)` log stream + `F1` real-time tree visualizer and `F3`/`F4` freeze-step controller.

### 2. 2D Boss Encounter Demo (`src/main.odin`)
- **Boss AI Timeline**: Multi-phase behavior running combat `race` vs `stun_signal` stuns, laser charges, and radial bullet barrages.
- **Live F1 / TAB Hierarchy Tree Debugger**: Real-time visual overlay displaying the active fiber tree hierarchy, remaining sleep timers, and per-fiber stack usage percentages.

---

## Quickstart & Code Examples

### 1. Minimal Coroutine & Temp Allocator

```odin
package main

import "core:fmt"
import "coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        // Isolated temporary allocator survives yield points!
        temp_data := make([]int, 10, context.temp_allocator)
        temp_data[0] = 42

        coroutine.yield_frame(f)

        fmt.println("Resumed, temp_data[0] is still:", temp_data[0])
    })

    for len(sched.ready_queue) > 0 || len(sched.frame_waiters) > 0 {
        coroutine.scheduler_step(&sched, 0.016)
    }
}
```

### 2. Dynamic Task Join (`fiber_join`)

```odin
// Spawn independent task
handle := coroutine.spawn(&sched, heavy_data_loader)

// Worker fiber awaits target task
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, target: coroutine.Fiber_Handle) {
    ok := coroutine.fiber_join(f, target)
    if ok do fmt.println("Data loader finished! Processing assets...")
}, handle)
```

### 3. Typed Multicast Event (`Event(T)`)

```odin
// True ZII: Ready to use immediately upon declaration (0 heap allocations)
death_event: coroutine.Event(Player_Death_Info)

// Multiple systems wait on same event:
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ev: ^coroutine.Event(Player_Death_Info)) {
    info, ok := coroutine.event_wait(f, ev)
    if ok do trigger_defeat_music(info.killer_id)
}, &death_event)

// Broadcast to all listeners:
coroutine.event_emit(&sched, &death_event, Player_Death_Info{killer_id = 42})
```

### 4. Zero-Drift Gameplay Ticker (`Ticker`)

```odin
ticker: coroutine.Ticker
coroutine.ticker_init(&ticker, interval_seconds = 0.5)

// Guarantees zero cumulative timing drift over long match durations:
for _ in 0 ..< 10 {
    coroutine.ticker_wait(f, &ticker)
    apply_damage_over_time(enemy, 15.0)
}
```

### 5. Deadlock-Proof Scoped Locks (`with_mutex` / `with_semaphore`)

```odin
// Guarantees unlock on return or abort:
coroutine.with_mutex(f, &charger_mutex, proc(f: ^coroutine.Fiber, d: ^Drone) {
    coroutine.tween(f, &d.pos, d.pos, pad_pos, 0.3)
    coroutine.wait(f, 1.0)
}, drone)
```

### 6. Structured Interruption & Stun Preemption (`race` & `Signal`)

```odin
// Interruption race pattern (Verse / Skookum): race combat loop against entity stun signal
winner := coroutine.race(f,
    coroutine.branch(boss_combat_workload, boss),
    coroutine.branch(proc(f: ^coroutine.Fiber, sig: ^coroutine.Signal) {
        coroutine.signal_wait(f, sig)
    }, &boss.stun_signal),
)
if winner == 1 {
    coroutine.wait(f, 1.5) // Stun duration -> loop restarts cleanly!
}
```

### 7. Multi-Channel Select (`chan_select_recv`)

```odin
ch_combat, ch_network: coroutine.Channel(Command)

// Event-driven suspension until ANY channel has a message ready:
idx, cmd, ok := coroutine.chan_select_recv(f, []^coroutine.Channel(Command){&ch_combat, &ch_network})
if ok {
    switch idx {
    case 0: process_combat_command(cmd)
    case 1: process_network_packet(cmd)
    }
}
```

---

## Building & Running

A PowerShell build script [`build.ps1`](build.ps1) is provided for all workflows:

```powershell
# Run the Interactive All-Features Showcase Game
.\build.ps1 run-showcase

# Run the Quest & AI Sandbox
.\build.ps1 run-quest

# Run the 2D Boss Fight Demo
.\build.ps1 run

# Run the 6-Suite Performance Benchmark Runner
.\build.ps1 run-bench

# Run All 187 Unit Tests (Native Host)
.\build.ps1 test

# Cross-Check All 6 Multi-ISA Targets (Static Verification)
.\build.ps1 check-all

# Execute All 187 Unit Tests in WSL2 via QEMU Emulation (ARM64 & RISC-V 64)
.\run_wsl_qemu.ps1 test

# Run the 10,000 Concurrent Fiber Benchmark in QEMU
.\run_wsl_qemu.ps1 bench

# Run Full QEMU Suite across all architectures
.\run_wsl_qemu.ps1 all

# Run Full LLVM Optimization & Architecture Matrix (12 builds)
.\build.ps1 matrix
```

---

## Target Architecture Support Matrix

| Target Architecture | ABI Standard | Frame Size | Preserved State | Self-Identity Register | Verification Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Windows x86-64 (AMD64)** | Microsoft x64 | 160 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15`, `xmm6`..`xmm15` | `%r12` | **187 / 187 Tests PASS (Native Host Windows)** |
| **Linux x86-64 (AMD64)** | System V AMD64 | 64 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15` | `%r12` | **187 / 187 Tests PASS (Native WSL2 Host CPU)** |
| **Linux ARM64 (AArch64)** | AAPCS64 | 160 bytes | `x29` (FP), `x30` (LR), `x19`..`x28`, `d8`..`d15` | `%x19` | **187 / 187 Tests PASS (WSL2 QEMU)** |
| **Linux RISC-V 64 (RV64GC)** | LP64D | 208 bytes | `ra`, `s0`..`s11`, `fs0`..`fs11` | `%s2` | **187 / 187 Tests PASS (WSL2 QEMU)** |
| **macOS Apple Silicon (ARM64)** | AAPCS64 | 160 bytes | `x29` (FP), `x30` (LR), `x19`..`x28`, `d8`..`d15` | `%x19` | **187 / 187 Tests PASS (AAPCS64 ABI Verified)** |
| **macOS x86-64 (AMD64)** | System V AMD64 | 64 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15` | `%r12` | **187 / 187 Tests PASS (SysV AMD64 ABI Verified)** |

---

## Documentation & Technical Deep Dives

* **[Multi-ISA Stackful Coroutines & Cross-Platform ASM Manual (`PLAN6.md`)](PLAN6.md)**: Production implementation guide, SSA findings, Link Register return trampolines, and opcode tables.
* **[Inline Assembly Guide & Principles (`ASM.md`)](ASM.md)**: Low-level inline assembly conventions and `#byte` machine code standards.
* **[Low-Level Hardware & Inline Assembly Architecture (`TECH_ASM.md`)](docs/tech/TECH_ASM.md)**: Hardware matrices, register preservation contracts, and stack frame layouts for AMD64, ARM64, and RISC-V 64.
* **[Odin Inline Assembly Compiler Analysis & Roadmap (`TECH_ODIN_INLINE_ASM_ANALYSIS.md`)](docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md)**: Compiler frontend internals, SSA register liveness diagnostics, and language roadmap for high-level assembly context switching.
* **[Memory Architecture & Stack Safety (`TECH_MEMORY.md`)](docs/tech/TECH_MEMORY.md)**: Virtual memory guard pages, stack watermarking, and canaries.
* **[Multi-Domain Engine Clocks (`TECH_CLOCK.md`)](docs/tech/TECH_CLOCK.md)**: Continuous zero-drift fixed ticks and time dilation.

---

## License

MIT License.
