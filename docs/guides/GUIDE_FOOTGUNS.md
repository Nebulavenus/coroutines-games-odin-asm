# The 10 Cooperative Fiber Footguns & Prevention Guide

> **MANDATORY READING FOR ALL GAMEPLAY AND SYSTEMS ENGINEERS**:
> Stackful cooperative coroutines provide unmatched clarity for complex gameplay state machines, hierarchical AI, cutscenes, and async pipelines. However, because fibers are **cooperative single-threaded execution contexts**, misuse can cause subtle deadlocks, memory corruption, or frame freezes.
> This guide details the **10 real-world footguns**, how they break code, how the engine mitigates them programmatically, and the golden rules to prevent them.

---

## The 10 Footguns Overview

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                          THE 10 FIBER FOOTGUNS                              │
├──────────────────────────────────────┬──────────────────────────────────────┤
│ 1. The Non-Yielding Infinite Loop    │ 6. The Orphaned Channel Receiver     │
│ 2. The 32KB Stack Overflow           │ 7. Cross-Fiber Temp Allocator Escape │
│ 3. The Dangling Ephemeral Pointer    │ 8. Save-Game Stack Serialization     │
│ 4. Stale Pointers Across Sleeps      │ 9. Cumulative Time Drift Loop        │
│ 5. The Deadlocked Mutex / Semaphore  │ 10. Unstructured Task Slices (Orphans)│
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
        // Forgot coroutine.yield_frame(f) or coroutine.wait(f, dt)!
    }
}
```

### How the Engine Mitigates It
1. **Debug Watchdog Timer**: In debug builds (`when ODIN_DEBUG`), the scheduler measures the wall-clock execution duration of every fiber slice.
2. If a single fiber slice exceeds the threshold (`watchdog_max_slice_ms = 100.0`), the engine immediately triggers a descriptive runtime panic naming the runaway fiber:
   ```text
   [WATCHDOG PANIC] Runaway non-yielding fiber detected! Fiber [#4] 'boss_ai' executed for 103.42 ms without yielding! Did you write an infinite loop without wait() or yield_frame()?
   ```
3. Configurable via `coroutine.scheduler_set_watchdog(&sched, enabled = true, max_slice_ms = 50.0)`.

### The Rule
> **Every `for` loop that spans multiple frames or polls conditions must contain an explicit suspension point: `wait(f, seconds)`, `yield_frame(f)`, `wait_ticks(f, n)`, or `wait_until(f, condition)`.**

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
Acquiring a lock or permit and returning early without unlocking:

```odin
// DANGEROUS:
charge_pad_fiber :: proc(f: ^coroutine.Fiber, m: ^coroutine.Fiber_Mutex) {
    coroutine.mutex_lock(f, m)
    if player_is_too_far() {
        return // BUG: Forgot mutex_unlock! Other fibers starved forever!
    }
    coroutine.mutex_unlock(f.sched, m)
}
```

### How the Engine Mitigates It
1. **Deadlock-Proof Scoped Locks (`with_mutex` / `with_semaphore`)**:
   ```odin
   // BEST: 100% deadlock-proof! Automatically guarantees unlock on return or abort:
   coroutine.with_mutex(f, m, proc(f: ^coroutine.Fiber, data: ^Task_Data) {
       if player_is_too_far() do return // Safe!
       perform_exclusive_work(data)
   }, data)
   ```
2. **Native Odin `defer`**:
   ```odin
   // SAFE: Guaranteed to unlock on return, break, or failure!
   charge_pad_fiber :: proc(f: ^coroutine.Fiber, m: ^coroutine.Fiber_Mutex) {
       coroutine.mutex_lock(f, m)
       defer coroutine.mutex_unlock(f.sched, m)

       if player_is_too_far() do return
   }
   ```
3. **Guaranteed Cancellation Cleanup (`fiber_set_cleanup`)**:
   ```odin
   coroutine.fiber_set_cleanup(f, proc(user_data: rawptr) {
       m := (^coroutine.Fiber_Mutex)(user_data)
       coroutine.mutex_unlock(g_sched, m)
   }, m)
   ```

### The Rule
> **Prefer `with_mutex` / `with_semaphore` for all scoped operations, or write `defer mutex_unlock(f.sched, m)` immediately after acquiring a lock.**

---

## Footgun 6: Orphaned Channel Receivers (Channel Leaks & Deadlocks)

### The Trap
A sender fiber terminates without closing a channel, leaving receiver fibers blocked in `chan_recv` indefinitely:

```odin
// DANGEROUS:
producer_fiber :: proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(int)) {
    coroutine.chan_send(f, ch, 100)
    // Exited without closing! Receiver waits forever!
}
```

### How the Engine Mitigates It
1. **Auto-Wake on Destruction (`chan_destroy`)**: Calling `chan_destroy` automatically triggers `chan_close`, unblocking all waiting senders and receivers with `ok = false` before deleting memory.
2. **Channel Deadline Reception (`chan_recv_timeout`)**:
   ```odin
   val, ok, timed_out := coroutine.chan_recv_timeout(f, &g_channel, timeout_seconds = 2.0)
   if timed_out {
       log_warn("Producer hung or disappeared!")
   }
   ```

### The Rule
> **Always use `defer chan_close(&ch)` in producer fibers, or use `chan_recv_timeout` when reading from untrusted producers.**

---

## Footgun 7: Cross-Fiber Temporary Memory Escapes

### The Trap
Allocating memory from `context.temp_allocator` inside Fiber A and passing the pointer to Fiber B:

```odin
// DANGEROUS:
fiber_a :: proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel([]int)) {
    data := make([]int, 10, context.temp_allocator) // Allocated in Fiber A's private temp arena!
    coroutine.chan_send(f, ch, data)
    // Fiber A finishes -> its 4KB temp arena is recycled/wiped! Fiber B reads garbage!
}
```

### How the Engine Mitigates It
* Each fiber has an **isolated 4KB `temp_arena`**. `context.temp_allocator` points to this private arena.

### The Rule
> **Treat `context.temp_allocator` as strictly private to the allocating fiber. Data communicated across fibers via channels must be copied by value (`Channel(T)` / `spawn_val`) or allocated with the general allocator.**

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
     coroutine.phase_switch(&boss.director, saved_phase, boss_phase2_fiber, &boss)
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
Use the built-in **`coroutine.Ticker`** (`ticker_init`, `ticker_wait`). The ticker advances target timestamps via absolute interval arithmetic ($\text{target\_time} += \text{interval}$), guaranteeing zero cumulative time drift regardless of frame execution variations.

```odin
// SAFE & DRIFT-FREE:
poison_dot_fiber :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    ticker: coroutine.Ticker
    coroutine.ticker_init(&ticker, interval_seconds = 0.5)

    for _ in 0 ..< 10 { // Exactly 10 ticks over 5.0 seconds
        coroutine.ticker_wait(f, &ticker)
        enemy.hp -= 10.0
    }
}
```

### The Rule
> **Never use naive `wait(f, interval)` loops for periodic heartbeats or rhythm-critical game actions. Use `coroutine.Ticker`.**

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
2. **Entity Scopes (`Fiber_Scope` & `scope_wait`)**: For dynamic clusters attached to an entity, pass `scope = &boss.scope`. Calling `scope_destroy` guarantees every child is terminated.

### The Rule
> **Prefer Structured Concurrency (`sync`/`race`) for hierarchical workflows, and `Fiber_Scope` (`scope_wait`) for entity lifecycle clusters. Never leave detached background handles unowned.**

---

## Summary: The Gameplay Programmer's Golden Rules Cheat Sheet

```text
┌─────────────────────────────────────────────────────────────────────────────┐
│                    THE GAMEPLAY PROGRAMMER'S CHEAT SHEET                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ 1. Always yield inside loops: Use wait(), yield_frame(), or Ticker.        │
│ 2. Keep stack buffers small: Use dynamic arrays for large data (>1 KB).     │
│ 3. Pass transient parameters by value: Let the 128B payload buffer copy it. │
│ 4. Bind fibers to entity scopes: scope_destroy() cancels them on death.     │
│ 5. Use with_mutex / with_semaphore: Guarantees deadlock-free scoped unlock. │
│ 6. Always close producer channels: Write defer chan_close(&ch).             │
│ 7. Treat temp memory as private: Do not pass temp slices across fibers.     │
│ 8. Save game state, not stacks: Re-spawn coroutines from phase checkpoints. │
│ 9. Use Ticker for periodic loops: Eliminates cumulative delta-time drift.   │
│ 10. Embrace Structured Concurrency: Use sync/race to prevent orphan tasks.  │
└─────────────────────────────────────────────────────────────────────────────┘
```