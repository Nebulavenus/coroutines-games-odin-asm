# Memory Architecture & Multi-Tier Safety (`TECH_MEMORY.md`)

This document details the slab allocation strategy, 3-tier stack overflow protection mechanisms, per-fiber isolated temporary allocators, and 128-byte inline payload semantics in the **Odin Stackful Coroutine Engine**.

---

## 1. Slab Allocation & Stack Pooling Strategy

Dynamic memory allocation (`new` / `malloc`) per fiber creation introduces OS syscall overhead, heap fragmentation, and allocator thread contention. The engine implements a fixed-size slab allocator with $O(1)$ stack recycling.

```
                      1 MB Master Slab Block
┌──────────────┬──────────────┬──────────────┬───┄┄───┬──────────────┐
│  Stack 0     │  Stack 1     │  Stack 2     │        │  Stack 31    │
│  (32 KB)     │  (32 KB)     │  (32 KB)     │        │  (32 KB)     │
└──────────────┴──────────────┴──────────────┴───┄┄───┴──────────────┘
       │              │
       ▼              ▼
 [Free List] ──► [Free List] ──► [O(1) Pop to Active Fiber]
```

### Memory Slab Invariants:
- **Default Stack Size:** 32 KB per fiber (customizable from 16 KB up to 1 MB+).
- **Stacks Per Slab:** 32 stacks per 1 MB contiguous memory block.
- **Free-List Recycling:** When a fiber finishes or is aborted, its stack index is pushed back onto the free-list in $O(1)$ time. Zero OS calls during standard gameplay loops.
- **Cache Locality:** Adjacent stacks reside within contiguous 1 MB virtual address ranges, maximizing L2/L3 CPU cache efficiency.

---

## 2. Detailed Memory Layout of `Fiber`

Each `Fiber` struct is a self-contained descriptor containing execution state, coordination pointers, memory arenas, and inline payload storage:

```
┌─────────────────────────────────────────────────────────────┐
│                        Fiber Struct                         │
├────────────────────────────────┬────────────────────────────┤
│ id: Fiber_ID                   │ Unique integer identifier  │
│ state: Fiber_State             │ Running, Ready, Sleeping...│
│ stack_base: rawptr             │ Top address of stack memory│
│ stack_limit: rawptr            │ Bottom overflow limit      │
│ saved_rsp: rawptr              │ CPU stack pointer at yield │
│ user_entry: proc(f: ^Fiber)    │ Entry procedure pointer    │
├────────────────────────────────┼────────────────────────────┤
│ parent: ^Fiber                 │ Hierarchical parent pointer│
│ first_child: ^Fiber            │ Head of active child list  │
│ sibling_next: ^Fiber           │ Intrusive sibling link     │
│ join_coord: Join_Coordinator   │ Concurrency coordinator    │
├────────────────────────────────┼────────────────────────────┤
│ temp_arena: mem.Arena          │ Embedded 4KB Arena struct  │
│ temp_buffer: [4096]u8          │ Isolated temp allocator mem│
├────────────────────────────────┼────────────────────────────┤
│ payload: [128]u8               │ Inline by-value copy buffer│
├────────────────────────────────┼────────────────────────────┤
│ wake_time: f64                 │ Absolute simulation wake   │
│ real_wake_time: f64            │ Absolute real-clock wake   │
│ heap_index: int                │ Cached index in timer_heap │
│ real_heap_index: int           │ Cached in real_timer_heap  │
└────────────────────────────────┴────────────────────────────┘
```

---

## 3. Multi-Tiered Safety Invariants

Stack overflows in native stackful coroutines are notoriously catastrophic if undetected. The engine provides a 3-tier defense-in-depth safety system:

```
 High Address (Base)
┌──────────────────────────────────────────────┐
│ Watermark Canary (0xDEAD_BEEF_CAFE_BABE)     │ ◄── Tier 1: Software Canary
├──────────────────────────────────────────────┤
│ 0xAA Watermark Pattern Fill                  │ ◄── Tier 2: Stack Usage Profiler
│ (Scanned by fiber_calc_stack_usage)          │
├──────────────────────────────────────────────┤
│ Active Call Stack & Local Variables          │
│ ▼ (Grows Downward)                           │
├──────────────────────────────────────────────┤
│ OS Guard Page (PAGE_GUARD / PROT_NONE)       │ ◄── Tier 3: Hardware Trap
└──────────────────────────────────────────────┘
 Low Address (Limit)
```

### Tier 1: Software Watermark Canaries
- At `stack_base - 64` and `stack_limit`, a 64-byte magic pattern (`0xDEAD_BEEF_CAFE_BABE`) is inscribed during stack initialization.
- Every context switch and yield asserts that the canary words remain uncorrupted. If a coroutine exceeds its stack, the canary violation is trapped immediately with an informative assertion error.

### Tier 2: Stack High-Water Profiling
- On fiber creation or recycling, unused stack memory is initialized with the `0xAA` byte pattern.
- `fiber_calc_stack_usage(f)` scans the stack memory from `stack_limit` upwards until the first non-`0xAA` byte is found:
  ```odin
  fiber_calc_stack_usage :: proc(f: ^Fiber) -> (used_bytes: int, total_bytes: int, pct: f32) {
      total_bytes = int(uintptr(f.stack_base) - uintptr(f.stack_limit))
      ptr := cast([^]u8)f.stack_limit
      unused := 0
      for i := 0; i < total_bytes; i += 1 {
          if ptr[i] != 0xAA do break
          unused += 1
      }
      used_bytes = total_bytes - unused
      pct = (f32(used_bytes) / f32(total_bytes)) * 100.0
      return
  }
  ```
- Returns exact stack usage in bytes and percentage (e.g. `2,140 / 32,768 bytes (6.5%)`), rendered live in the F1 hierarchy debugger.

### Tier 3: Hardware OS Virtual Memory Protection (`Virtual_Memory_OS`)
- Configured via `Stack_Allocation_Mode.Virtual_Memory_OS`.
- On Windows: Uses `VirtualAlloc` with `PAGE_GUARD` on the boundary page.
- On Linux / POSIX: Uses `mmap` with `mprotect(PROT_NONE)`.
- If a deep recursion touches the guard page, the CPU hardware memory management unit (MMU) raises a page fault exception instantly, preventing silent memory corruption of adjacent fibers.

---

## 4. Per-Fiber Isolated Temporary Allocator (`context.temp_allocator`)

In standard Odin programs, `context.temp_allocator` is typically a global ring buffer reset at the end of the frame. In a coroutine engine, multiple fibers yielding across frames would overwrite each other's temporary memory.

### Solution: Embedded 4KB Per-Fiber Arena
- Every `Fiber` contains an embedded 4KB `mem.Arena` buffer (`temp_arena`).
- When a fiber is activated during context switch, `context.temp_allocator` is bound to the fiber's isolated arena.
- Temporary allocations created within a fiber survive across multiple `yield_frame`, `wait`, or `sync` suspensions.
- When the fiber completes, the arena is reset in $O(1)$ time without fragmentation.

---

## 5. Inline 128-Byte By-Value Payload Storage

Passing parameters to spawned coroutines often creates a dilemma:
- **By Pointer (`spawn_ptr`):** Requires the caller's stack frame or entity to outlive the coroutine. If the caller was a short-lived procedure, the pointer dangles.
- **Dynamic Heap Allocation (`new(T)`):** Incurs heap allocation and deallocation overhead.

### The 128-Byte Inline Buffer (`spawn_val`)
Every `Fiber` structure contains an embedded 128-byte raw buffer:
```odin
FIBER_PAYLOAD_SIZE :: 128
payload: [FIBER_PAYLOAD_SIZE]u8
```

- When calling `spawn_val(sched, proc(f, val), my_struct)`:
  1. Compile-time `#assert(size_of(T) <= FIBER_PAYLOAD_SIZE)` ensures payload fits.
  2. The argument is copied directly into `fiber.payload`.
  3. The fiber procedure receives a safe, internal pointer `cast(^T)&f.payload[0]`.
  4. Zero heap allocations; 100% immune to caller stack invalidation.
