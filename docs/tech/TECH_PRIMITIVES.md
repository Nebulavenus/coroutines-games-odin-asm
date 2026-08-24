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
