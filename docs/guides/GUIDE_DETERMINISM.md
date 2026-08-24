# Determinism, Netcode & Fixed Ticking (`GUIDE_DETERMINISM.md`)

This guide explains how to leverage the **Discrete Tick Domain** (`wait_ticks`, `scheduler_step_ticks`) to achieve lockstep determinism, input replay recording, and rollback netcode compatibility.

---

## 1. Sources of Floating-Point Non-Determinism

Achieving 100% deterministic simulation across multiple client machines is essential for peer-to-peer multiplayer games, lockstep RTS engines, and competitive fighting games.

### Common Sources of Simulation Drift:
1. **Variable Delta Times ($\Delta t$):** Frame render times fluctuate on different hardware (144 Hz vs 60 Hz vs 30 Hz). Integrating velocity with variable $\Delta t$ produces divergent trajectories.
2. **Fused Multiply-Add (FMA):** Compilers may contract `a * b + c` into a single `vfmadd` instruction with 80-bit intermediate precision on modern CPUs, whereas older CPUs compute two separate rounded operations.
3. **Transcendental Library Functions (`sin`, `cos`, `sqrt`):** C runtime math libraries differ slightly between MSVC, glibc, and macOS libSystem.

---

## 2. Lockstep Determinism via Discrete Ticks

The coroutine engine eliminates time-based drift by introducing the **Fixed Tick Domain**:

```odin
// Fixed 60 Hz Tick Driver
FIXED_HZ :: 60
tick_accumulator += dt

for tick_accumulator >= (1.0 / f32(FIXED_HZ)) {
    coroutine.scheduler_step_ticks(&physics_sched, 1)
    tick_accumulator -= (1.0 / f32(FIXED_HZ))
}
```

### Deterministic Physics Coroutine:

```odin
Ball :: struct {
    pos: [2]i32, // Fixed-point 16.16 coordinates
    vel: [2]i32,
}

ball_physics_coroutine :: proc(f: ^coroutine.Fiber, ball: ^Ball) {
    for {
        // Yield for exactly ONE deterministic simulation tick
        coroutine.wait_ticks(f, 1)

        // Integer / Fixed-Point Integration (100% identical on every machine)
        ball.pos.x += ball.vel.x
        ball.pos.y += ball.vel.y
        ball.vel.y += 980 // Constant gravity
    }
}
```

---

## 3. Replay Recording & Rollback Architecture

Because coroutine scheduling is strictly bound to discrete tick counters:
1. **Replay Recording:** You only need to record player inputs per integer tick ($T_0, T_1, T_2, \dots$).
2. **Replay Verification:** Replaying the recorded input stream through the engine produces an identical execution history bit-for-bit.
3. **Rollback Snapshotting:** Checkpointing game state and rolling back $K$ ticks requires stepping the scheduler forward deterministically using `scheduler_step_ticks`.
