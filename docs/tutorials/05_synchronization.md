# Tutorial 5: Synchronization & Communication — Signals, Mutexes & CSP Channels

Coroutines frequently need to communicate across independent systems, wait for broadcast game events, or share restricted gameplay resources without polling or OS thread locks.

---

## 1. Zero-Polling Event Broadcasting with `Signal`

A `Signal` allows any number of fibers to suspend waiting for a broadcast event without CPU polling:

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

alarm_signal: coroutine.Signal

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.signal_init(&alarm_signal)

    // Spawn 4 sleeping sentries
    for i := 1; i <= 4; i += 1 {
        coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, id: int) {
            sentry_guard(f, id)
        }, i)
    }

    coroutine.scheduler_step(&sched, 0.1) // Sentries start sleeping

    fmt.Println("\n>>> Player steps on alarm pressure plate! <<<")
    coroutine.signal_emit(&alarm_signal) // WAKES ALL 4 SENTRIES SIMULTANEOUSLY!

    coroutine.scheduler_step(&sched, 0.1)
}
```

---

## 2. Shared Resource Arbitration with `Fiber_Mutex`

When multiple actors must access an exclusive gameplay station (e.g. an NPC dialogue booth, an ammo recharge station, or a crafting anvil), use `Fiber_Mutex`:

```odin
package main

import "core:fmt"
import "coroutine"

Charging_Station :: struct {
    mutex: coroutine.Fiber_Mutex,
}

drone_worker :: proc(f: ^coroutine.Fiber, id: int) {
    fmt.printf("[Drone %d] Arrived at charging bay. Requesting lock...\n", id)

    // Suspends fiber if another drone is currently charging
    coroutine.mutex_lock(f, &station.mutex)

    fmt.printf(">>> [Drone %d] ACQUIRED CHARGING PAD! Recharging battery...\n", id)
    coroutine.wait(f, 1.0) // 1 second charging time

    fmt.printf("<<< [Drone %d] Recharged 100%%. Releasing pad.\n", id)
    coroutine.mutex_unlock(&station.mutex) // Hands pad to next drone in queue
}

station: Charging_Station

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.mutex_init(&station.mutex)

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

## 3. CSP Typed Channels (`Channel(T)`)

For structured message passing between decoupled systems (e.g., Quest Director sending quest objective updates to the UI HUD):

```odin
package main

import "core:fmt"
import "coroutine"

Quest_Update :: struct {
    quest_name: string,
    step_desc:  string,
    is_done:    bool,
}

quest_director_proc :: proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(Quest_Update)) {
    coroutine.chan_send(f, ch, Quest_Update{"Goblin Cave", "Find Dungeon Key", false})
    coroutine.wait(f, 1.0)

    coroutine.chan_send(f, ch, Quest_Update{"Goblin Cave", "Defeat Goblin Shaman", false})
    coroutine.wait(f, 1.0)

    coroutine.chan_send(f, ch, Quest_Update{"Goblin Cave", "Quest Completed!", true})
}

ui_hud_proc :: proc(f: ^coroutine.Fiber, ch: ^coroutine.Channel(Quest_Update)) {
    for {
        // Suspends until the next message arrives
        update, ok := coroutine.chan_recv(f, ch)
        if !ok do break // Channel closed

        fmt.printf("[HUD Display] %s: %s\n", update.quest_name, update.step_desc)
        if update.is_done do break
    }
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    quest_channel: coroutine.Channel(Quest_Update)
    coroutine.chan_init(&quest_channel, capacity = 4)
    defer coroutine.chan_destroy(&quest_channel)

    coroutine.spawn_ptr(&sched, quest_director_proc, &quest_channel)
    coroutine.spawn_ptr(&sched, ui_hud_proc, &quest_channel)

    for i := 0; i < 5; i += 1 {
        coroutine.scheduler_step(&sched, 0.6)
    }
}
```

---

## 4. 1-to-Many Typed Multicast with `Event(T)`

While `Signal` broadcasts empty notifications, `Event(T)` delivers a typed payload to all active listening fibers in a single broadcast:

```odin
Player_Death :: struct {
    victim:    string,
    killer_id: int,
}

death_event: coroutine.Event(Player_Death)
coroutine.event_init(&death_event)
defer coroutine.event_destroy(&death_event)

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

## 5. Limiting Concurrency with `Fiber_Semaphore`

When you want to allow up to $N$ fibers to concurrently access a shared pool (e.g. max 2 concurrent audio voices or max 3 simultaneous A* searches):

```odin
pathfinding_sem: coroutine.Fiber_Semaphore
coroutine.semaphore_init(&pathfinding_sem, initial_permits = 3, max_permits = 3)
defer coroutine.semaphore_destroy(&pathfinding_sem)

ai_pathfind_task :: proc(f: ^coroutine.Fiber, sem: ^coroutine.Fiber_Semaphore) {
    coroutine.semaphore_acquire(f, sem) // Suspends if all 3 permits are in use
    defer coroutine.semaphore_release(f.sched, sem)

    // Compute heavy path...
    coroutine.wait(f, 0.2)
}
```

---

## 6. Multi-Subsystem Rendezvous with `Fiber_Latch`

A `Fiber_Latch` acts as a countdown barrier initialized with count $N$. Waiting fibers block until $N$ subsystems have called `latch_count_down`:

```odin
loading_latch: coroutine.Fiber_Latch
coroutine.latch_init(&loading_latch, initial_count = 3) // Wait for 3 systems
defer coroutine.latch_destroy(&loading_latch)

// Game Manager Fiber:
coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, latch: ^coroutine.Fiber_Latch) {
    fmt.Println("Waiting for Level, Textures, and Audio to finish loading...")
    coroutine.latch_wait(f, latch)
    fmt.Println("All 3 subsystems ready! Starting gameplay!")
}, &loading_latch)

// Subsystems report completion:
coroutine.latch_count_down(&sched, &loading_latch) // Loaded Level
coroutine.latch_count_down(&sched, &loading_latch) // Loaded Textures
coroutine.latch_count_down(&sched, &loading_latch) // Loaded Audio -> Unblocks Game Manager!
```

---

## 7. Dynamic Task Joining with `fiber_join`

Wait for any independent fiber handle to finish, fail, or be cancelled:

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

## 8. Multi-Channel Multiplexing with `chan_select_recv`

When a consumer fiber needs to receive messages from whichever channel has data available first (similar to Go's `select` or CSP multiplexing), use `chan_select_recv`:

```odin
package main

import "core:fmt"
import "coroutine"

Command :: struct {
    type_id: int,
    payload: string,
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    combat_chan, network_chan: coroutine.Channel(Command)
    coroutine.chan_init(&combat_chan, capacity = 4)
    coroutine.chan_init(&network_chan, capacity = 4)
    defer {
        coroutine.chan_destroy(&combat_chan)
        coroutine.chan_destroy(&network_chan)
    }

    // Unified consumer multiplexer fiber
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, env: ^Channels_Env) {
        channels := []^coroutine.Channel(Command){env.combat, env.network}

        for {
            // Suspends until ANY channel receives a message:
            ready_idx, cmd, ok := coroutine.chan_select_recv(f, channels)
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
    combat:  ^coroutine.Channel(Command),
    network: ^coroutine.Channel(Command),
}
```

### Non-Blocking Polling with `chan_try_select_recv`
If you need to check multiple channels immediately without suspending:

```odin
ready_idx, cmd, ok := coroutine.chan_try_select_recv(channels)
if ok {
    // Process command immediately
}
```

---

## 9. Decoupled Cancellation with `Cancel_Token`

While `Fiber_Scope` provides structural, parent-child cancellations for entities, `Cancel_Token` provides a lightweight, explicit cancellation handle for cross-subsystem coordination:

```odin
package main

import "core:fmt"
import "coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    // 1. Initialize cancellation token
    game_over_tok: coroutine.Cancel_Token
    coroutine.cancel_token_init(&game_over_tok)
    defer coroutine.cancel_token_destroy(&game_over_tok)

    // 2. Multiple unrelated fibers await cancellation:
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, tok: ^coroutine.Cancel_Token) {
        fmt.Println("[Audio Subsystem] Music playing...")
        coroutine.cancel_token_wait(f, tok) // Suspends until cancelled
        fmt.Println("[Audio Subsystem] Game Over received! Fading out music.")
    }, &game_over_tok)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, tok: ^coroutine.Cancel_Token) {
        fmt.Println("[Physics Subsystem] Simulating world...")
        coroutine.cancel_token_wait(f, tok) // Suspends until cancelled
        fmt.Println("[Physics Subsystem] Game Over received! Freezing ragdolls.")
    }, &game_over_tok)

    coroutine.scheduler_step(&sched, 0.1)

    // 3. Trigger cancellation across all listeners simultaneously:
    fmt.Println("\n>>> PLAYER DIES: Triggering Game Over Token! <<<")
    coroutine.cancel_token_cancel(&sched, &game_over_tok)

    coroutine.scheduler_step(&sched, 0.1)
}
```

---

## Next Steps
In [Tutorial 6: Offloading Heavy Compute](06_async_background_jobs.md), you will learn how to bridge OS background worker threads to coroutines with `await_async`.
