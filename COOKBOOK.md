# The Odin Coroutine Gameplay Cookbook

A curated collection of production-ready, copy-pasteable gameplay architectures built with the `coroutine` library.

---

## Table of Contents
1. [Recipe 1: Ability Channeling & Casting with Cancel Preemption (`race`)](#recipe-1-ability-channeling--casting-with-cancel-preemption-race)
2. [Recipe 2: Interactive Dialogue & Cutscene Tree (`Channel` + `Generator`)](#recipe-2-interactive-dialogue--cutscene-tree-channel--generator)
3. [Recipe 3: Multi-Wave Enemy Spawner (`Phase_Director` + `scope_wait`)](#recipe-3-multi-wave-enemy-spawner-phase_director--scope_wait)
4. [Recipe 4: AI Behavior Priority Fallbacks & Rush Objectives (`fallback` + `rush`)](#recipe-4-ai-behavior-priority-fallbacks--rush-objectives-fallback--rush)
5. [Recipe 5: Damped Smooth Spring Follower (`tween`)](#recipe-5-damped-smooth-spring-follower-tween)
6. [Recipe 6: Unpausable Real-Time Pause Menus & HUD Animations (`wait_real` + `spawn_real`)](#recipe-6-unpausable-real-time-pause-menus--hud-animations-wait_real--spawn_real)
7. [Recipe 7: Lockstep Fixed-Tick Physics & Rollback Netcode (`wait_ticks`)](#recipe-7-lockstep-fixed-tick-physics--rollback-netcode-wait_ticks)
8. [Recipe 8: Multi-Phase Boss AI with `Phase_Director`](#recipe-8-multi-phase-boss-ai-with-phase_director)
9. [Recipe 9: RTS Unit Action Queue with Command Preemption & Waypoints](#recipe-9-rts-unit-action-queue-with-command-preemption--waypoints)
10. [Recipe 10: Multi-Channel Network & Input Multiplexer (`chan_select_recv`)](#recipe-10-multi-channel-network--input-multiplexer-chan_select_recv)
11. [Recipe 11: Decoupled Stage Transition Signals (`Signal` / `Event(T)`)](#recipe-11-decoupled-stage-transition-signals-signal--eventt)
12. [Recipe 12: Entity Sub-Scopes & Localized EMP Stun (`Fiber_Scope`)](#recipe-12-entity-sub-scopes--localized-emp-stun-fiber_scope)
13. [Recipe 13: Channel Timeout & Deadlock-Free Message Polling (`chan_recv_timeout`)](#recipe-13-channel-timeout--deadlock-free-message-polling-chan_recv_timeout)
14. [Recipe 14: Zero-Drift Periodic Heartbeats & Damage-over-Time (`Ticker`)](#recipe-14-zero-drift-periodic-heartbeats--damage-over-time-ticker)
15. [Recipe 15: Deadlock-Proof Scoped Mutex & Semaphore Locks (`with_mutex` / `with_semaphore`)](#recipe-15-deadlock-proof-scoped-mutex--semaphore-locks-with_mutex--with_semaphore)
16. [Recipe 16: Structured Emergency Task Abort (`race` & `Signal`)](#recipe-16-structured-emergency-task-abort-race--signal)
17. [Recipe 17: Custom In-Engine Hierarchy Tree Debuggers (`scheduler_walk_tree`)](#recipe-17-custom-in-engine-hierarchy-tree-debuggers-scheduler_walk_tree)

> 💡 *See also: [`docs/guides/GUIDE_FOOTGUNS.md`](docs/guides/GUIDE_FOOTGUNS.md) for the 11 real-world cooperative fiber traps, engine mitigations, and the Gameplay Programmer's Golden Rules.*

---

## Recipe 1: Ability Channeling & Casting with Cancel Preemption (`race`)

### Problem
A player starts casting a powerful spell over 2.5 seconds. If the player moves, takes damage, or presses ESC, the cast must abort instantly, reset the cast bar, and trigger a fizzle effect.

### Solution
Use `coroutine.race` with two parallel branches:
* **Branch A (The Workload):** Tweens the cast bar from 0% to 100%, plays audio, and fires the spell.
* **Branch B (The Watcher):** Waits until a cancel condition occurs (damage taken or movement).

```odin
package gameplay

import "core:math"
import "src/coroutine"

Player_Cast :: struct {
    is_casting:    bool,
    cast_progress: f32,
    took_damage:   bool,
    is_moving:     bool,
    pos:           [2]f32,
}

cast_fireball_coroutine :: proc(f: ^coroutine.Fiber, player: ^Player_Cast) {
    player.is_casting = true
    player.cast_progress = 0.0
    player.took_damage = false

    // Race workload vs cancellation triggers
    winner := coroutine.race(f, {
        // Branch 0: Casting Workload
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            coroutine.tween_f32(f, &p.cast_progress, 0.0, 1.0, 2.5, coroutine.ease_in_quad)
            // Cast completed! Fire missile!
            spawn_fireball_projectile(p.pos)
        }, player),

        // Branch 1: Cancellation Watchdog
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            coroutine.wait_until(f, proc(p: ^Player_Cast) -> bool {
                return p.took_damage || p.is_moving
            }, p)
        }, player),
    })

    player.is_casting = false
    if winner == 1 {
        // Interrupted by damage or movement
        player.cast_progress = 0.0
        trigger_fizzle_vfx(player.pos)
    }
}
```

---

## Recipe 2: Interactive Dialogue & Cutscene Tree (`Channel` + `Generator`)

### Problem
A cutscene displays typewriter text, waits for the player to select a choice from a menu, and branches into the appropriate response without blocking the 60 FPS render loop.

### Solution
Use a `coroutine.Channel(int)` for player menu choice responses and a pull-based `Generator` to stream sentences.

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

Dialogue_Choice :: enum {
    Accept_Quest,
    Ask_Reward,
    Decline,
}

Dialogue_Context :: struct {
    npc_name:       string,
    current_line:   string,
    choice_channel: coroutine.Channel(Dialogue_Choice),
}

dialogue_tree_coroutine :: proc(f: ^coroutine.Fiber, ctx: ^Dialogue_Context) {
    // 1. NPC Greeting
    ctx.current_line = "Greetings, Traveler! The village needs your assistance."
    coroutine.wait(f, 2.0)

    ctx.current_line = "Will you venture into the Whispering Catacombs?"
    coroutine.wait(f, 1.5)

    // 2. Open Choice UI & Await Player Input (Suspends fiber until player clicks)
    choice, ok := coroutine.chan_recv(f, &ctx.choice_channel)
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

## Recipe 3: Multi-Wave Enemy Spawner (`Phase_Director` + `scope_wait`)

### Problem
An arena encounter spawns waves of enemies. Wave 2 must **only** start after **all** enemies in Wave 1 are defeated. When the boss appears, it transitions through distinct combat phases.

### Solution
Use `coroutine.scope_wait` to block until an entire wave's `Fiber_Scope` empties, and `coroutine.Phase_Director` to drive the boss lifecycle.

```odin
package gameplay

import "src/coroutine"

Wave_Manager :: struct {
    sched:      ^coroutine.Scheduler,
    wave_scope: coroutine.Fiber_Scope,
    director:   coroutine.Phase_Director,
}

spawn_enemy :: proc(sched: ^coroutine.Scheduler, scope: ^coroutine.Fiber_Scope, pos: [2]f32) {
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber) {
        for is_enemy_alive() {
            coroutine.yield_frame(f)
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

    // === BOSS ENCOUNTER via Phase_Director ===
    coroutine.phase_switch(&wm.director, 1, boss_phase1_timeline, wm)
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

import "src/coroutine"

Enemy_AI :: struct {
    pos:        [2]f32,
    player_pos: [2]f32,
    has_los:    bool,
}

enemy_decision_loop :: proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
    for {
        // Executes sequentially until first SUCCESS
        coroutine.fallback(f, {
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
        })

        coroutine.wait(f, 0.5)
    }
}
```

---

## Recipe 5: Damped Smooth Spring Follower (`tween`)

### Problem
A camera or floating pet needs to follow a target with juicy, springy overshoot without writing custom integration math.

### Solution
Use `coroutine.tween_vector2` with `coroutine.ease_out_back`.

```odin
package gameplay

import "src/coroutine"

Camera_Rig :: struct {
    pos:        [2]f32,
    target_pos: [2]f32,
}

camera_follower_coroutine :: proc(f: ^coroutine.Fiber, cam: ^Camera_Rig) {
    for {
        if cam.pos != cam.target_pos {
            coroutine.tween_vector2(f, &cam.pos, cam.pos, cam.target_pos, 0.4, coroutine.ease_out_back)
        } else {
            coroutine.yield_frame(f)
        }
    }
}
```

---

## Recipe 6: Unpausable Real-Time Pause Menus & HUD Animations (`wait_real` + `spawn_real`)

### Problem
When the player opens the pause menu, gameplay simulation halts (`sched.is_paused = true`). UI transitions and button hover wobbles must continue animating smoothly in real wall-clock time.

### Solution
Use `coroutine.spawn_real` and `coroutine.wait_real`.

```odin
package ui

import "src/coroutine"

Pause_Menu :: struct {
    is_open:      bool,
    backdrop_dim: f32,
    banner_scale: f32,
    sched:        ^coroutine.Scheduler,
}

open_pause_menu :: proc(menu: ^Pause_Menu) {
    menu.is_open = true

    // 1. Freeze gameplay simulation clock (all standard `wait` fibers halt)
    coroutine.scheduler_set_paused(menu.sched, true)

    // 2. Spawn unpausable real-time UI animation fiber
    coroutine.spawn_real(menu.sched, proc(f: ^coroutine.Fiber, m: ^Pause_Menu) {
        elapsed: f32 = 0.0
        duration: f32 = 0.30

        for elapsed < duration {
            dt := coroutine.delta_real(f)
            elapsed += dt
            t := min(1.0, elapsed / duration)

            m.backdrop_dim = coroutine.ease_out_quad(t) * 0.75
            m.banner_scale = coroutine.ease_out_back(t)

            coroutine.yield_frame(f)
        }

        m.backdrop_dim = 0.75
        m.banner_scale = 1.0
    }, menu)
}
```

---

## Recipe 7: Lockstep Fixed-Tick Physics & Rollback Netcode (`wait_ticks`)

### Problem
Multiplayer fighting games and physics engines require exact deterministic tick progression without floating point accumulation errors.

### Solution
Use integer ticks (`coroutine.wait_ticks` and `coroutine.scheduler_step_ticks`).

```odin
package physics

import "src/coroutine"

Physics_Object :: struct {
    pos: [2]f32,
    vel: [2]f32,
}

projectile_sim :: proc(f: ^coroutine.Fiber, obj: ^Physics_Object) {
    for i := 0; i < 60; i += 1 {
        // Wait exactly 1 integer tick
        coroutine.wait_ticks(f, 1)

        obj.pos += obj.vel
        obj.vel.y += 0.98 // Fixed gravity
    }
}
```

---

## Recipe 8: Multi-Phase Boss AI with `Phase_Director`

### Problem
A raid boss dynamically shifts behavior across 3 distinct phases (Phase 1: Melee, Phase 2: Bullet Hell, Phase 3: Enrage). Transitioning phases must abort all active phase-1 spell channels cleanly before starting phase 2.

### Solution
Use `coroutine.Phase_Director` to safely switch states and auto-cancel previous phase fibers:

```odin
package gameplay

import "src/coroutine"

Boss_Entity :: struct {
    hp:       int,
    director: coroutine.Phase_Director,
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
    // Start in Phase 1
    coroutine.phase_switch(&b.director, 1, boss_phase_1, b)

    // Wait until HP drops below 50%
    coroutine.wait_until(f, proc(b: ^Boss_Entity) -> bool { return b.hp < 50 }, b)

    // Seamlessly cancel Phase 1 and launch Phase 2!
    coroutine.phase_switch(&b.director, 2, boss_phase_2, b)
}
```

---

## Recipe 9: RTS Unit Action Queue with Command Preemption & Waypoints

### Problem
An RTS game (like *Warcraft 3* or *StarCraft*) requires units to process a queue of commands (Move $\rightarrow$ Attack $\rightarrow$ Build). When a player issues a new immediate order (right-clicking without Shift), the current action must abort instantly. When Shift-queuing orders, actions execute in sequence.

### Solution
Use `coroutine.Fiber_Scope` to manage unit action lifecycles and a dynamic action queue:

```odin
package gameplay

import "src/coroutine"

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

// Issue a brand-new immediate order (Cancels existing action immediately!)
unit_issue_immediate_order :: proc(unit: ^RTS_Unit, cmd: Unit_Command) {
    // 1. Instantly abort current executing action fiber
    coroutine.scope_cancel(unit.sched, &unit.action_scope)
    clear(&unit.cmd_queue)

    // 2. Start new action fiber
    append(&unit.cmd_queue, cmd)
    coroutine.spawn_ptr(unit.sched, unit_action_processor, unit, scope = &unit.action_scope)
}

// Issue a shift-queued order (Appends to queue)
unit_queue_order :: proc(unit: ^RTS_Unit, cmd: Unit_Command) {
    append(&unit.cmd_queue, cmd)
    if coroutine.scope_is_empty(&unit.action_scope) {
        coroutine.spawn_ptr(unit.sched, unit_action_processor, unit, scope = &unit.action_scope)
    }
}

// Action Queue Processor Fiber
unit_action_processor :: proc(f: ^coroutine.Fiber, unit: ^RTS_Unit) {
    for len(unit.cmd_queue) > 0 {
        cmd := pop_front(&unit.cmd_queue)

        switch cmd.kind {
        case .Move:
            // Tween position towards waypoint
            coroutine.tween_vector2(f, &unit.pos, unit.pos, cmd.target_pos, 2.0, coroutine.ease_linear)

        case .Attack_Target:
            // Combat animation loop
            for i := 0; i < 3; i += 1 {
                coroutine.wait(f, 0.8) // Attack swing timer
            }

        case .Build_Structure:
            // Construction channel
            coroutine.wait(f, 5.0) // 5s construction time
        }
    }
}
```

---

## Recipe 10: Multi-Channel Network & Input Multiplexer (`chan_select_recv`)

### Problem
A multiplayer game client needs a single unified actor processing loop that consumes commands arriving from multiple decoupled streams: local player keypresses, authoritative server network packets, and background pathfinder solutions.

### Solution
Use `coroutine.chan_select_recv` to suspend until *any* channel produces an event:

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

Command_Packet :: struct {
    sender_id: u32,
    action:    string,
}

actor_input_multiplexer :: proc(
    f: ^coroutine.Fiber,
    local_input_chan: ^coroutine.Channel(Command_Packet),
    network_recv_chan: ^coroutine.Channel(Command_Packet),
) {
    channels := []^coroutine.Channel(Command_Packet){local_input_chan, network_recv_chan}

    for {
        // Suspends until either local input or server packet arrives:
        ready_idx, packet, ok := coroutine.chan_select_recv(f, channels)
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
When a cutscene triggers or the player dies, dozens of independent entities across completely different systems (background particle spawners, ambient wildlife AI, combat encounter scripts) must react immediately without needing to share a monolithic `Fiber_Scope`.

### Solution
Use `coroutine.Signal` or `coroutine.Event(T)` as a lightweight, zero-polling broadcast handle:

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

Game_Session :: struct {
    sched:              coroutine.Scheduler,
    stage_clear_signal: coroutine.Signal,
}

// Any entity can suspend waiting on the transition signal:
wildlife_ambient_fiber :: proc(f: ^coroutine.Fiber, sig: ^coroutine.Signal) {
    coroutine.signal_wait(f, sig) // Zero-polling suspension!
    fmt.println("[Wildlife AI] Stage cleared; smoothly despawning ambient fauna.")
}

// When level completes or player reaches extraction:
session_end_stage :: proc(session: ^Game_Session) {
    // Unblocks all signal listeners instantly in one tick:
    coroutine.signal_emit(&session.sched, &session.stage_clear_signal)
}
```

---

## Recipe 12: Entity Sub-Scopes & Localized EMP Stun (`Fiber_Scope`)

### Problem
An in-game EMP bomb detonates within a radius. It must immediately disrupt and cancel all `combat_scope` and `shield_scope` coroutines on affected enemies, while leaving entity `movement_scope` and physics running unaffected in clean $O(1)$ time without global pool scans.

### Solution
Structure entity behaviors with dedicated sub-scopes:

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

Drone :: struct {
    entity_scope: coroutine.Fiber_Scope, // Death cancels all
    combat_scope: coroutine.Fiber_Scope, // Stun / EMP cancels attacks
    shield_scope: coroutine.Fiber_Scope, // EMP cancels shields
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

    // Shield loop (Bounded to shield_scope)
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        for d.is_alive {
            coroutine.wait(f, 0.1)
        }
    }, drone, scope = &drone.shield_scope)

    // Movement patrol loop (Bounded to entity_scope - Immune to EMP!)
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        for d.is_alive {
            fmt.println("Drone drifting forward...")
            coroutine.wait(f, 1.0)
        }
    }, drone, scope = &drone.entity_scope)
}

// EMP Detonation Event on target drone:
detonate_emp_blast_on_drone :: proc(sched: ^coroutine.Scheduler, drone: ^Drone) {
    // Cancels only combat and shield sub-scopes instantly in O(1) time:
    coroutine.scope_cancel(sched, &drone.combat_scope)
    coroutine.scope_cancel(sched, &drone.shield_scope)
    fmt.println("EMP DISRUPTION: Stunned drone combat and shield sub-scopes!")
}
```

---

## Recipe 13: Channel Timeout & Deadlock-Free Message Polling (`chan_recv_timeout`)

### Problem
A receiver fiber needs to read telemetry or heartbeat signals from a remote producer or network socket. If the producer terminates, crashes, or stalls, the consumer must not block forever.

### Solution
Use `coroutine.chan_recv_timeout(f, ch, timeout_seconds)` to specify a maximum wait deadline.

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

Telemetry_Packet :: struct {
    sender_id: int,
    ping_ms:   f32,
}

telemetry_monitor_fiber :: proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(Telemetry_Packet)) {
    for {
        // Wait at most 1.5 seconds for the next packet
        packet, ok, timed_out := coroutine.chan_recv_timeout(f, ch, timeout_seconds = 1.5)

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

## Recipe 14: Zero-Drift Periodic Heartbeats & Damage-over-Time (`Ticker`)

### Problem
When executing periodic gameplay actions with naive `wait(f, interval)`, frame execution delays compound over time. A poison DoT intended to tick exactly once every 0.5s over 60 seconds may only tick 100 times instead of 120 due to cumulative delta-time drift.

### Solution
Use `coroutine.Ticker` with `ticker_init` and `ticker_wait`. The ticker tracks absolute target timestamps (`target_time += interval`), eliminating drift across long match sessions.

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

apply_poison_dot_fiber :: proc(f: ^coroutine.Fiber, enemy: ^Enemy) {
    ticker: coroutine.Ticker
    coroutine.ticker_init(&ticker, interval_seconds = 0.5)

    // Exactly 10 ticks over 5.0 seconds with zero drift:
    for _ in 0 ..< 10 {
        coroutine.ticker_wait(f, &ticker)
        enemy.hp -= 12.0
        spawn_poison_vfx(enemy.pos)
    }
}
```

---

## Recipe 15: Deadlock-Proof Scoped Mutex & Semaphore Locks (`with_mutex` / `with_semaphore`)

### Problem
Fibers acquiring cooperative mutexes or counting semaphores may fail to call `mutex_unlock` or `semaphore_release` if an early `return` or error branch is taken, causing permanent subsystem deadlocks.

### Solution
Use `coroutine.with_mutex` and `coroutine.with_semaphore` procedure groups. They guarantee defer unlock upon body completion or early exit.

```odin
package gameplay

import "src/coroutine"

Drone_Task :: struct {
    pad_mutex: ^coroutine.Fiber_Mutex,
    drone_id:  int,
    pos:       [2]f32,
}

drone_recharge_fiber :: proc(f: ^coroutine.Fiber, task: ^Drone_Task) {
    // Guarantees unlock on return or abort:
    coroutine.with_mutex(f, task.pad_mutex, proc(f: ^coroutine.Fiber, t: ^Drone_Task) {
        coroutine.tween_v2(f, &t.pos, t.pos, {400, 300}, 0.5)
        coroutine.wait(f, 1.2) // Charge battery
    }, task)
}
```

---

## Recipe 16: Structured Emergency Task Abort (`race` & `Signal`)

### Problem
An interactive player action (hacking a terminal, channeling a portal, reviving an ally) needs to be preempted immediately if an emergency alarm signal trips, aborting cleanly without orphan fibers.

### Solution
Use `coroutine.race` combining the primary workload with a `coroutine.signal_wait` branch:

```odin
package gameplay

import "core:fmt"
import "src/coroutine"

hack_terminal_fiber :: proc(f: ^coroutine.Fiber, term: ^Terminal) {
    winner := coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, t: ^Terminal) {
            coroutine.tween_f32(f, &t.hack_progress, 0.0, 1.0, 3.0)
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
import "src/coroutine"

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
