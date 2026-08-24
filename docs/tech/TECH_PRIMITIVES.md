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

### `Fiber_Mutex`
- Zero-OS-contention mutual exclusion for shared gameplay resources (e.g., single-occupant charging pads, exclusive interaction terminals).
- If locked, `mutex_lock(f, &m)` suspends the caller and queues its `^Fiber` into the mutex's intrusive waitlist.
- When `mutex_unlock(&m)` is called, the next waiting fiber is moved to the ready queue in $O(1)$ time.

### `Signal`
- Event broadcast primitive (`signal_wait`, `signal_emit`).
- Allows multiple fibers to suspend awaiting a named event (e.g. `on_boss_enrage`, `on_alarm_tripped`).
- `signal_emit(&sig)` wakes all listening fibers simultaneously in a single frame.

---

## 5. Typed Multicast Events (`Event(T)`)

While `Signal` broadcasts void notifications (0 data), `Event(T)` provides 1-to-many typed publish-subscribe broadcasts:

```odin
Event :: struct($T: typeid) {
    waiters:   [dynamic]^Fiber,
    allocator: mem.Allocator,
}
```

- `event_wait(f, &ev)`: Suspends fiber and registers it in `ev.waiters`.
- `event_emit(sched, &ev, payload)`: Delivers a copy of `payload` to all active listeners and queues them for execution on the next frame. Zero CPU polling.

---

## 6. Counting Semaphores & Countdown Latches

### `Fiber_Semaphore` (Counting Semaphore)
- Generalizes mutual exclusion to up to $N$ concurrent permits.
- Ideal for concurrency limits (e.g. max 3 concurrent pathfinding queries, max 2 concurrent audio streams).
- `semaphore_acquire`: Suspends if available permits are 0.
- `semaphore_release`: Increments permits and wakes queued fibers in FIFO order.
- `semaphore_try_acquire`: Non-blocking permit check.

### `Fiber_Latch` (Countdown Rendezvous Barrier)
- Synchronization barrier initialized with count $N$.
- Multiple fibers can wait with `latch_wait(f, &latch)`.
- Other systems decrement the barrier with `latch_count_down(sched, &latch, count)`.
- When the count reaches 0, all waiting fibers are unblocked simultaneously.

---

## 7. Dynamic Task Joining (`fiber_join`)

Allows any fiber to await the termination of an independent fiber handle:

```odin
ok := coroutine.fiber_join(f, target_handle)
```

- If target fiber is already completed/recycled, returns immediately.
- Suspends calling fiber until target terminates. Returns `true` if target completed with `.Completed`, and `false` if target was aborted or failed.

