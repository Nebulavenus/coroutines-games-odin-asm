# Interactive Debugger & Telemetry Manual (`GUIDE_DEBUGGER.md`)

The engine includes a visual in-game fiber hierarchy debugger and an interactive freeze-frame time controller implemented across the example projects.

---

## 1. Live Fiber Tree Visualizer (`F1` / `TAB`)

Pressing `[F1]` or `[TAB]` in the interactive examples overlays the real-time coroutine hierarchy:

```
=== ACTIVE COROUTINE HIERARCHY TREE (F1 / H) ===
Pool: 2 Slabs | Stacks: 64 | Active: 5 | Free: 59 | Memory: 2048 KB
├─ [Fiber 1] Root: Boss AI Timeline (Running)
│  ├─ [Fiber 2] sync: Laser Charge (Sleeping_Time [SIM]: 0.42s remaining) [Stack: 1.8KB / 32KB] (5.6%)
│  ├─ [Fiber 3] sync: Radial Spreader (Sleeping_Time [SIM]: 0.12s remaining) [Stack: 2.1KB / 32KB] (6.5%)
│  └─ [Fiber 4] sync: Minion Summoner (Sleeping_Time [SIM]: 1.50s remaining) [Stack: 1.6KB / 32KB] (5.0%)
└─ [Fiber 5] Root: UI Toast Manager (Sleeping_Time [REAL]: 2.30s remaining) [Stack: 1.2KB / 32KB] (3.7%)
```

### Telemetry Fields Breakdown

| Telemetry Field | Display Example | Description |
| :--- | :--- | :--- |
| **Pool Memory Line** | `Pool: 2 Slabs, Stacks: 64` | Live `scheduler_pool_stats` metrics (Slabs, Stacks, Active, Free, Memory KB) |
| **Fiber ID & Tree Depth** | `├─ [Fiber 2]` | Intrusive hierarchy depth based on parent-child links |
| **Branch Role / Tag** | `sync: Laser Charge` | Debug label passed to `branch` or `spawn` |
| **Lifecycle State** | `(Sleeping_Time)` | Current `Fiber_Status`: `Running`, `Ready`, `Sleeping_Time`, `Sleeping_Steps`, `Suspended_Join` (tagged by `f.clock_id`) |
| **Remaining Timer** | `0.42s remaining` | Countdown to `f.wake_time` on `f.clock_id` |
| **Stack Consumption** | `[Stack: 1.8KB / 32KB]` | High-water mark calculated via `0xAA` watermarking scan |
| **Stack Usage %** | `(5.6%)` | Percentage of allocated stack capacity utilized |

---

## 2. Interactive Freeze-Step & Time Controls

| Keybind | Action | Description |
| :--- | :--- | :--- |
| `[P]` / `[Esc]` / `[F3]` | **Toggle Simulation Freeze** | Stops advancing `CLOCK_SIM` while continuing to advance `CLOCK_REAL`, keeping UI/overlays active while gameplay freezes. |
| `[N]` / `[.]` / `[F4]` | **Single Frame Step** | Advances `CLOCK_SIM` by exactly 1 frame (`+0.016s`) via `clock_advance(&sched, CLOCK_SIM, 0.016)` + `scheduler_run(&sched)`. |
| `[M]` / `[F5]` | **10-Frame Jump** | Advances `CLOCK_SIM` by 10 frames (`+0.160s`). |
| **Hold `[F4]`** | **Slow-Motion Stepping** | Steps continuously at ~6–15 FPS while held down. |
| **RMB** (`examples/game`) / `[1]–[3]` | **Time Dilation** | Scales the `dt` passed to `clock_advance(&sched, CLOCK_SIM, dt * scale)` (e.g. bullet-time slow-mo down to 0.15x or fast-forward 2.0x). |

---

## 3. Input Latching While Paused

When testing complex combat scenarios, players can press action keys while paused (`[F3]`). The engine latches the inputs into a queue and executes them precisely on the next stepped frame (`[F4]`), enabling frame-perfect combat verification.
