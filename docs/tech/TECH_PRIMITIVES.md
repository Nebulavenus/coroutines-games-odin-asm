# Core and Modular Synchronization Primitives (`TECH_PRIMITIVES.md`)

This document details the architecture and operational mechanics of the primitives in the **Odin Stackful Coroutine Engine**:
1. **Core Runtime Primitives (`package coroutine`)**: Unified multicast `Event(T)` and broadcast `Signal :: Event(struct{})`, dynamic `fiber_join`, `await_async` atomic job bridge, and hierarchical `Fiber_Scope`.
2. **Modular Synchronization Subpackage (`package coroutine_sync` in `sync/`)**: CSP typed channels (`Channel(T)`), cooperative mutual exclusion (`Fiber_Mutex`), counting semaphores (`Fiber_Semaphore`), and multi-channel select (`chan_select_recv`).

---

## 1. Unified Events & Broadcast Signals (`Event(T)` & `Signal`)

`Signal` is a zero-size specialization of `Event(T)`:

```odin
Event :: struct($T: typeid) {
    waiters: Wait_Queue,
}

Signal :: Event(struct{})

Sticky_Event :: struct($T: typeid) {
    waiters:   Wait_Queue,
    has_value: bool,
    value:     T,
}

Sticky_Signal :: Sticky_Event(struct{})
```

Built entirely on intrusive `Wait_Queue` pointers embedded in `Fiber` (`next_waiter`, `prev_waiter`):
- **True ZII**: Valid immediately upon declaration with zero initialization procedure calls required.
- **Zero Allocations**: Inserting or removing waiters performs no heap allocations.
- **Unified Engine**: `signal_emit` and `event_emit` share the same zero-allocation broadcast pipeline.
- **Latched State (`Sticky_Event` / `Sticky_Signal`)**: Caches the emitted state (`has_value = true`) and payload value. If a fiber calls `sticky_event_wait` after the event was already emitted, it resumes immediately in $O(1)$ time without suspending, eliminating race conditions on initialization and game phase milestones. Can be reset via `sticky_event_reset`.

---

## 2. Verse-Style Typed Task Futures (`Task(T)` & `spawn_task`)

A lightweight, zero-allocation asynchronous future container modeled after Verse `spawn{}`:

```odin
Task :: struct($T: typeid) {
    handle: Fiber_Handle,
    result: Sticky_Event(T),
}
```

### Key API:
- `task_init(&task)`: Initializes the task container (True-ZII compliant).
- `spawn_task(sched, &task, entry, data)`: Spawns an asynchronous worker fiber whose return value is automatically delivered via `task_complete(f, &task, result)`.
- `task_await(f, &task) -> (val: T, ok: bool)`: Suspends the calling fiber until the worker finishes; if the worker already completed, returns the cached result immediately in $O(1)$.
- `task_is_ready(&task) -> bool`: Checks if the result is available without suspending.

```odin
heavy_task: coroutine.Task(int)
coroutine.spawn_task(&sched, &heavy_task, proc(f: ^coroutine.Fiber) -> int {
    coroutine.wait(f, 0.5)
    return 42
})

coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, t: ^coroutine.Task(int)) {
    val, ok := coroutine.task_await(f, t)
    fmt.println("Computed result:", val) // 42
}, &heavy_task)
```

---

## 3. LIFO Multi-Hook Defer Stack (`fiber_defer` & `fiber_cleanup_pop`)

When stackful fibers are aborted externally (via `scope_cancel`, `race` preemption, or `with_timeout`), native Odin `defer` statements inside the procedure do not run because the fiber stack is not resumed on the CPU.

To provide guaranteed cancellation safety, each `Fiber` maintains an inline 8-slot LIFO cleanup stack (`MAX_FIBER_CLEANUPS :: 8`):

```odin
Fiber_Cleanup :: struct {
    proc_ptr:  proc(user_data: rawptr),
    user_data: rawptr,
}
```

### Key API:
- `coroutine.fiber_defer(f, proc(user_data: ^T), user_data)`: Pushes a cleanup hook onto the fiber's LIFO stack.
- `coroutine.fiber_cleanup_pop(f)`: Unregisters the most recent cleanup hook when a scope exits normally.
- **Execution Invariant**: Cleanups execute in strict reverse (LIFO) order upon normal completion, failure, or external abort, guaranteeing that resources (mutex unlocks, state flags, speed multipliers) are never orphaned.

---

## 4. Pre-Built Branch Constructors (`branch_signal`, `branch_wait`)

High-level constructors that generate `Branch_Desc` arms directly without boilerplate lambdas:

- `branch_signal(sig, name)`: Creates a branch descriptor that suspends on a `Signal`.
- `branch_sticky_signal(sig, name)`: Creates a branch descriptor that suspends on a `Sticky_Signal`.
- `branch_wait(seconds, name, clock)`: Creates a timer branch descriptor for `race` or `rush`.

---

## 5. Dynamic Task Joining (`fiber_join`)

Allows any fiber to await the natural completion or abortion of another independent fiber by its generational handle:

```odin
handle := coroutine.spawn(&sched, background_workload)

coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, target: coroutine.Fiber_Handle) {
    ok := coroutine.fiber_join(f, target)
    if ok {
        fmt.println("Target completed successfully!")
    }
}, handle)
```

- If the target fiber is already finished or invalid, `fiber_join` returns immediately in $O(1)$ time without suspending.
- If the target fiber is alive, the calling fiber attaches to the target's intrusive join wait queue and suspends until the target terminates.

---

## 6. Async Job Bridge (`await_async` / `Async_Token`)

Modern games often offload heavy compute (A* pathfinding, mesh generation, asset decompression) to background OS threads (e.g., `core:thread` thread pools). 

```
 Main Thread (Scheduler & Fibers)               Background Thread Pool (OS Threads)
┌────────────────────────────────┐             ┌────────────────────────────────────┐
│ Coroutine Fiber A:             │             │ Worker Thread 3:                   │
│   token: coroutine.Async_Token │ ──────────► │   Calculate 50,000 A* Nodes        │
│   await_async(f, &token)       │             │   token.result = computed_path     │
│   // Suspended! Zero Frame Drop│             │   async_token_complete(&token, true│
│                                │ ◄────────── └────────────────────────────────────┘
│ (Resumed when done!)           │
└────────────────────────────────┘
```

### Lock-Free Memory Contract:
- `Async_Token` contains an atomic `state: Async_State` (`Pending`, `Completed`, `Failed`).
- `await_async(f, &token)` yields cooperatively while atomic load reports `.Pending`, consuming 0 heap allocations and introducing zero locks or scheduler condition queues.

---

## 7. Modular Subpackage: CSP Typed Channels (`Channel(T)`)

Located in `sync/` (`package coroutine_sync`):

```
                  ┌─────────────────────────────────┐
                  │    Channel(T) Ring Buffer       │
                  │  [ 0 | 1 | 2 | 3 | 4 | 5 | 6 ]  │
                  └─────────▲─────────────▲─────────┘
                            │             │
                    tail (Write)       head (Read)
```

### Channel Modes:
1. **Symmetrical Unbuffered Rendezvous (`capacity == 0`):**
   - Sender and receiver meet synchronously. The first to arrive suspends; the second arrives, directly exchanges the payload, and wakes the first in $O(1)$ time.
2. **Bounded FIFO Buffered (Capacity $N$):**
   - Fixed-size circular ring buffer.
   - `chan_send`: Pushes value into ring buffer; suspends fiber only when full.
   - `chan_recv`: Pops value from ring buffer; suspends fiber only when empty.
   - `chan_recv_timeout` / `chan_send_timeout`: Bounded-time operations with clean timeout returns.
   - `chan_select_recv`: Multiplexer awaiting whichever channel is ready first.

---

## 8. Modular Subpackage: Mutual Exclusion & Semaphores

Located in `sync/` (`package coroutine_sync`):

### `Fiber_Mutex` (24 bytes, True ZII)
- Zero-OS-contention cooperative mutual exclusion.
- `mutex_lock(f, &m)`: Enqueues caller into intrusive wait queue if locked.
- `with_mutex(f, &m, proc)`: Scoped deadlock-proof lock with automatic unlock on return or abort.

### `Fiber_Semaphore` (32 bytes)
- Generalizes mutual exclusion to up to $N$ concurrent permits.
- `semaphore_acquire`, `semaphore_release`, `with_semaphore`.
- Safe permit accounting with automatic cleanup chaining.
