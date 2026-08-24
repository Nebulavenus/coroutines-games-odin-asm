package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

import "../../src/coroutine"

// ============================================================================
// Constants & Configuration
// ============================================================================

SCREEN_WIDTH  :: 1280
SCREEN_HEIGHT :: 720

// ============================================================================
// Data Types for Showcase Stations
// ============================================================================

Showcase_Event :: struct {
    title: string,
    desc:  string,
    color: rl.Color,
}

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

// --- Station 6: The Async Research Lab (Async_Token / await_async & fiber_join) ---
Research_Job :: struct {
    token:          coroutine.Async_Token,
    complexity:     int,
    result_nodes:   int,
    elapsed_worker: f32,
}

Lab_Station :: struct {
    pos:            rl.Vector2,
    job:            Research_Job,
    is_working:     bool,
    status_text:    string,
    status_color:   rl.Color,
    drone_active:   bool,
    drone_pos:      rl.Vector2,
    scope:          coroutine.Fiber_Scope,
}

// --- Station 7: The Telemetry Feed (Channel(T) & Multi-Channel Select) ---
Channel_Station :: struct {
    pos:           rl.Vector2,
    user_channel:  coroutine.Channel(string),
    sys_channel:   coroutine.Channel(string),
    recent_logs:   [dynamic]string,
    items_sent:    int,
    scope:         coroutine.Fiber_Scope,
}

// --- Station 8: Gate Construction Rendezvous (Fiber_Latch) ---
Gate_Task :: struct {
    name:     string,
    progress: f32,
    done:     bool,
    color:    rl.Color,
}

Gate_Station :: struct {
    pos:          rl.Vector2,
    latch:        coroutine.Fiber_Latch,
    tasks:        [3]Gate_Task, // 0: Pillars, 1: Power Core, 2: Matrix
    is_building:  bool,
    portal_open:  bool,
    portal_alpha: f32,
    status_text:  string,
    scope:        coroutine.Fiber_Scope,
}

// --- Station 9: Laser Defense Turrets (Fiber_Semaphore) ---
Turret :: struct {
    pos:         rl.Vector2,
    target_pos:  rl.Vector2,
    is_firing:   bool,
    laser_alpha: f32,
    color:       rl.Color,
    id:          int,
}

Defense_Station :: struct {
    pos:       rl.Vector2,
    sem:       coroutine.Fiber_Semaphore, // 2 concurrent permits
    turrets:   [4]Turret,
    is_active: bool,
    scope:     coroutine.Fiber_Scope,
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
    event_hub:               coroutine.Event(Showcase_Event),
    lockdown_token:          coroutine.Cancel_Token,
    player:                  Player,
    station_ritual:          Ritual_Station,
    station_capture:         Capture_Station,
    station_charger:         Charger_Station,
    station_beacon:          Beacon_Station,
    station_forge:           Forge_Station,
    station_lab:             Lab_Station,
    station_channel:         Channel_Station,
    station_gate:            Gate_Station,
    station_defense:         Defense_Station,
    toast_title:             string,
    toast_desc:              string,
    toast_color:             rl.Color,
    toast_timer:             f32,
    show_coroutine_debugger: bool,
    global_time:             f32,
    step_count:              int,
    step_flash_timer:        f32,
    last_step_dt:            f32,
    hold_step_timer:         f32,
    latched_station:         int,
    latched_interact:        bool,
}

g_world: ^Showcase_World

// ============================================================================
// Coroutine Logic for Each Station
// ============================================================================

// --- 1. Ritual Circle (sync) ---

rune_charge_fiber :: proc(f: ^coroutine.Fiber, r: ^Rune) {
    r.active = true
    r.progress = 0.0
    for r.progress < 1.0 {
        coroutine.yield_frame(f)
        r.progress += coroutine.delta_time(f) / 1.5
    }
    r.progress = 1.0
}

ritual_master_fiber :: proc(f: ^coroutine.Fiber, s: ^Ritual_Station) {
    s.is_active = true
    s.completed = false
    s.result_alpha = 0.0

    // Broadcast Event(T)
    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Ritual Started", "3 Runes charging in parallel (sync)", rl.SKYBLUE})

    // Parallel join of 3 runes using structured sync
    coroutine.sync(f,
        coroutine.branch(rune_charge_fiber, &s.runes[0], "Charge Fire Rune"),
        coroutine.branch(rune_charge_fiber, &s.runes[1], "Charge Frost Rune"),
        coroutine.branch(rune_charge_fiber, &s.runes[2], "Charge Storm Rune"),
    )

    // All runes finished! Animate completed burst
    s.completed = true
    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Ritual Complete", "All 3 runes synchronized successfully!", rl.GREEN})

    coroutine.tween(f, &s.result_alpha, 0.0, 1.0, 0.5, coroutine.ease_out_quad)
    coroutine.wait(f, 2.0)
    coroutine.tween(f, &s.result_alpha, 1.0, 0.0, 0.5, coroutine.ease_in_quad)

    for i in 0 ..< 3 {
        s.runes[i].active = false
        s.runes[i].progress = 0.0
    }
    s.is_active = false
    s.completed = false
}

// --- 2. Capture Contest (race & with_timeout) ---

capture_contest_fiber :: proc(f: ^coroutine.Fiber, s: ^Capture_Station) {
    s.is_capturing = true
    s.progress = 0.0
    s.status_text = "Contesting: Hold position in circle!"
    s.status_color = rl.YELLOW

    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Capture Contest", "Hold position before 3s timeout (race)", rl.YELLOW})

    // Preemptive race: Capture task vs. 3.0s timeout
    won_index := coroutine.race(f,
        // Branch 0: Player must stay inside radius for 1.8 accumulated seconds
        coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Capture_Station) {
            for s.progress < 1.0 {
                coroutine.yield_frame(f)
                dist := linalg.length(g_world.player.pos - s.pos)
                if dist < s.radius {
                    s.progress += coroutine.delta_time(f) / 1.8
                } else {
                    s.progress = max(0.0, s.progress - coroutine.delta_time(f) * 0.8)
                }
            }
        }, s, "Capture Accumulation"),

        // Branch 1: 3.5-second hard timeout
        coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Capture_Station) {
            coroutine.wait(f, 3.5)
        }, s, "Contest Timeout"),
    )

    if won_index == 0 {
        s.capture_success = true
        s.status_text = "SUCCESS: Point Captured!"
        s.status_color = rl.GREEN
        coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Point Captured", "Player secured the zone in time!", rl.GREEN})
    } else {
        s.capture_success = false
        s.status_text = "FAILED: Timeout Expired!"
        s.status_color = rl.RED
        coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Capture Failed", "Timeout expired before completion!", rl.RED})
    }

    coroutine.wait(f, 2.0)
    s.is_capturing = false
    s.progress = 0.0
    s.status_text = "Step into circle & Press [E] to contest"
    s.status_color = rl.RAYWHITE
}

// --- 3. Energy Charger (Fiber_Mutex) ---

drone_charge_fiber :: proc(f: ^coroutine.Fiber, d: ^Drone) {
    pad_pos := g_world.station_charger.pos

    // Move to charging pad entrance
    coroutine.tween(f, &d.pos, d.pos, pad_pos + {0, 30}, 0.8, coroutine.ease_in_out_quad)

    // Request mutual exclusion on charging pad
    coroutine.mutex_lock(f, &g_world.station_charger.mutex)
    defer coroutine.mutex_unlock(f.sched, &g_world.station_charger.mutex)

    // Entered charging pad
    d.is_charging = true
    coroutine.tween(f, &d.pos, d.pos, pad_pos, 0.3, coroutine.ease_out_quad)

    // Charge battery for 1.2 seconds
    for d.charge_level < 1.0 {
        coroutine.yield_frame(f)
        d.charge_level += coroutine.delta_time(f) / 1.2
    }
    d.charge_level = 1.0

    // Return to home post
    d.is_charging = false
    coroutine.tween(f, &d.pos, d.pos, d.home_pos, 0.8, coroutine.ease_in_out_quad)
    d.charge_level = 0.0
}

// --- 4. Alert Beacon (Signal & Cancel_Token) ---

sentry_watch_fiber :: proc(f: ^coroutine.Fiber, s: ^Sentry) {
    for {
        s.is_alerted = false

        // Suspends until alarm_signal is emitted! Zero CPU polling.
        coroutine.signal_wait(f, &g_world.station_beacon.alarm_signal)

        // Alarm triggered! Wake up and flash
        s.is_alerted = true
        s.alert_timer = 2.5

        // Move outwards in defensive perimeter
        dir := linalg.normalize(s.home_pos - g_world.station_beacon.pos)
        target := s.home_pos + dir * 30.0
        coroutine.tween(f, &s.pos, s.home_pos, target, 0.3, coroutine.ease_out_back)

        coroutine.wait(f, 2.0)

        // Return to resting position
        coroutine.tween(f, &s.pos, s.pos, s.home_pos, 0.6, coroutine.ease_in_out_quad)
    }
}

sentry_lockdown_watcher_fiber :: proc(f: ^coroutine.Fiber) {
    // Waits on Cancel_Token across all sentries!
    coroutine.cancel_token_wait(f, &g_world.lockdown_token)

    // Unblocked by token! Alert all sentries immediately
    for i in 0 ..< 6 {
        s := &g_world.station_beacon.sentries[i]
        s.is_alerted = true
        s.alert_timer = 5.0
        s.color = rl.RED
    }
}

// --- 5. Loot Forge (Generator) ---

loot_generator_entry :: proc(f: ^coroutine.Fiber, g: ^coroutine.Generator(Loot_Item)) {
    items := [?]Loot_Item{
        {"Rusty Dagger",      "Common",    rl.LIGHTGRAY, 12},
        {"Iron Longsword",    "Uncommon",  rl.GREEN,     35},
        {"Flametongue Blade", "Rare",      rl.SKYBLUE,   85},
        {"Obsidian Reaver",   "Epic",      rl.PURPLE,    160},
        {"Astra Divine Bow",  "Legendary", rl.GOLD,      320},
    }

    for {
        for item in items {
            // Yields item back to consumer in O(1) time
            coroutine.yield_value(f, g, item)
        }
    }
}

// --- 6. Async Research Lab (await_async & fiber_join) ---

research_worker_thread :: proc(data: rawptr) {
    job := cast(^Research_Job)data
    start_t := time.now()

    // Simulate heavy multi-threaded compute (1.0 seconds)
    time.sleep(1000 * time.Millisecond)

    job.result_nodes = 42 * job.complexity
    job.elapsed_worker = f32(time.duration_seconds(time.since(start_t)))

    // Mark completion atomically from background worker
    coroutine.async_token_complete(&job.token, true)
}

lab_research_fiber :: proc(f: ^coroutine.Fiber, s: ^Lab_Station) {
    s.is_working = true
    s.status_text = "Worker Thread Computing (await_async)..."
    s.status_color = rl.YELLOW

    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Async Job Dispatched", "Background OS thread spawned (await_async)", rl.YELLOW})

    coroutine.async_token_init(&s.job.token)
    s.job.complexity = 10

    // Dispatch real background thread using core:thread
    thread.create_and_start_with_data(&s.job, research_worker_thread)

    // Main thread fiber suspends without blocking frame updates
    ok := coroutine.await_async(f, &s.job.token)

    if ok {
        s.status_text = fmt.tprintf("Done in %.2fs! Spawning Analysis Drone (fiber_join)...", s.job.elapsed_worker)
        s.status_color = rl.SKYBLUE

        // Spawn Analysis Drone task and await with fiber_join!
        s.drone_active = true
        s.drone_pos = s.pos + {0, -40}

        drone_h := coroutine.spawn(f.sched, proc(f: ^coroutine.Fiber, s: ^Lab_Station) {
            for i := 0; i < 4; i += 1 {
                coroutine.wait(f, 0.4)
                s.drone_pos.x += (i % 2 == 0 ? 25.0 : -25.0)
            }
            s.drone_active = false
        }, s, name = "Analysis Drone (Task Join)")

        coroutine.fiber_join(f, drone_h)

        s.status_text = fmt.tprintf("Research & Drone Complete! Found %d nodes", s.job.result_nodes)
        s.status_color = rl.GREEN
        coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Analysis Complete", "Async job & Analysis Drone joined successfully!", rl.GREEN})
    } else {
        s.status_text = "Async Compute Failed"
        s.status_color = rl.RED
    }

    coroutine.wait(f, 3.0)
    s.is_working = false
    s.status_text = "Press [6] or [E] to launch background worker"
    s.status_color = rl.RAYWHITE
}

// --- 7. Telemetry Channel (Channel(T) & Multi-Channel Select) ---

channel_consumer_fiber :: proc(f: ^coroutine.Fiber, s: ^Channel_Station) {
    channels := []^coroutine.Channel(string){&s.user_channel, &s.sys_channel}

    for {
        // Multi-Channel Select: Awaits message from EITHER user channel or heartbeat channel!
        ready_idx, msg, ok := coroutine.chan_select_recv(f, channels)
        if !ok do break

        tag_prefix := ready_idx == 0 ? "[USER]" : "[SYS]"
        formatted := fmt.tprintf("%s %s", tag_prefix, msg)

        append(&s.recent_logs, formatted)
        if len(s.recent_logs) > 6 {
            ordered_remove(&s.recent_logs, 0)
        }
    }
}

system_heartbeat_fiber :: proc(f: ^coroutine.Fiber, s: ^Channel_Station) {
    count := 1
    for {
        coroutine.wait(f, 3.5)
        coroutine.chan_send(f, &s.sys_channel, fmt.tprintf("Pulse #%d (Nominal)", count))
        count += 1
    }
}

// --- 8. Gate Construction Rendezvous (Fiber_Latch) ---

builder_subtask_fiber :: proc(f: ^coroutine.Fiber, task: ^Gate_Task) {
    task.progress = 0.0
    task.done = false
    for task.progress < 1.0 {
        coroutine.yield_frame(f)
        task.progress += coroutine.delta_time(f) / 1.6
    }
    task.progress = 1.0
    task.done = true

    // Rendezvous count down!
    coroutine.latch_count_down(f.sched, &g_world.station_gate.latch)
}

gate_master_fiber :: proc(f: ^coroutine.Fiber, s: ^Gate_Station) {
    s.is_building = true
    s.portal_open = false
    s.portal_alpha = 0.0
    s.status_text = "Building: 3 Tasks Synchronizing (Fiber_Latch)..."

    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Gate Construction", "3 subtasks rendezvous on Fiber_Latch", rl.SKYBLUE})

    coroutine.latch_init(&s.latch, initial_count = 3)
    defer coroutine.latch_destroy(&s.latch)

    for i in 0 ..< 3 {
        coroutine.spawn(f.sched, builder_subtask_fiber, &s.tasks[i], scope = &s.scope, name = fmt.tprintf("Builder #%d", i + 1))
    }

    // Await all 3 builders via countdown barrier!
    coroutine.latch_wait(f, &s.latch)

    // Portal opens!
    s.portal_open = true
    s.status_text = "PORTAL ACTIVATED! All 3 builders rendezvoused!"
    coroutine.event_emit(f.sched, &g_world.event_hub, Showcase_Event{"Portal Open", "Fiber_Latch barrier unblocked!", rl.GREEN})

    coroutine.tween(f, &s.portal_alpha, 0.0, 1.0, 0.5, coroutine.ease_out_quad)
    coroutine.wait(f, 3.0)
    coroutine.tween(f, &s.portal_alpha, 1.0, 0.0, 0.5, coroutine.ease_in_quad)

    for i in 0 ..< 3 {
        s.tasks[i].done = false
        s.tasks[i].progress = 0.0
    }
    s.is_building = false
    s.portal_open = false
    s.status_text = "Press [7] or [E] to construct gate"
}

// --- 9. Laser Defense Turrets (Fiber_Semaphore) ---

turret_defense_fiber :: proc(f: ^coroutine.Fiber, t: ^Turret) {
    for {
        coroutine.wait(f, f32(t.id) * 0.4)

        // Acquire 1 of 2 power permits from semaphore
        coroutine.semaphore_acquire(f, &g_world.station_defense.sem)

        t.is_firing = true
        t.laser_alpha = 1.0

        for i := 0; i < 20; i += 1 {
            coroutine.yield_frame(f)
            t.laser_alpha = 0.6 + 0.4 * math.sin(g_world.global_time * 25.0)
        }

        t.is_firing = false
        t.laser_alpha = 0.0

        // Release power permit
        coroutine.semaphore_release(f.sched, &g_world.station_defense.sem)

        coroutine.wait(f, 1.2)
    }
}

// ============================================================================
// Initialization & Destruction
// ============================================================================

showcase_init :: proc(w: ^Showcase_World) {
    coroutine.scheduler_init(&w.sched)
    // Pre-warm stack pool for zero-allocation runtime performance
    coroutine.scheduler_prewarm(&w.sched, 64)

    coroutine.event_init(&w.event_hub)
    coroutine.cancel_token_init(&w.lockdown_token)

    w.player = Player{
        pos    = {SCREEN_WIDTH / 2.0, SCREEN_HEIGHT / 2.0},
        speed  = 240.0,
        radius = 16.0,
    }

    // 1. Ritual Station (sync)
    w.station_ritual.pos = {160, 160}
    w.station_ritual.runes[0] = Rune{pos = {120, 130}, color = rl.RED, name = "Fire"}
    w.station_ritual.runes[1] = Rune{pos = {160, 100}, color = rl.SKYBLUE, name = "Frost"}
    w.station_ritual.runes[2] = Rune{pos = {200, 130}, color = rl.GOLD, name = "Storm"}

    // 2. Capture Station (race & with_timeout)
    w.station_capture.pos = {460, 160}
    w.station_capture.radius = 55.0
    w.station_capture.status_text = "Step into circle & Press [E] to contest"
    w.station_capture.status_color = rl.RAYWHITE

    // 3. Charger Station (Fiber_Mutex)
    w.station_charger.pos = {760, 160}
    w.station_charger.radius = 42.0
    coroutine.mutex_init(&w.station_charger.mutex)
    for i in 0 ..< 4 {
        home := rl.Vector2{f32(680 + i * 55), 90}
        w.station_charger.drones[i] = Drone{
            pos       = home,
            home_pos  = home,
            color     = rl.Color{u8(100 + i * 40), 200, 255, 255},
            id        = i + 1,
        }
    }

    // 4. Beacon Station (Signal & Cancel_Token)
    w.station_beacon.pos = {160, 440}
    coroutine.signal_init(&w.station_beacon.alarm_signal)
    for i in 0 ..< 6 {
        angle := f32(i) * (math.TAU / 6.0)
        home := w.station_beacon.pos + {math.cos(angle) * 70.0, math.sin(angle) * 70.0}
        w.station_beacon.sentries[i] = Sentry{
            pos      = home,
            home_pos = home,
            color    = rl.ORANGE,
        }
        coroutine.spawn(&w.sched, sentry_watch_fiber, &w.station_beacon.sentries[i], scope = &w.station_beacon.scope, name = fmt.tprintf("Sentry #%d", i + 1))
    }
    // Sentry lockdown token listener fiber
    coroutine.spawn(&w.sched, sentry_lockdown_watcher_fiber, scope = &w.station_beacon.scope, name = "Sentry Lockdown Token Watcher")

    // 5. Forge Station (Generator)
    w.station_forge.pos = {460, 440}
    coroutine.generator_init(&w.station_forge.loot_gen, loot_generator_entry)

    // 6. Lab Station (Async_Token / await_async & fiber_join)
    w.station_lab.pos = {760, 440}
    w.station_lab.status_text = "Press [6] or [E] to launch worker"
    w.station_lab.status_color = rl.RAYWHITE

    // 7. Channel Station (CSP Multi-Channel Select)
    w.station_channel.pos = {1060, 160}
    w.station_channel.recent_logs = make([dynamic]string)
    coroutine.chan_init(&w.station_channel.user_channel, capacity = 10)
    coroutine.chan_init(&w.station_channel.sys_channel, capacity = 10)
    coroutine.spawn(&w.sched, channel_consumer_fiber, &w.station_channel, scope = &w.station_channel.scope, name = "Multi-Channel Select Consumer")
    coroutine.spawn(&w.sched, system_heartbeat_fiber, &w.station_channel, scope = &w.station_channel.scope, name = "System Heartbeat Producer")

    // 8. Gate Station (Fiber_Latch Rendezvous)
    w.station_gate.pos = {1060, 440}
    w.station_gate.tasks[0] = Gate_Task{name = "Pillars", color = rl.SKYBLUE}
    w.station_gate.tasks[1] = Gate_Task{name = "Core", color = rl.GOLD}
    w.station_gate.tasks[2] = Gate_Task{name = "Matrix", color = rl.PURPLE}
    w.station_gate.status_text = "Press [7] or [E] to construct gate"

    // 9. Defense Station (Fiber_Semaphore)
    w.station_defense.pos = {640, 600}
    coroutine.semaphore_init(&w.station_defense.sem, initial_permits = 2, max_permits = 2)
    for i in 0 ..< 4 {
        pos := rl.Vector2{f32(490 + i * 100), 620}
        w.station_defense.turrets[i] = Turret{
            pos        = pos,
            target_pos = pos + {0, -60},
            color      = rl.RED,
            id         = i + 1,
        }
        coroutine.spawn(&w.sched, turret_defense_fiber, &w.station_defense.turrets[i], scope = &w.station_defense.scope, name = fmt.tprintf("Turret #%d (Semaphore)", i + 1))
    }

    // Spawn Toast Notification Fiber (receives Event(Showcase_Event))
    coroutine.spawn(&w.sched, proc(f: ^coroutine.Fiber) {
        for {
            ev, ok := coroutine.event_wait(f, &g_world.event_hub)
            if ok {
                g_world.toast_title = ev.title
                g_world.toast_desc = ev.desc
                g_world.toast_color = ev.color
                g_world.toast_timer = 3.5
            }
        }
    }, name = "Event(T) Toast Listener")

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
    coroutine.scope_destroy(&w.sched, &w.station_gate.scope)
    coroutine.scope_destroy(&w.sched, &w.station_defense.scope)

    coroutine.semaphore_destroy(&w.station_defense.sem)
    coroutine.event_destroy(&w.event_hub)
    coroutine.cancel_token_destroy(&w.lockdown_token)
    coroutine.mutex_destroy(&w.station_charger.mutex)
    coroutine.signal_destroy(&w.station_beacon.alarm_signal)
    coroutine.generator_destroy(&w.station_forge.loot_gen)
    coroutine.chan_destroy(&w.station_channel.user_channel)
    coroutine.chan_destroy(&w.station_channel.sys_channel)
    delete(w.station_channel.recent_logs)
    coroutine.scheduler_destroy(&w.sched)
}

// ============================================================================
// Update & Input Handling
// ============================================================================

showcase_update :: proc(w: ^Showcase_World, dt: f32) {
    if rl.IsKeyPressed(.F3) {
        w.sched.is_paused = !w.sched.is_paused
    }

    if rl.IsKeyPressed(.F1) || rl.IsKeyPressed(.TAB) {
        w.show_coroutine_debugger = !w.show_coroutine_debugger
    }

    if w.toast_timer > 0.0 {
        w.toast_timer = max(0.0, w.toast_timer - dt)
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

    // Latch station interaction keys while running or paused
    if rl.IsKeyPressed(.ONE)   do w.latched_station = 1
    if rl.IsKeyPressed(.TWO)   do w.latched_station = 2
    if rl.IsKeyPressed(.THREE) do w.latched_station = 3
    if rl.IsKeyPressed(.FOUR)  do w.latched_station = 4
    if rl.IsKeyPressed(.FIVE) || rl.IsKeyPressed(.L) do w.latched_station = 5
    if rl.IsKeyPressed(.SIX)   do w.latched_station = 6
    if rl.IsKeyPressed(.SEVEN) do w.latched_station = 7
    if rl.IsKeyPressed(.E)     do w.latched_interact = true

    // If simulation is completely paused with no step this frame, pump real-time clock and halt world updates
    if sim_dt <= 0.0 {
        coroutine.scheduler_step(&w.sched, dt)
        return
    }

    w.global_time += sim_dt

    // Step coroutine engine
    if !w.sched.is_paused {
        coroutine.scheduler_step(&w.sched, sim_dt)
    } else {
        coroutine.scheduler_single_step(&w.sched, sim_dt)
    }

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

    // Process latched station triggers
    trigger_station := w.latched_station
    interact := w.latched_interact || rl.IsKeyPressed(.E)
    w.latched_station = 0
    w.latched_interact = false

    // --- Station 1: Ritual (Press [1] or [E] near station) ---
    dist1 := linalg.length(w.player.pos - w.station_ritual.pos)
    if (dist1 < 80.0 && interact) || trigger_station == 1 {
        if !coroutine.scope_is_busy(&w.station_ritual.scope) {
            coroutine.spawn(&w.sched, ritual_master_fiber, &w.station_ritual, scope = &w.station_ritual.scope, name = "Ritual Master (sync)")
            coroutine.chan_try_send(&w.station_channel.user_channel, "Ritual [sync] triggered")
        }
    }

    // --- Station 2: Capture Contest (Press [2] or [E] near station) ---
    dist2 := linalg.length(w.player.pos - w.station_capture.pos)
    if (dist2 < w.station_capture.radius && interact) || trigger_station == 2 {
        if !coroutine.scope_is_busy(&w.station_capture.scope) {
            coroutine.spawn(&w.sched, capture_contest_fiber, &w.station_capture, scope = &w.station_capture.scope, name = "Capture [race/timeout]")
            coroutine.chan_try_send(&w.station_channel.user_channel, "Capture Contest [race] started")
        }
    }

    // --- Station 3: Charger Mutex (Press [3] or [E] near station) ---
    dist3 := linalg.length(w.player.pos - w.station_charger.pos)
    if (dist3 < 90.0 && interact) || trigger_station == 3 {
        if !coroutine.scope_is_busy(&w.station_charger.scope) {
            for i in 0 ..< 4 {
                d := &w.station_charger.drones[i]
                coroutine.spawn(&w.sched, drone_charge_fiber, d, scope = &w.station_charger.scope, name = fmt.tprintf("Drone #%d (Mutex)", d.id))
            }
            coroutine.chan_try_send(&w.station_channel.user_channel, "4 Drones dispatched to [Mutex]")
        }
    }

    // --- Station 4: Beacon Signal & Cancel_Token (Press [4] or [E] near station) ---
    dist4 := linalg.length(w.player.pos - w.station_beacon.pos)
    if (dist4 < 80.0 && interact) || trigger_station == 4 {
        coroutine.signal_emit(&w.sched, &w.station_beacon.alarm_signal)
        coroutine.chan_try_send(&w.station_channel.user_channel, "Alarm [Signal] broadcast to 6 sentries")
        coroutine.event_emit(&w.sched, &w.event_hub, Showcase_Event{"Alarm Tripped", "Signal broadcast woken 6 sentries!", rl.RED})
    }

    // Emergency Lockdown Token Trigger (Press [K]: Toggle / Arm / Disarm)
    if rl.IsKeyPressed(.K) {
        if !coroutine.cancel_token_is_cancelled(&w.lockdown_token) {
            coroutine.cancel_token_cancel(&w.sched, &w.lockdown_token)
            coroutine.chan_try_send(&w.station_channel.user_channel, "EMERGENCY LOCKDOWN ACTIVATED [Cancel_Token]")
            coroutine.event_emit(&w.sched, &w.event_hub, Showcase_Event{"LOCKDOWN ACTIVE", "Cancel_Token broadcast unblocked 6 sentries!", rl.RED})
        } else {
            // Re-arm / Reset lockdown token
            coroutine.cancel_token_destroy(&w.lockdown_token)
            coroutine.cancel_token_init(&w.lockdown_token)
            for i in 0 ..< 6 {
                w.station_beacon.sentries[i].color = rl.ORANGE
                w.station_beacon.sentries[i].is_alerted = false
                w.station_beacon.sentries[i].alert_timer = 0.0
            }
            coroutine.spawn(&w.sched, sentry_lockdown_watcher_fiber, scope = &w.station_beacon.scope, name = "Sentry Lockdown Token Watcher")
            coroutine.chan_try_send(&w.station_channel.user_channel, "Lockdown Disarmed [Cancel_Token Re-armed]")
            coroutine.event_emit(&w.sched, &w.event_hub, Showcase_Event{"LOCKDOWN DISARMED", "Cancel_Token re-armed; Sentries reset", rl.GREEN})
        }
    }

    // --- Station 5: Loot Forge (Press [5] or [E] near station) ---
    dist5 := linalg.length(w.player.pos - w.station_forge.pos)
    if (dist5 < 80.0 && interact) || trigger_station == 5 {
        item, ok := coroutine.generator_next(&w.station_forge.loot_gen)
        if ok {
            w.station_forge.current_item = item
            w.station_forge.has_item = true
            w.station_forge.total_forged += 1
            coroutine.chan_try_send(&w.station_channel.user_channel, fmt.tprintf("Forged %s (%s)", item.name, item.tier))
            coroutine.event_emit(&w.sched, &w.event_hub, Showcase_Event{fmt.tprintf("Forged %s", item.name), fmt.tprintf("Tier: %s | Pwr: %d", item.tier, item.power), item.color})
        }
    }

    // --- Station 6: Async Research (Press [6] or [E] near station) ---
    dist6 := linalg.length(w.player.pos - w.station_lab.pos)
    if (dist6 < 80.0 && interact) || trigger_station == 6 {
        if !coroutine.scope_is_busy(&w.station_lab.scope) {
            coroutine.spawn(&w.sched, lab_research_fiber, &w.station_lab, scope = &w.station_lab.scope, name = "Async Research Lab")
            coroutine.chan_try_send(&w.station_channel.user_channel, "Dispatched [await_async] background worker")
        }
    }

    // --- Station 8: Gate Construction (Press [7] or [E] near station) ---
    dist8 := linalg.length(w.player.pos - w.station_gate.pos)
    if (dist8 < 80.0 && interact) || trigger_station == 7 {
        if !coroutine.scope_is_busy(&w.station_gate.scope) {
            coroutine.spawn(&w.sched, gate_master_fiber, &w.station_gate, scope = &w.station_gate.scope, name = "Gate Master (Fiber_Latch)")
            coroutine.chan_try_send(&w.station_channel.user_channel, "Gate Construction [Fiber_Latch] started")
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

    // Top Header & Pool Telemetry
    rl.DrawText("STACKFUL COROUTINE ENGINE — ADVANCED FEATURE SHOWCASE", 25, 14, 20, rl.RAYWHITE)
    stats := coroutine.scheduler_pool_stats(&w.sched)
    header_stats := fmt.ctprintf("Pool: %d Slabs | Stacks: %d | Active: %d | Free: %d | Mem: %d KB | Defense Sem: %d", stats.slabs_count, stats.total_stacks, stats.active_fibers, stats.free_fibers, stats.total_memory_kb, coroutine.semaphore_available_permits(&w.station_defense.sem))
    rl.DrawText(header_stats, 25, 38, 12, rl.SKYBLUE)

    // --- Station 1: Ritual Circle (sync) ---
    rl.DrawCircleLines(i32(w.station_ritual.pos.x), i32(w.station_ritual.pos.y), 65.0, rl.SKYBLUE)
    rl.DrawText("1. RITUAL CIRCLE", i32(w.station_ritual.pos.x) - 55, i32(w.station_ritual.pos.y) - 85, 13, rl.SKYBLUE)
    rl.DrawText("[sync: 3 Runes]", i32(w.station_ritual.pos.x) - 45, i32(w.station_ritual.pos.y) - 72, 11, rl.GRAY)

    for r in w.station_ritual.runes {
        rl.DrawCircleV(r.pos, 11.0, r.active ? r.color : rl.DARKGRAY)
        rl.DrawCircleLines(i32(r.pos.x), i32(r.pos.y), 11.0, r.color)
        rl.DrawRectangle(i32(r.pos.x) - 15, i32(r.pos.y) + 14, i32(30.0 * r.progress), 3, r.color)
    }
    if w.station_ritual.completed {
        rl.DrawCircleV(w.station_ritual.pos, 30.0, {100, 220, 255, u8(w.station_ritual.result_alpha * 200.0)})
    }

    // --- Station 2: Capture Contest (race & with_timeout) ---
    rl.DrawCircleLines(i32(w.station_capture.pos.x), i32(w.station_capture.pos.y), w.station_capture.radius, rl.YELLOW)
    rl.DrawCircleSector(w.station_capture.pos, w.station_capture.radius, 0, w.station_capture.progress * 360.0, 32, {255, 220, 50, 60})
    rl.DrawText("2. CAPTURE CONTEST", i32(w.station_capture.pos.x) - 65, i32(w.station_capture.pos.y) - 85, 13, rl.YELLOW)
    rl.DrawText("[race & timeout]", i32(w.station_capture.pos.x) - 50, i32(w.station_capture.pos.y) - 72, 11, rl.GRAY)
    rl.DrawText(fmt.ctprintf("%s", w.station_capture.status_text), i32(w.station_capture.pos.x) - 85, i32(w.station_capture.pos.y) + 65, 10, w.station_capture.status_color)

    // --- Station 3: Energy Charger (Fiber_Mutex) ---
    rl.DrawCircleLines(i32(w.station_charger.pos.x), i32(w.station_charger.pos.y), w.station_charger.radius, rl.PURPLE)
    rl.DrawText("3. ENERGY CHARGER", i32(w.station_charger.pos.x) - 60, i32(w.station_charger.pos.y) - 85, 13, rl.PURPLE)
    rl.DrawText("[Fiber_Mutex Pad]", i32(w.station_charger.pos.x) - 48, i32(w.station_charger.pos.y) - 72, 11, rl.GRAY)

    for d in w.station_charger.drones {
        rl.DrawCircleV(d.pos, 9.0, d.color)
        rl.DrawText(fmt.ctprintf("#%d", d.id), i32(d.pos.x) - 5, i32(d.pos.y) - 5, 9, rl.BLACK)
        if d.is_charging {
            rl.DrawCircleLines(i32(d.pos.x), i32(d.pos.y), 13.0, rl.WHITE)
        }
    }

    // --- Station 4: Alert Beacon (Signal & Cancel_Token) ---
    is_locked_down := coroutine.cancel_token_is_cancelled(&w.lockdown_token)
    beacon_color := is_locked_down ? rl.RED : rl.ORANGE
    rl.DrawCircleLines(i32(w.station_beacon.pos.x), i32(w.station_beacon.pos.y), 28.0, beacon_color)
    rl.DrawText("4. ALERT BEACON", i32(w.station_beacon.pos.x) - 52, i32(w.station_beacon.pos.y) - 60, 13, beacon_color)
    subtext := is_locked_down ? "[LOCKDOWN: K to Reset]" : "[Signal & Cancel_Token: K]"
    rl.DrawText(fmt.ctprintf(subtext), i32(w.station_beacon.pos.x) - 65, i32(w.station_beacon.pos.y) - 48, 10, is_locked_down ? rl.RED : rl.GRAY)

    if is_locked_down {
        pulse_r := 65.0 + 8.0 * math.sin(w.global_time * 8.0)
        rl.DrawCircleLines(i32(w.station_beacon.pos.x), i32(w.station_beacon.pos.y), pulse_r, rl.Fade(rl.RED, 0.6))
    }

    for s in w.station_beacon.sentries {
        rl.DrawCircleV(s.pos, 8.0, s.is_alerted ? rl.RED : s.color)
        if s.is_alerted {
            rl.DrawText("!", i32(s.pos.x) - 3, i32(s.pos.y) - 16, 13, rl.RED)
            if is_locked_down {
                dir := linalg.normalize(s.pos - w.station_beacon.pos)
                rl.DrawLineEx(s.pos, s.pos + dir * 18.0, 2.0, rl.Fade(rl.RED, 0.8))
            }
        }
    }

    // --- Station 5: Loot Forge (Generator) ---
    rl.DrawRectangleLines(i32(w.station_forge.pos.x) - 45, i32(w.station_forge.pos.y) - 45, 90, 90, rl.GOLD)
    rl.DrawText("5. LOOT FORGE", i32(w.station_forge.pos.x) - 42, i32(w.station_forge.pos.y) - 68, 13, rl.GOLD)
    rl.DrawText("[Generator(T)]", i32(w.station_forge.pos.x) - 38, i32(w.station_forge.pos.y) - 55, 11, rl.GRAY)

    if w.station_forge.has_item {
        item := w.station_forge.current_item
        rl.DrawText(fmt.ctprintf("%s", item.name), i32(w.station_forge.pos.x) - 38, i32(w.station_forge.pos.y) - 12, 11, item.color)
        rl.DrawText(fmt.ctprintf("[%s] Pwr: %d", item.tier, item.power), i32(w.station_forge.pos.x) - 38, i32(w.station_forge.pos.y) + 6, 9, rl.LIGHTGRAY)
    } else {
        rl.DrawText("Press [5]/[E]", i32(w.station_forge.pos.x) - 35, i32(w.station_forge.pos.y) - 4, 10, rl.GRAY)
    }

    // --- Station 6: Async Research Lab (Async_Token & fiber_join) ---
    rl.DrawRectangleLines(i32(w.station_lab.pos.x) - 55, i32(w.station_lab.pos.y) - 45, 110, 90, rl.LIME)
    rl.DrawText("6. ASYNC LAB", i32(w.station_lab.pos.x) - 40, i32(w.station_lab.pos.y) - 68, 13, rl.LIME)
    rl.DrawText("[await_async & join]", i32(w.station_lab.pos.x) - 55, i32(w.station_lab.pos.y) - 55, 10, rl.GRAY)
    rl.DrawText(fmt.ctprintf("%s", w.station_lab.status_text), i32(w.station_lab.pos.x) - 75, i32(w.station_lab.pos.y) + 52, 9, w.station_lab.status_color)

    if w.station_lab.drone_active {
        rl.DrawCircleV(w.station_lab.drone_pos, 8.0, rl.PINK)
        rl.DrawCircleLines(i32(w.station_lab.drone_pos.x), i32(w.station_lab.drone_pos.y), 10.0, rl.WHITE)
    }

    // --- Station 7: Telemetry Log Feed (Channel(T) & Multi-Channel Select) ---
    panel_x: i32 = 980
    panel_y: i32 = 60
    panel_w: i32 = 280
    panel_h: i32 = 170
    rl.DrawRectangle(panel_x, panel_y, panel_w, panel_h, {12, 16, 24, 220})
    rl.DrawRectangleLines(panel_x, panel_y, panel_w, panel_h, {60, 100, 150, 255})
    rl.DrawText("7. MULTI-CHANNEL SELECT", panel_x + 10, panel_y + 8, 12, rl.SKYBLUE)
    rl.DrawLine(panel_x + 10, panel_y + 24, panel_x + panel_w - 10, panel_y + 24, {50, 70, 100, 255})

    log_y := panel_y + 30
    for msg in w.station_channel.recent_logs {
        color := strings.has_prefix(msg, "[SYS]") ? rl.GOLD : rl.LIGHTGRAY
        rl.DrawText(fmt.ctprintf("> %s", msg), panel_x + 12, log_y, 10, color)
        log_y += 18
    }

    // --- Station 8: Gate Construction Rendezvous (Fiber_Latch) ---
    rl.DrawRectangleLines(i32(w.station_gate.pos.x) - 60, i32(w.station_gate.pos.y) - 50, 120, 100, rl.VIOLET)
    rl.DrawText("8. GATE RENDEZVOUS", i32(w.station_gate.pos.x) - 62, i32(w.station_gate.pos.y) - 72, 13, rl.VIOLET)
    rl.DrawText("[Fiber_Latch 3-Way]", i32(w.station_gate.pos.x) - 55, i32(w.station_gate.pos.y) - 58, 10, rl.GRAY)

    for i in 0 ..< 3 {
        task := w.station_gate.tasks[i]
        ty := i32(w.station_gate.pos.y) - 30 + i32(i * 18)
        rl.DrawText(fmt.ctprintf("%s:", task.name), i32(w.station_gate.pos.x) - 50, ty, 9, task.color)
        rl.DrawRectangle(i32(w.station_gate.pos.x) + 5, ty + 2, 45, 6, rl.DARKGRAY)
        rl.DrawRectangle(i32(w.station_gate.pos.x) + 5, ty + 2, i32(45.0 * task.progress), 6, task.color)
    }

    if w.station_gate.portal_open {
        rl.DrawCircleV(w.station_gate.pos + {0, 60}, 24.0, rl.Fade(rl.VIOLET, w.station_gate.portal_alpha))
        rl.DrawCircleLines(i32(w.station_gate.pos.x), i32(w.station_gate.pos.y) + 60, 24.0, rl.WHITE)
        rl.DrawText("PORTAL OPEN", i32(w.station_gate.pos.x) - 35, i32(w.station_gate.pos.y) + 55, 9, rl.WHITE)
    }
    rl.DrawText(fmt.ctprintf("%s", w.station_gate.status_text), i32(w.station_gate.pos.x) - 80, i32(w.station_gate.pos.y) + 58, 9, rl.YELLOW)

    // --- Station 9: Laser Defense Turrets (Fiber_Semaphore) ---
    rl.DrawRectangleLines(460, 565, 360, 95, {160, 60, 60, 255})
    rl.DrawText("9. LASER DEFENSE GRID (Fiber_Semaphore: 2 Permits)", 475, 572, 12, rl.RED)

    for t in w.station_defense.turrets {
        rl.DrawCircleV(t.pos, 8.0, t.is_firing ? rl.RED : rl.GRAY)
        if t.is_firing {
            rl.DrawLineEx(t.pos, t.target_pos, 3.0, rl.Fade(rl.RED, t.laser_alpha))
            rl.DrawCircleV(t.target_pos, 4.0, rl.ORANGE)
        }
    }

    // --- Multicast Event(T) Toast Banner ---
    if w.toast_timer > 0.0 {
        rl.DrawRectangle(25, SCREEN_HEIGHT - 65, 450, 24, {20, 30, 45, 235})
        rl.DrawRectangleLines(25, SCREEN_HEIGHT - 65, 450, 24, w.toast_color)
        rl.DrawText(fmt.ctprintf("Event(T) Toast: %s — %s", w.toast_title, w.toast_desc), 35, SCREEN_HEIGHT - 60, 11, w.toast_color)
    }

    // --- Player Character ---
    rl.DrawCircleV(w.player.pos, w.player.radius, rl.WHITE)
    rl.DrawCircleLines(i32(w.player.pos.x), i32(w.player.pos.y), w.player.radius + 3.0, rl.LIME)

    // --- Instructions Header & Pause Banner ---
    if w.sched.is_paused {
        flash_col := w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD
        step_text := fmt.ctprintf("PAUSED: Step #%d (+%.3fs) | Sim Time: %.3fs | F4: 1-Frame | F5: 10-Frames | Hold F4: Slow-Mo", w.step_count, w.last_step_dt, w.global_time)
        rl.DrawRectangle(20, SCREEN_HEIGHT - 35, SCREEN_WIDTH - 40, 25, {15, 18, 30, 230})
        rl.DrawRectangleLines(20, SCREEN_HEIGHT - 35, SCREEN_WIDTH - 40, 25, flash_col)
        rl.DrawText(step_text, 30, SCREEN_HEIGHT - 30, 14, flash_col)
    } else {
        rl.DrawRectangle(20, SCREEN_HEIGHT - 35, SCREEN_WIDTH - 40, 25, {12, 14, 20, 220})
        rl.DrawText("WASD: Move | [1-7]/[E]: Trigger | K: Lockdown Token | F1: Tree | F3: Pause | F4: Step 1F", 30, SCREEN_HEIGHT - 28, 12, rl.RAYWHITE)
    }

    // --- Live Coroutine Hierarchy Visualizer Overlay (F1 / TAB) ---
    if w.show_coroutine_debugger {
        overlay_x: i32 = 30
        overlay_y: i32 = 40
        overlay_w: i32 = 640
        overlay_h: i32 = 620

        rl.DrawRectangle(overlay_x, overlay_y, overlay_w, overlay_h, {10, 12, 18, 245})
        rl.DrawRectangleLines(overlay_x, overlay_y, overlay_w, overlay_h, {0, 200, 255, 220})

        pause_header := ""
        if w.sched.is_paused {
            pause_header = fmt.tprintf("[PAUSED #%d (Sim: %.2fs) | F4: 1F, F5: 10F]", w.step_count, w.global_time)
        }
        rl.DrawText(fmt.ctprintf("COROUTINE HIERARCHY & STACK PROFILER (F1) %s", pause_header), overlay_x + 15, overlay_y + 12, 14, w.step_flash_timer > 0.0 ? rl.LIME : rl.GOLD)

        stats_line := fmt.ctprintf("Pool: %d Slabs | Stacks: %d | Active: %d | Free: %d | Memory: %d KB", stats.slabs_count, stats.total_stacks, stats.active_fibers, stats.free_fibers, stats.total_memory_kb)
        rl.DrawText(stats_line, overlay_x + 15, overlay_y + 28, 11, rl.SKYBLUE)

        rl.DrawLine(overlay_x + 10, overlay_y + 44, overlay_x + overlay_w - 10, overlay_y + 44, {60, 80, 120, 255})

        tree_y := overlay_y + 54

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
