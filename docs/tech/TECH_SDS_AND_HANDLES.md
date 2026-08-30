# Technical Manual: Static Data Structures, Zero Is Initialization & Generational Handles

This document details the architectural principles, memory layouts, and data flow mechanisms governing **Static Data Structures (`sds`)**, **True Zero Is Initialization (ZII)**, **Packed Generational Handles ($O(1)$ Lookups)**, and **Intrusive Waiter Queues (OS Kernel / Futex Pattern)** in the Odin Stackful Coroutine Engine.

---

## 1. The Ideology of Static Data Structures (`sds`) & Tiger Style in Games

In real-time game engines, physics simulators, and high-frequency network servers, dynamic heap allocations (`malloc`, `new`, `[dynamic]T` reallocations) introduce three critical problems:
1. **Frame Stutter & Latency Spikes**: Amortized $O(1)$ operations hide occasional $O(N)$ allocations and memory copying, causing micro-hitches during gameplay spikes (e.g., boss transitions, particle bursts).
2. **Memory Fragmentation**: Dynamic allocations scatter memory blocks across the address space, degrading CPU L1/L2 data cache hit rates and increasing page table pressure.
3. **Non-Deterministic Failures**: Heap exhaustions or allocation panics can occur unpredictably under high concurrency load.

### Core SDS & Tiger Style Invariants in this Engine:
- **Zero Runtime Allocations in Steady-State**: Once initialized, neither the scheduler, timers, combinators, nor synchronization primitives allocate or free dynamic heap memory.
- **Bounded Worst-Case Memory**: Every memory structure has an explicit, compile-time configurable bound (via `config.odin` and `-define:KEY=VALUE`).
- **Cache-Coherent Preallocation**: Fibers, stacks, and handles reside in contiguous slabs and fixed arrays, maximizing cache line utilization.
- **Deep-Copy Snapshotability**: All scheduler state (except raw stack pointers) is flat and contiguous, simplifying state serialization, rollback netcode, and replays.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          CORE ARCHITECTURAL PILLARS                         │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ 1. Centralized Compile-Time #config  │ All stack sizes, slab counts, canary │
│    & Presets System                  │ buffers, and tick frequencies in one │
│                                      │ config module with -define overrides │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 2. Packed Generational Handles       │ 32-bit packed integer (16-bit slot,  │
│    (16-bit Index | 16-bit Gen)       │ 16-bit gen) delivering O(1) single-  │
│                                      │ instruction lookups with ABA safety. │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 3. Intrusive Waiter Queues           │ Doubly-linked intrusive pointers     │
│    (OS Kernel / Futex Pattern)       │ embedded in Fiber (next/prev_waiter) │
│                                      │ achieving 100% zero-alloc sync.      │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 4. True Zero Is Initialization (ZII) │ Default zeroed structs (Mutex, Sig,  │
│                                      │ Latch, Token) are immediately valid. │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## 2. Packed Generational Handles ($O(1)$ Direct Slot Resolution)

### 2.1 The Problem with Linear Scans & Bare Pointers
Using raw pointers (`^Fiber`) across long-lived systems or asynchronous jobs risks **use-after-free** crashes if a fiber finishes and its slab memory is reused. Conversely, traditional generational handle tables often required linear searches ($O(N)$) or auxiliary sparse lookup maps.

### 2.2 32-Bit Bitwise Packed Layout
The engine packs both the pool slot index and the generational lifecycle counter into a compact, distinct 32-bit integer:

```
 31                          16 15                           0
┌──────────────────────────────┬──────────────────────────────┐
│     Generation Counter       │       Pool Slot Index        │
│          (16 bits)           │          (16 bits)           │
│   Range: 1 .. 65,535         │    Range: 0 .. 65,535 slots  │
└──────────────────────────────┴──────────────────────────────┘
```

### 2.3 Bitwise Operations
All packing and unpacking procedures are declared `#force_inline proc "contextless"` with zero function call overhead:

```odin
Fiber_Handle :: distinct u32

#force_inline fiber_handle_pack :: proc "contextless" (index: u16, gen: u16) -> Fiber_Handle {
    return Fiber_Handle(u32(index) | (u32(gen) << 16))
}

#force_inline fiber_handle_index :: proc "contextless" (h: Fiber_Handle) -> u16 {
    return u16(u32(h) & 0xFFFF)
}

#force_inline fiber_handle_gen :: proc "contextless" (h: Fiber_Handle) -> u16 {
    return u16((u32(h) >> 16) & 0xFFFF)
}
```

### 2.4 $O(1)$ Single-Instruction Slot Lookup
To look up, validate, or cancel a fiber by its handle:
1. Extract the 16-bit slot index: `idx := int(fiber_handle_index(handle))`.
2. Perform direct bounds-checked array indexing into the pool: `f := pool.all_fibers[idx]`.
3. Verify that `f.handle == handle && f.status != .Unused`.

```odin
fiber_find_by_handle :: proc(sched: ^Scheduler, handle: Fiber_Handle) -> ^Fiber {
    if sched == nil || handle == 0 do return nil
    pool := &sched.fiber_pool
    idx := int(fiber_handle_index(handle))
    if idx < len(pool.all_fibers) {
        f := pool.all_fibers[idx]
        if f != nil && f.handle == handle && f.status != .Unused {
            return f
        }
    }
    return nil
}
```

### 2.5 ABA Safety & Lifecycle Wraparound
- **Allocation**: When a fiber is preallocated, it is assigned its permanent array index (`fiber.pool_index`) and initialized with `generation = 1`.
- **Acquisition**: `fiber.handle = fiber_handle_pack(fiber.pool_index, fiber.generation)`.
- **Recycling**: When a fiber completes, `fiber_pool_recycle` increments `fiber.generation += 1`. If `generation == 0` (overflow at $2^{16}$ recycles), it wraps to `1` (keeping `0` as an invalid sentinel).
- **Result**: Any old handle held by gameplay scripts or timers immediately fails handle validation in $O(1)$ time, guaranteeing absolute use-after-free and ABA safety.

---

## 3. Intrusive Waiter Queues (OS Kernel / Futex Pattern)

### 3.1 The Limitations of Array & Slice Waiters
Traditional synchronization designs store waiting fibers in dynamic slices (`[dynamic]^Fiber`) or fixed arrays (`[4]^Fiber` with overflow fallback):
- Dynamic slices require heap allocations (`append`, `make`, `delete`).
- Fixed arrays impose arbitrary capacity limits or allocate dynamic fallback memory under contention.

### 3.2 Doubly-Linked Intrusive Wait Queue Architecture
Borrowing the battle-tested architecture of operating system kernels (Linux futex wait queues, Windows dispatcher objects, FreeRTOS event queues), our engine embeds the queue link pointers directly inside the `Fiber` struct:

```odin
// Inside Fiber struct (src/coroutine/types.odin):
Fiber :: struct {
    // ...
    next_waiter:    ^Fiber, // Intrusive pointer to next waiting fiber
    prev_waiter:    ^Fiber, // Intrusive pointer to previous waiting fiber
    // ...
}

// Compact Wait_Queue header (only 16 bytes!):
Wait_Queue :: struct {
    head: ^Fiber,
    tail: ^Fiber,
}
```

```
                          INTRUSIVE WAIT QUEUE TOPOLOGY
  [ Wait_Queue Header ]
   • head: ──────► [ Fiber A ] (in pool)
   • tail: ──┐      • next_waiter ──────► [ Fiber B ] (in pool)
             │      • prev_waiter = nil    • next_waiter = nil
             │                             • prev_waiter ───────┐
             └─────────────────────────────▲                    │
                                           └────────────────────┘
```

### 3.3 Intrusive Queue Operations

| Operation | Procedure | Complexity | Mechanics |
| :--- | :--- | :---: | :--- |
| **Push Tail** | `wait_queue_push_back(q, f)` | $O(1)$ | Appends `f` to `q.tail`, updates pointers. |
| **Pop Head** | `wait_queue_pop_front(q)` | $O(1)$ | Pops `q.head`, advances head, clears neighbor links. |
| **In-Place Removal**| `wait_queue_remove(q, f)` | $O(1)$ | Unlinks `f` from `prev_waiter` and `next_waiter` in-place. |
| **Count** | `wait_queue_count(q)` | $O(N_{\text{waiters}})$ | Iterates over active chain without memory accesses outside cache. |
| **Empty Check** | `wait_queue_is_empty(q)` | $O(1)$ | `return q.head == nil`. |

### 3.4 $O(1)$ In-Place Unlinking in Action
When a fiber unregisters from a multi-channel select (`chan_select_recv`), times out (`chan_recv_timeout`, `wait_until_timeout`), or is cancelled by a sibling race (`race`, `rush`), it unlinks itself from any wait queue instantly without searching:

```odin
wait_queue_remove :: proc(q: ^Wait_Queue, f: ^Fiber) -> bool {
    if q == nil || f == nil do return false

    if f.prev_waiter != nil {
        f.prev_waiter.next_waiter = f.next_waiter
    } else if q.head == f {
        q.head = f.next_waiter
    }

    if f.next_waiter != nil {
        f.next_waiter.prev_waiter = f.prev_waiter
    } else if q.tail == f {
        q.tail = f.prev_waiter
    }

    f.next_waiter = nil
    f.prev_waiter = nil
    return true
}
```

---

## 4. True Zero Is Initialization (ZII)

In Odin, uninitialized or `{}` zero-initialized memory is guaranteed to have all bytes set to `0`. Because `Wait_Queue` consists of two `nil` pointers (`head = nil, tail = nil`), all synchronization primitives achieve **True Zero Is Initialization**:

```odin
// Immediately valid — no signal_init(&sig) required!
sig: coroutine.Signal
coroutine.signal_wait(f, &sig)

// Immediately valid — no mutex_init(&m) required!
m: coroutine.Fiber_Mutex
coroutine.mutex_lock(f, &m)

// Immediately valid — countdown latch ready on declaration!
latch := coroutine.Fiber_Latch{count = 3}
coroutine.latch_wait(f, &latch)

// Immediately valid — cancellation token ready on declaration!
tok: coroutine.Cancel_Token
coroutine.cancel_token_wait(f, &tok)
```

### Memory Footprint of Synchronization Primitives:
| Primitive | Internal Fields | Size (64-bit) | Zero-Allocation? | ZII Ready? |
| :--- | :--- | :---: | :---: | :---: |
| `Signal` | `waiters: Wait_Queue` | **16 bytes** | **Yes (100%)** | **Yes** |
| `Fiber_Mutex` | `locked: bool, waiters: Wait_Queue` | **24 bytes** | **Yes (100%)** | **Yes** |
| `Fiber_Latch` | `count: int, waiters: Wait_Queue` | **24 bytes** | **Yes (100%)** | **Yes** |
| `Cancel_Token` | `is_cancelled: bool, waiters: Wait_Queue` | **24 bytes** | **Yes (100%)** | **Yes** |
| `Fiber_Semaphore`| `permits: int, max_permits: int, waiters: Wait_Queue` | **32 bytes** | **Yes (100%)** | **Yes** |

---

## 5. Centralized Configuration Architecture (`config.odin`)

All engine limits, stack sizes, memory thresholds, and tick rates are consolidated in `src/coroutine/config.odin` using Odin's `#config` directive:

```odin
package coroutine

// --- 1. Memory & Stack Sizing ---
STACK_SIZE :: #config(CORO_STACK_SIZE, 32 * 1024)
STACKS_PER_SLAB :: #config(CORO_STACKS_PER_SLAB, 32)
PAYLOAD_SIZE :: #config(CORO_PAYLOAD_SIZE, 128)
TEMP_ARENA_SIZE :: #config(CORO_TEMP_ARENA_SIZE, 4 * 1024)

// --- 2. Safety, Canary & Diagnostics ---
CANARY_SIZE :: #config(CORO_CANARY_SIZE, 64)
CANARY_MAGIC :: #config(CORO_CANARY_MAGIC, 0xDEAD_BEEF_CAFE_BABE)
DEFAULT_ALLOC_MODE_INT :: #config(CORO_ALLOC_MODE, 0)
WATCHDOG_ENABLED :: #config(CORO_WATCHDOG_ENABLED, ODIN_DEBUG)
WATCHDOG_MAX_SLICE_MS :: #config(CORO_WATCHDOG_MAX_SLICE_MS, 100.0)

// --- 3. Clocks & Timers ---
DEFAULT_TICK_RATE_HZ :: #config(CORO_TICK_RATE_HZ, 1000)

// --- 4. Static Capacity Bounds ---
HANDLE_HISTORY_CAPACITY :: #config(CORO_HANDLE_HISTORY_CAPACITY, 2048)
```

### Build-Time Profile Presets

#### Profile A: Lightweight 2D / Indie Game / Mobile
```bash
odin build . -define:CORO_STACK_SIZE=16384 -define:CORO_PAYLOAD_SIZE=64 -define:CORO_TEMP_ARENA_SIZE=2048
```
*Reduces RAM footprint by 50% for memory-constrained platforms.*

#### Profile B: Standard 3D Action RPG / Bullet Hell (Default)
```bash
odin build .
```
*32 KB stack per fiber, 128 B inline payload, 4 KB per-fiber temporary arena.*

#### Profile C: High-Density Simulation / Dedicated Server
```bash
odin build . -define:CORO_STACK_SIZE=32768 -define:CORO_PAYLOAD_SIZE=256 -define:CORO_STACKS_PER_SLAB=64
```
*Accommodates 100,000+ active fibers with minimal slab allocation overhead.*

---

## 6. Performance Benchmarks & Comparison

```
================================================================================
           ODIN STACKFUL COROUTINE ENGINE — PERFORMANCE BENCHMARKS               
================================================================================

[BENCH 1] Raw ASM Context Switch   : 15.61 ns / switch (64.1M switches/sec) [PASS]
[BENCH 2] 10,000 Concurrent Fibers : 5.12 ms / 10k frame step (51.20 ms total) [PASS]
[BENCH 3] 10,000 Timer Min-Heap     : 49.96 ms total (O(log N) min-heap) [PASS]
[BENCH 4] CSP Channel Streaming     : 87.8 M msgs / sec (1M integers streamed) [PASS]
[BENCH 5] Structured Tree Churn     : 24.83 us / sync tree (248.30 ms for 10k) [PASS]
[BENCH 6] Headless Sim Fast-Forward : 32274x faster than real-time (60s in 1.9ms) [PASS]

================================================================================
ALL 6 BENCHMARKS COMPLETED WITH ZERO RUNTIME ALLOCATIONS IN STEADY-STATE.
================================================================================
```

---

## 7. Summary of Key Developer Guidelines

1. **Rely on ZII**: Declare synchronization primitives directly in your gameplay structs without boilerplate init procedures.
2. **Pass Handles Across Systems**: Use `Fiber_Handle` (32-bit value) instead of raw `^Fiber` pointers for persistent task references.
3. **Customize Tunables via `-define`**: Override stack and payload sizes in your build script (`build.ps1` or `build.bat`) rather than modifying engine source files.
4. **Leverage Zero-Allocation CSP**: Use `Channel(T)` and `chan_select_recv` for high-throughput messaging without garbage collection overhead.
