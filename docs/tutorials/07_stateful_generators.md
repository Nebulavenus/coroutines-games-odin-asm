# Tutorial 7: Procedural Generators & Streaming Sequences

Procedural content generation (such as rolling loot from drop tables, streaming procedural dialogue, or traversing dungeon graphs) requires clean sequential logic without tangled callback state machines.

In Odin, this is handled through two complementary patterns:
1. **Synchronous Pull Generators**: Lightweight structs storing sequence state, yielding items on demand with zero allocations.
2. **Asynchronous Coroutine Streams**: Fibers streaming values over time using `coroutine.Event(T)` or `sync.Channel(T)` with cooperative time delays.

---

## 1. Synchronous Pull Generators

For instant on-demand value generation (e.g. rolling loot when a chest is opened or generating tile positions), a simple struct with an iterator procedure is optimal and requires zero heap overhead:

```odin
package main

import "core:fmt"

Item_Rarity :: enum { Common, Uncommon, Rare, Epic, Legendary }

Loot_Item :: struct {
    name:   string,
    rarity: Item_Rarity,
    value:  int,
}

Loot_Table :: struct {
    items: []Loot_Item,
    index: int,
}

loot_table_init :: proc(table: ^Loot_Table) {
    table.items = []Loot_Item{
        {"Rusty Iron Dagger",   .Common,    10},
        {"Reinforced Buckler",  .Uncommon,  45},
        {"Shadowfang Blade",    .Rare,     250},
        {"Dragonscale Cuirass", .Epic,     850},
        {"Celestial Sunblade",  .Legendary, 5000},
    }
    table.index = 0
}

loot_table_next :: proc(table: ^Loot_Table) -> (item: Loot_Item, ok: bool) {
    if len(table.items) == 0 do return {}, false
    item = table.items[table.index % len(table.items)]
    table.index += 1
    return item, true
}

main :: proc() {
    table: Loot_Table
    loot_table_init(&table)

    fmt.println("=== OPENING 5 DUNGEON CHESTS ===")
    for chest_id := 1; chest_id <= 5; chest_id += 1 {
        if item, ok := loot_table_next(&table); ok {
            fmt.printf("Chest #%d opened -> [%v] %s (Value: %d Gold)\n",
                chest_id, item.rarity, item.name, item.value)
        }
    }
}
```

---

## 2. Asynchronous Temporal Streams with `coroutine/sync`

When item or event generation takes **time** (e.g. an NPC blacksmith forging weapons over several seconds, or a dialogue typewriter revealing characters line-by-line), use a coroutine producer paired with a `sync.Channel(T)`:

```odin
package main

import "core:fmt"
import "coroutine"
import sync "coroutine/sync"

Forged_Weapon :: struct {
    name:  string,
    power: int,
}

// Producer Fiber: Forges items over time
blacksmith_fiber :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(Forged_Weapon)) {
    recipes := []Forged_Weapon{
        {"Iron Shortsword", 12},
        {"Steel Longsword", 28},
        {"Mythril Claymore", 65},
    }

    for item in recipes {
        // Simulates forging time:
        fmt.printf("[Blacksmith] Hammering out %s...\n", item.name)
        coroutine.wait(f, 1.0)

        // Stream item to consumer:
        sync.chan_send(f, ch, item)
    }

    sync.chan_close(ch)
}

// Consumer Fiber: Collects items as they are ready
inventory_fiber :: proc(f: ^coroutine.Fiber, ch: ^sync.Channel(Forged_Weapon)) {
    for {
        item, ok := sync.chan_recv(f, ch)
        if !ok do break // Channel closed by blacksmith

        fmt.printf("[Inventory] Received fresh weapon: %s (Power: %d)\n", item.name, item.power)
    }
    fmt.println("[Inventory] Blacksmith finished order!")
}

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    forge_channel: sync.Channel(Forged_Weapon)
    sync.chan_init(&forge_channel, capacity = 2)
    defer sync.chan_destroy(&forge_channel)

    coroutine.spawn_ptr(&sched, blacksmith_fiber, &forge_channel)
    coroutine.spawn_ptr(&sched, inventory_fiber, &forge_channel)

    for i := 0; i < 40; i += 1 {
        coroutine.scheduler_step(&sched, 0.1)
    }
}
```

---

## 3. Advantages of Temporal Decoupling

1. **True Time Flow**: The consumer does not block the engine thread while waiting for the next forged item; the scheduler yields execution to rendering and input.
2. **Zero Polling**: When `forge_channel` is empty, `inventory_fiber` suspends via intrusive wait queues, consuming 0% CPU.
3. **Structured Lifetime**: Closing the channel cleanly terminates the consumer loop without boolean sentinel flags.

---

## Next Steps
In [Tutorial 8: Multi-Domain Clocks](08_multi_domain_clocks.md), you will learn how to use the indexed `Clock_Domain` architecture for pausable simulation, real-time UI, and fixed physics steps.
