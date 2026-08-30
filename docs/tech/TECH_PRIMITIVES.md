# Decoupled Subsystems & Primitives (`TECH_PRIMITIVES.md`)

This document details the architecture and operational mechanics of the auxiliary primitives in the **Odin Stackful Coroutine Engine**: CSP Typed Channels, Stateful Pull Generators, Async Background Thread Bridges, and Cooperative Mutexes/Signals.

---

## 1. CSP Typed Channels (`Channel(T)`)

The engine provides zero-allocation, type-safe Communicating Sequential Processes (CSP) channels modeled after Go and Occam.

```
                  ┌─────────────────────────────────┐
                  │    Channel(T) Ring Buffer       │
                  │  [ 0 | 1 | 2 | 3 | 4 | 5 | 6 ]  │
                  └─────────▲─────────────▲─────────┘
                            │             │
                    tail (Write)       head (Read)
```

### Mathematical Ring Buffer Mechanics
For a bounded channel of fixed capacity $C$:
- **Enqueue Position:** $\text{tail} = (\text{head} + \text{count}) \pmod C$
- **Dequeue Position:** $\text{head} = (\text{head} + 1) \pmod C$
- **Count Invariant:** $0 \le \text{count} \le C$
- **Empty Condition:** $\text{count} == 0$
- **Full Condition:** $\text{count} == C$

### Channel Architectures:
1. **Unbuffered (Rendezvous / Capacity 0):**
   - A sending fiber blocks until a receiving fiber arrives to accept the message (and vice-versa). Direct zero-copy handoff.
2. **Bounded FIFO Buffered (Capacity $N$):**
   - Fixed-size circular ring buffer with $O(1)$ head/tail index advancement.
   - `chan_send`: Pushes value into ring buffer; suspends fiber only when the buffer is completely full.
   - `chan_recv`: Pops value from ring buffer; suspends fiber only when the buffer is empty.
   - `chan_try_send` / `chan_try_recv`: Non-blocking instantaneous probe returning `(val, ok)`.
   - `chan_close`: Closes the channel; wakes all waiting receivers with `ok = false`.

---

## 2. Stateful Pull Generators (`Generator(T)`)

Generators provide lazy, stateful sequence generation (e.g., procedural item rolling, dungeon path generation, mathematical series) without heap allocations or manual iterator state structs.

```
 Consumer Loop                     Generator Fiber (16 KB Stack)
┌──────────────┐                  ┌──────────────────────────────┐
│ val, ok :=   │ ───────────────► │ for item in items {          │
│  gen_next(g) │                  │     yield_value(f, item)     │
│ fmt.print(v) │ ◄─────────────── │ }                            │
└──────────────┘   (Value + OK)   └──────────────────────────────┘
```

### Generator Architecture & Memory Footprint:
- Dedicated lightweight 16 KB stack per generator (64x smaller footprint than 1 MB standard slabs).
- Consumes zero CPU cycles while idle.
- Calling `generator_next(&gen)` switches context into the generator until `yield_value(f, value)` is called.
- Context switches back to caller returning `(value, true)`.
- When the generator procedure returns, `generator_next` returns `({}, false)`.

---

## 3. Async Job Bridge (`await_async` / `Async_Token`)

Modern games often offload heavy compute (A* pathfinding, mesh generation, asset decompression) to background OS threads (e.g., `core:thread` thread pools). 

```
 Main Thread (Scheduler & Fibers)               Background Thread Pool (OS Threads)
┌────────────────────────────────┐             ┌────────────────────────────────────┐
│ Coroutine Fiber A:             │             │ Worker Thread 3:                   │
│   token := async_dispatch(...) │ ──────────► │   Calculate 50,000 A* Nodes        │
│   await_async(f, &token)       │             │   token.result = computed_path     │
│   // Suspended! Zero Frame Drop│             │   atomic_store(&token.done, true)  │
│                                │ ◄────────── └────────────────────────────────────┘
│ (Resumed when done == true!)   │   Ready Queue
└────────────────────────────────┘
```

### Lock-Free Memory Contract:
- `Async_Token` contains an atomic `done: bool` flag and user-defined result pointer.
- `await_async(f, &token)` suspends the calling fiber without blocking the main game loop.
- The scheduler checks pending async tokens each tick using acquire-release memory semantics. The moment `done` evaluates to `true`, the fiber is re-queued into the Ready FIFO queue for immediate frame execution.

---

## 4. Cooperative Mutual Exclusion (`Fiber_Mutex` & `Signal`)

### `Fiber_Mutex` (24 bytes, True ZII)
- Zero-OS-contention mutual exclusion for shared gameplay resources (e.g., single-occupant charging pads, exclusive interaction terminals).
- If locked, `mutex_lock(f, &m)` suspends the caller and enqueues its intrusive `next_waiter` pointer into the mutex's `Wait_Queue` with **0 heap allocations**.
- When `mutex_unlock(sched, &m)` is called, the next waiting fiber is popped in $O(1)$ time and moved to the scheduler ready queue.
- **True ZII**: Valid immediately upon declaration (`m: coroutine.Fiber_Mutex`).

### `Signal` (16 bytes, True ZII)
- Event broadcast primitive (`signal_wait`, `signal_emit`).
- Allows multiple fibers to suspend awaiting a named event (e.g. `on_boss_enrage`, `on_alarm_tripped`).
- `signal_emit(sched, &sig)` pops and wakes all listening fibers from its `Wait_Queue` in a single frame.

---

## 5. Typed Multicast Events (`Event(T)`)

While `Signal` broadcasts void notifications (0 data), `Event(T)` provides 1-to-many typed publish-subscribe broadcasts:

```odin
Event :: struct($T: typeid) {
    waiters:   Wait_Queue,
    allocator: mem.Allocator,
}
```

- `event_wait(f, &ev)`: Suspends fiber and appends it to `ev.waiters` in $O(1)$ time.
- `event_emit(sched, &ev, payload)`: Delivers a copy of `payload` (up to 128 bytes) directly into each listener's `payload_storage` and wakes all living listeners simultaneously without CPU polling.

---

## 6. Counting Semaphores & Countdown Latches

### `Fiber_Semaphore` (Counting Semaphore, 32 bytes)
- Generalizes mutual exclusion to up to $N$ concurrent permits with an embedded `Wait_Queue`.
- Ideal for concurrency limits (e.g. max 3 concurrent pathfinding queries, max 2 concurrent audio streams).
- `semaphore_acquire`: Suspends if available permits are 0.
- `semaphore_release`: Increments permits and wakes queued fibers in FIFO order in $O(1)$ time.
- `semaphore_try_acquire`: Non-blocking permit check.

### `Fiber_Latch` (Countdown Rendezvous Barrier, 24 bytes, True ZII)
- Synchronization barrier initialized with count $N$ (`latch := coroutine.Fiber_Latch{count = 3}`).
- Multiple fibers can wait with `latch_wait(f, &latch)`.
- Other systems decrement the barrier with `latch_count_down(sched, &latch, count)`.
- When the count reaches 0, all waiting fibers are unblocked simultaneously in $O(1)$ time per node.

---

## 7. Dynamic Task Joining (`fiber_join`)

Allows any fiber to await the termination of an independent fiber handle:

```odin
ok := coroutine.fiber_join(f, target_handle)
```

- If target fiber is already completed/recycled, returns immediately in $O(1)$ time using packed generational handle slot lookup.
- Suspends calling fiber until target terminates. Returns `true` if target completed with `.Completed`, and `false` if target was aborted or failed.

---

## 8. Multi-Channel Select (`chan_select_recv` & `chan_try_select_recv`)

Provides classic Go-style CSP multi-channel multiplexing across an arbitrary slice of channels:

```odin
// Non-blocking select check
ready_idx, val, ok := coroutine.chan_try_select_recv([]^coroutine.Channel(int){&ch_a, &ch_b})

// Blocking fiber select suspension
ready_idx, val, ok := coroutine.chan_select_recv(f, []^coroutine.Channel(string){&ch_net, &ch_input})
```

- **Semantics:** 
  1. Fast path: probes all channels with `chan_try_recv` in $O(N)$ time.
  2. Event-driven suspension: if all channels are empty, registers calling fiber `f` into `ch.recv_waiters` across **all open channels** simultaneously in $O(1)$ time per channel.
  3. Wakeup & $O(1)$ in-place unlinking: on wakeup from any sender, calls `wait_queue_remove(&ch.recv_waiters, f)` across all selected channels to unlink `f` in $O(1)$ time without linear searching.

---

## 9. Explicit Cancellation Token (`Cancel_Token` & `with_cancel_token`)

A lightweight, decoupled cancellation primitive (24 bytes, True ZII) for cross-subsystem coordination:

```odin
Cancel_Token :: struct {
    is_cancelled: bool,
    waiters:      Wait_Queue,
    allocator:    mem.Allocator,
}

// Lifecycle & Control (True ZII: tok: Cancel_Token is immediately ready!)
cancel_token_cancel(&sched, &tok)
cancel_token_wait(f, &tok)
is_cancelled := cancel_token_is_cancelled(&tok)

// 1-line race cancellation wrapper:
cancelled := coroutine.with_cancel_token(f, &tok, coroutine.branch(task_proc, task_data))
```

- Enables multiple independent fibers across different entity scopes to coordinate abort signals without sharing a `Fiber_Scope`.
- Calling `cancel_token_wait` on an already-cancelled token returns immediately without suspension.
- `with_cancel_token` races the task branch against a token watcher and returns `true` if cancelled before completion.

---

## 10. Zero-Drift Gameplay Ticker (`Ticker`)

Periodic gameplay loops using relative sleeps `wait(f, interval)` suffer from cumulative floating-point time drift because workload execution delays compound across frames.

```odin
Ticker :: struct {
    interval:  f32,
    next_wake: f64,
    use_real:  bool,
}

ticker_init(&ticker, interval_seconds = 0.5, use_real_time = false)
ticker_wait(f, &ticker)
```

### Mathematical Time Anchoring:
- Calculates target wake timestamps via absolute interval addition: $t_{k+1} = t_k + \Delta t$
- If the game drops frames or stalls, the ticker catches up without cascading bursts by clamping forward to $\text{now} + \Delta t$.
- Guarantees exact frequency (e.g. exactly 120 ticks in 60.0s) across both simulation and real-time clock domains.

---

## 11. Deadlock-Proof Scoped Locks (`with_mutex` / `with_semaphore`)

```odin
with_mutex :: proc{with_mutex_ptr, with_mutex_val, with_mutex_nil}
with_semaphore :: proc{with_semaphore_ptr, with_semaphore_val, with_semaphore_nil}
```

- Automatically pairs `mutex_lock` / `semaphore_acquire` with deferred release upon lambda or procedure exit.
- Supports pointer payloads, inline by-value structs (`size_of(T) <= 128`), and parameterless nil lambdas.
- Prevents resource starvation and permanent deadlock when fibers take early returns or abort.

---

## 12. Hierarchy Tree Diagnostics (`scheduler_walk_tree` & `Fiber_Visitor`)

Provides engine-agnostic hierarchical traversal for custom in-game HUDs and GUI profilers (Raylib, ImGui, Sokol):

```odin
Fiber_Visitor :: #type proc(f: ^Fiber, depth: int, user_data: rawptr)

scheduler_walk_tree(sched, proc(f: ^coroutine.Fiber, depth: int, user_data: rawptr) {
    // Traverse active fiber hierarchy with depth-level indentation
    used, total := coroutine.fiber_calc_stack_usage(f)
    fmt.printf("%*s[#%d] %s (%v) - Stack: %.1fKB\n", depth * 2, "", f.handle, f.debug_name, f.status, f32(used)/1024.0)
})
```

---

## 13. Stale Aborted Waiter Immunity

All synchronization waitlists (`mutex.waiters`, `sem.waiters`, `latch.waiters`, `chan.recv_waiters`, `token.waiters`) are protected by **generational handle validation**:

```odin
if next_fiber.status == .Suspended_Join && fiber_is_alive(sched, next_fiber.handle) {
    next_fiber.status = .Ready
    append(&sched.ready_queue, next_fiber)
}
```

If a waiting fiber is aborted externally, its entry in a waiter queue is safely ignored and discarded upon release, preventing false wakeups or corrupted fiber states.

