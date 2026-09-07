# Browser Game Port & Zero-C Canvas 2D Adapter

This document details the architecture used to port the desktop Raylib game demo (`examples/game`) to WebAssembly (`js_wasm32`), explaining the **Zero-C HTML5 Canvas 2D Adapter**, WebAssembly C ABI memory passing conventions, browser input handling, and the headless testing pipeline.

---

## 1. Zero-C Architecture Overview

Most WebAssembly game ports rely on Emscripten and heavy compiled C runtimes (like full raylib compiled to `.wasm` or SDL2). This introduces complex multi-gigabyte SDK toolchains, slow compilation, and binary bloat.

Our implementation uses a **Zero-C Architecture**:
1. The Odin game code is compiled directly with `odin build examples/game -target:js_wasm32`.
2. All 21 Raylib graphics and input procedures are bound as foreign imports in package `rl`:
   ```odin
   foreign import raylib "raylib"
   @(default_calling_convention="c")
   foreign raylib {
       DrawCircleV :: proc(position: Vector2, radius: f32, color: Color) ---
       DrawRectangle :: proc(posX, posY, width, height: i32, color: Color) ---
       IsKeyDown :: proc(key: KeyboardKey) -> bool ---
       // ...
   }
   ```
3. A 250-line pure JavaScript file (`tools/web/raylib_canvas.js`) implements all 21 procedures directly against the standard browser `<canvas>` 2D rendering context (`CanvasRenderingContext2D`).

```text
┌─────────────────────────────────────────────────────────────┐
│                 Odin Game Logic (WebAssembly)               │
│                  examples/game/main.odin                    │
└──────────────────────────────┬──────────────────────────────┘
                               │ C ABI Foreign Imports
┌──────────────────────────────▼──────────────────────────────┐
│           Lightweight JS Adapter (tools/web/raylib_canvas.js)│
│     • unpackColor (Direct linear memory pointer reads)       │
│     • Key / Mouse Input State Maps                           │
└──────────────────────────────┬──────────────────────────────┘
                               │ Canvas2D API Calls
┌──────────────────────────────▼──────────────────────────────┐
│                  Browser DOM / HTML5 <canvas>                │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. WebAssembly C ABI Struct Passing Quirks

When interacting with JavaScript via WebAssembly foreign imports, understanding the LLVM/Clang C ABI on `wasm32` is critical.

### The Struct-by-Pointer Convention
Consider a simple procedure declaration in Odin:
```odin
DrawCircleV :: proc(position: Vector2, radius: f32, color: Color)
```
Where `Color` is a 4-byte struct:
```odin
Color :: struct {
    r, g, b, a: u8,
}
```
One might expect the WebAssembly export to receive `color` as an integer scalar (`i32`). However, according to the **WebAssembly C ABI Specification**:
- Small non-aggregate types (`f32`, `i32`, `f64`) pass via VM registers.
- **Aggregate struct types (`Color`) are passed by POINTER into linear memory!**

If the JavaScript import receives `(posX, posY, radius, color_ptr)`:
- `color_ptr` is an **offset in `memory.buffer`**, not a 32-bit hex integer!
- Passing `color_ptr` directly as `rgba(..., ..., ..., ...)` results in black or completely transparent rendering.

### The JavaScript `unpackColor` Solution
In `tools/web/raylib_canvas.js`, color arguments are unpacked directly from the WebAssembly instance's linear memory buffer:

```javascript
// tools/web/raylib_canvas.js
function unpackColor(wasmMemory, colorPtrOrVal) {
    if (!wasmMemory || !wasmMemory.buffer) return 'rgba(255,255,255,1.0)';
    const view = new DataView(wasmMemory.buffer);
    const r = view.getUint8(colorPtrOrVal);
    const g = view.getUint8(colorPtrOrVal + 1);
    const b = view.getUint8(colorPtrOrVal + 2);
    const a = view.getUint8(colorPtrOrVal + 3);
    return `rgba(${r},${g},${b},${(a / 255).toFixed(3)})`;
}
```

This ensures 100% color fidelity and enables full opacity, gradients, and particle alpha blends.

---

## 3. Browser Lifecycle & Event Loop Integration

Native desktop games execute an infinite blocking loop:
```odin
// Native Desktop (Blocking Loop)
for !rl.WindowShouldClose() {
    game_step()
    rl.BeginDrawing()
    game_render()
    rl.EndDrawing()
}
```
In the browser, an infinite blocking loop freezes the tab and triggers the browser's "Page Unresponsive" dialog.

### The Exported Web Lifecycle Hooks
For `js_wasm32`, `examples/game/main.odin` exports discrete lifecycle hooks:

```odin
@(export)
game_wasm_init :: proc() {
    rl.InitWindow(1280, 720, "Boss Fight Web")
    game_init(&g_game)
}

@(export)
game_wasm_step :: proc(dt: f32) {
    // 1. Advance coroutine scheduler
    scheduler_step(&g_game.sched, dt)
    // 2. Render active frame to canvas
    game_draw(&g_game)
}

@(export)
game_wasm_destroy :: proc() {
    game_destroy(&g_game)
}
```

The host HTML file (`tools/web/index.html`) drives the loop via `requestAnimationFrame`:
```javascript
let lastTime = performance.now();
function loop(now) {
    const dt = Math.min((now - lastTime) / 1000.0, 0.1);
    lastTime = now;
    wasmInstance.exports.game_wasm_step(dt);
    requestAnimationFrame(loop);
}
requestAnimationFrame(loop);
```

---

## 4. Modern Browser Controls & Input Hygiene

Standard desktop keyboard shortcuts frequently collide with browser reserved shortcuts:
- `F1` (Opens Browser Help)
- `F5` (Hard Page Reload)
- `F11` (Fullscreen Toggle)
- `F12` (Opens Browser DevTools)
- `Space` / `Arrow Keys` (Scrolls Page)

### Ergonomic Web Keybindings
All game controls were modernized to browser-safe ergonomic letter keys:
- **`WASD` / `Arrows`**: Player Ship Navigation.
- **`Space`**: Primary Blaster Cannon.
- **`E`**: EMP Shockwave Stun.
- **`P`**: Pause / Resume Simulation Time.
- **`H`**: Toggle Live Coroutine Hierarchy HUD.
- **`N` / `M`**: Advance Single Frame Step when paused.
- **`R` / `Enter`**: Instant Game Restart after victory or defeat.

### Default Event Prevention
In `tools/web/raylib_canvas.js`, all recognized game keys call `event.preventDefault()`:
```javascript
window.addEventListener('keydown', (e) => {
    if (['Space', 'KeyE', 'KeyP', 'KeyH', 'KeyN', 'KeyM', 'KeyR', 'ArrowUp', 'ArrowDown'].includes(e.code)) {
        e.preventDefault();
    }
    keyState[e.code] = true;
});
```
This prevents the browser window from scrolling, zooming, or losing focus during gameplay.

---

## 5. itch.io Hosting & Distribution

The web game template (`tools/web/index.html`) is designed for seamless embedding inside iframe environments like [itch.io](https://itch.io):

### Packaging for itch.io
Run the automated packaging command:
```powershell
.\build.ps1 pack-itch
```
This produces `build/boss_fight_itch.zip`, which packages `index.html`, `game_opt.wasm`, and `raylib_canvas.js` **directly at the root of the archive** without nested subdirectories, as required by itch.io.

### Recommended itch.io Dashboard Settings
When configuring the project page on itch.io:
- **Kind of project**: `HTML` (You have a ZIP or HTML file that will be played in the browser).
- **Uploads**: Upload `boss_fight_itch.zip` and check the checkbox **"This file will be played in the browser"**.
- **Viewport dimensions**: `1280` px width by `720` px height.
- **Orientation**: Landscape.
- **Options**:
  - Check **"Enable fullscreen button"** (the template supports responsive canvas scaling across all resolutions).
  - Uncheck scrollbars (the template has `overflow: hidden; margin: 0; padding: 0;` to prevent double scrollbars).
