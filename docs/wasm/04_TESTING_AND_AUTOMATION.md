# WebAssembly Testing & CI Automation

This document catalogs the 16 automated WebAssembly test suites in `examples/wasm_test/main.odin`, details the headless Node.js verification harnesses, and outlines continuous integration practices for WebAssembly coroutines.

---

## 1. Automated Test Suite Catalog (`examples/wasm_test/main.odin`)

The WebAssembly test runner validates every core engine primitive across 16 automated suites under `.\build.ps1 test-wasm`:

| Suite # | Test Name | Target Subsystem | Key Verification |
| :--- | :--- | :--- | :--- |
| **Test 1** | **Minimal Spawn & Finish** | `spawn`, `scheduler_step` | Fiber spawns, advances state, and reaches natural `.Finished` status. |
| **Test 2** | **Local Variables Across Yields** | Asyncify Rewind | Validates that local scalar variables (`a`, `b`, `sum`) survive unwinds and rewinds without corruption. |
| **Test 3** | **Multiple Concurrent Fibers** | Cooperative Scheduling | 3 fibers running simultaneously interleave execution frames in deterministic sequence. |
| **Test 4** | **Structured Concurrency (`sync`)** | `sync_combinator` | Parent fiber waits until all child branches complete before advancing. |
| **Test 5** | **Structured Concurrency (`race`)** | `race_combinator` | First branch to complete cancels all competing sibling branches immediately. |
| **Test 6** | **CSP Channel Rendezvous** | `Channel(T)` | Symmetrical unbuffered sender-first and receiver-first handoffs execute cleanly. |
| **Test 7** | **Multi-Domain Clocks** | `Time_Clock` | Validates time-scaled simulation clock vs. wall-clock real time under 0.5x scaling and pause. |
| **Test 8** | **Structured `Fiber_Scope`** | Scoped Cancellation | `scope_cancel` recursively aborts an entire tree of 10 fibers and reclaims heap nodes. |
| **Test 9** | **Signal Primitives** | `Signal`, `signal_wait` | Multi-waiter FIFO scheduling: `signal_emit` wakes waiters in exact registration order. |
| **Test 10** | **Nested Combinator Aborts** | `race` canceling `sync` | A fast racing timer aborts an active nested `sync` containing multiple child attack loops. |
| **Test 11** | **Ticker Zero-Drift Precision** | `Ticker`, `wait_ticker` | Steps 5 discrete frames @ 0.02s; asserts exactly 5 discrete ticks with zero timing drift. |
| **Test 12** | **Multi-Round EMP Stun Fuzzing** | Signals, Timers & Heap | Simulates 300 frames of rapid, randomized EMP signal stuns with 0 leaked fibers or heap nodes. |
| **Test 13** | **Verse `rush()` Combinator** | `rush_combinator` | First branch to succeed unblocks parent; losing arms continue executing in background. |
| **Test 14** | **Verse `branch_scoped()`** | `branch_scoped` | Spawns parent-bound fire-and-forget subtask; automatically aborted when parent exits. |
| **Test 15** | **Latched State (`Sticky_Event`)** | `Sticky_Event`, `Sticky_Signal` | Emits before await; late-joining fiber receives cached state immediately in $O(1)$. |
| **Test 16** | **In-Frame Timeslice (`yield_now`)** | `yield_now` | Multiple fibers interleave cooperative timeslices in the same frame without advancing clock. |

---

## 2. Headless Node.js Testing Infrastructure

To allow WebAssembly tests to run seamlessly in continuous integration (GitHub Actions, Linux containers, or local terminals without opening a web browser), we provide two headless Node.js harnesses:

### 1. `tools/run_wasm.js`
Executes `examples/wasm_test/main.odin`:
```javascript
const fs = require('fs');
const wasmBuffer = fs.readFileSync('build/wasm_test/test_opt.wasm');

// Minimal host imports providing write to stdout and clock access
const importObject = {
    odin_env: {
        write: (fd, ptr, len) => { /* write to stdout */ },
        performance_now: () => performance.now(),
    }
};

WebAssembly.instantiate(wasmBuffer, importObject).then(({ instance }) => {
    instance.exports._start();
});
```

### 2. `tools/web/test_headless_game.js`
Runs the complete Boss Battle game engine for **1000 frames** (16.7 seconds @ 60 FPS) in Node.js:
- Emulates a mock `<canvas>` 2D context.
- Verifies that `game_wasm_init()`, `game_wasm_step(0.0166667)`, and `game_wasm_destroy()` execute with zero panics.
- Validates over **300,000 drawing commands** and **160,000 colored shapes**, verifying that graphics commands are continuously generated and that the coroutine AI state machines never hang.

---

## 3. Running Automated Tests

```powershell
# Run the complete 16-suite Wasm test runner:
.\build.ps1 test-wasm

# Run the 1000-frame headless game simulation test:
.\build.ps1 test-web-game

# Verify native unit tests (182 tests across all architectures):
.\build.ps1 test
```

### Expected Output for `test-wasm`:
```text
Running WebAssembly test suite via Node.js...
Post-processing with Binaryen Asyncify...
=================================================================================
   WEBASSEMBLY (js_wasm32) COMPLETE COROUTINE PRIMITIVES TEST SUITE             
=================================================================================

  [Test 1] Minimal Fiber Spawn & Natural Finish... OK
  [Test 2] Local Variables Preserved Across Yields... OK
  [Test 3] Multiple Concurrent Fibers Interleaving... OK
  [Test 4] Structured Concurrency: sync() Combinator... OK
  [Test 5] Structured Concurrency: race() Winner Cancels Loser... OK
  [Test 6] CSP Channel: Symmetrical Rendezvous... OK
  [Test 7] Multi-Domain Clocks: Time Scaling & Real Time... OK
  [Test 8] Structured Fiber_Scope: Cancellation & Tree Pruning... OK
  [Test 9] Signal Primitives: FIFO Wake & Waiter Tracking... OK
  [Test 10] Nested race() Cancels Nested sync() with Child Tickers... OK
  [Test 11] Ticker Precision, Zero-Drift & Safe Scope Abort... OK
  [Test 12] Multi-Round EMP Stun AI Fuzzing & Memory Invariants... OK
  [Test 13] Verse rush(): Losers Continue in Background... OK
  [Test 14] Verse branch_scoped(): Parent-Bound Lifecycle... OK
  [Test 15] Latched State: Sticky_Event & Sticky_Signal... OK
  [Test 16] In-Frame Timeslice: yield_now() Same-Tick Interleave... OK

=================================================================================
ALL 16 WEBASSEMBLY COROUTINE TEST SUITES PASSED (0 FAILURES)
=================================================================================
```
