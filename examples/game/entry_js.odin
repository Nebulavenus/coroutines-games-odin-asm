#+build js
package main

import "base:runtime"
import "core:fmt"
import rl "vendor:raylib"

import coroutine "../.."

main :: proc() {
}

g_wasm_game: Game
g_wasm_game_ready: bool
g_wasm_step_count: int

@(export)
game_wasm_init :: proc "c" () -> bool {
    context = runtime.default_context()
    fmt.println("[Game Wasm] game_wasm_init: initializing window and game...")
    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Coroutines Boss AI Demo")
    rl.SetTargetFPS(60)
    game_init(&g_wasm_game)
    g_wasm_game_ready = true
    fmt.println("[Game Wasm] game_init complete! Active game set:", &g_wasm_game != nil, "| Ready Queue:", len(g_wasm_game.sched.ready_queue), "| Timer Heap:", len(g_wasm_game.sched.clocks[coroutine.CLOCK_SIM].timer_heap))
    return true
}

@(export)
game_wasm_step :: proc "c" (dt: f32) -> bool {
    context = runtime.default_context()
    if !g_wasm_game_ready do return false
    g_wasm_step_count += 1
    if g_wasm_step_count == 1 || g_wasm_step_count % 180 == 0 {
        fmt.println("[Game Wasm] Step #", g_wasm_step_count, "| dt:", dt, "| Boss HP:", g_wasm_game.boss.hp, "| Player HP:", g_wasm_game.player.hp, "| Camera Offset:", g_wasm_game.camera_offset)
    }
    game_update(&g_wasm_game, dt)
    game_render(&g_wasm_game)
    free_all(context.temp_allocator)
    return true
}

@(export)
game_wasm_destroy :: proc "c" () {
    context = runtime.default_context()
    if g_wasm_game_ready {
        fmt.println("[Game Wasm] game_wasm_destroy: cleaning up...")
        game_destroy(&g_wasm_game)
        rl.CloseWindow()
        g_wasm_game_ready = false
        fmt.println("[Game Wasm] Cleanup complete.")
    }
}

@(export)
game_wasm_get_projectile_count :: proc "c" () -> int {
    return g_wasm_game.projectile_count
}

@(export)
game_wasm_get_active_fibers :: proc "c" () -> int {
    context = runtime.default_context()
    stats := coroutine.scheduler_pool_stats(&g_wasm_game.sched)
    return stats.active_fibers
}
