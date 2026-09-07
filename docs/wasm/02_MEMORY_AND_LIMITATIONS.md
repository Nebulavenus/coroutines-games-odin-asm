# WebAssembly Memory Architecture & Limitations

This document provides a comprehensive technical analysis of the memory model in WebAssembly (`js_wasm32`), explains the **Dual-Stack Dilemma**, details why the C/LLVM shadow stack causes memory corruption across interleaved fiber yields, and presents the engine's built-in hardening solutions alongside the **3 Golden Rules of WebAssembly Coroutines**.

---

## 1. The Dual-Stack Dilemma

On native platforms (AMD64, ARM64, RISC-V 64), a fiber has a single, contiguous stack buffer. Both call frames and stack-allocated structs reside in this private buffer. When `fiber_context_switch` changes `%rsp` / `sp`, the entire stack is switched.

WebAssembly enforces a strict Harvard-style separation with **two distinct stacks**:

```
+-----------------------------------------------------------------------------+
|                          WebAssembly Runtime Model                          |
+-----------------------------------------------------------------------------+
|                                                                             |
|  1. VM Execution Stack (Managed by Browser Engine, Hidden from Code)        |
|     • Function call frames, block nesting, return addresses.                |
|     • Primitive local variables (i32, i64, f32, f64, externref).            |
|     • Cannot be referenced via pointers or rawptr.                          |
|     • Fully serialized and restored by Binaryen Asyncify!                   |
|                                                                             |
|  2. LLVM / C Shadow Stack (Lives inside Linear Memory: `memory.buffer`)     |
|     • Tracked by a single mutable global: `(global $__stack_pointer)`       |
|     • Allocated whenever Odin/C code takes the address of a variable (&x).  |
|     • Used for composite structs, fixed-size arrays, and pass-by-reference. |
|     • SHARED ACROSS ALL FIBERS BY DEFAULT!                                  |
|                                                                             |
+-----------------------------------------------------------------------------+
```

---

## 2. The Shared Shadow-Stack Aliasing Problem

Because standard WebAssembly 1.0 does not have per-fiber memory spaces:
1. **Asyncify serializes ONLY the VM Execution Stack.** It captures primitive values stored in VM registers.
2. **Asyncify does NOT save, restore, or split Linear Memory (`memory.buffer`).**

When code takes the address of a local struct (`&my_struct`), LLVM allocates it on the **shadow stack** in linear memory by decrementing `$__stack_pointer`.

### The Corruption Scenario:
```text
Turn 1: Fiber A runs.
        Allocates `ticker: Ticker` on shadow stack at address 0x10000.
        Yields (coroutine.wait). Asyncify saves Fiber A's VM registers.
        Linear memory at 0x10000 is left untouched.

Turn 2: Fiber B runs.
        Fiber B calls a function chain (e.g. camera shake, particle spawner).
        LLVM decrements `$__stack_pointer` and allocates Fiber B's frames
        right over 0x10000!
        Fiber B writes variables into 0x10000.

Turn 3: Fiber A wakes up.
        Asyncify restores Fiber A's VM registers.
        Fiber A reads from address 0x10000 (&ticker).
        The data at 0x10000 has been MUTATED or ZEROED by Fiber B!
```

---

## 3. Real-World Case Study: The Boss EMP Stun Bug

In our browser game demo (`examples/game/main.odin`), the Boss AI executed a spiral projectile barrage:

```odin
// DANGEROUS ANTI-PATTERN ON WEBASSEMBLY:
boss_spiral_shoot_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    ticker: coroutine.Ticker // <-- Local struct allocated on shared shadow stack!
    coroutine.ticker_init(&ticker, 0.08)
    for {
        coroutine.ticker_wait(f, &ticker) // Passes '&ticker' across yield
        fire_spiral_bullet(b)
    }
}
```

### What Happened During Playtesting:
1. When the player pressed `E` (EMP Stun), the boss was stunned for 1.5 seconds.
2. The attack fiber suspended execution.
3. During those 1.5 seconds, other active fibers (player shield recovery, floating combat text animations, particle emitters) executed deep stack frames.
4. Their stack allocations pushed down from `$__stack_pointer` and **physically overwrote `ticker.interval` with zeroes**.
5. When the boss woke from stun, `ticker_wait` checked:
   ```odin
   if t.next_wake <= 0.0 { ... }
   ```
   Because `interval` was `0`, the next wake time was identical to `now`.
6. Instead of waiting 0.08s between shots, `ticker_wait` fell back to `yield_frame(f)`, firing **80 bullets in 10 frames** (an immediate boss projectile machine-gun burst).

---

## 4. Engine Hardening Solutions

To permanently protect developers from this class of bugs, the coroutine engine provides built-in facilities that reside outside the shadow stack:

### 1. Built-in Fiber Ticker (`wait_ticker` & `ticker_wait`)
Instead of storing timing state on the local stack, the `Fiber` struct itself provides preallocated, persistent timing fields in heap/pool memory:

```odin
// types.odin
Fiber :: struct {
    // ...
    // --- Built-in Zero-Drift Ticker (100% Shadow-Stack Safe) ---
    ticker_interval:  f32,
    ticker_next_wake: f64,
    ticker_use_real:  bool,
    // ...
}
```

Developers can now write clean, zero-allocation timing loops without declaring a stack struct:

```odin
// 100% SAFE ON WEBASSEMBLY AND NATIVE:
boss_spiral_shoot_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for {
        // Zero stack allocations! Stored directly on Fiber:
        coroutine.wait_ticker(f, 0.08)
        fire_spiral_bullet(b)
    }
}
```

#### Key Capabilities:
- **Exact $f64$ Zero-Drift Precision**: Calculates `next_wake += interval` using double-precision floating point timestamps.
- **Dynamic Re-basing**: Automatically re-aligns schedule if the interval changes dynamically.
- **Stun / Interruption Reset**: Calling `coroutine.ticker_rebase(f)` resets the next wake timestamp to start cleanly from `now + interval` without catch-up bursts.

### 2. Fiber Payload Storage (`f.payload_storage`)
Each fiber contains an aligned 128-byte inline buffer (`[FIBER_PAYLOAD_SIZE]byte`). When using `spawn_val` or `spawn_real_val`, parameters are copied directly into the fiber's persistent memory, immune to stack overwrites.

### 3. Fiber Isolated Temp Arena (`f.temp_arena`)
Each fiber owns a private 4KB scratch arena (`f.temp_arena_buffer`). Memory allocated via `context.temp_allocator` inside a fiber:
- Persists across yields.
- Is strictly private to that fiber.
- Is automatically reset when the fiber completes and returns to the pool.

---

## 5. The 3 Golden Rules of WebAssembly Coroutines

When writing coroutines that target `js_wasm32`, adhere strictly to these three rules:

| Rule | Principle | Safe Pattern | Dangerous Anti-Pattern |
| :--- | :--- | :--- | :--- |
| **Rule 1** | **Keep Primitives in Local Variables** | `timer: f32 = 1.5`<br>`count: int = 10` | N/A (VM registers are safe) |
| **Rule 2** | **Never Retain Local `&` Across Yields** | Pass by value or store on heap/entity | `cfg := Config{...}`<br>`wait(f, 1)`<br>`apply_cfg(&cfg)` ❌ |
| **Rule 3** | **Store Composite State in Entities** | `boss.attack_phase = .Burst`<br>`boss.angle += 15` | Local struct arrays or state machines across yields ❌ |

---

## 6. Pattern Cheat Sheet

### ❌ UNSAFE: Stack-Allocated Struct across Yield
```odin
my_coroutine :: proc(f: ^coroutine.Fiber) {
    local_state := My_State{hp = 100, phase = 1}
    coroutine.wait(f, 1.0) // YIELD
    // BUG: If other fibers ran during this 1s, local_state is corrupted!
    fmt.println(local_state.hp)
}
```

### ✅ SAFE Option A: Value Types in VM Registers
```odin
my_coroutine :: proc(f: ^coroutine.Fiber) {
    hp: int = 100
    phase: int = 1
    coroutine.wait(f, 1.0) // YIELD
    // SAFE: hp and phase live in Wasm VM locals; Asyncify restores them.
    fmt.println(hp)
}
```

### ✅ SAFE Option B: Fiber-Owned Temp Arena
```odin
my_coroutine :: proc(f: ^coroutine.Fiber) {
    state := new(My_State, context.temp_allocator)
    state.hp = 100
    coroutine.wait(f, 1.0) // YIELD
    // SAFE: Allocated in f.temp_arena; completely private to this fiber.
    fmt.println(state.hp)
}
```

### ✅ SAFE Option C: Persistent Entity Memory
```odin
my_coroutine :: proc(f: ^coroutine.Fiber, e: ^Enemy) {
    e.hp = 100
    coroutine.wait(f, 1.0) // YIELD
    // SAFE: e lives on heap or global entity array outside the shadow stack.
    fmt.println(e.hp)
}
```
