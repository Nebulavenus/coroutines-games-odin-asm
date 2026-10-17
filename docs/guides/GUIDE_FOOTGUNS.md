# The 13 Cooperative Fiber Footguns & Prevention Guide

> **MANDATORY READING FOR ALL GAMEPLAY AND SYSTEMS ENGINEERS**:
> Stackful cooperative coroutines provide unmatched clarity for complex gameplay state machines, hierarchical AI, cutscenes, and async pipelines. However, because fibers are **cooperative single-threaded execution contexts**, misuse can cause subtle deadlocks, memory corruption, or frame freezes.
> This guide details the **13 real-world footguns**, how they break code, how the engine mitigates them programmatically, and the golden rules to prevent them.

---

## The 11 Footguns Overview

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          THE 11 FIBER FOOTGUNS                              │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ 1. The Non-Yielding Infinite Loop    │ 7. Cross-Fiber Temp Allocator Escape │
│ 2. The 32KB Stack Overflow           │ 8. Save-Game Stack Serialization     │
│ 3. The Dangling Ephemeral Pointer    │ 9. Cumulative Time Drift Loop        │
│ 4. Stale Pointers Across Sleeps      │ 10. Unstructured Task Slices (Orphans)│
│ 5. The Deadlocked Mutex / Semaphore  │ 11. Storing Raw ^Fiber Pointers      │
│ 6. The Orphaned Channel Receiver     │                                      │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## Footgun 1: The Non-Yielding Infinite Loop (Freezing the Main Thread)

### The Trap
Because fibers are **cooperative** (not preemptive OS threads), a fiber retains exclusive control of the CPU until it yields. If a `for` loop executes without a suspension point, the entire game engine freezes permanently:

```odin
// DANGEROUS: Freezes the entire game window permanently!
boss_ai :: proc(f: ^coroutine.Fiber, boss: ^Boss) {
    for !boss.is_ready {
        // Forgot coroutine.yield(f) or coroutine.wait(f, dt)!
    }
}
```

### How the Engine Mitigates It
1. **Debug Watchdog Timer**: In debug builds (`when ODIN_DEBUG`), the scheduler measures the wall-clock execution duration of every fiber slice.
2. If a single fiber slice exceeds the threshold (`watchdog_max_slice_ms = 100.0`), the engine immediately triggers a descriptive runtime panic naming the runaway fiber:
   ```text
   [WATCHDOG PANIC] Runaway non-yielding fiber detected! Fiber [#4] 'boss_ai' executed for 103.42 ms without yielding! Did you write an infinite loop without wait() or yield()?
   ```
3. Configurable via `coroutine.scheduler_set_watchdog(&sched, enabled = true, max_slice_ms = 50.0)`.

### The Rule
> **Every `for` loop that spans multiple frames or polls conditions must contain an explicit suspension point: `wait(f, seconds)`, `yield(f)`, or `wait_steps(f, count)`.**

---

## Footgun 2: The 32KB Stack Overflow (Oversized Stack Buffers)

### The Trap
Fibers use fixed-size memory stacks (default **32KB**). Allocating large local arrays directly on the stack blows past the stack bounds:

```odin
// DANGEROUS: 10,000 floats = 40 KB (Exceeds 32KB stack!)
calculate_path :: proc(f: ^coroutine.Fiber) {
    temp_grid: [10000]f32 // Stack overflow!
}
```

### How the Engine Mitigates It
1. **64-Byte Stack Canary Watermark (`0xDEAD_BEEF_CAFE_BABE`)**: Verified on every fiber recycling pass; corruptions trigger immediate panics.
2. **Hardware Guard Pages (`Stack_Allocation_Mode.Virtual_Memory_OS`)**: Uses OS virtual memory (`PAGE_GUARD` on Windows, `PROT_NONE` on POSIX) to trip a hardware exception at the exact instruction that overflowed.
3. **Usage Profiler (`fiber_calc_stack_usage`)**: Real-time stack watermarks displayed in the `F1` Hierarchy HUD.

### The Rule
> **Keep local stack variables small (<1KB). Large temporary buffers belong in dynamic arrays, arena allocators, or the heap.**

---

## Footgun 3: Dangling Ephemeral Pointers (Caller Stack Destruction)

### The Trap
Passing a pointer to a temporary stack variable into `spawn`:

```odin
// DANGEROUS:
trigger_explosion :: proc(pos: [2]f32) {
    // &pos points to trigger_explosion's local stack frame!
    coroutine.spawn(&sched, explosion_coroutine, &pos) 
    // trigger_explosion returns immediately! &pos is destroyed!
}
```

### How the Engine Mitigates It
* **128-Byte By-Value Payloads (`spawn_val` / `branch_val` / overloaded `spawn`)**:
  ```odin
  // SAFE: Automatically copied into fiber.payload_storage!
  trigger_explosion :: proc(pos: [2]f32) {
      coroutine.spawn(&sched, explosion_coroutine, pos) // Pass by value!
  }
  ```

### The Rule
> **Pass scalars, coordinates, and transient value structs by value. Pass pointers only to persistent heap entities (`^Boss`, `^Player`, `^World`).**

---

## Footgun 4: Stale Entity Pointers Across Sleeps (Entity Died Mid-Sleep)

### The Trap
Game entities can be destroyed while a fiber is suspended in `wait(f, 2.0)`:

```odin
// DANGEROUS:
wizard_attack :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    enemy.is_charging = true
    coroutine.wait(f, 2.0) // Sleeps for 2 seconds...

    // HAZARD: What if the enemy died and was freed during these 2 seconds?!
    enemy.is_charging = false // Use-After-Free CRASH!
}
```

### How the Engine Mitigates It
* **`Fiber_Scope` Structured Cancellation**:
  ```odin
  // Bind fiber to the entity's scope:
  coroutine.spawn(&sched, wizard_attack, enemy, scope = &enemy.scope)

  // When enemy dies:
  enemy_destroy :: proc(e: ^Enemy) {
      coroutine.scope_destroy(&sched, &e.scope) // Instantly cancels all active/sleeping fibers!
      free(e)
  }
  ```

### The Rule
> **Always bind entity-specific coroutines to that entity's `Fiber_Scope`. Call `scope_destroy` when the entity dies.**

---

## Footgun 5: The Deadlocked Mutex / Semaphore (Missing Unlock)

### The Trap
Acquiring a lock or permit and returning early without unlocking (primitives from `coroutine/sync`):

```odin
// DANGEROUS:
charge_pad_fiber :: proc(f: ^coroutine.Fiber, m: ^sync.Fiber_Mutex) {
    sync.mutex_lock(f, m)
    if player_is_too_far() {
        return // BUG: Forgot mutex_unlock! Other fibers starved forever!
    }
    sync.mutex_unlock(f.sched, m)
}
```

### How the Engine Mitigates It
1. **Deadlock-Proof Scoped Locks (`with_mutex` / `with_semaphore`)**:
   ```odin
   // BEST: 100% deadlock-proof! Automatically guarantees unlock on return or abort:
   sync.with_mutex(f, m, proc(f: ^coroutine.Fiber, data: ^Task_Data) {
       if player_is_too_far() do return // Safe!
       perform_exclusive_work(data)
   }, data)
   ```
2. **Native Odin `defer`**:
   ```odin
   // SAFE: Guaranteed to unlock on return, break, or failure!
   charge_pad_fiber :: proc(f: ^coroutine.Fiber, m: ^sync.Fiber_Mutex) {
       sync.mutex_lock(f, m)
       defer sync.mutex_unlock(f.sched, m)

       if player_is_too_far() do return
   }
   ```
3. **Guaranteed Cancellation Cleanup (`fiber_set_cleanup`)**:
   ```odin
   coroutine.fiber_set_cleanup(f, proc(user_data: rawptr) {
       m := (^sync.Fiber_Mutex)(user_data)
       sync.mutex_unlock(g_sched, m)
   }, m)
   ```

### The Rule
> **Prefer `sync.with_mutex` / `sync.with_semaphore` for all scoped operations, or write `defer sync.mutex_unlock(f.sched, m)` immediately after acquiring a lock.**

---

## Footgun 6: Orphaned Channel Receivers (Channel Leaks & Deadlocks)

### The Trap
A sender fiber terminates without closing a channel, leaving receiver fibers blocked in `chan_recv` indefinitely:

```odin
// DANGEROUS:
producer_fiber :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(int)) {
    sync.chan_send(f, ch, 100)
    // Exited without closing! Receiver waits forever!
}
```

### How the Engine Mitigates It
1. **Auto-Wake on Destruction (`chan_destroy`)**: Calling `sync.chan_destroy` automatically triggers `sync.chan_close`, unblocking all waiting senders and receivers with `ok = false` before deleting memory.
2. **Channel Deadline Reception (`chan_recv_timeout`)**:
   ```odin
   val, ok, timed_out := sync.chan_recv_timeout(f, &g_channel, timeout_seconds = 2.0)
   if timed_out {
       log_warn("Producer hung or disappeared!")
   }
   ```

### The Rule
> **Always use `defer sync.chan_close(&ch)` in producer fibers, or use `sync.chan_recv_timeout` when reading from untrusted producers.**

---

## Footgun 7: Cross-Fiber Temporary Memory Escapes

### The Trap
Allocating memory from `context.temp_allocator` inside Fiber A and passing the pointer to Fiber B:

```odin
// DANGEROUS:
fiber_a :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel([]int)) {
    data := make([]int, 10, context.temp_allocator) // Allocated in Fiber A's private temp arena!
    sync.chan_send(f, ch, data)
    // Fiber A finishes -> its 4KB temp arena is recycled/wiped! Fiber B reads garbage!
}
```

### How the Engine Mitigates It
* Each fiber has an **isolated 4KB `temp_arena`**. `context.temp_allocator` points to this private arena.

### The Rule
> **Treat `context.temp_allocator` as strictly private to the allocating fiber. Data communicated across fibers via channels must be copied by value (`sync.Channel(T)` / `spawn_val`) or allocated with the general allocator.**

---

## Footgun 8: Save/Load Game State Misconception (Fibers Are Not Serializers)

### The Trap
Attempting to serialize raw suspended fiber stack bytes directly to a disk save file.

* **Why It Fails**: A suspended stack contains raw machine register frames (`%rip`, `%rbp`, `%rsp`), instruction pointers, and memory addresses. Loading that raw memory on a different PC, OS version, or patched game build will immediately crash.
* **How Game Engines Solve This (The AAA State Machine Pattern)**:
  1. Fibers are **transient runtime execution threads** (cutscene animations, camera tweens, attack choreography, AI behavior trees).
  2. High-level game state is saved to disk (`boss.hp = 350`, `boss.phase = 2`, `quest.stage = 3`).
  3. When loading a save file, entities re-spawn their coroutine from the saved phase checkpoint:
     ```odin
     // On Game Load:
     coroutine.scope_cancel(&sched, &boss.phase_scope)
     coroutine.spawn(&sched, boss_phase2_fiber, &boss, scope = &boss.phase_scope)
     ```

### The Rule
> **Save game data (structs, coordinates, health, inventory), never CPU stack frames. Re-spawn coroutines from phase checkpoints upon save reload.**

---

## Footgun 9: The Cumulative Time-Drift Loop (Periodic Timers Falling Behind)

### The Trap
Writing periodic gameplay cadences (e.g. poison ticks, sensor scans, network pings) with naive relative sleeps `wait(f, interval)`. Because the work done during each loop iteration takes non-zero CPU execution time, that execution delay compounds across every frame, causing the loop to lag and drift seconds behind real game time:

```odin
// DANGEROUS: Suffers from cumulative floating-point time drift!
poison_dot_fiber :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    for {
        coroutine.wait(f, 0.5)
        heavy_ai_calculation() // If this takes 0.03s, next tick happens at 0.53s!
    }
}
```

### How the Engine Mitigates It
Use the built-in fiber-owned **`ticker_wait(f, interval)`**. The ticker advances target timestamps via absolute interval arithmetic ($t_{\text{target}} += \Delta t$), guaranteeing zero cumulative time drift regardless of frame execution variations.

```odin
// SAFE & DRIFT-FREE:
poison_dot_fiber :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    for _ in 0 ..< 10 { // Exactly 10 ticks over 5.0 seconds
        coroutine.ticker_wait(f, interval_seconds = 0.5)
        enemy.hp -= 10.0
    }
}
```

### The Rule
> **Never use naive `wait(f, interval)` loops for periodic heartbeats or rhythm-critical game actions. Use `coroutine.ticker_wait(f, interval)`.**

---

## Footgun 10: Unstructured Task Slices vs. Structured Trees (Background Orphan Fibers)

### The Trap
Spawning a dynamic array of independent fiber handles (`spawn()`) and manually polling them without parent-child ownership. If the parent fiber aborts or takes damage, the spawned background fibers **continue running as detached background orphans**, leaking CPU time and causing erratic game behavior:

```odin
// DANGEROUS:
boss_spawn_minions :: proc(f: ^coroutine.Fiber, boss: ^Boss) {
    handles: [4]coroutine.Fiber_Handle
    for i in 0 ..< 4 {
        handles[i] = coroutine.spawn(f.sched, minion_ai, &boss.minions[i])
    }
    // If boss dies or aborts here, minions KEEP RUNNING as orphaned background fibers!
}
```

### How the Engine Mitigates It
1. **Structured Concurrency (`sync`, `race`, `rush`, `fallback`)**: The parent fiber owns all branch children. If the parent or a sibling aborts, the entire branch tree is automatically cancelled and recycled bottom-up.
2. **Scope-Bound Fire-and-Forget (`branch_scoped`)**: If you need to launch a concurrent background task without suspending the parent, use `branch_scoped(f, ...)` instead of `spawn(...)`. Scoped branches are automatically bound to the parent's lifetime and aborted if the parent finishes or aborts.
3. **Entity Scopes (`Fiber_Scope` & `scope_wait`)**: For dynamic clusters attached to an entity, pass `scope = &boss.scope`. Calling `scope_cancel` guarantees every child is terminated.

### The Rule
> **Prefer Structured Concurrency (`sync`/`race`/`rush`), `branch_scoped` for parent-bound background tasks, and `Fiber_Scope` (`scope_wait`) for entity lifecycle clusters. Never leave detached background handles unowned.**

---

## Footgun 11: Storing Raw `^Fiber` Pointers Instead of Packed Generational Handles

### The Trap
Storing a bare `^Fiber` pointer across multiple frames or in external entity structs risks accessing recycled slab memory if that fiber terminates and its memory is repurposed for a new task:

```odin
// DANGEROUS: If target fiber finishes, raw_ptr becomes dangling or points to a recycled fiber!
stored_fiber: ^coroutine.Fiber = coroutine.spawn(&sched, enemy_ai_proc, &enemy)

// 5 seconds later:
if stored_fiber.status == .Running { // CRASH or corrupted state!
    // ...
}
```

### How the Engine Mitigates It
1. **Packed Generational Handles (`Fiber_Handle`)**: A 32-bit packed integer (`u16 slot | u16 generation`).
2. When a fiber slot is recycled, its generation counter is automatically incremented.
3. Checking `coroutine.fiber_is_alive(&sched, handle)` or `coroutine.fiber_find_by_handle(&sched, handle)` performs a single-instruction direct array lookup in $O(1)$ time, instantly detecting stale handles with **100% ABA safety**.

---

## Footgun 12: Inlining Across Fiber Context Switches & Register Allocation Under `-o:speed`

### The Trap
When compiling with aggressive whole-program optimization (`-o:speed -use-single-module`), the LLVM compiler inline-expands small utility procedures like `yield` or user loops. 
Under the x86-64 calling conventions (both Windows x64 and System V AMD64), registers like `%xmm0` through `%xmm5` are **caller-saved (volatile)** scratch registers. 

When a procedure containing floating-point computations (such as tweens, timers, or physics steps) is inlined across a fiber yield point, the compiler may retain intermediate loop counters (e.g. `duration`, `elapsed`, or loop bounds) in volatile floating-point registers. Because fiber context switching switches execution to the scheduler (which uses SSE/AVX registers for other tasks before switching back), those volatile scratch registers are not preserved across the switch! When the fiber resumes, values held in volatile registers are clobbered (often zeroed), causing loop bounds to immediately terminate prematurely.

Furthermore, in single-module builds where the compiler sees both the caller frame and the coroutine body, LLVM's scalar replacement of aggregates (SROA) and alias analysis may assume that local stack variables passed by reference (e.g. `out_1: f32`) cannot be modified across `scheduler_step(&sched)`, failing to reload them into registers in unit test assert loops.

```odin
// DANGEROUS UNDER -o:speed -use-single-module:
// If yield is #force_inline, the compiler may keep `duration` in volatile %xmm registers across the context switch.
for elapsed < duration {
    yield(f)
    elapsed += delta_time(f)
    // On resume, duration in %xmm register is 0.0 -> loop terminates after 1 iteration!
}
```

### How the Engine Mitigates It
1. **ABI Boundary Enforcement**: Procedures that invoke `fiber_context_switch` (`wait_steps`, `wait`, `yield`, etc.) are intentionally kept as standard non-inlined function boundaries. This forces LLVM's register allocator to spill all active caller-saved registers (`%xmm0-%xmm5`, `%rax`, `%rcx`, etc.) to the fiber stack across the call boundary according to the platform ABI.
2. **Callee-Saved Hardware Registers Preserved**: The assembly context switch (`fiber_context_switch`) fully preserves all callee-saved registers defined by the platform ABI:
   - **Win64**: `%rbx`, `%rbp`, `%rdi`, `%rsi`, `%r12-%r15`, and `%xmm6-%xmm15` (160 bytes of SIMD state).
   - **System V**: `%rbx`, `%rbp`, `%r12-%r15`.
   - **ARM64**: `x19-x28`, `fp`, `lr`, and `d8-d15` (160 bytes).
   - **RISC-V 64**: `s0-s11` and `fs0-fs11` (208 bytes).
3. **Volatile Status Reloads**: Scheduler status checks across context switches use `intrinsics.volatile_load` to prevent SSA caching across inline assembly blocks.

### The Rule
> **Keep yield/wait procedures as distinct function boundaries (never `#force_inline`). In test harnesses or benchmarks inspecting local scalar values modified by fibers across `scheduler_step`, aggregate values into structs or use pointers to ensure LLVM loads refreshed memory.**

---

## Footgun 13: WebAssembly Linear Memory Shadow-Stack Aliasing Across Asyncify Yields

### The Mistake
```odin
// DANGEROUS ON WEBASSEMBLY (js_wasm32):
Attack_Config :: struct { interval: f64, count: int }

boss_ai :: proc(f: ^coroutine.Fiber, boss: ^Boss) {
    cfg: Attack_Config // <-- Local composite struct on shared LLVM shadow stack!
    cfg.interval = 0.1
    setup_config(&cfg) // Taking address forces cfg into linear memory shadow stack
    for {
        coroutine.yield(f) // Interleaved fibers overwrite cfg in linear memory!
        fire_bullet(boss, &cfg)
    }
}
```

### What Happens
WebAssembly uses a **dual-stack model**. Asyncify serializes and restores the **VM Execution Stack** (local primitives `i32`, `f32`), but **does NOT save or partition linear memory** (`memory.buffer`). Local variables whose addresses are taken (`&cfg`) reside on the C/LLVM shadow stack pointed to by `(global $__stack_pointer)`.

Because all fibers share the single shadow stack, when `boss_ai` sleeps or yields, other interleaved fibers push their stack frames down from `$__stack_pointer` and **physically overwrite `cfg` in linear memory**. When `boss_ai` wakes, `cfg` has been corrupted by another fiber!

### The Solution
1. **Use Fiber-Owned Timing**: Use `coroutine.ticker_wait(f, interval)` (or `coroutine.wait_ticker(f, interval)`). Timing state is stored on the persistent `Fiber` struct in the pool—100% immune to shadow-stack clobbering.
2. **Keep Scalar Values in Locals**: Primitive values (`timer: f32`, `ticks: int`, `interval: f64`) live in Wasm VM registers and are perfectly restored by Asyncify.
3. **Store Composite State in Entities**: Store multi-field cross-yield state in persistent entities (`^Boss`, `^Player`) or inside the fiber's private 4KB arena (`f.temp_arena`).
4. **Deep Dive**: See [`docs/wasm/02_MEMORY_AND_LIMITATIONS.md`](../wasm/02_MEMORY_AND_LIMITATIONS.md) for full architectural analysis and stack-switching roadmap.

### The Rule
> **Never retain pointers to local stack-allocated structs across yields when targeting WebAssembly. Use fiber-owned primitives (`wait_ticker`), fiber temp arenas (`f.temp_arena`), or persistent entity structs.**

---

## Footgun 14: Accidental In-Frame Busy Spin with `yield_now` vs Frame-Boundary `yield`

### The Trap
Using `yield_now` inside a game state polling loop:

```odin
// DANGEROUS: Busy-spins within the current frame!
for !enemy.is_dead {
    coroutine.yield_now(f)
}
```

### What Happens
`coroutine.yield_now(f)` (like Epic Verse `Sleep(0.0)`) cooperatively relinquishes the CPU timeslice to other ready fibers in the **current** frame and re-enqueues itself into `sched.ready_queue` immediately.

If `enemy.is_dead` is only updated by an animation event, physics step, or combat damage in a **future** simulation tick, `yield_now(f)` will continuously re-enqueue and re-execute in the same frame without letting time advance. If other fibers also yield or complete, this fiber repeatedly spins within the current frame's `scheduler_run` loop, creating an accidental in-frame busy-spin!

### The Solution
1. **Computational Slicing**: Use `yield_now(f)` exclusively for distributing heavy computational workloads (e.g., A* pathfinding node slicing, procedural generation batches, raymarching iterations) across fibers in the current frame without causing frame hitching.
2. **Game State Polling**: Use `coroutine.yield(f)` (or `coroutine.wait(f, 0.0)`) when waiting for game state, physics, or entity health that updates across frame boundaries. `yield(f)` enqueues the fiber into the clock domain's `step_waiters` targeting the next tick ($t + 1$).
3. **Event-Driven Signaling**: Better yet, replace polling loops entirely with zero-polling events: `coroutine.signal_wait(f, &enemy.death_signal)`.

### The Rule
> **Use `yield_now(f)` only to distribute heavy CPU computation across fibers in the current tick. Use `yield(f)` or `wait(f, dt)` when waiting for gameplay state that changes across frame boundaries.**

---

## Summary: The Gameplay Programmer's Golden Rules Cheat Sheet

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE GAMEPLAY PROGRAMMER'S CHEAT SHEET                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Always yield inside loops: Use wait(), yield(), or ticker_wait().        │
│ 2. Keep stack buffers small: Use dynamic arrays for large data (>1 KB).     │
│ 3. Pass transient parameters by value: Let the 128B payload buffer copy it. │
│ 4. Bind fibers to entity scopes: scope_destroy() cancels them on death.     │
│ 5. Use with_mutex / with_semaphore: Guarantees deadlock-free scoped unlock. │
│ 6. Always close producer channels: Write defer chan_close(&ch).             │
│ 7. Treat temp memory as private: Do not pass temp slices across fibers.     │
│ 8. Save game state, not stacks: Re-spawn coroutines from phase checkpoints. │
│ 9. Use ticker_wait for periodic loops: Zero-drift timestamp anchor.         │
│ 10. Embrace Structured Concurrency: Use sync/race to prevent orphan tasks.  │
│ 11. Pass Fiber_Handle, not raw ^Fiber: 32-bit handles are 100% ABA safe.    │
│ 12. Never #force_inline yield points: Call boundaries preserve registers.   │
│ 13. Don't spin yield_now in state loops: Use yield() for next frame bounds. │
└─────────────────────────────────────────────────────────────────────────────┘
```