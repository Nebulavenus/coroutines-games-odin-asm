package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:thread"
import "core:time"
import rl "vendor:raylib"
import coroutine "../../src/coroutine"

// ============================================================================
// Constants & Configuration
// ============================================================================

SCREEN_WIDTH  :: 1280
SCREEN_HEIGHT :: 720

// ============================================================================
// Data Types for Showcase Stations
// ============================================================================

// --- Station 1: The Ritual Circle (sync) ---
Rune :: struct {
    pos:      rl.Vector2,
    progress: f32,
    color:    rl.Color,
    name:     string,
    active:   bool,
}

Ritual_Station :: struct {
    pos:          rl.Vector2,
    runes:        [3]Rune,
    is_active:    bool,
    completed:    bool,
    result_alpha: f32,
    scope:        coroutine.Fiber_Scope,
}

// --- Station 2: The Capture Contest (race & with_timeout) ---
Capture_Station :: struct {
    pos:             rl.Vector2,
    radius:          f32,
    progress:        f32,
    is_capturing:    bool,
    capture_success: bool,
    status_text:     string,
    status_color:    rl.Color,
    scope:           coroutine.Fiber_Scope,
}

// --- Station 3: The Energy Charger (Fiber_Mutex) ---
Drone :: struct {
    pos:          rl.Vector2,
    home_pos:     rl.Vector2,
    target_pos:   rl.Vector2,
    charge_level: f32,
    is_charging:  bool,
    color:        rl.Color,
    id:           int,
}

Charger_Station :: struct {
    pos:       rl.Vector2,
    radius:    f32,
    mutex:     coroutine.Fiber_Mutex,
    drones:    [4]Drone,
    is_active: bool,
    scope:     coroutine.Fiber_Scope,
}

// --- Station 4: The Alert Beacon (Signal) ---
Sentry :: struct {
    pos:         rl.Vector2,
    home_pos:    rl.Vector2,
    is_alerted:  bool,
    alert_timer: f32,
    color:       rl.Color,
}

Beacon_Station :: struct {
    pos:          rl.Vector2,
    alarm_signal: coroutine.Signal,
    sentries:     [6]Sentry,
    is_flashing:  bool,
    flash_alpha:  f32,
    scope:        coroutine.Fiber_Scope,
}

// --- Station 5: The Loot Forge (Generator) ---
Loot_Item :: struct {
    name:  string,
    tier:  string,
    color: rl.Color,
    power: int,
}

Forge_Station :: struct {
    pos:           rl.Vector2,
    loot_gen:      coroutine.Generator(Loot_Item),
    current_item:  Loot_Item,
    has_item:      bool,
    total_forged:  int,
    display_timer: f32,
}

// --- Station 6: The Async Research Lab (Async_Token / await_async) ---
Research_Job :: struct {
    token:          coroutine.Async_Token,
    complexity:     int,
    result_nodes:   int,
    elapsed_worker: f32,
}

Lab_Station :: struct {
    pos:          rl.Vector2,
    job:          Research_Job,
    is_working:   bool,
    status_text:  string,
    status_color: rl.Color,
    scope:        coroutine.Fiber_Scope,
}

// --- Station 7: The Telemetry Feed (Channel(T)) ---
Channel_Station :: struct {
    pos:           rl.Vector2,
    log_channel:   coroutine.Channel(string),
    recent_logs:   [dynamic]string,
    items_sent:    int,
    scope:         coroutine.Fiber_Scope,
}

// ============================================================================
// Overall Showcase World State
// ============================================================================

Player :: struct {
    pos:    rl.Vector2,
    speed:  f32,
    radius: f32,
    scope:  coroutine.Fiber_Scope,
}

Showcase_World :: struct {
    sched:                   coroutine.Scheduler,
    player:                  Player,
    station_ritual:          Ritual_Station,
    station_capture:         Capture_Station,
    station_charger:         Charger_Station,
    station_beacon:          Beacon_Station,
    station_forge:           Forge_Station,
    station_lab:             Lab_Station,
    station_channel:         Channel_Station,
    show_coroutine_debugger: bool,
    global_time:             f32,
}

g_world: ^Showcase_World

// ============================================================================
// Coroutine Logic for Each Station
// ============================================================================

// --- 1. Ritual Station (sync) ---

rune_charge_fiber :: proc(f: ^coroutine.Fiber, r: ^Rune) {
    r.active = true
    r.progress = 0.0
    dur: f32 = 1.0 + f32(r.pos.x - 100.0) / 100.0 // Varying durations
    if dur < 1.0 do dur = 1.5

    coroutine.tween(f, &r.progress, 0.0, 1.0, dur, coroutine.ease_in_out_quad)
    r.active = false
}

ritual_master_fiber :: proc(f: ^coroutine.Fiber, s: ^Ritual_Station) {
    s.is_active = true
    s.completed = false
    s.result_alpha = 0.0

    // SYNC: Run 3 charging runes in parallel; master resumes ONLY when all 3 finish
    all_ok := coroutine.sync(f,
        coroutine.branch(rune_charge_fiber, &s.runes[0], "Fire Rune"),
        coroutine.branch(rune_charge_fiber, &s.runes[1], "Frost Rune"),
        coroutine.branch(rune_charge_fiber, &s.runes[2], "Storm Rune"),
    )

    if all_ok {
        s.completed = true
        // Flash completion animation
        coroutine.tween(f, &s.result_alpha, 0.0, 1.0, 0.3)
        coroutine.wait(f, 1.0)
        coroutine.tween(f, &s.result_alpha, 1.0, 0.0, 0.5)
    }

    s.is_active = false
}

// --- 2. Capture Contest (race & with_timeout) ---

capture_contest_fiber :: proc(f: ^coroutine.Fiber, s: ^Capture_Station) {
    s.is_capturing = true
    s.progress = 0.0
    s.status_text = "Contesting Zone (Race vs 3.5s Timeout)..."
    s.status_color = rl.YELLOW

    // with_timeout uses race internally: aborts if time exceeds 3.5s
    timed_out := coroutine.with_timeout(f, 3.5, coroutine.branch(proc(f: ^coroutine.Fiber) {
        st := &g_world.station_capture
        for st.progress < 1.0 {
            coroutine.yield_frame(f)
            // Progress increases faster if player stays inside radius
            dist := linalg.length(g_world.player.pos - st.pos)
            if dist < st.radius {
                st.progress += f.sched.delta_time * 0.4
            } else {
                st.progress += f.sched.delta_time * 0.15
            }
        }
    }, "Player Capture Progress"))

    if timed_out {
        s.capture_success = false
        s.status_text = "FAILED: Zone Timed Out!"
        s.status_color = rl.RED
    } else {
        s.capture_success = true
        s.status_text = "SUCCESS: Zone Captured!"
        s.status_color = rl.GREEN
    }

    coroutine.wait(f, 2.0)
    s.is_capturing = false
    s.status_text = "Step into circle & Press [E] to contest"
    s.status_color = rl.RAYWHITE
}

// --- 3. Energy Charger (Fiber_Mutex) ---

drone_charge_fiber :: proc(f: ^coroutine.Fiber, d: ^Drone) {
    st := &g_world.station_charger
    charger_pos := st.pos

    // Fly to charger entrance
    coroutine.tween(f, &d.pos.x, d.pos.x, charger_pos.x - 30.0, 0.6)
    coroutine.tween(f, &d.pos.y, d.pos.y, charger_pos.y, 0.6)

    // CRITICAL SECTION: Mutex lock (only 1 drone can enter pad at a time)
    coroutine.mutex_lock(f, &st.mutex)
    d.is_charging = true

    // Move into pad center
    coroutine.tween(f, &d.pos.x, d.pos.x, charger_pos.x, 0.3)
    coroutine.tween(f, &d.pos.y, d.pos.y, charger_pos.y, 0.3)

    // Charge up over 1.2 seconds
    coroutine.tween(f, &d.charge_level, 0.0, 100.0, 1.2)

    // Move out of pad
    coroutine.tween(f, &d.pos.x, d.pos.x, charger_pos.x + 40.0, 0.3)

    d.is_charging = false
    coroutine.mutex_unlock(f.sched, &st.mutex)
    // END CRITICAL SECTION

    // Return to home position
    coroutine.tween(f, &d.pos.x, d.pos.x, d.home_pos.x, 0.8)
    coroutine.tween(f, &d.pos.y, d.pos.y, d.home_pos.y, 0.8)
}

// --- 4. Alert Beacon (Signal) ---

sentry_watch_fiber :: proc(f: ^coroutine.Fiber, s: ^Sentry) {
    for {
        // Zero-polling suspension: sleeps until alarm signal is emitted
        coroutine.signal_wait(f, &g_world.station_beacon.alarm_signal)

        // Sentry is alerted!
        s.is_alerted = true
        s.alert_timer = 2.5

        // Rush to beacon center
        beacon_pos := g_world.station_beacon.pos
        coroutine.tween(f, &s.pos.x, s.pos.x, beacon_pos.x + rand.float32_range(-40, 40), 0.5)
        coroutine.tween(f, &s.pos.y, s.pos.y, beacon_pos.y + rand.float32_range(-40, 40), 0.5)

        // Patrol alert area for 2 seconds
        coroutine.wait(f, 2.0)

        // Return home
        s.is_alerted = false
        coroutine.tween(f, &s.pos.x, s.pos.x, s.home_pos.x, 0.8)
        coroutine.tween(f, &s.pos.y, s.pos.y, s.home_pos.y, 0.8)
    }
}

// --- 5. Loot Forge (Stateful Generator) ---

loot_generator_entry :: proc(f: ^coroutine.Fiber, g: ^coroutine.Generator(Loot_Item)) {
    tiers := [?]string{"Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic"}
    colors := [?]rl.Color{rl.GRAY, rl.GREEN, rl.SKYBLUE, rl.PURPLE, rl.GOLD, rl.RED}
    names := [?]string{"Iron Dagger", "Ranger Bow", "Arcane Staff", "Dragon Blade", "Void Reaver", "Infinity Edge"}

    idx := 0
    for {
        t_idx := idx % len(tiers)
        item := Loot_Item{
            name  = names[t_idx],
            tier  = tiers[t_idx],
            color = colors[t_idx],
            power = 100 + (t_idx + 1) * 75,
        }

        // Pull-based yield to consumer
        coroutine.yield_value(f, g, item)
        idx += 1
    }
}

// --- 6. Async Research Lab (Async_Token / await_async) ---

research_worker_thread :: proc(data: rawptr) {
    job := (^Research_Job)(data)
    start_t := time.now()

    // Simulate heavy multi-threaded compute (1.2 seconds)
    time.sleep(1200 * time.Millisecond)

    job.result_nodes = 42 * job.complexity
    job.elapsed_worker = f32(time.duration_seconds(time.since(start_t)))

    // Mark completion atomically from background worker
    coroutine.async_token_complete(&job.token, true)
}

lab_research_fiber :: proc(f: ^coroutine.Fiber, s: ^Lab_Station) {
    s.is_working = true
    s.status_text = "Worker Thread Computing (await_async)..."
    s.status_color = rl.YELLOW

    coroutine.async_token_init(&s.job.token)
    s.job.complexity = 10

    // Dispatch real background thread using core:thread
    thread.create_and_start_with_data(&s.job, research_worker_thread)

    // Main thread fiber suspends without blocking frame updates
    ok := coroutine.await_async(f, &s.job.token)

    if ok {
        s.status_text = fmt.tprintf("Done in %.2fs! Found %d nodes", s.job.elapsed_worker, s.job.result_nodes)
        s.status_color = rl.GREEN
    } else {
        s.status_text = "Async Compute Failed"
        s.status_color = rl.RED
    }

    coroutine.wait(f, 3.0)
    s.is_working = false
    s.status_text = "Press [E] to launch background worker"
    s.status_color = rl.RAYWHITE
}

// --- 7. Telemetry Channel (Channel(T)) ---

channel_consumer_fiber :: proc(f: ^coroutine.Fiber, s: ^Channel_Station) {
    for {
        // Blocks until message arrives on channel
        msg, ok := coroutine.chan_recv(f, &s.log_channel)
        if !ok do break

        append(&s.recent_logs, msg)
        if len(s.recent_logs) > 6 {
            ordered_remove(&s.recent_logs, 0)
        }
    }
}

// ============================================================================
// Initialization & Destruction
// ============================================================================

showcase_init :: proc(w: ^Showcase_World) {
    coroutine.scheduler_init(&w.sched)

    w.player = Player{
        pos    = {SCREEN_WIDTH / 2.0, SCREEN_HEIGHT / 2.0},
        speed  = 220.0,
        radius = 16.0,
    }

    // 1. Ritual Station (sync)
    w.station_ritual.pos = {200, 180}
    w.station_ritual.runes[0] = Rune{pos = {150, 140}, color = rl.RED, name = "Fire"}
    w.station_ritual.runes[1] = Rune{pos = {200, 100}, color = rl.SKYBLUE, name = "Frost"}
    w.station_ritual.runes[2] = Rune{pos = {250, 140}, color = rl.GOLD, name = "Storm"}

    // 2. Capture Station (race & with_timeout)
    w.station_capture.pos = {540, 180}
    w.station_capture.radius = 60.0
    w.station_capture.status_text = "Step into circle & Press [E] to contest"
    w.station_capture.status_color = rl.RAYWHITE

    // 3. Charger Station (Fiber_Mutex)
    w.station_charger.pos = {880, 180}
    w.station_charger.radius = 45.0
    coroutine.mutex_init(&w.station_charger.mutex)
    for i in 0 ..< 4 {
        home := rl.Vector2{f32(780 + i * 65), 100}
        w.station_charger.drones[i] = Drone{
            pos       = home,
            home_pos  = home,
            color     = rl.Color{u8(100 + i * 40), 200, 255, 255},
            id        = i + 1,
        }
    }

    // 4. Beacon Station (Signal)
    w.station_beacon.pos = {200, 480}
    coroutine.signal_init(&w.station_beacon.alarm_signal)
    for i in 0 ..< 6 {
        angle := f32(i) * (math.TAU / 6.0)
        home := w.station_beacon.pos + {math.cos(angle) * 75.0, math.sin(angle) * 75.0}
        w.station_beacon.sentries[i] = Sentry{
            pos      = home,
            home_pos = home,
            color    = rl.ORANGE,
        }
        // Spawn sentry fibers
        coroutine.spawn(&w.sched, sentry_watch_fiber, &w.station_beacon.sentries[i], scope = &w.station_beacon.scope, name = fmt.tprintf("Sentry #%d", i + 1))
    }

    // 5. Forge Station (Generator)
    w.station_forge.pos = {540, 480}
    coroutine.generator_init(&w.station_forge.loot_gen, loot_generator_entry)

    // 6. Lab Station (Async_Token / await_async)
    w.station_lab.pos = {880, 480}
    w.station_lab.status_text = "Press [E] to launch background worker"
    w.station_lab.status_color = rl.RAYWHITE

    // 7. Channel Station (CSP Channel)
    w.station_channel.pos = {1140, 330}
    w.station_channel.recent_logs = make([dynamic]string)
    coroutine.chan_init(&w.station_channel.log_channel, capacity = 10)
    coroutine.spawn(&w.sched, channel_consumer_fiber, &w.station_channel, scope = &w.station_channel.scope, name = "Log Channel Consumer")

    g_world = w
}

showcase_destroy :: proc(w: ^Showcase_World) {
    coroutine.scope_destroy(&w.sched, &w.player.scope)
    coroutine.scope_destroy(&w.sched, &w.station_ritual.scope)
    coroutine.scope_destroy(&w.sched, &w.station_capture.scope)
    coroutine.scope_destroy(&w.sched, &w.station_charger.scope)
    coroutine.scope_destroy(&w.sched, &w.station_beacon.scope)
    coroutine.scope_destroy(&w.sched, &w.station_lab.scope)
    coroutine.scope_destroy(&w.sched, &w.station_channel.scope)

    coroutine.mutex_destroy(&w.station_charger.mutex)
    coroutine.signal_destroy(&w.station_beacon.alarm_signal)
    coroutine.generator_destroy(&w.station_forge.loot_gen)
    coroutine.chan_destroy(&w.station_channel.log_channel)
    delete(w.station_channel.recent_logs)

    coroutine.scheduler_destroy(&w.sched)
}

// ============================================================================
// Update & Input Handling
// ============================================================================

showcase_update :: proc(w: ^Showcase_World, dt: f32) {
    w.global_time += dt

    // Step coroutine engine
    coroutine.scheduler_step(&w.sched, dt)

    // Debugger overlay toggle
    if rl.IsKeyPressed(.F1) || rl.IsKeyPressed(.TAB) {
        w.show_coroutine_debugger = !w.show_coroutine_debugger
    }

    // --- Player Movement ---
    move_dir: rl.Vector2
    if rl.IsKeyDown(.W) || rl.IsKeyDown(.UP)    do move_dir.y -= 1
    if rl.IsKeyDown(.S) || rl.IsKeyDown(.DOWN)  do move_dir.y += 1
    if rl.IsKeyDown(.A) || rl.IsKeyDown(.LEFT)  do move_dir.x -= 1
    if rl.IsKeyDown(.D) || rl.IsKeyDown(.RIGHT) do move_dir.x += 1

    if linalg.length(move_dir) > 0 {
        move_dir = linalg.normalize(move_dir)
        w.player.pos += move_dir * w.player.speed * dt
    }

    // --- Station 1 Interaction: Ritual (Press [1] or [E] near station) ---
    dist1 := linalg.length(w.player.pos - w.station_ritual.pos)
    if (dist1 < 80.0 && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.ONE) {
        if !w.station_ritual.is_active {
            coroutine.spawn(&w.sched, ritual_master_fiber, &w.station_ritual, scope = &w.station_ritual.scope, name = "Ritual Master (sync)")
            coroutine.chan_try_send(&w.station_channel.log_channel, "Ritual [sync] triggered")
        }
    }

    // --- Station 2 Interaction: Capture Contest (Press [2] or [E] near station) ---
    dist2 := linalg.length(w.player.pos - w.station_capture.pos)
    if (dist2 < w.station_capture.radius && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.TWO) {
        if !w.station_capture.is_capturing {
            coroutine.spawn(&w.sched, capture_contest_fiber, &w.station_capture, scope = &w.station_capture.scope, name = "Capture [race/timeout]")
            coroutine.chan_try_send(&w.station_channel.log_channel, "Capture Contest [race] started")
        }
    }

    // --- Station 3 Interaction: Charger Mutex (Press [3] or [E] near station) ---
    dist3 := linalg.length(w.player.pos - w.station_charger.pos)
    if (dist3 < 90.0 && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.THREE) {
        for i in 0 ..< 4 {
            d := &w.station_charger.drones[i]
            if !d.is_charging {
                coroutine.spawn(&w.sched, drone_charge_fiber, d, scope = &w.station_charger.scope, name = fmt.tprintf("Drone #%d (Mutex)", d.id))
            }
        }
        coroutine.chan_try_send(&w.station_channel.log_channel, "4 Drones dispatched to [Mutex]")
    }

    // --- Station 4 Interaction: Beacon Signal (Press [4] or [E] near station) ---
    dist4 := linalg.length(w.player.pos - w.station_beacon.pos)
    if (dist4 < 80.0 && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.FOUR) {
        coroutine.signal_emit(&w.sched, &w.station_beacon.alarm_signal)
        coroutine.chan_try_send(&w.station_channel.log_channel, "Alarm [Signal] broadcast to 6 sentries")
    }

    // --- Station 5 Interaction: Loot Forge (Press [5] or [E] near station) ---
    dist5 := linalg.length(w.player.pos - w.station_forge.pos)
    if (dist5 < 80.0 && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.FIVE) || rl.IsKeyPressed(.L) {
        item, ok := coroutine.generator_next(&w.station_forge.loot_gen)
        if ok {
            w.station_forge.current_item = item
            w.station_forge.has_item = true
            w.station_forge.total_forged += 1
            coroutine.chan_try_send(&w.station_channel.log_channel, fmt.tprintf("Forged %s (%s)", item.name, item.tier))
        }
    }

    // --- Station 6 Interaction: Async Research (Press [6] or [E] near station) ---
    dist6 := linalg.length(w.player.pos - w.station_lab.pos)
    if (dist6 < 80.0 && rl.IsKeyPressed(.E)) || rl.IsKeyPressed(.SIX) {
        if !w.station_lab.is_working {
            coroutine.spawn(&w.sched, lab_research_fiber, &w.station_lab, scope = &w.station_lab.scope, name = "Async Research Lab")
            coroutine.chan_try_send(&w.station_channel.log_channel, "Dispatched [await_async] background worker")
        }
    }
}

// ============================================================================
// Render World & UI
// ============================================================================

showcase_render :: proc(w: ^Showcase_World) {
    rl.BeginDrawing()
    rl.ClearBackground({16, 20, 28, 255})

    // Grid Floor
    for x: i32 = 0; x < SCREEN_WIDTH; x += 40 {
        rl.DrawLine(x, 0, x, SCREEN_HEIGHT, {24, 30, 42, 255})
    }
    for y: i32 = 0; y < SCREEN_HEIGHT; y += 40 {
        rl.DrawLine(0, y, SCREEN_WIDTH, y, {24, 30, 42, 255})
    }

    // --- Render Station 1: Ritual Circle (sync) ---
    rl.DrawCircleLines(i32(w.station_ritual.pos.x), i32(w.station_ritual.pos.y), 70.0, rl.SKYBLUE)
    rl.DrawText("1. RITUAL CIRCLE", i32(w.station_ritual.pos.x) - 55, i32(w.station_ritual.pos.y) - 95, 14, rl.SKYBLUE)
    rl.DrawText("[sync: 3 Runes]", i32(w.station_ritual.pos.x) - 45, i32(w.station_ritual.pos.y) - 80, 12, rl.GRAY)

    for r in w.station_ritual.runes {
        rl.DrawCircleV(r.pos, 12.0, r.active ? r.color : rl.DARKGRAY)
        rl.DrawCircleLines(i32(r.pos.x), i32(r.pos.y), 12.0, r.color)
        rl.DrawRectangle(i32(r.pos.x) - 15, i32(r.pos.y) + 16, i32(30.0 * r.progress), 4, r.color)
    }
    if w.station_ritual.completed {
        rl.DrawCircleV(w.station_ritual.pos, 35.0, {100, 220, 255, u8(w.station_ritual.result_alpha * 200.0)})
    }

    // --- Render Station 2: Capture Contest (race & with_timeout) ---
    rl.DrawCircleLines(i32(w.station_capture.pos.x), i32(w.station_capture.pos.y), w.station_capture.radius, rl.YELLOW)
    rl.DrawCircleSector(w.station_capture.pos, w.station_capture.radius, 0, w.station_capture.progress * 360.0, 32, {255, 220, 50, 60})
    rl.DrawText("2. CAPTURE CONTEST", i32(w.station_capture.pos.x) - 65, i32(w.station_capture.pos.y) - 95, 14, rl.YELLOW)
    rl.DrawText("[race & with_timeout]", i32(w.station_capture.pos.x) - 60, i32(w.station_capture.pos.y) - 80, 12, rl.GRAY)
    rl.DrawText(fmt.ctprintf("%s", w.station_capture.status_text), i32(w.station_capture.pos.x) - 90, i32(w.station_capture.pos.y) + 70, 11, w.station_capture.status_color)

    // --- Render Station 3: Energy Charger (Fiber_Mutex) ---
    rl.DrawCircleLines(i32(w.station_charger.pos.x), i32(w.station_charger.pos.y), w.station_charger.radius, rl.PURPLE)
    rl.DrawText("3. ENERGY CHARGER", i32(w.station_charger.pos.x) - 65, i32(w.station_charger.pos.y) - 95, 14, rl.PURPLE)
    rl.DrawText("[Fiber_Mutex Pad]", i32(w.station_charger.pos.x) - 50, i32(w.station_charger.pos.y) - 80, 12, rl.GRAY)

    for d in w.station_charger.drones {
        rl.DrawCircleV(d.pos, 10.0, d.color)
        rl.DrawText(fmt.ctprintf("#%d", d.id), i32(d.pos.x) - 6, i32(d.pos.y) - 6, 10, rl.BLACK)
        if d.is_charging {
            rl.DrawCircleLines(i32(d.pos.x), i32(d.pos.y), 15.0, rl.WHITE)
        }
    }

    // --- Render Station 4: Alert Beacon (Signal) ---
    rl.DrawCircleLines(i32(w.station_beacon.pos.x), i32(w.station_beacon.pos.y), 30.0, rl.ORANGE)
    rl.DrawText("4. ALERT BEACON", i32(w.station_beacon.pos.x) - 55, i32(w.station_beacon.pos.y) - 65, 14, rl.ORANGE)
    rl.DrawText("[Signal Broadcast]", i32(w.station_beacon.pos.x) - 50, i32(w.station_beacon.pos.y) - 50, 12, rl.GRAY)

    for s in w.station_beacon.sentries {
        rl.DrawCircleV(s.pos, 9.0, s.is_alerted ? rl.RED : s.color)
        if s.is_alerted {
            rl.DrawText("!", i32(s.pos.x) - 3, i32(s.pos.y) - 18, 14, rl.RED)
        }
    }

    // --- Render Station 5: Loot Forge (Generator) ---
    rl.DrawRectangleLines(i32(w.station_forge.pos.x) - 50, i32(w.station_forge.pos.y) - 50, 100, 100, rl.GOLD)
    rl.DrawText("5. LOOT FORGE", i32(w.station_forge.pos.x) - 45, i32(w.station_forge.pos.y) - 75, 14, rl.GOLD)
    rl.DrawText("[Generator(T)]", i32(w.station_forge.pos.x) - 40, i32(w.station_forge.pos.y) - 60, 12, rl.GRAY)

    if w.station_forge.has_item {
        item := w.station_forge.current_item
        rl.DrawText(fmt.ctprintf("%s", item.name), i32(w.station_forge.pos.x) - 40, i32(w.station_forge.pos.y) - 15, 12, item.color)
        rl.DrawText(fmt.ctprintf("[%s] Pwr: %d", item.tier, item.power), i32(w.station_forge.pos.x) - 40, i32(w.station_forge.pos.y) + 5, 10, rl.LIGHTGRAY)
    } else {
        rl.DrawText("Press [E]/[5]/[L]", i32(w.station_forge.pos.x) - 42, i32(w.station_forge.pos.y) - 5, 10, rl.GRAY)
    }

    // --- Render Station 6: Async Research Lab (Async_Token / await_async) ---
    rl.DrawRectangleLines(i32(w.station_lab.pos.x) - 60, i32(w.station_lab.pos.y) - 50, 120, 100, rl.LIME)
    rl.DrawText("6. ASYNC LAB", i32(w.station_lab.pos.x) - 45, i32(w.station_lab.pos.y) - 75, 14, rl.LIME)
    rl.DrawText("[await_async]", i32(w.station_lab.pos.x) - 40, i32(w.station_lab.pos.y) - 60, 12, rl.GRAY)
    rl.DrawText(fmt.ctprintf("%s", w.station_lab.status_text), i32(w.station_lab.pos.x) - 80, i32(w.station_lab.pos.y) + 60, 10, w.station_lab.status_color)

    // --- Render Station 7: Telemetry Log Feed (Channel(T)) ---
    panel_x: i32 = 1000
    panel_y: i32 = 20
    panel_w: i32 = 260
    panel_h: i32 = 180
    rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 16, 24, 220})
    rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {60, 100, 150, 255})
    rl.DrawText("7. CSP CHANNEL LOGS", panel_x + 10, panel_y + 10, 12, rl.SKYBLUE)
    rl.DrawLine(panel_x + 10, panel_y + 28, panel_x + panel_w - 10, panel_y + 28, {50, 70, 100, 255})

    log_y := panel_y + 35
    for msg in w.station_channel.recent_logs {
        rl.DrawText(fmt.ctprintf("> %s", msg), panel_x + 12, log_y, 10, rl.LIGHTGRAY)
        log_y += 18
    }

    // --- Render Player Character ---
    rl.DrawCircleV(w.player.pos, w.player.radius, rl.WHITE)
    rl.DrawCircleLines(i32(w.player.pos.x), i32(w.player.pos.y), w.player.radius + 3.0, rl.LIME)

    // --- Instructions Header ---
    rl.DrawRectangle(20, SCREEN_HEIGHT - 35, SCREEN_WIDTH - 40, 25, {12, 14, 20, 220})
    rl.DrawText("WASD: Move | [1-6] or [E]: Trigger Nearby Station | [F1] or [TAB]: Toggle Live Hierarchy Debugger", 30, SCREEN_HEIGHT - 28, 12, rl.RAYWHITE)

    // --- Live Coroutine Hierarchy Visualizer Overlay (F1 / TAB) ---
    if w.show_coroutine_debugger {
        overlay_x: i32 = 30
        overlay_y: i32 = 40
        overlay_w: i32 = 640
        overlay_h: i32 = 620

        rl.DrawRectangle(overlay_x, overlay_y, overlay_w, overlay_h, {10, 12, 18, 245})
        rl.DrawRectangleLines(overlay_x, overlay_y, overlay_w, overlay_h, {0, 200, 255, 220})

        rl.DrawText("COROUTINE HIERARCHY & STACK PROFILER (F1 / TAB)", overlay_x + 15, overlay_y + 12, 15, rl.GOLD)
        rl.DrawLine(overlay_x + 10, overlay_y + 35, overlay_x + overlay_w - 10, overlay_y + 35, {60, 80, 120, 255})

        tree_y := overlay_y + 45

        draw_fiber_node :: proc(f: ^coroutine.Fiber, depth: int, cur_y: ^i32, max_y: i32) {
            if f == nil || cur_y^ > max_y do return

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
                left := max(0.0, f.wake_time - f.sched.current_time)
                status_str = fmt.tprintf("Sleeping_Time (%.2fs left)", left)
                status_col = rl.SKYBLUE
            case .Sleeping_Frames:
                left := f.wake_frame > f.sched.current_frame ? f.wake_frame - f.sched.current_frame : 0
                status_str = fmt.tprintf("Sleeping_Frames (%d frames)", left)
                status_col = rl.SKYBLUE
            case .Waiting_Condition:
                status_str = "Waiting_Condition"
                status_col = rl.ORANGE
            case .Suspended_Join:
                kind := f.active_coord.kind == .Sync ? "Sync" : "Race"
                status_str = fmt.tprintf("Suspended_Join (%s, %d active)", kind, f.active_coord.active_branches)
                status_col = rl.PURPLE
            case:
                status_str = fmt.tprintf("%v", f.status)
                status_col = rl.GRAY
            }

            used, total := coroutine.fiber_calc_stack_usage(f)
            pct := f32(used) / f32(total) * 100.0

            prefix := depth > 0 ? "├─ " : "▼ "
            row_text := fmt.tprintf("%s[#%d] %s: %s | Stack: %.1fKB/%.0fKB (%.1f%%)", prefix, f.handle, name, status_str, f32(used)/1024.0, f32(total)/1024.0, pct)
            rl.DrawText(fmt.ctprintf("%s", row_text), 45 + indent, cur_y^, 11, status_col)
            cur_y^ += 18

            child := f.first_child
            for child != nil {
                draw_fiber_node(child, depth + 1, cur_y, max_y)
                child = child.next_sibling
            }
        }

        for f in w.sched.fiber_pool.all_fibers {
            if f.status != .Unused && f.parent == nil {
                draw_fiber_node(f, 0, &tree_y, overlay_y + overlay_h - 25)
            }
        }
    }

    rl.EndDrawing()
}

// ============================================================================
// Main Entrypoint
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

    rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, "Stackful Coroutines - All Features Interactive Showcase")
    defer rl.CloseWindow()
    rl.SetTargetFPS(60)

    world: Showcase_World
    showcase_init(&world)
    defer showcase_destroy(&world)

    for !rl.WindowShouldClose() {
        dt := rl.GetFrameTime()
        showcase_update(&world, dt)
        showcase_render(&world)
    }
}
