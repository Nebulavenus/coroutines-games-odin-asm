# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - 2026-08-20

### Added
- **Native Stackful Coroutine Engine (`coroutine` package)**:
  - Low-level inline assembly context switch for AMD64 architecture (`asm_amd64.odin`) supporting Windows x64 ABI (GPRs + XMM6..XMM15) and System V AMD64 ABI.
  - Call/ret switch mechanism preserving frame alignment, register invariants, `#volatile` constraints, and caller-saved register clobbers (`%rax`, `%rcx`, `%rdx`, `%r8`..`%r11`).
  - Stack synthesis and bootstrap trampoline (`fiber_trampoline_entry`) initializing fiber execution.
  - Stack canary protection (64-byte magic watermark `0xDEAD_BEEF_CAFE_BABE`) with overflow detection.
  - Intrusive fiber hierarchy tree and stack memory slab pool (`pool.odin`).
  - Deterministic 5-stage scheduler (`scheduler.odin`) with:
    - O(1) Ready Queue
    - $O(\log N)$ Timer Min-Heap (`wait`) with cached index for instant removal on abort
    - Frame Wait Queue (`wait_frames`, `yield_frame`)
    - Condition Watchlist (`wait_until`, `wait_cond`)
  - SkookumScript-inspired Structured Concurrency (`api.odin`):
    - `sync`: Spawns multiple branches and joins all before resuming parent, returning `all_succeeded: bool`.
    - `race`: Preemptive first-to-finish race that aborts sibling branches immediately.
    - `branch` / `branch_nil`: Type-safe branch builders.
    - `scope_cancel` / `fiber_cancel`: Hierarchical subtree cancellation with zero dangling child tasks.
    - `tween`: Smooth interpolation with customizable easing functions (`ease_linear`, `ease_in_quad`, `ease_out_quad`, `ease_in_out_quad`, `ease_in_out_cubic`).
  - Exhaustive 27-test unit suite (`coroutine_test.odin`) covering 4-tier deep hierarchies (`sync`/`race`), 1000-timer min-heap stress, random mid-sleep cancellations, multi-slab expansion (15+ slabs), 10-generation pool reuse, stack isolation across 50 fibers, heterogeneous scope cancellation, 10,000-yield loops, and zero/negative boundary conditions.
- **Interactive Raylib Game (`src/main.odin`)**:
  - Full graphical boss encounter rendered via `vendor:raylib`.
  - Boss AI running 3 multi-phase timelines using `race`, `sync`, and `tween`.
  - Player dash ability, camera shake, and floating damage numbers powered by dedicated coroutines.
  - Live HUD displaying active fiber count, queue sizes, boss HP, and dash status with tracking allocator (zero memory leaks).

### Fixed
- Fixed runtime assertion in `camera_shake_coroutine` by clamping decay bounds.
- Fixed floating combat text persistence bug by switching from array indices to self-managed stable heap pointers (`^Floating_Text`).
- Guarded `scope_destroy` against active fibers by canceling remaining handles before deletion.
- Added full caller-saved register clobbers in AMD64 inline assembly context switcher to prevent compiler SSA caching across stack switches.
