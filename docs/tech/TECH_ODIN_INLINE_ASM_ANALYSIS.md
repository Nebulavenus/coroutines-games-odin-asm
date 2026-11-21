# Odin Inline Assembly: Technical Analysis, Compiler Internals & Remaining Constraints (`TECH_ODIN_INLINE_ASM_ANALYSIS.md`)

This technical document provides an exhaustive analysis of **Odin's Inline Assembly System (`asm`)** in `dev-2026-11:89246b0ad`, detailing compiler frontend mechanics, Static Single Assignment (SSA) liveness verification, Control Flow Graph (CFG) validation, how AMD64 context switching runs in **100% high-level `asm` (zero `#byte`)**, how ARM64 eliminated all `#byte` stack-pointer operations via `#pre`/`#post` writeback, and the two remaining upstream compiler constraints on ARM64 and RISC-V 64.

---

## 1. Executive Summary & Current Architecture Status

In the **Odin Stackful Coroutine Engine** (verified against Odin `dev-2026-11:89246b0ad`):

| Architecture | File | `get_rsp` / `get_sp` & Self-ID | `fiber_context_switch` Status | Remaining `#byte` Instructions |
| :--- | :--- | :--- | :--- | :--- |
| **AMD64** (`windows_amd64`, `linux_amd64`, `darwin_amd64`) | `asm_amd64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **100% High-Level `asm`** (`0` `#byte`) | **None (`0` `#byte`)** |
| **ARM64** (`linux_arm64`, `darwin_arm64`) | `asm_arm64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (GPRs `x19..x30`, `#pre`/`#post` SP frame, `mov %sp, to_rsp`, `adr`, `str`, `cbz`, `ret` in high-level `asm`) | 8 instructions (`stp`/`ldp d8..d15` only) |
| **RISC-V 64** (`linux_riscv64`) | `asm_riscv64.odin` | **100% High-Level `asm`** (`0` `#byte`) | **Hybrid High-Level `asm`** (`addi %sp`, `lla %ra`, `sd`/`ld ra, s0..s11`, `beq`, `jalr` in high-level `asm`) | 24 instructions (`fsd`/`fld fs0..fs11` only) |

1. **Self-Identity & Stack-Pointer Extractors (`100%` High-Level `asm` across all ISAs)**:
   ```odin
   // AMD64
   get_r12_reg :: asm() -> (res: rawptr)  [ res = %r12 ]             { mov res, %r12 }
   get_rsp     :: asm() -> (sp: rawptr)   [ sp = %rax, #volatile ]   { mov sp, %rsp }
   // ARM64
   get_x19_reg :: asm() -> (res: rawptr)  [ res = %x19 ]             { mov res, %x19 }
   get_sp      :: asm() -> (sp: rawptr)   [ sp = %x0, #volatile ]    { mov sp, %sp }
   // RISC-V 64
   get_s2_reg  :: asm() -> (res: rawptr)  [ res = %s2 ]              { addi res, %s2, 0 }
   get_sp      :: asm() -> (sp: rawptr)   [ sp = %a0, #volatile ]    { addi sp, %sp, 0 }
   ```
2. **AMD64 Hardware Context Switch (`100%` High-Level `asm`, Zero `#byte`)**:
   * Both Windows x64 (`240B` frame with `xmm6..xmm15`) and System V AMD64 (`64B` frame) use pure high-level `asm` mnemonics with `#align_stack` and `#volatile`.
   * System V uses direct `mov %rsp, to_rsp`; Windows x64 retains `xchg %rsp, to_rsp` due to `CLOBBER_REGS_NAMED` omitting `ClobberReg_RSP` during backward liveness past `add %rsp, 160` (see Section 3).
3. **ARM64 Hardware Context Switch (`8` `#byte` instructions — down from `11`)**:
   * All 3 `%sp`-modifying instructions are now high-level `asm`: `stp %x29, %x30, #pre [%sp - 160]`, `mov %sp, to_rsp`, and `ldp %x29, %x30, #post [%sp + 160]` (also saving 2 instructions per switch while preserving the exact 160-byte frame layout).
   * Only the 8 callee-saved float instructions (`stp`/`ldp d8..d15`) remain `#byte`.
4. **RISC-V 64 Hardware Context Switch (`24` `#byte` instructions)**:
   * All 33 GPR/stack/label/control-flow instructions use high-level `asm` with `#align_stack`.
   * Only the 24 callee-saved float instructions (`fsd`/`fld fs0..fs11`) remain `#byte`.

---

## 2. Upstream Compiler Progression (`dev-2026-10` → `dev-2026-11:89246b0ad`)

### 2.1 Foundation Fixes in `dev-2026-10:151d53f44`
1. **`#preserve %reg` Contract (`94aba2bd6`)**: Seeds entry liveness for preserved registers (`%rbp`, `%rbx`, `%rsi`, `%rdi`, `%ra`) without emitting LLVM output constraints (`={rbp}`).
2. **`#clobber %flags` Syntax (`45413b78a`)**: Replaces deprecated `#clobber flags`.
3. **Label Definition Colon Fix (`bea8fc68a`)**: Appends trailing `:` to `.L_<tmpl>_<label>${:uid}:` on AMD64 and RISC-V 64.
4. **RIP-Relative Label Memory Operands (`c7201725d`, `ab99241ce`)**: Supports `lea %rax, [.switch_done]` on AMD64.
5. **PC-Relative Symbolic Label Capture (`asm_tables_arm64.cpp`, `check_asm.cpp`)**: Supports `adr %x30, .switch_done` on ARM64 and `lla %ra, .switch_done` on RISC-V 64.

### 2.2 New Compiler Updates in `dev-2026-11:89246b0ad` (`151d53f44..89246b0ad`)
1. **Mandatory `#align_stack` Enforcement (`1590b7635`, `check_asm.cpp:2339, 3775`)**:
   * Any `asm` template that executes `push`, makes a `call`, or writes `%rsp`/`%sp` (including ARM64 `#pre`/`#post` writeback on `%sp`) must declare `#align_stack`.
   * Prevents LLVM from placing caller temporaries below `%rsp` (e.g. SysV AMD64 red zone) where a context switch's `push` instructions would overwrite them.
2. **Never Clobber Stack Pointer Implicitly (`f6c1e779f`, `check_asm.cpp:2360` & `88a10c973`, `check_asm.cpp:402-454`)**:
   * Masks `~asm_stack_pointer_bit(asm_ctx)` out of implicit clobbers and returns empty register family names for `%rsp`/`%sp`.
   * **Resolves former ARM64 Issue 4.2**: writing `%sp` on ARM64 no longer emits `~{sp}`, eliminating the LLVM `inline asm clobber list contains reserved registers: SP` warning completely.
3. **Stack Pointer Defined on Entry & Exit-Live (`b40bb67ea`, `check_asm_cfg.cpp:456, 731`)**:
   * Automatically seeds `asm_stack_pointer_bit(asm_ctx)` in entry `preserve_bits` and backward-liveness `exit_live`.
   * `#preserve %rsp` and `#preserve %sp` are no longer required in `get_rsp`, `get_sp`, or `fiber_context_switch`.
4. **ARM64 `#pre` / `#post` Writeback Lowering (`ea2a0509e`, `check_asm.cpp`, `llvm_backend_asm.cpp`)**:
   * Properly emits pre-indexed (`[sp, #-160]!`) and post-indexed (`[sp], #160`) writeback operands and tracks stack-pointer modification for `#align_stack`.
   * Allows fusing `sub sp, sp, #160` + `stp x29, x30, [sp]` into `stp %x29, %x30, #pre [%sp - 160]` and `ldp x29, x30, [sp]` + `add sp, sp, #160` into `ldp %x29, %x30, #post [%sp + 160]`.
5. **Automatic Clobbering of Written Named Registers & Input Auto-Tying (`88a10c973`, `0938fda9f`, `b3ea5193a`)**:
   * Every physical register written by name in a template body (`%r12..%r15`, `%xmm6..%xmm15`, etc.) is automatically added to `clobber_registers_set` by register family (`asm_clobber_written_register`), removing the need for manual `#clobber %r12..%r15` / `#clobber %xmm6..%xmm15` declarations on AMD64.
   * Overwritten inputs (such as `xchg %rsp, to_rsp`) are automatically lowered as tied to a discarded output rather than emitting conflicting LLVM clobbers.
6. **Checker Simplification & Terminal `reads_every_register` (`33482b517`, `check_asm.cpp:2325`)**:
   * Unconditional non-local transfers (`ret`, `jalr`) set `reads_every_register = true` so registers restored immediately before `ret`/`jalr` are treated as live.

---

## 3. Key Technical Details Across Architectures

### 3.1 AMD64 (`asm_amd64.odin`)
```odin
fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
    from_rsp = %rcx,
    to_rsp   = %rdx,
    #preserve %rbp,
    #preserve %rbx,
    #preserve %rsi,
    #preserve %rdi,
    #align_stack,
    #volatile,
    #clobber %rax,
    #clobber %r8,
    #clobber %r9,
    #clobber %r10,
    #clobber %r11,
    #clobber %xmm0,
    #clobber %xmm1,
    #clobber %xmm2,
    #clobber %xmm3,
    #clobber %xmm4,
    #clobber %xmm5,
    #clobber %flags,
    #clobber memory,
] {
    lea %rax, [.switch_done]
    push %rax
    // ... push GPRs, save XMM6..XMM15 ...
    mov [from_rsp], %rsp
    xchg %rsp, to_rsp
    // ... restore XMM6..XMM15, add %rsp, 160, pop GPRs ...
    jz .switch_done
    ret
.switch_done:
}
```
1. **Why Win64 uses `xchg %rsp, to_rsp` while SysV uses `mov %rsp, to_rsp`**:
   * In `asm_tables_amd64.cpp:296`, `CLOBBER_REGS_NAMED` omits `ClobberReg_RSP`. In `check_asm_cfg.cpp:712`, `asm_cfg_live_before` computes `(live_after & ~asm_full_kill_mask(f)) | (asm_cfg_read_regs(cfg, f) & REG_TOP)`.
   * On Windows x64, `add %rsp, 160` explicitly writes `ClobberReg_RSP` (clearing it from `live`), and `& REG_TOP` fails to re-add `ClobberReg_RSP` from `add`'s read set — causing a false-positive dead-write warning on a plain `mov %rsp, to_rsp`. Using `xchg %rsp, to_rsp` includes `ClobberReg_RSP` in `read_regs`, cleanly suppressing the false positive while `b3ea5193a` auto-ties `to_rsp`.
   * On System V AMD64, there is no `add %rsp, 160` between the swap and `pop`, so `mov %rsp, to_rsp` compiles with zero warnings.
2. **Why `jz .switch_done` / `cbz %x2, .switch_done` / `beq %sp, %zero, .switch_done` remain required**:
   * `check_asm_cfg.cpp:667` requires non-diverging templates to have a reachable path to the implicit end. Because `ret` / `jalr` is terminal (`is_terminal = true`), a never-taken conditional branch to the trailing `.switch_done:` label satisfies `check_asm_cfg_block_leaves`.

### 3.2 ARM64 (`asm_arm64.odin`)
* Uses `adr %x30, .switch_done` followed by `stp %x29, %x30, #pre [%sp - 160]` to allocate the 160-byte frame and store FP/LR in one instruction, `mov %sp, to_rsp` for the stack swap, and `ldp %x29, %x30, #post [%sp + 160]` to restore FP/LR and release the frame in one instruction.
* Verified with `odin build -build-mode:obj` on both `darwin_arm64` and `linux_arm64` at `-debug` and `-o:speed` with **0 warnings and 0 errors**.

---

## 4. Remaining Upstream Constraints in Odin `dev-2026-11:89246b0ad`

Two upstream compiler limitations remain and account for all remaining `#byte` instructions in the repository:

### 4.1 ARM64: Missing 64-bit Scalar SIMD (`d0`–`d31`) Register Names & `vN` Operand Formatting
- **Compiler Location**: `Odin\src\asm_tables_arm64.cpp:1361` (`register_strings`) and `Odin\src\llvm_backend_asm.cpp:1587` (`lbAsmGenerate_arm64::write_operand`).
- **Symptom**:
  1. Although `asm_tables_arm64.cpp:89` defines `REG_CLASS_D` and `check_asm.cpp:428` maps `REG_CLASS_D` in `asm_register_family_name`, `register_strings` still omits `d0`..`d31` and `q0`..`q31` (only `v0`..`v31` exist), rejecting `%d8` as an unknown register.
  2. `lbAsmGenerate_arm64::write_operand` emits literal `Ast_AsmRegister` names verbatim (`v8`), which AArch64 `stp`/`ldp` rejects (requiring `d8`/`q8`).
- **Current Workaround in `asm_arm64.odin`**: The 8 `stp`/`ldp d8..d15` instructions remain encoded via `#byte`.
- **Upstream Fix Needed**: Populate `d0`..`d31` (and `s0`..`s31`/`q0`..`q31`) in `asm_tables_arm64.cpp::register_strings` and `register_codes`, or apply `arm64_slot_reg_modifier` to literal `vN` registers in `lbAsmGenerate_arm64::write_operand`.

### 4.2 RISC-V 64: 64-bit Float Registers `%fs0`–`%fs11` Assigned Integer Type `t_u64`
- **Compiler Location**: `Odin\src\check_asm.cpp:1297-1315` (`check_register`).
- **Symptom**: `check_register` assigns `operand->type` solely by bit width (`case 64: operand->type = t_u64;`), ignoring `Asm_riscv::REG_CLASS_FPR`. Consequently, `%fs0`..`%fs11` are classified as `AsmRegClass_Integer`, causing `fsd %fs0, [%sp + 104]` and `fld %fs0, [%sp + 104]` to fail with a register-class mismatch error.
- **Current Workaround in `asm_riscv64.odin`**: The 24 `fsd`/`fld fs0..fs11` instructions remain encoded via `#byte`.
- **Upstream Fix Needed**: In `check_register` (`check_asm.cpp:1297`), inspect the register's class and assign `t_f32` / `t_f64` for floating-point registers.

### 4.3 Resolved: ARM64 `%sp`-Writing `~{sp}` Warning
- **Status**: **Fixed in Odin `dev-2026-11:89246b0ad`** via commits `f6c1e779f` and `88a10c973`. All 3 `#byte` `%sp` instructions in `asm_arm64.odin` have been migrated to high-level `asm`.

---

## 5. LLVM Register Allocation & Fiber Call-Boundary Invariant

Because `fiber_context_switch` preserves all **callee-saved** registers (`%xmm6`..`%xmm15` on Win64, `d8`..`d15` on ARM64, `fs0`..`fs11` on RISC-V 64, and non-volatile GPRs across all platforms), while **caller-saved** scratch registers remain volatile across procedure calls:
1. **Never `#force_inline` procedures that suspend a fiber**:
   Keeping `wait_steps`, `wait`, and `yield` as standard procedure calls ensures the platform ABI spills any live caller-saved registers before entering the yield function.
2. **Explicit `#align_stack`, `#volatile`, `#clobber memory`, and Full Caller-Saved Vector/FP Clobbers**:
   Every context switch template declares `#align_stack`, `#volatile`, `#clobber memory`, and all caller-saved volatile float/SIMD registers (`%xmm0..%xmm5` on Win64, `%xmm0..%xmm15` on SysV AMD64, `%v0..%v7` & `%v16..%v31` on ARM64, `%ft0..%ft11` & `%fa0..%fa7` on RISC-V 64). This protects live floating-point/SIMD locals even when LLVM aggressively inlines `yield` / `wait_steps` under `-o:speed -use-single-module` or `-o:aggressive`.
