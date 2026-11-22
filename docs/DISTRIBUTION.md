# Vendoring & Distribution Guide

`coroutines_asm` is designed to be vendored into Odin projects with zero friction. It supports two primary distribution paradigms:

1. **Direct Package Drop-in (`shared:coroutine`)**: Clone or submodule this repository directly.
2. **Amalgamated Single-File Drop-in (`dist/coroutine.odin`)**: A single self-contained native file (~3,360 lines; plus `dist/coroutine_wasm32.odin` at ~3,000 lines for WebAssembly) with unified imports.

---

## Method 1: Shared Package (`odin:shared`) — Recommended

Odin natively searches `<odin_dir>/shared/` for shared libraries.

### Installation
Clone this repository directly into your Odin installation's `shared/` directory:
```bash
git clone https://github.com/Nebulavenus/coroutines-games-odin-asm.git <path-to-odin>/shared/coroutine
```

### Usage
In any Odin file in any project:
```odin
package main

import "core:fmt"
import "shared:coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.println("Running fiber!")
        coroutine.yield(f)
    })

    coroutine.scheduler_step(&sched, 0.016)
}
```
No compiler flags or custom build steps required!

---

## Method 2: Project-Local Collection / Git Submodule (`libs:coroutine`)

If you prefer keeping dependencies checked into your repository under a `libs/` folder without touching the global Odin compiler installation:

### Installation
Add the repository as a git submodule (or clone it) into your project's `libs/` directory:
```bash
git submodule add https://github.com/Nebulavenus/coroutines-games-odin-asm.git libs/coroutine
```
Your project layout will look like:
```text
my_project/
├── libs/
│   └── coroutine/          # Cloned repo root (package coroutine)
│       ├── api.odin
│       ├── pool.odin
│       ├── scheduler.odin
│       └── ...
└── src/
    └── main.odin
```

### Build Command
Define a collection named `libs` pointing to your local `libs/` directory:
```bash
odin build src -collection:libs=libs
```

### Usage
In your application code, import directly through the `libs` collection:
```odin
package main

import "core:fmt"
import "libs:coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.println("Running fiber via libs collection!")
        coroutine.yield(f)
    })

    coroutine.scheduler_step(&sched, 0.016)
}
```

Or if you don't use collections, you can always use a relative path:
```odin
import coroutine "../libs/coroutine"
```

---

## Method 3: Amalgamated Single-File Drop-in (`dist/coroutine.odin`)

For developers who want a single-file drop-in without submodules or git management (similar to `stb_image` or `miniaudio`).

### Generating the Amalgamated File
Run the standalone amalgamation script from the repository:
```bash
python tools/amalgamate.py --all-targets
```
Or via PowerShell:
```powershell
.\build.ps1 dist
```
This generates `dist/coroutine.odin` (native AMD64, ARM64, RISC-V 64) and `dist/coroutine_wasm32.odin` (WebAssembly `js_wasm32`).

### Drop-in Setup
Because Odin requires all `.odin` files in a directory to share the same package name, place `coroutine.odin` in its own folder:
```
my_project/
├── coroutine/
│   └── coroutine.odin
└── src/
    └── main.odin
```

### Usage
```odin
package main

import "core:fmt"
import coroutine "../coroutine"

main :: proc() {
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber) {
        fmt.println("Fiber running from single-file drop-in!")
    })

    coroutine.scheduler_step(&sched, 0.016)
}
```

---

## Supported Target Architectures & Operating Systems

| Architecture | Operating Systems | Context Switch Implementation | ABI Standard |
| :--- | :--- | :--- | :--- |
| **AMD64 (x86_64)** | Windows | 100% high-level inline `asm` (0 `#byte`) | Microsoft x64 (Win64) |
| **AMD64 (x86_64)** | Linux, macOS, FreeBSD | 100% high-level inline `asm` (0 `#byte`) | System V AMD64 ABI |
| **ARM64 (aarch64)** | Linux, macOS, Android | Hybrid high-level `asm` (`#pre`/`#post` SP + GPRs; 8 `#byte` for `d8..d15`) | AAPCS64 Standard |
| **RISC-V 64** | Linux | Hybrid high-level `asm` (SP + GPRs; 24 `#byte` for `fs0..fs11`) | LP64D ABI |

All remaining `#byte` sequences are verified down to individual opcodes using Odin's `core:rexcode` disassembler.
