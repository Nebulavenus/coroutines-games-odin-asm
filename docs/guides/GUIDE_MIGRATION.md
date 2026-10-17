# Migration Guide (`GUIDE_MIGRATION.md`)

This guide serves as a Rosetta Stone for engineers migrating to the **Odin Stackful Coroutine Engine** from Unity C# Coroutines, Unreal Latent Actions, or Stackless AST Coroutines.

---

## 1. Migrating from Unity C# Coroutines (`IEnumerator`)

Unity C# coroutines allocate heap objects (`IEnumerator` state machines and `yield return new WaitForSeconds()`) on every tick and cannot easily coordinate parallel tasks without third-party libraries (like UniTask).

| Unity C# Pattern | Odin Stackful Coroutine Equivalent | Why Odin is Superior |
| :--- | :--- | :--- |
| `yield return null;` | `coroutine.yield(f)` | Zero GC allocations; native context switch. |
| `yield return new WaitForSeconds(2.0f);` | `coroutine.wait(f, 2.0)` | No heap object creation; cached min-heap indexing. |
| `yield return new WaitForSecondsRealtime(2.0f);` | `coroutine.wait(f, 2.0)` *(on `CLOCK_REAL`)* | Explicit clock domain with zero API duplication. |
| Nested coroutines (`yield return StartCoroutine(...)`) | `coroutine.sync(f, ...)` | Structured concurrency; parent automatically unwinds child subtrees on abort. |
| Coroutine cancellation (`StopCoroutine`) | `coroutine.fiber_cancel(&sched, handle)` | Bottom-up recursive tree cancellation; zero lingering orphans. |

---

## 2. Migrating from Unreal Engine Latent Actions / Epic Verse

Unreal Engine C++ requires `FLatentActionInfo` boilerplate or complex state trees. Epic's **Verse**, however, uses structured time combinators (`sync`, `race`, `rush`) — which this library brings directly to Odin:

```odin
// Straight-line gameplay logic with structured concurrency:
fade_and_load :: proc(f: ^coroutine.Fiber) {
    // Race user skip vs cutscene duration:
    winner := coroutine.race(f,
        coroutine.branch(proc(f: ^coroutine.Fiber) {
            coroutine.wait(f, 5.0) // Cutscene duration
        }),
        coroutine.branch(proc(f: ^coroutine.Fiber) {
            for !player_pressed_skip() {
                coroutine.yield(f)
            }
        }),
    )

    load_next_map()
}
```

---

## 3. Migrating from Stackless AST Coroutines

In stackless AST engines, saving state across yields requires wrapping variables in manual reference-counted structs (`Rc(T)`), preventing the use of standard local variables and loops. [Stackless Coroutines for Games in Odin](https://github.com/Nebulavenus/coroutines-games-odin)

In this stackful engine:
- Use standard Odin `for`, `if`, and `switch` statements directly.
- Local variables reside safely in the fiber's 32 KB stack.
- `context.temp_allocator` survives yields safely.
