# PLAN5: Centralized Configuration, Static Data Structures (SDS) & Generational Handles

This document establishes the architecture and execution plan for **Centralized Engine Configuration**, **Packed Generational Handles ($O(1)$ Lookups)**, and **Zero-Allocation Synchronization Primitives** across the Odin Coroutine Engine.

---

## 1. Executive Summary & Design Goals

Games and real-time simulations require deterministic execution, zero-allocation steady states, and instant symbol/handle lookups. By integrating the core principles of **Static Data Structures [`sds`](https://github.com/jakubtomsu/sds)**, **Floooh handles**, and **Tiger Style** bounds checking, we will elevate the engine into a truly engine-agnostic, zero-hitch concurrency library.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          PLAN 5 CORE PILLARS                                │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ 1. Centralized Compile-Time #config  │ Consolidate all stack, slab, memory, │
│    & Presets System                  │ canary, and timing tunables into one │
│                                      │ config module with -define overrides │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 2. Packed Generational Handles       │ Transform O(N) handle searches into  │
│    (16-bit Index | 16-bit Gen)       │ single-instruction O(1) direct slot  │
│                                      │ lookups with ABA safety guarantees.  │
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 3. Zero-Allocation Static Waiters    │ Embed fixed [STATIC_WAITERS_CAP]^Fiber│
│    in Sync Primitives                │ in Mutex, Signal, Semaphore, Latch   │
│                                      │ for 0-heap allocation initialization.│
├──────────────────────────────────────┼──────────────────────────────────────┤
│ 4. Engine-Agnostic Usability         │ Retain zero external dependencies,   │
│    & Zero-Hitch Real-Time Semantics  │ full ZII semantics, and pure drop-in │
│                                      │ modularity for Raylib/Sokol/custom.  │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## 2. Pillar 1: Centralized Configuration & Presets (`config.odin`)

Consolidate all engine tunables into a dedicated `config.odin` file using Odin's compile-time `#config` directive. This enables runtime game developers to override any parameter via `-define:KEY=VALUE` without modifying engine source files.

### Configuration Specification
```odin
package coroutine

// ============================================================================
// ENGINE CONFIGURATION & STATIC BOUNDS (PLAN 5)
// ============================================================================

// --- 1. Memory & Stack Sizing ---
STACK_SIZE :: #config(CORO_STACK_SIZE, 32 * 1024)
STACKS_PER_SLAB :: #config(CORO_STACKS_PER_SLAB, 32)
PAYLOAD_SIZE :: #config(CORO_PAYLOAD_SIZE, 128)
TEMP_ARENA_SIZE :: #config(CORO_TEMP_ARENA_SIZE, 4 * 1024)

// --- 2. Safety, Canary & Diagnostics ---
CANARY_SIZE :: #config(CORO_CANARY_SIZE, 64)
CANARY_MAGIC :: 0xDEAD_BEEF_CAFE_BABE
DEFAULT_ALLOC_MODE :: Stack_Allocation_Mode(#config(CORO_ALLOC_MODE, 0)) // 0: Standard_Slab, 1: Virtual_Memory_OS
WATCHDOG_ENABLED :: #config(CORO_WATCHDOG_ENABLED, ODIN_DEBUG)
WATCHDOG_MAX_SLICE_MS :: #config(CORO_WATCHDOG_MAX_SLICE_MS, 100.0)

// --- 3. Clocks & Timers ---
DEFAULT_TICK_RATE_HZ :: #config(CORO_TICK_RATE_HZ, 1000)

// --- 4. Static Capacity Bounds (sds Philosophy) ---
STATIC_WAITERS_CAPACITY :: #config(CORO_STATIC_WAITERS_CAPACITY, 4)
HANDLE_HISTORY_CAPACITY :: #config(CORO_HANDLE_HISTORY_CAPACITY, 2048)
```

### Game Profile Templates
1. **Lightweight 2D / Indie / Mobile**: `CORO_STACK_SIZE=16384`, `CORO_PAYLOAD_SIZE=64`, `CORO_TEMP_ARENA_SIZE=2048`
2. **Standard 3D Action RPG / Bullet Hell (Default)**: `CORO_STACK_SIZE=32768`, `CORO_PAYLOAD_SIZE=128`, `CORO_TEMP_ARENA_SIZE=4096`
3. **High-Density Dedicated Server / Simulation**: `CORO_STACK_SIZE=32768`, `CORO_PAYLOAD_SIZE=256`, `CORO_STACKS_PER_SLAB=64`

---

## 3. Pillar 2: Packed Generational Handles ($O(1)$ Direct Slot Lookups)

### Bitwise Layout
```
┌────────────────────────────────────────────────────────┐
│             FIBER_HANDLE (32-bit Packed)               │
├────────────────────────────┬───────────────────────────┤
│ Slot Index (Bits 0..15)    │ Generation (Bits 16..31)  │
│ Max 65,536 fiber slots     │ Max 65,536 reuse cycles   │
└────────────────────────────┴───────────────────────────┘
```

### Procedural Mechanics
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

### Pool Slot Lifecycle
1. **Allocation**: When a new fiber is created in `fiber_pool_grow`, assign `fiber.pool_index = u16(len(pool.all_fibers))` and `fiber.generation = 1`.
2. **Acquisition**: In `fiber_pool_acquire`, construct `fiber.handle = fiber_handle_pack(fiber.pool_index, fiber.generation)`.
3. **Recycling**: In `fiber_pool_recycle`, increment `fiber.generation += 1` (skipping generation `0` to keep handle `0` sentinel-invalid).
4. **Resolution**: `fiber_find_by_handle` extracts `fiber_handle_index(handle)` and performs direct index lookup into `pool.all_fibers[idx]`, confirming `f.handle == handle && f.status != .Unused` in $O(1)$ time with zero loops!

---

## 4. Pillar 3: Zero-Allocation Synchronization Primitives (`Waiter_List`)

### Unified Embedded Static Waiter Structure
```odin
Waiter_List :: struct {
    static_buf:   [STATIC_WAITERS_CAPACITY]^Fiber,
    count:        int,
    overflow:     [dynamic]^Fiber,
    allocator:    mem.Allocator,
}
```

### Methods
- `waiter_list_init(wl: ^Waiter_List, allocator := context.allocator)`
- `waiter_list_destroy(wl: ^Waiter_List)`: Frees overflow only if allocated; no-op if within static capacity.
- `waiter_list_add(wl: ^Waiter_List, f: ^Fiber)`: Adds to `static_buf` if `count < STATIC_WAITERS_CAPACITY`, else appends to `overflow`.
- `waiter_list_remove(wl: ^Waiter_List, f: ^Fiber) -> bool`: In-place removal.
- `waiter_list_pop_first(wl: ^Waiter_List) -> (^Fiber, bool)`: Pops first waiting fiber.
- `waiter_list_clear(wl: ^Waiter_List)`: Resets count and clears overflow.

### Target Primitives
- `Signal`
- `Fiber_Mutex`
- `Fiber_Semaphore`
- `Fiber_Latch`
- `Cancel_Token`
- `Event(T)`

---

## 5. Implementation Roadmap & Milestones (100% Completed)

- [x] **Step 1: Configuration Centralization**
  - Created `src/coroutine/config.odin`.
  - Wired `#config` constants into `types.odin`, `pool.odin`, and `scheduler.odin`.
- [x] **Step 2: Generational Handle Upgrade**
  - Updated `Fiber` with `pool_index: u16` and `generation: u16`.
  - Updated `fiber_pool_grow`, `fiber_pool_acquire`, and `fiber_pool_recycle`.
  - Refactored `fiber_find_by_handle`, `fiber_is_alive`, `fiber_status`, and `fiber_cancel` to use direct $O(1)$ index lookups with ABA safety.
- [x] **Step 3: Intrusive Waiter Queues in Synchronization Primitives (OS Kernel / Futex Pattern)**
  - Replaced array/overflow hybrid with doubly-linked intrusive `Wait_Queue` (`next_waiter`, `prev_waiter` inside `Fiber`).
  - Refactored `Signal`, `Fiber_Mutex`, `Fiber_Semaphore`, `Fiber_Latch`, `Cancel_Token`, `Event(T)`, and `Channel(T)` for 100% zero heap allocations, unbounded capacity, and True ZII.
- [x] **Step 4: Comprehensive Test Suite Expansion**
  - Added unit tests 139–143 verifying packed handle bit extraction, slot reuse safety, $O(1)$ lookup guarantees under high fiber loads, and intrusive `Wait_Queue` operations.
  - Test runner verified with **143 / 143 unit tests passing** (`.\build.ps1 test`).
  - Benchmark suite verified with **6 / 6 passing benchmarks** (`.\build.ps1 run-bench`).
- [x] **Step 5: Documentation & Changelog Refresh**
  - Updated `ARCHITECTURE.md`, `TECH_MEMORY.md`, `TECH_PRIMITIVES.md`, `README.md`, and `CHANGELOG.md`.

---
