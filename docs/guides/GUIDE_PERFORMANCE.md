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
