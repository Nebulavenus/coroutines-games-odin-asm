Here is an architectural brainstorm and technical roadmap for adding WebAssembly (`wasm32` / `wasm64`) support to the coroutine library so it can run in modern web browsers.

---

# 1. The Core Challenge: Wasm's Split-Stack Architecture

On native architectures (`amd64`, `arm64`, `riscv64`), you can swap the stack pointer (`%rsp`/`%sp`) and execute `ret`/`jalr` because the call stack lives in linear addressable memory.

**WebAssembly is fundamentally different:**
1. **The Execution/Call Stack is invisible**: It is managed directly by the browser's engine (V8, SpiderMonkey). It does not live in linear memory and **cannot be addressed, read, or modified by pointer manipulation**.
2. **Linear Memory only holds data**: Only spilled locals, allocations, and the "shadow stack" reside in linear memory.
3. **No native stack swapping in Wasm MVP**: You cannot write `mov sp, to_sp` or `#byte` opcodes to jump between different execution stacks in standard WebAssembly.

To run stackful coroutines in the browser, we must choose one of **three technical paths**.

---

# 2. The 3 Technical Approaches

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          WASM COROUTINE STRATEGIES                          │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ Approach A: Binaryen `Asyncify`      │ Toolchain post-processing. Unwinds   │
│ (Recommended & Production-Ready)     │ & rewinds Wasm call stacks into data │
│                                      │ buffers in linear memory.            │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ Approach B: W3C Wasm Stack Switching │ Future standard (WasmFX/Typed        │
│ (Bleeding-Edge / Future-Proof)       │ Continuations). Native VM fibers via │
│                                      │ `cont.new` / `suspend` / `resume`.   │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ Approach C: JSPI (JS Promise Integr.)│ Browser V8 feature bridging Wasm to  │
│ (Web-Native / Async)                 │ JavaScript Promises/microtasks.      │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## Approach A: Binaryen `Asyncify` (Recommended Path)

This is the industry standard used by Emscripten (`emscripten_fiber_*`), Rust (`wasm-bindgen-futures`), and Go's WebAssembly port.

### How It Works:
1. Compile Odin to `.wasm` using `-target:js_wasm32` or `-target:freestanding_wasm32`.
2. Post-process the output `.wasm` with `wasm-opt --asyncify`.
3. When a fiber yields:
   * It calls an imported/intrinsic function `asyncify_start_unwind(&fiber.asyncify_buf)`.
   * Wasm unwinds all active call frames, saving local variables and the execution pointer into `fiber.asyncify_buf` (which lives in standard linear memory).
   * Control returns cleanly to the top-level `scheduler_step`.
4. When the scheduler resumes that fiber:
   * It calls `asyncify_start_rewind(&target_fiber.asyncify_buf)`.
   * Wasm replays the call stack down to the exact yield point, restores all locals from linear memory, calls `asyncify_stop_rewind()`, and resumes execution.

### Advantages:
* **100% Browser Compatibility Today**: Runs in Chrome, Firefox, Safari, Edge, and mobile browsers out of the box without experimental flags.
* **Retains the Exact Same Odin Code**: Gameplay code remains straight-line: `wait()`, `sync()`, `race()`, `chan_recv()` work without changing a single line of game logic.

### Trade-offs:
* Requires `wasm-opt` (from the Binaryen toolkit) in the build pipeline (`build.ps1 wasm`).
* Slight binary size increase (~5–10%) and small function call overhead.

---

## Approach B: W3C WebAssembly Stack Switching (WasmFX)

The WebAssembly working group has an active proposal: [W3C Wasm Stack Switching (Typed Continuations)](https://github.com/WebAssembly/stack-switching).

### How It Works:
* Adds first-class stack-switching bytecode instructions directly into the Wasm virtual machine:
  * `cont.new`: Allocates a new stackful continuation.
  * `suspend`: Suspends the active continuation.
  * `resume`: Resumes a suspended continuation.
* Zero binaryen rewrites, zero unwinding/rewinding overhead. True native hardware-grade fiber performance inside the browser VM.

### Current Status:
* Implemented experimentally in V8/Chrome behind flags (`--experimental-wasm-stack-switching`).
* **Verdict**: The ultimate long-term destination, but not ready for production release in all browsers today.

---

## Approach C: WebAssembly JSPI (JavaScript Promise Integration)

A standardized API in modern V8/Chrome (Chrome 129+) allowing WebAssembly functions to suspend synchronously while waiting on JavaScript Promises.

### Trade-offs:
* Ties fiber yields to the JavaScript event loop and microtask queue.
* Sacrifices tight, deterministic, 60 FPS lockstep ticking because resumption is deferred to browser microtask scheduling.

---

# 3. Required Codebase Adaptations

To make this library compile and run on `js_wasm32`, here is what needs to change:

### 1. New Abstraction: `asm_wasm32.odin`
Add architecture guards for Wasm:

```odin
// asm_wasm32.odin
package coroutine

when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64 {

    // Asyncify structure allocated per fiber
    Asyncify_State :: struct {
        data_ptr: rawptr,
        data_end: rawptr,
    }

    // Replace the assembly switch with the Asyncify bridge
    fiber_context_switch :: proc(from_sp: ^rawptr, to_sp: rawptr) {
        // 1. Unwind current fiber to its linear memory buffer
        // 2. Rewind target fiber from its buffer
    }

    get_sp :: proc "contextless" () -> rawptr {
        // Read the Wasm shadow stack pointer global (__stack_pointer)
        return nil
    }
}
```

### 2. Slabs & Memory Pool (`pool.odin`)
* **Eliminate OS Virtual Memory on Wasm**:
  Windows `VirtualAlloc` and POSIX `mmap` do not exist in the browser.
  `alloc_mode` must be forced to `.Standard_Slab` when targeting `js_wasm32`:
  ```odin
  when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64 {
      DEFAULT_ALLOC_MODE :: Stack_Allocation_Mode.Standard_Slab
  }
  ```
* Stacks are simply slices allocated from Odin's linear memory allocator (`context.allocator`).
* Canaries (`0xDEAD_BEEF_CAFE_BABE`) work identically in linear memory.

### 3. Pointer & Handle Sizes (`types.odin`)
* In `wasm32`, pointers are **32-bit** (`size_of(rawptr) == 4`).
* `Fiber_Handle` is already a 32-bit packed integer (`u16 index | u16 gen`), which is **100% compatible** with `wasm32`.
* `FIBER_PAYLOAD_SIZE` (128 bytes) and 4KB temp arenas require no changes.

### 4. Browser Timing Loop
On desktop, games run a blocking `for !rl.WindowShouldClose()` loop. In browsers, the browser tab owns the event loop.
* Replace the blocking loop with `emscripten_set_main_loop` or Raylib's `rl.SetWindowShouldClose()` / `requestAnimationFrame`:
  ```odin
  frame_tick :: proc "c" () {
      context = runtime.default_context()
      dt := cast(f32)rl.GetFrameTime()
      coroutine.scheduler_step(&g_sched, dt)
      // render...
  }
  ```

---

# 4. Proposed Execution Roadmap

1. **Phase 1: Architecture Split & Build Cleanliness**
   * Create `asm_wasm32.odin` with empty/stub context switches.
   * Ensure `odin check . -target:js_wasm32` compiles with 0 errors (resolving `posix`/`windows` imports in `pool.odin`).
2. **Phase 2: Asyncify Bridge Implementation**
   * Implement the minimal Asyncify control contract (`asyncify_buf` per fiber).
   * Add a `wasm-opt --asyncify` step to `build.ps1`.
3. **Phase 3: Browser Smoke Test (`examples/dist_test` or Raylib Web)**
   * Run the test suite headlessly via Node.js (`node test_runner.wasm`).
   * Compile the Raylib Boss Fight or Showcase demo to WebAssembly and host it on an `index.html` page.

---

### Questions to Consider:
1. Would you prefer using Odin's native `-target:js_wasm32` with a minimal `odin.js` runtime, or targeting Emscripten (which ships `wasm-opt` and Raylib HTML5 build helpers out of the box)?
2. Should we start by making `odin check . -target:js_wasm32` pass statically across the library?

---

Here is the architectural design and implementation plan for adding native WebAssembly (`-target:js_wasm32`) support using Binaryen’s **`wasm-opt --asyncify`**, without Emscripten, with a minimal `odin.js` bridge, and a zero-dependency HTML5 2D canvas showcase runtime.

---

# 1. Architectural Blueprint & Invariants

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                      PURE WASM COROUTINE ARCHITECTURE                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Core Library (100% Pure Odin, Engine-Agnostic)                           │
│    • Compiled via: odin build . -target:js_wasm32                           │
│    • Post-processed via: wasm-opt --asyncify                                │
│    • Zero dependencies on Emscripten, libc, or POSIX                        │
├─────────────────────────────────────────────────────────────────────────────┤
│ 2. Asyncify State Engine (asm_wasm32.odin)                                  │
│    • Each Fiber owns an embedded Asyncify linear memory buffer              │
│    • Yielding initiates call-stack unwinding to the scheduler               │
│    • Resuming initiates call-stack rewinding directly to the yield point     │
├─────────────────────────────────────────────────────────────────────────────┤
│ 3. Minimal Host Bridge (odin.js & index.html)                               │
│    • Minimal JS loader (~60 lines): instantiates Wasm, hooks rAF loop       │
│    • Implements standard Asyncify state imports                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ 4. Zero-C Web Showcase Runtime                                              │
│    • Lightweight 2D canvas API in Odin matching Raylib conventions          │
│    • Directly exports draw calls to HTML5 <canvas>                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

# 2. How Asyncify Context Switching Works in Pure Odin

Because WebAssembly’s execution call stack is invisible and cannot be swapped by writing to `%rsp`, **Asyncify transforms the Wasm bytecode** into an unwinding/rewinding state machine.

### The Asymmetric Fiber Loop on Wasm:
In our native codebase, every fiber already yields back to `f.sched.scheduler_sp`. On Wasm, this maps naturally to Asyncify:

```
[ Scheduler Step ] ──► Resumes Fiber ──► [ Calls fiber entry / resume ]
        ▲                                          │
        │                                  (Replays stack to yield point)
        │                                          │
        │                                  [ Fiber resumes execution ]
        │                                          │
        │                                  [ Fiber calls wait() / yield() ]
        │                                          │
        │                                  (Initiates asyncify unwind)
        │                                          ▼
(Unwinds Wasm stack to Scheduler) ◄── [ Fiber returns out cleanly ]
```

### 1. Data Structure (`asm_wasm32.odin`)
Binaryen expects a pointer to a struct containing two 32-bit pointers (`top` and `end`), followed by a data storage area in linear memory where Asyncify spills locals and return addresses:

```odin
package coroutine

when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64 {

    ASYNCIFY_STORAGE_SIZE :: 4096 // 4KB per fiber is plenty for call-stack frames

    Asyncify_Buffer :: struct {
        top:     u32,
        end:     u32,
        storage: [ASYNCIFY_STORAGE_SIZE]byte,
    }

    // Binaryen Asyncify Standard Foreign Imports
    foreign import asyncify "asyncify" {
        @(link_name = "start_unwind")
        asyncify_start_unwind :: proc(buf: rawptr) ---
        @(link_name = "stop_unwind")
        asyncify_stop_unwind  :: proc() ---
        @(link_name = "start_rewind")
        asyncify_start_rewind :: proc(buf: rawptr) ---
        @(link_name = "stop_rewind")
        asyncify_stop_rewind  :: proc() ---
        @(link_name = "get_state")
        asyncify_get_state    :: proc() -> i32 --- // 0: none, 1: unwinding, 2: rewinding
    }
}
```

### 2. The Context Switch Bridge
```odin
fiber_context_switch :: proc(from_sp: ^rawptr, to_sp: rawptr) {
    when ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64 {
        // 1. If currently executing inside a fiber and yielding to scheduler:
        if asyncify_get_state() == 0 {
            // Signal Asyncify to unwind the Wasm execution stack into this fiber's buffer
            cur := g_active_fiber
            asyncify_start_unwind(&cur.asyncify_buf)
            return // Triggers cascade return up the call stack to scheduler_advance
        }
    }
}
```

---

# 3. Core Engine Adaptations for `-target:js_wasm32`

### A. Memory Allocation Isolation (`pool.odin`)
* On Windows, we use `VirtualAlloc`. On POSIX, we use `posix.mmap`.
* On Wasm, **virtual memory protection does not exist**.
* Isolate OS-specific imports:
  ```odin
  when ODIN_OS == .Windows {
      import win32 "core:sys/windows"
  } else when ODIN_OS != .JS && (ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD) {
      import "core:sys/posix"
  }
  ```
* When targeting `js_wasm32`, `alloc_mode` automatically defaults to `.Standard_Slab` (backed by Odin's native linear memory heap allocator `context.allocator`).
* Software Canaries (`0xDEAD_BEEF_CAFE_BABE`), watermarking (`0xAA`), and 4KB isolated temp arenas work out of the box in linear memory.

### B. Pointer & Handle Invariants
* `Fiber_Handle` is already a 32-bit packed integer (`u16 index | u16 gen`), requiring zero changes.
* `uint` and `rawptr` naturally scale down to 4 bytes on `wasm32`.

---

# 4. Minimal Web Runtime (`odin.js` + `index.html`)

No Emscripten runtime. A minimal, standalone `odin.js` (~80 lines):

1. **Asyncify Import Object**:
   ```javascript
   let asyncifyState = 0; // 0: None, 1: Unwinding, 2: Rewinding
   let asyncifyBuf = 0;

   const asyncifyImports = {
       start_unwind: (buf) => { asyncifyState = 1; asyncifyBuf = buf; },
       stop_unwind:  () =>    { asyncifyState = 0; },
       start_rewind: (buf) => { asyncifyState = 2; asyncifyBuf = buf; },
       stop_rewind:  () =>    { asyncifyState = 0; },
       get_state:    () => asyncifyState,
   };
   ```
2. **Game Loop (`requestAnimationFrame`)**:
   Calls the exported Odin function `web_update(dt)` every browser refresh frame.

---

# 5. Lightweight Showcase Runtime (Zero-C 2D Canvas)

To demonstrate the coroutine engine visually in the browser without importing Raylib or C libraries, we create a tiny, engine-agnostic canvas module (`examples/web_showcase/canvas.odin`):

* Thin foreign procedures calling into the 2D Canvas context in JS:
  * `canvas_clear(r, g, b, a)`
  * `canvas_draw_circle(x, y, radius, r, g, b, a)`
  * `canvas_draw_rect(x, y, w, h, r, g, b, a)`
  * `canvas_draw_text(str, x, y, size, r, g, b, a)`
* Allows running the **Feature Showcase** (Ritual sync, Capture race, Drone mutex, Beacon signals) directly inside any browser tab at 60 FPS with zero C toolchain requirements.

---

# 6. Phased Implementation Plan

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            PHASED EXECUTION PLAN                            │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 1: Wasm32 Static Compilation Parity                                   │
│  - Guard OS-specific imports in pool.odin (win32, posix).                   │
│  - Add asm_wasm32.odin with stubs and Asyncify declarations.                │
│  - Achieve 100% clean check: odin check . -target:js_wasm32.                │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 2: Binaryen Asyncify Scheduler Integration                            │
│  - Wire Asyncify buffer into Fiber struct when on wasm32.                   │
│  - Implement unwinding yield and rewinding dispatch in scheduler.           │
│  - Validate asyncify state transitions.                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 3: Build Script Automation & Wasm-Opt Pipeline                        │
│  - Add ./build.ps1 wasm and ./build.ps1 test-wasm.                          │
│  - Pipeline: odin build -> wasm-opt --asyncify -> output dist/coro.wasm.    │
│  - Run headless test suite in Node.js or browser.                           │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 4: Zero-C Browser Showcase Demo                                       │
│  - Create minimal web/ runtime (index.html, odin.js).                       │
│  - Implement lightweight 2D canvas drawing layer in examples/web_showcase.  │
│  - Demonstrate interactive coroutine stations running in the browser.       │
├─────────────────────────────────────────────────────────────────────────────┤
│ Phase 5: Distribution & Multi-Target Matrix Verification                   │
│  - Update tools/amalgamate.py to include asm_wasm32.odin.                   │
│  - Update CI & ./build.ps1 check-all to verify all 7 target platforms.      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Ready to proceed?
If this plan aligns with your vision, we can begin with **Phase 1: Multi-Platform Architecture & Wasm32 Compilation Parity**, ensuring the entire library passes `odin check . -target:js_wasm32` cleanly.
