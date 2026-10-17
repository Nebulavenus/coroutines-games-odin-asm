# WebAssembly (js_wasm32) Coroutine Engine Architecture

Welcome to the **WebAssembly Documentation Suite** for the Odin coroutine engine. This directory provides an exhaustive technical breakdown of how cooperative fibers, structured concurrency, and game simulation loops run inside web browsers and headless JavaScript runtimes without native OS threads or physical CPU register swapping.

---

## 1. Executive Summary

On native operating systems (Windows, Linux, macOS) across AMD64, ARM64, and RISC-V 64, this engine performs cooperative fiber context switching via custom assembly instructions (`#byte` machine code and high-level inline assembly) in **16 nanoseconds**, allocating an isolated physical stack buffer for each fiber.

Standard WebAssembly 1.0 does not provide physical stack pointers, register access, or first-class delimited continuations. To achieve full cross-platform parity for web browsers and Node.js:
1. **Binaryen Asyncify (`wasm-opt --asyncify`)**: Transforms standard Odin procedure call graphs into resumable state machines capable of unwinding and rewinding the WebAssembly execution stack.
2. **Zero-C HTML5 Canvas 2D Adapter (`tools/web/raylib_canvas.js`)**: Emulates Raylib graphics and input APIs directly in browser JavaScript with zero external C/C++ dependencies or Emscripten SDK overhead.
3. **Fiber-Owned Memory Hardening**: Solves the WebAssembly dual-stack dilemma (shared LLVM shadow stack) by storing timing, payload, and temporary state directly in heap-allocated fiber structures.

---

## 2. Architecture Comparison Matrix

| Feature | Native OS (AMD64, ARM64, RISC-V 64) | WebAssembly (`js_wasm32`) |
| :--- | :--- | :--- |
| **Context Switch Mechanism** | Physical register push/pop & stack pointer swap | Binaryen Asyncify stack unwinding / rewinding |
| **Context Switch Latency** | **~16 ns** | ~100–300 ns (traverses active call frames) |
| **Fiber Stacks** | Private, isolated memory buffer per fiber (32 KB) | Shared VM execution stack + Shared LLVM shadow stack |
| **Memory Isolation** | Full hardware page and stack frame isolation | Shared linear memory (`memory.buffer`) |
| **Local Variables** | Reside on private fiber stack | Wasm VM locals saved/restored; stack structs shared |
| **Structured Concurrency** | Fully supported (`sync`, `race`, `rush`, `branch_scoped`) | Fully supported (`sync`, `race`, `rush`, `branch_scoped`) |
| **CSP Channels** | Symmetrical rendezvous & buffered ring buffers | Symmetrical rendezvous & buffered ring buffers |
| **Multi-Domain Clocks** | Sim Time, Real Time, Fixed Ticks | Sim Time, Real Time, Fixed Ticks |
| **Graphics Runtime** | Native Desktop Raylib (OpenGL / DirectX) | Pure HTML5 2D Canvas Adapter (`tools/web/raylib_canvas.js`) |
| **Build Artifact** | Native PE / ELF / Mach-O executable | Standalone `.wasm` bundle (with Asyncify passes) |

---

## 3. Documentation Index

The documentation track is organized into five deep-dive technical modules:

```
docs/wasm/
├── README.md                      # This document (Navigation Hub & Overview)
├── 01_ARCHITECTURE_ASYNCIFY.md   # Asyncify Integration, Leaf Protocol & Event Loop
├── 02_MEMORY_AND_LIMITATIONS.md   # Dual-Stack Dilemma, Shadow-Stack Aliasing & 3 Golden Rules
├── 03_BROWSER_GAME_AND_CANVAS.md  # Porting Raylib Games, C ABI Struct Unpacking & Controls
├── 04_TESTING_AND_AUTOMATION.md   # 16-Suite Test Harness, Headless Node.js CI & Fuzzing
└── 05_STACK_SWITCHING_ROADMAP.md  # Future Wasm Stack-Switching, Pointer Swapping & WasmFX
```

### Module Summaries:
- **[01. Architecture & Asyncify Integration](01_ARCHITECTURE_ASYNCIFY.md)**:
  Examines how Odin procedures are rewritten by Binaryen Asyncify, why the leaf unwind/rewind protocol (`start_unwind` on yield, `stop_rewind` upon entry in `yield`) is required, and how the browser event loop schedules fibers.
- **[02. Memory Architecture & Limitations](02_MEMORY_AND_LIMITATIONS.md)**:
  Analyzes the fundamental difference between the WebAssembly VM execution stack and the LLVM shadow stack in linear memory. Explains shadow-stack aliasing across yields, details the Boss EMP post-mortem, and codifies the **3 Golden Rules**.
- **[03. Browser Game & Canvas Adapter](03_BROWSER_GAME_AND_CANVAS.md)**:
  Details the architecture of the browser-playable Boss Battle demo. Explains how Odin passes C structs by pointer across the Wasm boundary, how `raylib_canvas.js` unpacks colors, and how modern browser keyboard controls work.
- **[04. Testing & CI Automation](04_TESTING_AND_AUTOMATION.md)**:
  Catalogs the 16 automated test suites in `examples/wasm_test/main.odin` and explains how headless Node.js harnesses verify 1000+ simulation frames with zero visual regression and zero runtime panics.
- **[05. Future Stack-Switching Roadmap](05_STACK_SWITCHING_ROADMAP.md)**:
  Surveys upcoming WebAssembly capabilities: Phase 2 shadow-stack pointer swapping (`$__stack_pointer`) and Phase 3 native hardware delimited continuations (W3C WasmFX: `cont.new`, `suspend`, `resume`).

---

## 4. Cross-Platform Binaryen Setup (Windows, Linux, macOS)

Binaryen's `wasm-opt` is required to instrument WebAssembly binaries with Asyncify. The project provides cross-platform setup tooling supporting both `x86_64` and `arm64` (Apple Silicon / Linux ARM64):

### Option A: Automatic Discovery
`build.ps1` automatically checks your system `$PATH`. If you already have `wasm-opt` installed via a system package manager, it is used immediately:
```bash
# macOS (Homebrew)
brew install binaryen

# Ubuntu / Debian
sudo apt install binaryen

# Arch Linux
sudo pacman -S binaryen
```

### Option B: Cross-Platform PowerShell (`pwsh`)
Runs identically on Windows, Linux, and macOS:
```powershell
.\tools\download_binaryen.ps1
```

### Option C: Universal Python 3 Downloader
Zero dependencies (uses standard library `urllib` and `tarfile`):
```bash
python tools/download_binaryen.py
```

Both downloaders fetch the official release from GitHub, unpack into `tools/binaryen/bin/`, set executable permissions on Unix, and verify with `wasm-opt --version`.

---

## 5. Command Reference

All WebAssembly workflows are orchestrated through `build.ps1`:

### 1. Build and Run the Complete 16-Suite Automated Wasm Tests
Compiles `examples/wasm_test`, applies `wasm-opt --asyncify`, and runs the suite under Node.js:
```powershell
.\build.ps1 test-wasm
```

### 2. Build the Web Game Package
Compiles `examples/game` to WebAssembly, instruments with Asyncify, and packages HTML/JS assets into `build/web/`:
```powershell
.\build.ps1 web-game
```

### 3. Run the Headless 1000-Frame Simulation Test
Executes the compiled WebAssembly game inside a headless Node.js mock canvas environment for 1000 frames (16.7s @ 60 FPS) to verify determinism and memory safety:
```powershell
.\build.ps1 test-web-game
```

### 4. Launch the Browser Web Server
Starts a local web server serving `build/web/` at `http://localhost:8080`:
```powershell
.\build.ps1 run-web-game
```

### 5. Package for itch.io Release
Builds and packages the web game into `build/boss_fight_itch.zip` ready for direct upload to itch.io:
```powershell
.\build.ps1 pack-itch
```
The archive places `index.html`, `game_opt.wasm`, and `raylib_canvas.js` directly at the root of the ZIP file to meet itch.io's hosting requirements.

