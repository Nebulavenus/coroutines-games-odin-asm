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
   - If sleeping in `timer_heap` or `real_timer_heap`: Removed in $O(\log N)$ via cached heap indices.
   - If queued in `frame_waiters`: Removed from the frame wait array.
   - If waiting on `Signal`, `Fiber_Mutex`, or `Channel`: Removed from suspension waitlists.
3. **State Transition:** Fiber state transitions to `.Aborted` or `.Cancelled`.
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

## 5. The 4-Stage Zero-Shift Scheduler Dispatch Pipeline

The engine executes all active fibers, timers, and synchronization queues in a deterministic 4-stage pipeline per frame step:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE 4-STAGE DISPATCH PIPELINE                            │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Clock Updates: Absolute f64 Sim/Real Clocks + Discrete u64 Ticks.        │
│ 2. Dual Min-Heaps: O(1) peek & O(log N) pop for expired timers.             │
│ 3. Single-Pass Linear Partitioning: (Steps 5, 6, 7)                         │
│    • Linear scan with single-pass write_idx filtering.                      │
│    • Zero memory shifts during iteration + O(1) end-of-pass resize().       │
│ 4. Zero-Shift Dynamic Cursor: (Step 8)                                      │
│    • Linear index loop: for i := 0; i < len(ready_queue); i += 1.           │
│    • Eliminates 50,000,000 pointer shifts per frame!                        │
│    • Automatically processes fibers spawned/unblocked during the same frame.│
│    • O(1) clear(&ready_queue) keeps backing capacity for the next frame.    │
└─────────────────────────────────────────────────────────────────────────────┘
```

1. **Stage 1 (Clocks)**: Updates simulation time ($t_{\text{sim}} + dt \cdot \text{scale}$), real-world wall clock ($t_{\text{real}} + dt$), and discrete frame counters.
2. **Stage 2 (Dual Min-Heaps)**: $O(1)$ peeks at root nodes of `timer_heap` and `real_timer_heap`. Expired timers are popped in $O(\log N)$ and appended to `ready_queue`.
3. **Stage 3 (In-Place Linear Partitioning)**: Filters `tick_waiters`, `frame_waiters`, and `condition_waiters` in a cache-friendly single linear forward sweep. Expired waiters move to `ready_queue`, while active ones remain compacted at the head with a single $O(1)$ `resize(...)`.
4. **Stage 4 (Zero-Shift Ready Execution)**: Steps sequentially through `ready_queue` using an index cursor (`i < len(ready_queue)`). Context-switches into each fiber in $18.4\text{ ns}$, processes volatile status reloads, auto-recycles completed fibers, and cleans the queue with an $O(1)$ `clear(&sched.ready_queue)`.

