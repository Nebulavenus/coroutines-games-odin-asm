---
title: Odin Inline Assembly Templates Specification (Complete Reference)
summary: Authoritative and comprehensive specification of Odin inline assembly (`asm`), including AST bindings, undocumented compiler directives (#no_init, #skip), SSA dataflow rules, CFG verification, and LLVM backend mechanics.
weight: 10
---

# Odin Inline Assembly (`asm`) Templates: Complete Reference Manual (`ASM_2.md`)

> **Supported Targets**: `amd64`, `arm64`, and `riscv64`.

## 1. Overview & Execution Model

An `asm` template in Odin is a callable, forced-inlined intrinsic entity. It is not a raw statement block spliced into a surrounding procedure; rather, it behaves like an intrinsic procedure whose body lowers to a single GCC/LLVM inline assembly expression:

```odin
name :: asm(params) -> (results) [bindings] {
    body
}
```

### Component Breakdown
- `params`: Input operands with explicit Odin types (`name: type`).
- `-> (results)`: Optional output operands with explicit Odin types. Diverging templates are declared with `-> !`.
- `[bindings]`: Register pins, tied operands, scratch registers, clobbers, and template-level directives.
- `body`: The instruction stream using universal Intel operand order (`instruction dst, src`).

Both `-> (results)` and `[bindings]` are optional. Results may be left unhandled at the call site if they represent discarded ABI artifacts.

---

## 2. Parameter Types & Register Classes

Odin enforces strict type classification on all `asm` parameters:

| Category | Permitted Odin Types | Register Class | Maximum Bit Width |
| :--- | :--- | :--- | :--- |
| **Integer** | `i8`, `u8`, `i16`, `u16`, `i32`, `u32`, `i64`, `u64`, `int`, `uint`, `uintptr` | `AsmRegClass_Integer` | 64 bits (128-bit integers forbidden) |
| **Pointer-Like** | `rawptr`, `^T`, `[^]T` | `AsmRegClass_Integer` | 64 bits |
| **Boolean** | `bool`, `b8`, `b16`, `b32`, `b64` | `AsmRegClass_Integer` | Width of underlying type |
| **Floating Point** | `f16`, `f32`, `f64` | `AsmRegClass_Float` | 16, 32, or 64 bits |
| **SIMD Vectors** | `#simd[N]T` (e.g. `#simd[2]u64`, `#simd[4]f32`) | `AsmRegClass_Vector` | 128 bits (`xmm`), 256 bits (`ymm`), 512 bits (`zmm`) |

---

## 3. Bindings Specification (`[ ... ]`)

The bindings block configures parameter allocation, physical register pinning, tied dataflows, scratch allocations, and clobber constraints.

### 3.1 Physical Register Pinning (`= %reg`)
Pins a named parameter to a specific architectural register:
```odin
foo :: asm(val: u64) -> (res: u64) [ val = %rcx, res = %rax ] {
    mov res, val
}
```

### 3.2 Tied Input-to-Output Parameters (`in -> out = %reg`)
Specifies a two-address operand where an input and an output share the same physical register (common for x86 RMW instructions):
```odin
add_in_place :: asm(a: u64, b: u64) -> (res: u64) [ a -> res = %rax ] {
    add res, b
}
```

### 3.3 Scratch Register Declarations
Scratch registers are temporary registers allocated within the template that are not exposed to the caller:
```odin
temp_calc :: asm(x: u64) -> (res: u64) [ res = %rax, tmp: u64 = %rdx ] {
    mov tmp, x
    shl tmp, 2
    mov res, tmp
}
```

### 3.4 The `#no_init` Directive (Hidden / Undocumented Compiler Feature)
By default, the Odin SSA verifier (`check_asm_cfg.cpp`) requires that every register read inside the template is either passed as an initialized input parameter or written earlier in the block. Furthermore, all output parameters must be definitely assigned on every returning path.

The `#no_init` directive bypasses both constraints:
1. **Entry Seeding**: Pinned registers marked `#no_init` are automatically injected into `seed_regs` and `seed_pm` at block 0, allowing immediate reading without prior definition.
2. **Exit Exemption**: Output parameters marked `#no_init` are exempt from the definite-assignment check at template exit.

#### Applying `#no_init` to Output Parameters
```odin
// Reads %rax without caller input, leaves it unwritten without error
read_rax :: asm() -> (val: u64) [ val = %rax #no_init ] {
    // %rax is valid to read immediately
}
```

#### The Two-Step Scratch Register `#no_init` Pattern
In `check_asm.cpp`, single-step scratch declarations `[ tmp: u64 = %rbp #no_init ]` fail to apply `#no_init` because the parameter is inserted into scope after initial lookup. The **Two-Step Pattern** resolves this:
```odin
// Step 1: Declare scratch variable in scope
// Step 2: Pin to register and apply #no_init
fiber_switch :: asm() [
    rbp_reg: u64, rbp_reg = %rbp #no_init,
    rbx_reg: u64, rbx_reg = %rbx #no_init,
] {
    push rbp_reg // Valid! Does not trigger undefined register error
    pop  rbp_reg
}
```

### 3.5 Sub-Register Width-Views
Allows referencing a narrower sub-slice of a wider register parameter:
```odin
read_byte :: asm(in_val: u64) -> (res: u8) [
    in_val = %rax,
    in_byte: u8 = in_val, // Width-view of low 8 bits (%al)
    res = %cl,
] {
    mov res, in_byte
}
```

### 3.6 Template-Level Directives
- `#volatile`: Prevents the compiler from optimizing out or reordering the inline assembly block. Required for any template performing memory writes, stack operations, or hardware I/O.
- `#align_stack`: Directs the backend to enforce ABI stack alignment (16-byte alignment on x86_64/AAPCS64) before the assembly block.
- `#pure`: Asserts that the template has no observable side effects and depends strictly on its inputs (enables constant folding and CSE).

### 3.7 Clobber Directives
Informs LLVM of registers, flags, or memory mutated by the template:
```odin
[
    #clobber %rax,
    #clobber %rcx,
    #clobber flags,
    #clobber memory,
]
```
> [!TIP]
> **Silencing Dead-Write Diagnostics**: Adding `#clobber %reg` marks that register as live at template exit (`exit_live`), which eliminates compiler warnings on instructions like `pop rbp_reg` near the end of a template.

---

## 4. Body Directives & Instruction Syntax

### 4.1 Native Directives Inside `{ ... }`
- `#byte <imm8, ...>`: Emits raw machine code bytes directly into the instruction stream.
  ```odin
  #byte 0x0F, 0x05 // syscall
  ```
  *Note: Directives are treated as straight-line filler by Odin's CFG builder and do not create basic block boundaries.*
- `#align <pow2>`: Aligns the subsequent instruction to a power-of-two byte boundary (e.g. `#align 16`).
- `#skip <n>`: Emits $n$ zero-bytes into the stream (lowers to `.skip n`).

### 4.2 Universal Operand Ordering
All instructions across all ISAs follow Intel order: `instruction destination, source`:
```odin
// AMD64
mov res, val       // mov %rax, %rcx

// ARM64
add res, a, b      // add x0, x1, x2

// RISC-V 64
addi res, a, 10    // addi a0, a1, 10
```

### 4.3 Memory Operands
- Direct displacement: `[disp]` or `[0x1000]`
- Base + Displacement: `[base + disp]` (e.g. `[rsp_reg + 16]`)
- Base + Index * Scale + Displacement: `[base + index * 4 + 8]` (Scale must be 1, 2, 4, or 8)
- Segment overrides: `fs:[disp]`, `gs:[disp]`
- Label reference (AMD64 only): `[.label]` or `lea reg, [.label]`

---

## 5. SSA Verification & CFG Dataflow Engine (`check_asm_cfg.cpp`)

The Odin compiler runs rigorous dataflow analyses on assembly templates before codegen:

### 5.1 The Dual Liveness Systems: Parameter Masks vs Physical Width Lattice
1. **Parameter Mask (`pm`)**:
   Tracks logical Odin entities (`Ast_Ident`). Seeded by input parameters and `#no_init` declarations (`seed_pm`). An instruction reading a parameter identifier checks `run_pm & (1 << id)`.
2. **Sub-Register Width Lattice (`in_w`)**:
   Tracks raw physical registers (`Ast_AsmRegister`). Initialized to `{}` (0 bits defined) at entry block 0.
   > [!IMPORTANT]
   > Writing `mov res, %rcx` fails with `'mov' reads rcx at 64-bit width but only its low 0 bits are defined` because `%rcx` was checked against `in_w[0]`.
   > Writing `mov res, val` (where `val = %rcx`) succeeds because `val` is tracked through `seed_pm`! Always use parameter names rather than `%reg` in instruction operands.

### 5.2 CFG Block Construction & Terminal Instructions
- A new basic block leader is created at:
  1. The template entry.
  2. Any instruction preceded by a label (`.label:`).
  3. Any instruction following a control transfer.
- **Terminal Instructions**: `jmp`, `ret`, `hlt`, and **`call`** are marked `is_terminal = true`.
  - In Odin's CFG model, terminal instructions do **not** fall through (`fallthrough = false`).
  - Because `call` does not fall through, instructions following `call` without an explicit branch target are flagged as unreachable.

### 5.3 Template Return Verification (`check_asm_cfg_block_leaves`)
A non-diverging template (`asm()`) must prove that at least one reachable block exits the template:
1. **Straight-Line Exit**: The last block in the template is reachable and its final instruction is not terminal.
2. **Trailing Label Jump**: An instruction executes `jmp .end`, where `.end:` is a label declared at the very end of the template body (`target_index >= blocks.count`).

---

## 6. Multi-ISA Architecture Matrix

| Feature | AMD64 (`amd64`) | ARM64 (`arm64`) | RISC-V 64 (`riscv64`) |
| :--- | :--- | :--- | :--- |
| **Calling Convention** | Windows x64 / System V | AAPCS64 | LP64D |
| **Stack Pointer Reg** | `%rsp` | `%sp` | `%sp` |
| **Frame Pointer Reg** | `%rbp` | `%x29` (`%fp`) | `%s0` (`%fp`) |
| **Return Address Reg** | Stored on stack | `%x30` (`%lr`) | `%ra` (`%x1`) |
| **Callee-Saved GPRs** | `rbx, rbp, rdi, rsi, r12-r15` | `x19`–`x28` | `s0`–`s11` |
| **Callee-Saved SIMD** | `xmm6`–`xmm15` (Win) | `d8`–`d15` (`v8`–`v15`) | `fs0`–`fs11` |
| **Label Addressing** | `lea reg, [.label]` | `adrp` / `adr` | `la rd, .label`, `lla rd, .label` |

---

## 7. Compiler Codegen Issues & LLVM Low-Level Constraints

### 7.1 LLVM Backend Missing Label Colon (`llvm_backend_asm.cpp:390`)

In `E:\OdinLang\Odin\src\llvm_backend_asm.cpp`:
```cpp
// llvm_backend_asm.cpp line 388
virtual void write_label_def(AstIdent *label_ident) {
    String name = label_ident->token.string;
    write_cstr(".L_");
    write_string(tmpl_entity->token.string);
    write_cstr("_");
    write_string(name);
    write_cstr("${:uid}"); // BUG: Missing trailing colon ':'
}
```
- **ARM64**: Overrides `write_label_def` with `gb_string_append_fmt(asm_string, "%d:", ...)`, successfully emitting the colon.
- **AMD64 & RISC-V 64**: Use the default `write_label_def`, which omits the colon. When LLVM assembles the inline block, it encounters `.L_<tmpl>_<label>0` without a colon, rejecting it with:
  `LLVM Error: <inline asm>: unknown directive .L_...`
- **Workaround on Stock Odin**: Use `#byte` machine code for jump trampolines or avoid internal label definitions on AMD64/RISC-V until patched.

### 7.2 Vector Scratch Registers & Early-Clobber (`=&`) Output Semantic Trap

In `E:\OdinLang\Odin\src\llvm_backend_asm.cpp` (lines 208–233):
- Scratch parameter bindings (`reg: type, reg = %pin #no_init`) are lowered in Pass 1 as uninitialized output parameters with the **early-clobber modifier**: `=&{pin}`.
- When an instruction writes an XMM scratch parameter to memory (e.g. `movdqu [%rsp + off], xmm_reg`), Odin lowers it into AT&T syntax: `movdqu $N, off(%rsp)`.
- Because LLVM considers `$N` an early-clobber output register rather than an input, LLVM's register allocator treats the source register as undefined at the entry point of the inline assembly call.
- This results in live vector/SIMD state being overwritten with uninitialized data, causing hardware runtime traps (`Illegal_Instruction` / `0xC000001D`) when returning to calling scopes that execute floating-point/vector operations.
- **Rule for System Runtimes**: Callee-saved SIMD register arrays across context switches must use deterministic `#byte` opcodes to preserve exact hardware register bit patterns without compiler register-allocator interference.
