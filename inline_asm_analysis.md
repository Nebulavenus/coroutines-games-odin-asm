# Odin Inline Assembly Analysis: Compiler Internals, Blocking Mechanisms & High-Level ASM (`inline_asm_analysis.md`)

This document details the deep-dive research into the Odin programming language compiler source code (`E:\OdinLang\Odin\src\check_asm.cpp`, `check_asm_cfg.cpp`, `llvm_backend_asm.cpp`, and `parser.cpp`), explaining the exact compiler frontend, backend, and LLVM machine-instruction mechanisms that blocked high-level assembly in the coroutine library, documenting hidden features uncovered in the compiler, and presenting **Option A** (pure high-level assembly with compiler patch) and its runtime mechanics.

---

## 1. Executive Summary & Root Cause Findings

When implementing the stackful coroutine engine (`src/coroutine/asm_amd64.odin`, `asm_arm64.odin`, `asm_riscv64.odin`), the context switch was implemented using `#byte` machine code arrays rather than pure high-level assembly mnemonics.

Through compiler source analysis and LLVM code generation verification, **six distinct blocking behaviors across three compiler layers** were identified:

| Layer | Blocker | Compiler Location | Manifestation | Root Cause | Workaround / Solution |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Frontend SSA** | **1. Undefined Register Check** | `check_asm_cfg.cpp:688` (`check_asm_cfg_report_undef_reg`) | `'push' implicitly reads %rbp, but nothing in this template produces a value for it` | Callee-saved registers read at entry without prior write | `#no_init` directive on output/tied/scratch parameters |
| **Frontend SSA** | **2. Sub-Register Width Lattice Flaw** | `check_asm_cfg.cpp:698` (`in_w[0]`) | `'mov' reads %rcx at 64-bit width but only its low 0 bits are defined` | Entry lattice `in_w[0]` is initialized to `{}` for physical register tokens (`%reg`) | Parameter Indirection (`Ident` token routes to `seed_pm` instead of `in_w`) |
| **Frontend CFG** | **3. Dead-Write Detection** | `check_asm_cfg.cpp:1015` (`check_asm_cfg_liveness`) | `'pop' writes %rbp but its value is never read before being overwritten or template ends` | Final pops before template return are not read within template | Declare registers in `#clobber %reg` to add them to `exit_live` |
| **Frontend CFG** | **4. CFG Non-Fallthrough on `call`** | `check_asm_cfg.cpp:284` (`is_terminal`) | `The asm instruction is unreachable` on instructions following `call` | `call` is conservatively marked `is_terminal = true` | Use indirect jump (`jmp rax`), direct branch, or minimal trampoline |
| **Backend Codegen** | **5. LLVM Missing Label Colon Bug** | `llvm_backend_asm.cpp:390` (`write_label_def`) | `LLVM Error: unknown directive .L_...` & `assembler label ... can not be undefined` | Emits `.L_<tmpl>_<label>${:uid}` without trailing colon `:` on AMD64 & RISC-V | **Option A**: Patch `llvm_backend_asm.cpp` to emit `:` on label definitions |
| **LLVM Machine RA** | **6. Frame Pointer Interference** | LLVM Machine Function Register Allocator | `LLVM Error: Interference usage of base pointer/frame pointer.` | LLVM reserves `%rbp` as frame pointer; inline asm cannot bind/clobber `%rbp` | Low-level `#byte` machine code (which bypasses LLVM register allocator constraints) |

---

## 2. In-Depth Compiler Subsystem Walkthrough

### 2.1 The Undocumented `#no_init` Directive

In `E:\OdinLang\Odin\src\check_asm.cpp` (lines 821–835):
```cpp
for (Ast *dir_ : spec->directives) {
    ast_node(dir, BasicDirective, dir_);
    String name = dir->name.string;
    if (name == "no_init") {
        i32 input_index = -1;
        check_asm_find_group(input, *asm_template_entity_decls, &input_index);
        if (input_index >= 0) {
            auto *i = &(*asm_template_entity_decls)[input_index];
            i->no_init = true;
            if (i->tie >= 0) {
                auto *o = &(*asm_template_entity_decls)[i->tie];
                o->no_init = true;
            }
        }
    } else {
        error(dir_, "Invalid directive for an asm specification, got '#%.*s'", LIT(name));
    }
}
```

In `check_asm_cfg.cpp` (lines 405–415):
```cpp
u16 seed_regs = 0;
u64 seed_pm   = 0;
for_array(i, decls) {
    auto const &ed = decls[i];
    u16 pin_bit = cfg->decl_pin_bit[i];
    if (ed.no_init) {
        seed_pm |= bit_of(ed.entity);
        seed_regs |= pin_bit;
    }
    // ...
}
```
**Mechanism**:
- When `#no_init` is attached to a parameter spec, its pinned register bit is added to `seed_regs` and `seed_pm` at block 0.
- When an instruction at entry reads this register (e.g. `push rbp_reg`), `undef = f->read_regs & ~run_regs` evaluates to 0. No undefined register error is emitted!
- At template exit (`check_asm_cfg.cpp:818`), `if (ed.tie >= 0 || ed.no_init) continue;` exempts the parameter from mandatory write checks.

### 2.2 The Two-Step Scratch Binding Pattern

In `check_asm.cpp` (lines 567 and 635):
```cpp
Entity *input = scope_lookup_current(scope, spec->name->Ident.interned, spec->name->Ident.hash);
// ...
if (spec->type != nullptr) {
    // Scratch parameter declaration
    Entity *entity = alloc_entity_param(scope, ...);
    Entity *found = scope_insert(scope, entity); // Inserted into scope HERE
}
```
Because `input` is queried at the start of the spec loop before the scratch parameter is inserted into `scope`, single-step declarations like `[ rbp_reg: u64 = %rbp #no_init ]` evaluate `input == nullptr` when `#no_init` is processed.
**The Solution (Two-Step Declaration)**:
```odin
[
    rbp_reg: u64,                  // Step 1: Inserts 'rbp_reg' into scope
    rbp_reg = %rbp #no_init,       // Step 2: 'input' is found; #no_init is successfully set!
]
```

### 2.3 Parameter Indirection vs Physical Registers

In `check_asm.cpp` (lines 1770–1835):
- Explicit register tokens (`Ast_AsmRegister`, e.g. `%rcx`):
  Populate `facts->read_reg_w` and check the sub-register width lattice `in_w[0]`. Since `in_w[0]` is initialized to `{}` (0 bits), reading `%rcx` triggers:
  `'mov' reads rcx at 64-bit width but only its low 0 bits are defined on all paths here`.
- Parameter identifier tokens (`Ast_Ident`, e.g. `val`):
  Populate `facts->read_params` and check `run_pm & (1 << id)`. Since `val` is an input parameter (or `#no_init` scratch), its bit in `seed_pm` is set.
- **Rule**: Never use `%reg` directly in instruction operands when reading an existing value. Always bind a parameter name and reference the parameter identifier.

### 2.4 The LLVM Frame Pointer Interference Barrier

When an inline assembly template binds `%rbp` (e.g. `rbp_reg: u64, rbp_reg = %rbp #no_init`) or lists `#clobber %rbp`:
- Odin generates LLVM inline assembly constraints containing `{rbp}` or `~{rbp}`.
- LLVM's machine code generator reserves `%rbp` as the frame pointer for any procedure containing non-trivial stack allocations or dynamic stack alignment.
- When LLVM encounters `{rbp}` or `~{rbp}` in an inline assembly constraint, it aborts compilation with:
  `LLVM Error: Interference usage of base pointer/frame pointer.`
- **Crucial Architecture Takeaway**: In standard C/C++ and LLVM compilers, an inline assembly statement inside a regular C/Odin procedure is **strictly prohibited by LLVM** from clobbering or explicitly binding the host procedure's active frame pointer (`%rbp` on x86_64).
- This explains why operating systems and coroutine libraries (such as Boost.Context, glibc `swapcontext`, and Go runtime) implement stack context switches in standalone assembly files (`.S` / `.asm`) rather than inline assembly statements, or use raw `#byte` opcode streams that bypass LLVM's register allocator constraints!

---

## 3. The LLVM Backend Label Defect (Root Cause of Blocker 5)

### 3.1 Code Inspection of `llvm_backend_asm.cpp`

In `E:\OdinLang\Odin\src\llvm_backend_asm.cpp` (lines 388–398):
```cpp
virtual void write_label_def(AstIdent *label_ident) {
    String name = label_ident->token.string;
    write_cstr(".L_");
    write_string(tmpl_entity->token.string);
    write_cstr("_");
    write_string(name);
    write_cstr("${:uid}"); // BUG: Missing trailing colon ':'
}
virtual void write_label_ref(AstIdent *label_ident) {
    this->write_label_def(label_ident); // default: same spelling for def and ref
}
```
And in the instruction emission loop (line 305):
```cpp
case_ast_node(label, AsmLabelDecl, instr_);
    this->write_label_def(&label->name->Ident);
case_end;
```

### 3.2 The Asymmetry: ARM64 vs AMD64 / RISC-V
- In `lbAsmGenerate_arm64`:
  ```cpp
  void write_label_def(AstIdent *label_ident) override {
      asm_string = gb_string_append_fmt(asm_string, "%d:", this->arm64_label_number(label_ident));
  }
  void write_label_ref(AstIdent *label_ident) override {
      char dir = this->label_is_forward(label_ident) ? 'f' : 'b';
      asm_string = gb_string_append_fmt(asm_string, "%d%c", this->arm64_label_number(label_ident), dir);
  }
  ```
  ARM64 overrides both and explicitly includes `%d:` (with colon) on def, and `%d%c` (without colon) on ref.
- In `lbAsmGenerate` (default for AMD64 and RISC-V):
  `write_label_ref` simply forwards to `write_label_def`. Because both use the identical string, the author omitted the colon from `write_label_def` so references wouldn't have colons, but forgot to emit the colon when processing `AsmLabelDecl`!

---

## 4. Option A: Pure High-Level ASM Specification

Option A implements 100% pure high-level assembly with named labels and direct instruction mnemonics.

### 4.1 The Required Compiler Patch (`E:\OdinLang\Odin\src\llvm_backend_asm.cpp`)

To resolve the label defect upstream in Odin:
```diff
--- a/src/llvm_backend_asm.cpp
+++ b/src/llvm_backend_asm.cpp
@@ -304,6 +304,7 @@ struct lbAsmGenerate {
 			case_ast_node(label, AsmLabelDecl, instr_);
 				this->write_label_def(&label->name->Ident);
+				this->write_cstr(":\n");
 			case_end;
```
*(Per user instruction, this patch is documented here only and NOT applied to `E:\OdinLang\Odin` directly).*

### 4.2 High-Level AMD64 Context Switch Specification (Option A)

```odin
when ODIN_ARCH == .amd64 && ODIN_OS == .Windows {
    fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
        from_rsp = %rcx,
        to_rsp   = %rdx,
        rsp_reg: rawptr, rsp_reg = %rsp #no_init,
        rax_scratch: rawptr = %rax,

        // Callee-saved GPRs via Two-Step #no_init Scratch Binding
        rbp_reg: u64, rbp_reg = %rbp #no_init,
        rbx_reg: u64, rbx_reg = %rbx #no_init,
        rsi_reg: u64, rsi_reg = %rsi #no_init,
        rdi_reg: u64, rdi_reg = %rdi #no_init,
        r12_reg: u64, r12_reg = %r12 #no_init,
        r13_reg: u64, r13_reg = %r13 #no_init,
        r14_reg: u64, r14_reg = %r14 #no_init,
        r15_reg: u64, r15_reg = %r15 #no_init,

        #volatile,
        #clobber flags,
        #clobber memory,
        #clobber %rax,
        #clobber %rsp,
    ] {
        // Satisfy CFG reachability
        test to_rsp, to_rsp
        jz .resume

        // 1. Save GPRs
        push rbp_reg
        push rbx_reg
        push rsi_reg
        push rdi_reg
        push r12_reg
        push r13_reg
        push r14_reg
        push r15_reg

        // 2. Save XMMs (omitted for brevity)
        // 3. Push Resume Address
        lea rax_scratch, [.resume]
        push rax_scratch

        // 4. Swap Stack Pointers
        mov [from_rsp], rsp_reg
        mov rsp_reg, to_rsp

        // 5. Jump to Target Fiber's Saved Resume Point
        ret

    .resume:
        // 6. Restore GPRs
        pop r15_reg
        pop r14_reg
        pop r13_reg
        pop r12_reg
        pop rdi_reg
        pop rsi_reg
        pop rbx_reg
        pop rbp_reg
    }
}
```

---

---

## 5. Architectural Evaluation: Why `#byte` Remains the Optimal Production Standard

### 5.1 The Four Pillars of `#byte` Superiority
1. **Immunity to LLVM Frame Pointer & Base Pointer Interference**:
   Because `#byte` does not emit LLVM register constraints (`{rbp}`, `{rsp}`), LLVM's machine code allocator never raises `Interference usage of base pointer/frame pointer`.
2. **Immunity to Odin Label Backend Defects**:
   `#byte` opcodes encode relative offsets in machine code (`0xE8, 0x05...`), entirely bypassing the missing colon in Odin's LLVM label backend (`llvm_backend_asm.cpp:390`).
3. **Immunity to Vector Register Corruption via Early-Clobber (`=&`) Outputs**:
   In Odin's LLVM backend (`llvm_backend_asm.cpp:208-233`), scratch parameters are modeled as discarded early-clobber outputs (`=&{xmmN}`). When lowering instructions like `movdqu [%rsp + off], xmm_reg` into GNU AT&T syntax (`movdqu %xmmN, off(%rsp)`), LLVM treats `%xmmN` as an uninitialized output rather than an existing live input. This clobbers the caller's live floating-point/vector registers with undefined values, causing CPU traps (`Illegal_Instruction` / `0xC000001D`). Direct `#byte` emission (`0x44, 0x0F, 0x7F...`) preserves raw CPU hardware vector state without compiler interference.
4. **100% Stock Compiler Portability**:
   Works out of the box with any official Odin release without requiring custom patches or local compiler builds.
5. **Guaranteed Zero-Overhead**:
   Identical instruction sequences to pure assembly, validated down to the exact mnemonic via `core:rexcode` disassembler verification in Test 187.

---

## 6. Git Archaeology & Evolution: Why High-Level ASM Worked in Old Commits

A historical audit across both this codebase and the upstream Odin compiler (`E:\OdinLang\Odin`) explains the transition:

### 6.1 The Historical Working Code (`commit 5e87a71`)
In early August 2026, context switches were written in raw high-level assembly:
```odin
fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [ ... ] {
    call .switch_body
    jmp .switch_done
.switch_body:
    push %rbp
    push %rbx
    ...
    sub %rsp, 160
    mov [%rcx], %rsp
    mov %rsp, %rdx
    ...
    ret
.switch_done:
}
```
At that point:
- The Odin compiler frontend only performed basic syntactic checks and token validation.
- It did **not** construct a basic block Control Flow Graph (CFG).
- It did **not** track register definitions across execution paths.
- It did **not** evaluate sub-register bit-width lattices.

### 6.2 The Upstream Compiler Overhaul (August 24–28, 2026)
Between August 24 and August 28, 2026, Odin merged several major PRs authored by gingerBill:
- **`ee68d39c2` (PR #7444 `bill/asm-cfg`)**: Added `check_asm_cfg.cpp`, introducing a full basic-block CFG and conservative terminal checks (`call` marked `is_terminal = true`).
- **`b4cf9b14b` (`asm: Implement sub-register width analysis`)**: Added the `in_w` bit-width lattice, initializing raw physical registers `%reg` to 0 defined bits at entry block 0.
- **`6f65d775c` (`Re-add check_asm_cfg_liveness`)**: Enforced dead-write detection on unread register modifications near template exit.

These compiler enhancements broke the original high-level code with strict compile-time errors. Consequently, in commit [`f6ae2a7`](CHANGELOG.md), context switching was migrated to `#byte` machine code arrays, while high-level inline assembly was retained for stack and register extractors (`get_rsp`, `get_sp`, `get_r12_reg`, `get_x19_reg`, `get_s2_reg`).
