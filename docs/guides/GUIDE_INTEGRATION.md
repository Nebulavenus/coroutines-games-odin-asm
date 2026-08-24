# Game Engine Integration Blueprint (`GUIDE_INTEGRATION.md`)

This guide provides drop-in blueprints for embedding the **Odin Stackful Coroutine Engine** into commercial and custom game engines, including **Raylib**, **Sokol**, **GLFW / SDL**, and custom fixed-tick loops.

---

## 1. Raylib Production Integration Blueprint

Raylib is a popular C-based game engine with native Odin bindings (`vendor:raylib`).

```odin
package main

import "core:fmt"
import "core:mem"
import rl "vendor:raylib"
import "coroutine"

Game_World :: struct {
    sched:        coroutine.Scheduler,
    camera_shake: f32,
    player_pos:   [2]f32,
}

main :: proc() {
    // 1. Setup Tracking Allocator for Zero-Leak Verification
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        if len(track.allocation_map) > 0 {
            fmt.printf("=== %v Memory Leaks Detected ===\n", len(track.allocation_map))
        }
        mem.tracking_allocator_destroy(&track)
    }

    // 2. Initialize Window
    rl.InitWindow(1280, 720, "Raylib Coroutine Production Blueprint")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    // 3. Initialize Coroutine Engine
    world: Game_World
    coroutine.scheduler_init(&world.sched)
    coroutine.scheduler_prewarm(&world.sched, 64) // Pre-allocate slabs during boot
    defer coroutine.scheduler_destroy(&world.sched)

    // 4. Spawn Background World Timelines
    coroutine.spawn(&world.sched, proc(f: ^coroutine.Fiber, w: ^Game_World) {
        for {
            // Periodic world event
            fmt.println("Ambient wind blowing...")
            coroutine.wait(f, 5.0)
        }
    }, &world)

    // 5. Main Game Loop
    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()

        // Handle Player Input
        if rl.IsKeyPressed(.SPACE) {
            // Spawn an interactive camera shake coroutine!
            coroutine.spawn(&world.sched, proc(f: ^coroutine.Fiber, w: ^Game_World) {
                coroutine.tween_f32(f, &w.camera_shake, 10.0, 0.0, 0.5, coroutine.ease_out_quad)
            }, &world)
        }

        // Step the Coroutine Engine
        coroutine.scheduler_step(&world.sched, dt)

        // Render Frame
        rl.BeginDrawing()
        rl.ClearBackground(rl.DARKGRAY)
        rl.DrawText("Press [SPACE] to trigger a smooth Camera Shake Tween!", 20, 20, 20, rl.RAYWHITE)
        rl.DrawText(rl.TextFormat("Active Fibers: %d", len(world.sched.pool.active_fibers)), 20, 50, 18, rl.GREEN)
        rl.EndDrawing()
    }
}
```

---

## 2. Sokol / SDL / GLFW Integration with Fixed-Tick Accumulator

For engines running fixed-step physics with variable render deltas:

```odin
package main

import "core:time"
import "coroutine"

FIXED_DT :: 1.0 / 60.0 // 60 Hz Physics

Engine_Context :: struct {
    sched:       coroutine.Scheduler,
    accumulator: f32,
    last_time:   time.Time,
}

engine_update :: proc(ctx: ^Engine_Context) {
    now := time.now()
    frame_time := cast(f32)time.duration_seconds(time.diff(ctx.last_time, now))
    ctx.last_time = now

    // Cap maximum delta to prevent spiral of death
    if frame_time > 0.25 do frame_time = 0.25
    ctx.accumulator += frame_time

    // 1. Advance Discrete Fixed-Tick Physics
    for ctx.accumulator >= FIXED_DT {
        coroutine.scheduler_step_ticks(&ctx.sched, 1)
        ctx.accumulator -= FIXED_DT
    }

    // 2. Advance Variable Delta Visuals & Real-Time UI
    coroutine.scheduler_step(&ctx.sched, frame_time)
}
```

---

## 3. Clean Level Transitions & Scene Destruction

When switching levels or destroying an entity:
1. **Per-Entity Lifecycle:** Call `coroutine.scope_cancel(&entity.scope)` to instantly abort all coroutines attached to that entity.
2. **Whole-World Cleanup:** Call `coroutine.scheduler_destroy(&sched)` on scene unload to immediately reclaim all memory slabs and reset tracking allocators.
