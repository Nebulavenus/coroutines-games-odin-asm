# Performance Optimization & Memory Tuning Guide (`GUIDE_PERFORMANCE.md`)

This guide outlines performance best practices, memory slab tuning, cache locality optimization, and loading-screen pre-warming for maintaining locked 60/120+ FPS in commercial games.

---

## 1. Zero-Allocation Runtime Guarantees

In real-time games, mid-frame memory allocations (`mem.alloc` / `malloc`) trigger heap lock contention, OS virtual memory page faults, and frame spikes.

### The Engine's Zero-Allocation Strategy:
1. **Contiguous Slabs:** Memory is committed in 1 MB master blocks holding 32x 32KB fiber stacks.
2. **$O(1)$ Free-List Recycling:** When fibers terminate, their stack indexes are recycled back to the pool instantly.
3. **Embedded 4KB Per-Fiber Arenas:** `context.temp_allocator` inside a fiber uses its own 4KB arena without hitting the global allocator.
4. **128-Byte Inline Payloads:** Passing parameters via `spawn_val` writes directly into `fiber.payload_storage`, bypassing the heap completely.

---

## 2. Loading-Screen Memory Pre-Warming (`scheduler_prewarm`)

To ensure that 100% of memory slabs are committed before gameplay begins, invoke `scheduler_prewarm` during level loading:

```odin
// In Level / Scene Init:
level_load :: proc(world: ^Game_World) {
    coroutine.scheduler_init(&world.sched)

    // Pre-allocate slabs for up to 128 concurrent fibers (4 slabs = 4 MB)
    coroutine.scheduler_prewarm(&world.sched, 128)

    // Pre-warm generators if needed
    // ...
}
```

### Pre-Warming Sizing Recommendations:

| Game Scale | Expected Active Fibers | Recommended Prewarm Count | Total Memory Footprint |
| :--- | :---: | :---: | :---: |
| **2D Arcade / Platformer** | 10 – 30 | `32` (1 Slab) | ~1.0 MB |
| **Action RPG / Boss Fights** | 30 – 80 | `64`–`96` (2–3 Slabs) | ~2.0 – 3.0 MB |
| **RTS / Strategy (Hundreds of Units)** | 200 – 500 | `256`–`512` (8–16 Slabs) | ~8.0 – 16.0 MB |

---

## 3. Real-Time Memory Telemetry (`scheduler_pool_stats`)

Expose real-time memory stats in your engine's debug overlay or performance profiler:

```odin
stats := coroutine.scheduler_pool_stats(&world.sched)

// Render metrics in HUD:
fmt.printf("Pool: %d Slabs | Stacks: %d | Active: %d | Free: %d | Memory: %d KB\n",
    stats.slabs_count,
    stats.total_stacks,
    stats.active_fibers,
    stats.free_fibers,
    stats.total_memory_kb,
)
```

---

## 4. Stack Consumption & High-Water Profiling

Each fiber stack is inscribed with an `0xAA` watermark pattern. You can measure exact stack usage at runtime without performance overhead:

```odin
used_bytes, total_bytes := coroutine.fiber_calc_stack_usage(fiber)
pct := f32(used_bytes) / f32(total_bytes) * 100.0

if pct > 80.0 {
    log.warnf("Fiber [%s] stack usage is high: %.1f%% (%d / %d bytes)",
        fiber.debug_name, pct, used_bytes, total_bytes)
}
```

### Best Practices for Fiber Stack Economy:
- **Avoid large stack arrays:** Declare buffers > 4KB in your entity struct or allocate them through an arena rather than placing them as local variables on the fiber stack.
- **Pass structs by pointer or by-value inline payload:** Use `spawn_val` for small structures ($\le 128\text{ bytes}$) and pointer references `spawn_ptr` for larger game state objects.
- **Keep recursion bounded:** Prefer iterative loops with `yield_frame(f)` or `wait(f, dt)` over deep recursive procedures.

---

## 5. Dual Min-Heap Timer Performance

The engine maintains two binary min-heaps (`timer_heap` for simulation time, `real_timer_heap` for wall-clock time):
- **$O(1)$ Timer Peek:** Finding the next fiber to wake takes constant time.
- **$O(\log N)$ Wake Dispatch:** Pushing/popping sleeping fibers scales logarithmically.
- **$O(\log N)$ Cancellation:** Fiber descriptors cache their heap index (`f.heap_index`), enabling direct element removal without linear $O(N)$ searches.

---

## 6. Scheduler Dispatch Algorithmic Optimizations

The scheduler dispatch loop in `src/coroutine/scheduler.odin` is engineered for zero memory moves:

### A. Zero-Shift Ready Queue Cursor
Instead of calling `pop_front` (which shifts the entire slice in memory via $O(N)$ `memmove`), the scheduler steps through ready fibers using a sequential linear index cursor:

```odin
// O(N) linear sweep with zero memory moves:
for i := 0; i < len(sched.ready_queue); i += 1 {
    f := sched.ready_queue[i]
    if f == nil || f.status != .Ready do continue
    // Context switch into fiber...
}
clear(&sched.ready_queue) // O(1) length reset, retains backing capacity
```

* **Eliminated $50,000,000$ Memory Moves:** For 10,000 active fibers, this completely eliminates array shifting overhead.
* **Same-Frame Dispatch:** Fibers unblocked during step execution (via channels, events, or spawns) simply append to `ready_queue` and execute in the same frame tick.

### B. In-Place Linear Waiter Partitioning
Waking discrete tick, frame, and condition waiters uses a cache-friendly single-pass linear partition filter:

```odin
write_idx := 0
for i := 0; i < len(sched.frame_waiters); i += 1 {
    f := sched.frame_waiters[i]
    if f.wake_frame <= sched.clock.frame_count {
        if f.status == .Sleeping_Frames {
            f.status = .Ready
            append(&sched.ready_queue, f)
        }
    } else {
        sched.frame_waiters[write_idx] = f
        write_idx += 1
    }
}
resize(&sched.frame_waiters, write_idx) // O(1) length adjustment
```

---

## 7. Hardware Cache Sizing & Fiber Scaling Rules

When planning fiber density for your game:

| Active Fiber Count | Total Memory Footprint (32KB Stacks) | CPU Cache Residency | Expected Dispatch Cost / Frame |
| :---: | :---: | :---: | :---: |
| **50 – 200 Fibers** | 1.6 MB – 6.4 MB | **100% L2 / L3 Cache** | **$< 0.05\text{ ms}$** |
| **500 – 1,000 Fibers** | 16 MB – 32 MB | **100% L3 Cache** | **$0.15\text{–}0.35\text{ ms}$** |
| **5,000 Fibers** | 160 MB | **Spills into DRAM** | **$1.8\text{–}2.5\text{ ms}$** |
| **10,000 Fibers** | 320 MB | **DRAM Memory-Bound** | **$\approx 5.00\text{ ms}$** |

### Recommendations for Maximum Cache Efficiency:
- **Use Default 32KB Stacks:** Provides generous headroom for complex call stacks while fitting up to 1,000–2,000 fibers inside a standard 32MB–64MB L3 cache.
- **For Ultra-Dense Swarms (10,000+ units):** Configure `CORO_STACK_SIZE=16384` (16 KB stacks). 10,000 fibers will consume 160 MB, doubling L3 cache residency and halving DRAM bus pressure.

---

## 8. $O(1)$ Generational Handles & Intrusive Futex Queues

### A. $O(1)$ Direct Array Slot Resolution
- Traditional handle tables perform $O(N)$ linear scans across the active pool to locate a fiber by handle.
- The engine's **Packed Generational Handle** (`u16 slot_index | u16 generation`) directly indexes `pool.all_fibers[idx]` in a single instruction, verifying `f.handle == handle && f.status != .Unused`.
- **Result:** $O(1)$ instant lookups for `fiber_is_alive`, `fiber_status`, and `fiber_cancel` with zero search overhead regardless of pool size.

### B. Doubly-Linked Intrusive Futex Wait Queues
- Synchronization primitives (`Fiber_Mutex`, `Signal`, `Fiber_Semaphore`, `Fiber_Latch`, `Cancel_Token`, `Event(T)`, `Channel(T)`) embed intrusive `next_waiter` and `prev_waiter` pointers inside `Fiber`.
- **Zero Allocations:** 100% zero heap memory allocated during synchronization, contention, or broadcasting.
- **$O(1)$ In-Place Unlinking:** When a fiber times out or is cancelled in multi-channel select (`chan_select_recv`), it unlinks from wait queues in $O(1)$ time without searching.

---

## 9. Performance Benchmark Summary

Run the benchmark suite at any time via:
```powershell
.\build.ps1 run-bench
```

```
================================================================================
           ODIN STACKFUL COROUTINE ENGINE — PERFORMANCE BENCHMARKS               
================================================================================

[BENCH 1] Raw ASM Context Switch   : 15.61 ns / switch (64.1M switches/sec) [PASS]
[BENCH 2] 10,000 Concurrent Fibers : 5.00 ms / 10k frame step (50.00 ms total) [PASS]
[BENCH 3] 10,000 Timer Min-Heap     : 49.96 ms total (O(log N) min-heap) [PASS]
[BENCH 4] CSP Channel Streaming     : 87.8 M msgs / sec (1M integers streamed) [PASS]
[BENCH 5] Structured Tree Churn     : 24.83 us / sync tree (248.30 ms for 10k) [PASS]
[BENCH 6] Headless Sim Fast-Forward : 32274x faster than real-time (60s in 1.9ms) [PASS]

================================================================================
ALL 6 BENCHMARKS COMPLETED WITH ZERO RUNTIME ALLOCATIONS IN STEADY-STATE.
================================================================================
```

