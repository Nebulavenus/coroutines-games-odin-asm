package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import rl "vendor:raylib"

import "coroutine"

// ============================================================================
// Game State & Entity Structures
// ============================================================================

SCREEN_WIDTH  :: 1280
SCREEN_HEIGHT :: 720

Projectile :: struct {
    pos:      rl.Vector2,
    vel:      rl.Vector2,
    radius:   f32,
    color:    rl.Color,
    is_enemy: bool,
    alive:    bool,
}

Floating_Text :: struct {
    text:  string,
    pos:   rl.Vector2,
    color: rl.Color,
    alpha: f32,
    scale: f32,
}

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
    pos:          rl.Vector2,
    speed:        f32,
    radius:       f32,
    hp:           f32,
    max_hp:       f32,
    can_dash:     bool,
    is_dashing:   bool,
    dash_cooldown: f32,
    scope:        coroutine.Fiber_Scope,
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
    director:     coroutine.Phase_Director,
    stun_signal:  coroutine.Signal,
    alive:        bool,
}

Game :: struct {
    sched:          coroutine.Scheduler,
    player:         Player,
    boss:           Boss,
    projectiles:    [dynamic]Projectile,
    particles:      [dynamic]Particle,
    camera_offset:           rl.Vector2,
    game_time:               f32,
    show_coroutine_debugger: bool,
    game_over:               bool,
    victory:                 bool,
    step_count:              int,
    step_flash_timer:        f32,
    last_step_dt:            f32,
    hold_step_timer:         f32,
    latched_dash:            bool,
    latched_shoot:           bool,
}

// Global Game Reference for Coroutines
g_game: ^Game

// ============================================================================
// Particle & Visual Helpers
// ============================================================================

spawn_particles :: proc(pos: rl.Vector2, count: int, color: rl.Color) {
    for _ in 0 ..< count {
        angle := rand.float32_range(0, math.TAU)
        spd := rand.float32_range(50, 250)
        p := Particle{
            pos      = pos,
            vel      = {math.cos(angle) * spd, math.sin(angle) * spd},
            color    = color,
            alpha    = 1.0,
            size     = rand.float32_range(3, 8),
            lifetime = rand.float32_range(0.3, 0.7),
            alive    = true,
        }
        append(&g_game.particles, p)
    }
}

spawn_projectile :: proc(pos, vel: rl.Vector2, radius: f32, color: rl.Color, is_enemy: bool) {
    p := Projectile{
        pos      = pos,
        vel      = vel,
        radius   = radius,
        color    = color,
        is_enemy = is_enemy,
        alive    = true,
    }
    append(&g_game.projectiles, p)
}

// ============================================================================
// Coroutines: Player Abilities & Camera Effects
// ============================================================================

camera_shake_coroutine :: proc(f: ^coroutine.Fiber, intensity: f32) {
    dur: f32 = 0.3
    elapsed: f32 = 0.0

    for elapsed < dur {
        coroutine.yield_frame(f)
        elapsed += coroutine.delta_time(f)
        decay := clamp(1.0 - (elapsed / dur), 0.0, 1.0)
        curr := intensity * decay
        if curr > 0.0 {
            g_game.camera_offset = {
                rand.float32_range(-curr, curr),
                rand.float32_range(-curr, curr),
            }
        } else {
            g_game.camera_offset = {0, 0}
        }
    }
    g_game.camera_offset = {0, 0}
}

trigger_camera_shake :: proc(intensity: f32) {
    coroutine.spawn(&g_game.sched, camera_shake_coroutine, intensity)
}

floating_text_coroutine :: proc(f: ^coroutine.Fiber, ft: Floating_Text) {
    curr_ft := ft
    start_y := curr_ft.pos.y
    target_y := start_y - 45.0

    // Tween upward position with juicy back-easing and fade out
    dur: f32 = 0.8
    elapsed: f32 = 0.0
    for elapsed < dur {
        coroutine.yield_frame(f)
        elapsed += coroutine.delta_time(f)
        t := clamp(elapsed / dur, 0.0, 1.0)
        eased_t := coroutine.ease_out_back(t)
        curr_ft.pos.y = start_y + (target_y - start_y) * eased_t
        curr_ft.alpha = 1.0 - t
        (cast(^Floating_Text)&f.payload_storage[0])^ = curr_ft
    }
}

spawn_floating_text :: proc(text: string, pos: rl.Vector2, color: rl.Color = rl.GOLD, scale: f32 = 18.0) {
    if g_game == nil do return
    ft := Floating_Text{
        text  = text,
        pos   = pos + {rand.float32_range(-20, 20), rand.float32_range(-10, 10)},
        color = color,
        alpha = 1.0,
        scale = scale,
    }
    coroutine.spawn(&g_game.sched, floating_text_coroutine, ft, name = "Floating Text")
}

player_dash_coroutine :: proc(f: ^coroutine.Fiber, p: ^Player) {
    if !p.can_dash || p.is_dashing do return
    p.can_dash = false
    p.is_dashing = true

    // Dash burst speed
    orig_speed := p.speed
    p.speed *= 3.2
    trigger_camera_shake(5.0)
    spawn_particles(p.pos, 15, rl.SKYBLUE)

    // Dash duration
    coroutine.wait(f, 0.18)

    // Restore speed
    p.speed = orig_speed
    p.is_dashing = false

    // Dash Cooldown
    coroutine.wait(f, 0.8)
    p.can_dash = true
}

// ============================================================================
// Coroutines: Hierarchical Multi-Phase Boss AI (Pure Structured Concurrency)
// ============================================================================

boss_patrol_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    center_x := f32(SCREEN_WIDTH) / 2.0
    for {
        coroutine.tween(f, &b.pos.x, center_x, center_x + 350.0, 2.0, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.3)
        coroutine.tween(f, &b.pos.x, center_x + 350.0, center_x - 350.0, 4.0, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.3)
        coroutine.tween(f, &b.pos.x, center_x - 350.0, center_x, 2.0, coroutine.ease_in_out_quad)
        coroutine.wait(f, 0.3)
    }
}

boss_spiral_shoot_subloop :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    angle_offset: f32 = 0.0
    ticker: coroutine.Ticker
    coroutine.ticker_init(&ticker, 0.25)

    for {
        coroutine.ticker_wait(f, &ticker)
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

        // Fire 3 targeted bursts towards player using a precision zero-drift Ticker
        burst_ticker: coroutine.Ticker
        coroutine.ticker_init(&burst_ticker, 0.12)
        for _ in 0 ..< 3 {
            coroutine.ticker_wait(f, &burst_ticker)
            dir := linalg.normalize(g_game.player.pos - b.pos)
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

        // Rapid 360 ring burst
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

boss_attack_loop_phase1 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.hp > 700.0 && b.alive && b.phase == 1 {
        winner := coroutine.race(f,
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.sync(f,
                    coroutine.branch(boss_spiral_shoot_subloop, b, "Spiral Shoot Loop"),
                    coroutine.branch(boss_targeted_burst_subloop, b, "Targeted Burst Loop"),
                )
            }, b, "Phase 1 Attacks"),
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.signal_wait(f, &b.stun_signal)
            }, b, "Stun Signal Watcher"),
        )

        if winner == 1 && b.hp > 700.0 && b.alive && b.phase == 1 {
            spawn_floating_text("BOSS STUNNED!", b.pos, rl.YELLOW)
            b.color = rl.DARKGRAY
            coroutine.wait(f, 1.5)
            if b.alive && b.phase == 1 do b.color = rl.GOLD
        }
    }
}

boss_attack_loop_phase2 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.hp > 350.0 && b.alive && b.phase == 2 {
        winner := coroutine.race(f,
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.sync(f,
                    coroutine.branch(boss_enraged_laser_sweep, b, "Laser Sweep"),
                    coroutine.branch(boss_targeted_burst_subloop, b, "Targeted Burst"),
                )
            }, b, "Phase 2 Attacks"),
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.signal_wait(f, &b.stun_signal)
            }, b, "Stun Signal Watcher"),
        )

        if winner == 1 && b.hp > 350.0 && b.alive && b.phase == 2 {
            spawn_floating_text("BOSS STUNNED!", b.pos, rl.YELLOW)
            b.color = rl.DARKGRAY
            coroutine.wait(f, 1.5)
            if b.alive && b.phase == 2 do b.color = rl.SKYBLUE
        }
    }
}

boss_attack_loop_phase3 :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    for b.alive && b.phase == 3 {
        winner := coroutine.race(f,
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.sync(f,
                    coroutine.branch(boss_spiral_shoot_subloop, b, "Enraged Spiral"),
                    coroutine.branch(boss_enraged_laser_sweep, b, "Enraged Nova"),
                    coroutine.branch(boss_targeted_burst_subloop, b, "Rapid Targeted Fire"),
                )
            }, b, "Phase 3 Attacks"),
            coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
                coroutine.signal_wait(f, &b.stun_signal)
            }, b, "Stun Signal Watcher"),
        )

        if winner == 1 && b.alive && b.phase == 3 {
            spawn_floating_text("BOSS STUNNED!", b.pos, rl.YELLOW)
            b.color = rl.DARKGRAY
            coroutine.wait(f, 1.0)
            if b.alive && b.phase == 3 do b.color = rl.RED
        }
    }
}

// Master Boss AI Timeline
boss_master_ai :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    center_x := f32(SCREEN_WIDTH) / 2.0
    center_y := f32(180.0)

    // ========================================================================
    // PHASE 1: Patrol + Spiral Bullet Barrage (Runs until HP < 700)
    // ========================================================================
    coroutine.fiber_set_name(f, "Boss AI: Phase 1 (Spiral Barrage)")
    b.phase = 1
    b.phase_name = "Phase 1: Spiral Barrage"
    b.color = rl.GOLD
    spawn_floating_text("PHASE 1: ENGAGED", b.pos, rl.GOLD)

    coroutine.race(f,
        // Condition branch: End Phase 1 when HP < 700
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.wait_while(f, proc(b: ^Boss) -> bool {
                return b.hp > 700.0 && b.alive
            }, b)
        }, b, "HP < 700 Trigger"),

        coroutine.branch(boss_patrol_subloop, b, "Patrol Loop"),
        coroutine.branch(boss_attack_loop_phase1, b, "Phase 1 Attack Loop"),
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

    // 1. Move to Center
    coroutine.tween(f, &b.pos, b.pos, [2]f32{f32(SCREEN_WIDTH) / 2.0, 180.0}, 1.0, coroutine.ease_in_out_cubic)

    // 2. Shield Charge Cinematic
    coroutine.sync(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.tween(f, &b.shield_alpha, 0.0, 0.85, 1.2, coroutine.ease_in_out_quad)
            coroutine.wait(f, 0.5)
            coroutine.tween(f, &b.shield_alpha, 0.85, 0.0, 0.3)
        }, b, "Shield Tween"),
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            for _ in 0 ..< 10 {
                spawn_particles(b.pos, 8, rl.SKYBLUE)
                coroutine.wait(f, 0.15)
            }
        }, b, "Charge Particles"),
    )

    // 3. Super Radial Blast
    trigger_camera_shake(15.0)
    spawn_floating_text("SUPER NOVA BURST!", b.pos, rl.VIOLET)
    for i in 0 ..< 32 {
        a := f32(i) * (math.TAU / 32.0)
        dir := rl.Vector2{math.cos(a), math.sin(a)}
        spawn_projectile(b.pos, dir * 280.0, 10.0, rl.PURPLE, true)
    }

    // 4. Phase 2 Combat Loop until HP < 350
    coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.wait_while(f, proc(b: ^Boss) -> bool {
                return b.hp > 350.0 && b.alive
            }, b)
        }, b, "HP < 350 Trigger"),

        coroutine.branch(boss_patrol_subloop, b, "Patrol Subloop"),
        coroutine.branch(boss_attack_loop_phase2, b, "Phase 2 Attack Loop"),
    )

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

    coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.wait_while(f, proc(b: ^Boss) -> bool {
                return b.alive
            }, b)
        }, b, "Boss Death Trigger"),

        coroutine.branch(boss_patrol_subloop, b, "Patrol Subloop"),
        coroutine.branch(boss_attack_loop_phase3, b, "Phase 3 Attack Loop"),
    )
}

// ============================================================================
// Main Game Update & Render
// ============================================================================

game_init :: proc(g: ^Game) {
    coroutine.scheduler_init(&g.sched)
    coroutine.scheduler_prewarm(&g.sched, 64)

    g.player = Player{
        pos           = {f32(SCREEN_WIDTH) / 2.0, f32(SCREEN_HEIGHT) - 100.0},
        speed         = 320.0,
        radius        = 18.0,
        hp            = 400.0,
        max_hp        = 400.0,
        can_dash      = true,
        is_dashing    = false,
        dash_cooldown = 0.0,
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
        alive        = true,
    }

    g.projectiles = make([dynamic]Projectile)
    g.particles = make([dynamic]Particle)
    g.camera_offset = {0, 0}
    g.game_time = 0.0
    g.game_over = false
    g.victory = false

    g_game = g

    // Initialize Boss Phase Director & Spawn Boss AI timeline coroutine
    coroutine.phase_director_init(&g.boss.director, &g.sched)
    coroutine.spawn(&g.sched, boss_master_ai, &g.boss, scope = &g.boss.scope, name = "Boss AI Timeline")
}

game_destroy :: proc(g: ^Game) {
    coroutine.signal_destroy(&g.boss.stun_signal)
    coroutine.phase_director_destroy(&g.boss.director)
    coroutine.scope_destroy(&g.sched, &g.player.scope)
    coroutine.scope_destroy(&g.sched, &g.boss.scope)
    coroutine.scheduler_destroy(&g.sched)
    delete(g.projectiles)
    delete(g.particles)
}

game_update :: proc(g: ^Game, dt: f32) {
    if rl.IsKeyPressed(.F3) {
        coroutine.scheduler_set_paused(&g.sched, !coroutine.scheduler_is_paused(&g.sched))
    }

    if rl.IsKeyPressed(.F1) || rl.IsKeyPressed(.TAB) {
        g.show_coroutine_debugger = !g.show_coroutine_debugger
    }

    // Determine simulation delta-time for this frame
    sim_dt: f32 = 0.0

    if !coroutine.scheduler_is_paused(&g.sched) {
        sim_dt = dt
        g.step_flash_timer = 0.0
    } else {
        // Paused state: check for single-step, 10-frame jump, or slow-motion hold
        if g.step_flash_timer > 0.0 {
            g.step_flash_timer = max(0.0, g.step_flash_timer - dt)
        }

        if rl.IsKeyPressed(.F4) {
            sim_dt = 0.016
            g.step_count += 1
            g.last_step_dt = sim_dt
            g.step_flash_timer = 0.4
        } else if rl.IsKeyPressed(.F5) || (rl.IsKeyDown(.LEFT_SHIFT) && rl.IsKeyPressed(.F4)) {
            sim_dt = 0.160 // 10 frames (~160ms jump)
            g.step_count += 10
            g.last_step_dt = sim_dt
            g.step_flash_timer = 0.5
        } else if rl.IsKeyDown(.F4) {
            // Slow-motion continuous step when holding F4 (~15 FPS slow-mo)
            g.hold_step_timer += dt
            if g.hold_step_timer >= 0.066 {
                g.hold_step_timer = 0.0
                sim_dt = 0.016
                g.step_count += 1
                g.last_step_dt = sim_dt
                g.step_flash_timer = 0.2
            }
        } else {
            g.hold_step_timer = 0.0
        }
    }

    // Latch actions while paused or running
    if rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.RIGHT) {
        g.latched_dash = true
    }
    if rl.IsMouseButtonPressed(.LEFT) || rl.IsKeyPressed(.J) || rl.IsKeyPressed(.Z) {
        g.latched_shoot = true
    }

    // If simulation is completely paused with no step this frame, pump real-time clock and halt world updates
    if sim_dt <= 0.0 {
        coroutine.scheduler_step(&g.sched, dt)
        return
    }

    g.game_time += sim_dt

    // Step the Coroutine Engine
    if !coroutine.scheduler_is_paused(&g.sched) {
        coroutine.scheduler_step(&g.sched, sim_dt)
    } else {
        coroutine.scheduler_single_step(&g.sched, sim_dt)
    }

    if g.game_over || g.victory do return

    // --- Player Input & Movement ---
    move_dir := rl.Vector2{0, 0}
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    do move_dir.y -= 1
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  do move_dir.y += 1
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  do move_dir.x -= 1
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move_dir.x += 1

    if linalg.length(move_dir) > 0 {
        move_dir = linalg.normalize(move_dir)
        g.player.pos += move_dir * g.player.speed * sim_dt
    }

    // Clamp Player to screen bounds
    g.player.pos.x = clamp(g.player.pos.x, g.player.radius, f32(SCREEN_WIDTH) - g.player.radius)
    g.player.pos.y = clamp(g.player.pos.y, g.player.radius, f32(SCREEN_HEIGHT) - g.player.radius)

    // Player Dash Trigger (Space, Right Mouse or Latched)
    do_dash := g.latched_dash || rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.RIGHT)
    g.latched_dash = false
    if do_dash && g.player.can_dash && !coroutine.scope_is_busy(&g.player.scope) {
        coroutine.spawn(&g.sched, player_dash_coroutine, &g.player, scope = &g.player.scope, name = "Player Dash")
    }

    // Player EMP Parry Burst (B key / X key): Stun Boss directly via Signal & vaporize bullets!
    if rl.IsKeyPressed(.B) || rl.IsKeyPressed(.X) {
        coroutine.signal_emit(&g.sched, &g.boss.stun_signal)
        bullets_destroyed := 0
        for i := len(g.projectiles) - 1; i >= 0; i -= 1 {
            if g.projectiles[i].is_enemy {
                spawn_particles(g.projectiles[i].pos, 10, rl.GOLD)
                unordered_remove(&g.projectiles, i)
                bullets_destroyed += 1
            }
        }
        trigger_camera_shake(16.0)
        spawn_particles(g.player.pos, 50, rl.GOLD)
        spawn_floating_text(fmt.tprintf("EMP PARRY! Stunned Boss (%d Bullets Vaporized)", bullets_destroyed), g.player.pos, rl.GOLD)
    }

    // Player Shooting (Left Click, J/Z, or Latched)
    is_shooting := g.latched_shoot || rl.IsMouseButtonDown(.LEFT) || rl.IsKeyDown(.J) || rl.IsKeyDown(.Z)
    g.latched_shoot = false
    if is_shooting {
        if math.mod(g.game_time, 0.12) < sim_dt || sim_dt >= 0.12 {
            mouse_pos := rl.GetMousePosition()
            shoot_dir := rl.Vector2{0, -1}
            if linalg.length(mouse_pos - g.player.pos) > 10.0 {
                shoot_dir = linalg.normalize(mouse_pos - g.player.pos)
            }
            spawn_projectile(g.player.pos, shoot_dir * 650.0, 6.0, rl.GREEN, false)
            spawn_particles(g.player.pos, 2, rl.LIME)
        }
    }

    // --- Update Projectiles ---
    for i := len(g.projectiles) - 1; i >= 0; i -= 1 {
        p := &g.projectiles[i]
        if !p.alive {
            unordered_remove(&g.projectiles, i)
            continue
        }
        p.pos += p.vel * sim_dt

        // Check Out of bounds
        if p.pos.x < -50 || p.pos.x > SCREEN_WIDTH + 50 || p.pos.y < -50 || p.pos.y > SCREEN_HEIGHT + 50 {
            unordered_remove(&g.projectiles, i)
            continue
        }

        // Collision: Player projectile -> Boss
        if !p.is_enemy && g.boss.alive {
            if linalg.length(p.pos - g.boss.pos) < (p.radius + g.boss.radius) {
                // If boss shield is up, reduce damage
                dmg: f32 = 12.0
                if g.boss.shield_alpha > 0.3 {
                    dmg = 2.0
                    spawn_floating_text("BLOCKED!", g.boss.pos + {rand.float32_range(-30, 30), -50}, rl.SKYBLUE)
                } else {
                    spawn_floating_text(fmt.tprintf("-%.0f", dmg), g.boss.pos + {rand.float32_range(-40, 40), -40}, rl.YELLOW)
                }
                g.boss.hp -= dmg
                spawn_particles(p.pos, 6, rl.GOLD)
                unordered_remove(&g.projectiles, i)

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

        // Collision: Enemy projectile -> Player
        if p.is_enemy && !g.player.is_dashing {
            if linalg.length(p.pos - g.player.pos) < (p.radius + g.player.radius) {
                dmg: f32 = 15.0
                g.player.hp -= dmg
                spawn_floating_text(fmt.tprintf("-%.0f", dmg), g.player.pos + {0, -30}, rl.RED)
                trigger_camera_shake(6.0)
                spawn_particles(g.player.pos, 12, rl.RED)
                unordered_remove(&g.projectiles, i)

                if g.player.hp <= 0.0 {
                    g.player.hp = 0.0
                    g.game_over = true
                    coroutine.scope_cancel(&g.sched, &g.player.scope)
                    spawn_floating_text("GAME OVER", g.player.pos, rl.RED)
                }
                continue
            }
        }
    }

    // --- Update Particles ---
    for i := len(g.particles) - 1; i >= 0; i -= 1 {
        p := &g.particles[i]
        p.pos += p.vel * sim_dt
        p.alpha -= sim_dt * 2.0
        if p.alpha <= 0.0 {
            unordered_remove(&g.particles, i)
        }
    }
}

game_render :: proc(g: ^Game) {
    rl.BeginDrawing()
    rl.ClearBackground({18, 20, 30, 255})

    // Camera offset for shake
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
    for p in g.particles {
        c := p.color
        c.a = u8(clamp(p.alpha * 255.0, 0, 255))
        rl.DrawCircleV(p.pos + g.camera_offset, p.size, c)
    }

    // --- Draw Boss ---
    if g.boss.alive {
        boss_screen_pos := g.boss.pos + g.camera_offset
        // Boss body
        rl.DrawCircleV(boss_screen_pos, g.boss.radius, g.boss.color)
        rl.DrawCircleLinesV(boss_screen_pos, g.boss.radius + 4, rl.WHITE)

        // Shield aura
        if g.boss.shield_alpha > 0.01 {
            shield_col := rl.SKYBLUE
            shield_col.a = u8(g.boss.shield_alpha * 255.0)
            rl.DrawCircleV(boss_screen_pos, g.boss.radius + 20, shield_col)
        }

        // Boss eye/core
        rl.DrawCircleV(boss_screen_pos, 16.0, rl.BLACK)
        rl.DrawCircleV(boss_screen_pos, 8.0, rl.WHITE)
    }

    // --- Draw Player ---
    if g.player.hp > 0.0 {
        player_col := g.player.is_dashing ? rl.SKYBLUE : rl.GREEN
        player_screen_pos := g.player.pos + g.camera_offset
        rl.DrawCircleV(player_screen_pos, g.player.radius, player_col)
        rl.DrawCircleLinesV(player_screen_pos, g.player.radius + 2, rl.WHITE)

        // Direction indicator to mouse
        mouse_pos := rl.GetMousePosition()
        dir := linalg.normalize(mouse_pos - g.player.pos)
        rl.DrawLineV(player_screen_pos, player_screen_pos + dir * 24.0, rl.LIME)
    }

    // --- Draw Projectiles ---
    for p in g.projectiles {
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
            cstr := fmt.ctprintf(ft.text)
            rl.DrawText(cstr, i32(ft.pos.x) + ctx.cam_x, i32(ft.pos.y) + ctx.cam_y, i32(ft.scale), c)
        }
    }, &draw_ctx)

    // ========================================================================
    // UI OVERLAY
    // ========================================================================

    // 1. Boss HP Bar (Top)
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

    // 2. Player HP & Dash UI (Bottom Left)
    player_bar_w: f32 = 220.0
    player_bar_h: f32 = 18.0
    player_bar_x: f32 = 30.0
    player_bar_y := f32(SCREEN_HEIGHT) - 50.0

    rl.DrawRectangle(i32(player_bar_x), i32(player_bar_y), i32(player_bar_w), i32(player_bar_h), {40, 40, 50, 255})
    curr_hp_w := (g.player.hp / g.player.max_hp) * player_bar_w
    rl.DrawRectangle(i32(player_bar_x), i32(player_bar_y), i32(curr_hp_w), i32(player_bar_h), rl.GREEN)
    rl.DrawRectangleLines(i32(player_bar_x), i32(player_bar_y), i32(player_bar_w), i32(player_bar_h), rl.WHITE)
    rl.DrawText(fmt.ctprintf("HP: %.0f/%.0f", g.player.hp, g.player.max_hp), i32(player_bar_x) + 6, i32(player_bar_y) + 2, 14, rl.BLACK)

    // Dash indicator
    dash_text := g.player.can_dash ? "DASH: READY [SPACE / RMB]" : "DASH: RECHARGING..."
    dash_color := g.player.can_dash ? rl.SKYBLUE : rl.GRAY
    rl.DrawText(fmt.ctprintf(dash_text), i32(player_bar_x), i32(player_bar_y) - 24, 16, dash_color)

    // 3. Engine Diagnostics (Top Right)
    active_fibers := 0
    for f in g.sched.fiber_pool.all_fibers {
        if f.status != .Unused do active_fibers += 1
    }

    diag_y: i32 = 20
    rl.DrawText(fmt.ctprintf("FPS: %d", rl.GetFPS()), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Active Fibers (Coroutines): %d", active_fibers), SCREEN_WIDTH - 280, diag_y, 16, rl.YELLOW); diag_y += 22
    rl.DrawText(fmt.ctprintf("Boss Stun Signal: [B / X: EMP]"), SCREEN_WIDTH - 280, diag_y, 16, g.boss.color == rl.DARKGRAY ? rl.GRAY : rl.ORANGE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Timer Min-Heap: %d items", len(g.sched.timer_heap)), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Ready Queue: %d", len(g.sched.ready_queue)), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Projectiles: %d", len(g.projectiles)), SCREEN_WIDTH - 280, diag_y, 16, rl.RAYWHITE); diag_y += 22

    // Instructions & Pause Banner
    if coroutine.scheduler_is_paused(&g.sched) {
        flash_col := g.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD
        step_text := fmt.ctprintf("PAUSED: Step #%d (+%.3fs) | Sim Time: %.3fs | F4: 1-Frame | F5: 10-Frames | Hold F4: Slow-Mo", g.step_count, g.last_step_dt, g.game_time)
        rl.DrawRectangle(25, SCREEN_HEIGHT - 32, 850, 24, {15, 18, 30, 220})
        rl.DrawRectangleLines(25, SCREEN_HEIGHT - 32, 850, 24, flash_col)
        rl.DrawText(step_text, 35, SCREEN_HEIGHT - 28, 14, flash_col)
    } else {
        rl.DrawText("WASD: Move | LMB: Shoot | Space: Dash | B: EMP Parry | F1: Tree | F3: Pause | F4: Step 1F", 30, SCREEN_HEIGHT - 22, 13, rl.LIGHTGRAY)
    }

    // --- Live Coroutine Hierarchy Visualizer Overlay (F1 / TAB) ---
    if g.show_coroutine_debugger {
        panel_x: i32 = 25
        panel_y: i32 = 140
        panel_w: i32 = 620
        panel_h: i32 = 520

        rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 14, 22, 235})
        rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {0, 200, 255, 200})

        pause_header := ""
        if coroutine.scheduler_is_paused(&g.sched) {
            pause_header = fmt.tprintf("[PAUSED #%d (Sim: %.2fs) | F4: 1F, F5: 10F]", g.step_count, g.game_time)
        }
        rl.DrawText(fmt.ctprintf("COROUTINE HIERARCHY DEBUGGER (F1) %s", pause_header), panel_x + 15, panel_y + 12, 15, g.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD)

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
            #partial switch f.status {
            case .Running:
                status_str = "Running"
                status_col = rl.GREEN
            case .Ready:
                status_str = "Ready"
                status_col = rl.YELLOW
            case .Sleeping_Time:
                left := max(0.0, f.wake_time - f.sched.clock.sim_time)
                status_str = fmt.tprintf("Sleeping_Sim (%.2fs left)", left)
                status_col = rl.SKYBLUE
            case .Sleeping_Real_Time:
                left := max(0.0, f.wake_time - f.sched.clock.real_time)
                status_str = fmt.tprintf("Sleeping_Real (%.2fs left)", left)
                status_col = rl.PINK
            case .Sleeping_Ticks:
                left := f.wake_ticks > f.sched.clock.sim_ticks ? f.wake_ticks - f.sched.clock.sim_ticks : 0
                status_str = fmt.tprintf("Sleeping_Ticks (%d left)", left)
                status_col = rl.MAGENTA
            case .Sleeping_Frames:
                left := f.wake_frame > f.sched.clock.frame_count ? f.wake_frame - f.sched.clock.frame_count : 0
                status_str = fmt.tprintf("Sleeping_Frames (%d frames)", left)
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
                }
                status_str = fmt.tprintf("Suspended_Join (%s, %d branches)", kind, f.active_coord.active_branches)
                status_col = rl.PURPLE
            case:
                status_str = fmt.tprintf("%v", f.status)
                status_col = rl.GRAY
            }

            used, total := coroutine.fiber_calc_stack_usage(f)
            pct := f32(used) / f32(total) * 100.0

            prefix := depth > 0 ? "├─ " : "▼ "
            row_text := fmt.tprintf("%s[#%d] %s: %s | Stack: %.1fKB/%.0fKB (%.1f%%)", prefix, f.handle, name, status_str, f32(used)/1024.0, f32(total)/1024.0, pct)
            rl.DrawText(fmt.ctprintf("%s", row_text), 40 + indent, ctx.cur_y, 12, status_col)
            ctx.cur_y += 18
        }, &draw_ctx)
    }

    if g.game_over {
        rl.DrawRectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, {0, 0, 0, 180})
        rl.DrawText("GAME OVER", SCREEN_WIDTH/2 - 140, SCREEN_HEIGHT/2 - 40, 48, rl.RED)
        rl.DrawText("Press ESC to exit", SCREEN_WIDTH/2 - 80, SCREEN_HEIGHT/2 + 20, 20, rl.RAYWHITE)
    }

    if g.victory {
        rl.DrawRectangle(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, {0, 0, 0, 180})
        rl.DrawText("VICTORY ACHIEVED!", SCREEN_WIDTH/2 - 240, SCREEN_HEIGHT/2 - 40, 48, rl.GOLD)
        rl.DrawText("All Boss AI Coroutines Terminated Cleanly", SCREEN_WIDTH/2 - 200, SCREEN_HEIGHT/2 + 20, 20, rl.GREEN)
    }

    rl.EndDrawing()
}

// ============================================================================
// Main Application Entry
// ============================================================================

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

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "SkookumScript Concurrency Engine - Boss Fight Demo")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    game: Game
    game_init(&game)
    defer game_destroy(&game)

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        game_update(&game, dt)
        game_render(&game)
    }
}
