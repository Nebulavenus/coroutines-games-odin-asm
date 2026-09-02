# Low-Level Hardware & Inline Assembly Architecture (`TECH_ASM.md`)

This technical document details the low-level hardware mechanics, inline assembly primitives, register preservation contracts, synthetic stack frame initialization, and compiler safety invariants across **AMD64 (x86-64)**, **ARM64 (AArch64)**, and **RISC-V 64 (RV64GC)** powering the **Odin Stackful Coroutine Engine**.

> [!NOTE]
> For an in-depth breakdown of Odin's compiler internals, SSA liveness verification, and the future roadmap for high-level assembly context switching, see [`TECH_ODIN_INLINE_ASM_ANALYSIS.md`](./TECH_ODIN_INLINE_ASM_ANALYSIS.md).

---

## 1. Universal Multi-ISA Hardware Matrix

```
┌─────────────────────────────────────────────────────────────────────────────────────────┐
│                           UNIVERSAL MULTI-ISA HARDWARE MATRIX                           │
├───────────────────┬──────────────────────────┬──────────────────────────────────────────┤
│ Architecture      │ Target Devices           │ Frame Footprint & Preservation           │
├───────────────────┼──────────────────────────┼──────────────────────────────────────────┤
│ 1. AMD64 (x86-64) │ Intel / AMD Desktops,    │ Win64: 240B (8 GPRs + RET + XMM6..15)    │
│                   │ Servers, Steam Deck      │ SysV:   64B (6 GPRs + RET + Pad)         │
│                   │                          │ Self-ID: %r12                            │
├───────────────────┼──────────────────────────┼──────────────────────────────────────────┤
│ 2. ARM64 (AArch64)│ Apple Silicon (M1–M4),   │ 160B Frame (16-byte aligned):            │
│                   │ Linux ARM, Android, iOS, │ • 10 GPRs (x19–x28) + FP (x29) + LR (x30)│
│                   │ Switch, Win on ARM       │ • 8 SIMD/Float (d8–d15)                  │
│                   │                          │ Self-ID: %x19                            │
├───────────────────┼──────────────────────────┼──────────────────────────────────────────┤
│ 3. RISC-V 64      │ Linux RISC-V, SBCs,      │ 208B Frame (16-byte aligned):            │
│    (RV64GC)       │ VisionFive, Emulators    │ • 13 GPRs (ra, s0–s11)                   │
│                   │                          │ • 12 FPRs (fs0–fs11)                     │
│                   │                          │ Self-ID: %s2 (x18)                       │
└───────────────────┴──────────────────────────┴──────────────────────────────────────────┘
```

---

## 2. Multi-ISA Context Switching Mechanics

The coroutine engine implements cooperative user-space context switching (green threads / fibers) directly in Odin using native inline assembly (`asm`).

A context switch consists of suspending the execution state of the currently executing fiber (or scheduler) and resuming a target fiber by swapping CPU register state and the hardware stack pointer.

```
                    ┌──────────────────────────────────────────────┐
                    │              CPU Context Switch              │
                    └──────────────────────┬───────────────────────┘
                                           │
         Active Fiber Stack                ▼                   Target Fiber Stack
    ┌─────────────────────────┐   mov [from], sp         ┌─────────────────────────┐
    │ ...                     │ ───────────────────────► │ ...                     │
    │ [Saved Non-Volatile GPR]│   mov sp, to             │ [Saved Non-Volatile GPR]│
    │ [Saved SIMD / Float]    │ ◄─────────────────────── │ [Saved SIMD / Float]    │
    │ Return Address / LR     │      ret (Resume)        │ Target Instruction Ptr  │
    └─────────────────────────┘                          └─────────────────────────┘
```

When switching between fibers:
1. The caller executes `fiber_context_switch(&from_rsp, to_rsp)`.
2. The non-volatile registers (GPRs and callee-saved SIMD/floating-point registers) are saved onto the current stack.
3. The active stack pointer is written to `from_rsp^`.
4. The target stack pointer is loaded from `to_rsp` into the CPU's stack pointer register.
5. Callee-saved SIMD/float and GPR registers are restored from the target stack in reverse order.
6. The CPU executes `ret` (or jumps to the Link Register), resuming execution on the target fiber.

---

## 3. ABI Register Preservation Specifications

### A. AMD64 (Windows x64 vs. System V AMD64)

| Register Class | Windows x64 ABI (Win64) | System V AMD64 ABI (Linux / macOS / BSD) | Engine Preservation Strategy |
| :--- | :--- | :--- | :--- |
| **Stack Pointer** | `%rsp` | `%rsp` | Swapped via memory operand |
| **Callee-Saved GPRs** | `%rbp`, `%rbx`, `%rsi`, `%rdi`, `%r12`, `%r13`, `%r14`, `%r15` | `%rbp`, `%rbx`, `%r12`, `%r13`, `%r14`, `%r15` | Pushed / popped sequentially on fiber stack |
| **Callee-Saved SIMD** | `%xmm6` through `%xmm15` (10 registers) | None (all XMM registers are volatile) | Stored / loaded via `movdqu` (160 bytes on stack) |
| **Caller-Saved GPRs** | `%rax`, `%rcx`, `%rdx`, `%r8`..`%r11` | `%rax`, `%rcx`, `%rdx`, `%rsi`, `%rdi`, `%r8`..`%r11` | Declared in `#clobber` |
| **Self-Identity Register** | `%r12` | `%r12` | Bound to `^Fiber` across fiber lifecycle |

---

### B. ARM64 (AAPCS64 Standard ABI)

| Register Class | Registers Preserved | Size | Engine Preservation Strategy |
| :--- | :--- | :--- | :--- |
| **Stack Pointer** | `%sp` (16-byte aligned) | 8B | Hardware enforced 16-byte aligned accesses |
| **Frame / Link Regs** | `%x29` (FP) + `%x30` (LR / Return Address) | 16B | Stored / loaded via `stp`/`ldp x29, x30, [sp, #0]` |
| **Callee-Saved GPRs** | `%x19` through `%x28` (10 registers) | 80B | Stored / loaded in pairs via `stp`/`ldp` |
| **Callee-Saved SIMD** | `%d8` through `%d15` (8 registers) | 64B | Stored / loaded in pairs via `stp`/`ldp` |
| **Total Frame Size** | **160 Bytes** | 160B | `sub sp, sp, #160` / `add sp, sp, #160` |
| **Self-Identity Register** | `%x19` | 8B | Extracted via high-level inline `get_x19_reg()` |

---

### C. RISC-V 64 (RV64GC / LP64D ABI)

| Register Class | Registers Preserved | Size | Engine Preservation Strategy |
| :--- | :--- | :--- | :--- |
| **Stack Pointer** | `%sp` (`x2`, 16-byte aligned) | 8B | 16-byte aligned frame offset |
| **Return Address** | `%ra` (`x1`) | 8B | Stored / loaded via `sd`/`ld ra, 0(sp)` |
| **Callee-Saved GPRs** | `%s0` (`x8`/fp), `%s1` (`x9`), `%s2`–`%s11` (`x18`–`x27`) | 96B | Stored / loaded via `sd`/`ld` |
| **Callee-Saved FPRs** | `%fs0`–`%fs1` (`f8`–`f9`), `%fs2`–`%fs11` (`f18`–`f27`) | 96B | Stored / loaded via `fsd`/`fld` |
| **Alignment Pad** | 1 slot (8 bytes) | 8B | Padded to 208B for strict 16-byte alignment |
| **Total Frame Size** | **208 Bytes** | 208B | `addi sp, sp, -208` / `addi sp, sp, 208` |
| **Self-Identity Register** | `%s2` (`x18`) | 8B | Extracted via high-level inline `get_s2_reg()` |

---

### D. Link Register Return Trampolines on RISC Architectures
Because Odin inlines `asm(...)` templates directly into calling procedures (`wait_frames`, `scheduler_step`), the CPU's Link Register (`x30` on ARM64, `ra` on RISC-V 64) points to the outer caller upon entering the template. To ensure clean return flow, both RISC architectures use a **Branch-and-Link Return Trampoline**:
* **ARM64**: `bl .switch_body` (+8B) sets `x30` pointing to `b .switch_done` (+108B), so `ret` at the end of `.switch_body` jumps directly to `.switch_done` on the restored fiber's stack.
* **RISC-V 64**: `jal ra, +8` (+8B) sets `ra` pointing to `j .switch_done` (+224B), so `jalr zero, ra, 0` returns directly to `.switch_done` on the restored fiber's stack.

### F. High-Level Inline Assembly Register & Stack Extractors
For operations with well-defined dataflow, the engine uses **100% pure high-level Odin inline assembly templates**:
* **Fiber Self-Identity Registers**:
  ```odin
  // AMD64
  get_r12_reg :: asm() -> (res: rawptr) [ res = %r12 ] { mov res, %r12 }
  // ARM64
  get_x19_reg :: asm() -> (res: rawptr) [ res = %x19 ] { mov res, %x19 }
  // RISC-V 64
  get_s2_reg  :: asm() -> (res: rawptr) [ res = %s2 ]  { addi res, %s2, 0 }
  ```
* **Active Stack Pointer Extraction**:
  ```odin
  // AMD64 (uses effective address arithmetic to avoid unproduced register liveness checks)
  get_rsp :: asm() -> (sp: rawptr) [ #volatile ] { lea sp, [%rsp] }
  // ARM64
  get_sp  :: asm() -> (sp: rawptr) [ sp = %x0, #volatile ] { #byte 0xe0, 0x03, 0x00, 0x91 }
  // RISC-V 64
  get_sp  :: asm() -> (sp: rawptr) [ sp = %a0, #volatile ] { #byte 0x13, 0x05, 0x01, 0x00 }
  ```

---

## 4. Synthetic Stack Frame Initialization

When a fiber is acquired from the pool, `fiber_synthesize_initial_stack` sets up a bootstrap stack frame so that the first context switch enters `fiber_trampoline_entry` cleanly:

### AMD64 Windows Frame (240B)
* `top - 8`: Dummy alignment pad (`RSP % 16 == 8` on entry).
* `top - 16`: `rawptr(fiber_trampoline_entry)` (RET).
* `top - 56`: `rawptr(fiber)` (`%r12`).
* `top - 240`: Zeroed XMM storage.

### ARM64 Frame (160B)
* `sp + 0`: `x29 = nil`, `x30 = rawptr(fiber_trampoline_entry)` (LR).
* `sp + 16`: `x19 = rawptr(fiber)`, `x20 = nil`.
* `sp + 32..144`: Zeroed GPRs and SIMD registers.

### RISC-V 64 Frame (208B)
* `sp + 0`: `ra = rawptr(fiber_trampoline_entry)`.
* `sp + 8`: `s0 = nil`, `sp + 16`: `s1 = nil`.
* `sp + 24`: `s2 = rawptr(fiber)`.
* `sp + 32..192`: Zeroed GPRs and FPRs.

---

## 5. Verification & Cross-Architecture CI Matrix

The engine is verified across all targets via automated test runners:
```powershell
# Native Windows Host (All 188 unit tests)
.\build.ps1 test

# Cross-Target Static Compilation Validation (All 6 targets)
.\build.ps1 check-all

# WSL2 QEMU Full Unit Test Suite (All 188 tests on ARM64 & RISC-V 64)
.\run_wsl_qemu.ps1 test

# WSL2 QEMU 10,000 Concurrent Fiber Benchmarks
.\run_wsl_qemu.ps1 bench
```
* **GitHub Actions CI Matrix**: Tests native AMD64 (Windows/Ubuntu), native Apple Silicon ARM64 (`macos-14`), and QEMU-emulated Linux ARM64 and RISC-V 64 on every commit.


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
