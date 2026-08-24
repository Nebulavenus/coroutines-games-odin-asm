# Interactive Debugger & Telemetry Manual (`GUIDE_DEBUGGER.md`)

The engine includes a visual in-game fiber hierarchy debugger and an interactive freeze-frame time controller implemented across the example projects.

---

## 1. Live Fiber Tree Visualizer (`F1` / `TAB`)

Pressing `[F1]` or `[TAB]` in the interactive examples overlays the real-time coroutine hierarchy:

```
=== ACTIVE COROUTINE HIERARCHY TREE (F1) ===
Pool: 2 Slabs | Stacks: 64 | Active: 5 | Free: 59 | Memory: 2048 KB
├─ [Fiber 1] Root: Boss AI Timeline (Running)
│  ├─ [Fiber 2] sync: Laser Charge (Sleeping_Sim: 0.42s remaining) [Stack: 1.8KB / 32KB] (5.6%)
│  ├─ [Fiber 3] sync: Radial Spreader (Sleeping_Sim: 0.12s remaining) [Stack: 2.1KB / 32KB] (6.5%)
│  └─ [Fiber 4] sync: Minion Summoner (Sleeping_Sim: 1.50s remaining) [Stack: 1.6KB / 32KB] (5.0%)
└─ [Fiber 5] Root: UI Toast Manager (Sleeping_Real: 2.30s remaining) [Stack: 1.2KB / 32KB] (3.7%)
```

### Telemetry Fields Breakdown

| Telemetry Field | Display Example | Description |
| :--- | :--- | :--- |
| **Pool Memory Line** | `Pool: 2 Slabs \| Stacks: 64` | Live `scheduler_pool_stats` metrics (Slabs, Stacks, Active, Free, Memory KB) |
| **Fiber ID & Tree Depth** | `├─ [Fiber 2]` | Intrusive hierarchy depth based on parent-child links |
| **Branch Role / Tag** | `sync: Laser Charge` | Debug label passed to `branch` or `spawn` |
| **Lifecycle State** | `(Sleeping_Sim)` | Current status: `Running`, `Ready`, `Sleeping_Sim`, `Sleeping_Real`, `Sleeping_Ticks`, `Suspended_Join` |
| **Remaining Timer** | `0.42s remaining` | Real-time countdown to scheduled wake tick |
| **Stack Consumption** | `[Stack: 1.8KB / 32KB]` | High-water mark calculated via `0xAA` watermarking scan |
| **Stack Usage %** | `(5.6%)` | Percentage of allocated stack capacity utilized |

---

## 2. Interactive Freeze-Step & Time Controls

| Keybind | Action | Description |
| :--- | :--- | :--- |
| `[F3]` | **Toggle Simulation Freeze** | Sets `sched.is_paused = !sched.is_paused`. Gameplay freezes while UI menus and overlays remain active. |
| `[F4]` | **Single Frame Step** | Advances the paused simulation by exactly 1 frame ($+0.016\text{s}$). |
| `[F5]` / `[Shift+F4]` | **10-Frame Jump** | Advances simulation by 10 frames ($+0.160\text{s}$). |
| **Hold `[F4]`** | **Slow-Motion Stepping** | Steps continuously at 15 FPS while held down. |
| `[1]`, `[2]`, `[3]` | **Time Dilation Presets** | Adjusts `sched.time_scale` to 0.25x (slow-mo), 1.0x (normal), or 2.0x (fast forward). |

---

## 3. Input Latching While Paused

When testing complex combat scenarios, players can press action keys while paused (`[F3]`). The engine latches the inputs into a queue and executes them precisely on the next stepped frame (`[F4]`), enabling frame-perfect combat verification.
