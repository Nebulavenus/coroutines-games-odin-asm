# Changelog

All notable changes to this project will be documented in this file.

## [QoL Enhancements & Ergonomic Cleanups] - 2026-08-24

### Added
- **Vector `tween` Overloads (`tween :: proc{tween_f32, tween_vec2, tween_vec3, tween_vec4}`)**:
  - Direct single-line interpolation for `[2]f32` (Vector2), `[3]f32` (Vector3), and `[4]f32` (Vector4 / Color).
- **Direct Procedure Passing in `with_timeout` (`with_timeout :: proc{with_timeout_branch, with_timeout_ptr, with_timeout_val, with_timeout_nil}`)**:
  - Allows passing procedures directly to `with_timeout(f, seconds, entry, ...)` without manually wrapping with `coroutine.branch(...)`.
- **`wait_while` Helper Group (`wait_while :: proc{wait_while_ptr, wait_while_val, wait_while_nil}`)**:
  - Natural dual of `wait_until`, eliminating double-negative condition logic.
- **Scope Query Helpers (`scope_active_count`, `scope_is_busy`, `scope_is_empty`)**:
  - Inspect active fiber count and running status for any entity's `Fiber_Scope`.
- **`wait_until_val` and Unified `wait_until` Overloads (`wait_until :: proc{wait_until_ptr, wait_until_val, wait_until_nil}`)**:
  - Value-based predicate parameter support matching `spawn` and `branch`.
- **Unit Tests 45–50 (`src/coroutine/coroutine_test.odin`)**:
  - Added unit test coverage for ephemeral stack frame destruction safety, vector tweens, direct procedure `with_timeout` overloads, `wait_while`, `wait_until_val`, and scope query helpers.

### Changed
- **Boss Centering Animation Refactor (`src/main.odin`)**:
  - Replaced multi-branch `sync` centering block with a single vector `coroutine.tween(f, &b.pos, ...)` call.
- **Showcase Station 2 Refactor (`examples/showcase/main.odin`)**:
  - Simplified `with_timeout` call to pass the capture procedure directly.

## [By-Value Coroutine Spawning & Branching] - 2026-08-24

### Added
- **Embedded 128-Byte Inline Fiber Payload Storage (`FIBER_PAYLOAD_SIZE :: 128`)**:
  - `Fiber` and `Branch_Desc` structures now carry an inline fixed-size byte buffer (`payload_storage: [128]byte`) and procedure pointer (`user_fn: rawptr`).
  - Eliminates heap allocations (`new()`, `defer free()`) and dangling stack frame bugs for transient arguments (primitives, math vectors, and parameter structs $\le 128$ bytes).
  - Enforced via compile-time assertion `#assert(size_of(T) <= FIBER_PAYLOAD_SIZE)`.
- **`spawn_val` & `branch_val` Procedure Overloads**:
  - `spawn :: proc{spawn_ptr, spawn_val, spawn_nil}` automatically dispatches to by-value or by-pointer execution without user code boilerplate.
  - `branch :: proc{branch_ptr, branch_val, branch_nil}` supports by-value branch creation for `coroutine.sync` and `coroutine.race`.
  - Disambiguated using Odin's `where !intrinsics.type_is_pointer(T)` predicate.
- **Unit Tests 40–44 (`src/coroutine/coroutine_test.odin`)**:
  - Added unit test coverage for by-value primitives, composite structs, 32-fiber zero-crosstalk concurrency, `sync` with value branches, and `race` with value branches.

### Changed
- **Gameplay Cleanup (`src/main.odin`)**:
  - Refactored `trigger_camera_shake` and `camera_shake_coroutine` to pass `intensity: f32` directly by value without `new(f32)` and `defer free(i)`.

## [Ergonomic API Refinement] - 2026-08-20

### Changed
- **Unified `spawn` proc group**: `spawn :: proc{spawn_typed, spawn_nil}` — eliminates `_nil` suffix; call `spawn(...)` for both typed and nil-payload variants.
- **Unified `branch` proc group**: `branch :: proc{branch_typed, branch_nil}` — same unification for branch descriptors.
- **Unified `wait_until` proc group**: `wait_until :: proc{wait_until_typed, wait_until_nil}` — replaces separate `wait_until`/`wait_cond` with single entry point.
- **Mutex naming cleanup**: `fiber_mutex_lock` → `mutex_lock`, `fiber_mutex_unlock` → `mutex_unlock`, `fiber_mutex_try_lock` → `mutex_try_lock` (removes `fiber_` prefix stutter).
- **`scope_destroy` safety**: Parameter order changed to `scope_destroy(sched: ^Scheduler, scope: ^Fiber_Scope)` — `sched` is now required and first, preventing use-after-free from missing scheduler.

### Breaking Changes
- `fiber_mutex_lock` / `fiber_mutex_unlock` / `fiber_mutex_try_lock` renamed to `mutex_lock` / `mutex_unlock` / `mutex_try_lock`.
- `scope_destroy` parameter order flipped; `sched` is no longer optional.

## [Unreleased] - 2026-08-20

### Added
- **Interactive All-Features Showcase Application (`examples/showcase/main.odin`)**:
  - Dedicated interactive game arena visualizing all 12 engine features across 7 distinct interactive stations:
    - **Station 1 (The Ritual Circle):** `sync` parallel join of 3 charging runes.
    - **Station 2 (The Capture Contest):** `race` and `with_timeout` countdown contest.
    - **Station 3 (The Energy Charger):** `Fiber_Mutex` queuing 4 AI worker drones into a single charging pad.
    - **Station 4 (The Alert Beacon):** `Signal` broadcast waking 6 sleeping sentries simultaneously.
    - **Station 5 (The Loot Forge):** `Generator(T)` procedural on-demand item rolling.
    - **Station 6 (The Async Research Lab):** `Async_Token` & `await_async` bridging OS background worker threads.
    - **Station 7 (The Telemetry Feed & Tree Inspector):** CSP `Channel(T)` log stream + `F1` real-time tree and stack watermarking visualizer.
  - Added `showcase` and `run-showcase` targets in `build.ps1`.
- **Native Stackful Coroutine Engine (`coroutine` package)**:
  - Low-level inline assembly context switch for AMD64 architecture (`asm_amd64.odin`) supporting Windows x64 ABI (GPRs + XMM6..XMM15) and System V AMD64 ABI.
  - Call/ret switch mechanism preserving frame alignment, register invariants, `#volatile` constraints, and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`).
  - Per-fiber isolated `context.temp_allocator` backed by an embedded 4KB `mem.Arena` in each `Fiber`, eliminating cross-coroutine temporary allocation hazards across yields.
  - Multi-tiered stack safety: configurable `Stack_Allocation_Mode` supporting portable heap slabs + canary watermark checks (`Standard_Slab`) and OS virtual memory allocation with hardware `PAGE_GUARD` (`Virtual_Memory_OS`).
  - Stack synthesis and bootstrap trampoline (`fiber_trampoline_entry`) initializing fiber execution.
  - Stack canary protection (64-byte magic watermark `0xDEAD_BEEF_CAFE_BABE`) with overflow detection.
  - Real-time stack watermarking (`0xAA`) and high-water stack usage calculation (`fiber_calc_stack_usage`).
  - Intrusive fiber hierarchy tree and stack memory slab pool (`pool.odin`).
  - Deterministic 5-stage scheduler (`scheduler.odin`) with:
    - O(1) Ready Queue
    - $O(\log N)$ Timer Min-Heap (`wait`) with cached index for instant removal on abort
    - Frame Wait Queue (`wait_frames`, `yield_frame`)
    - Condition Watchlist (`wait_until`, `wait_cond`)
  - SkookumScript-inspired Structured Concurrency & Advanced Primitives (`api.odin`):
    - `sync`: Spawns multiple branches and joins all before resuming parent, returning `all_succeeded: bool`.
    - `race`: Preemptive first-to-finish race that aborts sibling branches immediately.
    - `with_timeout`: Auto-cancelling time-limited task execution.
    - `Signal`: Zero-polling event broadcasting (`signal_wait`, `signal_emit`).
    - `Fiber_Mutex`: Non-blocking cooperative mutual exclusion (`fiber_mutex_lock`, `fiber_mutex_unlock`, `fiber_mutex_try_lock`).
    - `Async_Token` & `await_async`: Zero-allocation lock-free bridge allowing main-thread fibers to suspend until external background workers complete.
    - `Channel(T)`: Pure CSP typed channels supporting unbuffered rendezvous and bounded FIFO buffering (`chan_send`, `chan_recv`, `chan_try_send`, `chan_try_recv`, `chan_close`).
    - `Generator(T)`: Stateful pull-based lazy sequence generators (`generator_init`, `yield_value`, `generator_next`, `generator_destroy`).
    - `branch` / `branch_nil`: Type-safe branch builders.
    - `scope_cancel` / `fiber_cancel`: Hierarchical subtree cancellation with zero dangling child tasks.
    - `tween`: Smooth interpolation with customizable easing functions (`ease_linear`, `ease_in_quad`, `ease_out_quad`, `ease_in_out_quad`, `ease_in_out_cubic`).
  - Exhaustive 39-test unit suite (`coroutine_test.odin`) covering 4-tier deep hierarchies (`sync`/`race`), 1000-timer min-heap stress, random mid-sleep cancellations, multi-slab expansion (15+ slabs), 10-generation pool reuse, stack isolation across 50 fibers, heterogeneous scope cancellation, temporary allocator isolation across yields, timeouts, signals, mutexes, async job bridges, CSP channels, stateful generators, stack watermark telemetry, and virtual memory guard pages.
- **Interactive Raylib Boss Fight Game (`src/main.odin`)**:
  - Full graphical boss encounter rendered via `vendor:raylib`.
  - Boss AI running 3 multi-phase timelines using `race`, `sync`, and `tween`.
  - Player dash ability, camera shake, and floating damage numbers powered by dedicated coroutines.
  - Interactive F1 / TAB Coroutine Hierarchy Debugger overlay visualizing live fiber hierarchy tree, remaining timers, and real-time stack utilization telemetry.
  - Live HUD displaying active fiber count, queue sizes, boss HP, and dash status with tracking allocator (zero memory leaks).

### Fixed
- Fixed runtime assertion in `camera_shake_coroutine` by clamping decay bounds.
- Fixed floating combat text persistence bug by switching from array indices to self-managed stable heap pointers (`^Floating_Text`).
- Guarded `scope_destroy` against active fibers by canceling remaining handles before deletion.
- Added full caller-saved register clobbers in AMD64 inline assembly context switcher to prevent compiler SSA caching across stack switches.
