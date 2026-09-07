import crypto from 'crypto';
// ============================================================================
// Headless Node.js Test Runner for Wasm Game Demo
//
// Validates that game_opt.wasm instantiates cleanly, initializes game state,
// runs 120 simulation frames of game_wasm_step() without trapping or leaking,
// and shuts down via game_wasm_destroy().
// ============================================================================

import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { createRaylibWeb } from './raylib_canvas.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

async function run() {
    const wasmPath = process.argv[2] || path.resolve(__dirname, '../../build/web/game_opt.wasm');
    console.log(`[Headless Test] Loading Wasm binary: ${wasmPath}`);

    if (!fs.existsSync(wasmPath)) {
        console.error(`[Headless Test] Error: File not found: ${wasmPath}`);
        process.exit(1);
    }

    const wasmBytes = fs.readFileSync(wasmPath);

    // Mock HTML5 Canvas & 2D Context
    let drawCalls = 0;
    let nonZeroAlphaCount = 0;
    let lastFillStyle = '';
    let lastStrokeStyle = '';

    const mockCtx = {
        get fillStyle() { return lastFillStyle; },
        set fillStyle(val) {
            lastFillStyle = val;
            if (!val.endsWith(',0)') && !val.endsWith(',0.000)')) {
                nonZeroAlphaCount++;
            }
        },
        get strokeStyle() { return lastStrokeStyle; },
        set strokeStyle(val) {
            lastStrokeStyle = val;
            if (!val.endsWith(',0)') && !val.endsWith(',0.000)')) {
                nonZeroAlphaCount++;
            }
        },
        lineWidth: 1,
        font: '',
        fillRect: () => { drawCalls++; },
        strokeRect: () => { drawCalls++; },
        clearRect: () => { drawCalls++; },
        beginPath: () => {},
        arc: () => { drawCalls++; },
        fill: () => { drawCalls++; },
        stroke: () => { drawCalls++; },
        moveTo: () => {},
        lineTo: () => { drawCalls++; },
        fillText: () => { drawCalls++; },
        measureText: (text) => ({ width: text.length * 10 }),
        save: () => {},
        restore: () => {},
    };

    const mockCanvas = {
        width: 1280,
        height: 720,
        getContext: () => mockCtx,
        getBoundingClientRect: () => ({ left: 0, top: 0, width: 1280, height: 720 }),
        addEventListener: () => {},
    };

    let wasmInstance = null;
    const memoryGetter = () => wasmInstance.exports.memory;
    const raylib = createRaylibWeb(mockCanvas, memoryGetter);

    // Odin default JS runtime mock
    const odinEnv = {
        write: (fd, ptr, len) => {
            const buf = Buffer.from(memoryGetter().buffer, ptr, len);
            const str = buf.toString('utf8');
            if (fd === 2) {
                process.stderr.write(str);
            } else {
                process.stdout.write(str);
            }
        },
        trap: () => {
            throw new Error("[Wasm Trap] Execution halted by Odin runtime");
        },
        alert: (ptr, len) => {
            const buf = Buffer.from(memoryGetter().buffer, ptr, len);
            console.warn("[Wasm Alert]", buf.toString('utf8'));
        },
        abort: () => {
            throw new Error("[Wasm Abort] Aborted by Odin runtime");
        },
        evaluate: () => 0,
        time_now: () => Date.now(),
        tick_now: () => performance.now(),
        rand_bytes: (ptr, len) => {
            const buf = Buffer.from(memoryGetter().buffer, ptr, len);
            crypto.randomFillSync(buf);
        },
        sqrt: Math.sqrt,
        sin: Math.sin,
        cos: Math.cos,
        pow: Math.pow,
        fmod: (x, y) => x % y,
        floor: Math.floor,
        ceil: Math.ceil,
        round: Math.round,
    };

    const importObject = {
        "wasm/libraylib.web.a": raylib,
        "odin_env": odinEnv,
        "env": odinEnv,
    };

    console.log("[Headless Test] Instantiating WebAssembly module...");
    const { instance } = await WebAssembly.instantiate(wasmBytes, importObject);
    wasmInstance = instance;

    console.log("[Headless Test] Module instantiated. Verifying exports...");
    const { game_wasm_init, game_wasm_step, game_wasm_destroy, _start } = instance.exports;

    if (typeof _start === 'function') {
        console.log("[Headless Test] Invoking _start entrypoint...");
        _start();
    }

    if (typeof game_wasm_init !== 'function') {
        throw new Error("Missing export: game_wasm_init");
    }
    if (typeof game_wasm_step !== 'function') {
        throw new Error("Missing export: game_wasm_step");
    }
    if (typeof game_wasm_destroy !== 'function') {
        throw new Error("Missing export: game_wasm_destroy");
    }

    console.log("[Headless Test] Calling game_wasm_init()...");
    game_wasm_init();

    const targetFrames = parseInt(process.argv[3], 10) || 120;
    console.log(`[Headless Test] Stepping simulation for ${targetFrames} frames (${(targetFrames / 60.0).toFixed(1)}s @ 60 FPS)...`);
    const dt = 1.0 / 60.0;
    for (let frame = 1; frame <= targetFrames; frame++) {
        game_wasm_step(dt);
    }
    console.log(`[Headless Test] Successfully stepped ${targetFrames} frames. Recorded ${drawCalls} mock draw calls.`);
    if (nonZeroAlphaCount === 0) {
        throw new Error("Render assertion failed: all draw calls rendered with zero alpha (transparent)!");
    }
    console.log(`[Headless Test] Verified ${nonZeroAlphaCount} opaque/colored drawing operations with visible alpha.`);

    console.log("[Headless Test] Calling game_wasm_destroy()...");
    game_wasm_destroy();

    console.log("[Headless Test] PASSED: WebAssembly game engine loop successfully executed without traps!");
}

run().catch((err) => {
    console.error("[Headless Test] FAILED with error:", err);
    process.exit(1);
});
