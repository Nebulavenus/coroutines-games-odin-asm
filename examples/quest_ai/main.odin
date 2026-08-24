package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:time"
import rl "vendor:raylib"

import "../../src/coroutine"

// ============================================================================
// Constants & Configuration
// ============================================================================

SCREEN_WIDTH  :: 1280
SCREEN_HEIGHT :: 720

// ============================================================================
// Entity & World Data Structures
// ============================================================================

Player :: struct {
    pos:    rl.Vector2,
    speed:  f32,
    radius: f32,
    scope:  coroutine.Fiber_Scope,
}

// --- Zone 1: Knight AI (fallback) ---
Knight_AI :: struct {
    pos:            rl.Vector2,
    home_pos:       rl.Vector2,
    radius:         f32,
    stamina:        f32,
    current_action: string,
    action_color:   rl.Color,
    scope:          coroutine.Fiber_Scope,
}

// --- Zone 2: Outpost Quest (rush) ---
Outpost_Quest :: struct {
    pos:             rl.Vector2,
    radius:          f32,
    is_active:       bool,
    completed:       bool,
    winner_name:     string,
    status_text:     string,
    status_color:    rl.Color,
    terminal_pos:    rl.Vector2,
    terminal_prog:   f32,
    keycard_pos:     rl.Vector2,
    keycard_found:   bool,
    drones_defeated: int,
    scope:           coroutine.Fiber_Scope,
}

// --- Zone 3: Void Sentinel (Phase_Director) ---
Void_Sentinel :: struct {
    pos:          rl.Vector2,
    radius:       f32,
    hp:           f32,
    max_hp:       f32,
    shield_alpha: f32,
    director:     coroutine.Phase_Director,
    color:        rl.Color,
    alive:        bool,
}

// --- Zone 4: Simulation Benchmark Results ---
Sim_Benchmark :: struct {
    has_run:        bool,
    sim_time_sec:   f64,
    wall_time_ms:   f64,
    steps_executed: int,
    test_result:    string,
}

World :: struct {
    sched:                   coroutine.Scheduler,
    player:                  Player,
    knight:                  Knight_AI,
    quest:                   Outpost_Quest,
    sentinel:                Void_Sentinel,
    benchmark:               Sim_Benchmark,
    global_time:             f32,
    show_coroutine_debugger: bool,
    step_count:              int,
    step_flash_timer:        f32,
    last_step_dt:            f32,
    hold_step_timer:         f32,
    latched_quest:           bool,
    latched_phase:           bool,
    latched_bench:           bool,
    latched_interact:        bool,
}

g_world: ^World

// ============================================================================
// Zone 1: AI Behavior Tree with Priority Fallbacks (fallback)
// ============================================================================

knight_decision_fiber :: proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
    for {
        // Evaluate priority decision tree via fallback
        succeeded, winning_idx := coroutine.fallback(f,
            // 1. Priority A: Melee Slam (Fails if player > 70px)
            coroutine.branch(proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
                dist := linalg.length(g_world.player.pos - k.pos)
                if dist > 70.0 {
                    coroutine.fail(f) // Too far!
                }
                k.current_action = "Melee Heavy Slam! (Priority A)"
                k.action_color = rl.RED
                coroutine.wait(f, 0.6)
            }, k, "1. Melee Slam Check"),

            // 2. Priority B: Tactical Shield Bash (Fails if player > 180px or stamina < 30)
            coroutine.branch(proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
                dist := linalg.length(g_world.player.pos - k.pos)
                if dist > 180.0 || k.stamina < 30.0 {
                    coroutine.fail(f) // Out of range or low stamina!
                }
                k.current_action = "Shield Bash Dash! (Priority B)"
                k.action_color = rl.ORANGE
                k.stamina -= 30.0
                target_pos := g_world.player.pos
                coroutine.tween(f, &k.pos, k.pos, target_pos, 0.4, coroutine.ease_out_quad)
                coroutine.wait(f, 0.5)
            }, k, "2. Shield Bash Check"),

            // 3. Priority C: Guaranteed Fallback (Patrol & Recover Stamina)
            coroutine.branch(proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
                k.current_action = "Tactical Patrol & Rest (Fallback C)"
                k.action_color = rl.SKYBLUE
                k.stamina = min(100.0, k.stamina + 20.0)
                // Move towards home position
                coroutine.tween(f, &k.pos, k.pos, k.home_pos, 0.8, coroutine.ease_in_out_quad)
                coroutine.wait(f, 0.4)
            }, k, "3. Patrol Fallback"),
        )

        coroutine.wait(f, 0.2)
    }
}

// ============================================================================
// Zone 2: Competitive Quest Objectives (rush)
// ============================================================================

outpost_quest_fiber :: proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
    q.is_active = true
    q.completed = false
    q.terminal_prog = 0.0
    q.drones_defeated = 0
    q.keycard_found = false
    q.status_text = "Quest Running: 3 Parallel Objectives (rush)..."
    q.status_color = rl.YELLOW

    // Run 3 objectives in parallel; first to SUCCEED wins and aborts the others!
    winner := coroutine.rush(f,
        // Option 0: Hack Security Terminal (Hold near terminal)
        coroutine.branch(proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
            for q.terminal_prog < 1.0 {
                coroutine.yield_frame(f)
                dist := linalg.length(g_world.player.pos - q.terminal_pos)
                if dist < 45.0 {
                    q.terminal_prog += coroutine.delta_time(f) * 0.5
                }
            }
            // Succeeded!
        }, q, "Objective 0: Hack Terminal"),

        // Option 1: Eliminate 2 Sentry Drones (Simulated combat timeout)
        coroutine.branch(proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
            coroutine.wait(f, 3.2) // Takes 3.2 seconds
            q.drones_defeated = 2
        }, q, "Objective 1: Destroy Sentries"),

        // Option 2: Collect Hidden Keycard (Touch keycard position)
        coroutine.branch(proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
            for !q.keycard_found {
                coroutine.yield_frame(f)
                dist := linalg.length(g_world.player.pos - q.keycard_pos)
                if dist < 35.0 {
                    q.keycard_found = true
                }
            }
        }, q, "Objective 2: Retrieve Keycard"),
    )

    q.is_active = false
    q.completed = true
    names := [?]string{"Terminal Hacked!", "Sentries Destroyed!", "Keycard Retrieved!"}
    if winner >= 0 && winner < 3 {
        q.winner_name = names[winner]
        q.status_text = fmt.tprintf("SUCCESS: %s (rush won by Option %d)", q.winner_name, winner)
        q.status_color = rl.GREEN
    } else {
        q.status_text = "QUEST FAILED"
        q.status_color = rl.RED
    }
}

// ============================================================================
// Zone 3: Void Sentinel State Machine (Phase_Director)
// ============================================================================

sentinel_phase1_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    s.color = rl.GOLD
    center := s.pos
    for {
        coroutine.tween(f, &s.pos, center, center + {60, 0}, 0.8, coroutine.ease_in_out_quad)
        coroutine.tween(f, &s.pos, center + {60, 0}, center - {60, 0}, 1.6, coroutine.ease_in_out_quad)
        coroutine.tween(f, &s.pos, center - {60, 0}, center, 0.8, coroutine.ease_in_out_quad)
    }
}

sentinel_phase2_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    s.color = rl.SKYBLUE
    for {
        coroutine.tween(f, &s.shield_alpha, 0.2, 0.9, 0.5, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.4)
        coroutine.tween(f, &s.shield_alpha, 0.9, 0.2, 0.5, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.4)
    }
}

sentinel_phase3_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    s.color = rl.RED
    for {
        target := g_world.player.pos
        coroutine.tween(f, &s.pos, s.pos, target, 0.35, coroutine.ease_in_quad)
        coroutine.wait(f, 0.3)
    }
}

// ============================================================================
// Zone 4: Headless Simulation Benchmark (simulate_until)
// ============================================================================

run_simulation_benchmark :: proc(w: ^World) {
    sim_sched: coroutine.Scheduler
    coroutine.scheduler_init(&sim_sched)
    defer coroutine.scheduler_destroy(&sim_sched)

    counter := 0
    start_sw := time.now()

    // Spawn 10 parallel virtual fibers
    for i in 0 ..< 10 {
        coroutine.spawn(&sim_sched, proc(f: ^coroutine.Fiber, c: ^int) {
            for _ in 0 ..< 600 {
                coroutine.wait(f, 0.1) // 60 simulated seconds total
                c^ += 1
            }
        }, &counter)
    }

    // Step scheduler headless until 6,000 steps completed
    ok, sim_time := coroutine.simulate_until(&sim_sched, 0.016, 70.0, proc(c: ^int) -> bool {
        return c^ >= 6000
    }, &counter)

    elapsed_wall := time.duration_seconds(time.since(start_sw)) * 1000.0

    w.benchmark.has_run = true
    w.benchmark.sim_time_sec = sim_time
    w.benchmark.wall_time_ms = elapsed_wall
    w.benchmark.steps_executed = counter
    w.benchmark.test_result = ok ? "PASS (6,000 events simulated)" : "TIMEOUT"
}

// ============================================================================
// World Lifecycle
// ============================================================================

world_init :: proc(w: ^World) {
    coroutine.scheduler_init(&w.sched)

    w.player = Player{
        pos    = {SCREEN_WIDTH / 2.0, SCREEN_HEIGHT / 2.0 + 80.0},
        speed  = 300.0,
        radius = 16.0,
    }

    w.knight = Knight_AI{
        pos            = {240, 260},
        home_pos       = {240, 260},
        radius         = 24.0,
        stamina        = 100.0,
        current_action = "Idle",
        action_color   = rl.GRAY,
    }

    w.quest = Outpost_Quest{
        pos          = {640, 240},
        radius       = 120.0,
        terminal_pos = {580, 240},
        keycard_pos  = {700, 240},
        status_text  = "Press [2] or walk here to start Rush Quest",
        status_color = rl.RAYWHITE,
    }

    w.sentinel = Void_Sentinel{
        pos          = {1020, 260},
        radius       = 32.0,
        hp           = 1000.0,
        max_hp       = 1000.0,
        shield_alpha = 0.0,
        color        = rl.GOLD,
        alive        = true,
    }

    w.global_time = 0.0
    w.show_coroutine_debugger = true
    g_world = w

    // Initialize Phase_Director for Sentinel
    coroutine.phase_director_init(&w.sentinel.director, &w.sched)
    coroutine.phase_switch(&w.sentinel.director, 1, sentinel_phase1_fiber, &w.sentinel, name = "Phase 1: Laser Patrol")

    // Start Knight AI decision loop
    coroutine.spawn(&w.sched, knight_decision_fiber, &w.knight, scope = &w.knight.scope, name = "Knight AI (fallback)")
}

world_destroy :: proc(w: ^World) {
    coroutine.phase_director_destroy(&w.sentinel.director)
    coroutine.scope_destroy(&w.sched, &w.knight.scope)
    coroutine.scope_destroy(&w.sched, &w.quest.scope)
    coroutine.scope_destroy(&w.sched, &w.player.scope)
    coroutine.scheduler_destroy(&w.sched)
}

world_update :: proc(w: ^World, dt: f32) {
    if rl.IsKeyPressed(.F3) {
        w.sched.is_paused = !w.sched.is_paused
    }

    if rl.IsKeyPressed(.F1) || rl.IsKeyPressed(.TAB) {
        w.show_coroutine_debugger = !w.show_coroutine_debugger
    }

    // Determine simulation delta-time for this frame
    sim_dt: f32 = 0.0

    if !w.sched.is_paused {
        sim_dt = dt
        w.step_flash_timer = 0.0
    } else {
        if w.step_flash_timer > 0.0 {
            w.step_flash_timer = max(0.0, w.step_flash_timer - dt)
        }

        if rl.IsKeyPressed(.F4) {
            sim_dt = 0.016
            w.step_count += 1
            w.last_step_dt = sim_dt
            w.step_flash_timer = 0.4
        } else if rl.IsKeyPressed(.F5) || (rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyPressed(.F4)) {
            sim_dt = 0.160 // 10 frames (~160ms jump)
            w.step_count += 10
            w.last_step_dt = sim_dt
            w.step_flash_timer = 0.5
        } else if rl.IsKeyDown(.F4) {
            // Slow-motion continuous step when holding F4 (~15 FPS slow-mo)
            w.hold_step_timer += dt
            if w.hold_step_timer >= 0.066 {
                w.hold_step_timer = 0.0
                sim_dt = 0.016
                w.step_count += 1
                w.last_step_dt = sim_dt
                w.step_flash_timer = 0.2
            }
        } else {
            w.hold_step_timer = 0.0
        }
    }

    // Latch triggers while running or paused
    if rl.IsKeyPressed(.TWO)   do w.latched_quest = true
    if rl.IsKeyPressed(.THREE) do w.latched_phase = true
    if rl.IsKeyPressed(.T)     do w.latched_bench = true
    if rl.IsKeyPressed(.E)     do w.latched_interact = true

    // If simulation is completely paused with no step this frame, halt world updates
    if sim_dt <= 0.0 do return

    w.global_time += sim_dt

    // Step coroutine engine
    coroutine.scheduler_single_step(&w.sched, sim_dt)

    // --- Player Movement ---
    move_dir: rl.Vector2
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    do move_dir.y -= 1
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  do move_dir.y += 1
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  do move_dir.x -= 1
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move_dir.x += 1

    if linalg.length(move_dir) > 0 {
        move_dir = linalg.normalize(move_dir)
        w.player.pos += move_dir * w.player.speed * sim_dt
    }

    // Process latched triggers
    do_quest := w.latched_quest || rl.IsKeyPressed(.TWO)
    do_phase := w.latched_phase || rl.IsKeyPressed(.THREE)
    do_bench := w.latched_bench || rl.IsKeyPressed(.T)
    interact := w.latched_interact || rl.IsKeyPressed(.E)
    w.latched_quest = false
    w.latched_phase = false
    w.latched_bench = false
    w.latched_interact = false

    // --- Zone 2 Trigger (Rush Quest) ---
    dist_quest := linalg.length(w.player.pos - w.quest.pos)
    if ((dist_quest < w.quest.radius && interact) || do_quest) && !coroutine.scope_is_busy(&w.quest.scope) {
        coroutine.spawn(&w.sched, outpost_quest_fiber, &w.quest, scope = &w.quest.scope, name = "Outpost Quest (rush)")
    }

    // --- Zone 3 Trigger (Sentinel Phase Switch: 1 -> 2 -> 3) ---
    if do_phase {
        cur := coroutine.phase_current(&w.sentinel.director)
        next_phase := (cur % 3) + 1
        switch next_phase {
        case 1:
            coroutine.phase_switch(&w.sentinel.director, 1, sentinel_phase1_fiber, &w.sentinel, name = "Phase 1: Laser Patrol")
        case 2:
            coroutine.phase_switch(&w.sentinel.director, 2, sentinel_phase2_fiber, &w.sentinel, name = "Phase 2: Super Nova")
        case 3:
            coroutine.phase_switch(&w.sentinel.director, 3, sentinel_phase3_fiber, &w.sentinel, name = "Phase 3: Berserk Rush")
        }
    }

    // --- Zone 4 Trigger (Run Headless Benchmark) ---
    if do_bench {
        run_simulation_benchmark(w)
    }
}

world_render :: proc(w: ^World) {
    rl.BeginDrawing()
    rl.ClearBackground({16, 18, 28, 255})

    // Header Title
    rl.DrawText("ADVANCED CONTROL FLOW & QUEST AI SHOWCASE", 30, 20, 24, rl.RAYWHITE)
    rl.DrawText("Features: fallback (Decision Trees) | rush (Parallel Success) | Phase_Director | simulate_until", 30, 48, 15, rl.SKYBLUE)

    // --- Zone 1: Knight AI (fallback) ---
    rl.DrawRectangleLines(30, 100, 360, 280, {60, 80, 120, 255})
    rl.DrawText("ZONE 1: AI Behavior (fallback)", 45, 115, 16, rl.GOLD)
    rl.DrawText("Priority: Melee (<70px) -> Bash (<180px) -> Patrol", 45, 138, 12, rl.GRAY)

    rl.DrawCircleV(w.knight.pos, w.knight.radius, w.knight.action_color)
    rl.DrawCircleLines(i32(w.knight.pos.x), i32(w.knight.pos.y), 70.0, {255, 0, 0, 80})
    rl.DrawCircleLines(i32(w.knight.pos.x), i32(w.knight.pos.y), 180.0, {255, 165, 0, 60})

    rl.DrawText(fmt.ctprintf("Action: %s", w.knight.current_action), 45, 330, 13, w.knight.action_color)
    rl.DrawText(fmt.ctprintf("Stamina: %.0f/100", w.knight.stamina), 45, 350, 13, rl.RAYWHITE)

    // --- Zone 2: Outpost Quest (rush) ---
    rl.DrawRectangleLines(420, 100, 440, 280, {60, 80, 120, 255})
    rl.DrawText("ZONE 2: Quest Objectives (rush)", 435, 115, 16, rl.GOLD)
    rl.DrawText("Rush: Hack Terminal || Kill Sentries || Keycard", 435, 138, 12, rl.GRAY)

    // Terminal
    rl.DrawRectangleV(w.quest.terminal_pos - {16, 16}, {32, 32}, rl.DARKBLUE)
    rl.DrawText("Terminal", i32(w.quest.terminal_pos.x) - 24, i32(w.quest.terminal_pos.y) - 30, 11, rl.SKYBLUE)
    if w.quest.is_active {
        rl.DrawRectangle(i32(w.quest.terminal_pos.x) - 20, i32(w.quest.terminal_pos.y) + 20, 40, 6, rl.DARKGRAY)
        rl.DrawRectangle(i32(w.quest.terminal_pos.x) - 20, i32(w.quest.terminal_pos.y) + 20, i32(40.0 * w.quest.terminal_prog), 6, rl.GREEN)
    }

    // Keycard
    rl.DrawCircleV(w.quest.keycard_pos, 12.0, w.quest.keycard_found ? rl.DARKGREEN : rl.GOLD)
    rl.DrawText("Keycard", i32(w.quest.keycard_pos.x) - 20, i32(w.quest.keycard_pos.y) - 26, 11, rl.YELLOW)

    rl.DrawText(fmt.ctprintf("Status: %s", w.quest.status_text), 435, 345, 13, w.quest.status_color)

    // --- Zone 3: Void Sentinel (Phase_Director) ---
    rl.DrawRectangleLines(890, 100, 360, 280, {60, 80, 120, 255})
    rl.DrawText("ZONE 3: Void Sentinel (Phase_Director)", 905, 115, 16, rl.GOLD)
    rl.DrawText("Press [3] to switch Phase (1 -> 2 -> 3)", 905, 138, 12, rl.GRAY)

    rl.DrawCircleV(w.sentinel.pos, w.sentinel.radius, w.sentinel.color)
    if w.sentinel.shield_alpha > 0.05 {
        rl.DrawCircleLines(i32(w.sentinel.pos.x), i32(w.sentinel.pos.y), w.sentinel.radius + 8.0, rl.Fade(rl.SKYBLUE, w.sentinel.shield_alpha))
    }

    cur_phase := coroutine.phase_current(&w.sentinel.director)
    p_name := coroutine.phase_name(&w.sentinel.director)
    rl.DrawText(fmt.ctprintf("Current Phase: %d (%s)", cur_phase, p_name), 905, 345, 13, rl.GREEN)

    // --- Zone 4: Simulation Benchmark (Bottom Left) ---
    rl.DrawRectangleLines(30, 400, 500, 280, {60, 80, 120, 255})
    rl.DrawText("ZONE 4: Headless CI/CD Runner (simulate_until)", 45, 415, 16, rl.GOLD)
    rl.DrawText("Press [T] to simulate 60s of 10 virtual fibers in <5ms", 45, 438, 12, rl.GRAY)

    if w.benchmark.has_run {
        rl.DrawText(fmt.ctprintf("Result: %s", w.benchmark.test_result), 45, 480, 15, rl.GREEN)
        rl.DrawText(fmt.ctprintf("Simulated Virtual Time: %.2f seconds", w.benchmark.sim_time_sec), 45, 510, 14, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("Real Wall-Clock Time:   %.2f ms", w.benchmark.wall_time_ms), 45, 535, 14, rl.YELLOW)
        rl.DrawText(fmt.ctprintf("Events Stepped:         %d events", w.benchmark.steps_executed), 45, 560, 14, rl.SKYBLUE)
        speedup := (w.benchmark.sim_time_sec * 1000.0) / max(0.001, w.benchmark.wall_time_ms)
        rl.DrawText(fmt.ctprintf("Speedup vs Real-Time:   %.0fx FASTER", speedup), 45, 595, 16, rl.LIME)
    } else {
        rl.DrawText("Ready to run. Press [T] to execute benchmark.", 45, 500, 14, rl.DARKGRAY)
    }

    // --- Player ---
    rl.DrawCircleV(w.player.pos, w.player.radius, rl.LIME)
    rl.DrawCircleLines(i32(w.player.pos.x), i32(w.player.pos.y), w.player.radius + 2, rl.WHITE)

    // Bottom HUD Instructions & Pause Banner
    if w.sched.is_paused {
        flash_col := w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD
        step_text := fmt.ctprintf("PAUSED: Step #%d (+%.3fs) | Sim Time: %.3fs | F4: 1-Frame | F5: 10-Frames | Hold F4: Slow-Mo", w.step_count, w.last_step_dt, w.global_time)
        rl.DrawRectangle(25, SCREEN_HEIGHT - 32, 850, 24, {15, 18, 30, 220})
        rl.DrawRectangleLines(25, SCREEN_HEIGHT - 32, 850, 24, flash_col)
        rl.DrawText(step_text, 35, SCREEN_HEIGHT - 28, 14, flash_col)
    } else {
        rl.DrawText("WASD: Move | [2]: Rush Quest | [3]: Phase | [T]: Bench | F1: Tree | F3: Pause | F4: Step 1F | F5: Step 10F", 30, SCREEN_HEIGHT - 22, 13, rl.LIGHTGRAY)
    }

    // --- Coroutine Hierarchy Visualizer Overlay (F1 / TAB) ---
    if w.show_coroutine_debugger {
        panel_x: i32 = 550
        panel_y: i32 = 400
        panel_w: i32 = 700
        panel_h: i32 = 280

        rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 14, 22, 240})
        rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {0, 200, 255, 200})

        pause_header := ""
        if w.sched.is_paused {
            pause_header = fmt.tprintf("[PAUSED #%d (Sim: %.2fs) | F4: 1F, F5: 10F]", w.step_count, w.global_time)
        }
        rl.DrawText(fmt.ctprintf("COROUTINE HIERARCHY TREE (F1) %s", pause_header), panel_x + 15, panel_y + 10, 14, w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD)
        rl.DrawLine(panel_x + 10, panel_y + 28, panel_x + panel_w - 10, panel_y + 28, {60, 80, 120, 255})

        tree_y := panel_y + 35

        draw_fiber_node :: proc(f: ^coroutine.Fiber, depth: int, cur_y: ^i32, max_y: i32) {
            if f == nil || cur_y^ > max_y do return

            indent := i32(depth * 16)
            name := f.debug_name != "" ? f.debug_name : "Fiber"

            status_str := ""
            status_col := rl.RAYWHITE
            #partial switch f.status {
            case .Running:
                status_str = "Running"
                status_col = rl.GREEN
            case .Ready:
                status_str = "Ready"
                status_col = rl.YELLOW
            case .Sleeping_Time:
                left := max(0.0, f.wake_time - f.sched.current_time)
                status_str = fmt.tprintf("Sleeping_Time (%.2fs)", left)
                status_col = rl.SKYBLUE
            case .Sleeping_Frames:
                left := f.wake_frame > f.sched.current_frame ? f.wake_frame - f.sched.current_frame : 0
                status_str = fmt.tprintf("Sleeping_Frames (%d)", left)
                status_col = rl.SKYBLUE
            case .Waiting_Condition:
                status_str = "Waiting_Condition"
                status_col = rl.ORANGE
            case .Suspended_Join:
                kind := "Sync"
                switch f.active_coord.kind {
                case .Sync:     kind = "Sync"
                case .Race:     kind = "Race"
                case .Rush:     kind = "Rush"
                case .Fallback: kind = "Fallback"
                }
                status_str = fmt.tprintf("Suspended_Join (%s, %d active)", kind, f.active_coord.active_branches)
                status_col = rl.PURPLE
            case:
                status_str = fmt.tprintf("%v", f.status)
                status_col = rl.GRAY
            }

            used, total := coroutine.fiber_calc_stack_usage(f)
            pct := f32(used) / f32(total) * 100.0

            prefix := depth > 0 ? "├─ " : "▼ "
            row_text := fmt.tprintf("%s[#%d] %s: %s | Stack: %.1fKB (%.1f%%)", prefix, f.handle, name, status_str, f32(used)/1024.0, pct)
            rl.DrawText(fmt.ctprintf("%s", row_text), 565 + indent, cur_y^, 11, status_col)
            cur_y^ += 16

            child := f.first_child
            for child != nil {
                draw_fiber_node(child, depth + 1, cur_y, max_y)
                child = child.next_sibling
            }
        }

        for f in w.sched.fiber_pool.all_fibers {
            if f.status != .Unused && f.parent == nil {
                draw_fiber_node(f, 0, &tree_y, panel_y + panel_h - 18)
            }
        }
    }

    rl.EndDrawing()
}

// ============================================================================
// Main Application Entry
// ============================================================================

main :: proc() {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)
    defer {
        for _, leak in track.allocation_map {
            fmt.printf("%v leaked %v bytes\n", leak.location, leak.size)
        }
        mem.tracking_allocator_clear(&track)
    }

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Advanced Concurrency & Quest AI Showcase")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    world: World
    world_init(&world)
    defer world_destroy(&world)

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        world_update(&world, dt)
        world_render(&world)
    }
}
