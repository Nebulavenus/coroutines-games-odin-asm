# Changelog

All notable changes to this project will be documented in this file.

## [Breaking API Modernization, Zero-Polling Wait Queues & Wasm Hardening] - 2026-11-22

### Changed (Breaking — Canonical API Cleanup)
- **Explicit Outcome Enums (`types.odin`, `scheduler.odin`, `api.odin`)**:
  - Added `Timeout_Outcome :: enum u8 { Completed, Timed_Out, Failed }` and `Signal_Outcome :: enum u8 { Completed, Interrupted, Failed }`.
  - Changed `with_timeout` to return `Timeout_Outcome` and `with_signal` / `with_sticky_signal` to return `Signal_Outcome`.
  - Added `Join_Kind.Guard` so task failure (`fail(f)`) inside `with_timeout` / `with_signal` / `with_sticky_signal` immediately aborts the guard watcher and returns `.Failed` instead of waiting for timeout or deadlocking.
- **Explicit Defer Stack Operations (`api.odin`)**:
  - Renamed `fiber_cleanup_pop` -> `fiber_defer_cancel` (unregisters top hook without executing) and added `fiber_defer_run_top` (pops and executes top hook immediately).
- **Removed Legacy Aliases (`api.odin`, `scheduler.odin`)**:
  - Removed duplicate aliases `wait_frames`, `yield_frame`, `current_frame`, `fiber_set_cleanup`, `fiber_set_cleanup_raw`, `fiber_set_cleanup_ptr`, `scheduler_sim_time`, `scheduler_frame_count`, and duplicate `scheduler_single_step`.
- **`scheduler_step` & Active Query (`scheduler.odin`)**:
  - Added `scheduler_has_active(sched)` and changed `scheduler_step` to return `has_active: bool` (enabling `for coroutine.scheduler_step(&sched, dt) {}`).
- **Zero-Polling Intrusive Waiting (`types.odin`, `pool.odin`, `scheduler.odin`, `api.odin`, `sync/sync.odin`)**:
  - Converted `scope_wait` (via `Fiber_Scope.waiters`), `fiber_join` (via `Fiber.join_waiters`), and `chan_select_recv` (via event-driven watcher branches) from per-tick `yield` polling to zero-polling suspension that also wakes across paused clocks.
  - Updated `chan_select_recv` so closing a subset of channels keeps waiting on still-open channels and only returns `(-1, {}, false)` once all channels are closed and drained.
  - Added `Fiber.step_index` for $O(1)$ `step_waiters` swap-remove on abort.
- **Handle History & Wasm Shadow-Stack Fixes (`types.odin`, `pool.odin`, `api.odin`, `sync/sync.odin`)**:
  - Replaced `u32(handle) % HANDLE_HISTORY_CAPACITY` (which ignored the upper 16 generation bits) with bijective `fiber_handle_history_slot` mixing index and generation; fixed `fiber_join` to return `false` for unknown/missing handles.
  - Eliminated parent stack pointers in `sync/sync.odin` (`with_mutex`, `with_semaphore`, `chan_recv_timeout`, `chan_send_timeout`, `chan_select_recv`), using direct pointers and scoped `f.temp_arena` allocations for full `js_wasm32` shadow-stack safety.
- **Zero-Context-Switch `await_async`, Arbitrary-Size `Event(T)`/`Sticky_Event(T)` & `Task(T)` Failure Propagation (`config.odin`, `types.odin`, `pool.odin`, `scheduler.odin`, `api.odin`, `asm_wasm32.odin`)**:
  - Replaced `await_async` per-tick `yield` polling with `Scheduler.async_waiters` checked once per `scheduler_run` (0 context switches while pending, wakes across paused clocks, $O(1)$ abort removal via `Fiber.async_index`, background threads remain lock-free).
  - Decoupled `Event(T)` and `Sticky_Event(T)` from `Fiber.payload_storage` (eliminating the 128B `#assert` cap and `spawn_val` aliasing hazard) using `Fiber.event_dest` + scoped `temp_arena`/heap delivery for `Event(T)` and direct `ev.value` reads for `Sticky_Event(T)`.
  - Added `Task_State` (`.Pending`, `.Completed`, `.Failed`), `task_fail`, and `task_state`; `spawn_task` now registers a `fiber_defer` hook so worker `fail(f)` or external cancellation immediately wakes `task_await` callers with `ok == false` instead of deadlocking.
  - Centralized `WASM_ASYNCIFY_STORAGE_SIZE :: #config(CORO_ASYNCIFY_STORAGE_SIZE, 4096)` in `config.odin`, added runtime `Asyncify_Buffer` overflow detection in `asm_wasm32.odin`, and replaced hardcoded `32` slab defaults in `pool.odin` with `STACKS_PER_SLAB`.
- **Contiguous Fiber Slabs, `Chan_Outcome` Enum & Centralized Config (`config.odin`, `types.odin`, `pool.odin`, `api.odin`, `sync/sync.odin`, `examples/wasm_test/main.odin`)**:
  - Replaced per-fiber `new(Fiber)` allocations in `fiber_pool_grow` with contiguous `Fiber_Pool.fiber_slabs: [dynamic][]Fiber` slices (2 heap allocations per slab instead of 33).
  - Centralized `MAX_FIBER_CLEANUPS :: #config(CORO_MAX_FIBER_CLEANUPS, 8)` and `MAX_STACK_BRANCHES :: #config(CORO_MAX_STACK_BRANCHES, 16)` in `config.odin`.
  - Replaced `(value, ok, timed_out)` / `(ok, timed_out)` on `chan_recv_timeout` and `chan_send_timeout` with `Chan_Outcome :: enum u8 { Ok, Closed, Timed_Out }`, and removed unused `FIBER_PAYLOAD_SIZE` `#assert` caps on `with_mutex_val` / `with_semaphore_val`.
  - Added WebAssembly Suite 18 in `examples/wasm_test/main.odin` covering `Chan_Outcome`, event-driven `chan_select_recv`, `with_mutex` abort cleanup, cancelled `Task(T)` wakeup, and large 512B `Event(T)` under Binaryen Asyncify.
- **Zero-Stack-Array Combinators, Fair Round-Robin `chan_select_recv` & Opt-Out `CORO_TEMP_ARENA_SIZE=0` (`config.odin`, `types.odin`, `pool.odin`, `api.odin`, `sync/sync.odin`)**:
  - Replaced `fiber_setup_branches` + `[16]Branch_Desc` stack buffers (~2.8 KB per call) with streaming `fiber_begin_join` / `fiber_spawn_join_child` / `fiber_wait_join` across `sync`/`race`/`rush` `_procs`/`_with` and `chan_select_recv`, supporting unbounded branch/channel counts with 0 heap branch arrays and removing `MAX_STACK_BRANCHES`.
  - Added deterministic round-robin `Scheduler.select_cursor` in `chan_select_recv` so constantly ready channels at index `0` never starve later channels while preserving lockstep replay determinism.
  - Fixed redundant `stored_context = context` overwrites in `spawn_*` / `branch_scoped_desc` that were clobbering per-fiber `temp_allocator` bindings set by `fiber_pool_acquire`.
  - Enabled full `-define:CORO_TEMP_ARENA_SIZE=0` support (reducing `size_of(Fiber)` by 4 KB) with live arena capacity checks and abort-safe `fiber_defer` heap fallback across `event_wait`, `chan_recv_timeout`, `chan_send_timeout`, and `chan_select_recv`.
- **64-Bit Generational Handles, OS-Split VMem Helpers & `-vet-unused -vet-shadowing` Cleanliness (`types.odin`, `pool.odin`, `pool_vmem_*.odin`, `api.odin`, `asm_*.odin`, `sync/sync.odin`, `tools/amalgamate.py`)**:
  - Widened `Fiber_Handle` from `u32` (`u16 index | u16 gen`, 65,535 cap) to `u64` (`u32 index | u32 gen`), eliminating 16-bit slot and generation wraparound limits for long-running servers and 100k+ fiber simulations.
  - Split platform virtual memory slab allocation into `pool_vmem_windows.odin`, `pool_vmem_posix.odin`, and `pool_vmem_other.odin`, unifying the 3 duplicated slab-init loops in `fiber_pool_grow`, fixing `Pool_Stats.total_memory_kb` to include `Fiber` struct slabs alongside stacks, and making core, `sync/`, tests, and examples pass `-vet-unused -vet-shadowing` cleanly across all 7 targets.
  - Changed `fiber_spawn_join_child` to take `^Branch_Desc` and eliminated `[2]Branch_Desc` stack copies in `with_timeout`, `with_signal`, and `with_sticky_signal`.
  - Updated `tools/amalgamate.py` to include `pool_vmem_*.odin`, remove unused `core:math`, and emit clean target-specific imports for `dist/coroutine_wasm32.odin`.
- **Main Demo Audit & Core Engine Hardening (`types.odin`, `scheduler.odin`, `pool.odin`, `api.odin`, `examples/game/`, `tools/web/`)**:
  - Added per-clock pause gating (`Clock_Domain.paused`, `clock_set_paused`, `clock_is_paused`): `clock_advance` skips paused domains and `scheduler_run` retains paused-clock ready fibers in FIFO order so newly spawned or signalled `CLOCK_SIM` fibers never execute while paused.
  - Hardened `fiber_abort_tree` and `scope_cancel` against self-cancellation and ancestor-cancellation via deferred `Scheduler.pending_abort_root` teardown on the scheduler stack, preventing stack use-after-free when a running fiber cancels itself or its own scope/ancestor.
  - Replaced sibling-pointer iteration in `fiber_on_finish` with mutation-safe `abort_coord_siblings` (resilient to `fiber_defer` hooks cancelling or spawning siblings), and aligned `fail(f)` to run LIFO `fiber_defer` hooks before `fiber_on_finish` (matching normal fiber completion).
  - Updated `fiber_calc_stack_usage` on `js_wasm32` to report live Asyncify unwind stack usage (`asyncify_buf.top - base` / `WASM_ASYNCIFY_STORAGE_SIZE`) instead of `0`.
  - Fixed all coroutine & lifecycle bugs uncovered in `examples/game/`: inline `[64]u8` `Floating_Text` payload + per-frame `free_all(context.temp_allocator)` (eliminating dangling temp pointers & format-string hazard), dedicated `CLOCK_PLAYER` for dash/camera-shake (agile in slowmo, frozen on pause), same-frame input-before-scheduler execution order, discrete 10x sub-stepping on `M`, overlapping camera-shake priority & `fiber_defer` cleanup, accurate `PLAYER_BASE_SPEED` & `can_dash` defer restoration, smooth Phase 3 patrol entry (no teleport), safe zero-vector normalization (no `NaN` projectile leaks), `is_stunned`/`shield_alpha` defer cleanups, simultaneous Victory/Game Over guard, full restart state reset, split `entry_native.odin`/`entry_js.odin` for clean `-vet-unused -vet-shadowing`, and interactive Wasm headless test coverage (`H` debugger, `SPACE` dash, `E` EMP, `Q` slowmo, `P`/`N`/`M` pause/stepping, `R` restart, 0 `NaN`/`Inf`).
- **Wasm Zero Native Stack Slabs, Heterogeneous Select Branches, Channel Wakeup Relay & `dist/sync` (`pool.odin`, `pool_vmem_other.odin`, `api.odin`, `sync/sync.odin`, `tools/amalgamate.py`, `examples/dist_test/main.odin`)**:
  - Skipped allocating unused OS stack slabs in `fiber_pool_grow` when `ODIN_ARCH == .wasm32` (saving 1 MB per 32-fiber slab in browsers/Node.js), set `Pool_Stats.stack_size_bytes` to `WASM_ASYNCIFY_STORAGE_SIZE`, and reported `slabs_count` from `fiber_slabs`.
  - Added heterogeneous branch builders `branch_event`, `branch_sticky_event`, `branch_join`, `branch_scope_wait` (core) and `branch_chan_recv`, `branch_chan_send` (`sync/`), enabling zero-polling mixed-type `race` / `sync` across `Channel(A)`, `Channel(B)`, `Event(C)`, `Signal`, `fiber_join`, `scope_wait`, and timers.
  - Hardened `sync/sync.odin` against lost wakeups when an awakened `chan_recv` or `chan_send` waiter (buffered or unbuffered) is aborted via `race`/`chan_select_recv` by relaying wakeups via `fiber_defer`, and fixed unbuffered `chan_try_send` to reject overwriting an occupied rendezvous slot (`ch.count > 0`).
  - Updated `tools/amalgamate.py` to generate and cross-check `dist/sync/sync.odin` alongside `dist/coroutine.odin` and `dist/coroutine_wasm32.odin`, verified end-to-end in `examples/dist_test/main.odin`.
- **Zero-Overhead Trace Hooks, Expanded `fiber_defer` Capacity & Full 206-Test Multi-ISA QEMU Parity (`config.odin`, `types.odin`, `pool.odin`, `scheduler.odin`, `api.odin`, `examples/test_runner/main.odin`)**:
  - Added optional zero-overhead profiler/tracing hooks (`Trace_Event`, `Trace_Hook`, `scheduler_set_trace_hook`) emitting paired lifecycle events (`.Spawn`, `.Resume`, `.Suspend`, `.Complete`, `.Fail`, `.Abort`), plus `fiber_resume_count` and `fiber_defer_count` diagnostics.
  - Raised default `MAX_FIBER_CLEANUPS` from `8` to `16` (configurable via `-define:CORO_MAX_FIBER_CLEANUPS`) to comfortably support deeply nested `with_mutex`, `chan_recv`, and user `fiber_defer` chains.
  - Synced `run_all_coroutine_tests` (153 core tests) and added `run_all_sync_tests` (53 sync tests) into `examples/test_runner/main.odin`, bringing Linux AMD64, ARM64 QEMU, and RISC-V 64 QEMU coverage to 100% parity (`206 / 206` tests).
- **Per-Fiber WebAssembly Shadow Stack Switching (`config.odin`, `types.odin`, `asm_wasm32.odin`, `pool.odin`, `tools/wasm_asyncify.py`, `build.ps1`)**:
  - Eliminated the WebAssembly Asyncify shared `$__stack_pointer` aliasing & abort-leak limitation by allocating a private per-fiber linear-memory shadow stack (`WASM_SHADOW_STACK_SIZE :: #config(CORO_WASM_SHADOW_STACK_SIZE, 8 * 1024)` with 64-byte canary & watermark checks) and swapping `$__stack_pointer` inside uninstrumented `wasm_dispatch_fiber`.
  - Added `tools/wasm_asyncify.py` (integrated into `build.ps1`) to patch `coro_sp.get_sp` / `coro_sp.set_sp` into 1-instruction internal Wasm `global.get`/`global.set $__stack_pointer` functions prior to `wasm-opt --asyncify`, requiring zero JS host changes.
  - Added `fiber_calc_asyncify_usage(f)` alongside native-parity `fiber_calc_stack_usage(f)`, and added WebAssembly Suite 21 verifying 8 interleaved `&local_struct` fibers, stack-local heterogeneous `race` out-pointers, and 500 mid-frame aborts with 0 bytes leaked on the host `$__stack_pointer`.
- **Examples & Demos Modernization (`examples/game/`, `examples/showcase/`, `examples/quest_ai/`, `examples/dist_test/`, `examples/wasm_test/`, `tools/amalgamate.py`)**:
  - Updated `examples/game/main.odin` Coroutine Hierarchy debugger (`H`) to display `fiber_resume_count` and, on `js_wasm32`, live `fiber_calc_asyncify_usage` alongside per-fiber shadow stack telemetry.
  - Modernized `examples/showcase/main.odin` and `examples/quest_ai/main.odin`: replaced cross-frame `fmt.tprintf` slices with inline `Fixed_Text` buffers + per-frame `free_all(context.temp_allocator)`, added `clock_set_paused` gating while paused, switched `F5` to 10 discrete `1/60s` sub-steps, moved input processing before `scheduler_step`, converted Station 7 (`channel_consumer_fiber`) to heterogeneous `race` + `sync.branch_chan_recv` with stack-local out-pointers, converted `turret_defense_fiber` and `knight_action_whirlwind` to abort-safe `sync.with_semaphore`, fixed orphaned `Crystal Minion Task` in `sentinel_phase2_fiber` (`scope = &s.phase_scope`), and added `fiber_defer` state cleanup across stations/phases.
  - Expanded `examples/dist_test/main.odin` to verify stack-local heterogeneous `race` out-pointers, `clock_set_paused`, and `scheduler_set_trace_hook`, removed unused `core:mem` import from `tools/amalgamate.py` `SYNC_IMPORTS`, and resolved all `-vet-unused -vet-shadowing` issues across all examples.
- **Tests, Distributions & Docs**:
  - Expanded native unit tests to `206` (`153` core + `53` sync, passing both at default 4 KB arena and `-define:CORO_TEMP_ARENA_SIZE=0` with 0 leaks), verified all `206 / 206` tests at runtime on Windows AMD64, Linux AMD64 (WSL2), ARM64 (QEMU), and RISC-V 64 (QEMU), and passed `21 / 21` WebAssembly suites + 1,000-frame interactive headless Wasm game.

## [Odin `dev-2026-11:89246b0ad` Inline ASM Upgrade & Caller-Saved FP/SIMD Hardening] - 2026-11-21

### Changed
- **Mandatory `#align_stack` & Entry-Defined SP Adoption (`asm_amd64.odin`, `asm_arm64.odin`, `asm_riscv64.odin`)**:
  - Added `#align_stack` and explicit `#volatile` to `fiber_context_switch` across AMD64 (Win64 & SysV), ARM64, and RISC-V 64 as required by Odin commit `1590b7635` (also protecting SysV AMD64 against red-zone overwrites).
  - Removed now-redundant `#preserve %rsp` / `#preserve %sp` declarations from `fiber_context_switch`, `get_rsp`, and `get_sp` (Odin commit `b40bb67ea` automatically defines `%rsp`/`%sp` on entry and marks it exit-live).
  - Removed redundant manually-declared written-register clobbers (`%r12..%r15`, `%xmm6..%xmm15`) on AMD64 (automatically inferred by Odin commit `88a10c973`).
  - Migrated System V AMD64 stack swap from `xchg %rsp, %rsi` to direct `mov %rsp, to_rsp`; updated Windows x64 swap to `xchg %rsp, to_rsp` (auto-tied via Odin commit `b3ea5193a`, avoiding the `CLOBBER_REGS_NAMED` `ClobberReg_RSP` dead-write false positive past `add %rsp, 160`).
- **ARM64 `#byte` Reduction (`11 -> 8`) via High-Level SP & `#pre`/`#post` Writeback (`asm_arm64.odin`)**:
  - Eliminated all 3 `#byte` `%sp`-modifying instructions (`sub sp, sp, #160`, `mov sp, x1`, `add sp, sp, #160`) now that Odin commits `f6c1e779f` and `88a10c973` no longer emit `~{sp}` clobbers.
  - Adopted Odin commit `ea2a0509e` writeback syntax (`stp %x29, %x30, #pre [%sp - 160]`, `mov %sp, to_rsp`, `ldp %x29, %x30, #post [%sp + 160]`), preserving the exact 160-byte frame layout while removing 2 instructions per context switch.
  - Only the 8 `stp`/`ldp d8..d15` instructions on ARM64 and 24 `fsd`/`fld fs0..fs11` instructions on RISC-V 64 remain `#byte` due to upstream register-table / typing limitations in Odin `89246b0ad`.
- **Full Caller-Saved Float/SIMD Clobbers Under Aggressive Single-Module Inlining (`asm_amd64.odin`, `asm_riscv64.odin`)**:
  - Added `#clobber %xmm0..%xmm5` (Windows x64), `#clobber %xmm0..%xmm15` (System V AMD64), and `#clobber %ft0..%ft11`, `%fa0..%fa7` (RISC-V 64) to `fiber_context_switch`.
  - Fixed floating-point register corruption across aggressively inlined `yield`/`wait_steps` calls under `-o:speed -use-single-module` and `-o:aggressive`.
- **Regenerated Amalgamated Distributions (`dist/coroutine.odin`, `dist/coroutine_wasm32.odin`)**:
  - Rebuilt standalone drop-ins via `.\build.ps1 amalgamate` and verified via `.\build.ps1 test-dist`.
- **Documentation Suite Audit & Update (All 36 `docs/` Files + `README.md`)**:
  - Audited and aligned all guides, technical specs, tutorials, WebAssembly docs, `ARCHITECTURE.md`, `COOKBOOK.md`, `REPORTS.md`, `DISTRIBUTION.md`, `ASM.md`, and `README.md` with the current public API and Odin `dev-2026-11:89246b0ad`.
  - Fixed inverted return-value checks for `with_signal` (`interrupted: bool`) and `with_timeout` (`timed_out: bool`), 2-value `task_await` returns, `fiber_cleanup_pop` semantics (unregisters without executing), `fallback`/`fallback_with` return signatures, and removed legacy `tween`/`wait_ticker`/`PAGE_GUARD`/`.Finished` references.
  - Rewrote `docs/wasm/01_ARCHITECTURE_ASYNCIFY.md` to match `Asyncify_Buffer`, `wasm_yield_leaf`, and `wasm_dispatch_fiber` in `types.odin` and `asm_wasm32.odin`; synced `docs/wasm/03_BROWSER_GAME_AND_CANVAS.md` controls/exports and test counts (`187` native tests, `17` Wasm suites) across all docs.
  - Fixed broken relative/absolute links (verified 0 broken links across all 37 markdown files).

## [Concurrency Hardening & Developer Ergonomics (Epic Verse Alignment)] - 2026-10-17

### Added
- **Monotonic Coordinator Generation Tracking (`types.odin`, `scheduler.odin`, `api.odin`)**:
  - Added `id: u64` to `Join_Coordinator` and `join_coord_id: u64` to `Fiber`.
  - Guarantees that when `rush` unblocks a parent fiber, background loser branches cannot accidentally match or corrupt subsequent `sync`, `race`, or `rush` calls on `parent.active_coord`.
  - Airtight detachment: winning `rush` arms detach losers by clearing `join_coord = nil` and `join_coord_id = 0`, cleanly transitioning losers into scope-bound background tasks.
- **LIFO Multi-Hook Defer Stack (`types.odin`, `api.odin`, `scheduler.odin`, `sync/sync.odin`)**:
  - Upgraded fiber cleanups to a native 8-slot LIFO defer stack (`MAX_FIBER_CLEANUPS :: 8`) with zero runtime heap allocation.
  - Added `fiber_defer(f, proc, user_data)` (with typed pointer overload) and `fiber_cleanup_pop(f)`.
  - Executed in strict reverse order (LIFO) upon normal completion, failure, or cancellation.
  - Replaced ad-hoc `SCOPED_CLEANUP_MAGIC` linked-list chaining across `sync/sync.odin` (`with_mutex`, `with_semaphore`, and `chan_send`) with standard `fiber_defer` and `fiber_cleanup_pop`.
- **Shared-Context Combinator Helpers (`api.odin`)**:
  - Added `sync_with(f, ctx, ..procs)`, `race_with(f, ctx, ..procs)`, `rush_with(f, ctx, ..procs)`, and `fallback_with(f, ctx, ..procs)`.
  - Allows passing a shared context pointer (e.g. `^Boss`, `^Player`) directly to a list of typed procedures without wrapping each call in `branch(...)`.
- **Direct Procedure Combinator Overloads (`api.odin`)**:
  - Overloaded `sync`, `race`, `rush`, and `fallback` to accept parameterless `..proc(f: ^Fiber)` directly alongside `..Branch_Desc`.
- **Synchronization Branch Constructors (`api.odin`)**:
  - Added `branch_signal(sig, name)` and `branch_sticky_signal(sig, name)`: creates pre-built `Branch_Desc` awaiting signals.
  - Added `branch_wait(seconds, name, clock)`: creates a pre-built `Branch_Desc` timer arm for `race` or `rush`.
- **Interruptible Task Combinators (`with_signal` / `with_sticky_signal`) (`api.odin`)**:
  - Added `with_signal(f, sig, task)` and `with_sticky_signal(f, sig, task)` (with pointer, value, nil, and descriptor overloads): runs a task until completion or aborts immediately if `sig` fires, returning `interrupted: bool`.
- **Verse-Style Typed Task Futures (`Task(T)` & `spawn_task`) (`types.odin`, `api.odin`)**:
  - Added lightweight, True-ZII `Task(T)` container backed by `Sticky_Event(T)` with zero dynamic allocation.
  - Added `task_init(&task)`, `task_complete(f/sched, &task, value)`, `task_await(f, &task)`, and `task_is_ready(&task)`.
  - Added `spawn_task(sched/f, &task, entry)` overloads: worker entry procedure returns `R` directly; engine automatically initializes the task, attaches the fiber handle, and delivers the result on completion.
  - Guarantees immediate delivery even if awaited long after the worker fiber has finished and recycled.
- **Unified `Sticky_Signal` as `Sticky_Event(struct{})` (`types.odin`, `api.odin`)**:
  - Aliased `Sticky_Signal :: Sticky_Event(struct{})` (mirroring `Signal :: Event(struct{})`), eliminating redundant wait queue logic and enabling uniform `sticky_event_is_set`, `sticky_event_reset`, `sticky_event_waiter_count`, and `sticky_emit`.
- **Standalone QEMU Test Runner (`run_all_coroutine_tests`) (`coroutine_test.odin`)**:
  - Updated `run_all_coroutine_tests` to an array-driven test dispatcher returning `(passed, failed)` and supporting optional `verbose` logging.
  - Runs all 138 core tests across native host and ARM64 / RISC-V 64 QEMU emulation harnesses.
- **Unit Test Coverage Expansion (182 -> 187 Native Tests)**:
  - Added Tests 169–173 in `coroutine_test.odin`: `test_rush_active_coord_reentry`, `test_fiber_defer_lifo_order`, `test_combinator_with_helpers`, `test_branch_primitives_and_with_signal`, and `test_task_future`.
- **Repository-Wide Example Modernization (`examples/game`, `examples/quest_ai`, `examples/showcase`, `examples/bench`, `examples/dist_test`, `examples/wasm_test`)**:
  - `examples/game/main.odin`: Modernized Boss Phase 1, Phase 2, and Phase 3 attack loops with `race_with(f, b, ...)`, `sync_with(f, b, ...)`, and `with_signal(f, &b.stun_signal, ...)`; added `fiber_defer` and `fiber_cleanup_pop` to `player_dash_coroutine` for guaranteed state restoration.
  - `examples/quest_ai/main.odin`: Decomposed Knight AI decision tree into modular procs dispatched via `fallback_with(f, k, ...)`; refactored Outpost Quest objective tree via `rush_with(f, q, ...)`.
  - `examples/showcase/main.odin`: Converted Capture Contest to `with_timeout(3.5)`; modernized Async Compute Lab to typed `Task(int)` spawned via `spawn_task` and awaited via `task_await`.
  - `examples/bench/main.odin`: Modernized `bench_structured_tree_churn` to `sync_with(f, c, ...)`, verifying 10,000 structured trees in 237 ms with zero dynamic allocations.
  - `examples/dist_test/main.odin`: Added verification for `spawn_task`, `task_await`, and `sync_with` on the amalgamated single-file library.
  - `examples/wasm_test/main.odin`: Refactored Test 4 (`sync_with`), Test 5 (`race_with`), Test 10 (`sync_with` + `branch_signal`), Test 12 (`with_signal` + `sync_with`), and Test 13 (`rush_with`).
- **WebAssembly Test Suite Expansion (16 -> 17 Test Suites) (`examples/wasm_test/main.odin`)**:
  - Added Test 17: `test_task_futures_and_combinator_helpers` verifying `spawn_task`, `task_await`, `sync_with`, and `with_signal` under Binaryen Asyncify execution.
  - Updated `docs/wasm/04_TESTING_AND_AUTOMATION.md` and `docs/wasm/README.md`.
- **Documentation Suite Modernization (`docs/`)**:
  - `docs/ARCHITECTURE.md`: Documented monotonic `coord.id` tracking, `child.join_coord_id`, and the 8-slot LIFO defer stack (`MAX_FIBER_CLEANUPS`).
  - `docs/tech/TECH_CONCURRENCY.md` & `docs/tech/TECH_PRIMITIVES.md`: Updated combinator matrix and primitive specifications for `sync_with`, `race_with`, `rush_with`, `fallback_with`, `with_signal`, `Task(T)` / `spawn_task`, and `fiber_defer`.
  - `docs/guides/GUIDE_FOOTGUNS.md`: Added Footgun 15 ("Relying on Native Odin defer for External Fiber Cancellation / Abort").
  - `docs/COOKBOOK.md`: Modernized Recipe 16 (`with_signal`) and added Recipe 18 (`Task(T)` futures) and Recipe 19 (`fiber_defer`).
  - `docs/tutorials/`: Modernized Tutorials 03, 04, 05, and 06 with shared-context combinator helpers, typed task futures, and interruption defer semantics.

## [Verse Structured Concurrency Realignment & Latched Primitives] - 2026-10-17

### Added
- **Scope-Bound Fire-and-Forget Subtasks (`branch_scoped`) (`api.odin`, `scheduler.odin`)**:
  - Implemented Verse-style `branch:` semantics via `branch_scoped(f, entry, ...)`: spawns a concurrent subtask linked directly into `f`'s active fiber hierarchy without suspending the caller.
  - Subtask automatically runs in the background concurrently with parent; auto-cancelled and reclaimed bottom-up if the parent finishes, fails, or is cancelled.
  - Overloaded for raw procedures (`proc(child: ^Fiber)`), pointers (`proc(child: ^Fiber, data: ^T)`), values (`proc(child: ^Fiber, data: T)`), and pre-built `Branch_Desc`.
- **Latched State Broadcast Primitives (`Sticky_Event(T)` / `Sticky_Signal`) (`types.odin`, `api.odin`)**:
  - Added `Sticky_Event(T)` and `Sticky_Signal`: caches the emitted value so that late awaiters unblock immediately without deadlocking or missing past phase transitions.
  - Added `sticky_event_wait`, `sticky_event_emit`, `sticky_event_peek`, `sticky_event_is_set`, `sticky_event_reset`, `sticky_signal_wait`, `sticky_signal_emit`, `sticky_signal_is_set`, and `sticky_signal_reset` (with overloaded `sticky_emit` and `sticky_wait`).
- **Cooperative In-Frame Yield (`yield_now`) (`api.odin`)**:
  - Added `yield_now(f)` matching Verse `Sleep(0.0)`: yields the fiber's timeslice to other ready fibers within the current simulation tick/frame and re-enqueues itself without advancing the clock step.

### Changed
- **Verse-Aligned `race` & `rush` (`scheduler.odin`, `types.odin`, `api.odin`)**:
  - Unified `race(f, ..branches)` with Verse specification: the first branch to SUCCEED (`.Completed`) wins and immediately cancels remaining sibling branches. Branches that call `fail(f)` drop out without winning; if all branches fail, `race` returns `-1`.
  - Realigned `rush(f, ..branches)` to strict Verse semantics: the first arm to succeed unblocks the parent immediately, while **losers continue running detached in the background** without being cancelled (auto-aborted if parent finishes).
  - Eliminates the artificial `race_success` distinction, giving `race` and `rush` standard, symmetrical Verse concurrency semantics.
- **Documentation & Scripting Guidelines**:
  - Added Footgun 14 to `docs/guides/GUIDE_FOOTGUNS.md` and warning callouts to `docs/tutorials/04_advanced_control_flow.md` and `README.md` clarifying that `yield_now` is for in-frame CPU computational slicing, while `yield` is required for frame-boundary state polling.
- **Example Logic Updates & Verse Visualizations**:
  - `examples/quest_ai/main.odin`: Realigned Zone 2 logic to demonstrate true Verse `rush` background continuation; winning the primary objective unblocks the quest director into a 4-second bonus window where secondary tasks (Terminal hacking, Sentry defeat) visibly continue running in the background as live child fibers.
  - `examples/showcase/main.odin`: Added `branch_scoped` parent-bound ambient swirl FX to Station 1 (Ritual Circle) and `Sticky_Signal` emergency lockdown latching to Station 4 (Beacon).
  - `examples/dist_test/main.odin`: Added automated verification for `branch_scoped` and `Sticky_Signal` via amalgamated `dist/coroutine.odin`.
- **WebAssembly Test Suite Expansion (12 -> 16 Suites) (`examples/wasm_test/main.odin`, `docs/wasm/`)**:
  - Added Test 13 (`test_verse_rush_losers_continue`), Test 14 (`test_branch_scoped_background_and_parent_abort`), Test 15 (`test_sticky_event_and_signal`), and Test 16 (`test_yield_now_same_tick`).
  - All 16 automated WebAssembly suites pass with 0 failures under Binaryen Asyncify and Node.js.

## [Matrix Slow-Mo & Recovery Bar Game Update] - 2026-10-17

### Added
- **Matrix-Style Bullet-Time Slow-Mo in Boss Fight Demo (`examples/game/main.odin`)**:
  - Right Mouse Button (RMB, with keyboard fallback Shift/Q) triggers non-linear Matrix bullet-time slow-motion.
  - Recovery bar HUD (`slowmo_charge` / `slowmo_max`) draining at 28 units/s and recharging at 22 units/s.
  - Non-linear slowdown curve ($t^{1.5}$) tracking the recovery bar: maximum world slowdown ($15\%$ speed) at full bar, smoothly easing back to normal ($100\%$) as the charge depletes.
  - Player agility advantage: player movement receives up to $+35\%$ speed multiplier while world is in slow-mo, achieving $>8.6\times$ relative velocity advantage over enemy bullets.
  - Real-time player dash: dedicated exclusively to Spacebar (and K) running on `CLOCK_REAL`.
  - Matrix visual feedback: fullscreen digital matrix tint, player ghost afterimage trails, and bullet-time projectile wakes.
- **Web Canvas Mouse Mapping (`tools/web/raylib_canvas.js`)**:
  - Mapped DOM mouse button events (0=Left, 1=Middle, 2=Right) to Raylib's `MouseButton` enum (0=Left, 1=Right, 2=Middle).

## [Minimal Verse/SkookumScript Core Refactoring & Indexed Clock_Domain Architecture] - 2026-10-17

### Changed
- **Indexed `Clock_Domain` Architecture (`config.odin`, `types.odin`, `scheduler.odin`, `api.odin`)**:
  - Replaced the hardcoded 3-tier `Scheduler_Clock` (`Real_Time`, `Sim_Scaled`, `Fixed_Tick`) and duplicate `*_real` / `*_ticks` procedures with a generic array `clocks: [MAX_CLOCKS]Clock_Domain` (`MAX_CLOCKS :: 4`; `CLOCK_SIM = 0`, `CLOCK_REAL = 1`, `CLOCK_PHYS = 2`, `CLOCK_INHERIT = -1`).
  - Each `Clock_Domain` encapsulates its own `time: f64`, `dt: f32`, `steps: u64`, `time_scale: f32`, `timer_heap: [dynamic]^Fiber`, and `step_waiters: [dynamic]^Fiber`.
  - Every `Fiber` carries `clock_id: Clock_ID`. Child branches in `sync()`, `race()`, `rush()`, and `fallback()` automatically inherit `parent.clock_id` unless overridden via `branch(..., clock = ...)`.
  - Unified timing & yielding API: `yield(f)`, `wait(f, seconds)`, `wait_steps(f, count)`, `ticker_wait(f, interval)` / `wait_ticker(f, interval)`, `ticker_rebase(f)`, `delta_time(f)`, `current_time(f)`, `current_step(f)`, `clock_advance(sched, clock_id, dt)`, `clock_set_scale(sched, clock_id, scale)`, `scheduler_run(sched)`, and `scheduler_step(sched, dt)`.
- **Unified `Signal` and `Event(T)` (`types.odin`, `api.odin`)**:
  - Defined `Signal :: Event(struct{})` as a zero-size payload specialization of `Event(T)`, unifying 1-to-many broadcast notifications.
  - Overloaded `event_emit(sched, &ev)` (0-arg for `Signal`) and `event_emit(sched, &ev, payload)` (for `Event(T)`), alongside `signal_init`, `signal_destroy`, `signal_wait`, `signal_emit`, and `signal_waiter_count`.
- **Simplified `Async_Token` (`types.odin`, `api.odin`)**:
  - Reduced `Async_Token` to `{ state: Async_State }` and simplified `await_async(f, token)` to a lightweight atomic check loop yielding one step per check, removing `Scheduler.condition_waiters`.
- **Extracted Optional `coroutine/sync` Subpackage (`sync/sync.odin`, `sync/sync_test.odin`)**:
  - Moved Go/OS-style concurrency primitives (`Fiber_Mutex`, `with_mutex`, `Fiber_Semaphore`, `with_semaphore`, `Channel(T)`, `chan_send`, `chan_recv`, `chan_try_send`, `chan_try_recv`, `chan_select_recv`) out of the core package into `sync/` (`package coroutine_sync`).

### Removed
- **Cut Gameplay & Redundant Primitives from Core (`api.odin`, `types.odin`, `scheduler.odin`)**:
  - Removed `tween_*` and `ease_*` easing helpers from core (moved to local user helpers in examples).
  - Removed `Phase_Director` state-machine wrapper from core (replaced by direct `Fiber_Scope` usage in examples).
  - Removed `Generator(T)` from core (which previously spun up an entire `Scheduler` instance per generator).
  - Removed external `Ticker` struct (`ticker_init`) in favor of the fiber-embedded zero-drift `ticker_wait(f, interval)`.
  - Removed per-frame closure polling `wait_until` / `wait_while` (+ `_timeout` overloads) and `Scheduler.condition_waiters`.
  - Removed `Fiber_Latch` (redundant with structured `sync()` and `scope_wait()`).
  - Removed `simulate_until` test helper from public API.
  - Reduced `api.odin` from ~1,452 lines to 531 lines (~63% reduction) and amalgamated `dist/coroutine.odin` to 2,783 lines.

## [WebAssembly Shadow-Stack Hardening & WASM_LIMITATIONS Architecture] - 2026-09-08

### Added
- **Built-in Fiber-Owned Zero-Drift Ticker (`api.odin`, `types.odin`, `pool.odin`)**:
  - Added `ticker_interval: f32`, `ticker_next_wake: f64`, and `ticker_use_real: bool` directly inside the `Fiber` struct in persistent pool/heap memory.
  - Added overloaded `coroutine.ticker_wait(f, interval_seconds, use_real_time)` and convenience alias `coroutine.wait_ticker(f, interval_seconds)` requiring zero stack struct allocations (`&Ticker`).
  - Added `coroutine.ticker_rebase(f)` to reset schedule timestamps cleanly after interruptions, stuns, or animation state switches.
  - Fully immune to WebAssembly Asyncify shadow-stack clobbering across interleaved fibers.
- **Unit Test 189 (`coroutine_test.odin`)**:
  - Validated fiber-owned ticker zero-drift timing, multi-fiber non-interference, and clean rebase behavior with 189/189 tests passing.
- **WebAssembly Limitations & Roadmap Documentation (`docs/wasm/02_MEMORY_AND_LIMITATIONS.md`)**:
  - Detailed the dual-stack model (VM execution stack vs LLVM shadow stack in linear memory).
  - Documented root causes of shadow-stack aliasing across Asyncify yields.
  - Codified the **3 Golden Rules of WebAssembly Coroutines**.
  - Documented the multi-phase architectural roadmap towards native Wasm Stack-Switching (`cont.new`, `suspend`, `resume`).

## [WebAssembly Test Suite Expansion & EMP Fiber Fix] - 2026-09-08

### Added
- **WebAssembly Comprehensive Test Suite Expansion (`examples/wasm_test/main.odin`)**:
  - Expanded test suite from 8 to 12 automated test suites:
    - **Test 9**: Signal primitives (`signal_wait`, `signal_emit`) with multi-waiter FIFO scheduling and waiter tracking.
    - **Test 10**: Deep nested `race()` cancelling an active `sync()` combinator containing multiple child attack fibers.
    - **Test 11**: Ticker zero-drift timing precision and safe cancellation via `Fiber_Scope`.
    - **Test 12**: Multi-round EMP stun AI fuzzing simulating rapid signal emissions across 300 frames with zero leaked fibers or heap nodes.
  - All 12 WebAssembly test suites passing with 0 failures under `.\build.ps1 test-wasm`.

### Fixed
- **Boss EMP Attack Fiber Multiplication & Projectile Spam (`examples/game/main.odin`, `api.odin`)**:
  - **Root Cause**: On WebAssembly with Asyncify, all fibers share the single Odin runtime shadow stack in linear memory. When fibers yield, local structs whose addresses are taken (such as `ticker: coroutine.Ticker`) can be overwritten by other interleaved fibers (e.g. camera shake, floating text, particles). When the attack fiber woke from stun, `ticker.interval` was zeroed out, causing `ticker_wait` to fail the forward-time check and fall back to `yield_frame(f)`, firing 8 bullets every single frame (500+ projectiles runaway burst).
  - **Remedy**: Replaced stack-allocated `Ticker` instances in `boss_spiral_shoot_subloop` and `boss_targeted_burst_subloop` with direct primitive `coroutine.wait(f, seconds)` calls where wake times are persisted directly in `f.wake_time` on the heap/pool.
  - **Defense-in-Depth**: Hardened `ticker_wait` in `api.odin` to clamp `t.interval = max(0.0001, t.interval)`, eliminating 1-frame busy spins if an uninitialized or zero-interval ticker is encountered.
  - **Player EMP Guard**: Added `emp_cooldown: f32` (1.8s) to `Player` in `examples/game/main.odin` preventing runaway stun spamming while the boss is already in stun recovery.

### Added
- **Browser-Playable Boss Fight Port (`examples/game/main.odin`)**:
  - Ported native Raylib boss battle demo to `js_wasm32` WebAssembly using Binaryen Asyncify and HTML5 Canvas 2D.
  - Exported browser lifecycle hooks (`game_wasm_init`, `game_wasm_step`, `game_wasm_destroy`) driven via `requestAnimationFrame` on `<canvas>` (1280x720) while preserving desktop native blocking loop for Win64/Linux.
- **Lightweight Zero-C HTML5 Canvas 2D Raylib Adapter (`tools/web/raylib_canvas.js`)**:
  - Implemented all 21 Raylib C ABI imports directly in JavaScript (`DrawCircleV`, `DrawLine`, `DrawRectangle`, `DrawText`, keyboard/mouse input dispatch) with zero external C libraries or Emscripten SDK dependencies.
- **Web Game Build Pipeline & Headless Automation (`build.ps1`, `tools/web/test_headless_game.js`)**:
  - Added `.\build.ps1 web-game`: compiles `examples/game` -> `build/web/game.wasm`, optimizes with `wasm-opt --asyncify` -> `build/web/game_opt.wasm`, and packages `index.html` + `raylib_canvas.js`.
  - Added `.\build.ps1 test-web-game`: headless Node.js runner simulating 1000 frames (16.7 seconds @ 60 FPS, 300,000+ draw calls) with zero traps, leaks, or desyncs.
  - Added `.\build.ps1 run-web-game`: builds bundle and spawns local HTTP server on `http://localhost:8080`.
- **Ergonomic Browser Control Scheme & Restart Support**:
  - Replaced browser-conflicting function keys with clean letter bindings: `P` / `Escape` (pause/resume), `H` / `Tab` (toggle hierarchy inspector), `N` / `.` (step 1 frame), `M` (step 10 frames), `E` / `B` (EMP stun).
  - Added dedicated restart action (`R` / `Enter`) both during active gameplay and on Game Over/Victory screens.
  - Added browser default event prevention for `Space`, `Tab`, `F1-F5`, and arrow keys in `raylib_canvas.js` to prevent viewport scrolling or focus loss.

### Fixed
- **Deterministic Math Random in WebAssembly Coroutines (`examples/game/main.odin`)**:
  - Replaced Odin `core:math/rand` inside fiber routines (`camera_shake_coroutine`, particle spawns, damage numbers) with lightweight deterministic LCG `game_rand_f32`.
  - Eliminated `RuntimeError: memory access out of bounds` caused by `runtime.default_random_generator_proc` accessing `@(thread_local)` TLS state or crossing into foreign JS `rand_bytes` during Asyncify unwinding/rewinding.
  - Added defensive null guard in `trigger_camera_shake`.

## [WebAssembly (js_wasm32) Asyncify Multi-Platform Architecture] - 2026-09-07

### Added
- **WebAssembly Target Architecture (`js_wasm32`)**:
  - Implemented full WebAssembly support using Binaryen Asyncify post-processing pipeline (`asm_wasm32.odin`), expanding the multi-ISA runtime to 7 architectures (`windows_amd64`, `linux_amd64`, `darwin_amd64`, `darwin_arm64`, `linux_arm64`, `linux_riscv64`, `js_wasm32`).
  - Implemented symmetric unwinding/rewinding leaf yield protocol (`wasm_yield_leaf`): calling `_raw_start_unwind` during execution to initiate call-stack unwinding, and `_raw_stop_rewind` upon reentry during rewind to cleanly resume forward execution with zero stack corruption.
  - Retained 100% straight-line structured concurrency API parity across all primitives: `wait`, `wait_frames`, `sync`, `race`, unbuffered CSP channels, multi-domain clocks (`time_scale`, `real_time`), and intrusive `Fiber_Scope` hierarchical cancellation.
  - Zero C/POSIX or Emscripten runtime dependencies; purely native Odin runtime environment powered by Node.js runner (`tools/run_wasm.js`).
- **WebAssembly Test Suite & Automation (`examples/wasm_test/main.odin`)**:
  - Authored comprehensive 8-suite headless WebAssembly test runner covering minimal spawn, local variable stack preservation across yields, concurrent interleaving, structured `sync()`, structured `race()`, unbuffered CSP channels, multi-domain clocks, and group scope aborts (8/8 suites passing, 0 failures).
  - Integrated `wasm`, `check-wasm`, and `test-wasm` tasks into `build.ps1`.
  - Expanded `check-all` verification matrix to all 7 target architectures.
- **Single-File Amalgamation & Vendoring Support (`tools/amalgamate.py`)**:
  - Updated amalgamation pipeline to generate dual standalone drop-ins in `dist/`: `dist/coroutine.odin` (native multi-ISA: AMD64, ARM64, RISC-V 64 with `#+build !js`) and `dist/coroutine_wasm32.odin` (WebAssembly with `#+build wasm32`), verified with `odin check -no-entry-point` across all 7 targets.

## [Root Package Layout & Amalgamated Single-File Distribution] - 2026-09-05

### Added
- **Root Package Architecture for Direct Odin Vendoring**:
  - Relocated library source files from `src/coroutine/` directly into the repository root (`package coroutine`), enabling direct cloning into `<odin>/shared/coroutine` for instant `import "shared:coroutine"` support across projects.
  - Relocated game showcase demo to [`examples/game/main.odin`](examples/game/main.odin) to keep root cleanly dedicated to `package coroutine`.
  - Updated all example targets ([`examples/bench`](examples/bench/main.odin), [`examples/quest_ai`](examples/quest_ai/main.odin), [`examples/showcase`](examples/showcase/main.odin), [`examples/test_runner`](examples/test_runner/main.odin), [`examples/game`](examples/game/main.odin)) to import `"../.."`.
- **Standalone Single-File Amalgamation Generator ([`tools/amalgamate.py`](tools/amalgamate.py))**:
  - Automated tool combining the 8 core library files (`config.odin`, `types.odin`, `asm_amd64.odin`, `asm_arm64.odin`, `asm_riscv64.odin`, `pool.odin`, `scheduler.odin`, `api.odin`) into a single zero-dependency drop-in at [`dist/coroutine.odin`](dist/coroutine.odin) (4,686 lines).
  - Automatically deduplicates and unifies top-level imports (`base:runtime`, `base:intrinsics`, `core:fmt`, `core:time`, `core:math`, `core:mem`, `core:sys/windows`, `core:sys/posix`) and injects release metadata headers.
  - Built-in multi-ISA verification (`--all-targets`) verifying `odin check -no-entry-point` across all 5 target systems (`windows_amd64`, `linux_amd64`, `darwin_arm64`, `linux_arm64`, `linux_riscv64`).
- **Distribution Smoke Test Harness ([`examples/dist_test/main.odin`](examples/dist_test/main.odin))**:
  - Added standalone verification application importing `dist/coroutine.odin` and exercising fiber lifecycle, CSP channels, and scheduler steps.
- **Build Script Integration ([`build.ps1`](build.ps1))**:
  - Added `amalgamate`, `dist`, and `test-dist` actions to [`build.ps1`](build.ps1).
- **LLVM Optimization & Context Switch Analysis Documentation**:
  - Documented Footgun 12 in [`docs/guides/GUIDE_FOOTGUNS.md`](docs/guides/GUIDE_FOOTGUNS.md): Inlining across fiber context switches under `-o:speed -use-single-module`, explaining why small yield procedures must retain distinct non-inlined ABI boundaries to force spilling caller-saved SIMD registers (`%xmm0..%xmm5`).
  - Added Section 9 to [`docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md`](docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md) detailing Odin compiler register clobber table internals (`src/asm_tables_amd64.cpp:308-328`), where AMD64 clobber bitmasks track only `xmm0` and ignore higher vector registers, necessitating standard procedural call boundaries.

## [Inline ASM Deep-Dive & #byte Production Standard Baseline] - 2026-09-04

### Added
- **Odin Inline Assembly Specification & Compiler Internals ([`docs/ASM.md`](docs/ASM.md), [`docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md`](docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md))**:
  - Documented complete inline assembly AST rules, undocumented directives (`#no_init`, `#skip`, `#align`), and two-step scratch parameter bindings.
  - Documented LLVM backend lowering constraints: missing label colon in AMD64/RISC-V (`llvm_backend_asm.cpp:390`), base pointer/frame pointer interference on `%rsp`/`%rbp`, and vector register early-clobber (`=&`) corruption on scratch XMM stores.
  - Completed git archaeology across project commit history and Odin compiler PRs (PR #7444 `bill/asm-cfg`, sub-register width lattice `in_w`, and backward liveness checks).
  - Confirmed `#byte` machine code arrays as the canonical production standard for the coroutine runtime across all 6 target architectures (`windows_amd64`, `linux_amd64`, `darwin_amd64`, `darwin_arm64`, `linux_arm64`, `linux_riscv64`), maintaining 100% test pass (188/188 tests) and 16.89ns context switch latency.
- **Full Odin Inline Assembly Specification ([`docs/ASM.md`](docs/ASM.md))**:
  - Authored authoritative manual covering all undocumented compiler directives (`#no_init`, `#skip`, `#align`, `#byte`), scratch parameter bindings, width-views, template directives (`#volatile`, `#align_stack`, `#pure`), and clobber constraints.
  - Documented SSA dataflow analysis (`seed_regs`, `seed_pm`, `in_w` lattice), CFG block construction, terminal instructions, and template exit requirements (`check_asm_cfg_block_leaves`).
- **Comprehensive Compiler Internals & Option A Specification ([`docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md`](docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md))**:
  - Identified 6 root-cause blockers across frontend SSA (`check_asm_cfg_report_undef_reg`, `in_w[0]`), frontend CFG (terminal calls, dead writes), backend codegen (missing label colon in `llvm_backend_asm.cpp:390`), and LLVM machine function register allocation (frame pointer interference on `%rbp`).
  - Documented Option A pure high-level inline assembly context switch pattern with named labels and direct mnemonics, along with the upstream Odin compiler patch.
  - Documented why `#byte` remains the optimal production standard for stock Odin compiler compatibility.

## [High-Level Inline Assembly Stack Readers & Compiler SSA Analysis] - 2026-09-02

### Added
- **High-Level Inline ASM Stack Pointer Extractors (`src/coroutine/asm_amd64.odin`, `asm_arm64.odin`, `asm_riscv64.odin`)**:
  - Implemented `get_rsp` for AMD64 using high-level inline assembly `lea sp, [%rsp]`.
  - Implemented `get_sp` for ARM64 using high-level inline assembly `add sp, %sp, 0`.
  - Implemented `get_sp` for RISC-V 64 using high-level inline assembly `addi sp, %sp, 0`.
- **Test 188: High-Level Inline Assembly Stack and Register Extractors (`src/coroutine/coroutine_test.odin`)**:
  - Added unit test verifying active stack pointer retrieval and self-identity register access across all supported architectures.
- **Deep Compiler SSA & Width Lattice Documentation (`docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md`)**:
  - Detailed the sub-register bit-width lattice initialization (`in_w[0] = {}`) in `check_asm_cfg.cpp`.
  - Documented why `#no_init` seeds entry register masks but still triggers bit-width errors for unproduced 64-bit physical registers.
  - Documented effective address (`lea`) mechanics vs general register moves.

## [Multi-ISA Return Trampoline Architecture & QEMU Validation (`arm64`, `riscv64`, `amd64`)] - 2026-09-02

### Added
- **Link Register Return Trampolines (`src/coroutine/asm_arm64.odin`, `asm_riscv64.odin`)**:
  - **ARM64**: Integrated `bl .switch_body` (+8B) and `b .switch_done` (+108B) trampoline to dynamically set Link Register (`x30`) to the post-switch instruction on inlined assembly templates.
  - **RISC-V 64**: Integrated `jal ra, +8` (+8B) and `j .switch_done` (+224B) trampoline to dynamically set Link Register (`ra`) to the post-switch instruction on inlined assembly templates.
- **Exhaustive Caller-Saved Register Clobber Directives (`src/coroutine/asm_arm64.odin`, `asm_riscv64.odin`)**:
  - Added individual `#clobber` specifications for all caller-saved registers (`%x2`..`%x17`, `%v0`..`%v7`, `%v16`..`%v31` on ARM64; `%t0`..`%t6`, `%a2`..`%a7` on RISC-V 64), ensuring the compiler register allocator spills all active variables across yield points.
- **Standalone Multi-ISA Test Harness & QEMU Automation (`examples/test_runner/main.odin`, `run_wsl_qemu.ps1`)**:
  - Added `run_all_coroutine_tests` dispatcher running all 187 unit tests across native host and QEMU emulation.
  - Added `.\run_wsl_qemu.ps1` supporting `test`, `bench`, and `all` targets under `qemu-aarch64` and `qemu-riscv64` in WSL2.
- **Machine Code Disassembler Validation with `core:rexcode` (`src/coroutine/coroutine_test.odin`)**:
  - Added **Test 187** validating that all `#byte` machine code opcodes decode byte-for-byte across x86-64, ARM64, and RISC-V 64 without errors.
- **Comprehensive Documentation (`docs/tech/TECH_ASM.md`, `docs/tech/TECH_ODIN_INLINE_ASM_ANALYSIS.md`)**:
  - Authored `docs/tech/TECH_ASM.md` detailing multi-ISA architecture, SSA pass diagnostics, trampoline sequences, and opcode mappings.

### Fixed
- **Multi-Frame Coroutine Yielding under RISC Architectures**:
  - Resolved stack pointer and link register preservation across multi-step yield loops (`yield_frame`, `wait`, `wait_ticks`), achieving **187 / 187 tests passing** under QEMU emulation.
- **RISC-V 64 Stack Pointer Move Encoding (`src/coroutine/asm_riscv64.odin`)**:
  - Corrected `addi sp, a1, 0` encoding to `0x13, 0x81, 0x05, 0x00`.

## [Universal Multi-ISA Native Inline ASM Architecture (`amd64`, `arm64`, `riscv64`)] - 2026-09-02

### Added
- **Universal Multi-ISA Architecture Support (`src/coroutine/asm_arm64.odin`, `asm_riscv64.odin`)**:
  - **ARM64 (AAPCS64 ABI)**: Implemented 160-byte stack frame preserving `x19`–`x28`, `x29` (FP), `x30` (LR), and `d8`–`d15` for macOS Apple Silicon (M1–M4), Linux ARM, iOS, Android, and Nintendo Switch.
  - **RISC-V 64 (LP64D ABI)**: Implemented 208-byte stack frame preserving `ra`, `s0`–`s11`, and `fs0`–`fs11` for open-source RISC-V hardware, SBCs, and embedded systems.
  - **High-Level Inline ASM Register Extractors**: Implemented `get_r12_reg` (`amd64`), `get_x19_reg` (`arm64`), and `get_s2_reg` (`riscv64`) using 100% pure high-level Odin inline assembly mnemonics.
- **Universal Multi-ISA Stack Synthesis (`src/coroutine/pool.odin`)**:
  - Added conditional architecture stack initializers in `fiber_synthesize_initial_stack` for `arm64` and `riscv64`.
  - Added multi-architecture fiber self-identity resolution in `fiber_trampoline_entry`.
- **Multi-ISA Build & CI Matrix (`build.ps1`, `build.sh`, `.github/workflows/ci.yml`)**:
  - Added `.\build.ps1 check-arm64`, `.\build.ps1 check-riscv64`, and `.\build.ps1 check-all` to cross-validate all 6 target platforms.
  - Added `build.sh` supporting native and QEMU user-space emulated execution (`qemu-aarch64`, `qemu-riscv64`).
  - Added comprehensive GitHub Actions workflow testing native Windows x64, native Ubuntu x64, native macOS Apple Silicon (`macos-14`), and QEMU-emulated Linux ARM64 and RISC-V 64 on every push.

### Fixed
- **POSIX Memory Protection Signatures (`src/coroutine/pool.odin`)**:
  - Corrected `posix.mmap` flags to Odin `bit_set` syntax `{.READ, .WRITE}` and `{.PRIVATE, .ANONYMOUS}`.
  - Corrected `posix.mprotect` flags to `{}` for `PROT_NONE` guard pages.

## [True ZII Semaphore Unbounded Permits, Mutex Owner Validation, CSP Send Timeouts & Domain Symmetries] - 2026-08-30

### Fixed
- **`Fiber_Semaphore` True ZII Unbounded Permits (`src/coroutine/api.odin`)**:
  - Fixed permit clamping when `sem.max_permits <= 0` (uninitialized/default True ZII state).
  - Calling `semaphore_release` now allows unconstrained permit accumulation when no upper ceiling is configured.
- **`Fiber_Mutex` Owner Tracking & Inspection Accessors (`src/coroutine/types.odin`, `api.odin`)**:
  - Added `owner: Fiber_Handle` to `Fiber_Mutex` (maintaining 32-byte True ZII struct size).
  - Tracks the exact owning fiber during lock acquisitions and handoffs; added `mutex_owner` and `mutex_is_locked` inline accessors.
- **`Fiber_Latch` Redundant Countdown Early Exit (`src/coroutine/api.odin`)**:
  - Added fast guard `if latch.count == 0 do return` to eliminate redundant waiter queue sweeps on duplicate count-downs.
- **Self-Join Deadlock Guard in `fiber_join` (`src/coroutine/api.odin`)**:
  - Added `target_handle == f.handle` rejection in `fiber_join`, immediately returning `false` to prevent self-deadlock.
- **Branch Domain & Wake-Clock Inheritance in `fiber_setup_branches` (`src/coroutine/api.odin`)**:
  - Child branches in `.Race`, `.Rush`, `.Sync` combinators now inherit `child.wake_clock = f.wake_clock` and use the domain-correct `start_time` (simulation or real-time wall clock).

### Added
- **`chan_send_timeout` Symmetrical CSP Primitive (`src/coroutine/api.odin`)**:
  - Implemented timeout-bounded channel sends: `chan_send_timeout(f, ch, value, timeout_seconds) -> (ok: bool, timed_out: bool)`.
- **`with_timeout_real` Real-Time Domain Timeouts (`src/coroutine/api.odin`)**:
  - Added overloaded real-time domain timeout combinators (`with_timeout_real_branch`, `with_timeout_real_ptr`, `with_timeout_real_val`, `with_timeout_real_nil`).
- **`simulate_until_val` Value-Type Simulation Runner (`src/coroutine/api.odin`)**:
  - Added by-value headless simulation dispatch overload to `simulate_until`.
- **Unit Tests 181–186 (`src/coroutine/coroutine_test.odin`)**:
  - Test 181: True ZII Semaphore Unbounded Permits & Multi-Fiber Acquisition.
  - Test 182: Mutex Owner Tracking, Lock State & Safe Handover.
  - Test 183: Self-Join Deadlock Rejection Guard.
  - Test 184: Symmetrical CSP Channel Send Timeout (`chan_send_timeout`).
  - Test 185: Real-Time Domain Timeouts (`with_timeout_real`).
  - Test 186: By-Value Headless Simulation Runner (`simulate_until_val`).
  - Test suite expanded to **186 / 186 unit tests passing** (100% with 0 memory leaks across all 12 build matrix targets).

## [Symmetrical CSP Rendezvous, Join Sibling Isolation & Precision Timing] - 2026-08-30

### Fixed
- **Unbuffered CSP Symmetrical Rendezvous Deadlock (Sender-First Ordering) (`src/coroutine/api.odin`)**:
  - Eliminated deadlock when a sender calls `chan_send` on an unbuffered channel before any receiver is waiting.
  - Senders now cleanly place their value in the rendezvous slot, set `ch.count = 1`, and wait in `send_waiters`. When a receiver calls `chan_recv`, it immediately consumes the value, resets `ch.count = 0`, wakes the sender, and completes the rendezvous handshake.
- **Race & Rush Sibling Branch Coordinator Scoping Isolation (`src/coroutine/scheduler.odin`)**:
  - Upgraded `fiber_on_finish` in `.Race` and `.Rush` join coordinators to check `child != fiber && child.join_coord == coord` before triggering cancellations.
  - Guarantees that only sibling branches created specifically for the winning join coordinator are aborted, preserving independent child fibers attached to the parent.
- **In-Place Safe Teardown in `fiber_abort_tree` (`src/coroutine/scheduler.odin`)**:
  - Refactored recursive child abortion to drain `root.first_child` in-place (`for root.first_child != nil { fiber_abort_tree(sched, root.first_child) }`).
  - Eliminates iterator invalidation risks during recursive unlinking and deallocation.
- **Exact `f64` Zero-Drift Scheduling in `ticker_wait` (`src/coroutine/api.odin`)**:
  - Scheduled `f.wake_time = t.next_wake` directly onto the timer heap without `f32` round-trip truncation, guaranteeing zero floating-point drift over millions of ticks.
- **Generator Initial Step Queue Deduplication (`src/coroutine/api.odin`)**:
  - `generator_next` now verifies `if f.status == .Suspended_Join` before enqueuing to `ready_queue`, preventing duplicate handles on turn 1.

### Added
- **Unit Tests 175–180 (`src/coroutine/coroutine_test.odin`)**:
  - Test 175: Unbuffered CSP Channel Sender-First Rendezvous Handshake (symmetrical delivery, zero deadlock).
  - Test 176: Multiple Unbuffered CSP Senders FIFO Rendezvous Handshake (strict FIFO ordering).
  - Test 177: Race Join Coordinator Independent Sibling Non-Interference (undisturbed long-lived child fibers).
  - Test 178: Rush Join Coordinator Independent Sibling Non-Interference (undisturbed long-lived child fibers).
  - Test 179: Zero-Drift `f64` Ticker Long-Horizon Simulation Stability (50 exact ticks).
  - Test 180: Stateful Generator Clean First-Step State & Early Destruction (clean teardown and zero leaks).
  - Test suite expanded to **180 / 180 unit tests passing** (100% with 0 memory leaks across all 12 build matrix targets).

## [Generational Ready-Queue ABA Guard, Scoped Lock Abort Safety & Concurrency Hardening] - 2026-08-30

### Fixed
- **Ready Queue Generational Handle ABA & Recycled Fiber Execution Guard (`src/coroutine/types.odin`, `scheduler.odin`, `api.odin`)**:
  - Upgraded `Scheduler.ready_queue` from `[dynamic]^Fiber` to `[dynamic]Fiber_Handle` (32-bit packed generational handle).
  - Ready-queue dispatch now checks `f := fiber_find_by_handle(sched, h)` in $O(1)$ time with generation verification before execution.
  - Guarantees that when a queued fiber is aborted and its memory recycled within the same frame, stale slots in `ready_queue` are safely skipped, preventing re-allocated fibers from executing twice in a single tick.
- **Paused State Condition Waiters Polling Starvation (`src/coroutine/scheduler.odin`)**:
  - Added in-place linear partitioning of `sched.condition_waiters` inside `scheduler_advance_real`.
  - Ensures async background jobs (`await_async` / `Async_Token`), real-time condition waits (`wait_until_timeout`, `wait_while_timeout`), and pause UI fibers are polled and woken seamlessly even while `sched.clock.is_paused` is active.
- **Automatic Abort Safety & Lock Release in `with_mutex` (`src/coroutine/api.odin`)**:
  - Integrated automatic abort cleanup hooks (`Scoped_Mutex_Cleanup_Ctx` / `cleanup_mutex_hook`) into `with_mutex_ptr`, `with_mutex_val`, and `with_mutex_nil`.
  - Guarantees that if a fiber holding a mutex is cancelled or aborted mid-operation (e.g. via `scope_cancel`, `race`, or `fiber_cancel`), the mutex is automatically unlocked and handed over to waiting fibers without deadlock or manual boilerplate.
- **Automatic Abort Safety & Permit Restoration in `with_semaphore` (`src/coroutine/api.odin`)**:
  - Integrated automatic abort cleanup hooks (`Scoped_Sem_Cleanup_Ctx` / `cleanup_sem_hook`) into `with_semaphore_ptr`, `with_semaphore_val`, and `with_semaphore_nil`.
  - Guarantees that aborted fibers automatically restore their acquired semaphore permit count.
- **CSP Select Message Priority Over Closed Channels (`src/coroutine/api.odin`)**:
  - Upgraded `chan_select_recv` to a two-pass evaluation: Pass 1 prioritizes available buffered data across all selected channels; Pass 2 handles closed channel EOF only when all channels are empty.
  - Eliminates message starvation when selecting across a closed empty channel alongside active buffered sister channels.

### Added
- **Unit Tests 170–174 (`src/coroutine/coroutine_test.odin`)**:
  - Test 170: Ready queue generational handle ABA & pointer recycling guard (no duplicate execution on same-frame replacement).
  - Test 171: Paused state condition waiters polling in `scheduler_advance_real` (`await_async` completion while paused).
  - Test 172: Automatic abort safety in `with_mutex` (immediate lock release upon fiber cancellation).
  - Test 173: Automatic abort safety in `with_semaphore` (immediate permit restoration upon fiber cancellation).
  - Test 174: `chan_select_recv` buffered message priority over closed channels (zero message loss).
  - Test suite expanded to **174 / 174 unit tests passing** (100% with 0 memory leaks across all 12 build matrix targets).

## [Comprehensive Logic & Concurrency Hardening] - 2026-08-30

### Fixed
- **Unbuffered Channel Multi-Sender FIFO & Symmetrical Rendezvous (`src/coroutine/api.odin`)**:
  - Prevented buffer overwriting and lost messages when multiple senders attempt to send on an unbuffered channel (`capacity == 0`) before a receiver arrives. Senders now queue cleanly in `send_waiters` without clobbering `ch.buffer[0]`.
  - Added automatic wake-up of the next waiting sender when an unbuffered rendezvous finishes, enabling seamless continuous multi-message throughput in FIFO order.
- **Unbuffered Sender Cancellation & Abort Cleanup (`src/coroutine/api.odin`)**:
  - Registered an intrusive cleanup callback on unbuffered senders waiting in rendezvous. If a sender is cancelled or aborted mid-rendezvous, `ch.count` is safely reset to 0, preventing ghost messages or stalled channels.
- **Real-Time Fiber & Ticker Execution When Simulation is Paused (`src/coroutine/api.odin`)**:
  - Implemented `yield_real(f)` and updated `wait_real(f, 0.0)` / real-time `Ticker` to yield to the real-time clock domain instead of simulation `frame_waiters`, completely eliminating UI/ticker freezes when the game is paused.
- **Fiber Recycle & Pool Sanitization (`src/coroutine/pool.odin`)**:
  - Sanitized all fiber state fields upon acquisition and recycling (`wake_clock = .Sim_Scaled`, `wake_ticks = 0`, `next_in_scope = nil`, `prev_in_scope = nil`, `cleanup_proc = nil`, `cleanup_data = nil`, `condition_data = nil`), eliminating stale real-time clock inheritance and dirty scope links across generational pool reuse.
- **Cleanup User Data Isolation (`src/coroutine/types.odin`, `api.odin`, `pool.odin`, `scheduler.odin`)**:
  - Added dedicated `cleanup_data: rawptr` to `Fiber` struct. `fiber_set_cleanup(f, proc, data)` no longer clobbers `fiber.user_data`, preserving entry arguments and payload storage integrity.
- **Defensive Scheduler & Scope Destruction (`src/coroutine/scheduler.odin`)**:
  - `scheduler_destroy` now cleanly detaches all active fibers from external `Fiber_Scope` instances (`fiber_scope_detach`), preventing dangling node pointers in outliving scopes.
  - Added defensive null-guards to `async_token_init`, `async_token_complete`, and hierarchy unlinking (`fiber_unlink_child`).

### Added
- **Unit Tests 163–169 (`src/coroutine/coroutine_test.odin`)**:
  - Test 163: Unbuffered channel multi-sender concurrent rendezvous safety (zero data loss across 3 senders and 1 receiver).
  - Test 164: Unbuffered channel sender abort cleanup and ghost message prevention.
  - Test 165: Real-time fiber paused yield safety via `yield_real` and `wait_real(f, 0.0)` (continuous stepping while paused).
  - Test 166: Real-time `Ticker` continuous execution while simulation clock is paused.
  - Test 167: `fiber_set_cleanup` user data isolation and callback fidelity.
  - Test 168: Fiber pool recycle wake clock sanitization from `.Real_Time` back to `.Sim_Scaled`.
  - Test 169: `scheduler_destroy` external `Fiber_Scope` clean detachment and zeroing.
  - Test suite expanded to **169 / 169 unit tests passing** (100% with 0 memory leaks across all 12 build matrix configurations).

## [Code Purity & Legacy Fallback Pruning] - 2026-08-30

### Refactored
- **Pruned Unused `allocator` Parameters in True ZII Sync Inits (`src/coroutine/api.odin`)**:
  - Removed obsolete `allocator := context.allocator` parameters from `signal_init`, `mutex_init`, `semaphore_init`, `latch_init`, and `event_init` since all synchronization primitives operate 100% on zero-allocation intrusive `Wait_Queue` headers.
- **Streamlined Memory Lifecycle Helpers (`src/coroutine/pool.odin`, `scheduler.odin`)**:
  - Simplified `fiber_pool_destroy(pool)` and `scheduler_destroy(sched)` signatures to directly utilize persistent struct allocators, eliminating redundant triple-fallback ternary expressions.
- **True ZII Verification (`src/coroutine/coroutine_test.odin`)**:
  - Updated Test 135 to verify that initializing and destroying all synchronization primitives incurs zero heap allocations.

## [Static Data Structure (SDS) & Memory Layout Migration] - 2026-08-30

### Refactored
- **Intrusive Doubly-Linked `Fiber_Scope` (`src/coroutine/types.odin`, `api.odin`, `scheduler.odin`)**:
  - Embedded `next_in_scope: ^Fiber` and `prev_in_scope: ^Fiber` directly inside `Fiber` descriptor.
  - Converted `Fiber_Scope` from dynamic slice `[dynamic]Fiber_Handle` to a 24-byte True ZII header (`head: ^Fiber, tail: ^Fiber, count: int`).
  - Achieved 100% zero-allocation scoped fiber spawning (`spawn(..., scope = &s)`).
  - Replaced $O(N)$ linear handle scans and `unordered_remove` in `fiber_cleanup_and_recycle` with $O(1)$ in-place list unlinking.
  - Eliminated `delete(scope.handles)` in `scope_destroy`; `Fiber_Scope` is now immediately valid on `{}` declaration.
- **Fixed SDS Active Arrays & Circular Buffers in Demos (`src/main.odin`, `examples/showcase/main.odin`)**:
  - Converted `projectiles` and `particles` in Boss Fight game to fixed SDS active arrays (`MAX_PROJECTILES :: 512`, `MAX_PARTICLES :: 1024`) with in-place swap-with-last compaction and zero runtime heap allocations.
  - Converted `recent_logs` in Feature Showcase (Station 7) to a fixed circular ring buffer (`MAX_RECENT_LOGS :: 8`) with modulo head/count indexing.

### Added
- **Test 162: Intrusive Doubly-Linked Fiber_Scope Zero-Allocation Lifecycle (`src/coroutine/coroutine_test.odin`)**:
  - Validates True ZII initialization, $O(1)$ natural fiber completion unlinking, and batch scope cancellation mid-flight.

## [Documentation Modernization & Learning Tracks] - 2026-08-30

### Documentation
- **4 Structured Engineering Tracks (`README.md`)**:
  - Reorganized entire documentation suite into 4 dedicated learning tracks: Track 1 (Gameplay Scripting), Track 2 (Engine Integration), Track 3 (Low-Level Specs & Hardware Math), and Track 4 (Reliability, Safety Harness & Developer Tooling).
- **API Signature Reconciliation (`docs/tutorials/06_async_background_jobs.md`)**:
  - Corrected `async_token_complete(&job.token, true)` signature and documented payload encapsulation within job structs.
- **The 11 Cooperative Fiber Footguns (`docs/guides/GUIDE_FOOTGUNS.md`, `COOKBOOK.md`)**:
  - Synchronized header, overview table, and cheat sheet to feature all 11 footguns (including Footgun 11: Storing Raw `^Fiber` Pointers Instead of Packed Generational Handles).
- **Symmetrical Unbuffered Rendezvous Documentation (`docs/tech/TECH_PRIMITIVES.md`, `COOKBOOK.md`)**:
  - Documented zero-deadlock symmetrical unbuffered rendezvous semantics (`capacity == 0`) and multi-channel select extraction.
- **Hardware MMU Parity Documentation (`docs/tech/TECH_MEMORY.md`)**:
  - Documented permanent `PAGE_NOACCESS` on Windows virtual memory slabs for 1:1 hardware parity with POSIX `PROT_NONE`.
- **Real-Time Inline Payloads & Headless Simulation Docs (`docs/tech/TECH_CLOCK.md`, `docs/tutorials/08_multi_domain_clocks.md`, `docs/tutorials/09_headless_ci_testing.md`)**:
  - Added explicit code examples and mathematical analysis for `spawn_real_val` and pause-immune/watchdog-safe `simulate_until`.

## [Technical Hardening & Quality Audit] - 2026-08-30

### Fixed
- **Unbuffered Channel (`capacity == 0`) Sender-First Rendezvous Deadlock (`src/coroutine/api.odin`)**:
  - In `chan_send` (unbuffered mode with empty `recv_waiters`), the sender now safely writes `ch.buffer[0] = value`, sets `ch.count = 1`, and suspends in `send_waiters`.
  - When `chan_recv`, `chan_try_recv`, or `chan_select_recv` subsequently runs, it consumes `ch.buffer[0]`, resets `ch.count = 0`, and wakes the waiting sender.
  - Symmetrical rendezvous execution eliminates any deadlock regardless of whether sender or receiver spawns first.
- **Windows Virtual Memory Guard Page Protection (`src/coroutine/pool.odin`)**:
  - Replaced transient `win32.PAGE_GUARD | win32.PAGE_READWRITE` with permanent `win32.PAGE_NOACCESS` on the bottom 4KB page of virtual memory slabs.
  - Achieves 1:1 hardware MMU crash trapping parity with POSIX `mprotect(PROT_NONE)`.
- **`simulate_until` Execution Safety When Paused (`src/coroutine/api.odin`)**:
  - `simulate_until_ptr` and `simulate_until_nil` now temporarily unpause the simulation clock (`sched.clock.is_paused = false` with defer restore), preventing infinite simulation loops during headless tests.
- **OS Thread Handle Leak in Showcase Station 6 (`examples/showcase/main.odin`)**:
  - Retained `^thread.Thread` handle in `research_lab_task` and called `thread.destroy` on completion of `await_async`.

### Added
- **`spawn_real_val` By-Value Inline Payload Procedure (`src/coroutine/api.odin`)**:
  - Added `spawn_real_val` supporting inline by-value payload structs (`size_of(T) <= 128`) on the real-time clock domain.
  - Expanded procedure group: `spawn_real :: proc{spawn_real_ptr, spawn_real_val, spawn_real_nil}`.
- **Defensive Input Clamping & Guards (`src/coroutine/api.odin`)**:
  - Guarded `semaphore_release` against non-positive counts (`count <= 0`).
  - Guarded `latch_count_down` against non-positive steps (`n <= 0`).
  - Defensively clamped `ticker_init` intervals (`t.interval = max(0.0001, interval_seconds)`).
- **`DEFAULT_ALLOC_MODE` Enum Alias (`src/coroutine/types.odin`, `pool.odin`, `scheduler.odin`)**:
  - Added `DEFAULT_ALLOC_MODE :: Stack_Allocation_Mode(DEFAULT_ALLOC_MODE_INT)` and wired as default parameter in `fiber_pool_init` and `scheduler_init`.

### Refactored
- **Compile-Time Procedure Constants for Thunk Trampolines (`src/coroutine/api.odin`)**:
  - Converted `wrapper := proc(...)` runtime variable declarations to compile-time procedure constants `wrapper :: proc(...)` in `spawn_nil`, `branch_nil`, `wait_until_nil`, and `wait_while_nil`.
- **Benchmark Payload Cleanliness (`examples/bench/main.odin`)**:
  - Refactored `bench_timer_min_heap` to pass `Timer_Bench_Ctx` directly via `spawn_val`, eliminating manual `f.user_data` pointer overwriting.
- **Unit Tests 157–161 (`src/coroutine/coroutine_test.odin`)**:
  - Test 157: Symmetrical unbuffered channel rendezvous (sender spawned before receiver).
  - Test 158: Unbuffered multi-channel select with pre-queued sender.
  - Test 159: `spawn_real_val` inline payload execution while game simulation is paused.
  - Test 160: Defensive non-positive counts in `semaphore_release` and `latch_count_down`.
  - Test 161: `simulate_until` execution safety when scheduler starts in paused state.
  - Test suite expanded to **161 / 161 unit tests passing** (100% with 0 memory leaks across all 12 build matrix targets).

## [Safety Hardening & Streamlined Branching] - 2026-08-30

### Fixed
- **Unbuffered Rendezvous `chan_recv_timeout` Deadlock Safety (`src/coroutine/api.odin`)**:
  - Constrained fast-path evaluation to buffered channels with ready items in memory (`ch.count > 0`).
  - Guarantees that unbuffered channels (`capacity == 0`) always route through `race` timeout preemption, preventing hangs if senders are aborted.
- **`Wait_Queue` Unlinking on `scheduler_destroy` (`src/coroutine/scheduler.odin`)**:
  - Added proactive unlinking of all active fibers from `fiber.current_wait_queue` during `scheduler_destroy`.
  - Prevents use-after-free (UAF) if channels, mutexes, semaphores, or events outlive the scheduler instance.
- **Stack Canary Verification in `fiber_calc_stack_usage` (`src/coroutine/pool.odin`)**:
  - Added watermark breach validation (`!fiber_check_canary(fiber)`) to return 100% stack consumption (`total_bytes, total_bytes`) immediately, highlighting stack overflows in telemetry and debug overlays.

### Refactored
- **`with_timeout_branch` Value-Passing (`src/coroutine/api.odin`)**:
  - Streamlined `with_timeout_branch` by passing `seconds: f32` directly into fiber inline payload storage via `branch_val`, eliminating temporary struct allocations and pointer indirections.
- **Pruned Unused `Join_Kind.Fallback` Enum Variant (`src/coroutine/types.odin`)**:
  - Pruned `Fallback` from `Join_Kind` enum, leaving the 3 fundamental orthogonal join modes (`.Sync`, `.Race`, `.Rush`).
  - High-level `fallback` combinator continues executing sequential branches via `sync` without unnecessary low-level join coordinator state.
- **Persistent Allocator Storage (`src/coroutine/types.odin`, `pool.odin`, `scheduler.odin`)**:
  - Stored `allocator: mem.Allocator` directly inside `Fiber_Pool` and `Scheduler` structs.
  - Ensures dynamic fiber pool growth (`fiber_pool_grow`) and teardown (`fiber_pool_destroy`, `scheduler_destroy`) always use the initial allocator, preventing mismatch when `context.allocator` is temporarily overridden.
- **`Event(T)` Runtime Size Check Cleanup (`src/coroutine/api.odin`)**:
  - Removed redundant runtime `if size_of(T) <= FIBER_PAYLOAD_SIZE` checks from `event_wait` and `event_emit`, relying on the compile-time `#assert` guarantee.
- **Unit Tests 153–156 (`src/coroutine/coroutine_test.odin`)**:
  - Test 153: Verified unbuffered channel `chan_recv_timeout` deadlock safety when no sender is present.
  - Test 154: Verified clean `Wait_Queue` unlinking upon `scheduler_destroy` for outliving sync primitives.
  - Test 155: Verified `with_timeout` by-value inline payload branching.
  - Test 156: Verified `fiber_calc_stack_usage` canary watermark breach detection and 100% usage reporting.
  - Test suite expanded to **156 / 156 unit tests passing** (100% with 0 memory leaks).

## [100% Pure Structured Concurrency & Category Tag Purge] - 2026-08-30

### Removed
- **`user_tag`, `scheduler_cancel_by_tag`, and `scheduler_count_by_tag` Purged from Engine**:
  - Eliminated `user_tag: u32` from `Fiber` and `tag: u32` from `Branch_Desc` and all `spawn_*` / `branch_*` procedures.
  - Eliminated `scheduler_cancel_by_tag` and `scheduler_count_by_tag`, removing the final unstructured escape hatch from the engine.
  - Replaced unstructured category tags with **100% Pure Structured Concurrency**:
    1. **`Fiber_Scope` / Sub-Scopes**: Hierarchical component and entity lifetimes (`scope_cancel` now returns `cancelled_count: int` in $O(1)$ time).
    2. **Interruption Races (`race` + `Signal`)**: Preempts and recovers from gameplay stuns, EMPs, silences, and phase transitions cleanly without out-of-band tag queries or duplicate spawned fibers.
    3. **Fork-Join Task Combinators**: `race`, `rush`, `sync`, `fallback`.
- **Refactored All Demos & Examples**:
  - `src/main.odin`: Refactored Boss AI into structured `race` vs `stun_signal` loops with EMP particle FX and clean auto-recovery; converted floating text renderer to tree-walk inspection.
  - `examples/showcase/main.odin`: Converted Station 4 sentry lockdown to structured `scope_cancel`.
  - `examples/quest_ai/main.odin`: Converted knight stun to structured `scope_cancel`.
- **Refactored Unit Tests**:
  - Updated all unit tests in `src/coroutine/coroutine_test.odin` (Tests 85, 87, 88, 89, 90, 96, 97, 98, 99, 100, 101, 108, 110, 145, 146, 147, 148).
  - **152 / 152 unit tests passing**; 0 memory leaks across all test runners and 12 LLVM matrix configurations.

## [Pure Structured Concurrency & Cancel_Token Elimination] - 2026-08-30

### Removed
- **`Cancel_Token` and `with_cancel_token` Purged from Engine**:
  - Eliminated `Cancel_Token` struct and all related procedures (`cancel_token_init`, `cancel_token_destroy`, `cancel_token_reset`, `cancel_token_is_cancelled`, `cancel_token_waiter_count`, `cancel_token_cancel`, `cancel_token_wait`, `with_cancel_token`).
  - Replaced the unstructured cancellation escape hatch with structured concurrency primitives.

## [Systems Engineering Hardening & Math Precision] - 2026-08-30

### Fixed
- **`chan_select_recv` Intrusive Queue Aliasing (Memory Corruption Fix)**:
  - Eliminated dangerous simultaneous multi-registration of a single `Fiber` node across multiple intrusive `Wait_Queue` channels.
  - Converted `chan_select_recv` to a zero-shift frame-yielding check across all selected channels, preventing intrusive queue pointer overwrites.
- **Continuous Synchronized `sim_ticks` (Zero-Drift Simulation Math)**:
  - Fixed fractional delta-time truncation drift where discrete simulation ticks drifted behind `sim_time` by up to 40ms per second at 60 FPS.
  - Computes `sim_ticks` from accumulated target simulation time (`u64(new_total_sim_time * tick_rate_hz) - sched.clock.sim_ticks`), guaranteeing exact 1000 ticks/sec alignment.
- **`scheduler_advance_real` Zero-Shift Optimization**:
  - Replaced legacy $O(N)$ slice `pop_front` shifts during paused game mode with an $O(N)$ zero-shift linear sweep in `scheduler_advance_real`, matching `scheduler_advance`.
- **Defensive `wait_queue_remove` Queue Validation**:
  - Added strict queue validation (`if f.current_wait_queue != q do return false`) in `wait_queue_remove` to guard against cross-queue pointer unlinking.
- **$O(1)$ Generational Lookup in `generator_next`**:
  - Replaced $O(N)$ linear pool scan with instant $O(1)$ generational handle index lookup via `fiber_find_by_handle`.
- **Removed Dead Legacy Struct Field `next_handle_id`**:
  - Cleaned up unused `next_handle_id: u32` from `Fiber_Pool` struct and `fiber_pool_init` initialization.
- **Defensive Clamping in `scheduler_set_time_scale`**:
  - Added non-negative clamping (`max(0.0, scale)`) and NaN fallback (`math.is_nan(scale) ? 1.0 : ...`) to guarantee binary min-heap timestamp monotonicity.
- **`Wait_Queue` Double-Unlink Defense on Fiber Recycling**:
  - Added defensive unlinking in `fiber_cleanup_and_recycle` (`if fiber.current_wait_queue != nil do wait_queue_remove(...)`) to guarantee clean queue state on abnormal termination.
- **Removed Unused `allocator` Fields from ZII Synchronization Primitives**:
  - Pruned unused 16-byte `allocator: mem.Allocator` fields from `Event(T)`, `Fiber_Semaphore`, `Fiber_Latch`, and `Cancel_Token` structs, achieving 100% zero-allocation True ZII footprint.
- **Unit Tests 149–152 (`src/coroutine/coroutine_test.odin`)**:
  - Test 149: Verified continuous synchronized `sim_ticks` zero-drift math across 60 frames at 60 FPS (exact 1000 ticks/sec).
  - Test 150: Verified defensive cross-queue unlinking protection and zero-shift real-time dispatch while simulation is paused.
  - Test 151: Verified defensive time scale clamping on negative values and NaNs.
  - Test 152: Verified generator $O(1)$ generational handle lookup and wait queue unlinking on fiber recycle.
  - Test suite expanded to **152 / 152 unit tests passing** (100% with 0 memory leaks across all 12 LLVM matrix builds).

## [PLAN 5: Centralized Configuration, Intrusive Wait Queues & Generational Handles] - 2026-08-30

### Added
- **Centralized Engine Configuration (`src/coroutine/config.odin`)**:
  - Consolidated all engine memory bounds, stack sizes, slab counts, payload capacities, temporary arena buffers, canaries, and tick frequencies into a unified `#config` module.
  - Supports build-time `-define:KEY=VALUE` overrides (e.g. `CORO_STACK_SIZE`, `CORO_PAYLOAD_SIZE`, `CORO_TEMP_ARENA_SIZE`, `CORO_HANDLE_HISTORY_CAPACITY`).
- **Packed Generational Handles ($O(1)$ Direct Slot Lookups)**:
  - Upgraded `Fiber_Handle` (packed 32-bit integer: lower 16 bits = slot index `0..65535`, upper 16 bits = generation `1..65535`).
  - Added `#force_inline` bitwise helpers: `fiber_handle_pack`, `fiber_handle_index`, `fiber_handle_gen`.
  - Replaced $O(N)$ linear scans with single-instruction $O(1)$ direct array index lookups in `fiber_find_by_handle`, `fiber_is_alive`, `fiber_status`, and `fiber_cancel`.
  - Complete ABA and use-after-free protection via generational slot increment on recycle.
- **Intrusive Waiter Queues (OS Kernel / Futex Pattern)**:
  - Replaced array/overflow hybrid buffers with **doubly-linked intrusive wait queues (`Wait_Queue`)**.
  - `Fiber` embeds `next_waiter: ^Fiber` and `prev_waiter: ^Fiber`, achieving **100% zero heap allocations** for all synchronization queues.
  - Enables unbounded waiter capacity with true **Zero Is Initialization (ZII)**: primitives (`Fiber_Mutex`, `Signal`, `Fiber_Latch`, `Cancel_Token`) are immediately valid upon declaration without calling `_init`.
  - Added $O(1)$ in-place unlinking (`wait_queue_remove`), allowing instant fiber removal on timeouts, cancellations, and multi-channel select without linear queue scans.
  - Primitives shrunk down to ultra-compact structs (`Fiber_Mutex` is only 24 bytes, `Signal` is 16 bytes).
- **Cancellation Token Robustness & Token Re-Arming (`cancel_token_reset`)**:
  - Added `cancel_token_reset(tok: ^Cancel_Token)` allowing cancellation tokens (lockdowns, alarms, EMPs) to be cleanly re-armed for multi-cycle reuse without permanent cancellation state stickiness.
  - Added automatic `current_wait_queue` tracking in `Fiber` and auto-unlinking in `fiber_abort_tree`, ensuring that when a fiber waiting in an intrusive `Wait_Queue` is aborted externally (tag cancel, scope destroy, sibling race), it unlinks in $O(1)$ time and leaves the queue pristine with zero dangling node corruption.
- **EMP Stun Recovery Loops in Boss AI & Showcase Demo**:
  - Restructured Boss AI attack phases with auto-recovering combat loops: when the player executes an EMP parry (`B` / `X`), attack branches are aborted, floating `"BOSS STUNNED!"` text appears, and attacks seamlessly resume after a 1.5s stun duration.
  - Enhanced Showcase lockdown demo: sentries enter `Lockdown Stunned` for 5.0s upon lockdown token trip, then re-arm the token and resume idle perimeter patrol.
- **Unit Tests 144–146 (`src/coroutine/coroutine_test.odin`)**:
  - Test 144: Wait_Queue auto-unlinking on fiber abort (preserves queue integrity for subsequent fibers).
  - Test 145: Cancel_Token reset and multi-cycle re-arming under `with_cancel_token`.
  - Test 146: EMP tag cancellation and subsequent attack recovery loop.
  - Test suite expanded to **146 / 146 unit tests passing** (100% with 0 memory leaks).

### Added
- **Condition Timeouts (`wait_until_timeout` & `wait_while_timeout`) (`src/coroutine/api.odin`)**:
  - Added 1-line auto-cancelling condition waiting primitives (`wait_until_timeout`, `wait_while_timeout`) with overloaded procedure groups supporting pointer data (`_ptr`), by-value inline payloads (`_val`), and parameterless predicates (`_nil`).
  - Automatically races condition evaluation against timeout deadline, ensuring zero leaked branches or dangling waiter fibers upon timeout.
- **Dynamic Fiber Renaming (`fiber_set_name` & `fiber_name`) (`src/coroutine/api.odin`)**:
  - Added real-time dynamic fiber renaming accessors (`fiber_set_name`, `fiber_name`) allowing stateful coroutines (Boss AI, cutscenes, behavior trees) to update their debug label on the fly for in-game debugger hierarchy display.
- **Channel Capacity Inspector (`chan_cap`) (`src/coroutine/api.odin`)**:
  - Added `#force_inline proc "contextless" chan_cap(ch) -> int` completing the Channel inspection API alongside `chan_count`, `chan_is_empty`, and `chan_is_full`.
- **Compile-Time Size Assertion for `Event(T)` (`src/coroutine/api.odin`)**:
  - Added `#assert(size_of(T) <= FIBER_PAYLOAD_SIZE)` across `event_init`, `event_wait`, and `event_emit`, enforcing payload constraints at compile time instead of silent runtime data truncation.
- **Allocator Fidelity in Synchronization Deallocation (`src/coroutine/api.odin`)**:
  - Hardened `event_destroy`, `semaphore_destroy`, `latch_destroy`, `cancel_token_destroy`, `signal_destroy`, and `mutex_destroy` with nil checks and guaranteed custom allocator deletion.
- **Headless Simulation Watchdog Safety (`simulate_until`)**:
  - Automatically suppresses and restores `sched.watchdog_enabled` during `simulate_until_ptr` and `simulate_until_nil` to eliminate false watchdog panics during multi-thousand-step headless benchmarks.
  - Expanded simulation idle checks across all timer and waiter queues (`real_timer_heap`, `tick_waiters`, `frame_waiters`, `condition_waiters`).
- **Zero-Allocation Floating Damage Text (`src/main.odin`)**:
  - Refactored floating damage and combat text to use by-value inline fiber payload storage (`TAG_FLOATING_TEXT`), eliminating all dynamic array heap allocations and `new()`/`free()` overhead during combat.
- **Unit Tests 133–138 (`src/coroutine/coroutine_test.odin`)**:
  - Added Test 133 (custom tracking arena allocation fidelity for all sync primitives), Test 134 (headless simulation with active watchdog), Test 135 (`wait_until_timeout`), Test 136 (`wait_while_timeout`), Test 137 (`fiber_set_name` / `fiber_name`), and Test 138 (`chan_cap`).
  - Test suite expanded to **138 / 138 unit tests passing** (100% with 0 memory leaks).

## [Orthogonal API Streamlining, Precision Ticker & Task Ergonomics] - 2026-08-28

### Added
- **Precision Zero-Drift Gameplay Ticker (`Ticker`, `ticker_init`, `ticker_wait`)**:
  - Added periodic timer primitive calculating target timestamps via absolute interval increments (`target += interval`) rather than relative sleep times, eliminating cumulative floating-point timing drift over long game matches.
  - Supports both scaled simulation time (`use_real_time = false`) and wall clock time (`use_real_time = true`).
- **Cancellation Ergonomics (`with_cancel_token`)**:
  - Added 1-line task/branch wrapper `with_cancel_token(f, tok, task) -> bool` racing a work branch against an explicit `Cancel_Token` watcher.
- **Unit Tests 131–132 (`src/coroutine/coroutine_test.odin`)**:
  - Added unit tests verifying zero-drift `Ticker` and `with_cancel_token` cancellation.
  - Test suite stands at **132 / 132 unit tests passing** (100% with 0 memory leaks).
- **GitHub Flavored Markdown KaTeX Compatibility**:
  - Normalized LaTeX math blocks across all documentation, guides, and tech specs to eliminate KaTeX text-mode underscore parsing errors (`\text{..._...}`) and ensure crisp rendering on GitHub.

### Removed
- **Unstructured Slice Joiners (`fiber_join_all` / `fiber_join_any`)**:
  - Pruned redundant unstructured handle slice joiners in favor of standard Structured Concurrency fork-join (`sync`, `race`, `rush`, `fallback`) and scoped entity synchronization (`scope_wait`).
  - Guarantees zero background orphan fibers on cancellation and maintains a strictly orthogonal, single-idiom concurrency API.

## [Event-Driven Select, By-Value Scoped Locks & Generic Tree Diagnostics] - 2026-08-28

### Added
- **Zero-Polling Event-Driven `chan_select_recv`**:
  - Upgraded multi-channel select from frame polling (`yield_frame`) to true $O(1)$ event-driven suspension across all open selected channels simultaneously with immediate wakeup and auto-cleanup.
- **By-Value Scoped Locks (`with_mutex_val` & `with_semaphore_val`)**:
  - Added inline value struct payload variants to `with_mutex` and `with_semaphore` overloaded procedure groups (`proc{with_mutex_ptr, with_mutex_val, with_mutex_nil}`).
- **Engine-Agnostic Tree Traversal (`scheduler_walk_tree` & `Fiber_Visitor`)**:
  - Added generic hierarchy tree walker utility in `src/coroutine/scheduler.odin`.
  - Refactored live debugger HUDs across `src/main.odin`, `examples/showcase/main.odin`, and `examples/quest_ai/main.odin` to use `scheduler_walk_tree`.
- **Unit Tests 127–130 (`src/coroutine/coroutine_test.odin`)**:
  - Added unit tests for `with_mutex_val`, `with_semaphore_val`, zero-polling `chan_select_recv`, and `scheduler_walk_tree`.
  - Test suite expanded to **130 / 130 unit tests passing** (100% with 0 memory leaks).

## [Critical Hardening, DRY Refactoring & Scoped Synchronization] - 2026-08-28

### Added
- **Deadlock-Proof Scoped Locks (`with_mutex` / `with_semaphore`)**:
  - Overloaded `with_mutex` (`with_mutex_ptr`, `with_mutex_nil`) acquiring a `Fiber_Mutex` and guaranteeing defer release upon body exit.
  - Overloaded `with_semaphore` (`with_semaphore_ptr`, `with_semaphore_nil`) acquiring and releasing a `Fiber_Semaphore` permit safely.
- **Generational Handle History Expansion (`FIBER_HANDLE_HISTORY_CAPACITY :: 2048`)**:
  - Expanded `Fiber_Pool.handle_history` from 256 to 2048 slots, eliminating ABA collisions and ensuring historical fiber queries remain accurate across long sessions.
- **Unit Tests 121–126 (`src/coroutine/coroutine_test.odin`)**:
  - Added 6 new unit tests validating stale waiter abort immunity in mutexes and channels, scoped lock mechanics, multi-channel select, cancel token broadcast, and extended handle capacity.
  - Suite expanded to **126 / 126 unit tests passing** (100% with 0 memory leaks).

### Changed
- **Stale Suspended Waiter Validation (100% Abort Immunity)**:
  - Hardened all synchronization wake sites (`mutex_unlock`, `semaphore_release`, `latch_count_down`, `signal_emit`, `event_emit`, `chan_send`, `chan_try_send`, `chan_recv`, `chan_try_recv`, `chan_close`, `cancel_token_cancel`).
  - Added `fiber_is_alive(sched, f.handle)` validation before unblocking suspended fibers, ensuring recycled or aborted fibers in waiter queues are never falsely awakened.
- **DRY Branch Spawning Refactoring (`fiber_setup_branches`)**:
  - Extracted private `fiber_setup_branches` helper in `src/coroutine/api.odin`, unifying ~90 lines of duplicate setup logic across `sync`, `race`, and `rush`.

## [Legacy Code Audit & Pristine Engine Cleanup] - 2026-08-28

### Removed
- **Obsolete Procedure Aliases (`src/coroutine/api.odin`)**:
  - Removed `spawn_typed`, `branch_typed`, `wait_until_typed`, and `wait_cond` aliases superseded by Odin's overloaded procedure groups (`spawn`, `branch`, `wait_until`).
- **Redundant Scheduler Clock Mirror Fields (`src/coroutine/types.odin` & `src/coroutine/scheduler.odin`)**:
  - Removed `current_time`, `current_frame`, `delta_time`, `time_scale`, and `is_paused` mirror fields from `Scheduler`.
  - Established `Scheduler.clock` (`Scheduler_Clock`) as the sole source of truth.
  - Eliminated per-frame synchronization assignments and branching overhead from `scheduler_step`, `scheduler_single_step`, and `scheduler_advance`.
- **Dead Debug Artifacts (`src/coroutine/scheduler.odin`)**:
  - Removed commented-out debug print from `fiber_cleanup_and_recycle`.

### Changed
- **Tween Delta Timing (`src/coroutine/api.odin`)**:
  - Refactored `tween_f32`, `tween_vec2`, `tween_vec3`, and `tween_vec4` to use `delta_time(f)` inline accessor.
- **Clock Accessors (`src/coroutine/scheduler.odin`)**:
  - Updated `scheduler_set_paused`, `scheduler_is_paused`, `scheduler_set_time_scale`, `scheduler_time_scale`, and added `scheduler_delta_time` to operate cleanly on `sched.clock`.

## [The 8 Footguns Safety Upgrades & Comprehensive Concurrency Hardening] - 2026-08-24

### Added
- **Debug Infinite Loop Watchdog (`Scheduler.watchdog_enabled`, `scheduler_set_watchdog`)**:
  - In debug builds (`when ODIN_DEBUG`), measures the duration of each fiber execution slice.
  - Automatically panics with descriptive diagnostics (`[WATCHDOG PANIC]`) naming the offending fiber handle and debug name if a fiber runs for > 100ms without yielding.
- **Channel Auto-Wake on Destruction (`chan_destroy`)**:
  - Automatically invokes `chan_close(ch)` before freeing backing arrays, waking all pending senders and receivers with `ok = false`.
- **Channel Receive with Deadline / Timeout (`chan_recv_timeout`)**:
  - Allows fibers to specify a timeout deadline returning `(value: T, ok: bool, timed_out: bool)` via structured `race` coordination.
- **Tag Inheritance in Structured Concurrency (`Branch_Desc.tag`)**:
  - `branch_ptr`, `branch_val`, and `branch_nil` now support `tag: u32 = 0`.
  - `sync`, `race`, and `rush` automatically propagate `tag` to spawned child branches, enabling category mass cancellations (e.g. EMP disruption) on nested behaviors.
- **Coordinator Abort Resolution (`fiber_abort_tree` & `fiber_on_finish`)**:
  - `fiber_abort_tree` now calls `fiber_on_finish` on `.Aborted` fibers to decrement `active_branches` and wake parent fibers awaiting `sync`, `race`, `rush`, or `fallback`.
- **Guaranteed Fiber Teardown (`fiber_set_cleanup`)**:
  - Registers a guaranteed cleanup callback that runs on normal fiber completion or external abort.
- **Master Footguns Guide (`docs/guides/GUIDE_FOOTGUNS.md`)**:
  - Comprehensive guide detailing the 8 real-world cooperative fiber traps, engine mitigations, and the Gameplay Programmer's Golden Rules Cheat Sheet.
- **Cookbook Recipe 13 (`COOKBOOK.md`)**:
  - Added Recipe 13 demonstrating deadlock-free telemetry polling via `chan_recv_timeout`.
- **Unit Tests 91–120 (`src/coroutine/coroutine_test.odin`)**:
  - 30 new unit tests (Suites 14, 15, and 16) covering tag propagation, multi-channel select with producer aborts, cancel token cascades, deep hierarchy cleanup, semaphore/mutex contention churn, event multicast pruning, latch countdown aborts, mixed-queue mass cancellation, slab growth, composite fallback/rush coordination, channel destruction auto-wake, channel timeouts, watchdog controls, scope protection against stale pointers, and temp allocator isolation.
  - Test suite expanded to **120 / 120 unit tests passing** (100% with 0 memory leaks).

## [Pure Systems Enhancements & POSIX Parity] - 2026-08-24

### Added
- **Multi-Channel Select (`chan_select_recv` / `chan_try_select_recv`)**:
  - Go-style CSP multiplexer allowing fibers to await whichever channel has a message available first (`chan_select_recv`) or inspect channels non-blockingly (`chan_try_select_recv`).
- **Explicit Cancellation Token (`Cancel_Token`)**:
  - Decoupled, lightweight cancellation handle (`cancel_token_init`, `cancel_token_destroy`, `cancel_token_cancel`, `cancel_token_is_cancelled`, `cancel_token_wait`).
  - Allows multiple independent fibers across different entity scopes to coordinate cancellation without sharing an intrusive `Fiber_Scope`.
- **Category User Tags & Mass Cancellation (`user_tag`, `scheduler_cancel_by_tag`, `scheduler_count_by_tag`)**:
  - Added 4-byte `user_tag: u32` to `Fiber` and `tag: u32 = 0` to all `spawn` procedures.
  - Added `scheduler_cancel_by_tag(sched, tag)` and `scheduler_count_by_tag(sched, tag)` for category mass cancellations (e.g. aborting all combat AI upon EMP).
- **POSIX Hardware Guard Page Parity (`mmap` + `mprotect(PROT_NONE)`)**:
  - `pool.odin` now implements hardware MMU crash trapping on Linux, macOS, and BSD systems via `posix.mmap` and `posix.mprotect(PROT_NONE)`.
- **Unit Tests 82–90 (`src/coroutine/coroutine_test.odin`)**:
  - 9 new unit tests covering multi-channel select, closed channel select handling, cancellation tokens, user tags, and tagged mass cancellations.
  - Test suite expanded to **90 / 90 unit tests passing** (100%).

## [Pure Concurrency Primitives & Telemetry] - 2026-08-24

### Added
- **Dynamic Task Joining (`fiber_join(f, handle)`)**:
  - Allows fibers to await the completion of independent fiber handles across different scopes or root tasks.
  - Returns `true` if target completed with `.Completed`, and `false` if aborted/failed.
- **Typed Multicast Event (`Event(T)`)**:
  - 1-to-Many publish-subscribe synchronization primitive (`event_init`, `event_destroy`, `event_wait`, `event_emit`, `event_waiter_count`, `event_has_waiters`).
  - Zero polling; delivers typed payloads to all active listeners in a single broadcast frame.
- **Counting Semaphore (`Fiber_Semaphore`)**:
  - Cooperative Dijkstra counting semaphore allowing up to $N$ concurrent permits (`semaphore_init`, `semaphore_destroy`, `semaphore_try_acquire`, `semaphore_acquire`, `semaphore_release`, `semaphore_available_permits`).
- **Countdown Latch / Barrier (`Fiber_Latch`)**:
  - Rendezvous barrier unblocking waiting fibers once counted down $N$ times (`latch_init`, `latch_destroy`, `latch_count_down`, `latch_wait`, `latch_get_count`, `latch_is_ready`).
- **Loading-Screen Memory Pre-Warming (`scheduler_prewarm` / `fiber_pool_prewarm`)**:
  - Allows games to pre-allocate slabs during level loads to eliminate runtime frame hitches.
- **Handle Introspection & Memory Telemetry (`fiber_is_alive`, `fiber_status`, `Pool_Stats`)**:
  - Safe handle querying via circular `handle_history` and real-time pool memory statistics (`scheduler_pool_stats`).
- **RTS Unit Action Queue Recipe (`COOKBOOK.md`)**:
  - Added Recipe 9 demonstrating unit command queuing with `Fiber_Scope` and preemption.
- **Unit Tests 71–81 (`src/coroutine/coroutine_test.odin`)**:
  - 11 new tests covering task join, multicast events, counting semaphores, countdown latches, pool pre-warming, and handle introspection. 81 / 81 unit tests passing (100%).

## [Documentation Suite, Technical Deep-Dives & Tutorials] - 2026-08-24

### Added
- **Complete Technical Documentation Suite (`docs/tech/`)**:
  - `TECH_ASM.md`: Low-level AMD64 context switching mechanics, Windows x64 vs System V ABI register preservation, call/ret trampoline, `#volatile` compiler clobbers, and 16-byte stack alignment invariants.
  - `TECH_CLOCK.md`: The physics and mathematics of game clocks ($f32$ vs $f64$ vs $u64$), the 3 clock domains, pluggable engine time drivers, and dual min-heap design.
  - `TECH_MEMORY.md`: Slab allocation strategy, 3-tier safety invariants (canaries, $0xAA$ profiling, OS `PAGE_GUARD`), per-fiber 4KB isolated temp arenas, and 128B inline payload storage.
  - `TECH_CONCURRENCY.md`: Structured concurrency matrix (`sync`, `race`, `rush`, `fallback`, `with_timeout`), `Join_Coordinator` intrusive tree topology, and bottom-up hierarchical cancellation.
  - `TECH_PRIMITIVES.md`: CSP typed channels (`Channel(T)`), stateful pull generators (`Generator(T)`), async background job bridge (`await_async`), and cooperative mutexes/signals.
- **Progressive 9-Stage Tutorial Series (`docs/tutorials/`)**:
  - `01_hello_coroutines.md`: Getting started, scheduler lifecycle, and straight-line yields (`wait`, `wait_frames`, `yield_frame`, `wait_until`).
  - `02_parameter_passing.md`: Entity pointers (`spawn_ptr`) vs 128-byte by-value payloads (`spawn_val`).
  - `03_structured_concurrency.md`: Multi-branch coordination with `sync` and preemption with `race`.
  - `04_advanced_control_flow.md`: Behavior trees with `fallback`, parallel quest racing with `rush`, and time constraints with `with_timeout`.
  - `05_synchronization.md`: Decoupled game systems using `Signal`, `Fiber_Mutex`, and `Channel(T)`.
  - `06_async_background_jobs.md`: Offloading heavy calculations via `await_async` without dropping frames.
  - `07_stateful_generators.md`: Lazy sequence streams and loot drop rolling with `Generator(T)`.
  - `08_multi_domain_clocks.md`: Real-time UI menus during paused simulation, bullet-time `time_scale`, fixed-tick physics.
  - `09_headless_ci_testing.md`: Blazing fast headless gameplay testing with `simulate_until` and zero-leak tracking.
- **Game Engine Integration & Architecture Guides (`docs/guides/`)**:
  - `GUIDE_INTEGRATION.md`: Integration blueprints for Raylib, Sokol, GLFW, SDL, and custom fixed/variable loops.
  - `GUIDE_SCHEDULERS.md`: Multi-scheduler setups (World vs UI) and scene lifecycle management.
  - `GUIDE_DETERMINISM.md`: Deterministic lockstep ticking, cross-architecture float safety, replays, and rollback netcode.
  - `GUIDE_MIGRATION.md`: Rosetta stone migration guide from Unity C# `IEnumerator`, Unreal Latent Actions, and stackless AST coroutines.
  - `GUIDE_DEBUGGER.md`: Visual fiber hierarchy inspector, live stack telemetry, freeze-frame stepping, and slow-motion controls.
- **Root Document Modernization**:
  - Synchronized `README.md`, `ARCHITECTURE.md`, `REPORTS.md` (70-test matrix), and `COOKBOOK.md` (8 production gameplay recipes).

## [3-Tier Engine Clock Architecture] - 2026-08-24

### Added
- **3-Tier Multi-Domain Engine Clock (`Scheduler_Clock` & `Time_Clock`)**:
  - **1. Real / Wall Clock (`real_time: f64`, `real_delta: f32`, `real_ticks: u64`)**: Unscaled and unpaused clock for UI, pause menus, network timeouts, and diagnostics (`wait_real`, `spawn_real`, `delta_real`, `real_time`).
  - **2. Scaled Simulation Clock (`sim_time: f64`, `sim_delta: f32`, `time_scale: f32`, `is_paused: bool`)**: Scaled gameplay clock for AI, combat, tweens, and timers (`wait`, `delta_time`, `current_time`).
  - **3. Discrete Simulation Ticks (`sim_ticks: u64`, `tick_rate_hz: u32`, `frame_count: u64`)**: Zero-drift integer ticking for deterministic physics, replay systems, and rollback netcode (`wait_ticks`, `current_ticks`, `scheduler_step_ticks`).
- **Engine-Agnostic Pluggable Time Drivers**:
  - `scheduler_step(sched, dt)`: Variable frame delta step.
  - `scheduler_single_step(sched, dt)`: Forced simulation step during debugger pause.
  - `scheduler_step_ticks(sched, ticks)`: Integer tick driver for fixed physics and headless testing.
  - `scheduler_step_dual(sched, real_dt, sim_dt)`: Dual real/simulation delta driver.
- **Dual Min-Heap & Multi-Queue Synchronization**:
  - `real_timer_heap`: Dedicated $O(\log N)$ min-heap for real-time timers.
  - `timer_heap`: Scaled simulation timer min-heap.
  - `tick_waiters`: Discrete integer tick waiting queue.
- **Unit Tests 67–70 (`src/coroutine/coroutine_test.odin`)**:
  - Tests covering real-time execution while paused (`test_real_time_clock_while_paused`), fixed integer discrete ticks (`test_fixed_integer_tick_clock`), dual-clock slow-mo / fast-forward scaling (`test_dual_clock_time_scaling`), and multi-clock heap integrity (`test_multi_clock_heap_integrity`). 70 / 70 unit tests passing (100%).

## [Gameplay Control Flow, Phase Director & Headless Runner] - 2026-08-24

### Added
- **`fallback` & `rush` Advanced Concurrency Operators**:
  - `fallback(f, ..branches)`: Sequential branch priority fallback ($A \rightarrow B \rightarrow C$), executing until the first successful branch.
  - `rush(f, ..branches)`: Parallel success preemption ($A \parallel B \parallel C$), ignoring early failures and aborting remaining siblings upon the first `.Completed` branch.
  - `fail(f)`: First-class failure primitive setting fiber status to `.Failed` and notifying parent coordinators.
- **`Phase_Director` Finite State Machine**:
  - Structured FSM driver for boss phases, dialogue trees, and cutscenes (`phase_director_init`, `phase_director_destroy`, `phase_switch`, `phase_current`, `phase_name`, `phase_is_busy`).
  - Automatically cancels and cleans up all active coroutines belonging to old phases upon state transition.
- **Headless Simulation Runner (`simulate_until`)**:
  - CI/CD automated test harness stepping the scheduler in virtual delta-time without real-time delay or window creation (`simulate_until :: proc{simulate_until_ptr, simulate_until_nil}`).
- **Interactive Debugger Freeze-Step & Slow-Motion Engine**:
  - `[F3]`: Unified Simulation Freeze / Pause (`sched.is_paused`) halting coroutines, world time, and entity physics in unison.
  - `scheduler_single_step(sched, dt)`: Dedicated stepping procedure to force execution forward while `is_paused` is active.
  - **Input Latching While Paused**: Action keys (`[1]`–`[6]`, `[E]`, `[Space]`, `[LMB]`, `[3]`, `[T]`) pressed while paused are latched and executed on the next step frame.
  - `[F4]`: Single-Frame Step ($1\text{ frame} = 0.016s$).
  - `[F5]` / `[Shift+F4]`: Multi-Frame Jump ($10\text{ frames} = 0.160s$) for rapid progression through sleeps and tweens.
  - **Hold `[F4]`**: Continuous Slow-Motion Stepping at 15 FPS for smooth frame-by-frame inspection.
  - Live HUD step badge with step count, step delta ($+0.016s$), simulation timestamp, and green flash confirmation pulse.
  - Visualizer overlay supports `Sync`, `Race`, `Rush`, and `Fallback` branch descriptors.
- **Gameplay Cookbook (`COOKBOOK.md`)**:
  - 5 complete, production-ready gameplay architecture patterns (Ability Channeling, Dialogue Trees, Multi-Wave Spawners, Behavior Fallbacks, and Damped Spring Followers).
- **Unit Tests 56–66 (`src/coroutine/coroutine_test.odin`)**:
  - Automated tests covering `fallback`, `rush`, `Phase_Director`, `simulate_until`, `fail` primitive error propagation, all-failing edge cases, 5-branch rushes, rapid multi-phase transitions, headless channel pipelines, deeply nested combinators, and paused single-stepping execution (`test_scheduler_step_while_paused`).
- **Quest & AI Interactive Showcase (`examples/quest_ai`)**:
  - 4-zone interactive Raylib showcase featuring AI Behavior Decision Trees (`fallback`), Competitive Objective Quests (`rush`), Void Sentinel Boss FSM (`Phase_Director`), and On-Screen Simulation Benchmarks (`simulate_until`).
  - Added `.\build.ps1 quest` and `.\build.ps1 run-quest` build automation.
- **Main Boss Game Refactor (`src/main.odin`)**:
  - Integrated `coroutine.Phase_Director` into `Boss` struct and game lifecycle.
