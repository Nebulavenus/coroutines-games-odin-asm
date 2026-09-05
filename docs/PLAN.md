Here are the most impactful **architectural recommendations, feature designs, and design decisions** you can take to evolve this engine into an industry-grade gameplay concurrency framework.

---

## 1. Memory Safety: Per-Fiber Temporary Allocator Isolation

### The Problem
In Odin, `context.temp_allocator` uses a thread-local ring buffer. If Fiber A does:
```odin
tmp := make([]f32, 100, context.temp_allocator)
coroutine.wait(f, 1.0)
// Fiber A wakes up next frame...
use_tmp(tmp) // BUG: Another fiber or game frame might have reset temp_allocator!
```
Temporary allocations across yield points will be corrupted if any other fiber calls `free_all(context.temp_allocator)`.

### The Solution: Embedded 4KB/8KB Arena per Fiber
Embed a small memory arena directly in the `Fiber` struct, and point `fiber.stored_context.temp_allocator` to it.

```odin
// Inside Fiber struct
Fiber :: struct {
    // ...
    temp_arena:       mem.Arena,
    temp_arena_buffer: [4 * 1024]byte, // 4KB private scratchpad per fiber
}

// In fiber_pool_acquire:
mem.arena_init(&fiber.temp_arena, fiber.temp_arena_buffer[:])
fiber.stored_context.temp_allocator = mem.arena_allocator(&fiber.temp_arena)

// In fiber_pool_recycle:
mem.arena_free_all(&fiber.temp_arena)
```
**Why do this?**
- Complete isolation: Every fiber can use `context.temp_allocator` freely with zero fear of cross-coroutine contamination.
- Fast, cache-local, and automatically wiped when the fiber finishes or recycles.

---

## 2. Higher-Level Concurrency Primitives

Because you have rock-solid `sync` and `race` primitives, you can build powerful gameplay helpers on top with very little code:

### A. `with_timeout` (Auto-Cancelling Operations)
Wraps any task with a maximum time limit using `race`.

```odin
with_timeout :: proc(f: ^Fiber, seconds: f32, task: Branch_Desc) -> (timed_out: bool) {
    Timeout_Data :: struct {
        seconds: f32,
    }
    
    timeout_proc :: proc(f: ^Fiber, user_data: rawptr) {
        td := (^Timeout_Data)(user_data)
        wait(f, td.seconds)
    }

    tdata := Timeout_Data{seconds}
    winner := race(f,
        task,
        Branch_Desc{entry_proc = timeout_proc, user_data = &tdata, name = "Timeout"},
    )
    return winner == 1 // Index 1 is the timer
}

// Usage in gameplay:
if with_timeout(f, 5.0, branch(dialogue_sequence, player)) {
    fmt.println("Player took too long to respond!")
}
```

### B. Signals & Event Broadcasts (Zero-Polling Event Triggers)
Instead of `wait_until` (which polls every frame), create a `Signal` that suspends a fiber until a specific game event occurs.

```odin
Signal :: struct {
    waiters: [dynamic]^Fiber,
}

signal_wait :: proc(f: ^Fiber, sig: ^Signal) {
    append(&sig.waiters, f)
    f.status = .Suspended_Join
    // Yield to scheduler...
}

signal_emit :: proc(sched: ^Scheduler, sig: ^Signal) {
    for f in sig.waiters {
        f.status = .Ready
        append(&sched.ready_queue, f)
    }
    clear(&sig.waiters)
}

// Usage:
// In Fiber: signal_wait(f, &player.on_damaged_signal)
// In Game:   signal_emit(&game.sched, &player.on_damaged_signal)
```

### C. Fiber Mutex / Lock (Resource Contention)
When two enemies try to reserve the same cover point or interact with the same NPC, OS mutexes block the game thread. A **Fiber Mutex** suspends only the calling fiber:

```odin
Fiber_Mutex :: struct {
    locked:  bool,
    waiters: [dynamic]^Fiber,
}

fiber_mutex_lock :: proc(f: ^Fiber, m: ^Fiber_Mutex) {
    if !m.locked {
        m.locked = true
        return
    }
    // Already locked: suspend this fiber and queue it
    append(&m.waiters, f)
    f.status = .Suspended_Join
    fiber_context_switch(&f.saved_sp, f.sched.scheduler_sp)
}

fiber_mutex_unlock :: proc(sched: ^Scheduler, m: ^Fiber_Mutex) {
    if len(m.waiters) > 0 {
        next_fiber := pop_front(&m.waiters)
        next_fiber.status = .Ready
        append(&sched.ready_queue, next_fiber)
    } else {
        m.locked = false
    }
}
```

---

## 3. Real-Time Stack Watermarking & Diagnostics

Since fibers use fixed stacks (32KB), knowing **exact stack consumption** in development avoids guesswork.

### How to Calculate High-Water Stack Usage
Initialize the entire stack area with a recognizable byte pattern (e.g., `0xAA`). During profiling or before recycling:
```odin
fiber_calc_stack_usage :: proc(fiber: ^Fiber) -> (used_bytes: uint, total_bytes: uint) {
    bytes := ([^]u8)(fiber.stack_base)
    start_offset := CANARY_SIZE // Skip canary
    
    // Find the first byte that was modified from 0xAA
    for i in start_offset ..< int(fiber.stack_size) {
        if bytes[i] != 0xAA {
            used_bytes = fiber.stack_size - uint(i)
            break
        }
    }
    return used_bytes, fiber.stack_size
}
```

This allows you to render a debug overlay:
```
[DEBUG] Active Fibers: 14
├─ Boss AI Timeline (Used: 2.1 KB / 32 KB) [6.5%]
├─ Player Dash       (Used: 1.2 KB / 32 KB) [3.7%]
└─ Super Nova Burst  (Used: 1.8 KB / 32 KB) [5.6%]
```

---

## 4. Visual Diagnostics UI (Bringing Back the Tree View)

In your original implementation, you had a tree-based coroutine debugger. You can now build a **live Fiber Hierarchy Visualizer**:

```
COROUTINE DEBUGGER (F1)
▼ [Fiber #1] Boss Master AI (Running, 4.2s)
  ▼ [Fiber #2] Phase 1 Combat Sync (Suspended Join)
    ├─ [Fiber #3] Patrol Loop (Sleeping Time, 0.12s left)
    ├─ [Fiber #4] Spiral Shoot Loop (Ready)
    └─ [Fiber #5] Targeted Burst Loop (Sleeping Time, 1.4s left)
  └─ [Fiber #6] HP < 700 Trigger (Waiting Condition)
```

Because your `Fiber` struct stores intrusive hierarchy pointers (`parent`, `first_child`, `next_sibling`), rendering this is a simple recursive tree walk starting from root fibers (`parent == nil`).

---

## 5. Architectural Decision Matrix

| Question | Recommended Approach | Rationale |
| :--- | :--- | :--- |
| **Should we run fibers across multiple worker threads?** | **No (Keep on Main Thread)** | Gameplay logic is vastly easier and safer when deterministic and single-threaded. OS context-switching / data-races on game state (HP, positions, inventories) are eliminated. |
| **Stack Allocation: OS Virtual Memory vs Slab Arena?** | **Slab Arena (Current)** | Your slab allocator achieves sub-microsecond allocation and zero OS syscall overhead. 1MB slabs for 32 fibers give $O(1)$ recycling with contiguous cache locality. |
| **Handling Fiber Return Values?** | **Pointer in Payload** | If a fiber produces a result (e.g., pathfinding node list), pass a pointer in the payload struct `Result_Data { out_path: ^Path }`. It avoids generic union gymnastics. |

---

## Suggested Next Feature Checklist

1. [ ] **Per-Fiber Temp Arena:** Embed `mem.Arena` in `Fiber` for isolated `context.temp_allocator`.
2. [ ] **`with_timeout` Helper:** Quick quality-of-life helper for race-against-clock operations.
3. [ ] **Live Debugger Overlay:** A Raylib tree overlay displaying active fibers, remaining sleep timers, and high-water stack usage.
4. [ ] **Fiber Signals:** Lightweight zero-polling event dispatchers.
