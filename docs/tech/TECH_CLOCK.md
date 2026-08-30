# The 3-Tier Multi-Domain Engine Clock (`TECH_CLOCK.md`)

This document provides the mathematical foundation, precision specifications, and subsystem architecture of the **3-Tier Engine Clock** implemented in the Odin Stackful Coroutine Engine.

---

## 1. The Physics & Mathematics of Game Clocks

Game engines must balance three distinct temporal concepts:
1. **Human Time (Real/Wall Time):** Menus, UI animations, network pings, telemetry, and frame profiling.
2. **Gameplay Time (Simulation Time):** Pausable, scaleable combat, tweens, bullet-time slow motion, and physics animations.
3. **Discrete Steps (Fixed Ticks):** Integer-indexed ticks for lockstep simulations, rollback netcode, and exact deterministic replays.

### Mathematical Analysis: Why `f32` Precision Degrades

In standard 32-bit floating point (`f32`), the IEEE 754 standard defines a 24-bit significand (1 implicit bit + 23 explicit bits), providing roughly 7 decimal digits of precision.

Let $T$ be the total elapsed time and $\Delta t$ be the frame duration ($1/60 \approx 0.0166667\text{s}$). The machine epsilon at magnitude $T$ is given by:

$$\epsilon(T) = 2^{\lfloor \log_2(T) \rfloor - 23}$$

| Elapsed Time $T$ | Equivalent Duration | Smallest Representable Step $\epsilon(T)$ | Frame Time Distortion ($\epsilon / \Delta t$) | Impact on Gameplay |
| :--- | :--- | :--- | :--- | :--- |
| **$60\text{ s}$** | 1 Minute | $0.0000038\text{ s}$ ($3.8\mu\text{s}$) | $0.02\%$ | Undetectable |
| **$3,600\text{ s}$** | 1 Hour | $0.000244\text{ s}$ ($244\mu\text{s}$) | $1.46\%$ | Minor timer rounding |
| **$32,768\text{ s}$** | 9.1 Hours | $0.001953\text{ s}$ ($1.95\text{ms}$) | **$11.72\%$** | Noticeable animation stutter |
| **$65,536\text{ s}$** | 18.2 Hours | $0.003906\text{ s}$ ($3.90\text{ms}$) | **$23.44\%$** | Severe frame drops and timer skipping |
| **$131,072\text{ s}$** | 36.4 Hours | $0.007812\text{ s}$ ($7.81\text{ms}$) | **$46.87\%$** | Physics breakdown |
| **$1,048,576\text{ s}$**| 12.1 Days | $0.062500\text{ s}$ ($62.5\text{ms}$) | **> 300%** | Time completely freezes |

### Why $f64$ + $u64$ Guarantees Multi-Year Zero-Drift

- **`f64` Accumulators (53-bit significand):**
  At 100 years of continuous runtime ($3.15 \times 10^9\text{s}$):
  $$\epsilon(3.15 \times 10^9) \approx 3.15 \times 10^9 \times 2^{-52} \approx 6.99 \times 10^{-7}\text{ s} \quad (0.7\mu\text{s})$$
  Sub-microsecond precision is maintained indefinitely across multiple real-time years.
- **`u64` Integer Ticks:**
  At a tick rate of 1,000 Hz, a 64-bit unsigned integer tick counter will not overflow for $1.84 \times 10^{19} / 1000 \approx 584\text{ million years}$.

---

## 2. The 3 Clock Domains in `Scheduler`

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           SCHEDULER ENGINE CLOCKS                           │
├────────────────────────────────┬────────────────────────────────────────────┤
│ Domain 1: Real / Wall Clock    │ • real_time: f64 (Unpaused elapsed seconds)│
│                                │ • real_delta: f32 (Latest unscaled dt)     │
│                                │ • real_ticks: u64 (Host frame counter)     │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Domain 2: Scaled Simulation    │ • sim_time: f64 (Gameplay elapsed seconds) │
│                                │ • sim_delta: f32 (Scaled dt = dt * scale)  │
│                                │ • time_scale: f32 (0.1 = slow-mo, 2.0=fast)│
│                                │ • is_paused: bool (Freezes sim clock)      │
├────────────────────────────────┼────────────────────────────────────────────┤
│ Domain 3: Discrete Fixed Ticks │ • sim_ticks: u64 (Integer game tick index) │
│                                │ • tick_rate_hz: u32 (Default: 60 Hz)       │
│                                │ • frame_count: u64 (Scheduler step counter)│
└────────────────────────────────┴────────────────────────────────────────────┘
```

### Accessor Matrix

| Clock Domain | Yield Primitive | Spawning Primitive | Time Query | Delta Query |
| :--- | :--- | :--- | :--- | :--- |
| **Simulation** | `coroutine.wait(f, seconds)` | `coroutine.spawn(&sched, proc)` | `coroutine.current_time(f)` | `coroutine.delta_time(f)` |
| **Real-Time** | `coroutine.wait_real(f, seconds)` | `coroutine.spawn_real(&sched, proc)` | `coroutine.real_time(f)` | `coroutine.delta_real(f)` |
| **Discrete Ticks** | `coroutine.wait_ticks(f, ticks)` | `coroutine.spawn(&sched, proc)` | `coroutine.current_ticks(f)` | $1 / f_{\text{tick}}$ |

---

## 3. Pluggable Engine Drivers

The engine provides 4 specialized drivers to tick the scheduler depending on the game engine architecture:

### A. `scheduler_step(sched, dt)`
Standard variable frame delta driver.
- Advances `real_time += dt`, `real_delta = dt`, `real_ticks += 1`.
- If `!is_paused`:
  - `sim_delta = dt * time_scale`
  - Computes `sim_ticks` continuously from total accumulated simulation time to guarantee zero integer truncation drift over arbitrarily long gameplay sessions:
    $$\text{target\_ticks} = \lfloor(\text{sim\_time} + \text{sim\_delta}) \times \text{tick\_rate\_hz}\rfloor$$
    $$\text{sim\_ticks} = \text{target\_ticks} - \text{clock.sim\_ticks}$$
  - `sim_time += sim_delta`
  - Evaluates and wakes sleeping fibers from `timer_heap`.
- Always evaluates and wakes sleeping fibers from `real_timer_heap`.
- Evaluates `tick_waiters`, `frame_waiters`, and `condition_waiters`.

```odin
scheduler_step(&sched, rl.GetFrameTime())
```

### B. `scheduler_step_ticks(sched, ticks)`
Advances the discrete simulation tick counter by `ticks` steps. Evaluates tick-based waiters registered via `wait_ticks(f, count)`.
```odin
// Fixed 60 Hz physics loop
scheduler_step_ticks(&sched, 1)
```

### C. `scheduler_step_dual(sched, real_dt, sim_dt)`
Explicit dual-clock driver for custom engines where the host simulation loop calculates scaled delta and unscaled delta independently.
```odin
scheduler_step_dual(&sched, raw_frame_delta, gameplay_delta)
```

### D. `scheduler_single_step(sched, dt)`
Manual stepping driver for debuggers and step-frame analysis. Forces exactly one frame advancement regardless of pause state.

---

## 4. Dual Min-Heap Architecture

To guarantee $O(1)$ wake inspection without linear list scanning, the scheduler maintains **two independent binary min-heaps**:

```
                       ┌──────────────────────────────┐
                       │       Scheduler Clocks       │
                       └──────────────┬───────────────┘
                                      │
              ┌───────────────────────┴───────────────────────┐
              ▼                                               ▼
     [ sim_time / sim_delta ]                        [ real_time / real_delta ]
              │                                               │
              ▼                                               ▼
    ┌───────────────────┐                           ┌───────────────────┐
    │    timer_heap     │                           │  real_timer_heap  │
    │  (Binary Min-Heap)│                           │ (Binary Min-Heap) │
    ├───────────────────┤                           ├───────────────────┤
    │ [Fiber 2: 4.12s]  │                           │ [Fiber 9: 1.05s]  │
    │ [Fiber 5: 6.80s]  │                           │ [Fiber 7: 2.30s]  │
    └───────────────────┘                           └───────────────────┘
```

### Min-Heap Invariants & Formulas:
For any element at 0-indexed position $i$:
- **Parent Index:** $\lfloor (i - 1) / 2 \rfloor$
- **Left Child Index:** $2i + 1$
- **Right Child Index:** $2i + 2$
- **Heap Invariant:** `wake_time[parent(i)] <= wake_time[i]`

### Operations & Complexity:
1. **$O(1)$ Root Peek:** The root at index 0 always contains the fiber with the earliest `wake_time`.
2. **$O(\log N)$ Insert:** Pushed to end of array and sifted upwards.
3. **$O(\log N)$ Removal with Cached Indices:**
   Each fiber stores its current heap array index (`heap_index` or `real_heap_index`). When a sleeping fiber is aborted via `fiber_cancel` or `race`, it is swapped with the last element and sifted in $O(\log N)$ time without full heap scanning.
