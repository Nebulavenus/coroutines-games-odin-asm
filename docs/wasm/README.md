# WebAssembly (js_wasm32) Coroutine Engine Architecture

Welcome to the **WebAssembly Documentation Suite** for the Odin coroutine engine. This directory provides an exhaustive technical breakdown of how cooperative fibers, structured concurrency, and game simulation loops run inside web browsers and headless JavaScript runtimes without native OS threads or physical CPU register swapping.

---

## 1. Executive Summary

On native operating systems (Windows, Linux, macOS) across AMD64, ARM64, and RISC-V 64, this engine performs cooperative fiber context switching via custom inline assembly (100% high-level `asm` on AMD64, hybrid high-level `asm` with minimal `#byte` on ARM64 and RISC-V 64) in **~16–19 nanoseconds**, allocating an isolated physical stack buffer for each fiber.

Standard WebAssembly 1.0 does not provide physical stack pointers, register access, or first-class delimited continuations. To achieve full cross-platform parity for web browsers and Node.js:
1. **Binaryen Asyncify + Per-Fiber Shadow Stacks (`tools/wasm_asyncify.py`)**: Transforms standard Odin procedure call graphs into resumable state machines (`wasm-opt --asyncify`) while swapping LLVM's `(global $__stack_pointer)` to a private 8 KB linear-memory shadow stack per fiber—giving 100% native parity for `&local_struct` across yields and 0-byte abort leaks with zero JS host changes.
2. **Zero-C HTML5 Canvas 2D Adapter (`tools/web/raylib_canvas.js`)**: Emulates Raylib graphics and input APIs directly in browser JavaScript with zero external C/C++ dependencies or Emscripten SDK overhead.
3. **Fiber-Owned Memory Hardening**: Complements per-fiber shadow stacks with fiber-owned `ticker_wait`, 128-byte inline `payload_storage`, and private 4 KB `temp_arena` scratchpads.

---

## 2. Architecture Comparison Matrix

| Feature | Native OS (AMD64, ARM64, RISC-V 64) | WebAssembly (`js_wasm32`) |
| :--- | :--- | :--- |
| **Context Switch Mechanism** | Physical register push/pop & stack pointer swap | Binaryen Asyncify unwind/rewind + `$__stack_pointer` swap |
| **Context Switch Latency** | **~16 ns** | ~120–300 ns (traverses active call frames) |
| **Fiber Stacks** | Private isolated stack buffer per fiber (32 KB + canary) | Private 8 KB shadow stack (+ 64B canary) + 4 KB Asyncify buffer |
| **Memory Isolation** | Per-fiber stack buffer (+ optional OS guard pages) | Per-fiber linear shadow stack + per-fiber Asyncify unwind buffer |
| **Local Variables** | Reside on private fiber stack | Scalar locals in Asyncify buffer; `&local_struct` in private shadow stack |
| **Structured Concurrency** | Fully supported (`sync`, `race`, `rush`, `branch_scoped`) | Fully supported (`sync`, `race`, `rush`, `branch_scoped`) |
| **CSP Channels** | Symmetrical rendezvous & buffered ring buffers | Symmetrical rendezvous & buffered ring buffers |
| **Multi-Domain Clocks** | Indexed `Clock_Domain` (`CLOCK_SIM`, `CLOCK_REAL`, `CLOCK_PHYS`) | Indexed `Clock_Domain` (`CLOCK_SIM`, `CLOCK_REAL`, `CLOCK_PHYS`) |
| **Graphics Runtime** | Native Desktop Raylib (OpenGL / DirectX) | Pure HTML5 2D Canvas Adapter (`tools/web/raylib_canvas.js`) |
| **Build Artifact** | Native PE / ELF / Mach-O executable | Standalone `.wasm` bundle (`tools/wasm_asyncify.py`) |

---

## 3. Documentation Index

The documentation track is organized into five deep-dive technical modules:

```
docs/wasm/
├── README.md                      # This document (Navigation Hub & Overview)
├── 01_ARCHITECTURE_ASYNCIFY.md   # Asyncify Integration, Leaf Protocol & Event Loop
├── 02_MEMORY_AND_LIMITATIONS.md   # Dual-Stack Mechanics, Per-Fiber $__stack_pointer Swap & Telemetry
├── 03_BROWSER_GAME_AND_CANVAS.md  # Porting Raylib Games, C ABI Struct Unpacking & Controls
├── 04_TESTING_AND_AUTOMATION.md   # 21-Suite Test Harness, Headless Node.js CI & Fuzzing
├── 05_STACK_SWITCHING_ROADMAP.md  # Phase 2 Shadow Stacks, Future Odin Compiler Features & WasmFX
```

### Module Summaries:
- **[01. Architecture & Asyncify Integration](01_ARCHITECTURE_ASYNCIFY.md)**:
  Examines how Odin procedures are rewritten by Binaryen Asyncify, why the leaf unwind/rewind protocol (`start_unwind` on yield, `stop_rewind` upon entry in `yield`) is required, and how the browser event loop schedules fibers.
- **[02. Memory Architecture & Per-Fiber Shadow Stacks](02_MEMORY_AND_LIMITATIONS.md)**:
  Dissects LLVM's `$__stack_pointer` bytecode under Asyncify, explains how per-fiber 8 KB shadow stacks + `tools/wasm_asyncify.py` eliminate both `&local_struct` corruption and abort leaks with zero JS overhead, and documents canary/watermark telemetry.
- **[03. Browser Game & Canvas Adapter](03_BROWSER_GAME_AND_CANVAS.md)**:
  Details the architecture of the browser-playable Boss Battle demo. Explains how Odin passes C structs by pointer across the Wasm boundary, how `raylib_canvas.js` unpacks colors, and how modern browser keyboard controls work.
- **[04. Testing & CI Automation](04_TESTING_AND_AUTOMATION.md)**:
  Catalogs all 21 automated test suites in `examples/wasm_test/main.odin` and explains how headless Node.js harnesses verify 1000+ interactive simulation frames with zero visual regression, zero `NaN`/`Inf`, and zero runtime panics.
- **[05. Stack-Switching, Future Odin Features & Roadmap](05_STACK_SWITCHING_ROADMAP.md)**:
  Documents implemented Phase 2 per-fiber shadow-stack switching, catalogs concrete upstream Odin compiler features (`intrinsics.set_stack_pointer`, Wasm inline `asm`, deferred `when`/`asm` parsing, WasmFX intrinsics), and outlines Phase 3 WasmFX migration.

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

### 1. Build and Run the Complete 21-Suite Automated Wasm Tests
Compiles `examples/wasm_test`, applies `tools/wasm_asyncify.py` (per-fiber shadow stacks + `wasm-opt --asyncify`), and runs the suite under Node.js:
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

