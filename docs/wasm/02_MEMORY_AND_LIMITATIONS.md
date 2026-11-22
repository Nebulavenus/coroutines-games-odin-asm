# WebAssembly Memory Architecture & Per-Fiber Shadow Stacks

This document provides a deep technical breakdown of the WebAssembly (`js_wasm32`) dual-stack execution model, explains the exact LLVM/Binaryen bytecode mechanics behind the historical shadow-stack aliasing and abort-leak bugs, and details how the engine's **Per-Fiber Shadow Stack Switching (`$__stack_pointer` swap)** permanently resolves both with 100% standard WebAssembly output and zero JavaScript host overhead.

---

## 1. The WebAssembly Dual-Stack Model

On native architectures (AMD64, ARM64, RISC-V 64), every fiber has a single contiguous hardware stack buffer holding call frames, return addresses, spilled registers, and address-taken locals. Swapping `%rsp` / `sp` isolates everything at once.

WebAssembly enforces a Harvard-style separation with **two distinct stacks**:

```text
+-----------------------------------------------------------------------------+
|                    WebAssembly (js_wasm32) Dual-Stack Model                 |
+-----------------------------------------------------------------------------+
|                                                                             |
|  1. Wasm VM Execution Stack (Hidden inside V8 / SpiderMonkey / Wasmtime)    |
|     • Function call frames, control-flow blocks, return addresses.          |
|     • Scalar local variables (i32, i64, f32, f64, externref).               |
|     • Not addressable via pointers or rawptr.                               |
|     • Serialized/restored per fiber by Binaryen Asyncify into               |
|       `Fiber.asyncify_buf` (default 4 KB).                                  |
|                                                                             |
|  2. LLVM Linear-Memory Shadow Stack (Lives inside `memory.buffer`)          |
|     • Tracked by a single mutable global: `(global $__stack_pointer i32)`   |
|     • Allocated whenever Odin/LLVM takes the address of a variable (`&x`),  |
|       passes structs by pointer, or stores fixed-size local arrays.         |
|     • ISOLATED PER FIBER by swapping `$__stack_pointer` in                  |
|       `wasm_dispatch_fiber` to each fiber's private 8 KB shadow stack!      |
|                                                                             |
+-----------------------------------------------------------------------------+
```

---

## 2. Why a Shared Shadow Stack Breaks Under Binaryen Asyncify

Disassembling an Asyncify-instrumented Odin function (`wasm-dis examples/wasm_test/test_opt.wasm`) reveals **two distinct bugs** when fibers share a single global `$__stack_pointer`:

```wat
;; Simplified WAT emitted by LLVM + `wasm-opt --asyncify` for a function
;; with a 16-byte shadow stack frame and a yield call:
(func $example_coroutine
  (local $fp i32)
  ;; --- 1. Rewind Preamble (state == 2): restores saved $fp from asyncify_buf ---
  (if (i32.eq (global.get $__asyncify_state) (i32.const 2))
    (then (local.set $fp (i32.load ...)))
  )
  (block $unwind_block
    ;; --- 2. Normal Entry Prologue (state == 0): decrements $__stack_pointer ---
    (if (i32.eq (global.get $__asyncify_state) (i32.const 0))
      (then
        (local.set $fp (i32.sub (global.get $__stack_pointer) (i32.const 16)))
        (global.set $__stack_pointer (local.get $fp))
      )
    )
    ;; --- 3. Yield Call Site ---
    (call $coroutine::yield)
    ;; If unwinding (state == 1), branch straight out — SKIPPING THE EPILOGUE!
    (if (i32.eq (global.get $__asyncify_state) (i32.const 1))
      (then (br $unwind_block))
    )
    ;; --- 4. Normal Return Epilogue (state == 0): restores $__stack_pointer ---
    (if (i32.eq (global.get $__asyncify_state) (i32.const 0))
      (then
        (global.set $__stack_pointer (i32.add (local.get $fp) (i32.const 16)))
        (return)
      )
    )
  )
  ;; Unwind tail: serializes $fp into asyncify_buf and returns WITHOUT restoring SP!
)
```

Look closely at what happens when two fibers share `(global $__stack_pointer)`:

1. **Permanent Shadow-Stack Leak on Unwind + Abort**:
   - When Fiber A enters `$example_coroutine`, `$__stack_pointer` decreases by `16`.
   - When Fiber A yields, Asyncify jumps to `$unwind_block` and **skips the epilogue** (`global.set $__stack_pointer ($fp + 16)`).
   - If Fiber A is subsequently **aborted** (`race` loss, timeout, `scope_cancel`) and never resumed, those `16` bytes (or 1 KB+ for larger local buffers) are **leaked permanently** off the single 1 MB global shadow stack until it collides with static data.
2. **Cross-Fiber Corruption on Out-of-Order Completion**:
   - Fiber A yields at `SP = 0xFF00`. Fiber B starts and pushes frames down to `SP = 0xFE80`, then yields.
   - Fiber A resumes and **returns** from `$example_coroutine`. Its epilogue executes `global.set $__stack_pointer (0xFF00 + 16 = 0xFF10)` — resetting the global `$__stack_pointer` **above Fiber B's live frame at `0xFE80`**!
   - The very next function call (Fiber C or the scheduler itself) decrements from `0xFF10` directly into `0xFE80` and **physically overwrites Fiber B's live local structs**.

---

## 3. The Solution: Per-Fiber Shadow Stack Switching (`$__stack_pointer` Swap)

Because Binaryen's unwind/rewind transform leaves `$__stack_pointer` at the exact bottom of a suspended fiber's active shadow-stack frames—and skips prologues on rewind while restoring saved `$fp` pointers—giving each fiber its own linear-memory shadow stack and swapping `$__stack_pointer` at the dispatcher boundary solves **both** corruption and leaks completely.

```mermaid
sequenceDiagram
    autonumber
    participant Sched as Scheduler (Host Stack)
    participant Disp as wasm_dispatch_fiber (Uninstrumented)
    participant Tramp as fiber_trampoline_entry
    participant Fiber as User Fiber Body

    Sched->>Disp: wasm_dispatch_fiber(f)
    Disp->>Disp: host_sp = _raw_get_sp()
    Disp->>Disp: _raw_set_sp(f.wasm_shadow_sp)
    Note over Disp,Fiber: $__stack_pointer now points inside f's private 8 KB slab
    Disp->>Tramp: fiber_trampoline_entry() [normal or rewind]
    Tramp->>Fiber: entry_proc(f, data)
    Fiber->>Fiber: local_st: My_Struct; ptr := &local_st (in f's private slab!)
    Fiber-->>Tramp: yield() -> Asyncify unwind (skips epilogues, preserves f's SP)
    Tramp-->>Disp: returns to uninstrumented boundary
    Disp->>Disp: _raw_stop_unwind()
    Disp->>Disp: f.wasm_shadow_sp = _raw_get_sp()
    Disp->>Disp: _raw_set_sp(host_sp)
    Note over Disp,Sched: Host $__stack_pointer restored BEFORE canary/overflow checks
    Disp->>Disp: Verify Asyncify_Buffer bounds & 64B shadow-stack canary
    Disp-->>Sched: Return safely on Host Stack
```

### 3.1 Why `wasm_dispatch_fiber` Is the Ideal Swap Boundary
Inspecting raw `wasm-dis` output confirms two crucial invariants:
1. **`wasm_dispatch_fiber` is `isBottomMostRuntime`** (calls `_raw_start_rewind` and `_raw_stop_unwind`): Binaryen never instruments it.
2. **`wasm_dispatch_fiber` allocates 0 shadow-stack bytes** of its own, storing `host_sp` in a Wasm VM `i32` register. Meanwhile, `fiber_trampoline_entry` *does* allocate a 64-byte shadow-stack frame (for `context = fiber.stored_context`)—and because it runs *after* `_raw_set_sp(f.wasm_shadow_sp)`, even the trampoline's `context` frame lives cleanly inside the fiber's private shadow stack!

### 3.2 Runtime Implementation ([`asm_wasm32.odin`](../../asm_wasm32.odin))

```odin
foreign import asyncify "asyncify"
foreign import wasm_sp "coro_sp"

@(default_calling_convention = "c")
foreign wasm_sp {
    @(link_name = "get_sp")
    _raw_get_sp :: proc() -> u32 ---
    @(link_name = "set_sp")
    _raw_set_sp :: proc(sp: u32) ---
}

wasm_dispatch_fiber :: proc(f: ^Fiber) {
    g_wasm_current_fiber = f
    host_sp := _raw_get_sp()
    _raw_set_sp(u32(uintptr(f.wasm_shadow_sp)))
    if !f.wasm_started {
        f.wasm_started = true
        fiber_trampoline_entry()
    } else {
        g_wasm_is_rewinding = true
        _raw_start_rewind(&f.asyncify_buf)
        fiber_trampoline_entry()
    }
    _raw_stop_unwind()
    f.wasm_shadow_sp = rawptr(uintptr(_raw_get_sp()))
    _raw_set_sp(host_sp)
    if f.asyncify_buf.top > f.asyncify_buf.end {
        panic("WebAssembly Asyncify_Buffer overflow! Increase -define:CORO_ASYNCIFY_STORAGE_SIZE.")
    }
    if !fiber_check_canary(f) {
        panic("WebAssembly fiber shadow stack overflow! Increase -define:CORO_WASM_SHADOW_STACK_SIZE.")
    }
}
```

### 3.3 Zero-JS Build-Time Lowering ([`tools/wasm_asyncify.py`](../../tools/wasm_asyncify.py))

Odin currently exposes `intrinsics.stack_pointer()` (read) but has no `set_stack_pointer` / `@llvm.stackrestore` intrinsic (write) and no inline `asm` for `wasm32`. Rather than crossing the JS boundary on every context switch, `tools/wasm_asyncify.py` lowers the two `"coro_sp"` imports directly into 1-instruction standard Wasm functions *before* running `wasm-opt --asyncify`:

1. Disassembles `<input.wasm>` using the bundled `tools/binaryen/bin/wasm-dis`.
2. Locates `(global $__stack_pointer (mut i32) ...)` (falling back to the first `(mut i32)` global for stripped `-o:speed` binaries—guaranteed to be global index 0 by the LLVM WebAssembly Tool Conventions ABI).
3. Removes the two `(import "coro_sp" ...)` lines and injects two internal module functions:
   ```wat
   (func $coro_sp..get_sp (result i32)
    (global.get $__stack_pointer)
   )
   (func $coro_sp..set_sp (param $0 i32)
    (global.set $__stack_pointer (local.get $0))
   )
   ```
4. Runs `wasm-opt --asyncify` with standard WebAssembly 2.0 feature flags (`--enable-bulk-memory`, `--enable-bulk-memory-opt`, `--enable-nontrapping-float-to-int`, `--enable-sign-ext`, `--enable-mutable-globals`, `--enable-multivalue`, `--enable-simd`, `--enable-reference-types`) to validate, re-index, and emit `<output.wasm>`.

**Properties of the resulting `.wasm` binary:**
- **100% Standard WebAssembly**: Uses only standard `global.get`/`global.set` instructions; no WasmFX, no experimental flags, no custom browser extensions.
- **Zero JS Host Changes**: `"coro_sp"` does not appear in the final module's imports (`tools/run_wasm.js`, `tools/web/raylib_canvas.js`, `index.html`, Node.js, Cloudflare Workers, Wasmtime, and itch.io work out of the box).
- **Zero-Python Fallback**: Downstream users who run raw `wasm-opt --asyncify` without `tools/wasm_asyncify.py` can still link with `-extra-linker-flags:"--export=__stack_pointer"` and supply a 2-line JS `coro_sp` import object:
  ```javascript
  coro_sp: {
      get_sp: () => instance.exports.__stack_pointer.value,
      set_sp: (sp) => { instance.exports.__stack_pointer.value = sp; },
  }
  ```

---

## 4. Per-Fiber Memory Footprint, Canaries & Telemetry

| Buffer on Wasm Fiber | Default Size | `#config` Override | Purpose & Overflow Protection |
| :--- | :---: | :--- | :--- |
| **Linear Shadow Stack** (`stack_base`..`stack_size`) | **8 KB** (256 KB / 32-fiber slab) | `-define:CORO_WASM_SHADOW_STACK_SIZE=N` | Holds `&local_var`, structs, arrays, trampoline `context`. Protected by 64B `CANARY_MAGIC` + `0xAA` watermark (`fiber_calc_stack_usage`). |
| **Asyncify Unwind Buffer** (`asyncify_buf.storage`) | **4 KB** (inline in `Fiber`) | `-define:CORO_ASYNCIFY_STORAGE_SIZE=N` | Serializes Wasm VM call frames & scalar locals across yields. Runtime overflow panic + live telemetry (`fiber_calc_asyncify_usage`). |
| **Fiber Temp Arena** (`temp_arena_buffer`) | **4 KB** (inline in `Fiber`) | `-define:CORO_TEMP_ARENA_SIZE=N` (`0` to opt out) | Isolated `context.temp_allocator` scratchpad per fiber. |
| **Inline Payload** (`payload_storage`) | **128 B** (inline in `Fiber`) | `-define:CORO_PAYLOAD_SIZE=N` | Zero-alloc `spawn_val` / `branch_val` parameter storage. |

Because Wasm's shadow stack **only** stores address-taken locals (unlike native 32 KB stacks that also store return addresses, saved registers, and all locals), 8 KB is 4× smaller than native stacks while providing generous headroom for structs, local arrays, and `fmt.tprintf`.

### What Happens on Abort (`fiber_abort_tree`)
When a suspended Wasm fiber is cancelled (`race` loss, timeout, `scope_cancel`):
- The host `$__stack_pointer` is completely untouched (it was already restored when the fiber yielded).
- `fiber_pool_recycle` checks the 64-byte canary, updates `stack_high_water`, resets `wasm_shadow_sp` back to the aligned top of the fiber's private slab, and returns the fiber to the pool.
- **0 bytes leaked** on the host shadow stack (verified by Suite 21 running 500 mid-frame aborts with 1 KB stack buffers and asserting `get_sp() == host_sp_before`).

---

## 5. Practical WebAssembly Guidelines

With per-fiber shadow stacks active, **native and WebAssembly code are 100% source-compatible**:

1. **Stack-Local Structs & `&local` Pointers Work Everywhere**:
   ```odin
   // 100% SAFE ON BOTH NATIVE AND WEBASSEMBLY:
   local_int := 0
   local_str := ""
   winner := coroutine.race(f,
       sync.branch_chan_recv(&ch_int, &local_int),
       sync.branch_chan_recv(&ch_str, &local_str),
       coroutine.branch_wait(1.0),
   )
   ```
2. **Size Shadow Stacks for Large Locals**: Default `CORO_WASM_SHADOW_STACK_SIZE` is `8 KB` (minimum `4 KB`). If your coroutines allocate multi-kilobyte local arrays on the stack, either raise `-define:CORO_WASM_SHADOW_STACK_SIZE=16384` or allocate large temporary buffers in `context.temp_allocator` / heap.
3. **Prefer `ticker_wait` for Drift-Free Loops**: Even though local structs are now shadow-stack safe, `coroutine.ticker_wait(f, interval)` remains the fastest, zero-stack-footprint periodic timer.
4. **Monitor Both Watermarks in Debuggers**: Use `coroutine.fiber_calc_stack_usage(f)` for shadow-stack high-water usage and `coroutine.fiber_calc_asyncify_usage(f)` for Asyncify VM unwind depth.
5. **Always Post-Process with `tools/wasm_asyncify.py`**: Use `.\build.ps1 wasm` / `test-wasm` / `web-game` / `pack-itch`, or run `python tools/wasm_asyncify.py input.wasm output.wasm` in custom pipelines.
