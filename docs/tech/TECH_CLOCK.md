# The Indexed Multi-Domain Engine Clock (`TECH_CLOCK.md`)

This document provides the mathematical foundation, precision specifications, and subsystem architecture of the **Indexed `Clock_Domain` Engine Clock** implemented in the Odin Stackful Coroutine Engine.

---

## 1. The Physics & Mathematics of Game Clocks

Game engines must balance multiple distinct temporal concepts:
1. **Human Time (Real/Wall Time):** Menus, UI animations, network pings, telemetry, and frame profiling.
2. **Gameplay Time (Simulation Time):** Pausable, scaleable combat, tweens, bullet-time slow motion, and character timelines.
3. **Discrete Steps (Fixed Ticks):** Integer-indexed steps for lockstep simulations, rollback netcode, and exact deterministic replays.

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
- **`u64` Integer Steps:**
  At a tick rate of 1,000 Hz, a 64-bit unsigned integer tick counter will not overflow for $1.84 \times 10^{19} / 1000 \approx 584\text{ million years}$.

---

## 2. The Indexed `Clock_Domain` Architecture

Instead of hardcoding fixed clock variables inside the scheduler, `Scheduler` holds an indexed array of timeline domains:

```odin
Clock_ID :: distinct int

CLOCK_INHERIT :: Clock_ID(-1)
CLOCK_SIM     :: Clock_ID(0)
CLOCK_REAL    :: Clock_ID(1)
CLOCK_PHYS    :: Clock_ID(2)

Clock_Domain :: struct {
    time:         f64,
    delta:        f32,
    steps:        u64,
    timer_heap:   [dynamic]^Fiber,
    step_waiters: [dynamic]^Fiber,
}

Scheduler :: struct {
    // ...
    ready_queue: [dynamic]Fiber_Handle,
    clocks:      [MAX_CLOCKS]Clock_Domain,
    // ...
}
```

Every `Fiber` carries `clock_id: Clock_ID`. Child fibers created in `sync`, `race`, or `rush` automatically inherit their parent's `clock_id` (`CLOCK_INHERIT`).

### Accessor Matrix

| Clock Domain | Yield Primitive | Spawning Primitive | Time Query | Delta Query |
| :--- | :--- | :--- | :--- | :--- |
| **Simulation** | `coroutine.wait(f, seconds)` | `coroutine.spawn(&sched, proc)` | `coroutine.current_time(f)` | `coroutine.delta_time(f)` |
| **Real-Time** | `coroutine.wait(f, seconds)` | `coroutine.spawn(&sched, proc, clock = CLOCK_REAL)` | `coroutine.current_time(f)` | `coroutine.delta_time(f)` |
| **Fixed Physics** | `coroutine.wait_steps(f, count)` | `coroutine.spawn(&sched, proc, clock = CLOCK_PHYS)` | `coroutine.current_steps(f)` | `coroutine.delta_time(f)` |

---

## 3. Explicit Stepping Pipeline

### A. `clock_advance(sched, clock_id, dt, steps = 1)`
Advances a specific clock domain's timeline:
1. Clamps `safe_dt = max(0.0, dt)` (immune to negative delta or NaN).
2. Updates `c.delta = safe_dt`, `c.time += f64(safe_dt)`, `c.steps += steps`.
3. Pops all expired timers from `c.timer_heap` (`wake_time <= c.time`) and pushes handles to `sched.ready_queue`.
4. Wakes all step waiters with `wake_step <= c.steps` and pushes handles to `sched.ready_queue`.

### B. `scheduler_run(sched)`
Drains all ready fibers in `sched.ready_queue` using generational handle validation, context switching into each fiber until it yields or terminates.

### C. Convenience Wrapper: `scheduler_step(sched, dt, clock_id = CLOCK_SIM)`
Calls `clock_advance(sched, clock_id, dt, 1)` followed by `scheduler_run(sched)`.

---

## 4. Per-Domain Binary Min-Heaps

Each `Clock_Domain` maintains its own independent binary min-heap (`timer_heap: [dynamic]^Fiber`):
- Insertions and removals are $O(\log N)$.
- Fibers store their heap index in `f.heap_index`, allowing $O(1)$ lookup and instant $O(\log N)$ deletion upon cancellation without linear searches.
- Fibers sleeping on steps live in an unordered array (`step_waiters: [dynamic]^Fiber`), partitioned in $O(N)$ and pruned in-place upon expiration or abort.
