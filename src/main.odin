package main

import "core:fmt"
import "core:log"
import "core:mem"
import "coroutine"

// Example Game Entity
Boss :: struct {
    hp:           f32,
    pos_x:        f32,
    shield_power: f32,
    phase:        int,
    scope:        coroutine.Fiber_Scope,
}

// Subroutine: Patrol behavior
boss_patrol_loop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for {
        fmt.printf("[Patrol] Moving Right (X: %.1f -> 200.0)\n", b.pos_x)
        coroutine.tween(f, &b.pos_x, b.pos_x, 200.0, 1.0, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.2)
        fmt.printf("[Patrol] Moving Left (X: %.1f -> -200.0)\n", b.pos_x)
        coroutine.tween(f, &b.pos_x, b.pos_x, -200.0, 1.0, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.2)
    }
}

// Subroutine: Spiral shoot behavior
boss_spiral_shoot_loop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for {
        coroutine.wait(f, 0.4)
        fmt.printf("[Attack] Firing spiral projectile burst at X: %.1f (Boss HP: %.1f)\n", b.pos_x, b.hp)
    }
}

// Full Timeline AI
boss_ai_timeline :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    fmt.println(">>> BOSS ENCOUNTER STARTED <<<")

    // ==========================================
    // PHASE 1: Attack and Patrol until HP < 400
    // ==========================================
    b.phase = 1
    fmt.println("\n--- Starting Phase 1 (Combat + Patrol until HP < 400) ---")

    winner := coroutine.race(f,
        // Branch 0: Condition to end Phase 1
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.wait_until(f, proc(b: ^Boss) -> bool {
                return b.hp < 400.0
            }, b)
            fmt.println("[Trigger] Boss HP dropped below 400! Preempting Phase 1...")
        }, b, "Wait HP < 400"),

        // Branch 1: Parallel combat loops
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync(f,
                coroutine.branch(boss_patrol_loop, b, "Patrol Sub-loop"),
                coroutine.branch(boss_spiral_shoot_loop, b, "Spiral Shoot Sub-loop"),
            )
        }, b, "Phase 1 Combat"),
    )

    fmt.printf("--- Phase 1 Finished (Winner Branch: %d) ---\n", winner)

    // ==========================================
    // PHASE 2: Shield Charge & Burst
    // ==========================================
    b.phase = 2
    fmt.println("\n--- Starting Phase 2 (Centering + Shield Charge) ---")

    // 1. Center the boss
    fmt.printf("[Move] Centering boss to 0.0 from %.1f\n", b.pos_x)
    coroutine.tween(f, &b.pos_x, b.pos_x, 0.0, 0.5, coroutine.ease_in_out_cubic)

    // 2. Shield charge
    coroutine.sync(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            fmt.println("[Visual] Charging shield effect...")
            coroutine.tween(f, &b.shield_power, 0.0, 1.0, 0.6)
            coroutine.wait(f, 0.2)
        }, b, "Shield Charge"),
    )

    fmt.println("[Explosion] Discharging shield burst!")
    b.shield_power = 0.0

    // ==========================================
    // PHASE 3: Enraged State
    // ==========================================
    b.phase = 3
    fmt.println("\n--- Boss Enraged (Phase 3 Complete) ---")
}

main :: proc() {
    context.logger = log.create_console_logger()

    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        for _, leak in track.allocation_map {
            fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
        }
        mem.tracking_allocator_clear(&track)
    }

    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    boss := Boss{
        hp           = 500.0,
        pos_x        = 0.0,
        shield_power = 0.0,
        phase        = 0,
    }
    defer coroutine.scope_destroy(&boss.scope)

    coroutine.spawn(&sched, boss_ai_timeline, &boss, scope = &boss.scope, name = "Boss AI")

    // Simulation loop
    dt: f32 = 0.1
    for frame := 0; frame < 30; frame += 1 {
        // Simulate damage taking in frame 10
        if frame == 10 {
            fmt.println("\n>>> [Player Attack] Dealing 150 damage to Boss! <<<")
            boss.hp -= 150.0 // HP goes 500 -> 350 (< 400 triggers Phase 1 race exit!)
        }

        coroutine.scheduler_step(&sched, dt)
    }

    fmt.println("\nSimulation complete. All fibers finished cleanly.")
}