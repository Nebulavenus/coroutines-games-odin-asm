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
(Fork-Join All)    (First Finishes)     (First Succeeds)    (Sequential Fallback)
```

### Comprehensive Combinator Specification

| Primitive | Execution Model | Success Criterion | Failure / Cancellation Behavior |
| :--- | :--- | :--- | :--- |
| **`sync`** | Parallel Fork-Join | Resumes parent when **all** branches succeed (`state == .Finished`). | If any branch fails or is cancelled, all remaining sibling branches are immediately aborted. Parent marks failure. |
| **`race`** | Parallel First-to-Finish Preemption | Resumes parent as soon as **any** branch finishes or fails. | The winning branch terminates the race; all losing sibling subtrees are recursively aborted. |
| **`rush`** | Parallel First-to-Succeed Race | Resumes parent when the **first successful** branch finishes. | Early failures of individual branches are ignored. If all branches fail, parent fails. |
| **`fallback`** | Sequential Priority Execution | Executes branches sequentially ($A \rightarrow B \rightarrow C$). Stops at first success. | If branch $A$ succeeds, $B$ and $C$ never spawn. If branch $A$ fails, execution cascades to $B$. |
| **`with_timeout`** | Time-Bounded Scoped Execution | Branch finishes before deadline $t$. | If timer expires, child fiber subtree is cancelled and `with_timeout` returns `false`. |

---

## 2. Coordinator Lifecycle & Intrusive Tree Topology

To achieve zero dynamic heap allocations during branch coordination, each `Fiber` contains an intrusive `Join_Coordinator` node.

```
                         [ Parent Fiber ]
                    Join_Coordinator: .Sync / .Race
                     ├─ count: 3, completed: 0
                     └─ first_child: ──┐
                                       │
         ┌─────────────────────────────┼─────────────────────────────┐
         ▼                             ▼                             ▼
   [ Child Fiber A ]             [ Child Fiber B ]             [ Child Fiber C ]
   sibling_next: ──────────────► sibling_next: ──────────────► sibling_next: nil
   parent: ^Parent               parent: ^Parent               parent: ^Parent
```

### Tree Topology Pointers:
- `first_child`: Pointer to the first active child fiber.
- `sibling_next`: Pointer to the next sibling in the linked list.
- `parent`: Pointer back to the parent fiber.
- `join_coord`: Intrusive struct managing join mode (`.Sync`, `.Race`, `.Rush`), active branch counts, and winner indices.

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
5. **Native Odin `defer` Execution:** When the cancelled fiber resumes for cleanup, its stack unwinds cleanly through native `defer` blocks.

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

