# Stackful Coroutines with Structured Concurrency in Odin

A high-performance, deterministic **stackful coroutine engine** in [Odin](https://odin-lang.org/) powered by native AMD64 inline assembly (`asm`), featuring **SkookumScript-inspired structured concurrency** (`sync`, `race`, `branch`), hierarchical scope cancellations, per-fiber isolated temporary allocators (`context.temp_allocator`), event broadcast signals (`Signal`), cooperative fiber mutexes (`Fiber_Mutex`), timeout wrappers (`with_timeout`), stack watermarking telemetry, and an interactive 2D Boss Encounter demo with a live F1 visual tree debugger built with `vendor:raylib`.

---

## Highlights

- **Native AMD64 Inline Assembly Context Switching**: Fast register swap using call/ret trampoline patterns with full register preservation (Windows x64 GPRs + `xmm6`..`xmm15`; System V AMD64 GPRs), `#volatile` and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`), and strict 16-byte stack alignment.
- **SkookumScript Structured Concurrency & Higher-Level Primitives**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `with_timeout`: Auto-cancelling task execution within time limits.
  - `Signal`: Zero-polling event broadcasting (`signal_wait`, `signal_emit`).
  - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion queue (`fiber_mutex_lock`, `fiber_mutex_unlock`, `fiber_mutex_try_lock`).
  - `branch` / `branch_nil`: Type-safe closures for branch definitions.
- **Isolated Per-Fiber Temporary Allocator**:
  - Embedded 4KB `mem.Arena` in each `Fiber` assigned to `context.temp_allocator`, guaranteeing allocations survive across yield points without cross-coroutine contamination.
- **Deterministic 5-Stage Scheduler**:
  - $O(1)$ Ready FIFO Queue.
  - $O(\log N)$ Binary Timer Min-Heap (`wait`) with cached index for instant removal on cancel.
  - Frame Wait Queue (`wait_frames`, `yield_frame`).
  - Condition Watchlist (`wait_until`, `wait_cond`).
- **Memory & Stack Diagnostics**:
  - Slab-allocated fiber pool with automatic growth and instant stack recycling.
  - 64-byte stack canary watermark (`0xDEAD_BEEF_CAFE_BABE`) with overflow detection.
  - `0xAA` stack watermarking and high-water usage profiling (`fiber_calc_stack_usage`).
- **Hierarchical Cancellations**:
  - `scope_cancel` / `scope_destroy`: Cleanly cancels and unwinds all coroutines attached to an entity scope.
  - `fiber_cancel`: Cancels an individual fiber and all its descendant children bottom-up.
- **Built-in Value Interpolation (`tween`)**:
  - Smooth property animation over time with linear, quadratic, and cubic easing curves.
- **Zero Runtime Dependencies**: Engine core is 100% pure Odin and inline assembly.

---

## Interactive 2D Boss Encounter Demo

The repository includes a complete 2D Boss Fight demo rendered in `vendor:raylib` visualizing coroutine execution:
- **Boss AI Timeline**: Multi-phase behavior running combat `race` triggers, laser charges, and radial bullet barrages.
- **Player Dash Ability**: Invulnerability frames and motion tweens running as concurrent fibers.
- **Live F1 / TAB Hierarchy Tree Debugger**: Real-time visual overlay displaying the active fiber tree hierarchy, remaining sleep timers, and per-fiber stack usage percentages `[Used: 2.1 KB / 32 KB] (6.5%)`.
- **Dynamic Camera Shake & Damage Floaters**: Visual coroutines self-animating and freeing themselves on completion.
- **Live Diagnostics HUD**: Real-time visualization of active fibers, ready queue sizes, frame waiters, and boss HP.

---

## Quickstart & Examples

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

### 3. Signals & Fiber Mutex

```odin
sig: coroutine.Signal
coroutine.signal_init(&sig)

mutex: coroutine.Fiber_Mutex
coroutine.mutex_init(&mutex)

// Wait for event broadcast
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, s: ^coroutine.Signal) {
    coroutine.signal_wait(f, s)
    fmt.println("Signal received!")
}, &sig)

// Mutual exclusion across fibers
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, m: ^coroutine.Fiber_Mutex) {
    coroutine.fiber_mutex_lock(f, m)
    // Critical Section...
    coroutine.wait_frames(f, 2)
    coroutine.fiber_mutex_unlock(f.sched, m)
}, &mutex)
```

---

## Project Structure

```
coroutines_asm/
├── src/
│   ├── coroutine/              # Core Stackful Coroutine Engine
│   │   ├── asm_amd64.odin      # AMD64 inline assembly context switcher
│   │   ├── types.odin          # Fiber, Scheduler, Signal, Mutex, and Coordinator definitions
│   │   ├── pool.odin           # Slab allocator, canary watermark & temp arena
│   │   ├── scheduler.odin      # 5-stage scheduler & timer min-heap
│   │   ├── api.odin            # spawn, wait, sync, race, with_timeout, signals, mutex, tween
│   │   └── coroutine_test.odin # 33 unit tests & stress validations
│   └── main.odin               # Raylib 2D Boss Encounter game + F1 Tree Debugger
├── build.ps1                   # Build, test, matrix, and debug script
├── ARCHITECTURE.md             # Detailed engine architectural specification
├── PLAN.md                     # Advanced gameplay concurrency roadmap
├── REPORTS.md                  # Comprehensive verification & LLVM matrix report
├── CHANGELOG.md                # Project version history
└── README.md                   # Project overview & documentation
```

---

## Building & Running

A PowerShell build script [`build.ps1`](file:///E:/OdinLang/Projects/coroutines_asm/build.ps1) is provided for all workflows:

### Run the 2D Boss Fight Demo
```powershell
.\build.ps1 run
```
*Press `F1` or `TAB` in-game to toggle the Live Coroutine Hierarchy Visualizer.*

### Build Production Release Binary
```powershell
.\build.ps1 release
```
*Outputs `build/game_release.exe` with `-o:speed -microarch:native -no-bounds-check -disable-assert`.*

### Run All 33 Unit Tests
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

The engine is validated against a 10-configuration build matrix across all optimization levels and microarchitecture baselines:

| # | Configuration Name | Optimization & Architecture Flags | Tests | Status |
| :-: | :--- | :--- | :-: | :-: |
| **1** | **Debug** | `-o:none -debug` | 33 / 33 | **PASS** |
| **2** | **Minimal (Default)** | `-o:minimal` | 33 / 33 | **PASS** |
| **3** | **Size** | `-o:size -use-single-module` | 33 / 33 | **PASS** |
| **4** | **Speed** | `-o:speed -use-single-module` | 33 / 33 | **PASS** |
| **5** | **Aggressive LLVM** | `-o:aggressive -use-single-module -no-bounds-check -disable-assert` | 33 / 33 | **PASS** |
| **6** | **Arch x86-64 (v1 Legacy)** | `-o:speed -microarch:x86-64 -use-single-module` | 33 / 33 | **PASS** |
| **7** | **Arch x86-64-v2 (Baseline)**| `-o:speed -microarch:x86-64-v2 -use-single-module` | 33 / 33 | **PASS** |
| **8** | **Arch x86-64-v3 (AVX2/FMA)**| `-o:speed -microarch:x86-64-v3 -use-single-module` | 33 / 33 | **PASS** |
| **9** | **Arch Native (Host Max)** | `-o:speed -microarch:native -use-single-module` | 33 / 33 | **PASS** |
| **10** | **Release Game Binary** | `-o:speed -microarch:native -no-bounds-check -disable-assert` | Binary | **PASS** |

See [`REPORTS.md`](file:///E:/OdinLang/Projects/coroutines_asm/REPORTS.md) for full benchmark and test breakdown.

---

## License

MIT License.
