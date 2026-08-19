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
    pos:    rl.Vector2,
    vel:    rl.Vector2,
    radius: f32,
    color:  rl.Color,
    is_enemy: bool,
    alive:  bool,
}

Floating_Text :: struct {
    text:     string,
    pos:      rl.Vector2,
    color:    rl.Color,
    alpha:    f32,
    scale:    f32,
    lifetime: f32,
    alive:    bool,
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
    alive:        bool,
}

Game :: struct {
    sched:          coroutine.Scheduler,
    player:         Player,
    boss:           Boss,
    projectiles:    [dynamic]Projectile,
    floating_texts: [dynamic]Floating_Text,
    particles:      [dynamic]Particle,
    camera_offset:  rl.Vector2,
    game_time:      f32,
    game_over:      bool,
    victory:        bool,
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

camera_shake_coroutine :: proc(f: ^coroutine.Fiber, intensity: ^f32) {
    dur: f32 = 0.3
    elapsed: f32 = 0.0
    initial := intensity^

    for elapsed < dur {
        coroutine.yield_frame(f)
        elapsed += f.sched.delta_time
        decay := clamp(1.0 - (elapsed / dur), 0.0, 1.0)
        curr := initial * decay
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
    int_copy := new(f32)
    int_copy^ = intensity
    coroutine.spawn(&g_game.sched, proc(f: ^coroutine.Fiber, i: ^f32) {
        defer free(i)
        camera_shake_coroutine(f, i)
    }, int_copy)
}

floating_text_coroutine :: proc(f: ^coroutine.Fiber, ft_index_ptr: ^int) {
    idx := ft_index_ptr^
    if idx >= len(g_game.floating_texts) do return

    start_y := g_game.floating_texts[idx].pos.y
    target_y := start_y - 45.0

    // Tween upward position and fade out
    dur: f32 = 0.8
    elapsed: f32 = 0.0
    for elapsed < dur {
        coroutine.yield_frame(f)
        elapsed += f.sched.delta_time
        if idx >= len(g_game.floating_texts) || !g_game.floating_texts[idx].alive do break
        t := elapsed / dur
        g_game.floating_texts[idx].pos.y = math.lerp(start_y, target_y, t)
        g_game.floating_texts[idx].alpha = 1.0 - t
    }

    if idx < len(g_game.floating_texts) {
        g_game.floating_texts[idx].alive = false
    }
}

spawn_floating_text :: proc(text: string, pos: rl.Vector2, color: rl.Color) {
    ft := Floating_Text{
        text     = text,
        pos      = pos,
        color    = color,
        alpha    = 1.0,
        scale    = 20,
        lifetime = 0.8,
        alive    = true,
    }
    append(&g_game.floating_texts, ft)
    idx := len(g_game.floating_texts) - 1

    idx_ptr := new(int)
    idx_ptr^ = idx
    coroutine.spawn(&g_game.sched, proc(f: ^coroutine.Fiber, p: ^int) {
        defer free(p)
        floating_text_coroutine(f, p)
    }, idx_ptr)
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
// Coroutines: Hierarchical Multi-Phase Boss AI
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

        // Fire 3 targeted bursts towards player
        for _ in 0 ..< 3 {
            dir := linalg.normalize(g_game.player.pos - b.pos)
            vel := dir * 420.0
            spawn_projectile(b.pos, vel, 9.0, rl.RED, true)
            spawn_particles(b.pos, 5, rl.RED)
            coroutine.wait(f, 0.12)
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

// Master Boss AI Timeline
boss_master_ai :: proc(f: ^coroutine.Fiber, b: ^Boss) {
    center_x := f32(SCREEN_WIDTH) / 2.0
    center_y := f32(180.0)

    // ========================================================================
    // PHASE 1: Patrol + Spiral Bullet Barrage (Runs until HP < 700)
    // ========================================================================
    b.phase = 1
    b.phase_name = "Phase 1: Spiral Barrage"
    b.color = rl.GOLD
    spawn_floating_text("PHASE 1: ENGAGED", b.pos, rl.GOLD)

    coroutine.race(f,
        // Condition branch: End Phase 1 when HP < 700
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.wait_until(f, proc(b: ^Boss) -> bool {
                return b.hp <= 700.0 || !b.alive
            }, b)
        }, b, "HP < 700 Trigger"),

        // Parallel combat subroutines
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync(f,
                coroutine.branch(boss_patrol_subloop, b, "Patrol Loop"),
                coroutine.branch(boss_spiral_shoot_subloop, b, "Spiral Shoot Loop"),
                coroutine.branch(boss_targeted_burst_subloop, b, "Targeted Burst Loop"),
            )
        }, b, "Phase 1 Combat Sync"),
    )

    if !b.alive do return

    // ========================================================================
    // PHASE 2: Super Shield Charge & Radial Nova (Runs until HP < 350)
    // ========================================================================
    b.phase = 2
    b.phase_name = "Phase 2: Super Nova Charge"
    b.color = rl.SKYBLUE
    spawn_floating_text("PHASE 2: SHIELD CHARGE!", b.pos, rl.SKYBLUE)
    trigger_camera_shake(10.0)

    // 1. Move to Center
    coroutine.sync(f,
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.tween(f, &b.pos.x, b.pos.x, f32(SCREEN_WIDTH)/2.0, 1.0, coroutine.ease_in_out_cubic)
        }, b),
        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.tween(f, &b.pos.y, b.pos.y, 180.0, 1.0, coroutine.ease_in_out_cubic)
        }, b),
    )

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
            coroutine.wait_until(f, proc(b: ^Boss) -> bool {
                return b.hp <= 350.0 || !b.alive
            }, b)
        }, b, "HP < 350 Trigger"),

        coroutine.branch(proc(f: ^coroutine.Fiber, b: ^Boss) {
            coroutine.sync(f,
                coroutine.branch(boss_patrol_subloop, b, "Patrol Subloop"),
                coroutine.branch(boss_enraged_laser_sweep, b, "Laser Sweep"),
                coroutine.branch(boss_targeted_burst_subloop, b, "Targeted Burst"),
            )
        }, b, "Phase 2 Combat Sync"),
    )

    if !b.alive do return

    // ========================================================================
    // PHASE 3: Enraged Berserk Mode (HP <= 350)
    // ========================================================================
    b.phase = 3
    b.phase_name = "Phase 3: BERSERK ENRAGED"
    b.color = rl.RED
    spawn_floating_text("PHASE 3: BERSERK MODE!", b.pos, rl.RED)
    trigger_camera_shake(20.0)

    coroutine.sync(f,
        coroutine.branch(boss_spiral_shoot_subloop, b, "Enraged Spiral"),
        coroutine.branch(boss_enraged_laser_sweep, b, "Enraged Nova"),
        coroutine.branch(boss_targeted_burst_subloop, b, "Rapid Targeted Fire"),
    )
}

// ============================================================================
// Main Game Update & Render
// ============================================================================

game_init :: proc(g: ^Game) {
    coroutine.scheduler_init(&g.sched)

    g.player = Player{
        pos           = {f32(SCREEN_WIDTH) / 2.0, f32(SCREEN_HEIGHT) - 100.0},
        speed         = 320.0,
        radius        = 18.0,
        hp            = 100.0,
        max_hp        = 100.0,
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
    g.floating_texts = make([dynamic]Floating_Text)
    g.particles = make([dynamic]Particle)
    g.camera_offset = {0, 0}
    g.game_time = 0.0
    g.game_over = false
    g.victory = false

    g_game = g

    // Spawn Boss AI timeline coroutine
    coroutine.spawn(&g.sched, boss_master_ai, &g.boss, scope = &g.boss.scope, name = "Boss AI Timeline")
}

game_destroy :: proc(g: ^Game) {
    coroutine.scope_destroy(&g.player.scope)
    coroutine.scope_destroy(&g.boss.scope)
    coroutine.scheduler_destroy(&g.sched)
    delete(g.projectiles)
    delete(g.floating_texts)
    delete(g.particles)
}

game_update :: proc(g: ^Game, dt: f32) {
    g.game_time += dt

    // Step the Coroutine Engine
    coroutine.scheduler_step(&g.sched, dt)

    if g.game_over || g.victory do return

    // --- Player Input & Movement ---
    move_dir := rl.Vector2{0, 0}
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    do move_dir.y -= 1
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  do move_dir.y += 1
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  do move_dir.x -= 1
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move_dir.x += 1

    if linalg.length(move_dir) > 0 {
        move_dir = linalg.normalize(move_dir)
        g.player.pos += move_dir * g.player.speed * dt
    }

    // Clamp Player to screen bounds
    g.player.pos.x = clamp(g.player.pos.x, g.player.radius, f32(SCREEN_WIDTH) - g.player.radius)
    g.player.pos.y = clamp(g.player.pos.y, g.player.radius, f32(SCREEN_HEIGHT) - g.player.radius)

    // Player Dash Trigger (Space or Right Mouse)
    if (rl.IsKeyPressed(.SPACE) || rl.IsMouseButtonPressed(.RIGHT)) && g.player.can_dash {
        coroutine.spawn(&g.sched, player_dash_coroutine, &g.player, scope = &g.player.scope, name = "Player Dash")
    }

    // Player Shooting (Left Click or J / Z)
    if rl.IsMouseButtonDown(.LEFT) || rl.IsKeyDown(.J) || rl.IsKeyDown(.Z) {
        if math.mod(g.game_time, 0.12) < dt {
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
        p.pos += p.vel * dt

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
        p.pos += p.vel * dt
        p.alpha -= dt * 2.0
        if p.alpha <= 0.0 {
            unordered_remove(&g.particles, i)
        }
    }

    // --- Cleanup Dead Floating Texts ---
    for i := len(g.floating_texts) - 1; i >= 0; i -= 1 {
        if !g.floating_texts[i].alive {
            unordered_remove(&g.floating_texts, i)
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

    // --- Draw Floating Texts ---
    for ft in g.floating_texts {
        c := ft.color
        c.a = u8(clamp(ft.alpha * 255.0, 0, 255))
        cstr := fmt.ctprintf(ft.text)
        rl.DrawText(cstr, i32(ft.pos.x) + cam_x, i32(ft.pos.y) + cam_y, i32(ft.scale), c)
    }

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
    rl.DrawText(fmt.ctprintf("FPS: %d", rl.GetFPS()), SCREEN_WIDTH - 260, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Active Fibers (Coroutines): %d", active_fibers), SCREEN_WIDTH - 260, diag_y, 16, rl.YELLOW); diag_y += 22
    rl.DrawText(fmt.ctprintf("Timer Min-Heap: %d items", len(g.sched.timer_heap)), SCREEN_WIDTH - 260, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Ready Queue: %d", len(g.sched.ready_queue)), SCREEN_WIDTH - 260, diag_y, 16, rl.RAYWHITE); diag_y += 22
    rl.DrawText(fmt.ctprintf("Projectiles: %d", len(g.projectiles)), SCREEN_WIDTH - 260, diag_y, 16, rl.RAYWHITE); diag_y += 22

    // Instructions
    rl.DrawText("WASD/Arrows: Move | Left Click / J: Shoot | Space / RMB: Dash", 30, SCREEN_HEIGHT - 20, 14, rl.LIGHTGRAY)

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