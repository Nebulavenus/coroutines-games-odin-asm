# WebAssembly Stack-Switching, Future Odin Compiler Features & Roadmap

This document tracks the evolution of WebAssembly stackful coroutines in `coroutines_asm`—from Phase 1 (shared-stack Asyncify) through **Phase 2 (Per-Fiber Shadow Stack Switching — Implemented)** to **Phase 3 (Native WasmFX)**—and catalogs specific **upstream Odin compiler and language improvements** that would eliminate remaining build-time tooling and push WebAssembly and native ergonomics even further.

---

## 1. Evolution Overview

| Phase | Technology | Stack Isolation | Context Switch Overhead | Toolchain Requirement | Status |
| :--- | :--- | :--- | :--- | :--- | :---: |
| **Phase 1** | **Binaryen Asyncify (Shared SP)** | VM locals saved; shared `$__stack_pointer` (aliasing & abort leaks) | ~120–300 ns | `wasm-opt --asyncify` | *Superseded* |
| **Phase 2 (Current)** | **Asyncify + Per-Fiber `$__stack_pointer` Swap** | Private 8 KB linear shadow stack + 64B canary per fiber; 0-leak aborts | ~120–300 ns + 2 `global` ops | `tools/wasm_asyncify.py` (`wasm-dis` + `wasm-opt --asyncify`) | **Implemented** |
| **Phase 2.5 (Odin Intrinsic)** | **Asyncify + `intrinsics.set_stack_pointer`** | Identical to Phase 2, zero WAT patching | ~120–300 ns + 2 `global` ops | Raw `wasm-opt --asyncify` only | *Pending Odin* |
| **Phase 3 (Future)** | **WasmFX Stack-Switching** | Hardware-isolated VM continuations (`cont.new`, `suspend`, `resume`) | **~15–20 ns** (no call-tree unwind) | Native Browser VM + Odin WasmFX intrinsics | *W3C Proposal* |

---

## 2. Phase 2 (Implemented): Per-Fiber Shadow-Stack Pointer Swapping

As detailed in [`02_MEMORY_AND_LIMITATIONS.md`](02_MEMORY_AND_LIMITATIONS.md), Phase 2 is live and enabled by default:
- Every Wasm fiber owns a dedicated linear-memory shadow stack (`WASM_SHADOW_STACK_SIZE :: #config(CORO_WASM_SHADOW_STACK_SIZE, 8 * 1024)`) with 64-byte `CANARY_MAGIC` overflow guards and watermark tracking (`fiber_calc_stack_usage`).
- `wasm_dispatch_fiber` (uninstrumented `isBottomMostRuntime`) saves the host `$__stack_pointer`, switches to `f.wasm_shadow_sp`, executes or rewinds `fiber_trampoline_entry()`, captures `f.wasm_shadow_sp`, and restores the host `$__stack_pointer` before checking Asyncify/canary overflow.
- [`tools/wasm_asyncify.py`](../../tools/wasm_asyncify.py) lowers `coro_sp.get_sp` / `coro_sp.set_sp` into 1-instruction internal Wasm `(global.get $__stack_pointer)` / `(global.set $__stack_pointer)` functions prior to `wasm-opt --asyncify`, producing **100% standard WebAssembly** with **zero JS host changes**.

---

## 3. What Could Be Added to Odin Later to Make This Even Better

Everything below represents concrete, minimal upstream additions to the **Odin compiler (`base:intrinsics`, parser, or driver)** that would directly simplify or accelerate this architecture.

### 3.1 `intrinsics.set_stack_pointer(sp: rawptr)` *(Highest Impact — Eliminates `wasm_asyncify.py`)*
- **Current Gap**: Odin already provides `intrinsics.stack_pointer() -> rawptr` (`base:intrinsics`), which lowers to LLVM `@llvm.stacksave` (`global.get $__stack_pointer` on `wasm32`), but provides **no write counterpart** (`@llvm.stackrestore` / `global.set $__stack_pointer`).
- **What Adding It Unlocks**:
  ```odin
  // Hypothetical pure-Odin wasm_dispatch_fiber with zero build-time WAT patching:
  wasm_dispatch_fiber :: proc(f: ^Fiber) {
      g_wasm_current_fiber = f
      host_sp := intrinsics.stack_pointer()
      intrinsics.set_stack_pointer(f.wasm_shadow_sp)
      // ... run or rewind fiber_trampoline_entry() ...
      _raw_stop_unwind()
      f.wasm_shadow_sp = intrinsics.stack_pointer()
      intrinsics.set_stack_pointer(host_sp)
  }
  ```
  - Completely removes `foreign import wasm_sp "coro_sp"` and `tools/wasm_asyncify.py`.
  - Reduces the Wasm build pipeline back to plain `odin build -target:js_wasm32` + `wasm-opt --asyncify`.
  - Works seamlessly for single-file `dist/coroutine_wasm32.odin` drop-in users with zero extra scripts.

### 3.2 WebAssembly Support in Odin's Inline `asm(...)` Templates
- **Current Gap**: Odin's new `asm(...)` template system (`docs/ASM.md`) currently supports `amd64`, `arm64`, and `riscv64`, rejecting `wasm32` at parse time.
- **What Adding It Unlocks**:
  - Direct emission of Wasm instructions (`global.get $__stack_pointer`, `global.set $__stack_pointer`, future WasmFX `cont.new` / `suspend` / `resume`, or SIMD/atomic instructions) using the exact same declarative `asm(...)` pattern as `asm_amd64.odin`, `asm_arm64.odin`, and `asm_riscv64.odin`.
  - Enables writing all 4 architectures (`amd64`, `arm64`, `riscv64`, `wasm32`) without external WAT scripts or foreign stubs.

### 3.3 Deferring `asm(...)` Target Validation Past `when` Branches
- **Current Gap**: Odin validates `asm(...)` template syntax during parsing—*before* compile-time `when ODIN_ARCH == ...` pruning. Including `asm(...)` blocks inside a file compiled for `-target:js_wasm32` fails with a syntax error even inside `when ODIN_ARCH == .amd64 { ... }`.
- **What Adding It Unlocks**:
  - Eliminates the need for **two** amalgamated distribution files (`dist/coroutine.odin` + `dist/coroutine_wasm32.odin`).
  - Allows a **single universal drop-in file (`dist/coroutine.odin`)** that compiles cleanly across all 7 targets (Windows/Linux/macOS AMD64, ARM64, RISC-V 64, and `js_wasm32`).

### 3.4 First-Class WasmFX (`stack-switching`) Intrinsics in `base:intrinsics`
- **Current Gap**: Binaryen Asyncify rewrites every potentially-yielding function into a state machine, adding ~10–15% binary size overhead and ~120–300 ns unwind/rewind latency proportional to call-stack depth.
- **What Adding It Unlocks** (once W3C WasmFX ships in V8/SpiderMonkey/JavaScriptCore):
  - Native VM-managed delimited continuations (`cont.new`, `suspend`, `resume`) exposed via `base:intrinsics` (or Wasm inline `asm`):
    ```wat
    (type $coro_sig (func (param i32)))
    (tag $yield_tag)
    cont.new $coro_cont (ref.func $fiber_trampoline_entry)
    suspend $yield_tag
    resume $coro_cont (on $yield_tag $handle_yield)
    ```
  - **Zero Binaryen post-processing** (`wasm-opt --asyncify` no longer required at all).
  - **~15–20 ns hardware-grade context switches** (matching native AMD64/ARM64/RISC-V 64) regardless of call depth.
  - Combined with per-fiber `$__stack_pointer` swapping (still required by LLVM's linear shadow stack even under WasmFX!), gives true zero-overhead native-equivalent fibers in browsers.

### 3.5 Optional Driver Integration (`-wasm-asyncify` or Post-Link Hook)
- **Current Gap**: Projects targeting Asyncify must invoke Binaryen externally via `build.ps1` / Make / CI scripts.
- **What Adding It Unlocks**: A built-in Odin compiler flag (e.g. `-wasm-asyncify` or a linker/post-link pass invoking Binaryen) would make `odin build examples/game -target:js_wasm32 -wasm-asyncify` a single-command workflow.

### 3.6 Native & API Ergonomics Improvements in Odin (Cross-Cutting)
Beyond WebAssembly, three small Odin compiler enhancements would also directly benefit the native backends and public API:
1. **Segment Register Prefix (`gs:` / `fs:`) in Win64 Inline `asm`**: Adding `gs:[0x08]` / `gs:[0x10]` support to Odin's AMD64 `asm` syntax would let `asm_amd64.odin` swap the Windows TEB `StackBase`/`StackLimit` fields cleanly without raw `#byte` machine-code escapes (improving interoperability with Windows SEH / C++ exceptions inside fibers).
2. **File/Group-Private `proc` Group Members**: Today, all member procedures of an exported `proc{...}` group (`spawn_ptr`, `spawn_val`, `spawn_nil`, `with_signal_*`) must remain package-public for cross-package overload resolution, inflating IDE autocomplete lists. Allowing `@(private="group")` (or resolving `proc` group members regardless of member visibility) would shrink the visible API surface by ~3× without losing polymorphic call ergonomics.
3. **Scoped Fiber Unwind / Cancellation Hooks**: Native Odin `defer` only executes on normal lexical return, requiring explicit `coroutine.fiber_defer` for abort-safe cleanup. While stackful coroutines fundamentally bypass lexical returns on external abort, lightweight anonymous captureless-or-explicit-capture closure sugar (or `defer` annotations) would reduce `Ctx` struct boilerplate in `sync` / `race` / `with_signal` call sites.

---

## 4. Phase 3: Hardware Wasm Stack-Switching (WasmFX)

When the W3C **WebAssembly Stack-Switching (WasmFX)** proposal reaches broad browser availability (Chrome, Firefox, Safari, Node.js LTS):
1. `asm_wasm32.odin` swaps its internal `wasm_dispatch_fiber` / `wasm_yield_leaf` implementation from Asyncify intrinsics to WasmFX `cont.new` / `suspend` / `resume`.
2. Per-fiber `$__stack_pointer` switching remains in place to isolate LLVM's linear shadow stack across continuations.
3. **Zero user code changes**: Every `spawn`, `wait`, `sync`, `race`, `rush`, `Channel(T)`, `Event(T)`, and `Clock_Domain` call remains 100% source-compatible across Native ASM, Asyncify + Shadow Stacks, and WasmFX.
