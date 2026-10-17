# Tutorial 5: Synchronization & Communication — Signals, Events & Sync Primitives

Coroutines frequently need to communicate across independent systems, wait for broadcast game events, or share restricted gameplay resources without polling or OS thread locks.

The runtime organizes synchronization into two tiers:
1. **Core Zero-Allocation Primitives (`coroutine`)**: Unified multicast `Event(T)` & parameterless broadcast `Signal :: Event(struct{})`, dynamic `fiber_join`, and hierarchical `Fiber_Scope`.
2. **Optional Modular CSP & Locking (`coroutine/sync`)**: `Fiber_Mutex`, `Fiber_Semaphore`, typed `Channel(T)`, and Go-style `chan_select_recv`.

---

## 1. Zero-Polling Broadcast with `Signal` & `Event(T)` (True ZII)

A `Signal` allows any number of fibers to suspend waiting for a broadcast event without CPU polling. In this engine, `Signal` is a zero-size specialization: `Signal :: Event(struct{})`.

Built on **doubly-linked intrusive wait queues**, both require **0 heap allocations** and support **True Zero Is Initialization (ZII)**:

```odin
package main

import "core:fmt"
import "coroutine"

sentry_guard :: proc(f: ^coroutine.Fiber, id: int) {
    fmt.printf("[Sentry %d] Sleeping at outpost...\n", id)

    // Suspends fiber until alarm_signal is emitted!
    coroutine.signal_wait(f, &alarm_signal)

    fmt.printf("[Sentry %d] Woken by alarm! Engaging intruder!\n", id)
}

// True ZII: Ready to use immediately — no init required!
alarm_signal: coroutine.Signal

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // Spawn 4 sleeping sentries
    for i := 1; i <= 4; i += 1 {
        coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, id: int) {
            sentry_guard(f, id)
        }, i)
    }

    coroutine.scheduler_step(&sched, 0.1) // Sentries start sleeping

    fmt.println("\n>>> Player steps on alarm pressure plate! <<<")
    coroutine.signal_emit(&sched, &alarm_signal) // WAKES ALL 4 SENTRIES SIMULTANEOUSLY!

    coroutine.scheduler_step(&sched, 0.1)
}
```

---

## 2. 1-to-Many Typed Multicast with `Event(T)`
 
While `Signal` broadcasts empty notifications, `Event(T)` delivers a typed payload to all active listening fibers in a single broadcast without heap allocations:

```odin
Player_Death :: struct {
    victim:    string,
    killer_id: int,
}

death_event: coroutine.Event(Player_Death) // True ZII: waiters Wait_Queue zero-initialized!

// UI Audio Fiber
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ev: ^coroutine.Event(Player_Death)) {
    info, ok := coroutine.event_wait(f, ev)
    if ok do fmt.printf("[Audio] Playing death sting for %s killed by #%d!\n", info.victim, info.killer_id)
}, &death_event)

// Scoreboard Fiber
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ev: ^coroutine.Event(Player_Death)) {
    info, ok := coroutine.event_wait(f, ev)
    if ok do fmt.printf("[Scoreboard] Incrementing kill count for killer #%d!\n", info.killer_id)
}, &death_event)

// Broadcasts to ALL listening fibers in 1 tick:
coroutine.event_emit(&sched, &death_event, Player_Death{"Knight", 42})
```

---

## 2.5 Latched Milestones with `Sticky_Event(T)` & `Sticky_Signal`

Standard `Signal` and `Event(T)` are transient broadcasts: if a signal is emitted *before* an actor arrives to await it, the message is dropped.

In games, state transitions (such as `game_started`, `cutscene_finished`, or `boss_defeated`) are **latched milestones**: late-joining fibers should see that the milestone has already occurred and continue immediately without waiting.

```odin
Game_State :: struct {
    ready_signal: coroutine.Sticky_Signal,
    winner_event: coroutine.Sticky_Event(string),
}

game: Game_State

// Late-joining UI fiber arrives after ready_signal was already emitted:
ui_fiber :: proc(f: ^coroutine.Fiber) {
    // If ready_signal was already emitted, sticky_signal_wait returns IMMEDIATELY in O(1)!
    coroutine.sticky_signal_wait(f, &game.ready_signal)
    fmt.println("[UI] HUD initialized!")

    // Await sticky payload:
    winner, ok := coroutine.sticky_event_wait(f, &game.winner_event)
    if ok {
        fmt.printf("[UI] Victory banner displayed for %s!\n", winner)
    }
}
```

- **True ZII & Zero Allocations**: Requires no heap memory or dynamic queues.
- **State Reset**: Call `coroutine.sticky_signal_reset(&game.ready_signal)` or `coroutine.sticky_event_reset(&game.winner_event)` when resetting the game match.

---

## 3. Shared Resource Arbitration with `Fiber_Mutex` (`coroutine/sync`)

When multiple actors must access an exclusive gameplay station (e.g. an NPC dialogue booth, an ammo recharge station, or a crafting anvil), import `coroutine/sync`. With True ZII, mutexes inside game structs are immediately valid:

```odin
package main

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Charging_Station :: struct {
    mutex: sync.Fiber_Mutex, // True ZII: 24 bytes, 0 allocations, immediately ready!
}

drone_worker :: proc(f: ^coroutine.Fiber, id: int) {
    fmt.printf("[Drone %d] Arrived at charging bay. Requesting lock...\n", id)

    // Deadlock-proof scoped lock (guarantees release on exit or abort):
    sync.with_mutex(f, &station.mutex, proc(f: ^coroutine.Fiber, id: int) {
        fmt.printf(">>> [Drone %d] ACQUIRED CHARGING PAD! Recharging battery...\n", id)
        coroutine.wait(f, 1.0) // 1 second charging time
        fmt.printf("<<< [Drone %d] Recharged 100%%. Releasing pad.\n", id)
    }, id)
}

station: Charging_Station

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // Spawn 3 drones competing for 1 charging pad
    for i := 1; i <= 3; i += 1 {
        coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, id: int) {
            drone_worker(f, id)
        }, i)
    }

    // Step scheduler across 3 seconds of sequential charging
    for i := 0; i < 6; i += 1 {
        coroutine.scheduler_step(&sched, 0.6)
    }
}
```

---

## 4. CSP Typed Channels (`Channel(T)` in `coroutine/sync`)

For structured message passing between decoupled systems (e.g., Quest Director sending quest objective updates to the UI HUD):

```odin
package main

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Quest_Update :: struct {
    quest_name: string,
    step_desc:  string,
    is_done:    bool,
}

quest_director_proc :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(Quest_Update)) {
    sync.chan_send(f, ch, Quest_Update{"Goblin Cave", "Find Dungeon Key", false})
    coroutine.wait(f, 1.0)

    sync.chan_send(f, ch, Quest_Update{"Goblin Cave", "Defeat Goblin Shaman", false})
    coroutine.wait(f, 1.0)

    sync.chan_send(f, ch, Quest_Update{"Goblin Cave", "Quest Completed!", true})
}

ui_hud_proc :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(Quest_Update)) {
    for {
        // Suspends until the next message arrives
        update, ok := sync.chan_recv(f, ch)
        if !ok do break // Channel closed

        fmt.printf("[HUD Display] %s: %s\n", update.quest_name, update.step_desc)
        if update.is_done do break
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    quest_channel: sync.Channel(Quest_Update)
    sync.chan_init(&quest_channel, capacity = 4)
    defer sync.chan_destroy(&quest_channel)

    coroutine.spawn_ptr(&sched, quest_director_proc, &quest_channel)
    coroutine.spawn_ptr(&sched, ui_hud_proc, &quest_channel)

    for i := 0; i < 5; i += 1 {
        coroutine.scheduler_step(&sched, 0.6)
    }
}
```

---

## 5. Limiting Concurrency with `Fiber_Semaphore` & `with_semaphore`

When you want to allow up to $N$ fibers to concurrently access a shared pool (e.g. max 2 concurrent audio voices or max 3 simultaneous A* searches), use `sync.Fiber_Semaphore` or the deadlock-proof `sync.with_semaphore` helper:

```odin
pathfinding_sem: sync.Fiber_Semaphore
sync.semaphore_init(&pathfinding_sem, initial_permits = 3, max_permits = 3)

ai_pathfind_task :: proc(f: ^coroutine.Fiber, target_node: int) {
    // Deadlock-proof scoped acquire & auto-release:
    sync.with_semaphore(f, &pathfinding_sem, proc(f: ^coroutine.Fiber, node: int) {
        fmt.printf("Calculating path to node #%d...\n", node)
        coroutine.wait(f, 0.2)
    }, target_node)
}
```

---

## 6. Multi-Subsystem Rendezvous with Structured Concurrency

Rather than relying on specialized countdown barriers, Verse / Skookum structured concurrency solves rendezvous synchronization natively with `sync`:

```odin
// Game Manager Fiber:
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
    fmt.println("Waiting for Level, Textures, and Audio to finish loading...")

    // Runs all 3 loader branches in parallel and suspends until ALL finish:
    coroutine.sync(f,
        coroutine.branch(load_level_proc),
        coroutine.branch(load_textures_proc),
        coroutine.branch(load_audio_proc),
    )

    fmt.println("All 3 subsystems ready! Starting gameplay!")
})
```

If the subsystems are spawned independently under a shared `Fiber_Scope`, awaiting their completion is equally clean with `coroutine.scope_wait(f, &loading_scope)`.

---

## 7. Dynamic Task Joining with `fiber_join`

Wait for any independent fiber handle to finish, fail, or be cancelled in $O(1)$ time:

```odin
boss_cutscene_handle := coroutine.spawn(&sched, cinematic_intro_proc)

// Player controller waits for cutscene to finish:
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, cutscene: coroutine.Fiber_Handle) {
    ok := coroutine.fiber_join(f, cutscene)
    if ok {
        fmt.println("Cutscene completed! Enabling player controls!")
    }
}, boss_cutscene_handle)
```

---

## 8. Multi-Channel Multiplexing with `chan_select_recv` (`coroutine/sync`)

When a consumer fiber needs to receive messages from whichever channel has data available first with **$O(1)$ zero-polling event-driven suspension and instant in-place unlinking**, use `sync.chan_select_recv`:

```odin
package main

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Command :: struct {
    type_id: int,
    payload: string,
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    combat_chan, network_chan: sync.Channel(Command)
    sync.chan_init(&combat_chan, capacity = 4)
    sync.chan_init(&network_chan, capacity = 4)
    defer {
        sync.chan_destroy(&combat_chan)
        sync.chan_destroy(&network_chan)
    }

    // Unified consumer multiplexer fiber
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, env: ^Channels_Env) {
        channels := []^sync.Channel(Command){env.combat, env.network}

        for {
            // Suspends until ANY channel receives a message:
            ready_idx, cmd, ok := sync.chan_select_recv(f, channels)
            if !ok do break // Channel closed

            switch ready_idx {
            case 0:
                fmt.printf("[Combat Channel #0] Processed action: %s\n", cmd.payload)
            case 1:
                fmt.printf("[Network Channel #1] Received packet: %s\n", cmd.payload)
            }
        }
    }, &Channels_Env{&combat_chan, &network_chan})
}

Channels_Env :: struct {
    combat:  ^sync.Channel(Command),
    network: ^sync.Channel(Command),
}
```

### Non-Blocking Polling with `chan_try_select_recv`
If you need to check multiple channels immediately without suspending:

```odin
ready_idx, cmd, ok := sync.chan_try_select_recv(channels)
if ok {
    // Process command immediately
}
```

---

## 9. Sub-Scope Cancellation & Interruption Races

To isolate status effects (such as EMP blasts, stuns, or silences) without global pool searches, structure subsystem lifecycles using sub-scopes and interruption races:

```odin
package main

import "core:fmt"
import "coroutine"

Drone :: struct {
    entity_scope: coroutine.Fiber_Scope,
    combat_scope: coroutine.Fiber_Scope,
    is_alive:     bool,
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    drone := Drone{is_alive = true}
    defer {
        coroutine.scope_destroy(&sched, &drone.entity_scope)
        coroutine.scope_destroy(&sched, &drone.combat_scope)
    }

    // 1. Spawn fibers bound to specific sub-scopes:
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        fmt.println("[Combat Subsystem] Firing attacks...")
        coroutine.wait(f, 5.0)
    }, &drone, scope = &drone.combat_scope)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, d: ^Drone) {
        fmt.println("[Movement Subsystem] Cruising along patrol route...")
        coroutine.wait(f, 5.0)
    }, &drone, scope = &drone.entity_scope)

    coroutine.scheduler_step(&sched, 0.1)

    // 2. EMP blast triggers: cancel only the combat sub-scope in O(1) time!
    fmt.println("\n>>> EMP BLAST DETONATES! <<<")
    stunned := coroutine.scope_cancel(&sched, &drone.combat_scope)
    fmt.printf("Stunned %d active combat fibers; Movement remains unaffected.\n", stunned)

    coroutine.scheduler_step(&sched, 0.1)
}
```

---

## Next Steps
In [Tutorial 6: Offloading Heavy Compute](06_async_background_jobs.md), you will learn how to bridge OS background worker threads to coroutines with `await_async`.
