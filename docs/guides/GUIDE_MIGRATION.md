# Migration Guide (`GUIDE_MIGRATION.md`)

This guide serves as a Rosetta Stone for engineers migrating to the **Odin Stackful Coroutine Engine** from Unity C# Coroutines, Unreal Latent Actions, or Stackless AST Coroutines.

---

## 1. Migrating from Unity C# Coroutines (`IEnumerator`)

Unity C# coroutines allocate heap objects (`IEnumerator` state machines and `yield return new WaitForSeconds()`) on every tick and cannot easily coordinate parallel tasks without third-party libraries (like UniTask).

| Unity C# Pattern | Odin Stackful Coroutine Equivalent | Why Odin is Superior |
| :--- | :--- | :--- |
| `yield return null;` | `coroutine.yield_frame(f)` | Zero GC allocations; native context switch. |
| `yield return new WaitForSeconds(2.0f);` | `coroutine.wait(f, 2.0)` | No heap object creation; cached min-heap indexing. |
| `yield return new WaitForSecondsRealtime(2.0f);` | `coroutine.wait_real(f, 2.0)` | Unpaused wall-clock timer domain. |
| Nested coroutines (`yield return StartCoroutine(...)`) | `coroutine.sync(f, { ... })` | Structured concurrency; parent automatically unwinds child subtrees on abort. |
| Coroutine cancellation (`StopCoroutine`) | `coroutine.fiber_cancel(f)` | Bottom-up recursive tree cancellation; zero lingering orphans. |

---

## 2. Migrating from Unreal Engine Latent Actions / Tasks

Unreal Engine uses `FLatentActionInfo` or C++ Task Graphs which require creating boilerplate structs and linking execution pins.

```odin
// Unreal: Requires custom FLatentAction class + Tick() implementation
// Odin: Just write a straight-line procedure!
fade_and_load :: proc(f: ^coroutine.Fiber) {
    coroutine.tween_f32(f, &ui_opacity, 0.0, 1.0, 0.5, coroutine.ease_linear)
    coroutine.wait(f, 0.2)
    load_next_map()
    coroutine.tween_f32(f, &ui_opacity, 1.0, 0.0, 0.5, coroutine.ease_linear)
}
```

---

## 3. Migrating from Stackless AST Coroutines

In stackless AST engines, saving state across yields requires wrapping variables in manual reference-counted structs (`Rc(T)`), preventing the use of standard local variables and loops. [Stackless Coroutines for Games in Odin](https://github.com/Nebulavenus/coroutines-games-odin)

In this stackful engine:
- Use standard Odin `for`, `if`, and `switch` statements directly.
- Local variables reside safely in the fiber's 32 KB stack.
- `context.temp_allocator` survives yields safely.
