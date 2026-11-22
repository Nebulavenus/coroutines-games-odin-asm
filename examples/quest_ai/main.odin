package main

import "core:fmt"
import "core:math/linalg"
import "core:mem"
import "core:time"
import rl "vendor:raylib"

import coroutine "../.."
import sync "../../sync"

// ============================================================================
// Constants & Configuration
// ============================================================================

SCREEN_WIDTH       :: 1280
SCREEN_HEIGHT      :: 720
FIXED_TEXT_MAX_LEN :: 96

Fixed_Text :: struct {
    buf: [FIXED_TEXT_MAX_LEN]u8,
    len: u8,
}

fixed_text_make :: proc(s: string) -> Fixed_Text {
    res: Fixed_Text
    n := min(len(s), FIXED_TEXT_MAX_LEN)
    if n > 0 {
        copy(res.buf[:n], s[:n])
    }
    res.len = u8(n)
    return res
}

fixed_text_str :: proc(t: ^Fixed_Text) -> string {
    return string(t.buf[:t.len])
}

// ============================================================================
// Entity & World Data Structures
// ============================================================================

Player :: struct {
    pos:    rl.Vector2,
    speed:  f32,
    radius: f32,
    scope:  coroutine.Fiber_Scope,
}

// --- Zone 1: Knight AI (fallback & semaphore) ---
Knight_AI :: struct {
    pos:            rl.Vector2,
    home_pos:       rl.Vector2,
    radius:         f32,
    stamina:        f32,
    current_action: Fixed_Text,
    action_color:   rl.Color,
    scope:          coroutine.Fiber_Scope,
}

// --- Zone 2: Outpost Quest (rush & Event(T)) ---
Quest_Milestone :: struct {
    text:  Fixed_Text,
    color: rl.Color,
}

Outpost_Quest :: struct {
    pos:             rl.Vector2,
    radius:          f32,
    is_active:       bool,
    completed:       bool,
    winner_name:     string,
    status_text:     Fixed_Text,
    status_color:    rl.Color,
    terminal_pos:    rl.Vector2,
    terminal_prog:   f32,
    keycard_pos:     rl.Vector2,
    keycard_found:   bool,
    drones_defeated: int,
    scope:           coroutine.Fiber_Scope,
}

// --- Zone 3: Void Sentinel (Fiber_Scope Phase Switching & fiber_join) ---
Void_Sentinel :: struct {
    pos:          rl.Vector2,
    home_pos:     rl.Vector2,
    radius:       f32,
    hp:           f32,
    max_hp:       f32,
    shield_alpha: f32,
    phase_scope:  coroutine.Fiber_Scope,
    phase:        int,
    phase_name:   string,
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
    combat_sem:              sync.Fiber_Semaphore,
    quest_event:             coroutine.Event(Quest_Milestone),
    player:                  Player,
    knight:                  Knight_AI,
    quest:                   Outpost_Quest,
    sentinel:                Void_Sentinel,
    benchmark:               Sim_Benchmark,
    global_time:             f32,
    is_paused:               bool,
    show_coroutine_debugger: bool,
    step_count:              int,
    step_flash_timer:        f32,
    last_step_dt:            f32,
    hold_step_timer:         f32,
    last_milestone:          Fixed_Text,
    milestone_timer:         f32,
    minion_active:           bool,
    minion_pos:              rl.Vector2,
    latched_quest:           bool,
    latched_phase:           bool,
    latched_bench:           bool,
    latched_interact:        bool,
    latched_stun:            bool,
}

g_world: ^World

ease_in_quad :: proc(t: f32) -> f32 { return t * t }
ease_out_quad :: proc(t: f32) -> f32 { return 1.0 - (1.0 - t) * (1.0 - t) }
ease_in_out_quad :: proc(t: f32) -> f32 {
    return t < 0.5 ? 2.0 * t * t : 1.0 - (-2.0 * t + 2.0) * (-2.0 * t + 2.0) / 2.0
}

tween_f32 :: proc(f: ^coroutine.Fiber, target: ^f32, from, to, duration: f32, ease: proc(f32) -> f32 = nil) {
    if duration <= 0 { target^ = to; return }
    elapsed: f32 = 0
    for elapsed < duration {
        coroutine.yield(f)
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / duration, 0.0, 1.0)
        target^ = from + (to - from) * (ease != nil ? ease(t) : t)
    }
    target^ = to
}

tween_vec2 :: proc(f: ^coroutine.Fiber, target: ^[2]f32, from, to: [2]f32, duration: f32, ease: proc(f32) -> f32 = nil) {
    if duration <= 0 { target^ = to; return }
    elapsed: f32 = 0
    for elapsed < duration {
        coroutine.yield(f)
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / duration, 0.0, 1.0)
        et := ease != nil ? ease(t) : t
        target^ = from + (to - from) * et
    }
    target^ = to
}

sentinel_switch_phase :: proc(sched: ^coroutine.Scheduler, s: ^Void_Sentinel, phase: int, entry: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel), name: string) {
    coroutine.scope_cancel(sched, &s.phase_scope)
    s.phase = phase
    s.phase_name = name
    coroutine.spawn(sched, entry, s, scope = &s.phase_scope, name = name)
}

// ============================================================================
// Zone 1: AI Behavior Tree with Priority Fallbacks & Semaphore
// ============================================================================

knight_action_whirlwind :: proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
    dist := linalg.length(g_world.player.pos - k.pos)
    if dist > 85.0 || k.stamina < 60.0 || sync.semaphore_available_permits(&g_world.combat_sem) <= 0 {
        coroutine.fail(f)
    }
    sync.with_semaphore(f, &g_world.combat_sem, proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
        coroutine.fiber_set_name(f, "Knight AI: Whirlwind Attack (A)")
        k.current_action = fixed_text_make("Whirlwind Attack! (Priority A)")
        k.action_color = rl.RED
        k.stamina -= 50.0
        coroutine.wait(f, 0.6)
    }, k)
}

knight_action_shield_bash :: proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
    dist := linalg.length(g_world.player.pos - k.pos)
    if dist > 180.0 || k.stamina < 30.0 {
        coroutine.fail(f)
    }
    coroutine.fiber_set_name(f, "Knight AI: Shield Bash (B)")
    k.current_action = fixed_text_make("Shield Bash Dash! (Priority B)")
    k.action_color = rl.ORANGE
    k.stamina -= 30.0
    target_pos := g_world.player.pos
    tween_vec2(f, &k.pos, k.pos, target_pos, 0.4, ease_out_quad)
    coroutine.wait(f, 0.5)
}

knight_action_patrol_rest :: proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
    coroutine.fiber_set_name(f, "Knight AI: Tactical Patrol & Rest (C)")
    k.current_action = fixed_text_make("Tactical Patrol & Rest (Fallback C)")
    k.action_color = rl.SKYBLUE
    k.stamina = min(100.0, k.stamina + 20.0)
    tween_vec2(f, &k.pos, k.pos, k.home_pos, 0.8, ease_in_out_quad)
    coroutine.wait(f, 0.4)
}

knight_ai_fiber :: proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
    k.pos = k.home_pos
    k.stamina = 100.0

    for {
        coroutine.ticker_wait(f, 0.2)

        coroutine.fallback_with(f, k,
            knight_action_whirlwind,
            knight_action_shield_bash,
            knight_action_patrol_rest,
        )
    }
}

// ============================================================================
// Zone 2: Competitive Quest Objectives (rush & Event(T) Multicast)
// ============================================================================

quest_obj_hack_terminal :: proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
    for q.terminal_prog < 1.0 {
        coroutine.yield(f)
        dist := linalg.length(g_world.player.pos - q.terminal_pos)
        if dist < 45.0 {
            q.terminal_prog += coroutine.delta_time(f) * 0.5
        }
    }
}

quest_obj_destroy_sentries :: proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
    coroutine.wait(f, 1.8)
    q.drones_defeated = 1
    coroutine.wait(f, 1.8)
    q.drones_defeated = 2
}

quest_obj_retrieve_keycard :: proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
    for !q.keycard_found {
        coroutine.yield(f)
        dist := linalg.length(g_world.player.pos - q.keycard_pos)
        if dist < 35.0 {
            q.keycard_found = true
        }
    }
}

outpost_quest_fiber :: proc(f: ^coroutine.Fiber, q: ^Outpost_Quest) {
    q.is_active = true
    q.completed = false
    q.terminal_prog = 0.0
    q.drones_defeated = 0
    q.keycard_found = false
    q.status_text = fixed_text_make("Quest Running: 3 Parallel Objectives (rush)...")
    q.status_color = rl.YELLOW
    coroutine.fiber_set_name(f, "Quest Director (Active rush)")

    coroutine.fiber_defer(f, proc(q: ^Outpost_Quest) {
        q.is_active = false
    }, q)

    coroutine.event_emit(f, &g_world.quest_event, Quest_Milestone{fixed_text_make("Outpost Quest Started: Hack, Slay, or Retrieve!"), rl.YELLOW})

    winner := coroutine.rush_with(f, q,
        quest_obj_hack_terminal,
        quest_obj_destroy_sentries,
        quest_obj_retrieve_keycard,
    )

    names := [?]string{"Terminal Hacked", "Sentries Cleared", "Keycard Found"}
    if winner >= 0 && winner < 3 {
        q.winner_name = names[winner]
        q.status_text = fixed_text_make(fmt.tprintf("PRIMARY: %s (bonus window...)", q.winner_name))
        q.status_color = rl.GREEN
        coroutine.fiber_set_name(f, "Quest Director (bonus window)")
        coroutine.event_emit(f, &g_world.quest_event, Quest_Milestone{fixed_text_make(fmt.tprintf("Primary met: %s", q.winner_name)), rl.GREEN})

        coroutine.wait(f, 4.0)

        q.status_text = fixed_text_make(fmt.tprintf("DONE: %s", q.winner_name))
        coroutine.fiber_set_name(f, "Quest Director: Completed")
    } else {
        q.status_text = fixed_text_make("QUEST FAILED")
        q.status_color = rl.RED
        coroutine.fiber_set_name(f, "Quest Director: Failed")
    }

    coroutine.fiber_defer_run_top(f)
    q.completed = true
}

// ============================================================================
// Zone 3: Void Sentinel State Machine (Fiber_Scope & fiber_join)
// ============================================================================

sentinel_phase1_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    coroutine.fiber_set_name(f, "Sentinel: Phase 1 (Patrol)")
    s.color = rl.GOLD
    center := s.home_pos
    tween_vec2(f, &s.pos, s.pos, center, 0.4, ease_in_out_quad)
    for {
        tween_vec2(f, &s.pos, center, center + {60, 0}, 0.8, ease_in_out_quad)
        tween_vec2(f, &s.pos, center + {60, 0}, center - {60, 0}, 1.6, ease_in_out_quad)
        tween_vec2(f, &s.pos, center - {60, 0}, center, 0.8, ease_in_out_quad)
    }
}

sentinel_phase2_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    coroutine.fiber_set_name(f, "Sentinel: Phase 2 (Shield & Minion)")
    s.color = rl.SKYBLUE

    coroutine.fiber_defer(f, proc(s: ^Void_Sentinel) {
        s.shield_alpha = 0.0
        g_world.minion_active = false
    }, s)

    for {
        s.shield_alpha = 0.95
        g_world.minion_active = true
        g_world.minion_pos = s.pos + {0, 60}

        minion_handle := coroutine.branch_scoped(f, proc(child: ^coroutine.Fiber) {
            coroutine.fiber_set_name(child, "Crystal Minion: Active")
            coroutine.fiber_defer(child, proc() {
                g_world.minion_active = false
            })
            for i := 0; i < 4; i += 1 {
                coroutine.ticker_wait(child, 0.5)
                g_world.minion_pos.x += (i % 2 == 0 ? 30.0 : -30.0)
            }
            coroutine.fiber_defer_run_top(child)
        }, name = "Crystal Minion Task")

        coroutine.fiber_join(f, minion_handle)

        tween_f32(f, &s.shield_alpha, 0.95, 0.1, 0.4, ease_out_quad)
        coroutine.wait(f, 0.8)
    }
}

sentinel_phase3_fiber :: proc(f: ^coroutine.Fiber, s: ^Void_Sentinel) {
    coroutine.fiber_set_name(f, "Sentinel: Phase 3 (Enraged Stalk)")
    s.color = rl.RED
    for {
        target := g_world.player.pos
        tween_vec2(f, &s.pos, s.pos, target, 0.35, ease_in_quad)
        coroutine.wait(f, 0.3)
    }
}

// ============================================================================
// Zone 4: Headless Simulation Runner (Headless Virtual Stepping)
// ============================================================================

run_simulation_benchmark :: proc(w: ^World) {
    bench_sched: coroutine.Scheduler
    coroutine.scheduler_init(&bench_sched)
    defer coroutine.scheduler_destroy(&bench_sched)

    counter := 0

    for _ in 0 ..< 10 {
        coroutine.spawn(&bench_sched, proc(f: ^coroutine.Fiber, c: ^int) {
            for _ in 0 ..< 600 {
                coroutine.wait(f, 0.1)
                c^ += 1
            }
        }, &counter)
    }

    t0 := time.now()

    coroutine.scheduler_run(&bench_sched)
    for counter < 6000 && coroutine.scheduler_time(&bench_sched) < 70.0 {
        next_dt, has_next := coroutine.scheduler_next_wake_time(&bench_sched)
        if !has_next do break
        coroutine.scheduler_step(&bench_sched, max(f32(next_dt), f32(0.0001)))
    }
    ok := counter >= 6000
    sim_time := coroutine.scheduler_time(&bench_sched)

    elapsed := time.since(t0)
    w.benchmark.has_run = true
    w.benchmark.sim_time_sec = sim_time
    w.benchmark.wall_time_ms = time.duration_milliseconds(elapsed)
    w.benchmark.steps_executed = counter
    w.benchmark.test_result = ok ? "SUCCESS (6,000 events simulated)" : "TIMEOUT"
}

// ============================================================================
// World Lifecycle
// ============================================================================

world_init :: proc(w: ^World) {
    if w.sched.fiber_pool.all_fibers != nil {
        world_destroy(w)
    }
    coroutine.scheduler_init(&w.sched)
    coroutine.scheduler_prewarm(&w.sched, 64)

    sync.semaphore_init(&w.combat_sem, initial_permits = 1, max_permits = 1)
    coroutine.event_init(&w.quest_event)

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
        current_action = fixed_text_make("Idle"),
        action_color   = rl.GRAY,
    }

    w.quest = Outpost_Quest{
        pos          = {640, 240},
        radius       = 120.0,
        terminal_pos = {580, 240},
        keycard_pos  = {700, 240},
        status_text  = fixed_text_make("Press [2] or walk here to start Rush Quest"),
        status_color = rl.RAYWHITE,
    }

    w.sentinel = Void_Sentinel{
        pos          = {1020, 260},
        home_pos     = {1020, 260},
        radius       = 32.0,
        hp           = 1000.0,
        max_hp       = 1000.0,
        shield_alpha = 0.0,
        color        = rl.GOLD,
        alive        = true,
    }

    w.global_time = 0.0
    w.is_paused = false
    w.show_coroutine_debugger = true
    g_world = w

    coroutine.spawn(&w.sched, proc(f: ^coroutine.Fiber) {
        for {
            m, ok := coroutine.event_wait(f, &g_world.quest_event)
            if ok {
                g_world.last_milestone = m.text
                g_world.milestone_timer = 3.5
            }
        }
    }, name = "Quest Event Listener")

    sentinel_switch_phase(&w.sched, &w.sentinel, 1, sentinel_phase1_fiber, "Phase 1: Laser Patrol")

    coroutine.spawn(&w.sched, knight_ai_fiber, &w.knight, scope = &w.knight.scope, name = "Knight AI (fallback)")
}

world_destroy :: proc(w: ^World) {
    coroutine.event_destroy(&w.quest_event)
    sync.semaphore_destroy(&w.combat_sem)
    coroutine.scope_destroy(&w.sched, &w.sentinel.phase_scope)
    coroutine.scope_destroy(&w.sched, &w.knight.scope)
    coroutine.scope_destroy(&w.sched, &w.quest.scope)
    coroutine.scope_destroy(&w.sched, &w.player.scope)
    coroutine.scheduler_destroy(&w.sched)
}

world_sim_step :: proc(w: ^World, sim_dt: f32, real_dt: f32) {
    w.global_time += sim_dt

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

    do_quest := w.latched_quest
    do_phase := w.latched_phase
    do_bench := w.latched_bench
    interact := w.latched_interact
    do_stun := w.latched_stun
    w.latched_quest = false
    w.latched_phase = false
    w.latched_bench = false
    w.latched_interact = false
    w.latched_stun = false

    // --- Zone 2 Trigger (Rush Quest) ---
    dist_quest := linalg.length(w.player.pos - w.quest.pos)
    if ((dist_quest < w.quest.radius && interact) || do_quest) && !coroutine.scope_is_busy(&w.quest.scope) {
        coroutine.spawn(&w.sched, outpost_quest_fiber, &w.quest, scope = &w.quest.scope, name = "Outpost Quest (rush)")
    }

    // --- Zone 3 Trigger (Sentinel Phase Switch: 1 -> 2 -> 3) ---
    if do_phase {
        next_phase := (w.sentinel.phase % 3) + 1
        switch next_phase {
        case 1:
            sentinel_switch_phase(&w.sched, &w.sentinel, 1, sentinel_phase1_fiber, "Phase 1: Laser Patrol")
        case 2:
            sentinel_switch_phase(&w.sched, &w.sentinel, 2, sentinel_phase2_fiber, "Phase 2: Minion Join")
        case 3:
            sentinel_switch_phase(&w.sched, &w.sentinel, 3, sentinel_phase3_fiber, "Phase 3: Berserk Rush")
        }
    }

    // --- Zone 4 Trigger (Run Headless Benchmark) ---
    if do_bench {
        run_simulation_benchmark(w)
    }

    // --- Scope Interrupt Trigger (Press [X]): Cancels Knight AI by Scope ---
    if do_stun {
        cancelled := coroutine.scope_cancel(&w.sched, &w.knight.scope)
        w.knight.current_action = fixed_text_make(fmt.tprintf("STUNNED via Scope Cancellation (Cancelled %d)", cancelled))
        w.knight.action_color = rl.GOLD
        coroutine.spawn(&w.sched, proc(f: ^coroutine.Fiber, k: ^Knight_AI) {
            coroutine.wait(f, 1.2)
            coroutine.spawn(f, knight_ai_fiber, k, &k.scope, name = "Knight AI (fallback)")
        }, &w.knight, scope = &w.knight.scope, name = "Knight Stun Recovery")
    }

    if real_dt > 0.0 {
        coroutine.clock_advance(&w.sched, coroutine.CLOCK_REAL, real_dt)
    }
    coroutine.scheduler_step(&w.sched, sim_dt)
}

world_update :: proc(w: ^World, dt: f32) {
    if rl.IsKeyPressed(.F3) {
        w.is_paused = !w.is_paused
    }

    if rl.IsKeyPressed(.F1) || rl.IsKeyPressed(.TAB) {
        w.show_coroutine_debugger = !w.show_coroutine_debugger
    }

    if w.milestone_timer > 0.0 {
        w.milestone_timer = max(0.0, w.milestone_timer - dt)
    }

    if rl.IsKeyPressed(.TWO)   do w.latched_quest = true
    if rl.IsKeyPressed(.THREE) do w.latched_phase = true
    if rl.IsKeyPressed(.T)     do w.latched_bench = true
    if rl.IsKeyPressed(.E)     do w.latched_interact = true
    if rl.IsKeyPressed(.X)     do w.latched_stun = true

    STEP_DT :: f32(1.0 / 60.0)
    steps_to_run := 0
    step_dt: f32 = 0.0

    if !w.is_paused {
        steps_to_run = 1
        step_dt = dt
        w.step_flash_timer = 0.0
    } else {
        if w.step_flash_timer > 0.0 {
            w.step_flash_timer = max(0.0, w.step_flash_timer - dt)
        }

        if rl.IsKeyPressed(.F5) || (rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyPressed(.F4)) {
            steps_to_run = 10
            step_dt = STEP_DT
            w.step_count += 10
            w.last_step_dt = STEP_DT * 10.0
            w.step_flash_timer = 0.5
        } else if rl.IsKeyPressed(.F4) {
            steps_to_run = 1
            step_dt = STEP_DT
            w.step_count += 1
            w.last_step_dt = STEP_DT
            w.step_flash_timer = 0.4
        } else if rl.IsKeyDown(.F4) {
            w.hold_step_timer += dt
            if w.hold_step_timer >= 0.066 {
                w.hold_step_timer = 0.0
                steps_to_run = 1
                step_dt = STEP_DT
                w.step_count += 1
                w.last_step_dt = STEP_DT
                w.step_flash_timer = 0.2
            }
        } else {
            w.hold_step_timer = 0.0
        }
    }

    if steps_to_run == 0 {
        coroutine.clock_set_paused(&w.sched, coroutine.CLOCK_SIM, true)
        coroutine.clock_advance(&w.sched, coroutine.CLOCK_REAL, dt)
        coroutine.scheduler_run(&w.sched)
        return
    }

    coroutine.clock_set_paused(&w.sched, coroutine.CLOCK_SIM, false)
    for i in 0 ..< steps_to_run {
        real_slice := i == 0 ? dt : f32(0.0)
        world_sim_step(w, step_dt, real_slice)
    }
    if w.is_paused {
        coroutine.clock_set_paused(&w.sched, coroutine.CLOCK_SIM, true)
    }
}

world_render :: proc(w: ^World) {
    rl.BeginDrawing()
    rl.ClearBackground({16, 18, 28, 255})

    rl.DrawText("ADVANCED CONTROL FLOW & QUEST AI SHOWCASE", 30, 16, 22, rl.RAYWHITE)

    stats := coroutine.scheduler_pool_stats(&w.sched)
    header_stats := fmt.ctprintf("Active: %d/%d | Slabs: %d | Mem: %d KB | Combat Sem: %d/1", stats.active_fibers, stats.total_stacks, stats.slabs_count, stats.total_memory_kb, sync.semaphore_available_permits(&w.combat_sem))
    rl.DrawText(header_stats, 30, 42, 12, rl.SKYBLUE)

    // --- Zone 1: Knight AI (fallback & semaphore) ---
    rl.DrawRectangleLines(30, 75, 360, 300, {60, 80, 120, 255})
    rl.DrawText("ZONE 1: Knight AI (fallback + Sem)", 45, 90, 14, rl.GOLD)
    rl.DrawText("Priority: Melee (<85px + Sem) -> Bash -> Patrol", 45, 110, 11, rl.GRAY)

    rl.DrawCircleV(w.knight.pos, w.knight.radius, w.knight.action_color)
    rl.DrawCircleLines(i32(w.knight.pos.x), i32(w.knight.pos.y), 85.0, {255, 0, 0, 80})
    rl.DrawCircleLines(i32(w.knight.pos.x), i32(w.knight.pos.y), 180.0, {255, 165, 0, 60})

    rl.DrawText(fmt.ctprintf("Action: %s", fixed_text_str(&w.knight.current_action)), 45, 330, 11, w.knight.action_color)
    rl.DrawText(fmt.ctprintf("Stamina: %.0f/100 | Sem: %d/1", w.knight.stamina, sync.semaphore_available_permits(&w.combat_sem)), 45, 350, 11, rl.RAYWHITE)

    // --- Zone 2: Outpost Quest (rush & Event(T)) ---
    rl.DrawRectangleLines(420, 75, 440, 300, {60, 80, 120, 255})
    rl.DrawText("ZONE 2: Quest Objectives (rush + Event)", 435, 90, 14, rl.GOLD)
    rl.DrawText("First goal wins; secondary goals keep running", 435, 110, 11, rl.GRAY)

    rl.DrawRectangleV(w.quest.terminal_pos - {16, 16}, {32, 32}, rl.DARKBLUE)
    rl.DrawText("Terminal", i32(w.quest.terminal_pos.x) - 24, i32(w.quest.terminal_pos.y) - 30, 11, rl.SKYBLUE)
    if w.quest.is_active || w.quest.terminal_prog > 0.0 {
        rl.DrawRectangle(i32(w.quest.terminal_pos.x) - 20, i32(w.quest.terminal_pos.y) + 20, 40, 6, rl.DARKGRAY)
        rl.DrawRectangle(i32(w.quest.terminal_pos.x) - 20, i32(w.quest.terminal_pos.y) + 20, i32(40.0 * w.quest.terminal_prog), 6, rl.GREEN)
    }

    rl.DrawCircleV({630, 200}, 14.0, w.quest.drones_defeated >= 2 ? rl.DARKGREEN : (w.quest.drones_defeated == 1 ? rl.ORANGE : rl.MAROON))
    rl.DrawText(fmt.ctprintf("Sentries (%d/2)", w.quest.drones_defeated), 590, 172, 11, rl.RAYWHITE)

    rl.DrawCircleV(w.quest.keycard_pos, 12.0, w.quest.keycard_found ? rl.DARKGREEN : rl.GOLD)
    rl.DrawText("Keycard", i32(w.quest.keycard_pos.x) - 20, i32(w.quest.keycard_pos.y) - 26, 11, rl.YELLOW)

    rl.DrawText(fmt.ctprintf("Status: %s", fixed_text_str(&w.quest.status_text)), 435, 330, 11, w.quest.status_color)

    if w.milestone_timer > 0.0 {
        rl.DrawRectangle(435, 350, 410, 20, {20, 40, 60, 220})
        rl.DrawText(fmt.ctprintf("Event: %s", fixed_text_str(&w.last_milestone)), 440, 354, 10, rl.LIME)
    }

    // --- Zone 3: Void Sentinel (Fiber_Scope & fiber_join) ---
    rl.DrawRectangleLines(890, 75, 360, 300, {60, 80, 120, 255})
    rl.DrawText("ZONE 3: Void Sentinel (Scope & Join)", 905, 90, 14, rl.GOLD)
    rl.DrawText("Phase 2 summons Minion; awaits via fiber_join", 905, 110, 11, rl.GRAY)

    rl.DrawCircleV(w.sentinel.pos, w.sentinel.radius, w.sentinel.color)
    if w.sentinel.shield_alpha > 0.05 {
        rl.DrawCircleLines(i32(w.sentinel.pos.x), i32(w.sentinel.pos.y), w.sentinel.radius + 8.0, rl.Fade(rl.SKYBLUE, w.sentinel.shield_alpha))
        rl.DrawText("INVULNERABLE", i32(w.sentinel.pos.x) - 40, i32(w.sentinel.pos.y) - 44, 10, rl.SKYBLUE)
    }

    if w.minion_active {
        rl.DrawCircleV(w.minion_pos, 14.0, rl.VIOLET)
        rl.DrawCircleLines(i32(w.minion_pos.x), i32(w.minion_pos.y), 16.0, rl.WHITE)
        rl.DrawText("Crystal Minion (Joined)", i32(w.minion_pos.x) - 55, i32(w.minion_pos.y) + 18, 10, rl.PINK)
    }

    cur_phase := w.sentinel.phase
    p_name := w.sentinel.phase_name
    rl.DrawText(fmt.ctprintf("Phase %d: %s", cur_phase, p_name), 905, 350, 11, rl.GREEN)

    // --- Zone 4: Simulation Benchmark (Bottom Left) ---
    rl.DrawRectangleLines(30, 390, 480, 290, {60, 80, 120, 255})
    rl.DrawText("ZONE 4: Headless CI/CD Fast-Forward Runner", 45, 405, 14, rl.GOLD)
    rl.DrawText("Press [T] to fast-forward 60s via next_wake_time", 45, 426, 11, rl.GRAY)

    if w.benchmark.has_run {
        rl.DrawText(fmt.ctprintf("Result: %s", w.benchmark.test_result), 45, 470, 13, rl.GREEN)
        rl.DrawText(fmt.ctprintf("Simulated Virtual Time: %.2f seconds", w.benchmark.sim_time_sec), 45, 500, 13, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("Real Wall-Clock Time:   %.2f ms", w.benchmark.wall_time_ms), 45, 525, 13, rl.YELLOW)
        rl.DrawText(fmt.ctprintf("Events Stepped:         %d events", w.benchmark.steps_executed), 45, 550, 13, rl.SKYBLUE)
        speedup := (w.benchmark.sim_time_sec * 1000.0) / max(0.001, w.benchmark.wall_time_ms)
        rl.DrawText(fmt.ctprintf("Speedup vs Real-Time:   %.0fx FASTER", speedup), 45, 585, 15, rl.LIME)
    } else {
        rl.DrawText("Ready to run. Press [T] to execute benchmark.", 45, 490, 13, rl.DARKGRAY)
    }

    // --- Player ---
    rl.DrawCircleV(w.player.pos, w.player.radius, rl.LIME)
    rl.DrawCircleLines(i32(w.player.pos.x), i32(w.player.pos.y), w.player.radius + 2, rl.WHITE)

    if w.is_paused {
        flash_col := w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD
        step_text := fmt.ctprintf("PAUSED: Step #%d (+%.3fs) | Sim: %.3fs | F4: 1F | F5: 10F | Hold F4: Slow-Mo | F3: Resume", w.step_count, w.last_step_dt, w.global_time)
        rl.DrawRectangle(25, SCREEN_HEIGHT - 32, SCREEN_WIDTH - 50, 24, {15, 18, 30, 230})
        rl.DrawRectangleLines(25, SCREEN_HEIGHT - 32, SCREEN_WIDTH - 50, 24, flash_col)
        rl.DrawText(step_text, 35, SCREEN_HEIGHT - 27, 13, flash_col)
    } else {
        rl.DrawText("WASD: Move | [2]: Quest | [3]: Phase | [X]: Stun | [T]: Bench | F1/Tab: Tree | F3: Pause | F4: Step 1F", 30, SCREEN_HEIGHT - 22, 13, rl.LIGHTGRAY)
    }

    // --- Coroutine Hierarchy Visualizer Overlay (F1 / TAB) ---
    if w.show_coroutine_debugger {
        panel_x: i32 = 530
        panel_y: i32 = 390
        panel_w: i32 = 720
        panel_h: i32 = 290

        rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 14, 22, 240})
        rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {0, 200, 255, 200})

        rl.DrawText("COROUTINE TREE (F1)", panel_x + 12, panel_y + 10, 14, w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD)
        rl.DrawLine(panel_x + 10, panel_y + 30, panel_x + panel_w - 10, panel_y + 30, {60, 80, 120, 255})

        Tree_Draw_Ctx :: struct {
            cur_y:   i32,
            max_y:   i32,
            panel_x: i32,
            col_r:   i32,
        }
        draw_ctx := Tree_Draw_Ctx{
            cur_y   = panel_y + 38,
            max_y   = panel_y + panel_h - 18,
            panel_x = panel_x,
            col_r   = panel_x + 440,
        }

        coroutine.scheduler_walk_tree(&w.sched, proc(f: ^coroutine.Fiber, depth: int, user_data: rawptr) {
            ctx := cast(^Tree_Draw_Ctx)user_data
            if f == nil || ctx.cur_y > ctx.max_y do return

            indent := i32(min(depth, 6) * 14)
            row_x := ctx.panel_x + 12 + indent
            name := f.debug_name != "" ? f.debug_name : "Fiber"

            status_str := ""
            status_col := rl.RAYWHITE
            cid := f.clock_id >= 0 && int(f.clock_id) < coroutine.MAX_CLOCKS ? f.clock_id : coroutine.CLOCK_SIM
            clock_tag := cid == coroutine.CLOCK_SIM ? "" : (cid == coroutine.CLOCK_REAL ? " [REAL]" : fmt.tprintf(" [C%d]", cid))
            #partial switch f.status {
            case .Running:
                status_str = "Run"
                status_col = rl.GREEN
            case .Ready:
                status_str = "Ready"
                status_col = rl.YELLOW
            case .Sleeping_Time:
                left := max(0.0, f.wake_time - coroutine.current_time(f))
                status_str = fmt.tprintf("%.2fs%s", left, clock_tag)
                status_col = cid == coroutine.CLOCK_REAL ? rl.PINK : rl.SKYBLUE
            case .Sleeping_Steps:
                cur_s := coroutine.current_steps(f)
                left := f.wake_step > cur_s ? f.wake_step - cur_s : 0
                status_str = fmt.tprintf("%dst%s", left, clock_tag)
                status_col = rl.SKYBLUE
            case .Suspended_Join:
                if f.active_coord.active_branches > 0 {
                    kind := "Sync"
                    switch f.active_coord.kind {
                    case .Sync:  kind = "Sync"
                    case .Race:  kind = "Race"
                    case .Rush:  kind = "Rush"
                    case .Guard: kind = "Guard"
                    }
                    status_str = fmt.tprintf("%s(%d)", kind, f.active_coord.active_branches)
                    status_col = rl.PURPLE
                } else if coroutine.fiber_is_awaiting_async(f) {
                    status_str = "Async"
                    status_col = rl.ORANGE
                } else {
                    status_str = "Wait"
                    status_col = rl.LIGHTGRAY
                }
            case:
                status_str = fmt.tprintf("%v", f.status)
                status_col = rl.GRAY
            }

            used, total := coroutine.fiber_calc_stack_usage(f)
            resumes := coroutine.fiber_resume_count(f)

            prefix := depth > 0 ? "+- " : "> "
            slot := coroutine.fiber_handle_index(f.handle)
            gen := coroutine.fiber_handle_gen(f.handle)
            left_text := fmt.tprintf("%s#%d:%d %s", prefix, slot, gen, name)
            max_chars := max(8, int(ctx.col_r - row_x - 10) / 7)
            if len(left_text) > max_chars {
                left_text = fmt.tprintf("%s..", left_text[:max_chars - 2])
            }
            right_text := fmt.tprintf("%-10s | %.1fK/%.0fK | r:%d", status_str, f32(used)/1024.0, f32(total)/1024.0, resumes)

            rl.DrawText(fmt.ctprintf("%s", left_text), row_x, ctx.cur_y, 11, status_col)
            rl.DrawText(fmt.ctprintf("%s", right_text), ctx.col_r, ctx.cur_y, 11, rl.LIGHTGRAY)
            ctx.cur_y += 16
        }, &draw_ctx)
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
        free_all(context.temp_allocator)
    }
}
