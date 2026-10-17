# Multi-Scheduler Engine Architectures (`GUIDE_SCHEDULERS.md`)

In large-scale production game architectures, managing multiple independent `Scheduler` instances allows clean lifecycle isolation between game worlds, UI menus, and background scenes.

---

## 1. The Dual-Scheduler Pattern (World vs. UI)

Rather than sharing a single scheduler, games frequently use two dedicated schedulers:

```
┌───────────────────────────────────────────────┐
│              Host Engine Loop                 │
└───────┬───────────────────────────────┬───────┘
        │ (dt * time_scale)             │ (dt)
        ▼                               ▼
┌─────────────────────────┐   ┌─────────────────────────┐
│     world_scheduler     │   │      ui_scheduler       │
├─────────────────────────┤   ├─────────────────────────┤
│ • Enemies & Boss AI     │   │ • Pause Menu Banners    │
│ • Projectiles & Spells  │   │ • Inventory Modals      │
│ • Camera Shake & FX     │   │ • Dialogue Typewriters  │
│ (Frozen when paused!)   │   │ (Always Active!)        │
└─────────────────────────┘   └─────────────────────────┘
```

> [!TIP]
> **Single-Scheduler Alternative**: In lightweight projects, you can achieve world/UI isolation inside a single scheduler using the indexed clock domain architecture (`CLOCK_SIM` for world gameplay, `CLOCK_REAL` for unpaused UI). See [Tutorial 8: Multi-Domain Clocks](../tutorials/08_multi_domain_clocks.md). Use multi-scheduler architectures when full memory pool isolation and independent lifecycle teardown are required.

---

## 2. Multi-Scene Lifecycle Management

When switching levels (e.g. from Dungeon Level 1 to Dungeon Level 2):
1. Simply call `coroutine.scheduler_destroy(&level_1_sched)`.
2. All level-1 enemy AI, patrol timers, and spawned spell fibers are instantly destroyed with zero dangling pointers.
3. Initialize `level_2_sched` fresh with clean stacks!
