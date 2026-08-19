# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased] - 2026-08-20

### Added
- **Native Stackful Coroutine Engine (`coroutine` package)**:
  - Low-level inline assembly context switch for AMD64 architecture (`asm_amd64.odin`) supporting Windows x64 ABI (GPRs + XMM6..XMM15) and System V AMD64 ABI.
  - Call/ret switch mechanism preserving frame alignment and register invariants.
  - Stack synthesis and bootstrap trampoline (`fiber_trampoline_entry`) initializing fiber execution.
  - Stack canary protection (64-byte magic watermark `0xDEAD_BEEF_CAFE_BABE`) with overflow detection.
  - Intrusive fiber hierarchy tree and stack memory slab pool (`pool.odin`).
  - Deterministic 5-stage scheduler (`scheduler.odin`) with:
    - O(1) Ready Queue
    - $O(\log N)$ Timer Min-Heap (`wait`) with cached index for instant removal on abort
    - Frame Wait Queue (`wait_frames`, `yield_frame`)
    - Condition Watchlist (`wait_until`, `wait_cond`)
  - SkookumScript-inspired Structured Concurrency (`api.odin`):
    - `sync`: Spawns multiple branches and joins all before resuming parent.
    - `race`: Preemptive first-to-finish race that aborts sibling branches immediately.
    - `branch` / `branch_nil`: Type-safe branch builders.
    - `scope_cancel` / `fiber_cancel`: Hierarchical subtree cancellation with zero dangling child tasks.
    - `tween`: Smooth interpolation with customizable easing functions (`ease_linear`, `ease_in_quad`, `ease_out_quad`, `ease_in_out_quad`, `ease_in_out_cubic`).
  - Complete TDD test suite (`coroutine_test.odin`) covering context switching, stack persistence across yields, time/frame/condition waits, `sync`, `race`, scope cancellation, destructors, canary validation, and tweens.
