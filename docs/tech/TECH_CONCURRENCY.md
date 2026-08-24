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
- `join_coord`: Intrusive struct managing join mode (`.Sync`, `.Race`, `.Rush`, `.Fallback`), active branch counts, and winner indices.

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

## 4. The Three Dimensions of Cancellation

The engine provides 3 orthogonal cancellation models tailored to different gameplay architectures:

```
┌───────────────────────────┬───────────────────────────┬───────────────────────────┐
│ 1. STRUCTURAL (Hierarchical)│ 2. CATEGORY (Orthogonal) │ 3. EXPLICIT (Decoupled)   │
├───────────────────────────┼───────────────────────────┼───────────────────────────┤
│ `Fiber_Scope` / Tree      │ `user_tag: u32`           │ `Cancel_Token`            │
│ Bounded to entity lifetime│ Bounded to gameplay class │ Bounded to broadcast event│
│ e.g. Entity death         │ e.g. EMP / Silence blast  │ e.g. Game over / Cutscene │
└───────────────────────────┴───────────────────────────┴───────────────────────────┘
```

### Dimension 1: Structural Scopes (`Fiber_Scope`)
- Attached directly to game entities (e.g. `monster.scope`).
- All fibers spawned with `scope = &monster.scope` are tracked in `scope.handles`.
- When the monster dies, calling `scope_cancel(sched, &monster.scope)` cancels every coroutine attached to that monster in one call.

### Dimension 2: Category Tags (`user_tag` & `scheduler_cancel_by_tag`)
- Assigned on spawn: `spawn(sched, proc, tag = u32(Tag.Combat_AI))`.
- Bypasses entity hierarchy to cancel an entire category of behaviors across the whole world (e.g. cancelling all combat AI and shields on EMP detonation).

### Dimension 3: Explicit Tokens (`Cancel_Token`)
- Decoupled token handle passed to arbitrary fibers across different systems.
- Unrelated fibers await cancellation with `cancel_token_wait(f, &tok)`.
- Calling `cancel_token_cancel(sched, &tok)` awakens and unblocks all listeners simultaneously.
