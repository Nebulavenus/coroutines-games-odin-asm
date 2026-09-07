// ============================================================================
// Lightweight HTML5 Canvas 2D Adapter for Raylib on WebAssembly
//
// Implements the 21 Raylib functions imported by examples/game/main.odin
// directly to HTML5 Canvas 2D and browser DOM input events. Zero external C/Wasm libs.
// ============================================================================

export function createRaylibWeb(canvas, memoryGetter) {
    const ctx = canvas ? canvas.getContext('2d') : null;

    let width = canvas ? canvas.width : 1280;
    let height = canvas ? canvas.height : 720;
    let lastFrameTime = 1.0 / 60.0;
    let fps = 60;

    // Mouse & Keyboard input states
    const keysDown = new Set();
    const keysPressed = new Set();
    const mouseDown = new Set();
    const mousePressed = new Set();

    let mouseX = 0;
    let mouseY = 0;

    // Raylib Keycode Mappings (matches GLFW / Raylib Key enum)
    const KEY_MAP = {
        'KeyW': 87, 'KeyA': 65, 'KeyS': 83, 'KeyD': 68,
        'KeyJ': 74, 'KeyK': 75, 'KeyZ': 90, 'KeyX': 88,
        'KeyE': 69, 'KeyB': 66, 'KeyR': 82, 'KeyP': 80,
        'KeyH': 72, 'KeyT': 84, 'KeyN': 78, 'KeyM': 77,
        'ArrowUp': 265, 'ArrowDown': 264, 'ArrowLeft': 263, 'ArrowRight': 262,
        'Space': 32, 'Tab': 258, 'Enter': 257, 'Escape': 256,
        'Period': 46, 'Comma': 44,
        'ShiftLeft': 340, 'ShiftRight': 340,
        'F1': 290, 'F2': 291, 'F3': 292, 'F4': 293, 'F5': 294
    };

    if (typeof window !== 'undefined' && canvas) {
        window.addEventListener('keydown', (e) => {
            const code = KEY_MAP[e.code] || e.keyCode;
            if (code) {
                if (!keysDown.has(code)) {
                    keysPressed.add(code);
                }
                keysDown.add(code);
            }
            if (e.code === 'Space' || e.code === 'Tab' || e.code.startsWith('Arrow') || e.code === 'F1' || e.code === 'F3' || e.code === 'F4' || e.code === 'F5') {
                e.preventDefault();
            }
        });

        window.addEventListener('keyup', (e) => {
            const code = KEY_MAP[e.code] || e.keyCode;
            if (code) {
                keysDown.delete(code);
            }
        });

        canvas.addEventListener('mousemove', (e) => {
            const rect = canvas.getBoundingClientRect();
            const scaleX = canvas.width / rect.width;
            const scaleY = canvas.height / rect.height;
            mouseX = (e.clientX - rect.left) * scaleX;
            mouseY = (e.clientY - rect.top) * scaleY;
        });

        canvas.addEventListener('mousedown', (e) => {
            const btn = e.button; // 0: Left, 1: Middle, 2: Right
            if (!mouseDown.has(btn)) {
                mousePressed.add(btn);
            }
            mouseDown.add(btn);
        });

        window.addEventListener('mouseup', (e) => {
            const btn = e.button;
            mouseDown.delete(btn);
        });

        canvas.addEventListener('contextmenu', (e) => e.preventDefault());
    }

    function getMemView() {
        const mem = memoryGetter();
        return new DataView(mem.buffer);
    }

    function readString(ptr) {
        if (!ptr) return '';
        const mem = memoryGetter();
        const bytes = new Uint8Array(mem.buffer);
        let end = ptr;
        while (bytes[end] !== 0) end++;
        const decoder = new TextDecoder('utf-8');
        return decoder.decode(bytes.subarray(ptr, end));
    }

    function unpackColor(color) {
        if (typeof color !== 'number') return 'rgba(255,255,255,1)';
        const mem = memoryGetter();
        // In Odin Wasm32 C ABI, Color struct ({r, g, b, a: u8}) is passed as a pointer into linear memory
        if (mem && color >= 0 && color + 4 <= mem.buffer.byteLength) {
            const bytes = new Uint8Array(mem.buffer, color, 4);
            const a = (bytes[3] / 255.0).toFixed(3);
            return `rgba(${bytes[0]},${bytes[1]},${bytes[2]},${a})`;
        }
        // Fallback for packed 32-bit integer color
        const r = color & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = (color >> 16) & 0xFF;
        const a = (((color >> 24) & 0xFF) / 255.0).toFixed(3);
        return `rgba(${r},${g},${b},${a})`;
    }

    let firstFrameLogged = false;
    let loggedDrawCircle = 0;

    return {
        // --- Input Queries ---
        IsKeyPressed: (k) => (keysPressed.has(k) ? 1 : 0),
        IsKeyDown: (k) => (keysDown.has(k) ? 1 : 0),
        IsMouseButtonPressed: (b) => (mousePressed.has(b) ? 1 : 0),
        IsMouseButtonDown: (b) => (mouseDown.has(b) ? 1 : 0),
        GetMousePosition: (retPtr) => {
            const view = getMemView();
            view.setFloat32(retPtr, mouseX, true);
            view.setFloat32(retPtr + 4, mouseY, true);
        },

        // --- Render Lifecycle ---
        BeginDrawing: () => {},
        EndDrawing: () => {
            // Per-frame clear of transient pressed inputs
            keysPressed.clear();
            mousePressed.clear();
        },
        ClearBackground: (color) => {
            if (!ctx) return;
            const style = unpackColor(color);
            if (!firstFrameLogged) {
                firstFrameLogged = true;
                console.log(`[Raylib 2D Canvas] First frame render started! Canvas: ${width}x${height}, Clear color: ${style}`);
            }
            ctx.fillStyle = style;
            ctx.fillRect(0, 0, width, height);
        },

        // --- Geometric Primitives ---
        DrawCircleV: (centerPtr, radius, color) => {
            if (!ctx) return;
            const view = getMemView();
            const x = view.getFloat32(centerPtr, true);
            const y = view.getFloat32(centerPtr + 4, true);
            const style = unpackColor(color);
            if (loggedDrawCircle < 4) {
                loggedDrawCircle++;
                console.log(`[Raylib 2D Canvas] DrawCircleV #${loggedDrawCircle} at (${x.toFixed(1)}, ${y.toFixed(1)}) r=${radius} color=${style}`);
            }
            ctx.fillStyle = style;
            ctx.beginPath();
            ctx.arc(x, y, radius, 0, Math.PI * 2);
            ctx.fill();
        },
        DrawCircleLinesV: (centerPtr, radius, color) => {
            if (!ctx) return;
            const view = getMemView();
            const x = view.getFloat32(centerPtr, true);
            const y = view.getFloat32(centerPtr + 4, true);
            ctx.strokeStyle = unpackColor(color);
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.arc(x, y, radius, 0, Math.PI * 2);
            ctx.stroke();
        },
        DrawLine: (x1, y1, x2, y2, color) => {
            if (!ctx) return;
            ctx.strokeStyle = unpackColor(color);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.stroke();
        },
        DrawLineV: (p1Ptr, p2Ptr, color) => {
            if (!ctx) return;
            const view = getMemView();
            const x1 = view.getFloat32(p1Ptr, true);
            const y1 = view.getFloat32(p1Ptr + 4, true);
            const x2 = view.getFloat32(p2Ptr, true);
            const y2 = view.getFloat32(p2Ptr + 4, true);
            ctx.strokeStyle = unpackColor(color);
            ctx.beginPath();
            ctx.moveTo(x1, y1);
            ctx.lineTo(x2, y2);
            ctx.stroke();
        },
        DrawRectangle: (x, y, w, h, color) => {
            if (!ctx) return;
            ctx.fillStyle = unpackColor(color);
            ctx.fillRect(x, y, w, h);
        },
        DrawRectangleLines: (x, y, w, h, color) => {
            if (!ctx) return;
            ctx.strokeStyle = unpackColor(color);
            ctx.lineWidth = 1;
            ctx.strokeRect(x, y, w, h);
        },
        DrawText: (textPtr, x, y, size, color) => {
            if (!ctx) return;
            const text = readString(textPtr);
            ctx.fillStyle = unpackColor(color);
            ctx.font = `${size}px monospace`;
            ctx.textBaseline = 'top';
            ctx.fillText(text, x, y);
        },

        // --- Window & Timing ---
        GetFPS: () => fps,
        GetFrameTime: () => lastFrameTime,
        InitWindow: (w, h, titlePtr) => {
            width = w;
            height = h;
            if (canvas) {
                canvas.width = w;
                canvas.height = h;
            }
        },
        SetTargetFPS: (target) => {
            fps = target || 60;
        },
        WindowShouldClose: () => 0,
        CloseWindow: () => {},

        // Helper to update frame time from requestAnimationFrame
        setFrameDt: (dt) => {
            lastFrameTime = dt;
            if (dt > 0) fps = Math.round(1.0 / dt);
        }
    };
}
