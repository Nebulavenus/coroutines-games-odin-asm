Here is an in-depth industry analysis of game engine timing, an audit of our current coroutine scheduler, and a complete design proposal for a **3-Tier Engine Clock** that is pluggable and 100% engine-agnostic.

---

# 1. Industry Standard Time Architecture

In commercial engines (Unreal, Unity, Frostbite, Source, and SkookumScript), time is never a single `float dt`. Modern engines separate time into **three distinct domains**:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         THE 3-TIER ENGINE CLOCK                             │
├───────────────────────┬────────────────────────────┬────────────────────────┤
│ 1. Real / Wall Clock  │ 2. Scaled Sim Clock (f64)  │ 3. Fixed Sim Ticks(u64)│
├───────────────────────┼────────────────────────────┼────────────────────────┤
│ • Unscaled & unpaused │ • Affected by time_scale   │ • Discrete integer     │
│ • Real-world seconds  │   (slow-mo / fast-forward) │   increments (e.g. Hz) │
│ • UI, menus, network  │ • Pauses when game pauses  │ • Deterministic physics│
│   heartbeats, profiler│ • AI, combat, cutscenes,   │   & rollback netcode   │
│   and telemetry       │   tweens, timers           │ • Exact replay systems │
└───────────────────────┴────────────────────────────┴────────────────────────┘
```

### Why `f32` Fails for Game Timers (The Math)

An IEEE-754 32-bit float (`f32`) has a **24-bit significand** (approx. 7 decimal digits of precision):
* **At 1 hour ($3,600\text{ s}$):** Resolution drops to $\approx 0.00024\text{ s}$ ($0.24\text{ ms}$).
* **At 9.1 hours ($32,768\text{ s} = 2^{15}\text{ s}$):** Adding $1\text{ ms}$ ($0.001\text{ s}$) is partially rounded away.
* **At 18.2 hours ($65,536\text{ s} = 2^{16}\text{ s}$):** The machine epsilon is $\approx 7.8\text{ ms}$. Adding a normal $16.6\text{ ms}$ ($60\text{ FPS}$) frame loses nearly half its precision bits. Adding small sub-frame deltas is **completely ignored**.

#### The SkookumScript Solution:
1. **`f64` for Simulation Seconds:** A 64-bit float has a **53-bit significand** ($\approx 15\text{-}17\text{ decimal digits}$). It can run continuously for **thousands of years** with microsecond precision.
2. **`u64` for Integer Ticks:** 64-bit integer ticks (milliseconds or microseconds) **never suffer from floating-point rounding errors**, never drift between different CPU architectures, and overflow only after **584 million years**.
3. **Absolute Timestamps vs. Relative Delta Subtraction:**
   * *Anti-Pattern:* Decrementing `timer -= dt` every frame. Floating-point subtraction accumulates compounding rounding errors over thousands of frames.
   * *Correct Pattern:* Calculate `wake_time = current_time + duration` once at sleep time, and test `current_time >= wake_time`.

---

# 2. Audit: Is Our Current Scheduler Accurate & Deterministic?

### Where We Are Already Accurate:
1. **Absolute `f64` Timestamps:** Our scheduler already stores `wake_time: f64` and `current_time: f64`, completely preventing the 9-hour `f32` degradation trap.
2. **Min-Heap $O(\log N)$ Precision:** Timers wake based on absolute timestamp comparison (`root.wake_time <= sched.current_time`) rather than frame-by-frame float subtraction.
3. **Sequential Execution Order:** Single-threaded execution ensures zero nondeterministic data races.

### Where Our Current Gaps Are:
1. **No Real / Wall Clock:** If `sched.is_paused = true`, `current_time` freezes. There is currently no way for a fiber to run in unscaled real-time (e.g. pause menu animations, loading screen fades, network timeout guards).
2. **No Integer Discrete Ticks:** Frame counters (`current_frame: u64`) exist, but there is no dedicated integer simulation tick (`sim_ticks: u64`) for fixed-step deterministic physics/netcode.
3. **Hardcoded Engine Time Step:** `scheduler_step(sched, dt)` assumes the caller passes a float `dt`, rather than supporting pluggable fixed-step or discrete tick drivers.

---

# 3. Proposed Design: The 3-Tier Engine Clock Architecture

We can upgrade `Scheduler` to incorporate a **multi-clock engine structure**:

```odin
Time_Clock :: enum u8 {
    Sim_Scaled,  // Affected by time_scale and pause (Default for gameplay)
    Real_Time,   // Always runs at 1.0x real wall-clock speed (UI, menus)
    Fixed_Tick,  // Driven by fixed integer discrete ticks (Physics, netcode)
}

Scheduler_Clock :: struct {
    // --- 1. Real / Wall Clock (Unscaled & Unpaused) ---
    real_time:         f64,     // Absolute real-world seconds since start
    real_delta:        f32,     // Real-world frame delta (seconds)
    real_ticks:        u64,     // Real-world millisecond/microsecond integer timestamp

    // --- 2. Simulation Clock (Scaled & Pausable) ---
    sim_time:          f64,     // Scaled simulation seconds since start
    sim_delta:         f32,     // Scaled delta for this step
    time_scale:        f32,     // Multiplier (1.0 = normal, 0.5 = slow-mo, 2.0 = fast)
    is_paused:         bool,    // Freeze sim_time when true

    // --- 3. Discrete Simulation Ticks (Deterministic Integer Clock) ---
    sim_ticks:         u64,     // Integer simulation ticks (e.g. 1 tick = 1 ms or 1 fixed physics step)
    tick_rate_hz:      u32,     // e.g. 60 Hz, 120 Hz, or 1000 Hz (default: 1000 = 1 tick per ms)
    frame_count:       u64,     // Total scheduler steps executed
}
```

---

# 4. Engine-Agnostic Pluggable Time Drivers

To make this completely agnostic to any game engine or custom timing loop, the scheduler can be advanced via **three distinct entry points**:

```
                       SCHEDULER TIME DRIVERS
 ┌───────────────────────────┬───────────────────────────┬───────────────────────────┐
 │ 1. Variable Delta Step    │ 2. Fixed-Tick Step        │ 3. Dual-Delta Step        │
 │    scheduler_step(dt)     │    scheduler_step_tick(N) │    scheduler_step_dual    │
 ├───────────────────────────┼───────────────────────────┼───────────────────────────┤
 │ Standard games passing    │ Deterministic physics,    │ Explicitly passes both    │
 │ variable frame delta from │ rollback netcode, headless│ real_dt and sim_dt        │
 │ Raylib / GLFW / SDL.      │ CI benchmarks, replays.   │ from engine subsystems.   │
 └───────────────────────────┴───────────────────────────┴───────────────────────────┘
```

### Driver 1: Variable Delta Step (`scheduler_step`)
```odin
scheduler_step :: proc(sched: ^Scheduler, dt: f32) {
    real_dt := dt
    sim_dt  := sched.clock.is_paused ? 0.0 : f64(dt * sched.clock.time_scale)

    sched.clock.real_delta = real_dt
    sched.clock.real_time += f64(real_dt)
    sched.clock.real_ticks += u64(real_dt * 1000.0)

    sched.clock.sim_delta = f32(sim_dt)
    sched.clock.sim_time += sim_dt
    sched.clock.sim_ticks += u64(sim_dt * 1000.0)
    sched.clock.frame_count += 1

    scheduler_advance_queues(sched)
}
```

### Driver 2: Fixed Integer Tick Step (`scheduler_step_ticks`)
For 100% deterministic physics, lockstep networking, or headless simulation:
```odin
// Advances by exact integer ticks (e.g., 16 ms per fixed tick at 60Hz)
scheduler_step_ticks :: proc(sched: ^Scheduler, ticks: u64) {
    sec := f64(ticks) / f64(sched.clock.tick_rate_hz)
    sched.clock.sim_ticks += ticks
    sched.clock.sim_time += sec
    sched.clock.sim_delta = f32(sec)
    sched.clock.frame_count += 1

    scheduler_advance_queues(sched)
}
```

---

# 5. Expressive Multi-Domain Waiting Primitives

With the 3-Tier Clock, gameplay programmers can choose the exact clock domain for their coroutines:

```odin
// 1. Simulation Time (Pausable & Scaled - Standard Gameplay)
coroutine.wait(f, 2.5)           // Waits 2.5 scaled simulation seconds

// 2. Real / Wall Time (Unpausable & Unscaled - UI / Menus / Networking)
coroutine.wait_real(f, 0.5)      // Waits 0.5 real wall-clock seconds even if game is paused!

// 3. Discrete Integer Ticks (Deterministic Physics / Replays)
coroutine.wait_ticks(f, 60)      // Waits exactly 60 simulation ticks

// 4. Frame Count
coroutine.wait_frames(f, 3)      // Waits exactly 3 scheduler steps
```

### Example: Unpausable Pause Menu Animation
```odin
pause_menu_fade_coroutine :: proc(f: ^coroutine.Fiber, menu: ^Pause_Menu) {
    // Game is paused! (g_game.sched.clock.is_paused = true)
    // Using wait_real allows UI animations to run smoothly at normal speed:
    for menu.alpha < 1.0 {
        coroutine.yield_frame(f)
        menu.alpha += coroutine.delta_real(f) * 4.0 // 0.25s fade
    }
}
```

---

# 6. Min-Heap Multi-Clock Integration

To support both **Sim Time** and **Real Time** sleeping fibers without creating separate heaps, each sleeping fiber records its target clock:

```odin
Fiber :: struct {
    // ...
    wake_time:   f64,
    wake_clock:  Time_Clock, // .Sim_Scaled vs .Real_Time vs .Fixed_Tick
    // ...
}
```

In the scheduler tick:
- **Sim Timers** wake when `fiber.wake_time <= sched.clock.sim_time`.
- **Real Timers** wake when `fiber.wake_time <= sched.clock.real_time`.
- **Tick Timers** wake when `fiber.wake_ticks <= sched.clock.sim_ticks`.

---

# Summary & Discussion

1. **Precision:** Using `f64` for simulation seconds + `u64` for integer ticks guarantees that games can run for months on dedicated servers or consoles without timing drift or precision loss.
2. **Deterministic Simulation:** Discrete integer ticking (`scheduler_step_ticks`) enables lockstep netcode, replay reproduction, and instant headless testing.
3. **Ergonomics:** Programmers get `wait_real(f, sec)` for UI and `wait_ticks(f, ticks)` for physics without needing separate scheduler instances.

What do you think of this 3-tier clock design? Shall we proceed to implement it?
