# Low-Level Hardware & Inline Assembly Architecture (`TECH_ASM.md`)

This technical document details the low-level AMD64 hardware mechanics, inline assembly primitives, register preservation contracts, synthetic stack frame initialization, and compiler safety invariants powering the **Odin Stackful Coroutine Engine**.

---

## 1. AMD64 Context Switching Mechanics

The coroutine engine implements cooperative user-space context switching (green threads / fibers) directly in Odin using native inline assembly (`#asm` / `asm`). 

A context switch consists of suspending the execution state of the currently executing fiber (or scheduler) and resuming a target fiber by swapping CPU register state and the hardware stack pointer (`%rsp`).

```
                    ┌──────────────────────────────────────────────┐
                    │              CPU Context Switch              │
                    └──────────────────────┬───────────────────────┘
                                           │
         Scheduler Stack                   ▼                   Target Fiber Stack
    ┌─────────────────────────┐   movq %rsp, (%rdi)      ┌─────────────────────────┐
    │ ...                     │ ───────────────────────► │ ...                     │
    │ [Saved Non-Volatile GPR]│   movq (%rsi), %rsp      │ [Saved Non-Volatile GPR]│
    │ [Saved SIMD Registers]  │ ◄─────────────────────── │ [Saved SIMD Registers]  │
    │ Return Address (Caller) │      ret (Resume)        │ Target Instruction Ptr  │
    └─────────────────────────┘                          └─────────────────────────┘
```

When switching between fibers:
1. The caller executes a call to the context switch routine. The CPU hardware automatically pushes the 8-byte instruction pointer (`%rip`) of the instruction following the call onto the current stack.
2. The context switch routine saves all callee-saved General Purpose Registers (GPRs) and callee-saved SIMD floating-point registers (`%xmm6` through `%xmm15` on Windows x64) onto the current stack.
3. The current stack pointer `%rsp` is saved into the active fiber's `from_rsp^` storage pointer.
4. The target fiber's saved stack pointer is loaded from `to_rsp` directly into the CPU's `%rsp` register.
5. Callee-saved SIMD and GPR registers are restored (popped) in reverse order from the target fiber's stack.
6. The CPU executes `ret`, which pops the target fiber's saved instruction pointer from the new stack into `%rip`, resuming execution seamlessly.

---

## 2. ABI Register Preservation Specifications

Operating systems and calling conventions dictate which registers are **callee-saved (non-volatile)** and must be preserved across procedure calls and context switches, versus **caller-saved (volatile)** registers.

### Windows x64 ABI vs. System V AMD64 ABI

| Register Class | Windows x64 ABI (Win64) | System V AMD64 ABI (Linux / macOS / BSD) | Engine Preservation Strategy |
| :--- | :--- | :--- | :--- |
| **Stack Pointer** | `%rsp` | `%rsp` | Swapped via memory operand |
| **Callee-Saved GPRs** | `%rbp`, `%rbx`, `%rdi`, `%rsi`, `%r12`, `%r13`, `%r14`, `%r15` | `%rbp`, `%rbx`, `%r12`, `%r13`, `%r14`, `%r15` | Pushed / popped sequentially on fiber stack |
| **Callee-Saved SIMD** | `%xmm6` through `%xmm15` (10 registers) | None (all XMM registers are volatile) | Stored / loaded via `movdqu` (160 bytes on stack) |
| **Caller-Saved GPRs** | `%rax`, `%rcx`, `%rdx`, `%r8`, `%r9`, `%r10`, `%r11` | `%rax`, `%rcx`, `%rdx`, `%rsi`, `%rdi`, `%r8`, `%r9`, `%r10`, `%r11` | Explicitly declared in `#clobbers` |
| **Status Flags** | `rflags` | `rflags` | Declared in `#clobbers` (`"cc"`) |

### Why Windows x64 Requires Preserving `xmm6`–`xmm15`

Under the Microsoft x64 calling convention, the low 128 bits of registers `xmm6` through `xmm15` are non-volatile and **must be preserved** by a callee. If a context switch does not save and restore `xmm6`–`xmm15`:
- Vector math, floating-point calculations, matrix transforms, and SIMD operations inside one coroutine will silently corrupt floating-point registers in other coroutines or the main engine loop.
- The engine allocates 160 bytes (10 registers $\times$ 16 bytes) on the stack during every context switch on Windows to store these registers with unaligned 16-byte move instructions (`movdqu`).

### Complete Windows x64 Callee-Saved Stack Layout

When a fiber suspends on Windows x64, its stack frame holds exactly:
1. 10 SIMD registers $\times$ 16 bytes = 160 bytes (`xmm6` .. `xmm15`).
2. 8 General Purpose Registers $\times$ 8 bytes = 64 bytes (`rbp`, `rbx`, `rdi`, `rsi`, `r12`, `r13`, `r14`, `r15`).
3. 1 Return address $\times$ 8 bytes = 8 bytes.

Total context switch frame size: **232 bytes**.

```
High Address (Stack Base)
┌────────────────────────────────────────────────────────┐
│ Return Address (%rip after call)              (8 Bytes)│
├────────────────────────────────────────────────────────┤
│ Saved %rbp                                    (8 Bytes)│
│ Saved %rbx                                    (8 Bytes)│
│ Saved %rdi                                    (8 Bytes)│
│ Saved %rsi                                    (8 Bytes)│
│ Saved %r12                                    (8 Bytes)│
│ Saved %r13                                    (8 Bytes)│
│ Saved %r14                                    (8 Bytes)│
│ Saved %r15                                    (8 Bytes)│
├────────────────────────────────────────────────────────┤
│ Saved %xmm6                                  (16 Bytes)│
│ Saved %xmm7                                  (16 Bytes)│
│ Saved %xmm8                                  (16 Bytes)│
│ Saved %xmm9                                  (16 Bytes)│
│ Saved %xmm10                                 (16 Bytes)│
│ Saved %xmm11                                 (16 Bytes)│
│ Saved %xmm12                                 (16 Bytes)│
│ Saved %xmm13                                 (16 Bytes)│
│ Saved %xmm14                                 (16 Bytes)│
│ Saved %xmm15                                 (16 Bytes)│
└────────────────────────────────────────────────────────┘ ◄── Current %rsp
Low Address
```

---

## 3. The Call / Ret Trampoline Mechanism

Instead of maintaining a separate Program Counter (`%rip`) field in the fiber struct and manually jumping via `jmp`, the engine leverages the CPU's native `call` and `ret` instructions:

1. When `context_switch(from_rsp, to_rsp)` is invoked:
   - The CPU pushes the return address (`%rip` immediately after the call) onto the current stack.
   - The context switch routine pushes all non-volatile GPRs and SIMD registers onto the current stack.
   - The current stack pointer (`%rsp`) is saved into `from_rsp^`.
   - The target stack pointer is loaded into `%rsp` from `to_rsp`.
   - Non-volatile SIMD and GPRs are popped from the target stack.
   - The `ret` instruction pops the stored return address into `%rip`, seamlessly resuming execution inside the target fiber or scheduler.

This ensures zero branch mispredictions or instruction decoding stalls compared to manual long jumps.

---

## 4. The `%r12` Universal Register Passing Trick

During initial fiber bootstrap and subsequent context switches, the target `^Fiber` pointer must be accessible without polluting caller-saved argument registers that could be overwritten during initialization:

- When `scheduler_step` switches to a fiber, `%r12` is loaded with the fiber pointer (`target_fiber`).
- Because `%r12` is a callee-saved register across both Windows x64 and System V ABIs, procedures inside the fiber can recover self-identity and scheduler references directly from `%r12`.
- When switching back to the scheduler, `%r12` is restored to its original value, ensuring zero register pollution in the host loop.

---

## 5. Compiler Safety & SSA Invalidation

Modern optimizing compilers (such as LLVM in Odin) perform aggressive Dead Code Elimination (DCE), Common Subexpression Elimination (CSE), and register caching across procedure calls. A stack switch violates standard single-stack assumptions if not properly guarded.

### Compiler Invariants Enforced in Engine

1. **`#volatile` Directive:**
   All inline assembly blocks are marked `#volatile`. This instructs the compiler backend that the assembly block has side effects that cannot be reordered, duplicated, or eliminated.

2. **Caller-Saved Register Clobbers:**
   All volatile registers are explicitly listed in the `#clobbers` clause:
   ```odin
   #clobbers "rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11", "cc", "memory"
   ```

3. **Memory Barrier (`"memory"` clobber):**
   The `"memory"` clobber forces LLVM to flush all cached register values to memory before the context switch and reload memory values after resuming. This prevents the compiler from assuming heap or global memory remains unchanged across a yield.

---

## 6. Stack Layout & Strict 16-Byte Alignment

AMD64 ABIs require the stack pointer (`%rsp`) to be **16-byte aligned** immediately before any `call` instruction.

```
Stack High Address (Base)
┌──────────────────────────────────────────┐ ◄── stack_base (16-byte aligned)
│ Top-of-Stack Canary (0xDEADBEEF...)      │
├──────────────────────────────────────────┤
│ Synthetic Stack Frame (Bootstrap)        │
│ • Initial Return Address: fiber_entry    │
│ • Initial Saved GPRs (8 x 8B = 64B)      │
│ • Initial Saved SIMD (10 x 16B = 160B)   │
├──────────────────────────────────────────┤ ◄── Initial rsp (aligned to 16B - 8B offset)
│ Active Execution Call Stack              │
│ ▼ (Grows Downward)                       │
│                                          │
├──────────────────────────────────────────┤ ◄── stack_limit (Stack Overflow Boundary)
│ Bottom Guard / Canary (0xDEADBEEF...)    │
└──────────────────────────────────────────┘ ◄── stack_memory (Allocation Base)
Stack Low Address
```

### Synthetic Frame Initialization
When `fiber_init` configures a new fiber stack:
1. `rsp` is set to `stack_base - size_of(Synthetic_Frame)`.
2. The synthetic frame's return address is set to `fiber_entry_trampoline`.
3. When the scheduler switches to this virgin stack for the first time, `ret` pops `fiber_entry_trampoline`, jumping directly into the user procedure with a fully aligned stack.
4. When the user procedure returns, `fiber_entry_trampoline` marks the fiber as `.Finished`, resets its temporary arena, and switches back to the scheduler loop.
