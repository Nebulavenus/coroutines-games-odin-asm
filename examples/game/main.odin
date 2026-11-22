package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

import coroutine "../.."

// ============================================================================
// Game State & Entity Structures
// ============================================================================

SCREEN_WIDTH          :: 1280
SCREEN_HEIGHT         :: 720
PLAYER_BASE_SPEED     :: f32(320.0)
CLOCK_PLAYER          :: coroutine.Clock_ID(3)
FLOATING_TEXT_MAX_LEN :: 64

Projectile :: struct {
    pos:      rl.Vector2,
    vel:      rl.Vector2,
    radius:   f32,
    color:    rl.Color,
    is_enemy: bool,
    alive:    bool,
}

Floating_Text :: struct {
    text_buf: [FLOATING_TEXT_MAX_LEN]u8,
    text_len: u8,
    pos:      rl.Vector2,
    color:    rl.Color,
    alpha:    f32,
    scale:    f32,
}

#assert(size_of(Floating_Text) <= coroutine.FIBER_PAYLOAD_SIZE)

Particle :: struct {
    pos:      rl.Vector2,
    vel:      rl.Vector2,
    color:    rl.Color,
    alpha:    f32,
    size:     f32,
    lifetime: f32,
    alive:    bool,
}

Player :: struct {
    pos:             rl.Vector2,
    speed:           f32,
    radius:          f32,
    hp:              f32,
    max_hp:          f32,
    can_dash:        bool,
    is_dashing:      bool,
    dash_cooldown:   f32,
    emp_cooldown:    f32,
    slowmo_charge:   f32,
    slowmo_max:      f32,
    is_slowmo:       bool,
    slowmo_factor:   f32,
    shoot_timer:     f32,
    ghost_positions: [6]rl.Vector2,
    ghost_alphas:    [6]f32,
    ghost_timer:     f32,
    scope:           coroutine.Fiber_Scope,
}

Boss :: struct {
    pos:          rl.Vector2,
    radius:       f32,
    hp:           f32,
    max_hp:       f32,
    phase:        int,
    phase_name:   string,
    shield_alpha: f32,
    color:        rl.Color,
    scope:        coroutine.Fiber_Scope,
    stun_signal:  coroutine.Signal,
    is_stunned:   bool,
    alive:        bool,
}

MAX_PROJECTILES :: 512
MAX_PARTICLES   :: 1024

Game :: struct {
    sched:                   coroutine.Scheduler,
    player:                  Player,
    boss:                    Boss,
    vfx_scope:               coroutine.Fiber_Scope,
    camera_shake_handle:     coroutine.Fiber_Handle,
    camera_shake_intensity:  f32,
    projectiles:             [MAX_PROJECTILES]Projectile,
    projectile_count:        int,
    particles:               [MAX_PARTICLES]Particle,
    particle_count:          int,
    camera_offset:           rl.Vector2,
    game_time:               f32,
    is_paused:               bool,
    show_coroutine_debugger: bool,
    game_over:               bool,
    victory:                 bool,
    step_count:              int,
    step_flash_timer:        f32,
    last_step_dt:            f32,
    hold_step_timer:         f32,
    latched_dash:            bool,
    latched_shoot:           bool,
    latched_emp:             bool,
}

g_game: ^Game

g_rng_state: u32 = 0x853c49e6

ease_out_back :: proc(t: f32) -> f32 {
    c1: f32 = 1.70158
    c3 := c1 + 1.0
    tm1 := t - 1.0
    return 1.0 + c3 * tm1 * tm1 * tm1 + c1 * tm1 * tm1
}

ease_in_out_quad :: proc(t: f32) -> f32 {
    return t < 0.5 ? 2.0 * t * t : 1.0 - (-2.0 * t + 2.0) * (-2.0 * t + 2.0) / 2.0
}

ease_in_out_cubic :: proc(t: f32) -> f32 {
    return t < 0.5 ? 4.0 * t * t * t : 1.0 - (-2.0 * t + 2.0) * (-2.0 * t + 2.0) * (-2.0 * t + 2.0) / 2.0
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

game_rand_f32 :: proc(min_val, max_val: f32) -> f32 {
    g_rng_state = g_rng_state * 1664525 + 1013904223
    t := f32(g_rng_state & 0x00FFFFFF) / f32(0x01000000)
    return min_val + (max_val - min_val) * t
}

safe_normalize :: proc(v: rl.Vector2, fallback: rl.Vector2) -> rl.Vector2 {
    len_sq := v.x * v.x + v.y * v.y
    if len_sq <= 1e-6 do return fallback
    inv_len := 1.0 / math.sqrt(len_sq)
    return {v.x * inv_len, v.y * inv_len}
}

// ============================================================================
// Particle & Visual Helpers
// ============================================================================

spawn_particles :: proc(pos: rl.Vector2, count: int, color: rl.Color) {
    if g_game == nil do return
    for _ in 0 ..< count {
        if g_game.particle_count >= MAX_PARTICLES do break
        angle := game_rand_f32(0, math.TAU)
        spd := game_rand_f32(50, 250)
        p := Particle{
            pos      = pos,
            vel      = {math.cos(angle) * spd, math.sin(angle) * spd},
            color    = color,
            alpha    = 1.0,
            size     = game_rand_f32(3, 8),
            lifetime = game_rand_f32(0.3, 0.7),
            alive    = true,
        }
        g_game.particles[g_game.particle_count] = p
        g_game.particle_count += 1
    }
}

spawn_projectile :: proc(pos, vel: rl.Vector2, radius: f32, color: rl.Color, is_enemy: bool) {
    if g_game == nil || g_game.projectile_count >= MAX_PROJECTILES do return
    p := Projectile{
        pos      = pos,
        vel      = vel,
        radius   = radius,
        color    = color,
        is_enemy = is_enemy,
        alive    = true,
    }
    g_game.projectiles[g_game.projectile_count] = p
    g_game.projectile_count += 1
}

// ============================================================================
// Coroutines: Player Abilities & Camera Effects
// ============================================================================

camera_shake_coroutine :: proc(f: ^coroutine.Fiber, intensity: f32) {
    dur: f32 = 0.3
    elapsed: f32 = 0.0

    coroutine.fiber_defer(f, proc(g: ^Game) {
        g.camera_offset = {0, 0}
        g.camera_shake_intensity = 0.0
        g.camera_shake_handle = 0
    }, g_game)

    g_game.camera_shake_intensity = intensity

    for elapsed < dur {
        coroutine.yield(f)
        elapsed += coroutine.delta_time(f)
        decay := clamp(1.0 - (elapsed / dur), 0.0, 1.0)
        curr := intensity * decay
        g_game.camera_shake_intensity = curr
        if curr > 0.0 {
            g_game.camera_offset = {
                game_rand_f32(-curr, curr),
                game_rand_f32(-curr, curr),
            }
        } else {
            g_game.camera_offset = {0, 0}
        }
    }
    coroutine.fiber_defer_run_top(f)
}

trigger_camera_shake :: proc(intensity: f32) {
    if g_game == nil || intensity <= 0.0 do return
    if g_game.camera_shake_handle != 0 && coroutine.fiber_is_alive(&g_game.sched, g_game.camera_shake_handle) {
        if intensity < g_game.camera_shake_intensity {
            return
        }
        coroutine.fiber_cancel(&g_game.sched, g_game.camera_shake_handle)
    }
    g_game.camera_shake_intensity = intensity
    g_game.camera_shake_handle = coroutine.spawn(
        &g_game.sched,
        camera_shake_coroutine,
        intensity,
        scope = &g_game.vfx_scope,
        name = "Camera Shake",
        clock = CLOCK_PLAYER,
    )
}

floating_text_coroutine :: proc(f: ^coroutine.Fiber, ft: Floating_Text) {
    curr_ft := ft
    start_y := curr_ft.pos.y
    target_y := start_y - 45.0

    dur: f32 = 0.8
    elapsed: f32 = 0.0

    for elapsed < dur {
        coroutine.yield(f)
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / dur, 0.0, 1.0)
        eased_t := ease_out_back(t)
        curr_ft.pos.y = start_y + (target_y - start_y) * eased_t
        curr_ft.alpha = 1.0 - t
        (cast(^Floating_Text)&f.payload_storage[0])^ = curr_ft
    }
}

spawn_floating_text :: proc(text: string, pos: rl.Vector2, color: rl.Color = rl.GOLD, scale: f32 = 18.0) {
    if g_game == nil do return
    ft := Floating_Text{
        pos   = pos + {game_rand_f32(-20, 20), game_rand_f32(-10, 10)},
        color = color,
        alpha = 1.0,
        scale = scale,
    }
    n := min(len(text), FLOATING_TEXT_MAX_LEN)
    if n > 0 {
        copy(ft.text_buf[:n], text[:n])
    }
    ft.text_len = u8(n)
    coroutine.spawn(&g_game.sched, floating_text_coroutine, ft, scope = &g_game.vfx_scope, name = "Floating Text")
}

player_dash_coroutine :: proc(f: ^coroutine.Fiber, p: ^Player) {
    if !p.can_dash || p.is_dashing do return
    p.can_dash = false
    p.is_dashing = true
    p.dash_cooldown = 0.0
    p.speed = PLAYER_BASE_SPEED * 3.2

    trigger_camera_shake(5.0)
    spawn_particles(p.pos, 15, rl.SKYBLUE)

    coroutine.fiber_defer(f, proc(p: ^Player) {
        p.speed = PLAYER_BASE_SPEED
        p.is_dashing = false
        p.can_dash = true
        p.dash_cooldown = 0.0
    }, p)

    coroutine.fiber_defer(f, proc(p: ^Player) {
        p.speed = PLAYER_BASE_SPEED
        p.is_dashing = false
    }, p)

    coroutine.wait(f, 0.18)
    coroutine.fiber_defer_run_top(f)

    p.dash_cooldown = 0.8
    for p.dash_cooldown > 0.0 {
        coroutine.yield(f)
        p.dash_cooldown = max(0.0, p.dash_cooldown - coroutine.delta_time(f))
    }
    coroutine.fiber_defer_run_top(f)
}

// ============================================================================
// Coroutines: Hierarchical Multi-Phase Boss AI (Pure Structured Concurrency)
// ============================================================================

boss_patrol_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    center_x := f32(SCREEN_WIDTH) / 2.0
    right_x := center_x + 350.0
    left_x := center_x - 350.0

    initial_dur := max(0.25, math.abs(right_x - b.pos.x) / 175.0)
    tween_f32(f, &b.pos.x, b.pos.x, right_x, initial_dur, ease_in_out_quad)
    coroutine.wait(f, 0.3)

    for {
        tween_f32(f, &b.pos.x, right_x, left_x, 4.0, ease_in_out_quad)
        coroutine.wait(f, 0.3)
        tween_f32(f, &b.pos.x, left_x, right_x, 4.0, ease_in_out_quad)
        coroutine.wait(f, 0.3)
    }
}

boss_spiral_shoot_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    angle_offset: f32 = 0.0

    for {
        coroutine.wait(f, 0.25)
        if !b.alive do break

        bullets_count := 8
        step := math.TAU / f32(bullets_count)
        for i in 0 ..< bullets_count {
            a := angle_offset + f32(i) * step
            dir := rl.Vector2{math.cos(a), math.sin(a)}
            vel := dir * 220.0
            spawn_projectile(b.pos, vel, 7.0, rl.ORANGE, true)
        }
        angle_offset += 0.35
    }
}

boss_targeted_burst_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for {
        coroutine.wait(f, 1.8)
        if !b.alive do break

        for _ in 0 ..< 3 {
            coroutine.wait(f, 0.12)
            if !b.alive do break
            dir := safe_normalize(g_game.player.pos - b.pos, {0, 1})
            vel := dir * 420.0
            spawn_projectile(b.pos, vel, 9.0, rl.RED, true)
            spawn_particles(b.pos, 5, rl.RED)
        }
    }
}

boss_enraged_laser_sweep :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for {
        coroutine.wait(f, 1.2)
        if !b.alive do break

        trigger_camera_shake(8.0)
        spawn_particles(b.pos, 30, rl.PURPLE)
        ring_count := 18
        step := math.TAU / f32(ring_count)
        for i in 0 ..< ring_count {
            a := f32(i) * step
            dir := rl.Vector2{math.cos(a), math.sin(a)}
            vel := dir * 300.0
            spawn_projectile(b.pos, vel, 8.0, rl.MAGENTA, true)
        }
    }
}

boss_apply_stun :: proc(f: ^coroutine.Fiber, b: ^Boss, duration: f32, restore_color: rl.Color) {
    spawn_floating_text("BOSS STUNNED!", b.pos, rl.YELLOW)
    b.is_stunned = true
    b.color = rl.DARKGRAY
    coroutine.fiber_defer(f, proc(b: ^Boss) {
        b.is_stunned = false
    }, b)
    coroutine.wait(f, duration)
    coroutine.fiber_defer_run_top(f)
    if b.alive {
        b.color = restore_color
    }
}

boss_attack_loop_phase1 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.hp > 700.0 && b.alive && b.phase == 1 {
        outcome := coroutine.with_signal(f, &b.stun_signal, proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync_with(f, b, boss_spiral_shoot_subloop, boss_targeted_burst_subloop)
        }, b, "Phase 1 Attacks")

        if outcome == .Interrupted && b.hp > 700.0 && b.alive && b.phase == 1 {
            boss_apply_stun(f, b, 1.5, rl.GOLD)
        }
    }
}

boss_attack_loop_phase2 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.hp > 350.0 && b.alive && b.phase == 2 {
        outcome := coroutine.with_signal(f, &b.stun_signal, proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync_with(f, b, boss_enraged_laser_sweep, boss_targeted_burst_subloop)
        }, b, "Phase 2 Attacks")

        if outcome == .Interrupted && b.hp > 350.0 && b.alive && b.phase == 2 {
            boss_apply_stun(f, b, 1.5, rl.SKYBLUE)
        }
    }
}

boss_attack_loop_phase3 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.alive && b.phase == 3 {
        outcome := coroutine.with_signal(f, &b.stun_signal, proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync_with(f, b, boss_spiral_shoot_subloop, boss_enraged_laser_sweep, boss_targeted_burst_subloop)
        }, b, "Phase 3 Attacks")

        if outcome == .Interrupted && b.alive && b.phase == 3 {
            boss_apply_stun(f, b, 1.0, rl.RED)
        }
    }
}

boss_master_ai :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    // ========================================================================
    // PHASE 1: Patrol + Spiral Bullet Barrage (Runs until HP < 700)
    // ========================================================================
    coroutine.fiber_set_name(f, "Boss AI: Phase 1 (Spiral Barrage)")
    b.phase = 1
    b.phase_name = "Phase 1: Spiral Barrage"
    b.color = rl.GOLD
    spawn_floating_text("PHASE 1: ENGAGED", b.pos, rl.GOLD)

    coroutine.race_with(f, b,
        proc(f: ^coroutine.Fiber, b: ^Boss) {
            for b.hp > 700.0 && b.alive {
                coroutine.yield(f)
            }
        },
        boss_patrol_subloop,
        boss_attack_loop_phase1,
    )

    if !b.alive do return

    // ========================================================================
    // PHASE 2: Super Shield Charge & Radial Nova (Runs until HP < 350)
    // ========================================================================
    coroutine.fiber_set_name(f, "Boss AI: Phase 2 (Shield & Nova)")
    b.phase = 2
    b.phase_name = "Phase 2: Super Nova Charge"
    b.color = rl.SKYBLUE
    spawn_floating_text("PHASE 2: SHIELD CHARGE!", b.pos, rl.SKYBLUE)
    trigger_camera_shake(10.0)

    tween_vec2(f, &b.pos, b.pos, [2]f32{f32(SCREEN_WIDTH) / 2.0, 180.0}, 1.0, ease_in_out_cubic)
    if !b.alive do return

    coroutine.fiber_defer(f, proc(b: ^Boss) {
        b.shield_alpha = 0.0
    }, b)

    coroutine.sync_with(f, b,
        proc(f: ^coroutine.Fiber, b: ^Boss) {
            tween_f32(f, &b.shield_alpha, 0.0, 0.85, 1.2, ease_in_out_quad)
            coroutine.wait(f, 0.5)
            tween_f32(f, &b.shield_alpha, 0.85, 0.0, 0.3)
        },
        proc(f: ^coroutine.Fiber, b: ^Boss) {
            for _ in 0 ..< 10 {
                spawn_particles(b.pos, 8, rl.SKYBLUE)
                coroutine.wait(f, 0.15)
            }
        },
    )
    coroutine.fiber_defer_run_top(f)

    if !b.alive do return

    trigger_camera_shake(15.0)
    spawn_floating_text("SUPER NOVA BURST!", b.pos, rl.VIOLET)
    for i in 0 ..< 32 {
        a := f32(i) * (math.TAU / 32.0)
        dir := rl.Vector2{math.cos(a), math.sin(a)}
        spawn_projectile(b.pos, dir * 280.0, 10.0, rl.PURPLE, true)
    }

    if b.hp > 350.0 && b.alive {
        coroutine.race_with(f, b,
            proc(f: ^coroutine.Fiber, b: ^Boss) {
                for b.hp > 350.0 && b.alive {
                    coroutine.yield(f)
                }
            },
            boss_patrol_subloop,
            boss_attack_loop_phase2,
        )
    }

    if !b.alive do return

    // ========================================================================
    // PHASE 3: Enraged Berserk Mode (HP <= 350)
    // ========================================================================
    coroutine.fiber_set_name(f, "Boss AI: Phase 3 (Enraged Berserk)")
    b.phase = 3
    b.phase_name = "Phase 3: BERSERK ENRAGED"
    b.color = rl.RED
    spawn_floating_text("PHASE 3: BERSERK MODE!", b.pos, rl.RED)
    trigger_camera_shake(20.0)

    coroutine.race_with(f, b,
        proc(f: ^coroutine.Fiber, b: ^Boss) {
            for b.alive {
                coroutine.yield(f)
            }
        },
        boss_patrol_subloop,
        boss_attack_loop_phase3,
    )
}

// ============================================================================
// Main Game Update & Render
// ============================================================================

game_init :: proc(g: ^Game) {
    if g.sched.fiber_pool.all_fibers != nil {
        game_destroy(g)
    }
    coroutine.scheduler_init(&g.sched)
    coroutine.scheduler_prewarm(&g.sched, 64)

    g.player = Player{
        pos           = {f32(SCREEN_WIDTH) / 2.0, f32(SCREEN_HEIGHT) - 100.0},
        speed         = PLAYER_BASE_SPEED,
        radius        = 18.0,
        hp            = 400.0,
        max_hp        = 400.0,
        can_dash      = true,
        is_dashing    = false,
        dash_cooldown = 0.0,
        slowmo_charge = 100.0,
        slowmo_max    = 100.0,
    }

    g.boss = Boss{
        pos          = {f32(SCREEN_WIDTH) / 2.0, 150.0},
        radius       = 48.0,
        hp           = 1000.0,
        max_hp       = 1000.0,
        phase        = 1,
        phase_name   = "Phase 1: Spiral Barrage",
        shield_alpha = 0.0,
        color        = rl.GOLD,
        is_stunned   = false,
        alive        = true,
    }

    g.vfx_scope = {}
    g.camera_shake_handle = 0
    g.camera_shake_intensity = 0.0
    g.projectile_count = 0
    g.particle_count = 0
    g.camera_offset = {0, 0}
    g.game_time = 0.0
    g.is_paused = false
    g.game_over = false
    g.victory = false
    g.step_count = 0
    g.step_flash_timer = 0.0
    g.last_step_dt = 0.0
    g.hold_step_timer = 0.0
    g.latched_dash = false
    g.latched_shoot = false
    g.latched_emp = false
    g_rng_state = 0x853c49e6

    g_game = g

    coroutine.spawn(&g.sched, boss_master_ai, &g.boss, scope = &g.boss.scope, name = "Boss AI Timeline")
}

game_destroy :: proc(g: ^Game) {
    coroutine.signal_destroy(&g.boss.stun_signal)
    coroutine.scope_destroy(&g.sched, &g.vfx_scope)
    coroutine.scope_destroy(&g.sched, &g.player.scope)
    coroutine.scope_destroy(&g.sched, &g.boss.scope)
    coroutine.scheduler_destroy(&g.sched)
    g.camera_shake_handle = 0
    g.camera_shake_intensity = 0.0
}

game_sim_step :: proc(g: ^Game, sim_dt: f32, real_dt: f32) {
    if g.game_over || g.victory {
        if real_dt > 0.0 {
            coroutine.clock_advance(&g.sched, coroutine.CLOCK_REAL, real_dt)
        }
        coroutine.clock_advance(&g.sched, CLOCK_PLAYER, sim_dt)
        coroutine.clock_advance(&g.sched, coroutine.CLOCK_SIM, sim_dt)
        coroutine.scheduler_run(&g.sched)

        for i := g.particle_count - 1; i >= 0; i -= 1 {
            p := &g.particles[i]
            p.pos += p.vel * sim_dt
            p.alpha -= sim_dt * 2.0
            if p.alpha <= 0.0 {
                g.particles[i] = g.particles[g.particle_count - 1]
                g.particle_count -= 1
            }
        }
        return
    }

    // --- Matrix Slowmo Mechanic (Hold RMB) with Recovery Bar ---
    slowmo_held := rl.IsMouseButtonDown(.RIGHT) || rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.Q)
    if slowmo_held && g.player.slowmo_charge > 0.0 && !g.is_paused {
        g.player.is_slowmo = true
        DRAIN_RATE : f32 = 28.0 // ~3.57s of continuous bullet-time
        g.player.slowmo_charge = max(0.0, g.player.slowmo_charge - DRAIN_RATE * sim_dt)
        if g.player.slowmo_charge <= 0.0 {
            g.player.is_slowmo = false
        }
    } else {
        g.player.is_slowmo = false
        RECHARGE_RATE : f32 = 22.0 // ~4.5s to fully recover
        g.player.slowmo_charge = min(g.player.slowmo_max, g.player.slowmo_charge + RECHARGE_RATE * sim_dt)
    }

    t := clamp(g.player.slowmo_charge / g.player.slowmo_max, 0.0, 1.0)
    factor: f32 = 0.0
    if g.player.is_slowmo {
        factor = t * math.sqrt(t)
    }
    g.player.slowmo_factor = factor

    MIN_WORLD_SCALE : f32 = 0.15 // Down to 15% speed at full bar
    world_time_scale := 1.0 - (1.0 - MIN_WORLD_SCALE) * factor
    world_sim_dt := sim_dt * world_time_scale
    player_agility := 1.0 + 0.35 * factor
    player_dt := sim_dt * player_agility

    g.game_time += world_sim_dt

    // --- Player Dash Coroutine Trigger (Space / K) ---
    do_dash := g.latched_dash || rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.K)
    g.latched_dash = false
    if do_dash && g.player.can_dash && !coroutine.scope_is_busy(&g.player.scope) {
        coroutine.spawn(&g.sched, player_dash_coroutine, &g.player, scope = &g.player.scope, name = "Player Dash", clock = CLOCK_PLAYER)
    }

    // --- Player EMP / Stun Trigger (E / B / X key) ---
    if g.player.emp_cooldown > 0.0 {
        g.player.emp_cooldown = max(0.0, g.player.emp_cooldown - player_dt)
    }

    do_emp := g.latched_emp || rl.IsKeyPressed(.E) || rl.IsKeyPressed(.B) || rl.IsKeyPressed(.X)
    g.latched_emp = false
    if do_emp && g.player.emp_cooldown <= 0.0 {
        g.player.emp_cooldown = 1.8
        will_stun := coroutine.signal_has_waiters(&g.boss.stun_signal)
        coroutine.signal_emit(&g.sched, &g.boss.stun_signal)
        bullets_destroyed := 0
        for i := g.projectile_count - 1; i >= 0; i -= 1 {
            if g.projectiles[i].is_enemy {
                spawn_particles(g.projectiles[i].pos, 10, rl.GOLD)
                g.projectiles[i] = g.projectiles[g.projectile_count - 1]
                g.projectile_count -= 1
                bullets_destroyed += 1
            }
        }
        trigger_camera_shake(16.0)
        spawn_particles(g.player.pos, 50, rl.GOLD)
        if will_stun {
            spawn_floating_text(fmt.tprintf("EMP PARRY! Stunned Boss (%d Vaporized)", bullets_destroyed), g.player.pos, rl.GOLD)
        } else {
            spawn_floating_text(fmt.tprintf("EMP PULSE! (%d Bullets Vaporized)", bullets_destroyed), g.player.pos, rl.SKYBLUE)
        }
    }

    if real_dt > 0.0 {
        coroutine.clock_advance(&g.sched, coroutine.CLOCK_REAL, real_dt)
    }
    coroutine.clock_advance(&g.sched, CLOCK_PLAYER, player_dt)
    coroutine.clock_advance(&g.sched, coroutine.CLOCK_SIM, world_sim_dt)
    coroutine.scheduler_run(&g.sched)

    // --- Player Movement (WASD / Arrows with Matrix Agility) ---
    move_dir := rl.Vector2{0, 0}
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    do move_dir.y -= 1
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  do move_dir.y += 1
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  do move_dir.x -= 1
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move_dir.x += 1

    if linalg.length(move_dir) > 0 {
        move_dir = linalg.normalize(move_dir)
        g.player.pos += move_dir * (g.player.speed * player_agility) * sim_dt
        g.player.pos.x = clamp(g.player.pos.x, g.player.radius, f32(SCREEN_WIDTH) - g.player.radius)
        g.player.pos.y = clamp(g.player.pos.y, g.player.radius, f32(SCREEN_HEIGHT) - g.player.radius)
    }

    // --- Player Afterimage Ghost Trail (Bullet-time silhouette) ---
    for i in 0 ..< 6 {
        if g.player.ghost_alphas[i] > 0.0 {
            g.player.ghost_alphas[i] = max(0.0, g.player.ghost_alphas[i] - sim_dt * 4.0)
        }
    }
    if g.player.is_slowmo || g.player.is_dashing {
        g.player.ghost_timer += sim_dt
        if g.player.ghost_timer >= 0.035 {
            g.player.ghost_timer = 0.0
            for i := 5; i > 0; i -= 1 {
                g.player.ghost_positions[i] = g.player.ghost_positions[i - 1]
                g.player.ghost_alphas[i] = g.player.ghost_alphas[i - 1] * 0.75
            }
            g.player.ghost_positions[0] = g.player.pos
            g.player.ghost_alphas[0] = g.player.is_dashing ? 0.9 : (0.35 + 0.5 * factor)
        }
    }

    g.player.shoot_timer += player_dt
    is_shooting := g.latched_shoot || rl.IsMouseButtonDown(.LEFT) || rl.IsKeyDown(.J) || rl.IsKeyDown(.Z)
    g.latched_shoot = false
    if is_shooting {
        if g.player.shoot_timer >= 0.12 {
            g.player.shoot_timer = 0.0
            mouse_pos := rl.GetMousePosition()
            shoot_dir := rl.Vector2{0, -1}
            if linalg.length(mouse_pos - g.player.pos) > 10.0 {
                shoot_dir = safe_normalize(mouse_pos - g.player.pos, {0, -1})
            }
            spawn_projectile(g.player.pos, shoot_dir * 650.0, 6.0, rl.GREEN, false)
            spawn_particles(g.player.pos, 2, rl.LIME)
        }
    }

    // --- Update Projectiles ---
    for i := g.projectile_count - 1; i >= 0; i -= 1 {
        p := &g.projectiles[i]
        if !p.alive {
            g.projectiles[i] = g.projectiles[g.projectile_count - 1]
            g.projectile_count -= 1
            continue
        }
        p_dt := p.is_enemy ? world_sim_dt : sim_dt
        p.pos += p.vel * p_dt

        if p.pos.x < -50 || p.pos.x > SCREEN_WIDTH + 50 || p.pos.y < -50 || p.pos.y > SCREEN_HEIGHT + 50 {
            g.projectiles[i] = g.projectiles[g.projectile_count - 1]
            g.projectile_count -= 1
            continue
        }

        if !p.is_enemy && g.boss.alive && !g.game_over {
            if linalg.length(p.pos - g.boss.pos) < (p.radius + g.boss.radius) {
                dmg: f32 = 12.0
                if g.boss.shield_alpha > 0.3 {
                    dmg = 2.0
                    spawn_floating_text("BLOCKED!", g.boss.pos + {game_rand_f32(-30, 30), -50}, rl.SKYBLUE)
                } else {
                    spawn_floating_text(fmt.tprintf("-%.0f", dmg), g.boss.pos + {game_rand_f32(-40, 40), -40}, rl.YELLOW)
                }
                g.boss.hp -= dmg
                spawn_particles(p.pos, 6, rl.GOLD)
                g.projectiles[i] = g.projectiles[g.projectile_count - 1]
                g.projectile_count -= 1

                if g.boss.hp <= 0.0 {
                    g.boss.hp = 0.0
                    g.boss.alive = false
                    g.victory = true
                    coroutine.scope_cancel(&g.sched, &g.boss.scope)
                    spawn_floating_text("VICTORY!", g.boss.pos, rl.GREEN)
                    trigger_camera_shake(25.0)
                    spawn_particles(g.boss.pos, 100, rl.GOLD)
                }
                continue
            }
        }

        if p.is_enemy && !g.player.is_dashing && !g.victory && !g.game_over {
            if linalg.length(p.pos - g.player.pos) < (p.radius + g.player.radius) {
                dmg: f32 = 15.0
                g.player.hp -= dmg
                spawn_floating_text(fmt.tprintf("-%.0f", dmg), g.player.pos + {0, -30}, rl.RED)
                trigger_camera_shake(6.0)
                spawn_particles(g.player.pos, 12, rl.RED)
                g.projectiles[i] = g.projectiles[g.projectile_count - 1]
                g.projectile_count -= 1

                if g.player.hp <= 0.0 {
                    g.player.hp = 0.0
                    g.game_over = true
                    coroutine.scope_cancel(&g.sched, &g.player.scope)
                    coroutine.scope_cancel(&g.sched, &g.boss.scope)
                    spawn_floating_text("GAME OVER", g.player.pos, rl.RED)
                }
                continue
            }
        }
    }

    // --- Update Particles ---
    for i := g.particle_count - 1; i >= 0; i -= 1 {
        p := &g.particles[i]
        p.pos += p.vel * world_sim_dt
        p.alpha -= world_sim_dt * 2.0
        if p.alpha <= 0.0 {
            g.particles[i] = g.particles[g.particle_count - 1]
            g.particle_count -= 1
        }
    }
}

game_update :: proc(g: ^Game, dt: f32) {
    if rl.IsKeyPressed(.R) || ((g.game_over || g.victory) && (rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.SPACE))) {
        game_init(g)
        return
    }

    if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.ESCAPE) || rl.IsKeyPressed(.F3) {
        g.is_paused = !g.is_paused
    }
    if rl.IsKeyPressed(.H) || rl.IsKeyPressed(.TAB) || rl.IsKeyPressed(.F1) {
        g.show_coroutine_debugger = !g.show_coroutine_debugger
    }

    steps_to_run := 0
    step_dt: f32 = 0.0

    if !g.is_paused {
        steps_to_run = 1
        step_dt = dt
        g.step_flash_timer = 0.0
    } else {
        if g.step_flash_timer > 0.0 {
            g.step_flash_timer = max(0.0, g.step_flash_timer - dt)
        }

        step_1_pressed := rl.IsKeyPressed(.N) || rl.IsKeyPressed(.PERIOD) || rl.IsKeyPressed(.F4)
        step_10_pressed := rl.IsKeyPressed(.M) || rl.IsKeyPressed(.F5) || (rl.IsKeyDown(.LEFT_SHIFT) && step_1_pressed)
        step_hold := rl.IsKeyDown(.N) || rl.IsKeyDown(.PERIOD) || rl.IsKeyDown(.F4)

        if step_1_pressed && !rl.IsKeyDown(.LEFT_SHIFT) {
            steps_to_run = 1
            step_dt = 1.0 / 60.0
            g.step_count += 1
            g.last_step_dt = step_dt
            g.step_flash_timer = 0.4
        } else if step_10_pressed {
            steps_to_run = 10
            step_dt = 1.0 / 60.0
            g.step_count += 10
            g.last_step_dt = 10.0 / 60.0
            g.step_flash_timer = 0.5
        } else if step_hold {
            g.hold_step_timer += dt
            if g.hold_step_timer >= 0.15 {
                steps_to_run = 1
                step_dt = 1.0 / 60.0
                g.step_count += 1
                g.last_step_dt = step_dt
                g.hold_step_timer = 0.0
                g.step_flash_timer = 0.2
            }
        } else {
            g.hold_step_timer = 0.0
        }
    }

    if !g.game_over && !g.victory {
        if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.K) {
            g.latched_dash = true
        }
        if rl.IsMouseButtonPressed(.LEFT) || rl.IsKeyPressed(.J) || rl.IsKeyPressed(.Z) {
            g.latched_shoot = true
        }
        if rl.IsKeyPressed(.E) || rl.IsKeyPressed(.B) || rl.IsKeyPressed(.X) {
            g.latched_emp = true
        }
    }

    if steps_to_run <= 0 {
        coroutine.clock_set_paused(&g.sched, coroutine.CLOCK_SIM, true)
        coroutine.clock_set_paused(&g.sched, CLOCK_PLAYER, true)
        coroutine.clock_advance(&g.sched, coroutine.CLOCK_REAL, dt)
        coroutine.scheduler_run(&g.sched)
        return
    }

    coroutine.clock_set_paused(&g.sched, coroutine.CLOCK_SIM, false)
    coroutine.clock_set_paused(&g.sched, CLOCK_PLAYER, false)
    for step_idx in 0 ..< steps_to_run {
        real_step_dt := step_idx == 0 ? dt : f32(0.0)
        game_sim_step(g, step_dt, real_step_dt)
    }
    coroutine.clock_set_paused(&g.sched, coroutine.CLOCK_SIM, g.is_paused)
    coroutine.clock_set_paused(&g.sched, CLOCK_PLAYER, g.is_paused)
}

game_render :: proc(g: ^Game) {
    rl.BeginDrawing()
    rl.ClearBackground({18, 20, 30, 255})

    cam_x := i32(g.camera_offset.x)
    cam_y := i32(g.camera_offset.y)

    // --- Draw Grid Background ---
    for x := i32(0); x < SCREEN_WIDTH; x += 40 {
        rl.DrawLine(x + cam_x, 0, x + cam_x, SCREEN_HEIGHT, {30, 35, 50, 255})
    }
    for y := i32(0); y < SCREEN_HEIGHT; y += 40 {
        rl.DrawLine(0, y + cam_y, SCREEN_WIDTH, y + cam_y, {30, 35, 50, 255})
    }

    // --- Draw Particles ---
    for i in 0 ..< g.particle_count {
        p := &g.particles[i]
        c := p.color
        c.a = u8(clamp(p.alpha * 255.0, 0, 255))
        rl.DrawCircleV(p.pos + g.camera_offset, p.size, c)
    }

    // --- Matrix Bullet-Time Fullscreen Tint ---
    if g.player.is_slowmo && g.player.slowmo_factor > 0.01 {
        tint_alpha := u8(clamp(g.player.slowmo_factor * 45.0, 0, 75))
        rl.DrawRectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, {0, 30, 10, tint_alpha})
    }

    // --- Draw Boss ---
    if g.boss.alive {
        boss_screen_pos := g.boss.pos + g.camera_offset
        rl.DrawCircleV(boss_screen_pos, g.boss.radius, g.boss.color)
        rl.DrawCircleLinesV(boss_screen_pos, g.boss.radius + 4, rl.WHITE)

        if g.boss.shield_alpha > 0.01 {
            shield_col := rl.SKYBLUE
            shield_col.a = u8(g.boss.shield_alpha * 255.0)
            rl.DrawCircleV(boss_screen_pos, g.boss.radius + 20, shield_col)
        }

        rl.DrawCircleV(boss_screen_pos, 16.0, rl.BLACK)
        rl.DrawCircleV(boss_screen_pos, 8.0, rl.WHITE)
    }

    // --- Draw Player Ghost Afterimages (Bullet-time silhouettes) ---
    for i in 0 ..< 6 {
        alpha := g.player.ghost_alphas[i]
        if alpha > 0.01 {
            ghost_col := g.player.is_dashing ? rl.SKYBLUE : rl.Color{0, 255, 130, 255}
            ghost_col.a = u8(clamp(alpha * 255.0, 0, 255))
            screen_pos := g.player.ghost_positions[i] + g.camera_offset
            rl.DrawCircleV(screen_pos, g.player.radius * (1.0 - f32(i) * 0.08), ghost_col)
        }
    }

    // --- Draw Player ---
    if g.player.hp > 0.0 {
        player_col := g.player.is_dashing ? rl.SKYBLUE : rl.GREEN
        player_screen_pos := g.player.pos + g.camera_offset
        rl.DrawCircleV(player_screen_pos, g.player.radius, player_col)
        rl.DrawCircleLinesV(player_screen_pos, g.player.radius + 2, rl.WHITE)

        mouse_pos := rl.GetMousePosition()
        dir := safe_normalize(mouse_pos - g.player.pos, {0, -1})
        rl.DrawLineV(player_screen_pos, player_screen_pos + dir * 24.0, rl.LIME)
    }

    // --- Draw Projectiles (With Bullet-Time Wakes) ---
    for i in 0 ..< g.projectile_count {
        p := &g.projectiles[i]
        if g.player.is_slowmo && p.is_enemy && g.player.slowmo_factor > 0.08 {
            v_len := linalg.length(p.vel)
            if v_len > 1.0 {
                v_dir := p.vel / v_len
                trail_len := 16.0 * g.player.slowmo_factor
                wake_col := rl.Color{0, 255, 160, u8(clamp(g.player.slowmo_factor * 160.0, 0, 200))}
                rl.DrawLineV(p.pos + g.camera_offset, p.pos + g.camera_offset - v_dir * trail_len, wake_col)
                rl.DrawCircleLinesV(p.pos + g.camera_offset, p.radius + 3.0 * g.player.slowmo_factor, wake_col)
            }
        }
        rl.DrawCircleV(p.pos + g.camera_offset, p.radius, p.color)
    }

    // --- Draw Floating Texts (Zero-Allocation via Fiber Payloads) ---
    Floating_Draw_Ctx :: struct {
        cam_x: i32,
        cam_y: i32,
    }
    draw_ctx := Floating_Draw_Ctx{cam_x = cam_x, cam_y = cam_y}
    coroutine.scheduler_walk_tree(&g.sched, proc(f: ^coroutine.Fiber, depth: int, user_data: rawptr) {
        if f != nil && f.debug_name == "Floating Text" && f.status != .Unused && f.status != .Completed && f.status != .Aborted && f.status != .Failed {
            ft := (cast(^Floating_Text)&f.payload_storage[0])^
            ctx := (cast(^Floating_Draw_Ctx)user_data)^
            c := ft.color
            c.a = u8(clamp(ft.alpha * 255.0, 0, 255))
            text := string(ft.text_buf[:min(int(ft.text_len), FLOATING_TEXT_MAX_LEN)])
            cstr := fmt.ctprintf("%s", text)
            rl.DrawText(cstr, i32(ft.pos.x) + ctx.cam_x, i32(ft.pos.y) + ctx.cam_y, i32(ft.scale), c)
        }
    }, &draw_ctx)

    // ========================================================================
    // UI OVERLAY
    // ========================================================================

    boss_bar_w: f32 = 700.0
    boss_bar_h: f32 = 24.0
    boss_bar_x := (f32(SCREEN_WIDTH) - boss_bar_w) / 2.0
    boss_bar_y: f32 = 30.0

    rl.DrawRectangle(i32(boss_bar_x) - 4, i32(boss_bar_y) - 4, i32(boss_bar_w) + 8, i32(boss_bar_h) + 8, {10, 10, 15, 220})
    rl.DrawRectangle(i32(boss_bar_x), i32(boss_bar_y), i32(boss_bar_w), i32(boss_bar_h), {40, 40, 50, 255})
    curr_boss_w := (g.boss.hp / g.boss.max_hp) * boss_bar_w
    rl.DrawRectangle(i32(boss_bar_x), i32(boss_bar_y), i32(curr_boss_w), i32(boss_bar_h), g.boss.color)
    rl.DrawRectangleLines(i32(boss_bar_x), i32(boss_bar_y), i32(boss_bar_w), i32(boss_bar_h), rl.WHITE)

    boss_info := fmt.ctprintf("BOSS: %s (HP: %.0f / %.0f)", g.boss.phase_name, g.boss.hp, g.boss.max_hp)
    rl.DrawText(boss_info, i32(boss_bar_x) + 10, i32(boss_bar_y) + 4, 16, rl.BLACK)

    player_bar_w: f32 = 240.0
    player_bar_h: f32 = 16.0
    player_bar_x: f32 = 30.0
    base_y := f32(SCREEN_HEIGHT) - 78.0

    slowmo_y := base_y
    rl.DrawRectangle(i32(player_bar_x) - 2, i32(slowmo_y) - 2, i32(player_bar_w) + 4, i32(player_bar_h) + 4, {10, 20, 15, 200})
    rl.DrawRectangle(i32(player_bar_x), i32(slowmo_y), i32(player_bar_w), i32(player_bar_h), {25, 40, 30, 255})
    curr_slowmo_w := (g.player.slowmo_charge / g.player.slowmo_max) * player_bar_w
    slowmo_bar_col := g.player.is_slowmo ? rl.Color{0, 255, 140, 255} : rl.Color{0, 200, 100, 255}
    rl.DrawRectangle(i32(player_bar_x), i32(slowmo_y), i32(curr_slowmo_w), i32(player_bar_h), slowmo_bar_col)
    border_col := g.player.is_slowmo ? rl.WHITE : rl.Color{0, 220, 120, 255}
    rl.DrawRectangleLines(i32(player_bar_x), i32(slowmo_y), i32(player_bar_w), i32(player_bar_h), border_col)

    speed_pct := (1.0 - (1.0 - 0.15) * g.player.slowmo_factor) * 100.0
    slowmo_label := fmt.ctprintf("SLOWMO: %.0f%% (WORLD: %.0f%%)", g.player.slowmo_charge, speed_pct)
    rl.DrawText(slowmo_label, i32(player_bar_x) + 6, i32(slowmo_y) + 2, 12, rl.BLACK)

    hp_y := base_y + 22.0
    rl.DrawRectangle(i32(player_bar_x) - 2, i32(hp_y) - 2, i32(player_bar_w) + 4, i32(player_bar_h) + 4, {15, 15, 20, 200})
    rl.DrawRectangle(i32(player_bar_x), i32(hp_y), i32(player_bar_w), i32(player_bar_h), {40, 40, 50, 255})
    curr_hp_w := (g.player.hp / g.player.max_hp) * player_bar_w
    rl.DrawRectangle(i32(player_bar_x), i32(hp_y), i32(curr_hp_w), i32(player_bar_h), rl.GREEN)
    rl.DrawRectangleLines(i32(player_bar_x), i32(hp_y), i32(player_bar_w), i32(player_bar_h), rl.WHITE)
    rl.DrawText(fmt.ctprintf("HP: %.0f/%.0f", g.player.hp, g.player.max_hp), i32(player_bar_x) + 6, i32(hp_y) + 2, 12, rl.BLACK)

    dash_text := g.player.can_dash ? "DASH: READY [SPACE]" : (g.player.is_dashing ? "DASH: ACTIVE" : fmt.tprintf("DASH: %.1fs", g.player.dash_cooldown))
    dash_color := g.player.can_dash ? rl.SKYBLUE : (g.player.is_dashing ? rl.LIME : rl.GRAY)
    rl.DrawText(fmt.ctprintf("%s", dash_text), i32(player_bar_x), i32(base_y) - 20, 15, dash_color)
    rl.DrawText("SLOWMO: [HOLD RMB]", i32(player_bar_x) + 170, i32(base_y) - 20, 13, g.player.is_slowmo ? rl.LIME : rl.DARKGREEN)

    active_fibers := 0
    for f in g.sched.fiber_pool.all_fibers {
        if f.status != .Unused do active_fibers += 1
    }

    emp_label := "EMP [E/B/X]: READY"
    emp_col := rl.ORANGE
    if g.boss.is_stunned {
        emp_label = "EMP [E/B/X]: BOSS STUNNED"
        emp_col = rl.YELLOW
    } else if g.player.emp_cooldown > 0.0 {
        emp_label = fmt.tprintf("EMP [E/B/X]: %.1fs", g.player.emp_cooldown)
        emp_col = rl.GRAY
    }

    diag_y: i32 = 20
    rl.DrawText(fmt.ctprintf("FPS: %d", rl.GetFPS()), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Active Fibers (Coroutines): %d", active_fibers), SCREEN_WIDTH - 280, diag_y, 16, rl.YELLOW); diag_y += 22
    rl.DrawText(fmt.ctprintf("%s", emp_label), SCREEN_WIDTH - 280, diag_y, 16, emp_col); diag_y += 22
    rl.DrawText(fmt.ctprintf("Timer Min-Heap: %d items", len(g.sched.clocks[coroutine.CLOCK_SIM].timer_heap)), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("World Speed: %.0f%%", speed_pct), SCREEN_WIDTH - 280, diag_y, 16, g.player.is_slowmo ? rl.LIME : rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Ready Queue: %d", len(g.sched.ready_queue)), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Projectiles: %d", g.projectile_count), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22

    if g.is_paused {
        flash_col := g.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD
        step_text := fmt.ctprintf("PAUSED: Step #%d (+%.3fs) | Sim: %.3fs | N / .: 1-Frame | M: 10-Frames | Hold N: Slow-Mo | P: Resume", g.step_count, g.last_step_dt, g.game_time)
        rl.DrawRectangle(25, SCREEN_HEIGHT - 32, 900, 24, {15, 18, 30, 220})
        rl.DrawRectangleLines(25, SCREEN_HEIGHT - 32, 900, 24, flash_col)
        rl.DrawText(step_text, 35, SCREEN_HEIGHT - 28, 14, flash_col)
    } else {
        rl.DrawText("WASD: Move | LMB/J: Shoot | Space: Dash | RMB: Matrix Slowmo | E/B: EMP | H/Tab: Hierarchy | P: Pause | R: Restart", 30, SCREEN_HEIGHT - 22, 13, rl.LIGHTGRAY)
    }

    // --- Live Coroutine Hierarchy Visualizer Overlay (H / TAB / F1) ---
    if g.show_coroutine_debugger {
        panel_x: i32 = 25
        panel_y: i32 = 140
        panel_w: i32 = 620
        panel_h: i32 = 520

        rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 14, 22, 235})
        rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {0, 200, 255, 200})

        pause_header := ""
        if g.is_paused {
            pause_header = fmt.tprintf("[PAUSED #%d (Sim: %.2fs) | N: 1F, M: 10F]", g.step_count, g.game_time)
        }
        rl.DrawText(fmt.ctprintf("COROUTINE HIERARCHY DEBUGGER (H / TAB) %s", pause_header), panel_x + 15, panel_y + 12, 15, g.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD)

        stats := coroutine.scheduler_pool_stats(&g.sched)
        stats_text := fmt.ctprintf("Pool: %d Slabs | Stacks: %d | Active: %d | Free: %d | Memory: %d KB", stats.slabs_count, stats.total_stacks, stats.active_fibers, stats.free_fibers, stats.total_memory_kb)
        rl.DrawText(stats_text, panel_x + 15, panel_y + 32, 11, rl.SKYBLUE)

        rl.DrawLine(panel_x + 10, panel_y + 48, panel_x + panel_w - 10, panel_y + 48, {60, 80, 120, 255})

        Tree_Draw_Ctx :: struct {
            cur_y: i32,
            max_y: i32,
        }
        draw_ctx := Tree_Draw_Ctx{
            cur_y = panel_y + 58,
            max_y = panel_y + panel_h - 25,
        }

        coroutine.scheduler_walk_tree(&g.sched, proc(f: ^coroutine.Fiber, depth: int, user_data: rawptr) {
            ctx := cast(^Tree_Draw_Ctx)user_data
            if f == nil || ctx.cur_y > ctx.max_y do return

            indent := i32(depth * 18)
            name := f.debug_name != "" ? f.debug_name : "Fiber"

            status_str := ""
            status_col := rl.RAYWHITE
            cid := f.clock_id >= 0 && int(f.clock_id) < coroutine.MAX_CLOCKS ? f.clock_id : coroutine.CLOCK_SIM
            clock_label := "SIM"
            switch cid {
            case coroutine.CLOCK_SIM:  clock_label = "SIM"
            case coroutine.CLOCK_REAL: clock_label = "REAL"
            case CLOCK_PLAYER:         clock_label = "PLYR"
            case:                      clock_label = fmt.tprintf("C%d", cid)
            }
            #partial switch f.status {
            case .Running:
                status_str = "Running"
                status_col = rl.GREEN
            case .Ready:
                status_str = "Ready"
                status_col = rl.YELLOW
            case .Sleeping_Time:
                left := max(0.0, f.wake_time - f.sched.clocks[cid].time)
                status_str = fmt.tprintf("Sleeping_Time [%s] (%.2fs left)", clock_label, left)
                status_col = cid == coroutine.CLOCK_REAL ? rl.PINK : (cid == CLOCK_PLAYER ? rl.LIME : rl.SKYBLUE)
            case .Sleeping_Steps:
                cur_s := f.sched.clocks[cid].steps
                left := f.wake_step > cur_s ? f.wake_step - cur_s : 0
                status_str = fmt.tprintf("Sleeping_Steps [%s] (%d steps)", clock_label, left)
                status_col = cid == CLOCK_PLAYER ? rl.LIME : rl.SKYBLUE
            case .Suspended_Join:
                kind := "Sync"
                switch f.active_coord.kind {
                case .Sync: kind = "Sync"
                case .Race: kind = "Race"
                case .Rush: kind = "Rush"
                case .Guard: kind = "Guard"
                }
                status_str = fmt.tprintf("Suspended_Join (%s, %d branches)", kind, f.active_coord.active_branches)
                status_col = rl.PURPLE
            case:
                status_str = fmt.tprintf("%v", f.status)
                status_col = rl.GRAY
            }

            used, total := coroutine.fiber_calc_stack_usage(f)
            pct := total > 0 ? f32(used) / f32(total) * 100.0 : 0.0
            resumes := coroutine.fiber_resume_count(f)

            prefix := depth > 0 ? "├─ " : "▼ "
            when ODIN_ARCH == .wasm32 {
                a_used, a_total := coroutine.fiber_calc_asyncify_usage(f)
                row_text := fmt.tprintf("%s[#%d] %s: %s | Stack: %.1fKB/%.0fKB (%.1f%%) | Asyncify: %.1fKB/%.0fKB | Resumes: %d", prefix, f.handle, name, status_str, f32(used)/1024.0, f32(total)/1024.0, pct, f32(a_used)/1024.0, f32(a_total)/1024.0, resumes)
            } else {
                row_text := fmt.tprintf("%s[#%d] %s: %s | Stack: %.1fKB/%.0fKB (%.1f%%) | Resumes: %d", prefix, f.handle, name, status_str, f32(used)/1024.0, f32(total)/1024.0, pct, resumes)
            }
            rl.DrawText(fmt.ctprintf("%s", row_text), 40 + indent, ctx.cur_y, 12, status_col)
            ctx.cur_y += 18
        }, &draw_ctx)
    }

    if g.game_over {
        rl.DrawRectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, {0, 0, 0, 180})
        rl.DrawText("GAME OVER", SCREEN_WIDTH/2 - 140, SCREEN_HEIGHT/2 - 40, 48, rl.RED)
        rl.DrawText("Press R or ENTER to Restart", SCREEN_WIDTH/2 - 140, SCREEN_HEIGHT/2 + 20, 20, rl.RAYWHITE)
    }

    if g.victory {
        rl.DrawRectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, {0, 0, 0, 180})
        rl.DrawText("VICTORY ACHIEVED!", SCREEN_WIDTH/2 - 240, SCREEN_HEIGHT/2 - 40, 48, rl.GOLD)
        rl.DrawText("All Boss AI Coroutines Terminated Cleanly", SCREEN_WIDTH/2 - 200, SCREEN_HEIGHT/2 + 20, 20, rl.GREEN)
        rl.DrawText("Press R or ENTER to Play Again", SCREEN_WIDTH/2 - 150, SCREEN_HEIGHT/2 + 55, 20, rl.RAYWHITE)
    }

    rl.EndDrawing()
}
