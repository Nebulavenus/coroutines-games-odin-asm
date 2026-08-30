# Changelog

All notable changes to this project will be documented in this file.

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
