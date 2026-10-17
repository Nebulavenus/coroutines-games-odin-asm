# Determinism, Netcode & Fixed Ticking (`GUIDE_DETERMINISM.md`)

This guide explains how to leverage the **Discrete Step Domain** (`CLOCK_PHYS`, `wait_steps`, `clock_advance`) to achieve lockstep determinism, input replay recording, and rollback netcode compatibility.

---

## 1. Sources of Floating-Point Non-Determinism

Achieving 100% deterministic simulation across multiple client machines is essential for peer-to-peer multiplayer games, lockstep RTS engines, and competitive fighting games.

### Common Sources of Simulation Drift:
1. **Variable Delta Times ($\Delta t$):** Frame render times fluctuate on different hardware (144 Hz vs 60 Hz vs 30 Hz). Integrating velocity with variable $\Delta t$ produces divergent trajectories.
2. **Fused Multiply-Add (FMA):** Compilers may contract `a * b + c` into a single `vfmadd` instruction with 80-bit intermediate precision on modern CPUs, whereas older CPUs compute two separate rounded operations.
3. **Transcendental Library Functions (`sin`, `cos`, `sqrt`):** C runtime math libraries differ slightly between MSVC, glibc, and macOS libSystem.

---

## 2. Lockstep Determinism via Discrete Steps (`CLOCK_PHYS`)

The coroutine engine eliminates time-based drift by providing the **Fixed Physics / Step Domain (`CLOCK_PHYS`)**:

```odin
// Fixed 60 Hz Tick Driver
FIXED_HZ :: 60
FIXED_DT :: 1.0 / f32(FIXED_HZ)
tick_accumulator += dt

for tick_accumulator >= FIXED_DT {
    coroutine.clock_advance(&sched, coroutine.CLOCK_PHYS, FIXED_DT, steps = 1)
    tick_accumulator -= FIXED_DT
}
coroutine.scheduler_run(&sched)
```

### Deterministic Physics Coroutine:

```odin
Ball :: struct {
    pos: [2]i32, // Fixed-point 16.16 coordinates
    vel: [2]i32,
}

ball_physics_coroutine :: proc(f: ^coroutine.Fiber, ball: ^Ball) {
    for {
        // Yield for exactly ONE deterministic simulation step
        coroutine.wait_steps(f, 1)

        // Integer / Fixed-Point Integration (100% identical on every machine)
        ball.pos.x += ball.vel.x
        ball.pos.y += ball.vel.y
        ball.vel.y += 980 // Constant gravity
    }
}

// Spawn ball coroutine bound to CLOCK_PHYS:
coroutine.spawn(&sched, ball_physics_coroutine, &ball, clock = coroutine.CLOCK_PHYS)
```

---

## 3. Replay Recording & Rollback Architecture

Because coroutine scheduling is strictly bound to discrete step counters:
1. **Replay Recording:** You only need to record player inputs per integer step ($T_0, T_1, T_2, \dots$).
2. **Replay Verification:** Replaying the recorded input stream through the engine produces an identical execution history bit-for-bit.
3. **Rollback Snapshotting:** Checkpointing game state and rolling back $K$ steps requires stepping the scheduler forward deterministically using `clock_advance(&sched, coroutine.CLOCK_PHYS, FIXED_DT, 1)` + `scheduler_run(&sched)`.
