# Game Engine Timing, Frame Quantization & Time Drift Prevention (`GUIDE_TIMING_AND_DRIFT.md`)

> **ESSENTIAL GUIDE FOR GAMEPLAY & SYSTEMS ENGINEERS**:
> This document details the mathematics of **frame quantization**, why cumulative time drift occurs in naive sleep loops, how other commercial engines (Unreal, Unity, SkookumScript) handle it, and how the **Odin Stackful Coroutine Engine** eliminates drift using self-correcting timestamp anchors in `coroutine.Ticker`.

---

## 1. Why Did Drift Happen? (The Math of Frame Quantization)

Game engines do not run continuously in analog real-time; they tick in **discrete frames** (e.g., $60\text{ FPS} \approx 16.666\text{ ms}$ per frame).

```
Discrete 60 FPS Frames:  |──16.6ms──|──16.6ms──|──16.6ms──|──16.6ms──| ...
Target Periodic Tick:                ▲ (Target: 25.0ms)
Actual Wakeup Point:                            ▲ (Frame 2 @ 33.3ms) -> Over by +8.3ms!
```

Because frames are quantized, a timer requesting a duration that does not divide perfectly into the frame delta-time will always wake up on the **first frame boundary at or after** its requested expiration timestamp.

---

### The Two Mathematical Models

#### A. Naive `wait(f, interval)` Loop (Compounds Error Every Iteration)

In a naive relative loop:
```odin
for {
    coroutine.wait(f, 0.5) // Calculates: next_wake = CURRENT_TIME + 0.5
    do_heavy_gameplay_work()
}
```

1. **Target:** Wake at $t = 0.5000\text{ s}$.
2. **Frame Quantization:** At 60 FPS ($16.666\text{ ms}$ per frame), the engine lands on Frame 31 ($t = 0.5166\text{ s}$).
3. **The Trap:** When the fiber resumes, it computes `next_wake` relative to the *current* overshoot time:
   $$\text{next\_wake} = 0.5166 + 0.5000 = \mathbf{1.0166\text{ s}}$$
4. The next wakeup lands on Frame 62 ($t = 1.0333\text{ s}$).
5. **The Error Accumulates:** The $+16.666\text{ ms}$ frame overshoot is **permanently added to the timeline on EVERY single iteration**.
6. **Result:** After 60 iterations (intended 30.0 seconds), the loop has drifted by **$+1.0\text{ to } +2.0\text{ full seconds}$!**

---

#### B. The `Ticker` Formula (Self-Correcting Timestamp Anchor)

In a `Ticker` loop:
```odin
ticker: coroutine.Ticker
coroutine.ticker_init(&ticker, interval_seconds = 0.5)

for {
    coroutine.ticker_wait(f, &ticker) // Calculates: next_wake += interval
    do_heavy_gameplay_work()
}
```

1. **Target 1:** $\text{target}_1 = 0.5000\text{ s} \rightarrow$ Wakes at $t = 0.5166\text{ s}$.
2. **The Self-Correction:** Next target is calculated by **adding the interval to the previous target anchor**, NOT the current overshoot time:
   $$\text{next\_wake} = 0.5000 + 0.5000 = \mathbf{1.0000\text{ s}}$$
3. It asks the scheduler to wait for the exact difference:
   $$\Delta t_{\text{wait}} = 1.0000 - 0.5166 = \mathbf{0.4834\text{ s}}$$
4. The next wakeup lands at Frame 61 ($t = 1.0166\text{ s}$).
5. **Result:** After 1,000 iterations, the total cumulative error is **never more than a single frame ($\le 16.666\text{ ms}$)**. The error never compounds.

```
Iteration Timeline:
Target Grid:  |──────0.5s──────|──────1.0s──────|──────1.5s──────|──────2.0s──────|
Naive Sleep:  |──────0.517s────┼──────1.033s────┼──────1.550s────┼──────2.067s────► (Lagging +67ms)
Ticker Anchor:|──────0.517s────┼──────1.017s────┼──────1.517s────┼──────2.017s────► (Locked <= 17ms)
```

---

## 2. Where Else Does Timing Occur in Game Engines?

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          TIMING MECHANISM AUDIT                             │
├───────────────────────┬────────────────────────────┬────────────────────────┤
│ Mechanism             │ Does It Suffer from Drift? │ Why?                   │
├───────────────────────┼────────────────────────────┼────────────────────────┤
│ Naive wait() loops    │ **YES (Compounds)**        │ Relative to wake time. │
│ Ticker loops          │ **NO (Zero Drift)**        │ Absolute time anchor.  │
│ tween()               │ **NO (Self-Clamping)**     │ Clamps to exact end.   │
│ wait_frames(N)        │ **NO (Exact)**             │ Discrete integer math. │
│ wait_ticks(N)         │ **NO (Bit-Identical)**     │ Fixed discrete clock.  │
└───────────────────────┴────────────────────────────┴────────────────────────┘
```

### 1. In `tween` (No Drift)
`tween` does not drift because it interpolates between fixed endpoints ($t = 0.0 \rightarrow t = 1.0$). If a frame overshoots the duration, `math.clamp(elapsed / duration, 0.0, 1.0)` forces the final evaluated value **exactly to the target value**.

### 2. In `wait_frames` and `wait_ticks` (No Drift)
Frame waits and tick waits use **pure integer arithmetic** (`current_frame + N`, `sim_ticks + N`). There are zero floating-point rounding errors.

---

## 3. How Commercial Game Engines Handle This

Frame quantization drift is a universal reality in all game engines, and every major engine handles it using the same architectural patterns:

| Engine / Language | What Happens in Naive Loops | How the Engine Solves It |
| :--- | :--- | :--- |
| **Unreal Engine (C++)** | Calling `Delay(0.5)` in Blueprint loops **drifts significantly**. | `FTimerManager::SetTimer(..., bLoop = true)` internally does `ExpireTime += Rate` (identical to our `Ticker`). |
| **Unity (C#)** | `while (true) { yield return new WaitForSeconds(0.5f); }` **drifts by seconds**. | Developers must use fixed timestamps (`nextTime += interval`) or `FixedUpdate`. |
| **SkookumScript** | Calling `_wait(0.5)` in a loop drifted. | Provided a dedicated `_periodic(0.5)` primitive that anchored the timestamp. |
| **Odin Coroutines (ASM)** | Calling `wait(f, 0.5)` in a loop drifted. | Provided `coroutine.Ticker` + `coroutine.ticker_wait(f, &t)`. |

---

## 4. Why Can't We Make Standard `wait()` Drift-Free Automatically?

**Because `wait()` has no contextual knowledge of whether it is being called inside a recurring loop or as a one-off action.**

Consider a one-off cutscene delay:
```odin
play_cutscene_explosion()
coroutine.wait(f, 2.0) // "Wait 2 seconds from RIGHT NOW"
spawn_boss()
```

If `wait()` was automatically anchored to an old historic timestamp, calling it after a 5-second cutscene would cause it to wake up instantly ($0\text{ seconds}$) because it would perceive itself as overdue!

Therefore, in systems architecture:
1. **`wait(f, seconds)`** is for **one-off relative delays** (*"Pause for $X$ seconds from right now"*).
2. **`Ticker` / `ticker_wait(f, &t)`** is for **periodic recurring intervals** (*"Tick every $X$ seconds on an exact grid"*).
3. **`wait_ticks(f, N)`** is for **fixed-timestep physics & netcode** (*"Advance exactly $N$ integer ticks"*).

---

## 5. Summary: Timing Primitive Decision Matrix

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    WHEN TO USE WHICH TIMING PRIMITIVE                       │
├─────────────────────────────────────────────────────────────────────────────┤
│ • One-off actions & animations:  Use wait(f, seconds)                      │
│   (e.g. Laser telegraph delay, cutscene pause, screen fade).                │
│                                                                             │
│ • Periodic loops & recurring ticks: Use Ticker + ticker_wait(f, &ticker)   │
│   (e.g. Damage-over-time poison ticks, weapon fire rates, UI blinkers).     │
│                                                                             │
│ • Deterministic physics & netcode: Use wait_ticks(f, tick_count)           │
│   (e.g. Rollback simulation, replay playback, fixed 60Hz logic).            │
│                                                                             │
│ • UI & Pause-Immune timers: Use wait_real(f, seconds) or Ticker(use_real)  │
│   (e.g. Pause menu carousel, notification toasts, network pings).           │
└─────────────────────────────────────────────────────────────────────────────┘
```
