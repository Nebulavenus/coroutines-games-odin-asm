// Minimal Node.js runner for Odin WebAssembly binaries
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

if (process.argv.length < 3) {
    console.error("Usage: node run_wasm.js <path/to/binary.wasm> [args...]");
    process.exit(1);
}

const wasmFile = path.resolve(process.argv[2]);
if (!fs.existsSync(wasmFile)) {
    console.error(`Error: File not found: ${wasmFile}`);
    process.exit(1);
}

const wasmBytes = fs.readFileSync(wasmFile);
let memory;

const importObject = {
    odin_env: {
        write: (fd, ptr, len) => {
            const buf = Buffer.from(memory.buffer, ptr, len);
            if (fd === 1) {
                process.stdout.write(buf);
            } else {
                process.stderr.write(buf);
            }
        },
        trap: () => {
            console.error("TRAP: Odin program triggered a trap");
            process.exit(1);
        },
        abort: () => {
            console.error("ABORT: Odin program aborted");
            process.exit(1);
        },
        alert: (ptr, len) => {
            const msg = Buffer.from(memory.buffer, ptr, len).toString("utf8");
            console.log("ALERT:", msg);
        },
        evaluate: () => {},
        time_now: () => BigInt(Date.now()),
        tick_now: () => performance.now(),
        time_sleep: (duration_ms) => {},
        sqrt: Math.sqrt,
        sin: Math.sin,
        cos: Math.cos,
        pow: Math.pow,
        fmuladd: (x, y, z) => x * y + z,
        ln: Math.log,
        exp: Math.exp,
        ldexp: (x, exp) => x * Math.pow(2, exp),
        round: Math.round,
        floor: Math.floor,
        ceil: Math.ceil,
        trunc: Math.trunc,
        rand_bytes: (ptr, len) => {
            const buf = Buffer.from(memory.buffer, ptr, len);
            crypto.randomFillSync(buf);
        },
    },
    odin_dom: {},
};

WebAssembly.instantiate(wasmBytes, importObject).then(result => {
    memory = result.instance.exports.memory;
    if (result.instance.exports._start) {
        result.instance.exports._start();
    } else if (result.instance.exports.main) {
        result.instance.exports.main();
    } else {
        console.error("Error: No _start or main entry point found in wasm module");
        process.exit(1);
    }
}).catch(err => {
    console.error("WebAssembly Runtime Error:", err);
    process.exit(1);
});
