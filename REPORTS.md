# 1 Verification & Architecture Compliance Report

This document records the verification matrix and test coverage for the SkookumScript-inspired stackful coroutine engine implemented in Odin using native inline assembly (`asm`).

---

## 1. Feature Verification Matrix

| Feature / Subsystem | Verification Method | Status |
| :--- | :--- | :--- |
| **Low-Level ASM Context Switch** | [`src/coroutine/asm_amd64.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/asm_amd64.odin) — Call/ret pattern with callee-saved GPRs + XMM6..15 register preservation and stack alignment | Verified |
| **Stack Synthesis & Trampoline** | [`src/coroutine/pool.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/pool.odin#L173) — Initial frame layout with `%r12` fiber passing | Verified |
| **Stack Overflow Protection** | [`src/coroutine/pool.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/pool.odin#L68) — 64-byte `0xDEAD_BEEF_CAFE_BABE` canary guard validation (`test_stack_canary_guard`) | Verified |
| **Stack Preservation Across Yields** | Verified local variables survive multiple frame yields (`test_stack_local_variables_across_yields`) | Verified |
| **Timer Min-Heap** | [`src/coroutine/scheduler.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/scheduler.odin#L41) — $O(\log N)$ min-heap with cached index for instant removal on cancel (`test_wait_seconds_timer_heap`) | Verified |
| **Frame & Condition Waits** | [`src/coroutine/scheduler.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/scheduler.odin#L199) — `wait_frames`, `yield_frame`, `wait_until`, `wait_cond` (`test_wait_frames`, `test_wait_until_condition`) | Verified |
| **Structured Concurrency: `sync`** | [`src/coroutine/api.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/api.odin#L173) — Parallel join of $N$ branches, suspends parent until all complete (`test_structured_sync`) | Verified |
| **Structured Concurrency: `race`** | [`src/coroutine/api.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/api.odin#L214) — Preemptive first-to-finish race, immediately aborts all competing sibling subtrees (`test_structured_race`) | Verified |
| **Nested Structured Concurrency** | Nested `race` containing a parallel `sync` branch (`test_nested_race_with_sync_branch`) | Verified |
| **Hierarchical Scope Cancellation** | [`src/coroutine/scheduler.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/scheduler.odin#L341) — `scope_cancel` recursively unwinds all child fibers attached to an entity (`test_scope_cancellation`) | Verified |
| **Defer & Destructor Execution** | Custom cleanup callbacks run on early aborts / cancel (`test_cleanup_proc_and_defer`) | Verified |
| **Value Interpolation & Easing** | [`src/coroutine/api.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/coroutine/api.odin#L286) — `tween` with linear, quad, and cubic easing curves (`test_tween_interpolation`) | Verified |
| **Multi-Fiber Concurrency** | 100 concurrent fibers interleaved across frames (`test_many_concurrent_fibers`) | Verified |
| **Full Boss AI Gameplay Simulation** | [`src/main.odin`](file:///E:/OdinLang/Projects/coroutines_asm/src/main.odin) — Multi-phase AI timeline with racing triggers, combat `sync`, `tween` movement, and tracking allocator (0 memory leaks) | Verified |

---

## 2. Test Suite Execution Results

All unit tests are executed via `build.ps1 test`:

```
Testing coroutine package...
Finished 14 tests in ~3.7ms. All tests were successful.
```

### Coverage by Test:
1. `test_basic_spawn_and_run`: Spawns a fiber and verifies execution upon `scheduler_step`.
2. `test_stack_local_variables_across_yields`: Validates that registers/local stack variables maintain state across multiple yields.
3. `test_wait_seconds_timer_heap`: Validates timer min-heap sleeping and waking based on absolute engine time.
4. `test_wait_frames`: Validates exact frame-count pauses.
5. `test_wait_until_condition`: Validates polling boolean predicate closures across frames.
6. `test_structured_sync`: Validates parallel branch execution and parent waking only after all children finish.
7. `test_structured_race`: Validates first-to-finish preemption and sibling cancellation.
8. `test_scope_cancellation`: Validates tearing down all coroutines belonging to an entity's `Fiber_Scope`.
9. `test_cleanup_proc_and_defer`: Validates guaranteed cleanup callbacks when a fiber is cancelled prematurely.
10. `test_tween_interpolation`: Validates linear and non-linear numerical interpolation over time.
11. `test_stack_canary_guard`: Validates 64-byte stack canary watermark integrity.
12. `test_nested_race_with_sync_branch`: Validates complex hierarchical compositions (`race` containing `sync` sub-branches).
13. `test_time_scaling_and_pause`: Validates `time_scale` multipliers and `is_paused` flags.
14. `test_many_concurrent_fibers`: Validates 100 simultaneous fibers executing concurrently with interleaved context switching.
