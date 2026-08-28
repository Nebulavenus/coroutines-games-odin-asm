# Tutorial 7: Stateful Iterators — Procedural Content with `Generator(T)`

Pull-based generators let you write infinite procedural sequences, loot roll tables, and dungeon graph traversals as simple imperative loops that yield values on demand.

---

## 1. Pull Generators vs. Push Iterators

In standard programming, generating a complex sequence (such as a multi-tier loot table or Fibonacci stream) typically requires:
1. **Arrays:** Allocating large heap slices up-front.
2. **Custom Struct State Machines:** Storing index offsets, state flags, and step counters across function calls.

A **`Generator(T)`** runs inside a dedicated lightweight 16 KB fiber stack. You write a standard `for` loop that calls `yield_value(f, value)`. The caller pulls elements one at a time using `generator_next(&gen)`:

```
 Consumer (Caller)                            Generator Fiber (16 KB Stack)
┌─────────────────────────┐                  ┌─────────────────────────────────┐
│ item, ok := gen_next(g) │ ───────────────► │ for item in loot_table {        │
│                         │                  │     coroutine.yield_value(f, i) │
│ (Receives value + true) │ ◄─────────────── │     // Suspends execution!      │
│                         │                  │ }                               │
└─────────────────────────┘                  └─────────────────────────────────┘
```

---

## 2. Complete Runnable Example: Procedural Loot Forge

```odin
package main

import "core:fmt"
import "coroutine"

Item_Rarity :: enum { Common, Uncommon, Rare, Epic, Legendary }

Loot_Item :: struct {
    name:   string,
    rarity: Item_Rarity,
    value:  int,
}

loot_forge_procedure :: proc(f: ^coroutine.Fiber, g: ^coroutine.Generator(Loot_Item)) {
    items := []Loot_Item{
        {"Rusty Iron Dagger",   .Common,    10},
        {"Reinforced Buckler",  .Uncommon,  45},
        {"Shadowfang Blade",    .Rare,     250},
        {"Dragonscale Cuirass", .Epic,     850},
        {"Celestial Sunblade",  .Legendary, 5000},
    }

    index := 0
    for {
        item := items[index % len(items)]
        index += 1

        // Yield value to caller and pause generator fiber!
        coroutine.yield_value(f, g, item)
    }
}

main :: proc() {
    // Initialize Generator with dedicated lightweight 16KB stack slab
    forge: coroutine.Generator(Loot_Item)
    coroutine.generator_init(&forge, loot_forge_procedure)
    defer coroutine.generator_destroy(&forge)

    fmt.println("=== OPENING 5 DUNGEON CHESTS ===")

    // Pull 5 items on demand
    for chest_id := 1; chest_id <= 5; chest_id += 1 {
        item, ok := coroutine.generator_next(&forge)
        if ok {
            fmt.printf("Chest #%d opened -> [%v] %s (Value: %d Gold)\n",
                chest_id, item.rarity, item.name, item.value)
        }
    }
}
```

---

## 3. Why 16KB Dedicated Stacks Matter

Standard coroutines in the engine allocate 32 KB stacks inside 1 MB master slabs. Because generators only execute single sequential loops, `generator_init` allocates a dedicated 16 KB single-stack slab.
- **64x Lower Memory Footprint:** Consumes only 16 KB of RAM.
- **Zero Heap Calls:** Free-list recycled automatically upon `generator_destroy`.
- **Zero CPU Idle Cost:** When not calling `generator_next`, the generator consumes 0% CPU.

---

## Next Steps
In [Tutorial 8: The 3-Tier Clock in Practice](08_multi_domain_clocks.md), you will master pause menus, time scale dilation, and fixed tick simulations.
