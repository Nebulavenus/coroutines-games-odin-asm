# WebAssembly Stack-Switching & Future Roadmap

This document surveys future WebAssembly specifications, analyzes the technical evolution from Binaryen Asyncify to **Shadow-Stack Pointer Swapping** (Phase 2) and native **Wasm Stack-Switching** (Phase 3: WasmFX), and explains the architectural migration path.

---

## 1. Evolution Overview

| Phase | Technology | Stack Isolation | Context Switch Overhead | Toolchain Requirement |
| :--- | :--- | :--- | :--- | :--- |
| **Phase 1 (Current)** | **Binaryen Asyncify** | VM locals saved; Shared shadow stack in linear memory | ~120–350 ns (call tree traversal) | `wasm-opt --asyncify` |
| **Phase 2 (Near-Term)** | **Shadow-Stack Swapping** | Private shadow stack slices in linear memory per fiber | ~120–350 ns + pointer swap | Host JS or Binaryen pass |
| **Phase 3 (Standard)** | **WasmFX Stack-Switching** | True hardware-isolated delimited continuations | **~15–20 ns** (Zero call tree traversal) | Native Browser VM Support (`cont.new`) |

---

## 2. Phase 2: True Shadow-Stack Pointer Swapping

### The Motivation
Currently, Asyncify unwinds the WebAssembly execution stack, but all fibers share the single LLVM shadow stack at `(global $__stack_pointer)`. As detailed in `02_MEMORY_AND_LIMITATIONS.md`, this creates shadow-stack aliasing if local structs are retained across yields.

### How Shadow-Stack Swapping Works
LLVM allocates the shadow stack starting at a high linear memory address (e.g. `1048576`) and grows downward.
In Phase 2, each fiber in `Fiber_Pool` is assigned a private 16 KB or 32 KB slice of linear memory:

```odin
// Proposed Fiber Memory Layout in Linear Memory
Fiber_Shadow_Stack :: struct {
    stack_bottom: rawptr,
    stack_top:    rawptr,
    saved_sp:     i32,
}
```

When yielding and resuming:
1. **On Yield (`yield`)**:
   ```javascript
   // Read current LLVM stack pointer and store in active fiber
   fiber.saved_shadow_sp = wasmInstance.exports.__stack_pointer.value;
   ```
2. **On Resume (`run_fiber`)**:
   ```javascript
   // Restore next fiber's private shadow stack pointer
   wasmInstance.exports.__stack_pointer.value = nextFiber.saved_shadow_sp;
   ```

### Toolchain Prerequisites
- **Odin Compiler Support**: Currently, Odin's `asm` keyword is restricted to `-target:*_amd64`, `-target:*_arm64`, and `-target:*_riscv64`. Attempting `asm() { "global.get $__stack_pointer", ... }` produces a syntax error.
- **Interim Path**: Expose helper functions through JavaScript or a small WAT module (`(export "get_sp")` / `(export "set_sp")`).

---

## 3. Phase 3: Hardware Wasm Stack-Switching (WasmFX)

The W3C WebAssembly Working Group is actively finalizing the **Wasm Stack-Switching / Delimited Continuations Proposal** (Phase 3).

### What WasmFX Provides
WasmFX introduces first-class continuations directly into the WebAssembly instruction set:

```wat
;; WasmFX Delimited Continuation Instructions
(type $coro_sig (func (param i32) (result i32)))
(tag $yield_tag (param i32) (result i32))

;; Create a new stack-switching continuation
cont.new $continuation_type (ref.func $fiber_entry)

;; Suspend the active continuation without unwinding
suspend $yield_tag

;; Resume a suspended continuation
resume $continuation_type (tag $yield_tag $on_yield_handler)
```

### The Architectural Transformation
When browser engines standardize WasmFX:
1. **Zero Binaryen Asyncify**: `wasm-opt --asyncify` is no longer needed.
2. **Zero Code Size Bloat**: Binaries shrink by 10–15% because functions no longer require injected state machines.
3. **Hardware Latency (~16 ns)**: Suspending and resuming a continuation will be as fast as our native AMD64/ARM64 context switches.
4. **Complete Stack Isolation**: Continuations provide true VM-level stack isolation for each fiber.

---

## 4. Migration & Compatibility Guarantee

The public API of this library is designed with pure abstraction:
```odin
coroutine.spawn(&sched, proc(f: ^Fiber) {
    for {
        coroutine.wait(f, 0.5)
    }
})
```
Whether running on **Native Assembly** (AMD64/ARM64/RISC-V 64), **Binaryen Asyncify** (Phase 1), **Shadow-Stack Swapping** (Phase 2), or **WasmFX** (Phase 3), the gameplay programmer writes the exact same clean, idiomatic Odin code with zero platform-specific `#ifdef` directives.
