# Stackful Coroutines with Structured Concurrency in Odin

> **Compiler Requirement**: Built and verified with Odin `dev-2026-10` (`master` branch commit [`151d53f44`](https://github.com/odin-lang/Odin/commit/151d53f44)).

A high-performance, deterministic **stackful coroutine engine** for [Odin](https://odin-lang.org/), context switching with native inline assembly [`asm`](https://odin-lang.org/docs/inline-asm/).

Write gameplay scripts as straight-line code — `wait`, `yield`, `sync`, `race`, `rush`, `fallback` — while the scheduler handles suspension, cancellation, and hierarchy behind the scenes. No callback spaghetti, no state machines, no OOP boilerplate.

**Verse & SkookumScript-inspired** Structured Concurrency (`sync`/`race`/`rush`/`fallback`/`with_timeout`/`fail`) · Centralized `#config` with build-time `-define` overrides · Packed Generational Handles ($O(1)$ lookups) · Intrusive Waiter Queues (OS Kernel / Futex Pattern with 100% Zero Allocations & True ZII) · Indexed Multi-Domain Clocks (`Clock_Domain` min-heaps with `CLOCK_SIM`, `CLOCK_REAL`, `CLOCK_PHYS`, and child clock inheritance) · Dynamic task join (`fiber_join`) · Typed multicast events (`Event(T)`) & zero-payload broadcast signals (`Signal :: Event(struct{})`) · Zero-drift fiber-owned tickers (`ticker_wait`/`ticker_rebase`) · Lock-free async job bridge (`await_async` / `Async_Token`) · Per-fiber isolated temp allocators (`context.temp_allocator`) · 128B inline by-value payloads (`spawn_val` / `branch_val`) · Multi-tiered stack safety with OS `PAGE_NOACCESS` / POSIX `PROT_NONE` · Modular CSP & synchronization subpackage (`coroutine/sync` for `Channel(T)`, `Fiber_Mutex`, `Fiber_Semaphore`, and `chan_select_recv`).

Ships with interactive **Raylib** demos: a 2D Boss Encounter, an AI & Quest Sandbox, an All-Features Showcase with a live F1 fiber-tree debugger and freeze-frame controls, and a fully automated WebAssembly game build running in headless Node.js.

---

## Highlights

- **Minimal, Orthogonal Verse & SkookumScript Core**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `rush`: First-to-succeed race that ignores early failures and resumes on first success.
  - `fallback`: Sequential priority execution ($A \rightarrow B \rightarrow C$) stopping at first success.
  - `with_timeout`: Auto-cancelling task execution within time limits, with optional cross-clock evaluation.
  - `fail`: Marks the current fiber as failed, causing `rush` to wait for other branches or `fallback` to advance.
- **Indexed Multi-Domain Engine Clocks (`Clock_Domain`)**:
  - `Scheduler` holds an indexed array of timeline domains (`clocks: [MAX_CLOCKS]Clock_Domain`).
  - Predefined domains: `CLOCK_SIM` (pausable gameplay), `CLOCK_REAL` (unpausable UI/menus), `CLOCK_PHYS` (fixed physics/logic steps), plus user-defined domains.
  - Child branches in `sync`/`race`/`rush` automatically inherit `parent.clock_id` (`CLOCK_INHERIT`).
  - Explicit stepped progression: `clock_advance(sched, clock_id, dt, steps)` + `scheduler_run(sched)`, or convenience `scheduler_step(sched, dt, clock_id)`.
  - Zero duplicate APIs: `wait(f, seconds)`, `wait_steps(f, steps)`, and `yield(f)` work transparently across whichever clock domain the fiber belongs to.
- **Intrusive Waiter Queues (100% Zero-Allocation & True ZII)**:
  - Primitives (`Signal`, `Event(T)`, `Wait_Queue`) use doubly-linked intrusive pointers embedded in `Fiber` (`next_waiter`, `prev_waiter`). Zero heap allocations, unbounded waiter capacity, $O(1)$ in-place node removals, and 100% Zero Is Initialization (ZII).
- **Fiber-Owned Zero-Drift Tickers**:
  - Zero-drift timers stored directly inside `Fiber` (`ticker_wait(f, interval)`, `ticker_rebase(f)`), completely immune to WebAssembly Asyncify stack clobbering with no external struct allocations.
- **Unified Events & Broadcast Signals**:
  - `Signal` is a zero-size specialization: `Signal :: Event(struct{})`. One unified, zero-allocation broadcast engine for both typed data payloads and parameterless wakes (`signal_wait`, `signal_emit`, `event_wait`, `event_emit`).
- **Unopinionated Async Job Bridge (`await_async` / `Async_Token`)**:
  - Simple, atomic-backed completion token allowing main-thread fibers to yield cleanly until *any* background OS thread or worker pool marks work complete. Zero scheduler-side condition polling.
- **Optional Synchronization Subpackage (`coroutine/sync`)**:
  - Cleanly isolates Go/OS-style concurrency utilities from the game scripting core:
    - `Channel(T)`: Synchronous unbuffered rendezvous (capacity 0) with timeouts and bounded FIFO buffered queues.
    - `chan_select_recv`: Multi-channel multiplexer awaiting whichever channel is ready first.
    - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion (`mutex_lock`, `mutex_unlock`, `with_mutex`).
    - `Fiber_Semaphore`: Cooperative counting semaphore allowing up to $N$ concurrent permits (`with_semaphore`).
- **Universal Multi-ISA Native Inline Assembly Context Switching**:
  - **AMD64 (x86-64)**: Fast register swap with Windows x64 (160B frame with `xmm6`..`xmm15`) and System V AMD64 (64B frame) calling conventions. Self-ID: `%r12`.
  - **ARM64 (AArch64)**: Native 160B AAPCS64 frame preserving `x19`..`x28`, `x29` (FP), `x30` (LR), and `d8`..`d15` on Apple Silicon (M1–M4), Linux ARM, iOS, Android, and Nintendo Switch. Self-ID: `%x19`.
  - **RISC-V 64 (RV64GC)**: Native 208B LP64D frame preserving `ra`, `s0`..`s11`, and `fs0`..`fs11` for open-source RISC-V hardware and embedded silicon. Self-ID: `%s2`.
  - **WebAssembly (`js_wasm32`)**: Native browser and Node.js execution via Binaryen Asyncify with shadow-stack protection.
- **Isolated Per-Fiber Temporary Allocator**:
  - Embedded 4KB `mem.Arena` in each `Fiber` assigned to `context.temp_allocator`, guaranteeing allocations survive across yield points without cross-coroutine contamination.
- **Multi-Tiered Stack Safety**:
  - Portable heap slabs with 64-byte `0xDEAD_BEEF_CAFE_BABE` canary watermark.
  - OS-level virtual memory allocation with hardware `PAGE_NOACCESS` (Windows) and `mprotect(PROT_NONE)` (Linux/macOS) trapping.
  - Stack watermarking and real-time high-water usage profiling (`fiber_calc_stack_usage`).
- **Structured Scopes & Hierarchical Abort**:
  - `scope_cancel`: Cleanly cancels and unwinds all coroutines attached to an entity scope in $O(1)$.
  - `fiber_cancel`: Cancels an individual fiber and all its descendant children bottom-up.
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
* [`docs/COOKBOOK.md`](docs/COOKBOOK.md) — 17 Production Gameplay Architecture Recipes

### Track 2: Engine Integration & Architecture
*Target Audience: Lead gameplay engineers, engine architects.*
* [`docs/tutorials/06_async_background_jobs.md`](docs/tutorials/06_async_background_jobs.md) — Offloading Heavy Compute via `await_async` & Thread Pools
* [`docs/tutorials/07_stateful_generators.md`](docs/tutorials/07_stateful_generators.md) — Procedural Content & Custom Coroutine Iterators
* [`docs/tutorials/08_multi_domain_clocks.md`](docs/tutorials/08_multi_domain_clocks.md) — Indexed `Clock_Domain` Architecture, Pausable Sim, Real-Time UI & Fixed Steps
* [`docs/tutorials/09_headless_ci_testing.md`](docs/tutorials/09_headless_ci_testing.md) — Headless Simulation Testing in CI/CD Loops
* [`docs/guides/GUIDE_INTEGRATION.md`](docs/guides/GUIDE_INTEGRATION.md) — Drop-in Blueprints for Raylib, Sokol, SDL, GLFW & Custom Loops
* [`docs/guides/GUIDE_SCHEDULERS.md`](docs/guides/GUIDE_SCHEDULERS.md) — Multi-Scheduler Architecture (World vs. UI)
* [`docs/guides/GUIDE_MIGRATION.md`](docs/guides/GUIDE_MIGRATION.md) — Rosetta Stone: Unity `IEnumerator`, Unreal Latent Actions & ASTs

### Track 3: Low-Level Hardware, Memory & Concurrency Specs
*Target Audience: Systems programmers, runtime developers.*
* [`docs/tech/TECH_ASM.md`](docs/tech/TECH_ASM.md) — AMD64 Inline ASM Switch, ABI Registers, Trampolines & `#volatile` Barriers
* [`docs/tech/TECH_WASM_ASYNCIFY.md`](docs/tech/TECH_WASM_ASYNCIFY.md) — WebAssembly Asyncify Architecture, State Machine Unwind/Rewind & Leaf Yield Protocol
* [`docs/wasm/README.md`](docs/wasm/README.md) — Dedicated WebAssembly Suite: Dual-Stack Memory, Zero-C Canvas & WasmFX Roadmap
* [`docs/tech/TECH_CLOCK.md`](docs/tech/TECH_CLOCK.md) — Indexed `Clock_Domain` Array, Min-Heaps & Stepping Architecture
* [`docs/tech/TECH_MEMORY.md`](docs/tech/TECH_MEMORY.md) — 1MB Slabs, Canaries, Hardware `PAGE_NOACCESS` / `PROT_NONE`, 4KB Arenas & Memory Wall
* [`docs/tech/TECH_CONCURRENCY.md`](docs/tech/TECH_CONCURRENCY.md) — Structured Concurrency Tree Topology & Dispatch Pipeline
* [`docs/tech/TECH_PRIMITIVES.md`](docs/tech/TECH_PRIMITIVES.md) — Unified Events/Signals, Async Bridge, and Optional `sync/` Concurrency Primitives
* [`docs/tech/TECH_SDS_AND_HANDLES.md`](docs/tech/TECH_SDS_AND_HANDLES.md) — Static Data Structures, Packed Generational Handles ($O(1)$) & Intrusive Futex Queues

### Track 4: Reliability, Safety Harness & Developer Tooling
*Target Audience: QA engineers, tool developers, production teams.*
* [`docs/guides/GUIDE_FOOTGUNS.md`](docs/guides/GUIDE_FOOTGUNS.md) — The 13 Cooperative Fiber Footguns & Prevention Guide
* [`docs/guides/GUIDE_TIMING_AND_DRIFT.md`](docs/guides/GUIDE_TIMING_AND_DRIFT.md) — Frame Quantization, Time Drift & Fiber-Owned Tickers
* [`docs/guides/GUIDE_DETERMINISM.md`](docs/guides/GUIDE_DETERMINISM.md) — Discrete Step Domain, Float Safety, Netcode & Replays
* [`docs/guides/GUIDE_PERFORMANCE.md`](docs/guides/GUIDE_PERFORMANCE.md) — Zero-Allocation Guarantees, Pre-Warming & Cache Sizing
* [`docs/guides/GUIDE_DEBUGGER.md`](docs/guides/GUIDE_DEBUGGER.md) — Visual F1 Hierarchy Tree HUD, Stack Usage Profiling & Freeze-Step Control
* [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — Complete Engine Architecture Specification
* [`docs/REPORTS.md`](docs/REPORTS.md) — Verification Matrix & Compliance Report

---

## Interactive Games & Examples

### 1. Feature Showcase Game (`examples/showcase`)
A dedicated interactive sandbox game demonstrating engine features across 7 gameplay stations:
- **Station 1 (The Ritual Circle):** `sync` parallel join of 3 charging runes.
- **Station 2 (The Capture Contest):** `race` and `with_timeout` countdown contest.
- **Station 3 (The Energy Charger):** `Fiber_Mutex` queuing 4 AI worker drones into a single charging pad (`coroutine/sync`).
- **Station 4 (The Alert Beacon):** `Signal` broadcast waking 6 sleeping sentries simultaneously and `scope_cancel` lockdown.
- **Station 5 (The Loot Forge):** Procedural on-demand item rolling with custom coroutine iterators.
- **Station 6 (The Async Research Lab):** `Async_Token` & `await_async` bridging OS background worker threads.
- **Station 7 (The Telemetry Feed & Tree Inspector):** CSP `Channel(T)` log stream (`coroutine/sync`) + `F1` real-time tree visualizer and `F3`/`F4` freeze-step controller.

### 2. 2D Boss Encounter Demo (`src/main.odin` & `examples/game`)
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

        coroutine.yield(f)

        fmt.println("Resumed, temp_data[0] is still:", temp_data[0])
    })

    for len(sched.ready_queue) > 0 {
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

### 3. Typed Multicast Event (`Event(T)`) & Broadcast Signal (`Signal`)

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

// Parameterless broadcast signals use the exact same unified engine:
sig: coroutine.Signal
coroutine.signal_emit(&sched, &sig) // or coroutine.event_emit(&sched, &sig)
```

### 4. Zero-Drift Gameplay Ticker (`ticker_wait`)

```odin
// Built-in fiber-owned zero-drift ticker (immune to Wasm shadow-stack clobbering):
for _ in 0 ..< 10 {
    coroutine.ticker_wait(f, interval_seconds = 0.5)
    apply_damage_over_time(enemy, 15.0)
}
```

### 5. Deadlock-Proof Scoped Locks (`coroutine/sync`)

```odin
import sync "coroutine/sync"

// Guarantees unlock on return or abort:
sync.with_mutex(f, &charger_mutex, proc(f: ^coroutine.Fiber, d: ^Drone) {
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

### 7. Multi-Channel Select (`coroutine/sync`)

```odin
import sync "coroutine/sync"

ch_combat, ch_network: sync.Channel(Command)

// Event-driven suspension until ANY channel has a message ready:
idx, cmd, ok := sync.chan_select_recv(f, []^sync.Channel(Command){&ch_combat, &ch_network})
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

# Run All 177 Unit Tests (128 Core + 49 Sync)
.\build.ps1 test

# Cross-Check All 7 Multi-ISA & Wasm Targets
.\build.ps1 check-all

# Execute All Unit Tests in WSL2 via QEMU Emulation (ARM64 & RISC-V 64)
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
| **Windows x86-64 (AMD64)** | Microsoft x64 | 160 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15`, `xmm6`..`xmm15` | `%r12` | **177 / 177 Tests PASS (Native Host Windows)** |
| **Linux x86-64 (AMD64)** | System V AMD64 | 64 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15` | `%r12` | **177 / 177 Tests PASS (Native WSL2 Host CPU)** |
| **Linux ARM64 (AArch64)** | AAPCS64 | 160 bytes | `x29` (FP), `x30` (LR), `x19`..`x28`, `d8`..`d15` | `%x19` | **177 / 177 Tests PASS (WSL2 QEMU)** |
| **Linux RISC-V 64 (RV64GC)** | LP64D | 208 bytes | `ra`, `s0`..`s11`, `fs0`..`fs11` | `%s2` | **177 / 177 Tests PASS (WSL2 QEMU)** |
| **macOS Apple Silicon (ARM64)** | AAPCS64 | 160 bytes | `x29` (FP), `x30` (LR), `x19`..`x28`, `d8`..`d15` | `%x19` | **177 / 177 Tests PASS (AAPCS64 ABI Verified)** |
| **macOS x86-64 (AMD64)** | System V AMD64 | 64 bytes | `rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15` | `%r12` | **177 / 177 Tests PASS (SysV AMD64 ABI Verified)** |
| **WebAssembly (`js_wasm32`)** | Wasm + Asyncify | Linear Memory | Shadow Stack Unwind/Rewind | N/A | **12 / 12 Test Suites + 1000-Frame Headless Game PASS** |

---

## Documentation & Technical Deep Dives

* **[Library Distribution & Vendoring Guide (`DISTRIBUTION.md`)](docs/DISTRIBUTION.md)**: Zero-dependency single-file amalgamation (`dist/coroutine.odin`) and `odin:shared` root package vendoring.
* **[Architecture & Design Specifications (`ARCHITECTURE.md`)](docs/ARCHITECTURE.md)**: Engine design philosophy, structured concurrency invariants, memory lifecycle, and scheduling pipeline.
* **[Cookbook & Gameplay Patterns (`COOKBOOK.md`)](docs/COOKBOOK.md)**: Ready-to-use patterns for cutscenes, boss AI state machines, weapon cooldowns, and physics tweens.
* **[Multi-ISA Stackful Coroutines & Cross-Platform ASM Manual (`PLAN6.md`)](docs/PLAN6.md)**: Production implementation guide, SSA findings, Link Register return trampolines, and opcode tables.
* **[Inline Assembly Guide & Principles (`ASM.md`)](docs/ASM.md)**: Low-level inline assembly conventions and `#byte` machine code standards.
* **[Low-Level Hardware & Inline Assembly Architecture (`TECH_ASM.md`)](docs/tech/TECH_ASM.md)**: Hardware matrices, register preservation contracts, and stack frame layouts for AMD64, ARM64, and RISC-V 64.
* **[WebAssembly Asyncify Architecture & Implementation (`TECH_WASM_ASYNCIFY.md`)](docs/tech/TECH_WASM_ASYNCIFY.md)**: WebAssembly Harvard architecture, Binaryen Asyncify transformation, leaf yield protocols, and dual amalgamation.
* **[Odin Inline Assembly Compiler Analysis & Roadmap (`TECH_ODIN_INLINE_ASM_ANALYSIS.md`)](docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md)**: Compiler frontend internals, SSA register liveness diagnostics, and language roadmap for high-level assembly context switching.
* **[Memory Architecture & Stack Safety (`TECH_MEMORY.md`)](docs/tech/TECH_MEMORY.md)**: Virtual memory guard pages, stack watermarking, and canaries.
* **[Multi-Domain Engine Clocks (`TECH_CLOCK.md`)](docs/tech/TECH_CLOCK.md)**: Continuous zero-drift fixed ticks and time dilation.
* **[Verification & Architecture Compliance Report (`REPORTS.md`)](docs/REPORTS.md)**: 188-test catalog, zero-allocation benchmark telemetry, and multi-ISA target matrix.

---

## License

MIT License.
