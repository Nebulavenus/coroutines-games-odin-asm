# The Odin Coroutine Gameplay Cookbook

A curated collection of production-ready, copy-pasteable gameplay architectures built with the `coroutine` library and its modular `coroutine/sync` subpackage.

---

## Table of Contents
1. [Recipe 1: Ability Channeling & Casting with Cancel Preemption (`race`)](#recipe-1-ability-channeling--casting-with-cancel-preemption-race)
2. [Recipe 2: Interactive Dialogue & Cutscene Tree (`coroutine/sync` Channel)](#recipe-2-interactive-dialogue--cutscene-tree-coroutinesync-channel)
3. [Recipe 3: Multi-Wave Enemy Spawner (`Fiber_Scope` + `scope_wait`)](#recipe-3-multi-wave-enemy-spawner-fiber_scope--scope_wait)
4. [Recipe 4: AI Behavior Priority Fallbacks & Rush Objectives (`fallback` + `rush`)](#recipe-4-ai-behavior-priority-fallbacks--rush-objectives-fallback--rush)
5. [Recipe 5: Damped Smooth Spring Follower (Tween Pattern)](#recipe-5-damped-smooth-spring-follower-tween-pattern)
6. [Recipe 6: Unpausable Real-Time Pause Menus (`CLOCK_REAL`)](#recipe-6-unpausable-real-time-pause-menus-clock_real)
7. [Recipe 7: Lockstep Fixed-Tick Physics & Rollback Netcode (`CLOCK_PHYS`)](#recipe-7-lockstep-fixed-tick-physics--rollback-netcode-clock_phys)
8. [Recipe 8: Multi-Phase Boss AI with Hierarchical Scopes (`Fiber_Scope`)](#recipe-8-multi-phase-boss-ai-with-hierarchical-scopes-fiber_scope)
9. [Recipe 9: RTS Unit Action Queue with Command Preemption & Waypoints](#recipe-9-rts-unit-action-queue-with-command-preemption--waypoints)
10. [Recipe 10: Multi-Channel Network & Input Multiplexer (`chan_select_recv`)](#recipe-10-multi-channel-network--input-multiplexer-chan_select_recv)
11. [Recipe 11: Decoupled Stage Transition Signals (`Signal` / `Event(T)`)](#recipe-11-decoupled-stage-transition-signals-signal--eventt)
12. [Recipe 12: Entity Sub-Scopes & Localized EMP Stun (`Fiber_Scope`)](#recipe-12-entity-sub-scopes--localized-emp-stun-fiber_scope)
13. [Recipe 13: Channel Timeout & Deadlock-Free Message Polling (`chan_recv_timeout`)](#recipe-13-channel-timeout--deadlock-free-message-polling-chan_recv_timeout)
14. [Recipe 14: Zero-Drift Periodic Heartbeats & Damage-over-Time (`ticker_wait`)](#recipe-14-zero-drift-periodic-heartbeats--damage-over-time-ticker_wait)
15. [Recipe 15: Deadlock-Proof Scoped Mutex & Semaphore Locks (`with_mutex` / `with_semaphore`)](#recipe-15-deadlock-proof-scoped-mutex--semaphore-locks-with_mutex--with_semaphore)
16. [Recipe 16: Structured Emergency Task Abort (`race` & `Signal`)](#recipe-16-structured-emergency-task-abort-race--signal)
17. [Recipe 17: Custom In-Engine Hierarchy Tree Debuggers (`scheduler_walk_tree`)](#recipe-17-custom-in-engine-hierarchy-tree-debuggers-scheduler_walk_tree)

---

## Recipe 1: Ability Channeling & Casting with Cancel Preemption (`race`)

### Problem
A player starts casting a powerful spell over 2.5 seconds. If the player moves, takes damage, or presses ESC, the cast must abort instantly, reset the cast bar, and trigger a fizzle effect.

### Solution
Use `coroutine.race` with two parallel branches:
* **Branch A (The Workload):** Animates the cast bar from 0% to 100%, plays audio, and fires the spell.
* **Branch B (The Watcher):** Suspends and monitors whether a cancel condition occurs (damage taken or movement).

```odin
package gameplay

import "coroutine"

Player_Cast :: struct {
    is_casting:    bool,
    cast_progress: f32,
    took_damage:   bool,
    is_moving:     bool,
    pos:           [2]f32,
}

tween_f32 :: proc(f: ^coroutine.Fiber, val: ^f32, start, target, duration: f32) {
    elapsed: f32 = 0
    for elapsed < duration {
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / duration, 0.0, 1.0)
        val^ = start + (target - start) * (t * t) // Ease-in quad
        coroutine.yield(f)
    }
    val^ = target
}

cast_fireball_coroutine :: proc(f: ^coroutine.Fiber, player: ^Player_Cast) {
    player.is_casting = true
    player.cast_progress = 0.0
    player.took_damage = false

    // Race workload vs cancellation triggers:
    winner := coroutine.race(f,
        // Branch 0: Casting Workload
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            tween_f32(f, &p.cast_progress, 0.0, 1.0, 2.5)
            // Cast completed! Fire missile!
            spawn_fireball_projectile(p.pos)
        }, player),

        // Branch 1: Cancellation Watchdog
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            for !(p.took_damage || p.is_moving) {
                coroutine.yield(f)
            }
        }, player),
    )

    player.is_casting = false
    if winner == 1 {
        // Interrupted by damage or movement
        player.cast_progress = 0.0
        trigger_fizzle_vfx(player.pos)
    }
}
```

---

## Recipe 2: Interactive Dialogue & Cutscene Tree (`coroutine/sync` Channel)

### Problem
A cutscene displays typewriter text, waits for the player to select a choice from a menu, and branches into the appropriate response without blocking the 60 FPS render loop.

### Solution
Use a `sync.Channel(Dialogue_Choice)` from `coroutine/sync` for player menu choice responses.

```odin
package gameplay

import "coroutine"
import sync "coroutine/sync"

Dialogue_Choice :: enum {
    Accept_Quest,
    Ask_Reward,
    Decline,
}

Dialogue_Context :: struct {
    npc_name:       string,
    current_line:   string,
    choice_channel: sync.Channel(Dialogue_Choice),
}

dialogue_tree_coroutine :: proc(f: ^coroutine.Fiber, ctx: ^Dialogue_Context) {
    // 1. NPC Greeting
    ctx.current_line = "Greetings, Traveler! The village needs your assistance."
    coroutine.wait(f, 2.0)

    ctx.current_line = "Will you venture into the Whispering Catacombs?"
    coroutine.wait(f, 1.5)

    // 2. Open Choice UI & Await Player Input (Suspends fiber until player clicks)
    choice, ok := sync.chan_recv(f, &ctx.choice_channel)
    if !ok do return

    // 3. Branching response
    switch choice {
    case .Accept_Quest:
        ctx.current_line = "May the light guide your blade! Take this ancient talisman."
        coroutine.wait(f, 3.0)
    case .Ask_Reward:
        ctx.current_line = "I can offer 500 gold pieces and my family's heirloom."
        coroutine.wait(f, 3.0)
    case .Decline:
        ctx.current_line = "Then doom awaits us all..."
        coroutine.wait(f, 2.5)
    }

    ctx.current_line = ""
}
```

---

## Recipe 3: Multi-Wave Enemy Spawner (`Fiber_Scope` + `scope_wait`)

### Problem
An arena encounter spawns waves of enemies. Wave 2 must **only** start after **all** enemies in Wave 1 are defeated. Transitioning between phases must abort previous phase fibers.

### Solution
Use `coroutine.scope_wait` to block until an entire wave's `Fiber_Scope` empties, and `coroutine.scope_cancel` to clean up combat subtrees upon transition.

```odin
package gameplay

import "coroutine"

Wave_Manager :: struct {
    sched:      ^coroutine.Scheduler,
    wave_scope: coroutine.Fiber_Scope,
    boss_scope: coroutine.Fiber_Scope,
}

spawn_enemy :: proc(sched: ^coroutine.Scheduler, scope: ^coroutine.Fiber_Scope, pos: [2]f32) {
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber) {
        for is_enemy_alive() {
            coroutine.yield(f)
            // AI behavior...
        }
    }, scope = scope)
}

arena_master_timeline :: proc(f: ^coroutine.Fiber, wm: ^Wave_Manager) {
    // === WAVE 1: 5 Minions ===
    for i in 0 ..< 5 {
        spawn_enemy(wm.sched, &wm.wave_scope, [2]f32{f32(i * 100), 200})
    }
    // Suspends until ALL 5 minions in wave_scope die!
    coroutine.scope_wait(f, &wm.wave_scope)

    // === WAVE 2: 3 Elites ===
    coroutine.wait(f, 2.0)
    for i in 0 ..< 3 {
        spawn_enemy(wm.sched, &wm.wave_scope, [2]f32{f32(i * 200), 300})
    }
    coroutine.scope_wait(f, &wm.wave_scope)

    // === BOSS ENCOUNTER ===
    coroutine.spawn_ptr(wm.sched, boss_phase1_timeline, wm, scope = &wm.boss_scope)
}
```

---

## Recipe 4: AI Behavior Priority Fallbacks & Rush Objectives (`fallback` + `rush`)

### Problem
An AI enemy needs a priority decision tree:
1. Try heavy melee slam (fails if player > 80px).
2. If melee fails, try ranged snipe (fails if no line of sight).
3. If snipe fails, fallback to patrol.

### Solution
Use `coroutine.fallback` and `coroutine.fail`.

```odin
package gameplay

import "coroutine"

Enemy_AI :: struct {
    pos:        [2]f32,
    player_pos: [2]f32,
    has_los:    bool,
}

enemy_decision_loop :: proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
    for {
        // Executes sequentially until first SUCCESS
        coroutine.fallback(f,
            // 1. Priority: Melee Slam
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                dist := distance(e.pos, e.player_pos)
                if dist > 80.0 {
                    coroutine.fail(f) // Too far! Fallback to next
                }
                execute_slam_animation(f, e)
            }, e),

            // 2. Secondary: Ranged Snipe
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                if !e.has_los {
                    coroutine.fail(f) // No line of sight! Fallback to next
                }
                execute_snipe_animation(f, e)
            }, e),

            // 3. Guaranteed Fallback: Patrol
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                patrol_routine(f, e)
            }, e),
        )

        coroutine.wait(f, 0.5)
    }
}

// Opportunistic scouting with rush:
// Parent resumes as soon as ANY scout succeeds, but other scouts
// continue surveying the map concurrently in the background!
scouting_mission :: proc(f: ^coroutine.Fiber) {
    coroutine.rush(f,
        coroutine.branch(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 0.4)
            coroutine.fail(f) // Dead end: drops out harmlessly
        }),
        coroutine.branch(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 0.8)
            // Primary objective located! Unblocks parent immediately.
        }),
        coroutine.branch(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 2.0)
            // Secondary objective mapped in background (not cancelled by rush!)
        }),
    )
    // Parent continues gameplay immediately at 0.8s!
}
```

---

## Recipe 5: Damped Smooth Spring Follower (Tween Pattern)

### Problem
A camera or floating pet needs to follow a target with smooth interpolation over time.

### Solution
Write a 5-line property tween loop using `coroutine.yield(f)`:

```odin
package gameplay

import "coroutine"

Camera_Rig :: struct {
    pos:        [2]f32,
    target_pos: [2]f32,
}

tween_vec2 :: proc(f: ^coroutine.Fiber, val: ^[2]f32, target: [2]f32, duration: f32) {
    start := val^
    elapsed: f32 = 0
    for elapsed < duration {
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / duration, 0.0, 1.0)
        // Smooth cubic ease-out
        t = 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t)
        val^ = start + (target - start) * t
        coroutine.yield(f)
    }
    val^ = target
}

camera_follower_coroutine :: proc(f: ^coroutine.Fiber, cam: ^Camera_Rig) {
    for {
        if cam.pos != cam.target_pos {
            tween_vec2(f, &cam.pos, cam.target_pos, 0.4)
        } else {
            coroutine.yield(f)
        }
    }
}
```

---

## Recipe 6: Unpausable Real-Time Pause Menus (`CLOCK_REAL`)

### Problem
When the player opens the pause menu, gameplay simulation halts (`CLOCK_SIM` is paused). UI transitions and button hover wobbles must continue animating smoothly in real wall-clock time.

### Solution
Spawn UI animations with `clock = coroutine.CLOCK_REAL`:

```odin
package ui

import "coroutine"

Pause_Menu :: struct {
    is_open:      bool,
    backdrop_dim: f32,
    banner_scale: f32,
    sched:        ^coroutine.Scheduler,
}

open_pause_menu :: proc(menu: ^Pause_Menu) {
    menu.is_open = true

    // Spawn unpausable real-time UI animation fiber on CLOCK_REAL:
    coroutine.spawn(menu.sched, proc(f: ^coroutine.Fiber, m: ^Pause_Menu) {
        elapsed: f32 = 0.0
        duration: f32 = 0.30

        for elapsed < duration {
            dt := coroutine.delta_time(f)
            elapsed += dt
            t := min(1.0, elapsed / duration)

            m.backdrop_dim = t * 0.75
            m.banner_scale = 1.0 + (1.0 - t) * 0.2
            coroutine.yield(f)
        }

        m.backdrop_dim = 0.75
        m.banner_scale = 1.0
    }, menu, clock = coroutine.CLOCK_REAL)
}
```

---

## Recipe 7: Lockstep Fixed-Tick Physics & Rollback Netcode (`CLOCK_PHYS`)

### Problem
Multiplayer fighting games and physics engines require exact deterministic tick progression without floating point accumulation errors.

### Solution
Use `coroutine.CLOCK_PHYS` and `coroutine.wait_steps(f, 1)`.

```odin
package physics

import "coroutine"

Physics_Object :: struct {
    pos: [2]f32,
    vel: [2]f32,
}

projectile_sim :: proc(f: ^coroutine.Fiber, obj: ^Physics_Object) {
    for i := 0; i < 60; i += 1 {
        // Wait exactly 1 integer physics tick
        coroutine.wait_steps(f, 1)

        obj.pos += obj.vel
        obj.vel.y += 0.98 // Fixed gravity step
    }
}

spawn_projectile :: proc(sched: ^coroutine.Scheduler, obj: ^Physics_Object) {
    coroutine.spawn(sched, projectile_sim, obj, clock = coroutine.CLOCK_PHYS)
}
```

---

## Recipe 8: Multi-Phase Boss AI with Hierarchical Scopes (`Fiber_Scope`)

### Problem
A raid boss dynamically shifts behavior across 3 distinct phases. Transitioning phases must abort all active phase-1 spell channels cleanly before starting phase 2.

### Solution
Use `coroutine.Fiber_Scope` with `coroutine.scope_cancel` to cleanly prune previous phase fibers:

```odin
package gameplay

import "coroutine"

Boss_Entity :: struct {
    hp:          int,
    phase_scope: coroutine.Fiber_Scope,
    sched:       ^coroutine.Scheduler,
}

boss_switch_phase :: proc(b: ^Boss_Entity, phase_proc: proc(^coroutine.Fiber, ^Boss_Entity)) {
    // 1. Instantly abort all active fibers from the previous phase!
    coroutine.scope_cancel(b.sched, &b.phase_scope)

    // 2. Spawn the new phase routine into the fresh scope:
    coroutine.spawn(b.sched, phase_proc, b, scope = &b.phase_scope)
}

boss_phase_1 :: proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
    for {
        cast_melee_slam(f, b)
        coroutine.wait(f, 2.0)
    }
}

boss_phase_2 :: proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
    for {
        cast_radial_bullet_hell(f, b)
        coroutine.wait(f, 1.0)
    }
}

boss_lifecycle_controller :: proc(f: ^coroutine.Fiber, b: ^Boss_Entity) {
    boss_switch_phase(b, boss_phase_1)

    // Wait until HP drops below 50%
    for b.hp >= 50 {
        coroutine.yield(f)
    }

    // Seamlessly cancel Phase 1 attacks and launch Phase 2!
    boss_switch_phase(b, boss_phase_2)
}
```

---

## Recipe 9: RTS Unit Action Queue with Command Preemption & Waypoints

### Problem
An RTS game requires units to process a queue of commands (Move $\rightarrow$ Attack $\rightarrow$ Build). When a player issues a new immediate order, the current action must abort instantly.

### Solution
Use `coroutine.Fiber_Scope` to manage unit action lifecycles and a dynamic action queue:

```odin
package gameplay

import "coroutine"

Command_Kind :: enum { Move, Attack_Target, Build_Structure }

Unit_Command :: struct {
    kind:       Command_Kind,
    target_pos: [2]f32,
    target_id:  u32,
}

RTS_Unit :: struct {
    pos:          [2]f32,
    action_scope: coroutine.Fiber_Scope,
    cmd_queue:    [dynamic]Unit_Command,
    sched:        ^coroutine.Scheduler,
}

unit_issue_immediate_order :: proc(unit: ^RTS_Unit, cmd: Unit_Command) {
    // 1. Instantly abort current executing action fiber
    coroutine.scope_cancel(unit.sched, &unit.action_scope)
    clear(&unit.cmd_queue)

    // 2. Start new action fiber
    append(&unit.cmd_queue, cmd)
    coroutine.spawn(unit.sched, unit_action_processor, unit, scope = &unit.action_scope)
}

unit_action_processor :: proc(f: ^coroutine.Fiber, unit: ^RTS_Unit) {
    for len(unit.cmd_queue) > 0 {
        cmd := pop_front(&unit.cmd_queue)

        switch cmd.kind {
        case .Move:
            tween_vec2(f, &unit.pos, cmd.target_pos, 2.0)

        case .Attack_Target:
            for i := 0; i < 3; i += 1 {
                coroutine.wait(f, 0.8) // Attack swing timer
            }

        case .Build_Structure:
            coroutine.wait(f, 5.0) // 5s construction time
        }
    }
}
```

---

## Recipe 10: Multi-Channel Network & Input Multiplexer (`chan_select_recv`)

### Problem
A multiplayer game client needs a single unified actor loop consuming commands arriving from multiple decoupled streams: local player keypresses and server network packets.

### Solution
Use `sync.chan_select_recv` from `coroutine/sync`:

```odin
package gameplay

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Command_Packet :: struct {
    sender_id: u32,
    action:    string,
}

actor_input_multiplexer :: proc(
    f: ^coroutine.Fiber,
    local_input_chan: ^sync.Channel(Command_Packet),
    network_recv_chan: ^sync.Channel(Command_Packet),
) {
    channels := []^sync.Channel(Command_Packet){local_input_chan, network_recv_chan}

    for {
        // Suspends until either local input or server packet arrives:
        ready_idx, packet, ok := sync.chan_select_recv(f, channels)
        if !ok do break

        switch ready_idx {
        case 0:
            fmt.printf("[Local Input] Executing client-predicted action: %s\n", packet.action)
        case 1:
            fmt.printf("[Server Network] Reconciling server state: %s from sender %d\n", packet.action, packet.sender_id)
        }
    }
}
```

---

## Recipe 11: Decoupled Stage Transition Signals (`Signal` / `Event(T)`)

### Problem
When a cutscene triggers or the player dies, dozens of independent entities must react immediately without needing to share a monolithic `Fiber_Scope`.

### Solution
Use `coroutine.Signal` or `coroutine.Event(T)` as a lightweight, zero-polling broadcast handle:

```odin
package gameplay

import "core:fmt"
import "coroutine"

Game_Session :: struct {
    sched:              coroutine.Scheduler,
    stage_clear_signal: coroutine.Signal,
}

wildlife_ambient_fiber :: proc(f: ^coroutine.Fiber, sig: ^coroutine.Signal) {
    coroutine.signal_wait(f, sig) // Zero-polling suspension!
    fmt.println("[Wildlife AI] Stage cleared; smoothly despawning ambient fauna.")
}

session_end_stage :: proc(session: ^Game_Session) {
    // Unblocks all signal listeners instantly in one tick:
    coroutine.signal_emit(&session.sched, &session.stage_clear_signal)
}

// Latched Milestone Transitions (Sticky_Signal / Sticky_Event(T)):
// If an event can occur before late-joining fibers begin awaiting (e.g. game phase switches,
// asset loading milestones), standard broadcast events drop the unawaited signal.
// Sticky_Signal / Sticky_Event(T) caches the signal state so late joiners unblock immediately:
late_joining_hud_fiber :: proc(f: ^coroutine.Fiber, ready_sig: ^coroutine.Sticky_Signal) {
    coroutine.sticky_signal_wait(f, ready_sig) // Resumes immediately if already signaled!
    fmt.println("[HUD] Initialized after game ready milestone.")
}
```

---

## Recipe 12: Entity Sub-Scopes & Localized EMP Stun (`Fiber_Scope`)

### Problem
An in-game EMP bomb detonates within a radius. It must immediately disrupt and cancel all `combat_scope` coroutines on affected enemies, while leaving entity `movement_scope` running unaffected in clean $O(1)$ time.

### Solution
Structure entity behaviors with dedicated sub-scopes:

```odin
package gameplay

import "core:fmt"
import "coroutine"

Drone :: struct {
    entity_scope: coroutine.Fiber_Scope, // Death cancels all
    combat_scope: coroutine.Fiber_Scope, // Stun / EMP cancels attacks
    is_alive:     bool,
}

spawn_enemy_drone :: proc(sched: ^coroutine.Scheduler, drone: ^Drone) {
    // Combat loop (Bounded to combat_scope)
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        for d.is_alive {
            fmt.println("Drone firing lasers!")
            coroutine.wait(f, 0.5)
        }
    }, drone, scope = &drone.combat_scope)

    // Movement patrol loop (Bounded to entity_scope - Immune to EMP!)
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        for d.is_alive {
            fmt.println("Drone drifting forward...")
            coroutine.wait(f, 1.0)
        }
    }, drone, scope = &drone.entity_scope)
}

detonate_emp_blast_on_drone :: proc(sched: ^coroutine.Scheduler, drone: ^Drone) {
    // Cancels only combat sub-scope instantly in O(1) time:
    coroutine.scope_cancel(sched, &drone.combat_scope)
    fmt.println("EMP DISRUPTION: Stunned drone combat sub-scope!")
}
```

---

## Recipe 13: Channel Timeout & Deadlock-Free Message Polling (`chan_recv_timeout`)

### Problem
A receiver fiber reads messages from a remote producer. If the producer stalls, the consumer must not block forever.

### Solution
Use `sync.chan_recv_timeout(f, ch, timeout_seconds)` from `coroutine/sync`:

```odin
package gameplay

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Telemetry_Packet :: struct {
    sender_id: int,
    ping_ms:   f32,
}

telemetry_monitor_fiber :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(Telemetry_Packet)) {
    for {
        packet, ok, timed_out := sync.chan_recv_timeout(f, ch, timeout_seconds = 1.5)

        if timed_out {
            fmt.println("[WARN] Remote sensor heartbeat lost! Falling back to autonomous navigation.")
            break
        }

        if !ok {
            fmt.println("[INFO] Telemetry channel closed cleanly.")
            break
        }

        fmt.printf("[TELEMETRY] Node #%d ping: %.1f ms\n", packet.sender_id, packet.ping_ms)
    }
}
```

---

## Recipe 14: Zero-Drift Periodic Heartbeats & Damage-over-Time (`ticker_wait`)

### Problem
When executing periodic gameplay actions with naive `wait(f, interval)`, frame execution delays compound over time. A poison DoT intended to tick once every 0.5s over 60 seconds may only tick 100 times instead of 120 due to cumulative frame-rate drift.

### Solution
Use built-in fiber-owned `coroutine.ticker_wait(f, interval)`.

```odin
package gameplay

import "coroutine"

apply_poison_dot_fiber :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    // Exactly 10 ticks over 5.0 seconds with zero cumulative drift:
    for _ in 0 ..< 10 {
        coroutine.ticker_wait(f, interval_seconds = 0.5)
        enemy.hp -= 12.0
        spawn_poison_vfx(enemy.pos)
    }
}
```

---

## Recipe 15: Deadlock-Proof Scoped Mutex & Semaphore Locks (`with_mutex` / `with_semaphore`)

### Problem
Fibers acquiring cooperative mutexes or counting semaphores may fail to call `mutex_unlock` or `semaphore_release` if an early `return` or error branch is taken.

### Solution
Use `sync.with_mutex` and `sync.with_semaphore` from `coroutine/sync`:

```odin
package gameplay

import "coroutine"
import sync "coroutine/sync"

Drone_Task :: struct {
    pad_mutex: ^sync.Fiber_Mutex,
    drone_id:  int,
    pos:       [2]f32,
}

drone_recharge_fiber :: proc(f: ^coroutine.Fiber, task: ^Drone_Task) {
    // Guarantees unlock on return or abort:
    sync.with_mutex(f, task.pad_mutex, proc(f: ^coroutine.Fiber, t: ^Drone_Task) {
        tween_vec2(f, &t.pos, {400, 300}, 0.5)
        coroutine.wait(f, 1.2) // Charge battery
    }, task)
}
```

---

## Recipe 16: Structured Emergency Task Abort (`race` & `Signal`)

### Problem
An interactive player action (hacking a terminal) needs to be preempted immediately if an emergency alarm signal trips.

### Solution
Use `coroutine.race` combining the primary workload with a `coroutine.signal_wait` branch:

```odin
package gameplay

import "core:fmt"
import "coroutine"

hack_terminal_fiber :: proc(f: ^coroutine.Fiber, term: ^Terminal) {
    winner := coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, t: ^Terminal) {
            tween_f32(f, &t.hack_progress, 0.0, 1.0, 3.0)
            t.is_hacked = true
        }, term, name = "Hack Workload"),

        coroutine.branch(proc(f: ^coroutine.Fiber, sig: ^coroutine.Signal) {
            coroutine.signal_wait(f, sig)
        }, &g_lockdown_signal, name = "Lockdown Signal Watcher"),
    )

    if winner == 1 {
        fmt.println("Hacking aborted: Emergency lockdown alarm sounded!")
        term.hack_progress = 0.0
    }
}
```

---

## Recipe 17: Custom In-Engine Hierarchy Tree Debuggers (`scheduler_walk_tree`)

### Problem
Developers building in-engine GUI visualizers (e.g. Raylib, Dear ImGui, Sokol) need to traverse the active coroutine tree without writing duplicate recursive boilerplate.

### Solution
Use `coroutine.scheduler_walk_tree` with a `coroutine.Fiber_Visitor` procedure:

```odin
package gameplay

import "core:fmt"
import "coroutine"

Draw_Context :: struct {
    start_y: i32,
    row_h:   i32,
}

render_fiber_debugger_hud :: proc(sched: ^coroutine.Scheduler) {
    ctx := Draw_Context{start_y = 40, row_h = 18}

    coroutine.scheduler_walk_tree(sched, proc(f: ^coroutine.Fiber, depth: int, user_data: rawptr) {
        c := cast(^Draw_Context)user_data
        indent := depth * 16
        used, total := coroutine.fiber_calc_stack_usage(f)

        name := f.debug_name != "" ? f.debug_name : "Fiber"
        text := fmt.tprintf("%*s[#%d] %s (%v) - %.1fKB/%.0fKB", indent, "", f.handle, name, f.status, f32(used)/1024.0, f32(total)/1024.0)

        draw_hud_text(text, 20 + i32(indent), c.start_y)
        c.start_y += c.row_h
    }, &ctx)
}
```
