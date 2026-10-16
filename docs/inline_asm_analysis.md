# Odin Inline Assembly (`asm`) Compiler Analysis & Context Switch Architecture

This document details the interaction between Odin's inline assembly (`asm`) subsystem (`Odin\src\check_asm.cpp`, `Odin\src\check_asm_cfg.cpp`, `Odin\src\llvm_backend_asm.cpp`, `Odin\src\asm_tables_*.cpp`) and the coroutine context-switching implementation in `asm_amd64.odin`, `asm_arm64.odin`, and `asm_riscv64.odin`.

---

## 1. Compiler Fixes in `dev-2026-10:151d53f44` & `docs/ASM.md`

Five upstream compiler improvements in `dev-2026-10:151d53f44` resolved the historical blockers that previously forced raw `#byte` opcodes on AMD64 and `get_sp`:

1. **`#preserve %reg` Contract (`94aba2bd6`, `check_asm.cpp:3010`, `check_asm_cfg.cpp:439`)**:
   - Declaring `#preserve %rbp`, `#preserve %rbx`, `#preserve %rsi`, `#preserve %rdi`, `#preserve %rsp`, `#preserve %sp`, or `#preserve %ra` in the `[...]` bindings block seeds `seed_regs` and `entry_seed_w` at entry block `0` (permitting entry reads such as `push %rbp` or `mov sp, %rsp`) and adds them to `exit_live` (verifying restoration before exit) **without** emitting LLVM output register constraints (`={rbp}`), which previously triggered `LLVM Error: Interference usage of base pointer/frame pointer`.
2. **`#clobber %flags` Syntax (`45413b78a`, `docs/ASM.md:191`)**:
   - `#clobber flags` is deprecated and replaced by `#clobber %flags`.
3. **Label Definition Colon Fix (`bea8fc68a`, `llvm_backend_asm.cpp:90-93`)**:
   - `lbAsmGenerate::write_label_def` now appends the trailing colon `:` on AMD64 and RISC-V 64 (`.L_<tmpl>_<label>${:uid}:`), allowing internal labels like `.switch_done:` to assemble cleanly across all targets.
4. **RIP-Relative Label Memory Operands (`c7201725d`, `ab99241ce`, `check_asm.cpp:19-25`)**:
   - `[.label]` is supported on AMD64 (`lea %rax, [.switch_done]`), lowering to `.L_fiber_context_switch_switch_done0(%rip)` and eliminating the old `call .switch_body` / `jmp .switch_done` `#byte` trampoline.
5. **PC-Relative Symbolic Label Capture on ARM64 & RISC-V (`check_asm.cpp:1062`, `asm_tables_arm64.cpp`)**:
   - ARM64 supports `adr %x30, .switch_done` and RISC-V 64 supports `lla %ra, .switch_done`, replacing hardcoded PC-relative byte offsets with assembler-resolved local labels.

---

## 2. Per-Architecture Implementation Status

| Architecture | File | `get_rsp` / `get_sp` & Self-ID | `fiber_context_switch` Status | Remaining `#byte` Instructions |
| :--- | :--- | :--- | :--- | :--- |
| **AMD64** (`windows_amd64`, `linux_amd64`, `darwin_amd64`) | `asm_amd64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **100% High-Level `asm`** (`0` `#byte`) | **None (0 `#byte`)** |
| **ARM64** (`linux_arm64`, `darwin_arm64`) | `asm_arm64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (GPRs `x19..x30`, `adr`, `str`, `cbz`, `ret` in high-level `asm`) | 11 instructions (`stp`/`ldp d8..d15` + 3 `sp`-writing ops) |
| **RISC-V 64** (`linux_riscv64`) | `asm_riscv64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (`addi %sp`, `lla %ra`, `sd`/`ld ra, s0..s11`, `beq`, `jalr` in high-level `asm`) | 24 instructions (`fsd`/`fld fs0..fs11` only) |

### 2.1 AMD64 (`asm_amd64.odin`) — 100% High-Level `asm` (Zero `#byte`)
Both `fiber_context_switch` (Windows x64 & System V AMD64) and `get_rsp` / `get_r12_reg` are implemented using **100% high-level Odin `asm` mnemonics** with zero `#byte` directives:
- **Resume RIP Capture**: `lea %rax, [.switch_done]; push %rax`.
- **Callee-Saved GPRs & XMMs**: Direct `%rbp`, `%rbx`, `%rsi`, `%rdi`, `%r12`..`%r15` (`push`/`pop`) and `%xmm6`..`%xmm15` (`movdqu [%rsp + offset], %xmmN`). Because `clobber_bit_for_reg_name` returns `0` for `r12`..`r15` and `xmm6`..`xmm15`, they are accessed directly as hardware registers without scratch parameter early-clobber (`=&`) allocation traps.
- **Stack Pointer Swap & CFG Exit Liveness**:
  - `CLOBBER_REGS_NAMED` (`asm_tables_amd64.cpp:296`) omits `ClobberReg_RSP` from `exit_live`. Using `xchg %rsp, %rdx` (Windows) / `xchg %rsp, %rsi` (SysV) includes `ClobberReg_RSP` in `facts->read_regs`, preventing a dead-write warning on the stack swap.
  - Because `ret` is marked `is_terminal = true`, placing a never-taken `jz .switch_done` immediately before `ret` (`add %rsp, 160` on Windows or `test %rsp, %rsp` on SysV guarantees `ZF=0` at runtime since `%rsp != 0`) links the basic block to `.switch_done:` (`check_asm_cfg_block_leaves`), seeding `live_out` with `exit_live` and silencing dead-write warnings on `pop %rdi..%rbp`.

### 2.2 ARM64 (`asm_arm64.odin`) — High-Level `get_sp` & Hybrid `fiber_context_switch`
- **`get_sp` & `get_x19_reg`**: 100% high-level `asm` (`mov sp, %sp` with `#preserve %sp`; `mov res, %x19`).
- **`fiber_context_switch`**:
  - Uses high-level `adr %x30, .switch_done`, `stp`/`ldp` for all 12 callee-saved GPRs (`%x19`..`%x30`), `mov %x2, %sp`, `str %x2, [from_rsp]`, `cbz %x2, .switch_done`, `ret`, and `.switch_done:`.
  - Retains `#byte` for 2 specific compiler constraints (detailed in Section 3 below).

### 2.3 RISC-V 64 (`asm_riscv64.odin`) — High-Level `get_sp` & Hybrid `fiber_context_switch`
- **`get_sp` & `get_s2_reg`**: 100% high-level `asm` (`addi sp, %sp, 0` with `#preserve %sp`; `addi res, %s2, 0`).
- **`fiber_context_switch`**:
  - Uses high-level `addi %sp, %sp, -208`, `lla %ra, .switch_done`, `sd`/`ld` for `%ra` and `%s0`..`%s11`, `sd %sp, [from_rsp + 0]`, `addi %sp, to_rsp, 0`, `addi %sp, %sp, 208`, `beq %sp, %zero, .switch_done`, `jalr %zero, %ra, 0`, and `.switch_done:`.
  - Retains `#byte` only for `fsd`/`fld fs0..fs11` (detailed in Section 3 below).

---

## 3. What Remains Unfixed in Odin's Inline `asm` Compiler (`dev-2026-10:151d53f44`)

While AMD64 is now 100% `#byte`-free and ARM64/RISC-V 64 use high-level mnemonics for all GPRs, labels, and control flow, three upstream Odin compiler limitations remain in `dev-2026-10:151d53f44`:

### 3.1 ARM64: Missing 64-bit Scalar SIMD (`d0`–`d31`) Register Names & `vN` Formatting (`asm_tables_arm64.cpp` / `llvm_backend_asm.cpp`)
- **Compiler Location**: `Odin\src\asm_tables_arm64.cpp:1361` (`register_strings`) and `Odin\src\llvm_backend_asm.cpp:1490` (`lbAsmGenerate_arm64::write_operand`).
- **Issue**:
  1. `register_strings` on ARM64 only defines 128-bit vector names `v0`..`v31` (`REG_CLASS_V | REG_SIZE_128`); scalar 64-bit `d0`..`d31` (`REG_CLASS_F | REG_SIZE_64`) and 32-bit `s0`..`s31` names are not in the lookup table.
  2. When a physical register `%v8` (`Ast_AsmRegister`) is passed to `stp %v8, %v9, [%sp, 96]`, `lbAsmGenerate_arm64::write_operand` writes the bare string `v8, v9` into the LLVM inline assembly string (whereas parameter variables get `${N:d}` or `${N:q}` modifiers). The AArch64 LLVM assembler rejects `stp v8, v9, [sp, #96]` with `error: invalid operand for instruction` because AArch64 `stp`/`ldp` requires width-qualified register names (`d8`/`d9` for 64-bit or `q8`/`q9` for 128-bit).
- **Upstream Fix Needed**: Add `d0`..`d31` (64-bit) and `q0`..`q31` (128-bit) to `register_strings` in `asm_tables_arm64.cpp` (or format `Ast_AsmRegister` in `lbAsmGenerate_arm64::write_operand` as `qN`/`dN`).

### 3.2 ARM64: Writing to `%sp` Emits `~{sp}` in LLVM Clobber String (`check_asm.cpp`)
- **Compiler Location**: `Odin\src\check_asm.cpp:2042-2046`.
- **Issue**: Any instruction in an ARM64 `asm` block that writes to `%sp` (such as `sub %sp, %sp, 160` or `add %sp, %sp, 160`) sets `ClobberReg_SP` in `auto_clobber_regs`. Even when `#preserve %sp` is specified, `check_asm.cpp` appends `~{sp}` to the LLVM inline asm constraint string. Unlike x86_64 and RISC-V, LLVM's AArch64 backend emits `LLVM Warning: inline asm clobber list contains reserved registers: SP` whenever `~{sp}` is present.
- **Upstream Fix Needed**: Suppress emitting `~{sp}` (and `~{fp}`) into LLVM's clobber constraint string when the register is declared with `#preserve %sp` (since the template contractually restores it before exit).

### 3.3 RISC-V 64: 64-bit Float Registers `%fs0`–`%fs11` Typed as Integer `t_u64` (`check_asm.cpp`)
- **Compiler Location**: `Odin\src\check_asm.cpp:947-965` (`check_register`).
- **Issue**: Although `asm_tables_riscv64.cpp:587` correctly tags `fs0`..`fs11` with `REG_CLASS_F | REG_SIZE_64`, `check_register` in `check_asm.cpp` assigns the Odin AST type based solely on bit-width:
  ```cpp
  case 1: operand->type = t_u8;  break;
  case 2: operand->type = t_u16; break;
  case 4: operand->type = t_u32; break;
  case 8: operand->type = t_u64; break; // <-- Assigns integer t_u64 even for REG_CLASS_F!
  ```
  Subsequently, `operand_reg_class` checks `is_type_float(operand->type)` and classifies `%fs0`..`%fs11` as `AsmRegClass_Integer`, causing `fsd %fs0, [%sp + 104]` to fail with:
  `Error: 'fsd' operand-1 is in the wrong register class, expected 64-bit float register, got 64-bit integer register`.
- **Upstream Fix Needed**: In `check_register` (`check_asm.cpp:947`), assign `t_f32` / `t_f64` when `(reg_flags & REG_CLASS_F) != 0`.

---

## 4. Memory Lifecycle & Re-Initialization Safety Fixes

During verification of the interactive Raylib examples (`examples/game`, `examples/quest_ai`, `examples/showcase`) with Odin's `core:mem.Tracking_Allocator`, we also resolved a lifecycle leak triggered by in-place restarts (pressing `R` in `examples/game/main.odin`):
- **Root Cause**: Calling `game_init(g)` on an already-initialized `Game` struct invoked `scheduler_init(&g.sched)` without calling `game_destroy(g)` / `scheduler_destroy(&g.sched)` first, overwriting the existing dynamic queues (`ready_queue`, `timer_heap`, `frame_waiters`, `condition_waiters`) and `Fiber_Pool` arrays (`slabs`, `all_fibers`, `free_fibers`) and leaking the 2 prewarmed 1 MB stack slabs and 64 `Fiber` allocations.
- **Fixes Applied**:
  1. `fiber_pool_init` (`pool.odin`) and `scheduler_init` / `scheduler_init_config` (`scheduler.odin`) now check if the pool/scheduler is already initialized and automatically invoke `fiber_pool_destroy` / `scheduler_destroy` before re-allocating.
  2. `fiber_pool_destroy`, `scheduler_destroy`, and `chan_destroy` (`api.odin`) now nil out all freed slices/dynamic arrays so repeated `*_destroy` calls are safe no-ops.
  3. `game_init`, `world_init`, and `showcase_init` now call their corresponding `*_destroy` procedure if `sched` is already initialized.
  4. Covered by unit test `test_scheduler_reinit_no_memory_leak` in `coroutine_test.odin` (`190/190` tests passing with 0 leaks).
