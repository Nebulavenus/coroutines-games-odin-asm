# Stackful Coroutines with Structured Concurrency in Odin

A high-performance, deterministic **stackful coroutine engine** in [Odin](https://odin-lang.org/) powered by native AMD64 inline assembly (`asm`), featuring **SkookumScript-inspired structured concurrency** (`sync`, `race`, `branch`), hierarchical scope cancellations, per-fiber isolated temporary allocators (`context.temp_allocator`), unopinionated async job bridges (`Async_Token` / `await_async`), pure CSP typed channels (`Channel(T)`), stateful pull generators (`Generator(T)`), multi-tiered stack safety (`Stack_Allocation_Mode` with OS `PAGE_GUARD`), event broadcast signals (`Signal`), cooperative fiber mutexes (`Fiber_Mutex`), timeout wrappers (`with_timeout`), an interactive 2D Boss Encounter demo, and an interactive **All-Features Showcase Game** with a live F1 visual tree debugger built with `vendor:raylib`.

---

## Highlights

- **Native AMD64 Inline Assembly Context Switching**: Fast register swap using call/ret trampoline patterns with full register preservation (Windows x64 GPRs + `xmm6`..`xmm15`; System V AMD64 GPRs), `#volatile` and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`), and strict 16-byte stack alignment.
- **SkookumScript Structured Concurrency & Advanced Primitives**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `with_timeout`: Auto-cancelling task execution within time limits.
  - `Signal`: Zero-polling event broadcasting (`signal_wait`, `signal_emit`).
  - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion queue (`fiber_mutex_lock`, `fiber_mutex_unlock`, `fiber_mutex_try_lock`).
  - `branch` / `branch_nil`: Type-safe closures for branch definitions.
- **Unopinionated Async Job Bridge (`await_async` / `Async_Token`)**:
  - Lock-free, zero-allocation contract allowing main-thread fibers to suspend until *any* background thread pool marks work complete.
- **Pure CSP Typed Channels (`Channel(T)`)**:
  - Synchronous unbuffered rendezvous (capacity 0) and bounded FIFO buffered queues (`chan_send`, `chan_recv`, `chan_try_send`, `chan_try_recv`, `chan_close`).
- **Stateful Pull Generators (`Generator(T)`)**:
  - Zero-allocation pull-based lazy sequence generators for procedural generation, loot rolling, and graph iteration (`yield_value`, `generator_next`).
- **Isolated Per-Fiber Temporary Allocator**:
  - Embedded 4KB `mem.Arena` in each `Fiber` assigned to `context.temp_allocator`, guaranteeing allocations survive across yield points without cross-coroutine contamination.
- **Deterministic 5-Stage Scheduler**:
  - $O(1)$ Ready FIFO Queue.
  - $O(\log N)$ Binary Timer Min-Heap (`wait`) with cached index for instant removal on cancel.
  - Frame Wait Queue (`wait_frames`, `yield_frame`).
  - Condition Watchlist (`wait_until`, `wait_cond`).
- **Multi-Tiered Stack Safety**:
  - Configurable `Stack_Allocation_Mode`:
    - `Standard_Slab`: 100% portable heap slabs with 64-byte `0xDEAD_BEEF_CAFE_BABE` canary watermark.
    - `Virtual_Memory_OS`: OS-level virtual memory allocation with hardware `PAGE_GUARD` trapping.
  - `0xAA` stack watermarking and real-time high-water usage profiling (`fiber_calc_stack_usage`).
- **Hierarchical Cancellations**:
  - `scope_cancel` / `scope_destroy`: Cleanly cancels and unwinds all coroutines attached to an entity scope.
  - `fiber_cancel`: Cancels an individual fiber and all its descendant children bottom-up.
- **Built-in Value Interpolation (`tween`)**:
  - Smooth property animation over time with linear, quadratic, and cubic easing curves.
- **Zero Runtime Dependencies**: Engine core is 100% pure Odin and inline assembly.

---

## Interactive Games & Examples

### 1. Feature Showcase Game (`examples/showcase`)
A dedicated interactive sandbox game demonstrating all 12 engine features across 7 gameplay stations:
- **Station 1 (The Ritual Circle):** `sync` parallel join of 3 charging runes.
- **Station 2 (The Capture Contest):** `race` and `with_timeout` countdown contest.
- **Station 3 (The Energy Charger):** `Fiber_Mutex` queuing 4 AI worker drones into a single charging pad.
- **Station 4 (The Alert Beacon):** `Signal` broadcast waking 6 sleeping sentries simultaneously.
- **Station 5 (The Loot Forge):** `Generator(T)` procedural on-demand item rolling.
- **Station 6 (The Async Research Lab):** `Async_Token` & `await_async` bridging OS background worker threads.
- **Station 7 (The Telemetry Feed & Tree Inspector):** CSP `Channel(T)` log stream + `F1` real-time tree and stack watermarking visualizer.

### 2. 2D Boss Encounter Demo (`src/main.odin`)
- **Boss AI Timeline**: Multi-phase behavior running combat `race` triggers, laser charges, and radial bullet barrages.
- **Player Dash Ability**: Invulnerability frames and motion tweens running as concurrent fibers.
- **Live F1 / TAB Hierarchy Tree Debugger**: Real-time visual overlay displaying the active fiber tree hierarchy, remaining sleep timers, and per-fiber stack usage percentages.
- **Dynamic Camera Shake & Damage Floaters**: Visual coroutines self-animating and freeing themselves on completion.

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

### 2. Structured Concurrency (`sync`, `race` & `with_timeout`)

```odin
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
    // SYNC: Run two tasks in parallel; resumes parent only when BOTH finish
    coroutine.sync(f,
        coroutine.branch_nil(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 1.0)
            fmt.println("Task A completed")
        }),
        coroutine.branch_nil(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 2.0)
            fmt.println("Task B completed")
        }),
    )

    // WITH_TIMEOUT: Automatically aborts task if it exceeds 3.0 seconds
    timed_out := coroutine.with_timeout(f, 3.0,
        coroutine.branch_nil(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 1.5)
            fmt.println("Subtask finished within time limit")
        }),
    )
    fmt.println("Timed out:", timed_out)
})
```

### 3. Async Job Bridge (`await_async`)

```odin
// Background worker signals token when compute finishes
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, token: ^coroutine.Async_Token) {
    fmt.println("Dispatching background work...")
    
    // Fiber suspends; main thread remains at 144 FPS
    if coroutine.await_async(f, token) {
        fmt.println("Background work completed successfully!")
    }
}, &token)
```

### 4. CSP Typed Channels (`Channel(T)`)

```odin
ch: coroutine.Channel(string)
coroutine.chan_init(&ch, capacity = 2)
defer coroutine.chan_destroy(&ch)

// Sender fiber
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(string)) {
    coroutine.chan_send(f, ch, "Hello from Fiber A")
}, &ch)

// Receiver fiber
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(string)) {
    msg, ok := coroutine.chan_recv(f, ch)
    if ok do fmt.println("Received:", msg)
}, &ch)
```

### 5. Stateful Pull Generators (`Generator(T)`)

```odin
gen: coroutine.Generator(int)
coroutine.generator_init(&gen, proc(f: ^coroutine.Fiber, g: ^coroutine.Generator(int)) {
    a, b := 0, 1
    for {
        coroutine.yield_value(f, g, a)
        a, b = b, a + b
    }
})
defer coroutine.generator_destroy(&gen)

for _ in 0 ..< 5 {
    val, ok := coroutine.generator_next(&gen)
    fmt.println("Fib:", val) // 0, 1, 1, 2, 3
}
```

---

## Project Structure

```
coroutines_asm/
├── src/
│   ├── coroutine/              # Core Stackful Coroutine Engine
│   │   ├── asm_amd64.odin      # AMD64 inline assembly context switcher
│   │   ├── types.odin          # Fiber, Scheduler, Async_Token, Channel, Generator
│   │   ├── pool.odin           # Slab allocator, canary watermark & VirtualAlloc
│   │   ├── scheduler.odin      # 5-stage scheduler & timer min-heap
│   │   ├── api.odin            # spawn, wait, sync, race, with_timeout, channels, generators
│   │   └── coroutine_test.odin # 39 unit tests & stress validations
│   └── main.odin               # Raylib 2D Boss Encounter game + F1 Tree Debugger
├── examples/
│   └── showcase/
│       └── main.odin           # Interactive All-Features Showcase Game (7 stations)
├── build.ps1                   # Build, test, matrix, and debug script
├── ARCHITECTURE.md             # Detailed engine architectural specification
├── PLAN.md                     # Advanced gameplay concurrency roadmap
├── PLAN2.md                    # Foundational engine-agnostic library pillars
├── REPORTS.md                  # Comprehensive verification & LLVM matrix report
├── CHANGELOG.md                # Project version history
└── README.md                   # Project overview & documentation
```

---

## Building & Running

A PowerShell build script [`build.ps1`](file:///E:/OdinLang/Projects/coroutines_asm/build.ps1) is provided for all workflows:

### Run the Interactive All-Features Showcase Game
```powershell
.\build.ps1 run-showcase
```

### Run the 2D Boss Fight Demo
```powershell
.\build.ps1 run
```

### Build Production Release Binaries
```powershell
.\build.ps1 release
.\build.ps1 showcase
```

### Run All 39 Unit Tests
```powershell
.\build.ps1 test
```

### Run Full LLVM Optimization & Architecture Matrix
```powershell
.\build.ps1 matrix
```

### Debug with RAD Debugger
```powershell
.\build.ps1 debug
```

---

## Optimization & Architecture Validation Matrix

The engine is validated against an 11-configuration build matrix across all optimization levels and microarchitecture baselines:

| # | Configuration Name | Optimization & Architecture Flags | Tests | Status |
| :-: | :--- | :--- | :-: | :-: |
| **1** | **Debug** | `-o:none -debug` | 39 / 39 | **PASS** |
| **2** | **Minimal (Default)** | `-o:minimal` | 39 / 39 | **PASS** |
| **3** | **Size** | `-o:size -use-single-module` | 39 / 39 | **PASS** |
| **4** | **Speed** | `-o:speed -use-single-module` | 39 / 39 | **PASS** |
| **5** | **Aggressive LLVM** | `-o:aggressive -use-single-module -no-bounds-check -disable-assert` | 39 / 39 | **PASS** |
| **6** | **Arch x86-64 (v1 Legacy)** | `-o:speed -microarch:x86-64 -use-single-module` | 39 / 39 | **PASS** |
| **7** | **Arch x86-64-v2 (Baseline)**| `-o:speed -microarch:x86-64-v2 -use-single-module` | 39 / 39 | **PASS** |
| **8** | **Arch x86-64-v3 (AVX2/FMA)**| `-o:speed -microarch:x86-64-v3 -use-single-module` | 39 / 39 | **PASS** |
| **9** | **Arch Native (Host Max)** | `-o:speed -microarch:native -use-single-module` | 39 / 39 | **PASS** |
| **10** | **Release Game Binary** | `-o:speed -microarch:native -no-bounds-check -disable-assert` | Binary | **PASS** |
| **11** | **Showcase Binary** | `-o:speed -microarch:native -no-bounds-check -disable-assert` | Binary | **PASS** |

See [`REPORTS.md`](file:///E:/OdinLang/Projects/coroutines_asm/REPORTS.md) for full benchmark and test breakdown.

---

## License

MIT License.
