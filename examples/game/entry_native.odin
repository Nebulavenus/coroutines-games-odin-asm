#+build !js
package main

import "core:fmt"
import "core:log"
import "core:mem"
import rl "vendor:raylib"

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

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "SkookumScript Inspired Concurrency Engine - Boss Fight Demo")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    game: Game
    game_init(&game)
    defer game_destroy(&game)

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        game_update(&game, dt)
        game_render(&game)
        free_all(context.temp_allocator)
    }
}
