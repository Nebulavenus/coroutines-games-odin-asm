# Stackful Coroutines with Structured Concurrency in Odin

A high-performance, deterministic **stackful coroutine engine** in [Odin](https://odin-lang.org/) powered by native AMD64 inline assembly (`asm`), featuring **SkookumScript-inspired structured concurrency** (`sync`, `race`, `branch`), hierarchical scope cancellations, an $O(\log N)$ timer min-heap, stack overflow canary guards, and an interactive 2D Boss Encounter demo built with `vendor:raylib`.

---

## Highlights

- **Native AMD64 Inline Assembly Context Switching**: Fast register swap using call/ret trampoline patterns with full register preservation (Windows x64 GPRs + `xmm6`..`xmm15`; System V AMD64 GPRs) and strict 16-byte stack alignment.
- **SkookumScript Structured Concurrency**:
  - `sync`: Spawns parallel branches and suspends the parent fiber until all branches complete.
  - `race`: Preemptive first-to-finish race that immediately and recursively aborts competing sibling subtrees.
  - `branch` / `branch_nil`: Type-safe closures for branch definitions.
- **Deterministic 5-Stage Scheduler**:
  - $O(1)$ Ready FIFO Queue.
  - $O(\log N)$ Binary Timer Min-Heap (`wait`) with cached index for instant removal on cancel.
  - Frame Wait Queue (`wait_frames`, `yield_frame`).
  - Condition Watchlist (`wait_until`, `wait_cond`).
- **Memory & Stack Safety**:
  - Slab-allocated fiber pool with automatic growth and instant stack recycling.
  - 64-byte stack canary watermark (`0xDEAD_BEEF_CAFE_BABE`) with overflow detection.
  - `#volatile` and caller-saved register clobber safety preventing LLVM SSA optimization hazards.
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
- **Dynamic Camera Shake & Damage Floaters**: Visual coroutines self-animating and freeing themselves on completion.
- **Live Diagnostics HUD**: Real-time visualization of active fibers, ready queue sizes, frame waiters, and boss HP.

---

## Quickstart & Examples

### 1. Minimal Coroutine

```odin
package main

import "core:fmt"
import "coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.println("Step 1: Fiber started")
        coroutine.yield_frame(f)

        fmt.println("Step 2: Resumed after 1 frame")
        coroutine.wait(f, 0.5)

        fmt.println("Step 3: Resumed after 0.5 seconds")
    })

    // Advance engine loop
    for !sched.ready_queue.len == 0 {
        coroutine.scheduler_step(&sched, 0.016)
    }
}
```

### 2. Structured Concurrency (`sync` & `race`)

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

    // RACE: First branch to finish wins; immediately aborts losing branches
    winner := coroutine.race(f,
        coroutine.branch_nil(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 5.0) // Timeout
        }, "Timeout"),
        coroutine.branch_nil(proc(f: ^coroutine.Fiber) {
            coroutine.wait_until(f, check_player_arrived, nil)
        }, "Player Arrived"),
    )

    fmt.println("Race winner index:", winner)
})
```

### 3. Tweening & Value Interpolation

```odin
pos_x: f32 = 0.0
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, x_ptr: ^f32) {
    // Smoothly animate pos_x from 0 to 500 over 1.5 seconds using quad easing
    coroutine.tween(f, x_ptr, 0.0, 500.0, 1.5, coroutine.ease_in_out_quad)
}, &pos_x)
```

---

## Project Structure

```
coroutines_asm/
├── src/
│   ├── coroutine/              # Core Stackful Coroutine Engine
│   │   ├── asm_amd64.odin      # AMD64 inline assembly context switcher
│   │   ├── types.odin          # Fiber, Scheduler, and Coordinator definitions
│   │   ├── pool.odin           # Slab allocator, canary watermark & trampoline
│   │   ├── scheduler.odin      # 5-stage scheduler & timer min-heap
│   │   ├── api.odin            # spawn, wait, sync, race, branch, tween
│   │   └── coroutine_test.odin # 27 unit tests & stress validations
│   └── main.odin               # Raylib 2D Boss Encounter game
├── build.ps1                   # Build, test, matrix, and debug script
├── ARCHITECTURE.md             # Detailed engine architectural specification
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

### Build Production Release Binary
```powershell
.\build.ps1 release
```
*Outputs `build/game_release.exe` with `-o:speed -microarch:native -no-bounds-check -disable-assert`.*

### Run All 27 Unit Tests
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
| **1** | **Debug** | `-o:none -debug` | 27 / 27 | **PASS** |
| **2** | **Minimal (Default)** | `-o:minimal` | 27 / 27 | **PASS** |
| **3** | **Size** | `-o:size -use-single-module` | 27 / 27 | **PASS** |
| **4** | **Speed** | `-o:speed -use-single-module` | 27 / 27 | **PASS** |
| **5** | **Aggressive LLVM** | `-o:aggressive -use-single-module -no-bounds-check -disable-assert` | 27 / 27 | **PASS** |
| **6** | **Arch x86-64 (v1 Legacy)** | `-o:speed -microarch:x86-64 -use-single-module` | 27 / 27 | **PASS** |
| **7** | **Arch x86-64-v2 (Baseline)**| `-o:speed -microarch:x86-64-v2 -use-single-module` | 27 / 27 | **PASS** |
| **8** | **Arch x86-64-v3 (AVX2/FMA)**| `-o:speed -microarch:x86-64-v3 -use-single-module` | 27 / 27 | **PASS** |
| **9** | **Arch Native (Host Max)** | `-o:speed -microarch:native -use-single-module` | 27 / 27 | **PASS** |
| **10** | **Release Game Binary** | `-o:speed -microarch:native -no-bounds-check -disable-assert` | Binary | **PASS** |

See [`REPORTS.md`](file:///E:/OdinLang/Projects/coroutines_asm/REPORTS.md) for full benchmark and test breakdown.

---

## License

MIT License.
