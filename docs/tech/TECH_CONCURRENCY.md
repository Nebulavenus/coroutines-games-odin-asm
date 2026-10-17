# Structured Concurrency & Coordinators (`TECH_CONCURRENCY.md`)

This document provides the formal architectural specification of structured concurrency, the `Join_Coordinator` intrusive tree topology, and bottom-up cancellation mechanics in the **Odin Stackful Coroutine Engine**.

---

## 1. The Structured Concurrency Matrix

Structured concurrency guarantees that concurrent branches are bounded by lexical scope. A parent fiber spawning child branches cannot complete or leave its execution scope until all child branches have terminated.

```
                                  [ Parent Fiber ]
                                         │
        ┌───────────────────┬────────────┴───────┬───────────────────┐
        ▼                   ▼                    ▼                   ▼
     `sync`              `race`               `rush`            `fallback`
(Fork-Join All)     (First to Succeed,   (First to Succeed,  (Sequential Priority)
                     Aborts Rivals)       Losers Continue)
```

### Comprehensive Combinator Specification

| Primitive | Execution Model | Success Criterion | Failure / Cancellation Behavior |
| :--- | :--- | :--- | :--- |
| **`sync`** | Parallel Fork-Join | Resumes parent when **all** branches succeed (`state == .Completed`). | If any branch fails or is cancelled, all remaining sibling branches are immediately aborted. Parent marks failure. |
| **`sync_with`** | Parallel Fork-Join (Shared Context) | Resumes parent when all branches succeed. Passes shared `^T` context without `branch` closures. | Sibling abort on failure; 16-slot inline buffer eliminates dynamic allocation. |
| **`race`** | Parallel First-to-Succeed Preemption | Resumes parent as soon as **any** branch completes successfully (`.Completed`). | Sibling branches that call `fail(f)` drop out without winning. The first successful arm wins and recursively aborts all competing sibling subtrees. If all branches fail, parent fails (`winner_index = -1`). |
| **`race_with`** | Parallel Preemption (Shared Context) | Resumes parent as soon as any branch succeeds. Passes shared `^T` context. | First success aborts sibling subtrees; returns winner index or `-1` on total failure. |
| **`rush`** | Parallel First-to-Succeed Partial Join | Resumes parent as soon as the **first** branch completes successfully (`.Completed`). | Early failures are ignored. **Crucially: losing sibling arms are NOT aborted.** Their join coordinator is detached (`child.join_coord = nil; child.join_coord_id = 0`) and they continue executing concurrently in the background. If all branches fail, parent fails. |
| **`rush_with`** | Parallel Partial Join (Shared Context) | Resumes parent on first success with shared `^T` context. | Losers continue running detached in background bound to parent scope. |
| **`fallback`** | Sequential Priority Execution | Executes branches sequentially ($A \rightarrow B \rightarrow C$). Stops at first success. | If branch $A$ succeeds, $B$ and $C$ never spawn. If branch $A$ fails, execution cascades to $B$. |
| **`fallback_with`** | Sequential Priority (Shared Context) | Executes sequentially passing shared `^T` context. Stops at first success. | Cascades on `fail(f)`. Returns index of first succeeding branch or `-1`. |
| **`branch_scoped`** | Parent-Bound Fire-and-Forget | Parent continues immediately without suspending. Subtask runs in background. | Scoped to parent lifetime: if the parent fiber completes, fails, or is cancelled, all attached scoped branches are automatically aborted bottom-up. |
| **`with_signal`** | Interruptible Task Execution | Task completes normally before signal emits. Returns `interrupted: false`. | If signal emits while task runs, task is immediately aborted and combinator returns `interrupted: true`. |
| **`with_timeout`** | Time-Bounded Scoped Execution | Branch finishes before deadline $t$. Returns `timed_out: false`. | If timer expires, child fiber subtree is cancelled and `with_timeout` returns `timed_out: true`. |
| **`Task(T)` / `spawn_task`** | Typed Future Computation | Worker completes and delivers typed `T` payload via `Sticky_Event(T)`. | True-ZII; late awaiters receive result immediately even after worker fiber has finished and recycled. |
| **`yield_now`** | In-Frame Cooperative Timeslice | Relinquishes timeslice to other ready fibers in the current frame. | Resumes before the current simulation tick finishes without waiting for the next clock step. |

---

## 2. Coordinator Lifecycle & Intrusive Tree Topology

To achieve zero dynamic heap allocations during branch coordination, each `Fiber` contains an intrusive `Join_Coordinator` node (`f.active_coord`).

```
                         [ Parent Fiber ]
                    Join_Coordinator: .Sync / .Race / .Rush
                     ├─ id: monotonic u64 generation ID
                     ├─ count: 3, completed: 0
                     └─ first_child: ──┐
                                       │
         ┌─────────────────────────────┼─────────────────────────────┐
         ▼                             ▼                             ▼
   [ Child Fiber A ]             [ Child Fiber B ]             [ Child Fiber C ]
   join_coord_id: coord.id       join_coord_id: coord.id       join_coord_id: coord.id
   sibling_next: ──────────────► sibling_next: ──────────────► sibling_next: nil
   parent: ^Parent               parent: ^Parent               parent: ^Parent
```

### Tree Topology & Monotonic Generation Tracking:
- `id: u64`: Monotonically incrementing coordinator ID assigned on setup (`sched.next_coord_id += 1`).
- `join_coord_id: u64`: Stored on each child fiber matching `coord.id`. Prevents stale background branches from an earlier `rush` from accidentally corrupting subsequent `sync`, `race`, or `rush` invocations on `parent.active_coord`.
- `first_child`: Pointer to the first active child fiber.
- `sibling_next`: Pointer to the next sibling in the linked list.
- `parent`: Pointer back to the parent fiber.
- `join_coord`: Intrusive struct managing join mode (`.Sync`, `.Race`, `.Rush`), active branch counts, and winner indices.
  - In `.Race`: the first completed arm wins, parent is unblocked, and all sibling branches are recursively aborted.
  - In `.Rush`: the first completed arm wins and unblocks the parent; losing siblings have `join_coord` and `join_coord_id` zeroed out and continue executing concurrently in the background as scoped children of `parent`.
  - When `parent` terminates or cancels, `fiber_cleanup_and_recycle` sweeps `first_child` to cleanly drain and abort all background children bottom-up.

---

## 3. Hierarchical Bottom-Up Unwinding & Cancellation

When a branch is cancelled (via `race` preemption, `fiber_cancel`, `with_timeout`, or entity destruction), the engine guarantees deterministic cleanup:

```
                            [ fiber_cancel(Root) ]
                                      │
               ┌──────────────────────┴──────────────────────┐
               ▼                                             ▼
       [ Cancel Child A ]                            [ Cancel Child B ]
               │
       ┌───────┴───────┐
       ▼               ▼
 [ Grandchild 1 ] [ Grandchild 2 ]
```

### Unwinding Sequence:
1. **Recursive Leaf Traversal:** The cancellation algorithm recursively navigates to the bottom-most leaf nodes of the fiber tree first.
2. **Scheduler Queue Extraction:**
   - If sleeping in `.Sleeping_Time`: Removed in $O(\log N)$ from `sched.clocks[root.clock_id].timer_heap` via cached heap indices.
   - If queued in `.Sleeping_Steps`: Removed in-place from `sched.clocks[root.clock_id].step_waiters`.
   - If waiting on an intrusive wait queue (`Wait_Queue`): Removed in $O(1)$ via `wait_queue_remove`.
3. **State Transition:** Fiber state transitions to `.Aborted`.
4. **Stack & Resource Recycling:** Fiber stacks are recycled back into the slab free list in $O(1)$ time, and parent child counters are decremented.
5. **LIFO Defer Stack Execution (`fiber_defer`)**: Because suspended fibers cancelled from the outside are not resumed on CPU instructions (their stacks are recycled directly), native Odin `defer` does NOT execute on external abort. Instead, the engine executes the fiber's registered 8-slot LIFO defer stack (`fiber_defer`) in strict reverse order (`for root.cleanup_count > 0`), ensuring guaranteed resource reclamation (mutex/semaphore unlocks, state resets, entity flags) across normal returns, failures, and external cancellations alike.

---

## 4. Pure Structured Concurrency: The Two Dimensions of Cancellation

The engine provides 2 orthogonal cancellation models tailored to gameplay architectures, preserving 100% structured concurrency without loose unstructured token state:

```
┌───────────────────────────────────────────┬───────────────────────────────────────────┐
│ 1. HIERARCHICAL SCOPES (Ownership / Bounds)│ 2. INTERRUPTION RACES (Status / Mechanics)│
├───────────────────────────────────────────┼───────────────────────────────────────────┤
│ `Fiber_Scope` / Sub-Scopes / Trees        │ `race` & `Signal` / Fork-Join Preemption  │
│ Bounded to entity & subsystem lifetime    │ Bounded to gameplay status effects & stuns│
│ e.g. Entity death, despawn, scene unloads │ e.g. EMP blast, Silence, Stun, Interruption│
└───────────────────────────────────────────┴───────────────────────────────────────────┘
```

### Dimension 1: Hierarchical Scopes & Sub-Scopes (`Fiber_Scope` / `scope_cancel`)
- Attached directly to game entities (e.g. `monster.entity_scope`, `monster.combat_scope`).
- All fibers spawned with `scope = &monster.combat_scope` are tracked in `scope.handles`.
- When the monster dies or is stunned, calling `scope_cancel(sched, &monster.combat_scope)` cleanly cancels all attached fibers in $O(1)$ time.
- Task trees (`race`, `rush`, `sync`, `fallback`) automatically clean up subtrees bottom-up upon completion or failure.

### Dimension 2: Interruption Races (`race` & `Signal`)
- Combat workloads race against entity or area signals: `race(f, branch(combat_loop), branch(signal_wait(&stun_sig)))`.
- When a stun occurs, the combat subtree is aborted with zero leaked fibers, executes stun recovery, and loops around cleanly.

---

## 5. The Zero-Shift Scheduler Dispatch Pipeline

The engine executes active fibers, timers, and synchronization queues in a deterministic two-phase pipeline per step:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE SCHEDULER DISPATCH PIPELINE                          │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Clock Updates (clock_advance):                                           │
│    • Advances timeline for target Clock_Domain (delta, time, steps).        │
│    • O(1) peek & O(log N) pop for expired timers in domain's timer_heap.    │
│    • In-place partition of step_waiters with O(1) resize.                   │
│    • Appends awakened fiber handles to sched.ready_queue.                   │
│ 2. Ready Queue Dispatch (scheduler_run):                                    │
│    • Linear index loop: for i := 0; i < len(ready_queue); i += 1.           │
│    • Generational handle validation (f.handle == handle && f.status==.Ready)│
│    • Context-switches into each fiber in ~18ns.                             │
│    • O(1) clear(&ready_queue) keeps backing capacity for the next frame.    │
└─────────────────────────────────────────────────────────────────────────────┘
```

1. **Clock Phase (`clock_advance`)**: Advances the domain timeline ($t_{\text{domain}} + \Delta t$), pops expired timers from `c.timer_heap` into `sched.ready_queue`, and partitions `c.step_waiters`.
2. **Execution Phase (`scheduler_run`)**: Steps sequentially through `sched.ready_queue` using an index cursor (`i < len(ready_queue)`). Context-switches into each fiber, auto-recycles completed fibers, and cleans the queue with an $O(1)$ `clear(&sched.ready_queue)`.

