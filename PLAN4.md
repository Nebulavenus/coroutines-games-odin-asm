# Master Documentation, Tutorial & Technical Guide Roadmap

This document establishes the comprehensive blueprint for documenting the **Odin Stackful Coroutine & Structured Concurrency Engine**. It details the exact structure, technical topics, tutorials, and architectural guides to be produced.

---

## Roadmap Overview

```
                                DOCUMENTATION MASTER PLAN
 ┌───────────────────────────────────────────┬───────────────────────────────────────────┐
 │ PART 1: EXISTING DOCUMENT SYNCHRONIZATION │ PART 2: LOW-LEVEL TECHNICAL SPECIFICATIONS│
 │ • README.md (Comprehensive Redesign)      │ • Low-Level ASM Context Switch & ABI      │
 │ • ARCHITECTURE.md (Modern Specification)  │ • 3-Tier Multi-Domain Engine Clock        │
 │ • REPORTS.md (70-Test Full Verification)  │ • Memory Isolation & Multi-Tier Safety    │
 │ • COOKBOOK.md (Gameplay Recipes)          │ • Structured Concurrency & Coordinators   │
 ├───────────────────────────────────────────┼───────────────────────────────────────────┤
 │ PART 3: PROGRESSIVE TUTORIAL SERIES (1-9) │ PART 4: ENGINE INTEGRATION & GUIDES       │
 │ • 1. Hello Coroutines & Basic Yields      │ • Game Engine Integration (Raylib/Sokol)  │
 │ • 2. Parameter Passing & 128B Payloads    │ • Determinism, Netcode & Fixed Ticking    │
 │ • 3. Structured Concurrency (sync/race)   │ • Multi-Scheduler Setup (World vs. UI)    │
 │ • 4. Advanced Control Flow (rush/fallback)│ • Migration Guide (Unity/Unreal/AST)      │
 │ • 5. Synchronization (Signals & Mutexes)  │ • Interactive Debugger & Telemetry Manual │
 └───────────────────────────────────────────┴───────────────────────────────────────────┘
```

---

# Part 1: Existing Documentation Synchronization

| File | Primary Update Objectives |
| :--- | :--- |
| **`README.md`** | • Modernize feature matrix to reflect all **70 unit tests** and latest capabilities.<br>• Document the **3-Tier Engine Clock** (`Sim_Scaled`, `Real_Time`, `Fixed_Tick`).<br>• Add quickstart guides for `fallback`, `rush`, `Phase_Director`, and `simulate_until`.<br>• Update benchmark and build matrix tables. |
| **`ARCHITECTURE.md`** | • Document complete architectural diagrams of the dual min-heaps (`timer_heap`, `real_timer_heap`).<br>• Detail the $O(1)$ ring-buffer channel and 16KB lightweight generator pool.<br>• Provide exact memory layout specs for the 128-byte inline payload buffer and synthetic stack frame. |
| **`REPORTS.md`** | • Expand test verification catalog from **39 to 70 tests**.<br>• Document verification across all optimization profiles (`-o:none` through `-o:aggressive`) and microarchitecture levels (`x86-64-v1` to `native`).<br>• Detail headless simulation benchmarks and zero-leak tracking allocator reports. |
| **`COOKBOOK.md`** | • Review and expand all 6 production recipes with updated vector tweens and 3-tier clock accessors.<br>• Add recipes for **Lockstep Fixed-Tick Physics** and **Multi-Phase Boss AI with `Phase_Director`**. |

---

# Part 2: Technical Deep-Dives & Architectural Specifications

### Section 2.1: Low-Level Hardware & Inline Assembly Architecture (`TECH_ASM.md`)
* **AMD64 Context Switching Mechanics:**
  * Windows x64 ABI vs. System V AMD64 ABI callee-saved register sets.
  * Preserving GPRs (`rbp`, `rbx`, `rsi`, `rdi`, `r12`..`r15`) and SIMD (`xmm6`..`xmm15` via `movdqu`).
  * Call/ret trampoline mechanism: How `%rsp` swapping resumes execution seamlessly.
  * The `%r12` universal register passing trick for fiber self-discovery.
* **Compiler Safety & SSA Invalidation:**
  * `#volatile` and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`, `flags`, `memory`).
  * Preventing LLVM from caching memory reads across context switch boundaries.
* **Stack Layout & Strict Alignment:**
  * 16-byte stack alignment invariants before `call` instructions.
  * Synthetic stack frame structure and initial bootstrap initialization.

---

### Section 2.2: The 3-Tier Multi-Domain Engine Clock (`TECH_CLOCK.md`)
* **The Physics & Mathematics of Game Clocks:**
  * Why `f32` precision degrades after 3–9 hours (floating-point epsilon loss).
  * Why `f64` (53-bit significand) + `u64` integer ticks guarantees multi-year zero-drift accuracy.
* **The 3 Clock Domains:**
  1. *Real / Wall Clock (`real_time: f64`, `real_delta: f32`, `real_ticks: u64`):* Unscaled, unpaused clock for UI, menus, network heartbeats, and profilers.
  2. *Scaled Simulation Clock (`sim_time: f64`, `sim_delta: f32`, `time_scale: f32`, `is_paused: bool`):* Gameplay clock for AI, combat, tweens, and animations.
  3. *Discrete Simulation Ticks (`sim_ticks: u64`, `tick_rate_hz: u32`, `frame_count: u64`):* Integer clock for deterministic physics, replays, and rollback netcode.
* **Pluggable Engine Drivers:**
  * `scheduler_step(sched, dt)`: Variable frame delta driver.
  * `scheduler_step_ticks(sched, ticks)`: Integer tick driver.
  * `scheduler_step_dual(sched, real_dt, sim_dt)`: Dual-clock driver.
  * `scheduler_single_step(sched, dt)`: Debugger manual stepping driver.
* **Dual Min-Heap Architecture:**
  * Separate binary min-heaps for simulation timers (`timer_heap`) and real-time timers (`real_timer_heap`).
  * $O(1)$ wake inspection and $O(\log N)$ cached-index removal on abort.

---

### Section 2.3: Memory Architecture & Multi-Tier Safety (`TECH_MEMORY.md`)
* **Slab Allocation Strategy:**
  * Contiguous 1MB memory blocks divided into 32KB fixed-size stacks.
  * $O(1)$ free-list stack acquisition and recycling without runtime OS syscalls.
* **Multi-Tiered Safety Invariants:**
  * *Tier 1 (Software Canary):* 64-byte `0xDEAD_BEEF_CAFE_BABE` watermark at `stack_base`.
  * *Tier 2 (Stack Usage Profiling):* `0xAA` watermark scanning via `fiber_calc_stack_usage`.
  * *Tier 3 (Hardware Protection):* Virtual memory allocation with `PAGE_GUARD` (Windows) / `mprotect(PROT_NONE)` (POSIX) trapping overflows immediately.
* **Per-Fiber Isolated Temporary Memory:**
  * Embedded 4KB `mem.Arena` per fiber bound to `context.temp_allocator`.
  * Guaranteeing temporary allocations survive yields without cross-coroutine corruption.
* **Inline 128-Byte By-Value Payload Storage:**
  * Eliminating `new()` / `free()` heap allocations for transient arguments.
  * Prevention of dangling stack frame pointers for short-lived callers.
  * Compile-time size validation via `#assert(size_of(T) <= FIBER_PAYLOAD_SIZE)`.

---

### Section 2.4: Structured Concurrency & Coordinators (`TECH_CONCURRENCY.md`)
* **The Concurrency Matrix:**
  * `sync`: Parallel fork-join; resumes parent when all branches succeed.
  * `race`: Preemptive race; first branch to finish aborts all siblings.
  * `rush`: Parallel success race; first branch to *succeed* wins, ignoring early failures.
  * `fallback`: Sequential priority execution ($A \rightarrow B \rightarrow C$) stopping at first success.
* **Coordinator Lifecycle & Tree Topology:**
  * Zero-allocation intrusive `Join_Coordinator` embedded in `Fiber`.
  * Parent-child-sibling pointer links.
* **Hierarchical Bottom-Up Unwinding:**
  * Recursive descendant tree pruning on cancel or race preemption.
  * Removal of sleeping fibers from heaps, frame queues, and condition watchlists.
  * Execution of cleanup destructors and native `defer` blocks.

---

### Section 2.5: Decoupled Subsystems & Primitives (`TECH_PRIMITIVES.md`)
* **CSP Typed Channels (`Channel(T)`):**
  * $O(1)$ circular ring buffer (`head`, `tail`, `count`).
  * Unbuffered rendezvous (capacity 0) vs. bounded FIFO queuing.
  * Blocking fiber operations (`chan_send`, `chan_recv`) vs. non-blocking polling (`chan_try_send`, `chan_try_recv`).
* **Stateful Pull Generators (`Generator(T)`):**
  * Pull-based lazy sequence generation.
  * Lightweight 16KB dedicated single-stack scheduler.
* **Async Job Bridge (`await_async` / `Async_Token`):**
  * Lock-free atomic synchronization between background worker threads and main-thread fibers.
* **Cooperative Mutual Exclusion (`Fiber_Mutex` & `Signal`):**
  * Non-blocking fiber suspension queues without OS thread contention.

---

# Part 3: Progressive Tutorial Series (Zero to Hero)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          THE 9-STAGE LEARNING PATH                          │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Getting Started: Hello Coroutines & Basic Yields                         │
│ 2. State & Parameter Passing (Pointers vs. By-Value 128B Buffers)           │
│ 3. Structured Concurrency: Building a Boss Fight with sync and race        │
│ 4. Advanced Decision Trees: AI Behavior with rush, fallback & with_timeout  │
│ 5. Decoupled Communication: Signals, Fiber Mutexes & CSP Channels           │
│ 6. Bridging Background Threads: Heavy Compute via await_async               │
│ 7. Stateful Iterators: Procedural Content with Generator(T)                 │
│ 8. Real-Time vs. Pausable Simulation: Mastering the 3-Tier Clock            │
│ 9. Headless CI/CD Gameplay Testing: Automated Simulation with simulate_until│
└─────────────────────────────────────────────────────────────────────────────┘
```

### Outline for Each Tutorial Chapter:
1. **Tutorial 1: Hello Coroutines & Basic Yields**
   * Initializing `Scheduler`, spawning root fibers, stepping the game loop.
   * Time delays (`wait`), frame delays (`wait_frames`, `yield_frame`), and condition waits (`wait_until`).
   * Using native Odin loops (`for`), conditionals (`if`), and `defer` cleanup.
2. **Tutorial 2: State & Parameter Passing**
   * Pointers (`spawn_ptr`) for persistent living entities (`Boss`, `Player`).
   * By-value copies (`spawn_val`) for transient scalars, coordinates, and configs.
   * Avoiding dangling stack pointers in fire-and-forget procedures.
3. **Tutorial 3: Structured Concurrency (`sync` & `race`)**
   * Multi-branch parallel coordination.
   * Building multi-laser attacks (`sync`) and attack-vs-health-threshold phases (`race`).
   * Automatic cancellation of loser subtrees.
4. **Tutorial 4: AI Decision Trees (`rush`, `fallback`, `with_timeout`)**
   * Priority behavior trees with `fallback` and explicit `fail(f)`.
   * Multi-objective quest completion with `rush`.
   * Auto-cancelling time-limited tasks with `with_timeout`.
5. **Tutorial 5: Synchronization & Communication**
   * Waking sentries with `Signal` broadcasts.
   * Sharing single-occupancy charge pads with `Fiber_Mutex`.
   * Decoupling dialogue UI and quest scripts via `Channel(T)`.
6. **Tutorial 6: Offloading Heavy Compute (`await_async`)**
   * Dispatching A* pathfinding to `core:thread` worker pools.
   * Suspending main-thread fibers with zero frame drops at 144 FPS.
7. **Tutorial 7: Procedural Generators (`Generator(T)`)**
   * Building stateful loot drop forges and lazy sequence streams.
   * Consuming values with `generator_next` and yielding with `yield_value`.
8. **Tutorial 8: The 3-Tier Clock in Practice**
   * Pausing the game world (`is_paused = true`) while animating pause menus with `wait_real`.
   * Driving deterministic physics and replays with `wait_ticks`.
   * Implementing bullet-time slow motion via `time_scale`.
9. **Tutorial 9: Headless CI/CD Simulation (`simulate_until`)**
   * Writing automated gameplay integration tests without window creation.
   * Simulating 60 seconds of complex AI combat in 5 milliseconds.

---

# Part 4: Game Engine Integration & Architecture Guides

### Guide 4.1: Game Engine Integration Blueprint (`GUIDE_INTEGRATION.md`)
* Integrating the scheduler into standard game loops:
  * **Raylib:** Binding to `rl.GetFrameTime()`.
  * **Sokol / GLFW / SDL:** Standard delta step integration.
  * **Custom Engines:** Fixed-step vs. variable-step architectures.
* Managing tracking allocators and memory cleanups on game shutdown.

### Guide 4.2: Multi-Scheduler Engine Architectures (`GUIDE_SCHEDULERS.md`)
* The Dual-Scheduler Pattern:
  * `world_sched`: Ticked with simulation delta; frozen during pause menus.
  * `ui_sched`: Ticked with real delta; drives menus, loading screens, and HUDs.
* Managing independent fiber pools across game scenes and levels.

### Guide 4.3: Determinism, Rollback Netcode & Replays (`GUIDE_DETERMINISM.md`)
* Using integer ticks (`scheduler_step_ticks` + `wait_ticks`) for lockstep simulation.
* Eliminating floating-point drift across different CPU architectures.
* Checkpointing high-level game state for save/load systems.

### Guide 4.4: Migration Guide (`GUIDE_MIGRATION.md`)
* **From Unity C# Coroutines (`IEnumerator`):** Replacing heap-allocated `yield return new WaitForSeconds()` with zero-allocation `coroutine.wait(f, 1.0)`.
* **From Unreal Latent Actions / Tasks:** Replacing complex C++ task nodes with imperative Odin procedures.
* **From Stackless AST Coroutines:** Eliminating manual `Rc(T)` payload wrappers and node compositions.

---

# Part 5: Visual Debugging & Telemetry Manual (`GUIDE_DEBUGGER.md`)

* **In-Game Debugger Controls & Overlay (F1 / TAB):**
  * Interpreting the live coroutine hierarchy tree (Root $\rightarrow$ Composite $\rightarrow$ Leaf).
  * Reading fiber statuses (`Running`, `Ready`, `Sleeping_Sim`, `Sleeping_Real`, `Sleeping_Ticks`, `Suspended_Join`).
  * Live stack high-water telemetry (`[Used: 2.1KB / 32KB] (6.5%)`).
* **Interactive Freeze-Step & Slow-Motion Engine:**
  * `[F3]`: Freezing gameplay simulation while keeping real-time UI active.
  * `[F4]`: Single-frame step ($+0.016\text{s}$).
  * `[F5]` / `[Shift+F4]`: 10-frame jump ($+0.160\text{s}$).
  * **Hold `[F4]`**: Continuous slow-motion stepping at 15 FPS.
  * Latched input execution: Registering player actions while paused for next-frame execution.

---

## Deliverable Document Index

```
coroutines_asm/
├── README.md                  # Master Overview, Highlights & Quickstart
├── ARCHITECTURE.md            # Complete Engine Architectural Specification
├── ASM.md                     # Odin Inline Assembly Reference & Grammar
├── CHANGELOG.md               # Version History & Release Notes
├── REPORTS.md                 # Verification Matrix & 70-Test Compliance Report
├── COOKBOOK.md                # 6 Production Gameplay Architecture Recipes
│
├── docs/
│   ├── tech/
│   │   ├── TECH_ASM.md         # Low-Level ASM Switch, Registers & ABI Spec
│   │   ├── TECH_CLOCK.md       # 3-Tier Clock Math, Precision & Drivers
│   │   ├── TECH_MEMORY.md      # Slabs, Canaries, Guard Pages & Temp Arenas
│   │   ├── TECH_CONCURRENCY.md # Structured Concurrency & Coordinator Lifecycle
│   │   └── TECH_PRIMITIVES.md  # Channels, Generators, Async Bridge & Mutexes
│   │
│   ├── tutorials/
│   │   ├── 01_hello_coroutines.md
│   │   ├── 02_parameter_passing.md
│   │   ├── 03_structured_concurrency.md
│   │   ├── 04_advanced_control_flow.md
│   │   ├── 05_synchronization.md
│   │   ├── 06_async_background_jobs.md
│   │   ├── 07_stateful_generators.md
│   │   ├── 08_multi_domain_clocks.md
│   │   └── 09_headless_ci_testing.md
│   │
│   └── guides/
│       ├── GUIDE_INTEGRATION.md # Engine Integration (Raylib, Sokol, Custom)
│       ├── GUIDE_SCHEDULERS.md   # Multi-Scheduler Architecture (World vs. UI)
│       ├── GUIDE_DETERMINISM.md  # Determinism, Physics & Rollback Netcode
│       ├── GUIDE_MIGRATION.md    # Migration from Unity / Unreal / AST
│       └── GUIDE_DEBUGGER.md     # In-Engine Tree Inspector & Freeze-Step
```

---

## Execution Readiness

This design provides complete coverage of the engine's theoretical foundations, implementation details, gameplay workflows, and developer tooling. 

Let me know if you would like to adjust any section before we begin drafting the documentation suite!
