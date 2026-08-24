# The Odin Coroutine Gameplay Cookbook

A curated collection of production-ready, copy-pasteable gameplay architectures built with the `coroutine` library.

---

## Table of Contents
1. [Recipe 1: Ability Channeling & Casting with Cancel Preemption (`race`)](#recipe-1-ability-channeling--casting-with-cancel-preemption-race)
2. [Recipe 2: Interactive Dialogue & Cutscene Tree (`Channel` + `Generator`)](#recipe-2-interactive-dialogue--cutscene-tree-channel--generator)
3. [Recipe 3: Multi-Wave Enemy Spawner (`Phase_Director` + `scope_wait`)](#recipe-3-multi-wave-enemy-spawner-phase_director--scope_wait)
4. [Recipe 4: AI Behavior Priority Fallbacks & Rush Objectives (`fallback` + `rush`)](#recipe-4-ai-behavior-priority-fallbacks--rush-objectives-fallback--rush)
5. [Recipe 5: Damped Smooth Spring Follower (`tween`)](#recipe-5-damped-smooth-spring-follower-tween)

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
    winner := coroutine.race(f,
        // Branch 0: Casting Workload
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            coroutine.tween(f, &p.cast_progress, 0.0, 1.0, 2.5, coroutine.ease_in_quad)
            // Cast completed! Fire missile!
            spawn_fireball_projectile(p.pos)
        }, player, "Cast Workload"),

        // Branch 1: Cancellation Watchdog
        coroutine.branch(proc(f: ^coroutine.Fiber, p: ^Player_Cast) {
            coroutine.wait_until(f, proc(p: ^Player_Cast) -> bool {
                return p.took_damage || p.is_moving
            }, p)
        }, player, "Cast Cancel Watchdog"),
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
    coroutine.spawn(sched, proc(f: ^coroutine.Fiber, p: [2]f32) {
        for is_enemy_alive(p) {
            coroutine.yield_frame(f)
            // AI behavior...
        }
    }, pos, scope = scope)
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
        coroutine.fallback(f,
            // 1. Priority: Melee Slam
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                dist := distance(e.pos, e.player_pos)
                if dist > 80.0 {
                    coroutine.fail(f) // Too far! Fallback to next
                }
                execute_slam_animation(f, e)
            }, e, "Melee Slam"),

            // 2. Secondary: Ranged Snipe
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                if !e.has_los {
                    coroutine.fail(f) // No line of sight! Fallback to next
                }
                execute_snipe_animation(f, e)
            }, e, "Ranged Snipe"),

            // 3. Guaranteed Fallback: Patrol
            coroutine.branch(proc(f: ^coroutine.Fiber, e: ^Enemy_AI) {
                patrol_routine(f, e)
            }, e, "Patrol"),
        )

        coroutine.wait(f, 0.5)
    }
}
```

---

## Recipe 5: Damped Smooth Spring Follower (`tween`)

### Problem
A camera or floating pet needs to follow a target with juicy, springy overshoot without writing complex custom integration math.

### Solution
Use multi-dimensional `coroutine.tween` with `coroutine.ease_out_back` or `coroutine.ease_out_elastic`.

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
            // Spring tween position towards target with back-overshoot
            coroutine.tween(f, &cam.pos, cam.pos, cam.target_pos, 0.4, coroutine.ease_out_back)
        } else {
            coroutine.yield_frame(f)
        }
    }
}
```
