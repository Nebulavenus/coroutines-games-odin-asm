# Odin Inline Assembly: Technical Analysis, Compiler Internals & Remaining Constraints (`TECH_ODIN_INLINE_ASM_ANALYSIS.md`)

This technical document provides an exhaustive analysis of **Odin's Inline Assembly System (`asm`)** in `dev-2026-10:151d53f44`, detailing compiler frontend mechanics, Static Single Assignment (SSA) liveness verification, Control Flow Graph (CFG) validation, how AMD64 context switching was migrated to **100% high-level `asm` (zero `#byte`)**, and the specific remaining compiler constraints on ARM64 and RISC-V 64.

---

## 1. Executive Summary & Current Architecture Status

In the **Odin Stackful Coroutine Engine** (verified against Odin `dev-2026-10:151d53f44`):

| Architecture | File | `get_rsp` / `get_sp` & Self-ID | `fiber_context_switch` Status | Remaining `#byte` Instructions |
| :--- | :--- | :--- | :--- | :--- |
| **AMD64** (`windows_amd64`, `linux_amd64`, `darwin_amd64`) | `asm_amd64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **100% High-Level `asm`** (`0` `#byte`) | **None (`0` `#byte`)** |
| **ARM64** (`linux_arm64`, `darwin_arm64`) | `asm_arm64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (GPRs `x19..x30`, `adr`, `str`, `cbz`, `ret` in high-level `asm`) | 11 instructions (`stp`/`ldp d8..d15` + 3 `sp`-writing ops) |
| **RISC-V 64** (`linux_riscv64`) | `asm_riscv64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (`addi %sp`, `lla %ra`, `sd`/`ld ra, s0..s11`, `beq`, `jalr` in high-level `asm`) | 24 instructions (`fsd`/`fld fs0..fs11` only) |

1. **Self-Identity & Stack-Pointer Extractors (`100%` High-Level `asm` across all ISAs)**:
   ```odin
   // AMD64
   get_r12_reg :: asm() -> (res: rawptr)  [ res = %r12 ]                    { mov res, %r12 }
   get_rsp     :: asm() -> (sp: uintptr)  [ #preserve %rsp, #volatile ]     { mov sp, %rsp }
   // ARM64
   get_x19_reg :: asm() -> (res: rawptr)  [ res = %x19 ]                    { mov res, %x19 }
   get_sp      :: asm() -> (sp: rawptr)   [ sp = %x0, #preserve %sp, #volatile ] { mov sp, %sp }
   // RISC-V 64
   get_s2_reg  :: asm() -> (res: rawptr)  [ res = %s2 ]                     { addi res, %s2, 0 }
   get_sp      :: asm() -> (sp: rawptr)   [ sp = %a0, #preserve %sp, #volatile ] { addi sp, %sp, 0 }
   ```
2. **AMD64 Hardware Context Switch (`100%` High-Level `asm`, Zero `#byte`)**:
   * Both Windows x64 (`240B` frame with `xmm6..xmm15`) and System V AMD64 (`64B` frame) use pure high-level `asm` mnemonics (`lea %rax, [.switch_done]`, `push`/`pop`, `movdqu`, `xchg %rsp, ...`, `jz .switch_done`, `ret`).
3. **ARM64 & RISC-V 64 Hardware Context Switch (Hybrid High-Level `asm`)**:
   * All callee-saved GPRs (`%x19`..`%x30` on ARM64, `%ra` and `%s0`..`%s11` on RISC-V 64), symbolic resume label capture (`adr %x30, .switch_done` and `lla %ra, .switch_done`), stack pointer stores, and return jumps are written in high-level `asm`.
   * Only the callee-saved float/SIMD instructions (`stp`/`ldp d8..d15` on ARM64, `fsd`/`fld fs0..fs11` on RISC-V 64) and 3 `sp`-modifying instructions on ARM64 retain `#byte` due to three upstream compiler constraints documented in Section 4.

---

## 2. Upstream Compiler Fixes in `dev-2026-10:151d53f44`

Five upstream compiler improvements in `dev-2026-10:151d53f44` (and `docs/ASM.md`) unlocked high-level inline assembly for context switching:

1. **`#preserve %reg` Contract (`94aba2bd6`, `check_asm.cpp:3010`, `check_asm_cfg.cpp:439`)**:
   * Declaring `#preserve %rbp`, `#preserve %rbx`, `#preserve %rsi`, `#preserve %rdi`, `#preserve %rsp`, `#preserve %sp`, or `#preserve %ra` seeds `seed_regs` and `entry_seed_w` at entry block `0` (permitting entry reads like `push %rbp` or `mov sp, %rsp`) and adds them to `exit_live` (verifying restoration before exit) **without** emitting LLVM output register constraints (`={rbp}`), which previously caused `LLVM Error: Interference usage of base pointer/frame pointer`.
2. **`#clobber %flags` Syntax (`45413b78a`, `docs/ASM.md:191`)**:
   * `#clobber flags` is replaced by `#clobber %flags`.
3. **Label Definition Colon Fix (`bea8fc68a`, `llvm_backend_asm.cpp:90-93`)**:
   * `lbAsmGenerate::write_label_def` now appends the trailing colon `:` on AMD64 and RISC-V 64 (`.L_<tmpl>_<label>${:uid}:`), allowing internal labels like `.switch_done:` to assemble cleanly across all targets.
4. **RIP-Relative Label Memory Operands (`c7201725d`, `ab99241ce`, `check_asm.cpp:19-25`)**:
   * `[.label]` is supported on AMD64 (`lea %rax, [.switch_done]`), lowering to `.L_fiber_context_switch_switch_done0(%rip)` and eliminating the old `call .switch_body` / `jmp .switch_done` `#byte` trampoline.
5. **PC-Relative Symbolic Label Capture on ARM64 & RISC-V (`check_asm.cpp:1062`, `asm_tables_arm64.cpp`)**:
   * ARM64 supports `adr %x30, .switch_done` and RISC-V 64 supports `lla %ra, .switch_done`, replacing hardcoded PC-relative byte offsets with assembler-resolved local labels.

---

## 3. How AMD64 Achieves 100% High-Level `asm` (`asm_amd64.odin`)

```odin
fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
    from_rsp = %rcx,
    to_rsp   = %rdx,
    #preserve %rbp,
    #preserve %rbx,
    #preserve %rsi,
    #preserve %rdi,
    #preserve %rsp,
    #volatile,
    #clobber %flags,
    #clobber memory,
    #clobber %rax, %rcx, %rdx, %r8, %r9, %r10, %r11, %xmm0,
] {
    // 1. Push resume RIP (.switch_done) onto current stack
    lea %rax, [.switch_done]
    push %rax

    // 2. Save Callee-Saved GPRs (64 bytes)
    push %rbp
    push %rbx
    push %rsi
    push %rdi
    push %r12
    push %r13
    push %r14
    push %r15

    // 3. Save Callee-Saved XMM6..XMM15 (160 bytes)
    sub %rsp, 160
    movdqu [%rsp + 0x00], %xmm15
    // ... %xmm14 .. %xmm6 ...

    // 4. Swap Stack Pointers
    mov [from_rsp], %rsp
    xchg %rsp, %rdx

    // 5. Restore Callee-Saved XMM6..XMM15 & GPRs
    // ... movdqu %xmm6 .. %xmm15 ...
    add %rsp, 160
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rdi
    pop %rsi
    pop %rbx
    pop %rbp

    // 6. Link CFG to .switch_done (never taken at runtime since %rsp != 0) & return
    jz .switch_done
    ret

.switch_done:
}
```

### Key Technical Details on AMD64:
1. **Why `%r12`..`%r15` and `%xmm6`..`%xmm15` are accessed directly**:
   In `asm_tables_amd64.cpp`, `clobber_bit_for_reg_name` returns `0` for `r12`..`r15` and `xmm6`..`xmm15`. Because they have no clobber bit in `universe_regs`, `check_asm_cfg.cpp` neither rejects entry reads nor warns on exit writes when they are referenced directly as `%r12`..`%r15` and `%xmm6`..`%xmm15` (whereas declaring them as unpinned scratch variables would emit `=&r` / `=&x` early-clobber constraints that exhaust LLVM's register allocator).
2. **Why `xchg %rsp, %rdx` (Win64) / `xchg %rsp, %rsi` (SysV) is used for the stack swap**:
   `CLOBBER_REGS_NAMED` (`asm_tables_amd64.cpp:296`) omits `ClobberReg_RSP` from `exit_live`. A plain `mov %rsp, %rdx` writes `ClobberReg_RSP` without reading it, triggering a dead-write warning on the subsequent `pop`. `xchg %rsp, %rdx` sets `ClobberReg_RSP` in both `read_regs` and `write_regs`, satisfying the backward liveness pass.
3. **Why `jz .switch_done` precedes `ret`**:
   `ret` is marked `is_terminal = true` with `fallthrough = false`. Placing a conditional jump `jz .switch_done` before `ret` (after `add %rsp, 160` on Win64 or `test %rsp, %rsp` on SysV, where `%rsp != 0` guarantees `ZF = 0`) adds an edge from the basic block to `.switch_done:`. This satisfies `check_asm_cfg_block_leaves` and seeds `live_out` with `exit_live` so `pop %rdi..%rbp` are recognized as live restores.

---

## 4. What Remains Unfixed in Odin's Inline `asm` Compiler (`dev-2026-10:151d53f44`)

Three upstream compiler limitations explain the remaining `#byte` instructions in `asm_arm64.odin` and `asm_riscv64.odin`:

### 4.1 ARM64: Missing 64-bit Scalar SIMD (`d0`–`d31`) Register Names & `vN` Operand Formatting
- **Compiler Location**: `Odin\src\asm_tables_arm64.cpp:1361` (`register_strings`) and `Odin\src\llvm_backend_asm.cpp:1490` (`lbAsmGenerate_arm64::write_operand`).
- **Symptom**:
  1. `register_strings` on ARM64 only defines 128-bit vector names `v0`..`v31` (`REG_CLASS_V | REG_SIZE_128`). Scalar 64-bit `d0`..`d31` (`REG_CLASS_F | REG_SIZE_64`) and 32-bit `s0`..`s31` names are not in the register table (`Error: Unknown register '%d8'`).
  2. If `%v8, %v9` (`Ast_AsmRegister`) are used directly in `stp %v8, %v9, [%sp, 96]`, `lbAsmGenerate_arm64::write_operand` emits bare `v8, v9` into the LLVM inline assembly string (whereas bound parameter variables receive `${N:d}` or `${N:q}` modifiers). The AArch64 LLVM assembler rejects `stp v8, v9, [sp, #96]` with `error: invalid operand for instruction` because AArch64 `stp`/`ldp` requires `d8`/`d9` (64-bit) or `q8`/`q9` (128-bit).
- **Current Workaround in `asm_arm64.odin`**: The 8 `stp`/`ldp d8..d15` instructions remain encoded via `#byte`.
- **Upstream Compiler Fix Needed**: Add `d0`..`d31` (64-bit) and `q0`..`q31` (128-bit) to `register_strings` in `asm_tables_arm64.cpp` (or format `Ast_AsmRegister` in `lbAsmGenerate_arm64::write_operand` as `dN`/`qN`).

### 4.2 ARM64: Writing to `%sp` Emits `~{sp}` in LLVM Clobber Constraints
- **Compiler Location**: `Odin\src\check_asm.cpp:2042-2046`.
- **Symptom**: Any instruction in an ARM64 `asm` block that writes to `%sp` (such as `sub %sp, %sp, 160` or `add %sp, %sp, 160`) sets `ClobberReg_SP` in `auto_clobber_regs`. Even when `#preserve %sp` is specified, `check_asm.cpp` appends `~{sp}` to the LLVM inline asm constraint string, which causes LLVM's AArch64 backend to emit:
  `LLVM Warning: inline asm clobber list contains reserved registers: SP`.
- **Current Workaround in `asm_arm64.odin`**: Read-only `%sp` operations (`mov sp, %sp` in `get_sp` and `mov %x2, %sp` in `fiber_context_switch`) use high-level `asm` with `#preserve %sp`, while the 3 `%sp`-writing instructions (`sub sp, sp, #160`, `mov sp, x1`, `add sp, sp, #160`) remain `#byte` to keep builds 100% warning-free.
- **Upstream Compiler Fix Needed**: In `check_asm.cpp`, omit registers declared in `preserve_regs` (such as `#preserve %sp`) from the emitted LLVM `~{...}` clobber constraint list.

### 4.3 RISC-V 64: 64-bit Float Registers `%fs0`–`%fs11` Assigned Integer Type `t_u64`
- **Compiler Location**: `Odin\src\check_asm.cpp:947-965` (`check_register`).
- **Symptom**: Although `asm_tables_riscv64.cpp:587` tags `fs0`..`fs11` with `REG_CLASS_F | REG_SIZE_64`, `check_register` in `check_asm.cpp` assigns `operand->type` solely by byte size:
  ```cpp
  case 1: operand->type = t_u8;  break;
  case 2: operand->type = t_u16; break;
  case 4: operand->type = t_u32; break;
  case 8: operand->type = t_u64; break; // <-- Assigns integer t_u64 even when REG_CLASS_F is set!
  ```
  Because `operand_reg_class` checks `is_type_float(operand->type)`, `%fs0`..`%fs11` are classified as `AsmRegClass_Integer`, causing `fsd %fs0, [%sp + 104]` to fail with:
  `Error: 'fsd' operand-1 is in the wrong register class, expected 64-bit float register, got 64-bit integer register`.
- **Current Workaround in `asm_riscv64.odin`**: The 24 `fsd`/`fld fs0..fs11` instructions remain encoded via `#byte`, while all 33 GPR/stack/label/control-flow instructions use high-level `asm`.
- **Upstream Compiler Fix Needed**: In `check_register` (`check_asm.cpp:947`), assign `t_f32` / `t_f64` when `(reg_flags & REG_CLASS_F) != 0`.

---

## 5. LLVM Register Allocation & Fiber Call-Boundary Invariant

Because `fiber_context_switch` preserves all **callee-saved** registers (`%xmm6`..`%xmm15` on Win64, `d8`..`d15` on ARM64, `fs0`..`fs11` on RISC-V 64, and non-volatile GPRs across all platforms), while **caller-saved** scratch registers remain volatile across procedure calls:
1. **Never `#force_inline` procedures that suspend a fiber**:
   Keeping `wait_steps`, `wait`, and `yield` as standard procedure calls ensures the platform ABI spills any live caller-saved registers before entering the yield function.
2. **Explicit `#volatile` and `#clobber memory`**:
   Every context switch template is marked `#volatile` and `#clobber memory`, preventing LLVM from caching memory loads across a fiber suspension point.
