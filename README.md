# Stackful Coroutines with Structured Concurrency in Odin

A high-performance, deterministic **stackful coroutine engine** for [Odin](https://odin-lang.org/), context switching with native inline assembly [`asm`](https://odin-lang.org/docs/inline-asm/).

Write gameplay scripts as straight-line code — `wait`, `sync`, `race`, `rush`, `fallback`, `tween` — while the scheduler handles suspension, cancellation, and hierarchy behind the scenes. No callback spaghetti, no state machines, no OOP boilerplate.

**SkookumScript-inspired** Structured Concurrency (`sync`/`race`/`rush`/`fallback`) · 3-Tier Engine Clock (`Sim_Scaled`, `Real_Time`, `Fixed_Tick`) · dynamic task join (`fiber_join`) · typed multicast events (`Event(T)`) · multi-channel select (`chan_select_recv`) · cancellation tokens (`Cancel_Token`) · category mass cancellation (`scheduler_cancel_by_tag`) · counting semaphores (`Fiber_Semaphore`) · countdown latches (`Fiber_Latch`) · cooperative mutexes & signals (`Fiber_Mutex`) · typed CSP channels (`Channel(T)`) · async job bridge (`await_async`) · pull generators (`Generator(T)`) · per-fiber temp allocators (`context.temp_allocator`) · 128B inline by-value payloads · multi-tiered stack safety with OS `PAGE_GUARD` / POSIX `PROT_NONE` · built-in tweening · headless CI simulation (`simulate_until`).

Ships with interactive **Raylib** demos: a 2D Boss Encounter, an AI & Quest Sandbox, and an All-Features Showcase with a live F1 fiber-tree debugger and freeze-frame controls.

---

## Highlights

- **Native AMD64 Inline Assembly Context Switching**: Fast register swap using call/ret trampoline patterns with full register preservation (Windows x64 GPRs + `xmm6`..`xmm15`; System V AMD64 GPRs), `#volatile` and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`), and strict 16-byte stack alignment.
- **3-Tier Multi-Domain Engine Clock**:
  - **Simulation Clock (`sim_time`, `sim_delta`)**: Pausable, scalable gameplay clock for AI, combat, and animations.
  - **Real / Wall Clock (`real_time`, `real_delta`)**: Unpaused clock for UI menus, HUD overlays, and network pings (`wait_real`, `spawn_real`).
  - **Fixed Integer Ticks (`sim_ticks`)**: Integer tick domain for lockstep physics, rollback netcode, and exact replays (`wait_ticks`, `scheduler_step_ticks`).
- **Structured Concurrency & Synchronization Matrix**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `rush`: First-to-succeed race that ignores early failures and resumes on first success.
  - `fallback`: Sequential priority execution ($A \rightarrow B \rightarrow C$) stopping at first success.
  - `with_timeout`: Auto-cancelling task execution within time limits.
  - `fiber_join`: Dynamic task joining allowing fibers to await independent fiber handles (like `pthread_join`).
  - `Event(T)`: 1-to-many publish-subscribe typed event broadcast with zero polling.
  - `chan_select_recv`: Go-style CSP multi-channel multiplexer awaiting whichever channel is ready first.
  - `Cancel_Token`: Decoupled explicit cancellation token for cross-subsystem aborts without shared scopes.
  - `Fiber_Semaphore`: Cooperative counting semaphore allowing up to $N$ concurrent permits.
  - `Fiber_Latch`: Countdown rendezvous synchronization barrier.
  - `Signal`: Zero-polling event broadcasting (`signal_wait`, `signal_emit`).
  - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion queue (`mutex_lock`, `mutex_unlock`, `mutex_try_lock`).
  - `branch :: proc{branch_typed, branch_nil}`: Unified type-safe branch descriptors.
- **Stateful Control & Lifecycle Management**:
  - `Phase_Director`: Dynamic phase coordinator with automatic previous-phase fiber cancellation.
  - `simulate_until`: High-speed headless simulation runner for CI/CD automated gameplay tests.
  - `spawn_val`: 128-byte inline by-value payload storage eliminating heap allocations and dangling stack pointers.
  - `user_tag` & `scheduler_cancel_by_tag`: 4-byte category tagging enabling selective mass cancellations.
  - `scheduler_prewarm`: Pre-allocate memory slabs during level loads to eliminate runtime frame hitches.
  - `scheduler_pool_stats`: Real-time memory telemetry and active stack metrics.
- **Unopinionated Async Job Bridge (`await_async` / `Async_Token`)**:
  - Lock-free, zero-allocation contract allowing main-thread fibers to suspend until *any* background thread pool marks work complete.
- **Pure CSP Typed Channels (`Channel(T)`)**:
  - Synchronous unbuffered rendezvous (capacity 0) and bounded FIFO buffered queues (`chan_send`, `chan_recv`, `chan_try_send`, `chan_try_recv`, `chan_close`).
- **Stateful Pull Generators (`Generator(T)`)**:
  - Zero-allocation pull-based lazy sequence generators for procedural generation, loot rolling, and graph iteration (`yield_value`, `generator_next`).
- **Isolated Per-Fiber Temporary Allocator**:
  - Embedded 4KB `mem.Arena` in each `Fiber` assigned to `context.temp_allocator`, guaranteeing allocations survive across yield points without cross-coroutine contamination.
- **Deterministic Multi-Stage Scheduler**:
  - $O(1)$ Ready FIFO Queue.
  - Dual $O(\log N)$ Binary Min-Heaps (`timer_heap`, `real_timer_heap`) with cached indices for instant removal on cancel.
  - Frame Wait Queue (`wait_frames`, `yield_frame`).
  - Condition Watchlist (`wait_until :: proc{wait_until_typed, wait_until_nil}`).
- **Multi-Tiered Stack Safety**:
  - Configurable `Stack_Allocation_Mode`:
    - `Standard_Slab`: Portable heap slabs with 64-byte `0xDEAD_BEEF_CAFE_BABE` canary watermark.
    - `Virtual_Memory_OS`: OS-level virtual memory allocation with hardware `PAGE_GUARD` (Windows) and `mprotect(PROT_NONE)` (Linux/macOS) trapping.
  - `0xAA` stack watermarking and real-time high-water usage profiling (`fiber_calc_stack_usage`).
- **Hierarchical Cancellations**:
  - `scope_cancel` / `scope_destroy`: Cleanly cancels and unwinds all coroutines attached to an entity scope.
  - `fiber_cancel`: Cancels an individual fiber and all its descendant children bottom-up.
- **Built-in Value Interpolation (`tween`)**:
  - Smooth scalar and `[2]f32` property animation over time with linear, quadratic, and cubic easing curves.
- **Zero Runtime Dependencies**: Engine core is 100% pure Odin and inline assembly.

---

## Complete Documentation Index

```
coroutines_asm/
├── README.md                  # Master Overview, Highlights & Quickstart
├── ARCHITECTURE.md            # Complete Engine Architectural Specification
├── ASM.md                     # Odin Inline Assembly Reference & Grammar
├── CHANGELOG.md               # Version History & Release Notes
├── REPORTS.md                 # Verification Matrix & 81-Test Compliance Report
├── COOKBOOK.md                # 17 Production Gameplay Architecture Recipes
│
├── docs/
│   ├── tech/
│   │   ├── TECH_ASM.md         # Low-Level ASM Switch, Registers & ABI Spec
│   │   ├── TECH_CLOCK.md       # 3-Tier Clock Math, Precision & Drivers
│   │   ├── TECH_MEMORY.md      # Slabs, Canaries, Guard Pages & Temp Arenas
│   │   ├── TECH_CONCURRENCY.md # Structured Concurrency & Coordinator Lifecycle
│   │   └── TECH_PRIMITIVES.md  # Channels, Generators, Async Bridge, Mutexes & Events
│   │
│   ├── tutorials/
│   │   ├── 01_hello_coroutines.md      # Getting Started & Basic Yields
│   │   ├── 02_parameter_passing.md     # Pointers vs By-Value 128B Payloads
│   │   ├── 03_structured_concurrency.md# Boss Fight with sync and race
│   │   ├── 04_advanced_control_flow.md # AI Trees with rush, fallback & timeouts
│   │   ├── 05_synchronization.md       # Signals, Mutexes, Events & Semaphores
│   │   ├── 06_async_background_jobs.md # Offloading Compute via await_async
│   │   ├── 07_stateful_generators.md   # Procedural Loot with Generator(T)
│   │   ├── 08_multi_domain_clocks.md   # Pausing, Time Scale & Fixed Ticking
│   │   └── 09_headless_ci_testing.md   # Headless Simulation with simulate_until
│   │
│   └── guides/
│       ├── GUIDE_TIMING_AND_DRIFT.md # Frame Quantization & Time Drift Prevention
│       ├── GUIDE_FOOTGUNS.md    # The 10 Fiber Footguns & Prevention Guide
│       ├── GUIDE_INTEGRATION.md # Engine Integration (Raylib, Sokol, Custom)
│       ├── GUIDE_SCHEDULERS.md   # Multi-Scheduler Architecture (World vs. UI)
│       ├── GUIDE_DETERMINISM.md  # Determinism, Physics & Rollback Netcode
│       ├── GUIDE_MIGRATION.md    # Migration from Unity / Unreal / AST
│       └── GUIDE_DEBUGGER.md     # In-Engine Tree Inspector & Freeze-Step
```

---

## Interactive Games & Examples

### 1. Feature Showcase Game (`examples/showcase`)
A dedicated interactive sandbox game demonstrating engine features across 7 gameplay stations:
- **Station 1 (The Ritual Circle):** `sync` parallel join of 3 charging runes.
- **Station 2 (The Capture Contest):** `race` and `with_timeout` countdown contest.
- **Station 3 (The Energy Charger):** `Fiber_Mutex` queuing 4 AI worker drones into a single charging pad.
- **Station 4 (The Alert Beacon):** `Signal` broadcast waking 6 sleeping sentries simultaneously.
- **Station 5 (The Loot Forge):** `Generator(T)` procedural on-demand item rolling.
- **Station 6 (The Async Research Lab):** `Async_Token` & `await_async` bridging OS background worker threads.
- **Station 7 (The Telemetry Feed & Tree Inspector):** CSP `Channel(T)` log stream + `F1` real-time tree visualizer and `F3`/`F4` freeze-step controller.

### 2. 2D Boss Encounter Demo (`src/main.odin`)
- **Boss AI Timeline**: Multi-phase behavior running combat `race` triggers, laser charges, and radial bullet barrages.
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
death_event: coroutine.Event(Player_Death_Info)
coroutine.event_init(&death_event)
defer coroutine.event_destroy(&death_event)

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

### 6. 1-Line Task Cancellation (`with_cancel_token`)

```odin
// Executes task, aborting immediately if lockdown alarm trips:
interrupted := coroutine.with_cancel_token(f, &lockdown_token, coroutine.branch(hack_terminal, terminal))
if interrupted {
    fmt.println("Hacking aborted due to lockdown alarm!")
}
```

### 7. Multi-Channel Select (`chan_select_recv`)

```odin
ch_combat, ch_network: coroutine.Channel(Command)

// $O(1)$ Event-driven suspension until ANY channel has a message ready:
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

# Run All 138 Unit Tests
.\build.ps1 test

# Run Full LLVM Optimization & Architecture Matrix (12 builds)
.\build.ps1 matrix
```

---

## License

MIT License.
