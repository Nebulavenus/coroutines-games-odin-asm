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

## Next Steps
In [Tutorial 6: Offloading Heavy Compute](06_async_background_jobs.md), you will learn how to bridge OS background worker threads to coroutines with `await_async`.
