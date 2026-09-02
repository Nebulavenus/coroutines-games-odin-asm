# Odin Inline Assembly: Technical Analysis, Compiler Internals & Future Roadmap (`TECH_ODIN_INLINE_ASM_ANALYSIS.md`)

This technical document provides an exhaustive analysis of **Odin's Inline Assembly System (`asm`)**, detailing compiler frontend mechanics, Static Single Assignment (SSA) liveness verification, Control Flow Graph (CFG) validation, why non-local stack swapping currently uses the `#byte` directive, and a concrete language proposal / roadmap for supporting pure high-level inline assembly context switching in future Odin versions.

---

## 1. Executive Summary

In the **Odin Stackful Coroutine Engine**, assembly operations fall into two distinct categories:

1. **Self-Identity Register Extractors & Intrinsics**:
   * Operations such as reading the current fiber pointer from `%r12` (AMD64), `%x19` (ARM64), or `%s2` (RISC-V 64) are implemented in **100% pure high-level Odin inline assembly mnemonics**:
     ```odin
     // AMD64
     get_r12_reg :: asm() -> (res: rawptr) [ res = %r12 ] { mov res, %r12 }
     // ARM64
     get_x19_reg :: asm() -> (res: rawptr) [ res = %x19 ] { mov res, %x19 }
     // RISC-V 64
     get_s2_reg  :: asm() -> (res: rawptr) [ res = %s2 ]  { addi res, %s2, 0 }
     ```
   * These compile cleanly through Odin's semantic analyzer because inputs, outputs, and register bindings are explicitly declared.

2. **Low-Level Hardware Context Switches (`fiber_context_switch`)**:
   * Operations that swap the CPU stack pointer (`%rsp` / `%sp`) and save/restore non-volatile register sets across foreign memory spaces currently utilize the native **`#byte` directive** inside Odin `asm` templates:
     ```odin
     fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [ ... ] {
         #byte 0xE8, 0x05, 0x00, 0x00, 0x00 // call .switch_body
         ...
     }
     ```
   * As detailed below, this is because Odin's compiler frontend enforces rigorous SSA dataflow rules and local CFG checks designed for *intra-procedure macro inlining*, which intentionally reject unproduced physical register reads and foreign stack returns when written as high-level mnemonics.

---

## 2. Historical Git Evidence: When High-Level Inline ASM Worked & What Changed

In earlier commits of this engine (e.g. commit `5e87a71` / `186f2d7`), `fiber_context_switch` was written entirely in **high-level Odin inline assembly mnemonics without a single `#byte` directive**:

```odin
// Original high-level AMD64 context switch (commit 5e87a71):
fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
    from_rsp = %rcx,
    to_rsp   = %rdx,
    #volatile,
    #clobber flags,
    #clobber memory,
    #clobber %rax, %rcx, %rdx, %r8, %r9, %r10, %r11,
] {
    call .switch_body
    jmp .switch_done

.switch_body:
    // 1. Save Callee-Saved GPRs
    push %rbp
    push %rbx
    push %rsi
    push %rdi
    push %r12
    push %r13
    push %r14
    push %r15

    // 2. Save Callee-Saved XMM Registers (160 bytes)
    sub %rsp, 160
    movdqu [%rsp + 0x00], %xmm15
    movdqu [%rsp + 0x10], %xmm14
    ...
    // 3. Swap Stack Pointers
    mov [%rcx], %rsp
    mov %rsp, %rdx

    // 4. Restore Callee-Saved XMM Registers
    movdqu %xmm6,  [%rsp + 0x90]
    ...
    add %rsp, 160

    // 5. Restore Callee-Saved GPRs
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rdi
    pop %rsi
    pop %rbx
    pop %rbp

    // 6. Return to target fiber's saved RIP
    ret

.switch_done:
}
```

### Why It Previously Compiled:
* In earlier versions of Odin's inline assembler, the frontend parsed the high-level mnemonics (`push`, `pop`, `movdqu`, `call`, `ret`) and passed them directly to `llvm_backend_asm.cpp` as string templates with minimal dataflow constraints.
* The LLVM backend (`LLVMInlineAsm`) happily accepted and lowered this assembly to byte-exact machine code, producing a fully working fiber context switch with **100% functional correctness**.

### Why Newer Compiler Revisions Added Stricter Checks:
* To prevent accidental bugs in user arithmetic and vector code (such as reading uninitialized variables or forgetting to assign outputs), Odin introduced a full static dataflow and CFG verification pass (`check_asm_cfg.cpp`).
* While this SSA verifier is excellent for catching bugs in normal procedural inline assembly, it treats all `asm` templates as *intra-procedure inlined macros*.
* Because a low-level context switch reads the caller's live hardware registers (`push %rbp`) without having defined them inside the template first, the new CFG pass flags them with `check_asm_cfg_report_undef_reg`.
* **Key Takeaway**: The LLVM backend code generator *already* supports high-level inline assembly context switching completely; the only adjustment needed is a frontend diagnostic waiver (`#untracked_registers`) in `check_asm_cfg.cpp`.

---

## 3. Odin Compiler Inline ASM Pipeline Architecture

When the Odin compiler processes an `asm(...)` declaration, it passes through four discrete compilation phases within `E:\OdinLang\Odin\src\`:

```
               [ Odin Source Code: asm(...) ]
                              │
                              ▼
    [ check_asm.cpp ] ────────────────► [ asm_tables_<arch>.cpp ]
    • Lexical parsing                   • ISA instruction dictionaries
    • Parameter/result type checking    • Physical register class maps
    • Directive validation              • Operand constraint verification
                              │
                              ▼
    [ check_asm_cfg.cpp ] ────────────► [ SSA / Liveness Engine ]
    • Basic Block & Leader detection    • Universe bitset tracking per decl
    • Reachability & Fallthrough checks • `check_asm_cfg_report_undef_reg`
    • Diverging contract enforcement    • Dead-code & unread write warnings
                              │
                              ▼
    [ llvm_backend_asm.cpp ]
    • Lowers AST nodes to LLVM inline asm strings
    • Generates `LLVMInlineAsmDialectATT` nodes
    • Emits `call asm sideeffect` IR calls
```

---

## 4. Deep Dive: The 3 Core Compiler Barriers

### Barrier 1: Static SSA Register Liveness Enforcement (`check_asm_cfg.cpp`)

#### The Mechanism:
In `check_asm_cfg.cpp`, the compiler maintains a 64-bit universe bitmask (`universe_pm`) tracking which variables and physical registers are "defined" (produced) at every point in the basic block graph:
* **Parameters (`params`)**: Automatically marked as defined upon entry.
* **Pinned Parameters (`name = %reg`)**: Marks the physical register `%reg` as defined upon entry.
* **Scratch Registers (`name: T = %reg`)**: Marked as **undefined (0 bits)** until an instruction explicitly writes to them.

#### The Error when using High-Level Mnemonics:
When writing a high-level context switch sequence:
```odin
// High-level attempt on AMD64:
push %rbp
push %rbx
push %rsi
push %rdi
push %r12
...
```
The compiler's CFG analysis produces:
```
Error: 'push' implicitly reads %rbp, but nothing in this template produces a value for it on all paths reaching here; pin an input to %rbp, or write %rbp first
```

#### Why standard workarounds fail:
1. **Writing to `%rbp` first (e.g. `mov %rbp, 0`)**: Destroys the live CPU register value of the calling procedure that we are trying to save!
2. **Declaring all registers as parameters (`asm(from, to, rbp, rbx, ...: rawptr)`)**:
   * Odin **forbids default values** on `asm` template parameters:
     ```
     Syntax Error: Default parameters are only allowed for procedures
     ```
   * This would force every `yield()`, `wait()`, and channel operation in the entire codebase to pass 10+ dummy register arguments manually.

---

### Barrier 2: Non-Local Control Flow & CFG Divergence (`check_asm_cfg.cpp`)

#### The Mechanism:
In `check_asm_cfg_analyse`:
* If an `asm` template is **not diverging**: Control *must* fall through the end of the template block. If the template contains a `ret` instruction without a branch falling through, Odin reports:
  ```
  Error: This 'asm' template has no reachable path that returns or falls through the end; if this is intended, declare it diverging (-> !)
  ```
* If the template is declared **diverging (`-> !`)**: No path may ever return to the caller. But in a coroutine, the context switch *does* return—just on a different fiber's stack at a later point in time!
* A context switch is fundamentally a **non-local jump**: it enters with Stack Frame $A$ and returns with Stack Frame $B$. An SSA macro inliner expects single-frame structured flow.

---

### Barrier 3: Frontend Register Table Mismatch on RISC-V (`asm_tables_riscv.cpp`)

#### The Mechanism:
In `asm_tables_riscv.cpp`, the callee-saved floating-point registers `fs0` through `fs11` (`f8`–`f9`, `f18`–`f27`) are currently categorized in the integer register class rather than the floating-point register class.

#### The Error:
```odin
fsd %fs0, [%sp + 104]
```
Produces:
```
Error: 'fsd' operand-0 is in the wrong register class, expected 64-bit float register, got 64-bit integer register
```
This causes high-level floating-point store/load mnemonics on RISC-V to be rejected during semantic checking.

---

## 5. Exhaustive Analysis of Attempted In-Language Workarounds

We systematically tested every potential language-level workaround within Odin's current syntax to determine if high-level mnemonics could be salvaged without compiler source modifications. Below is the complete matrix of findings:

| Workaround Strategy | Attempted Implementation | Compiler Diagnostic / Outcome | Fundamental Architectural Reason |
| :--- | :--- | :--- | :--- |
| **Strategy A: Write to register before reading** | `mov %rbp, 0; push %rbp` | Passes SSA check, but **corrupts runtime data**. | Overwriting the register destroys the caller's live state that we are trying to save into the fiber context frame. |
| **Strategy B: Declare callee-saved registers as template parameters** | `asm(from, to, rbp, rbx: rawptr = nil)` | `Syntax Error: Default parameters are only allowed for procedures` | Odin forbids default parameters on `asm` templates. Every single `yield()`, `wait()`, and channel operation would be forced to pass 10+ dummy arguments manually. |
| **Strategy C: Wrap in a procedure (`proc "c"` / `proc "naked"`)** | `proc "c" (...) { asm { ... } }` | `Error: 'push' implicitly reads %rbp...` | In `proc "c"`, the procedure prologue already modified the stack pointer (`RSP`), and inside the body, reading `%rbp` is still flagged by the nested `asm` template's SSA verifier. |
| **Strategy D: Output Pinning (`res = %reg`)** | `asm() -> (res: rawptr) [ res = %rbp ] { mov res, %rbp }` | `Error: 'mov' implicitly reads %rbp, which is bound to the output parameter 'res'` | Output parameters are defined as *uninitialized upon entry*. Reading an output before writing to it is flagged as reading an undefined register. |
| **Strategy E: Pass-Through Ties (`in -> out = %reg`)** | `asm(in_rbp: rawptr) -> (out_rbp: rawptr) [ in_rbp -> out_rbp = %rbp ]` | Compiles for 1 register, but cannot be defaulted. | Still requires the caller to provide `in_rbp`, leading back to the same default-parameter limitation in Strategy B. |
| **Strategy F: Effective Address Arithmetic (`lea`)** | `lea cur_sp, [%rsp + 0]` | **Successfully reads `%rsp`!** (Implemented in `get_rsp` / `get_sp`). | While `lea` solves reading `%rsp` as an address operand, it cannot be used to load or save general registers like `%rbp`, `%rbx`, `%rsi`, `%rdi`, `%r12`..`%r15`. |
| **Strategy G: `#no_init` Output Pinning** | `-> (r: rawptr) [ r = %rbp #no_init ]` | `Error: 'push' reads rbp at 64-bit width but only its low 0 bits are defined` | While `#no_init` sets the `seed_regs` entry bitmask in `check_asm_cfg.cpp`, the basic-block sub-register width lattice (`in_w[0]`) is initialized to all zeros, causing 64-bit reads to be rejected. |

### Conclusion on In-Language Workarounds:
Because an `asm` template in Odin is an **inlined SSA expression**, the compiler logically treats reading an unpinned physical register as a dataflow bug. Therefore, within the bounds of Odin's current frontend semantics, **no purely syntactic trick can bypass `check_asm_cfg_report_undef_reg`** without an explicit compiler-level directive (`#untracked_registers`) or using the native `#byte` directive.

---

## 6. Why `#byte` is the Designed and Safe Solution Today

The `#byte` directive is **not an external hack**; it is an official language-level capability defined directly in the Odin inline assembly grammar (`ASM.md` lines 221–233) and handled in `check_asm.cpp`:

```cpp
if (node->kind != Ast_AsmInstruction) {
    continue; // Directives (#byte, #skip, #nop) are straight-line filler; no CFG effect
}
```

### Benefits of `#byte` in the Current Architecture:
1. **Zero External Dependencies**: Bypasses the need for external assemblers (NASM, GAS, LLVM-MC), C compilers, or `.obj` / `.o` file linkers.
2. **100% Native Cross-Compilation**: Any host machine (e.g. Windows x64) can cross-compile for all targets (`darwin_arm64`, `linux_riscv64`, `linux_arm64`, `windows_amd64`) out of the box using `odin build` or `odin check`.
3. **Guaranteed Byte-Exact Machine Code**: Exactly 240 bytes (Win64), 64 bytes (SysV), 160 bytes (ARM64), and 208 bytes (RISC-V 64) with strict 16-byte alignment and no unexpected compiler register spills.

---

## 7. Future Compiler Roadmap: How to Enable Pure High-Level Inline ASM in Odin

To allow pure high-level assembly syntax for low-level runtime routines in future Odin versions, we propose the following 3 compiler improvements:

### Proposal A: `#untracked_registers` Template Directive
Add a new template directive `#untracked_registers` (or `#raw_frame`) to Odin's `asm` grammar:

```odin
fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
    from_rsp = %rcx,
    to_rsp   = %rdx,
    #untracked_registers, // Informs check_asm_cfg to disable undefined physical register diagnostics
    #volatile,
    #clobber memory,
] {
    push %rbp
    push %rbx
    push %rsi
    push %rdi
    push %r12
    push %r13
    push %r14
    push %r15
    ...
}
```
**Compiler Implementation**:
In `check_asm_cfg_analyse` (`E:\OdinLang\Odin\src\check_asm_cfg.cpp`), when `tmpl_entity->AsmTemplate.is_untracked_registers` is set, skip `check_asm_cfg_report_undef_reg` for unpinned physical registers.

---

### Proposal B: Fix RISC-V Float Register Table Classes
In `E:\OdinLang\Odin\src\asm_tables_riscv.cpp`, update the registration of registers `fs0`–`fs11`:
```cpp
// Change from:
REGISTER("fs0", AsmReg_fs0, AsmRegClass_GPR, 64)
// To:
REGISTER("fs0", AsmReg_fs0, AsmRegClass_FPR, 64)
```
This will allow `fsd` and `fld` mnemonics to pass operand type-checking.

---

### Proposal C: First-Class Naked Assembly Procedures (`proc "naked" asm`)
Allow procedures declared as `proc "naked"` to contain inline `asm` bodies where:
1. Arguments are automatically passed in standard ABI registers (`%rcx`/`%rdx` on Win64, `%rdi`/`%rsi` on SysV, `%x0`/`%x1` on ARM64, `%a0`/`%a1` on RISC-V).
2. The procedure is treated as an independent compilation unit rather than an inlined macro.
3. `ret` instructions inside the body are treated as the normal procedure exit point.

```odin
#no_instrumentation
fiber_context_switch :: proc "naked" (from_rsp: ^rawptr, to_rsp: rawptr) {
    asm [ #volatile, #clobber memory ] {
        push %rbp
        push %rbx
        ...
        mov [%rcx], %rsp
        mov %rsp, %rdx
        ...
        pop %rbx
        pop %rbp
        ret
    }
}
```

---

## 8. Summary & Quick Reference

| Use Case | Recommended Odin Syntax | Current Status |
| :--- | :--- | :--- |
| **Register Extraction (`get_r12_reg`, `get_x19_reg`, `get_s2_reg`)** | Pure High-Level Inline `asm` (`mov res, %r12`) | **Production Ready (In Use)** |
| **Vector & Math Intrinsics** | Pure High-Level Inline `asm` (`asm(a, b) -> (r)`) | **Production Ready (In Use)** |
| **Stack Swapping (`fiber_context_switch`)** | Inline `asm` with `#byte` directives | **Production Ready (In Use)** |
| **High-Level Context Switching** | High-Level `asm` + `#untracked_registers` | **Proposed Roadmap for Odin** |
