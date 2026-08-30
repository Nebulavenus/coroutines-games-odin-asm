Here is a comprehensive architectural analysis and design proposal for building a **SkookumScript-inspired, Structured Concurrency Coroutine Library** in Odin from the ground up, utilizing native **inline assembly (`asm`)**.

---

# 1. Paradigm Shift: Where We Are vs. Where We Want to Be

### Current Architecture (The AST / Tagged-Union State Machine)
Your current implementation uses a **stackless AST graph**:
- Coroutines are trees of `Node` structs stored in a handle map.
- Execution steps down the tree frame-by-frame.
- **The Friction:**
  - Control flow cannot use native Odin keywords (`if`, `for`, `switch`, local variables).
  - State persistence across yields requires manual closure emulation via `Rc(T)`, headers, raw pointers, and thunk wrappers.
  - Composing logic feels like building an expression tree rather than writing gameplay code.

### Proposed Architecture (Native Stackful Structured Concurrency via ASM)
With Odin's new inline `asm` templates, we can implement **lightweight, cooperative green threads (Fibers)** directly into Odin.
- Coroutines become **real Odin procedures** with standard local variables, loops, and conditions.
- Pausing execution (`wait`, `yield`, `race`, `sync`) is a direct CPU register context switch taking **~5–15 nanoseconds**.
- **SkookumScript's killer feature**—Hierarchical Structured Concurrency (`race`, `sync`, branch cancellation, and lifecycle scopes)—is built on a parent-child fiber tree rather than a manual AST.

---

# 2. Deconstructing the SkookumScript Concurrency Model

SkookumScript’s gameplay scripting model relies on five core pillars:

```
                      [ Parent Coroutine ]
                               │
            ┌──────────────────┴──────────────────┐
            ▼                                     ▼
      sync { A, B }                         race { C, D }
      (Waits for both)                   (First wins, aborts other)
     ┌──────┴──────┐                           ┌──────┴──────┐
     ▼             ▼                           ▼             ▼
  [Task A]      [Task B]                    [Task C]      [Task D]
```

1. **Sequential Linearity:** Code reads top-to-bottom. Yielding does not lose call-stack context.
2. **`sync` (Parallel Join):** Spawns $N$ concurrent branches and suspends the parent. The parent resumes *only when all branches finish successfully*. If any branch fails, all sibling branches are cancelled immediately.
3. **`race` (First-to-Finish Preemption):** Spawns $N$ concurrent branches. The moment *any* branch completes or fails, all other competing branches are **instantly aborted and cleaned up**.
4. **Hierarchical Lifetime & Scope Guarding:** Coroutines are attached to an owner (e.g., an `Enemy` or a parent task). If the owner dies or the parent aborts, the entire sub-tree of child fibers is guaranteed to be terminated.
5. **No Manual Ref-Counting (`Rc` Elimination):** Because each coroutine has its own stack frame, local variables remain safely on the stack across yields.

---

# 3. Technical Core: How Inline ASM Enables This

### A. The Context Switch (`asm` primitive)
To switch between the **Scheduler Stack** and a **Coroutine Fiber Stack**, we only need to preserve the **non-volatile (callee-saved) registers** as dictated by the target ABI.

* **Windows x64 ABI Callee-Saved Registers:**
  `rsp`, `rbp`, `rbx`, `rsi`, `rdi`, `r12`, `r13`, `r14`, `r15`, and SIMD `xmm6` through `xmm15`.
* **System V ABI (Linux / macOS amd64) Callee-Saved Registers:**
  `rsp`, `rbp`, `rbx`, `r12`, `r13`, `r14`, `r15`.

Using Odin's inline `asm`, a context switch is a single inlined template that:
1. Pushes/stores caller-saved state or adjusts the stack.
2. Swaps `%rsp` with the target fiber's saved `%rsp`.
3. Pops/restores the state and executes `ret` into the new fiber.

### B. Preserving Odin's `runtime.Context`
Odin passes an implicit `context` structure to procedures. When switching stacks, the library must save and restore the fiber's `context` (which includes custom allocators, temporary allocators, logger, and user data) so that Odin's runtime invariants are never broken.

### C. Stack Memory Strategy (Zero OS Thread Overhead)
- **Preallocated Stack Pools:** Instead of allocating memory dynamically for every coroutine, the scheduler maintains an array/pool of fixed-size stack arenas (e.g., **16 KB to 64 KB** each).
- **Recycling:** When a fiber finishes or is aborted, its stack is returned to the free list immediately.
- **Cache Locality:** 1,000 active fibers at 32 KB each consume ~32 MB of virtual memory—completely negligible on modern hardware.

---

# 4. Deep-Dive Design: Solving the Hardest Problems

### Problem 1: How does `race` abort siblings without corrupting memory?
In a stackless system, cancelling a node is trivial (you just stop ticking it). In a **stackful** system, abruptly dropping a fiber while it is in the middle of execution could leak heap memory or leave locks open if not handled properly.

**Proposed Solution: Collaborative Unwinding + Poisoning**
1. **Cancellation Flag:** Every fiber has a `cancellation_requested` status.
2. **Cancellation Points:** Whenever a fiber calls `yield()`, `wait(t)`, `sync()`, or `race()`, the scheduler checks this flag. If cancelled, the scheduler throws a cancellation signal / returns an exit code that unwinds the procedure cleanly via native Odin `defer` statements.
3. **Hard Abort Fallback:** If a parent is forcibly destroyed (e.g., enemy entity dead), child fibers can be immediately recycled back to the pool, while executing any registered explicit destructors.

### Problem 2: How to handle `sync` and `race` ergonomically in Odin?
Instead of creating complex tree-building functions like `seq(sync(loop(...)))`, we can pass standard Odin procedures or closures to `sync` and `race` blocks:

```odin
// Conceptual API Example
boss_behavior :: proc(fiber: ^Fiber, boss: ^Boss) {
    // Phase 1: Race between health threshold and attacks
    fiber_race(fiber, 
        proc(f: ^Fiber, b: ^Boss) {
            wait_until(f, proc(b: ^Boss) -> bool { return b.hp < 400 }, b)
        },
        proc(f: ^Fiber, b: ^Boss) {
            fiber_sync(f,
                proc(f: ^Fiber, b: ^Boss) { boss_patrol(f, b) },
                proc(f: ^Fiber, b: ^Boss) { boss_shoot_loop(f, b) },
            )
        },
        boss,
    )

    // Phase 2: Runs only after Phase 1 finishes (either HP dropped or attack completed)
    boss_enrage_sequence(fiber, boss)
}
```

### Problem 3: Eliminating the `Rc` System Entirely
In your current codebase, you wrote:
```odin
Payload :: struct { game: ^Game_World, id: int }
p := rc_new(Payload{game, id})
defer rc_dec(p)
// manual callback thunking...
```
With stackful coroutines, this entire concept is deleted. You simply write:
```odin
wizard_attack :: proc(f: ^Fiber, game: ^Game_World, enemy_id: int) {
    // Local variables live on this fiber's stack frame!
    enemy := find_enemy(game, enemy_id)
    if enemy == nil do return

    enemy.telegraph_timer = 0.8
    wait_seconds(f, 0.8)

    // Re-verify after wait
    enemy = find_enemy(game, enemy_id)
    if enemy == nil do return

    spawn_fireball(game, enemy.pos)
}
```

---

# 5. Proposed Architecture Overview

```
┌──────────────────────────────────────────────────────────────┐
│                       COROUTINE ENGINE                       │
├──────────────────────────────────────────────────────────────┤
│ 1. Scheduler / Dispatcher                                    │
│    - Ticks root fibers on the main game thread.              │
│    - Manages Time (Game Time vs. Real Time).                 │
│    - Handles Sleeping Queues (Timer min-heaps).              │
│                                                              │
│ 2. Fiber Pool & Stack Manager                                │
│    - Pre-allocated stack memory blocks (16KB–64KB).          │
│    - Free-list recycler.                                     │
│                                                              │
│ 3. Assembly Context Switcher (asm Templates)                 │
│    - asm_context_switch(from_rsp, to_rsp)                    │
│    - asm_fiber_entry_trampoline()                            │
│                                                              │
│ 4. Structured Concurrency Tree                               │
│    - Parent-Child links.                                     │
│    - race() / sync() / branch() coordinators.                │
│    - Scoped Cancellation & Unwind propagation.               │
│                                                              │
│ 5. Diagnostics & Visual Debugger                             │
│    - Tree inspection (Fiber hierarchy, stack usage, status). │
│    - Real-time pause/step/resume.                            │
└──────────────────────────────────────────────────────────────┘
```

---

# 6. Evaluation: What We Gain vs. What We Must Watch Out For

### Major Gains:
1. **10x Developer Productivity:** You write normal Odin code with `for`, `if`, local pointers, and natural indentation instead of building tagged-union syntax trees.
2. **Zero `Rc` Boilerplate:** Local variables live on the fiber stack across yields.
3. **True Structured Concurrency:** `race` and `sync` behave like native control flow constructs.
4. **Performance:** Context switching between fibers in pure ASM takes ~10–20 instructions (sub-20 nanoseconds), easily allowing thousands of concurrent game tasks per frame.

### Key Considerations:
1. **Stack Size & Overflow:** Stacks will be fixed size (e.g., 32KB). Game scripting should avoid allocating large arrays directly on the stack (heap/allocator should be used for big buffers). Guard pages can be added in debug mode to catch overflows.
2. **Platform ABI differences:** The inline `asm` template must handle Windows x64 register calling conventions (`xmm6-xmm15`, shadow stack space) vs. System V (Linux/macOS).
3. **Temp Allocator Management:** Each fiber should either have its own scoped temporary allocator or reset `context.temp_allocator` cleanly on yields.

---

# Next Step

Once you review this analysis, let me know if you would like to proceed to:
1. **The Low-Level ASM Context Switch Specification:** Define the exact register state, trampoline, and stack layout for Windows/Linux x64.
2. **The Scheduler & Fiber Tree Design:** Define the data structures for managing `race`, `sync`, timeouts, and hierarchical cancellation.
3. **The High-Level API Design:** Draft the exact Odin syntax and ergonomics for gameplay programmers.

# Low-Level ASM Context Switch Specification
**Target Architectures:** `windows_amd64` (Microsoft x64 ABI) & `linux_amd64` / `darwin_amd64` (System V AMD64 ABI)  
**Implementation Mechanism:** Odin inline `asm` templates + stack-frame synthesis

---

## 1. Register Preservation Matrix

A cooperative context switch does not preempt arbitrary instructions; it is a **voluntary yield**. Therefore, we only need to preserve the **callee-saved (non-volatile) registers** defined by each ABI. All caller-saved registers are assumed clobbered across yields by the compiler.

| Register Class | Windows x64 (Microsoft ABI) | Linux / macOS (System V ABI) |
| :--- | :--- | :--- |
| **GPRs (Callee-Saved)** | `rbx`, `rbp`, `rdi`, `rsi`, `r12`, `r13`, `r14`, `r15` | `rbx`, `rbp`, `r12`, `r13`, `r14`, `r15` |
| **GPRs (Volatile)** | `rax`, `rcx`, `rdx`, `r8`, `r9`, `r10`, `r11` | `rax`, `rcx`, `rdx`, `rsi`, `rdi`, `r8`, `r9`, `r10`, `r11` |
| **SIMD (Callee-Saved)** | `xmm6` through `xmm15` (lower 128-bits) | **None** (all `xmm0`–`xmm15` are volatile) |
| **Stack Pointer** | `rsp` (16-byte aligned before `call`) | `rsp` (16-byte aligned before `call`) |
| **Shadow Space** | **32 bytes** allocated by caller | **None** (128-byte Red Zone below `rsp` ignored) |

> **Note on Windows `rdi` / `rsi`:** In System V, `rdi` and `rsi` are argument registers (volatile). In Windows x64, `rdi` and `rsi` are **non-volatile** and must be saved.

---

## 2. Stack Memory Layout & Alignment

### A. Alignment Invariants
1. AMD64 requires `%rsp` to be **16-byte aligned** immediately before any `call` instruction.
2. When a procedure is entered (immediately after `call`), `%rsp % 16 == 8` (because the 8-byte return address was pushed).
3. The context switch frame must preserve 16-byte alignment so that SIMD vector operations (`movaps`, SSE/AVX) inside fibers or scheduler routines do not cause hardware alignment faults (`#GP`).

### B. Stack Frame Layouts During Context Switch

```
System V AMD64 Stack Frame                 Windows x64 Stack Frame
┌───────────────────────────────┐ High    ┌───────────────────────────────┐ High
│       ... Older Frames ...    │         │       ... Older Frames ...    │
├───────────────────────────────┤         ├───────────────────────────────┤
│ Return Address (Instruction)  │ +0x38   │ Return Address (Instruction)  │ +0xE8
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved RBP                     │ +0x30   │ Saved RBP                     │ +0xE0
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved RBX                     │ +0x28   │ Saved RBX                     │ +0xD8
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved R12                     │ +0x20   │ Saved RSI                     │ +0xD0
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved R13                     │ +0x18   │ Saved RDI                     │ +0xC8
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved R14                     │ +0x10   │ Saved R12                     │ +0xC0
├───────────────────────────────┤         ├───────────────────────────────┤
│ Saved R15                     │ +0x08   │ Saved R13                     │ +0xB8
├───────────────────────────────┤ ◄── RSP ├───────────────────────────────┤
│ (Active Stack Growth Area)    │ Low     │ Saved R14                     │ +0xB0
└───────────────────────────────┘         ├───────────────────────────────┤
                                          │ Saved R15                     │ +0xA8
                                          ├───────────────────────────────┤
                                          │ Saved XMM6  (16 bytes)        │ +0x98
                                          │ Saved XMM7  (16 bytes)        │ +0x88
                                          │ Saved XMM8  (16 bytes)        │ +0x78
                                          │ Saved XMM9  (16 bytes)        │ +0x68
                                          │ Saved XMM10 (16 bytes)        │ +0x58
                                          │ Saved XMM11 (16 bytes)        │ +0x48
                                          │ Saved XMM12 (16 bytes)        │ +0x38
                                          │ Saved XMM13 (16 bytes)        │ +0x28
                                          │ Saved XMM14 (16 bytes)        │ +0x18
                                          │ Saved XMM15 (16 bytes)        │ +0x08
                                          ├───────────────────────────────┤ ◄── RSP
                                          │ (Active Stack Growth Area)    │ Low
                                          └───────────────────────────────┘
```

---

## 3. The Context Switch (`asm` Templates)

The switch function `fiber_context_switch(from_rsp: ^^rawptr, to_rsp: ^rawptr)` performs an atomic swap:
1. Pushes the current fiber's non-volatile state onto its stack.
2. Stores the resulting `%rsp` into `from_rsp^`.
3. Loads `%rsp` from `to_rsp`.
4. Pops the new fiber's non-volatile state from its stack.
5. Executes `ret` (which pops the return address into `%rip`, resuming the target fiber).

### A. System V (Linux / macOS amd64) Specification

```odin
// System V: Preserves 6 GPRs (48 bytes) + Return Address (8 bytes) = 56 bytes.
// With caller's push RIP, total delta is 64 bytes (maintains 16-byte alignment).
asm_context_switch_sysv :: asm(from_rsp: ^^rawptr, to_rsp: ^rawptr) [
    from_rsp = %rdi,
    to_rsp   = %rsi,
    #clobber flags,
    #clobber memory,
] {
    // 1. Save Callee-Saved Registers
    push %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15

    // 2. Swap Stack Pointers
    mov [%rdi], %rsp
    mov %rsp, %rsi

    // 3. Restore Callee-Saved Registers for target fiber
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp

    // 4. Jump to target fiber's saved RIP
    ret
}
```

### B. Windows x64 (Microsoft ABI) Specification

```odin
// Windows x64: Preserves 8 GPRs (64 bytes) + 10 XMM regs (160 bytes) + Return Address (8 bytes) = 232 bytes.
// To guarantee 16-byte alignment before SIMD saves, stack adjustments are aligned.
asm_context_switch_windows :: asm(from_rsp: ^^rawptr, to_rsp: ^rawptr) [
    from_rsp = %rcx,
    to_rsp   = %rdx,
    #clobber flags,
    #clobber memory,
] {
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
    movdqu [%rsp + 0x20], %xmm13
    movdqu [%rsp + 0x30], %xmm12
    movdqu [%rsp + 0x40], %xmm11
    movdqu [%rsp + 0x50], %xmm10
    movdqu [%rsp + 0x60], %xmm9
    movdqu [%rsp + 0x70], %xmm8
    movdqu [%rsp + 0x80], %xmm7
    movdqu [%rsp + 0x90], %xmm6

    // 3. Swap Stack Pointers
    mov [%rcx], %rsp
    mov %rsp, %rdx

    // 4. Restore Callee-Saved XMM Registers
    movdqu %xmm6,  [%rsp + 0x90]
    movdqu %xmm7,  [%rsp + 0x80]
    movdqu %xmm8,  [%rsp + 0x70]
    movdqu %xmm9,  [%rsp + 0x60]
    movdqu %xmm10, [%rsp + 0x50]
    movdqu %xmm11, [%rsp + 0x40]
    movdqu %xmm12, [%rsp + 0x30]
    movdqu %xmm13, [%rsp + 0x20]
    movdqu %xmm14, [%rsp + 0x10]
    movdqu %xmm15, [%rsp + 0x00]
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

    // 6. Jump to target fiber's saved RIP
    ret
}
```

---

## 4. The Trampoline & Initial Stack Synthesis

When a fiber is initialized, it has not run yet. We synthesize its stack to look **identical** to a fiber suspended in `fiber_context_switch`. When the scheduler first switches to it, the `ret` instruction jumps cleanly into a bootstrap trampoline.

### The Universal Register Passing Trick
To avoid ABI-specific argument shuffling during startup:
1. We initialize the synthetic saved `%r12` slot with the `^Fiber` pointer.
2. In both ABIs, `%r12` is non-volatile.
3. When `fiber_context_switch` pops `%r12` and executes `ret`, the CPU jumps to `fiber_trampoline_entry` with `%r12` guaranteed to point to the fiber instance!

```
                  INITIAL SYNTHETIC STACK (Windows x64 Example)
Top of Stack (stack_base + stack_size)
    │
    ├── [0x00] Alignment padding (to ensure 16-byte boundary)
    ├── [-0x08] Return Address = rawptr(fiber_trampoline_entry)
    ├── [-0x10] Saved RBP      = nil
    ├── [-0x18] Saved RBX      = nil
    ├── [-0x20] Saved RSI      = nil
    ├── [-0x28] Saved RDI      = nil
    ├── [-0x30] Saved R12      = rawptr(fiber_ptr)  <-- Holds ^Fiber instance
    ├── [-0x38] Saved R13      = nil
    ├── [-0x40] Saved R14      = nil
    ├── [-0x48] Saved R15      = nil
    ├── [-0xE8] Saved XMM6..15 = [160 bytes of zeros]
    │
    └── Initial SP (stored in fiber.saved_sp)
```

### The Trampoline Procedure

```odin
// Universal Entry Trampoline
// When entered: %r12 contains ^Fiber
fiber_trampoline_entry :: proc "c" () {
    // 1. Recover Fiber pointer from %r12
    fiber: ^Fiber
    when ODIN_ARCH == .amd64 {
        #no_bounds_check {
            // Retrieve %r12 into fiber variable
            fiber = get_r12_reg()
        }
    }

    // 2. Establish Odin context
    // This restores custom allocators, loggers, and user pointers
    context = fiber.stored_context

    // 3. Execute User Procedure
    if fiber.entry_proc != nil {
        fiber.entry_proc(fiber, fiber.user_data)
    }

    // 4. Mark Fiber as completed
    fiber.status = .Completed

    // 5. Yield back to Scheduler forever (Fiber is now dead, to be recycled)
    fiber_yield_final(fiber)
}

get_r12_reg :: asm() -> (res: ^Fiber) [ res = %r12 ] {
    // No-op: r12 already contains the value, binding assigns it to res
}
```

---

## 5. Odin Runtime Context & Safety Invariants

### A. Context Preservation
Every fiber struct stores a private `runtime.Context`:
```odin
Fiber :: struct {
    saved_sp:       rawptr,
    stack_base:     rawptr,
    stack_size:     uint,
    status:         Fiber_Status,
    stored_context: runtime.Context,
    
    // Concurrency Hierarchy
    parent:         ^Fiber,
    first_child:    ^Fiber,
    next_sibling:   ^Fiber,
    
    // User Entry
    entry_proc:     proc(f: ^Fiber, user_data: rawptr),
    user_data:      rawptr,
}
```
Whenever a fiber yields or resumes, its active `context` (which may have been mutated via `context.allocator = ...`) is kept intact.

### B. Temporary Allocator Isolation
In Odin, `context.temp_allocator` relies on a ring-buffer arena. To prevent two interleaved fibers from corrupting each other's temporary memory:
* **Option 1 (Per-Fiber Temp Arena):** Allocate a lightweight 4KB/8KB temporary arena within the `Fiber` struct itself.
* **Option 2 (Frame-Scoped Reset):** Enforce that `free_all(context.temp_allocator)` is called at the boundary of top-level fiber execution.
* *Recommendation:* Assigning a dedicated `mem.Arena` to `fiber.stored_context.temp_allocator` provides complete memory isolation across fibers.

### C. Windows Thread Information Block (TIB / TEB) Considerations
On Windows x64, the OS stores stack limits in the Thread Environment Block (`GS:[0x08]` StackBase, `GS:[0x10]` StackLimit).
* For pure gameplay scripting and mathematics, modifying the TEB on every switch is unnecessary.
* If a fiber makes deep Win32 OS calls or triggers Windows Structured Exception Handling (SEH), updating `GS:[0x08]` and `GS:[0x10]` in the context switch prevents the OS from misidentifying the fiber stack as a corrupted thread stack.

---

## 6. Execution Flow Diagram

```
[ SCHEDULER THREAD ]                                    [ FIBER STACK ]
   │                                                         │
   │ 1. Picks next fiber from run queue                      │
   │ 2. fiber_context_switch(&sched_sp, fiber.saved_sp)      │
   ├─────────────────── PUSH SCHEDULER STATE ───────────────►│
   │                    SWAP %RSP                            │
   │◄────────────────── POP FIBER STATE ─────────────────────┤
   │                                                         │
   │                                                         │ 3. Resumes execution in fiber proc
   │                                                         │    (e.g., boss_attack_behavior)
   │                                                         │
   │                                                         │ 4. Calls wait_seconds(f, 2.0)
   │                                                         │ 5. fiber_context_switch(&fiber.saved_sp, sched_sp)
   ├─────────────────── PUSH FIBER STATE ───────────────────►│
   │                    SWAP %RSP                            │
   │◄────────────────── POP SCHEDULER STATE ─────────────────┤
   │                                                         │
   │ 6. Scheduler resumes loop; processes next game entity   │
```

---

## Summary of the Low-Level Contract

1. **Cycle Cost:** A full context switch requires only **~15–25 CPU cycles** (push/pop of registers + stack pointer swap), allowing tens of thousands of switches per frame.
2. **Deterministic Layout:** Stacks are aligned to **16 bytes** at all times.
3. **No Garbage Collection / No RC:** Variables declared in a fiber live on that fiber's stack and stay valid across yields without allocation overhead.
4. **Cross-Platform:** The architecture isolates ABI differences into two dedicated inline `asm` templates (`asm_context_switch_sysv` and `asm_context_switch_windows`), while sharing the exact same high-level scheduler.

# Scheduler & Fiber Tree Design Specification
**Focus:** Structured Concurrency, Coordinators (`sync` / `race`), Hierarchical Cancellation, and Deterministic Stack Scheduling.

---

## 1. Core Data Structures & Topology

The system is designed around zero-allocation execution during gameplay: fibers, stack memory, timer nodes, and concurrency coordinators are pooled and linked via **intrusive pointers**.

```
                           [ ENTITY / ROOT FIBER ]
                                      │ (first_child)
                                      ▼
                             [ FIBER: "Phase 1" ] ◄───────┐
                                      │ (first_child)     │ (next_sibling)
                         ┌────────────┴────────────┐      │
                         ▼                         ▼      │
                  [ FIBER: "Patrol" ] ──► [ FIBER: "Shoot" ]
                  (Coordinator: sync)     (Coordinator: sync)
```

### A. Fiber Status Enum
```odin
Fiber_Status :: enum u8 {
    Unused,            // In stack pool / free list
    Ready,             // In ready queue, ready to be dispatched
    Running,           // Currently active on the CPU
    Sleeping_Time,     // Sleeping in timer min-heap (wait_seconds)
    Sleeping_Frames,   // Sleeping in frame-counter queue (wait_frames)
    Waiting_Condition, // Polling a predicate each frame (wait_until)
    Suspended_Join,    // Suspended waiting for children (sync / race)
    Completed,         // Naturally finished execution
    Failed,            // Encountered error / explicitly failed
    Aborted,           // Cancelled by parent or sibling race winner
}
```

### B. The `Fiber` Structure
```odin
Fiber_Handle :: distinct u32

Fiber :: struct {
    // --- Execution Context & Stack ---
    handle:           Fiber_Handle,
    saved_sp:         rawptr,          // Saved stack pointer (%rsp)
    stack_base:       rawptr,          // Lowest memory address of stack
    stack_size:       uint,            // Allocated stack size (e.g. 32KB)
    stored_context:   runtime.Context, // Odin runtime context (allocators, etc.)
    status:           Fiber_Status,
    
    // --- Intrusive Tree Hierarchy (Structured Concurrency) ---
    parent:           ^Fiber,
    first_child:      ^Fiber,
    last_child:       ^Fiber,
    next_sibling:     ^Fiber,
    prev_sibling:     ^Fiber,
    child_count:      int,

    // --- Concurrency & Join Coordination ---
    join_coord:       ^Join_Coordinator, // If this fiber is a branch in a sync/race
    active_coord:     Join_Coordinator,  // Embedded coordinator for when THIS fiber spawns children

    // --- Wait / Wake Triggers ---
    wake_time:        f64,             // Target absolute timestamp for Sleeping_Time
    wake_frame:       u64,             // Target engine frame for Sleeping_Frames
    heap_index:       int,             // Index in Timer Min-Heap (for O(log N) deletion on abort)
    
    // Condition polling
    condition_fn:     proc(user_data: rawptr) -> bool,
    condition_data:   rawptr,

    // --- User Entry & State ---
    entry_proc:       proc(f: ^Fiber, user_data: rawptr),
    user_data:        rawptr,
    cleanup_proc:     proc(user_data: rawptr), // Run on abort/finish if registered

    // --- Diagnostics & Profiling ---
    debug_name:       string,
    start_time:       f64,
    stack_high_water: uint,            // For stack overflow detection
}
```

### C. The `Join_Coordinator` (Powers `sync` and `race`)
A coordinator synchronizes a group of child fibers spawned by a parent. It lives inside the parent's `Fiber` struct (or on the parent's stack), requiring **zero heap allocations**.

```odin
Join_Kind :: enum u8 {
    Sync, // All children must finish; parent resumes when remaining == 0
    Race, // First child to finish wins; immediately aborts all siblings
}

Join_Coordinator :: struct {
    kind:            Join_Kind,
    parent:          ^Fiber,
    total_branches:  int,
    active_branches: int,
    winner:          ^Fiber,      // Set in Race mode
    has_failed:      bool,       // True if any child failed in Sync mode
    completed:       bool,
}
```

---

## 2. Concurrency Coordinators: `sync` vs. `race`

### A. The `sync` Lifecycle (Parallel Join)
1. **Spawn:** Parent initializes its `active_coord` (`kind = .Sync`, `active_branches = N`).
2. **Link:** Parent spawns $N$ child fibers, setting each child's `join_coord = &parent.active_coord`.
3. **Suspend:** Parent suspends with `status = .Suspended_Join` and yields to the scheduler.
4. **Step:** Children execute across subsequent frames.
5. **Child Completion:** As each child finishes, it decrements `active_coord.active_branches`.
   * If a child fails: `has_failed = true`. If strict-fail is enabled, all remaining sibling fibers are aborted immediately.
6. **Resume:** When `active_branches == 0`, the scheduler moves the parent fiber from `.Suspended_Join` back to the **Ready Queue**.

```
[ Parent: fiber_sync(...) ]
       │
       ├── Spawn Child A ──┐
       ├── Spawn Child B ──┼── Both point to Parent's Join_Coordinator
       └── Suspends Parent │
                           ▼
                 Child A finishes (rem = 1)
                 Child B finishes (rem = 0) ──► Parent Wakes Up
```

### B. The `race` Lifecycle (First-to-Finish Preemption)
1. **Spawn:** Parent initializes `active_coord` (`kind = .Race`, `active_branches = N`, `winner = nil`).
2. **Link & Suspend:** Parent spawns $N$ children and suspends with `.Suspended_Join`.
3. **First Arrival Wins:** The first child to finish (or satisfy a condition):
   * Sets `active_coord.winner = current_child`.
   * Sets `active_coord.completed = true`.
   * **Instantly aborts all sibling branches** linked to that coordinator.
   * Moves the parent fiber back to the **Ready Queue**.
4. **Cleanup:** Aborted siblings are immediately removed from scheduler queues (timer heap, condition lists) and their stacks are recycled.

---

## 3. Scheduler Architecture & Queues

```
┌────────────────────────────────────────────────────────────────────────┐
│                               SCHEDULER                                │
├────────────────────────────────────────────────────────────────────────┤
│ 1. Ready Queue        : [ Fiber 1 ] -> [ Fiber 4 ] -> [ Fiber 7 ]      │
│    (O(1) Ring Buffer)                                                  │
│                                                                        │
│ 2. Timer Min-Heap     : Wake Time Sorted (Min element at index 0)       │
│    (wait_seconds)       [ 0.15s: Fiber 2 ]                             │
│                        /                  \                            │
│              [ 0.80s: Fiber 3 ]      [ 1.20s: Fiber 5 ]                │
│                                                                        │
│ 3. Frame Queue        : Array of fibers waiting for specific frames    │
│    (wait_frames)        [ Target: 120, Fiber 6 ]                       │
│                                                                        │
│ 4. Condition Watchlist: Array of fibers with polling predicates        │
│    (wait_until)         [ proc(), Fiber 8 ]                            │
└────────────────────────────────────────────────────────────────────────┘
```

### A. The `Scheduler` & `Scheduler_Clock` Structs
```odin
Time_Clock :: enum u8 {
    Sim_Scaled,  // Scaled by time_scale and halted by is_paused (Default for gameplay)
    Real_Time,   // Always runs at 1.0x real wall-clock speed (UI, menus, network)
    Fixed_Tick,  // Driven by fixed integer discrete ticks (Physics, rollback netcode)
}

Scheduler_Clock :: struct {
    // --- 1. Real / Wall Clock (Unscaled & Unpaused) ---
    real_time:         f64,     // Absolute real-world seconds since start
    real_delta:        f32,     // Real-world frame delta (seconds)
    real_ticks:        u64,     // Real-world millisecond integer timestamp

    // --- 2. Simulation Clock (Scaled & Pausable) ---
    sim_time:          f64,     // Scaled simulation seconds since start
    sim_delta:         f32,     // Scaled delta for this step
    time_scale:        f32,     // Multiplier (1.0 = normal, 0.5 = slow-mo, 2.0 = fast)
    is_paused:         bool,    // Freeze sim_time when true

    // --- 3. Discrete Simulation Ticks (Deterministic Integer Clock) ---
    sim_ticks:         u64,     // Integer simulation ticks (zero drift)
    tick_rate_hz:      u32,     // e.g. 60 Hz physics or 1000 Hz ms clock
    frame_count:       u64,     // Total scheduler steps executed
}

Scheduler :: struct {
    // Queues & Heaps
    ready_queue:       [dynamic]^Fiber,
    timer_heap:        [dynamic]^Fiber, // Min-Heap sorted by wake_time (Simulation Clock)
    real_timer_heap:   [dynamic]^Fiber, // Min-Heap sorted by wake_time (Real/Wall Clock)
    tick_waiters:      [dynamic]^Fiber, // Waiting on discrete integer simulation ticks
    frame_waiters:     [dynamic]^Fiber, // Waiting on frame count
    condition_waiters: [dynamic]^Fiber, // Waiting on boolean predicates
    
    // Stack Allocator & Pool
    fiber_pool:        Fiber_Pool,
    
    // 3-Tier Multi-Domain Engine Clock
    clock:             Scheduler_Clock,

    // Execution Context
    scheduler_sp:      rawptr, // Saved %rsp of the scheduler main thread
    current_fiber:     ^Fiber, // Currently executing fiber
}
```

### B. Multi-Domain Dispatch Loop Pipeline

The scheduler supports **three pluggable engine drivers**:
1. `scheduler_step(sched, dt)`: Standard variable frame delta step.
2. `scheduler_step_ticks(sched, ticks)`: Deterministic integer tick step.
3. `scheduler_single_step(sched, dt)`: Debugger freeze step.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. Advance Clocks:                                                      │
│    • Real Clock: real_time += dt, real_ticks += dt * 1000               │
│    • Sim Clock:  sim_time += sim_dt, sim_ticks += ticks, frames += 1   │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. Wake Real Timers (Real-Timer Min-Heap):                              │
│    While root.wake_time <= real_time -> pop to Ready Queue.             │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. Wake Sim Timers (Sim-Timer Min-Heap):                                │
│    While root.wake_time <= sim_time -> pop to Ready Queue.              │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. Wake Integer Tick Waiters:                                           │
│    For each waiter: if wake_ticks <= sim_ticks -> move to Ready.        │
├─────────────────────────────────────────────────────────────────────────┤
│ 5. Wake Frame Waiters:                                                  │
│    For each waiter: if wake_frame <= frame_count -> move to Ready.      │
├─────────────────────────────────────────────────────────────────────────┤
│ 6. Poll Conditions:                                                     │
│    For each waiter: if condition_fn(user_data) == true -> move to Ready │
├─────────────────────────────────────────────────────────────────────────┤
│ 7. Execute Ready Queue:                                                 │
│    While len(ready_queue) > 0:                                          │
│      f = pop_front(ready_queue)                                         │
│      f.status = .Running                                                │
│      fiber_context_switch(&sched.scheduler_sp, f.saved_sp)              │
│      process_post_execution(f)                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 4. Hierarchical Cancellation & Tree Invariants

### A. The Problem with Uncontrolled Fiber Aborts
If a parent fiber or an entity dies, child fibers might be sleeping in:
1. The **Timer Min-Heap**
2. The **Condition Watchlist**
3. The **Ready Queue**

If we only unlink the parent, orphan child fibers will wake up later and execute against freed memory.

### B. The Cascade Cancellation Protocol (`fiber_abort_tree`)
Cancellation is **recursive, bottom-up, and immediate**:

```odin
// Conceptual flow for aborting a fiber and its entire subtree
fiber_abort_tree :: proc(sched: ^Scheduler, root: ^Fiber) {
    // 1. Recursively abort all children first (Bottom-Up)
    child := root.first_child
    for child != nil {
        next := child.next_sibling
        fiber_abort_tree(sched, child)
        child = next
    }

    // 2. Remove THIS fiber from wherever it is suspended in the scheduler
    switch root.status {
    case .Ready:
        remove_by_swap(sched.ready_queue, root)
    case .Sleeping_Time:
        timer_heap_remove(sched, root.heap_index) // O(log N) using stored index
    case .Sleeping_Frames:
        unordered_remove_fiber(&sched.frame_waiters, root)
    case .Waiting_Condition:
        unordered_remove_fiber(&sched.condition_waiters, root)
    case .Suspended_Join, .Running, .Completed, .Failed, .Aborted, .Unused:
        // No queue removal needed
    }

    // 3. Execute optional cleanup callback (destructor)
    if root.cleanup_proc != nil {
        root.cleanup_proc(root.user_data)
        root.cleanup_proc = nil
    }

    // 4. Update status & reclaim stack memory
    root.status = .Aborted
    fiber_pool_recycle(&sched.fiber_pool, root)
}
```

### C. Fast $O(\log N)$ Timer Removal
Because `Fiber` caches its `heap_index`, when a fiber is aborted in a `race`, it is removed from the timer min-heap instantly in $O(\log N)$ time without scanning the heap array.

---

## 5. Stack Pool & Memory Management

### A. Memory Sizing & Canary Guard
* **Stack Size:** Fixed at **32 KB** per fiber (ideal for game logic, UI sequences, and deep AI trees).
* **Pool Slabs:** Stacks are allocated in contiguous 1MB memory blocks (32 stacks per slab).
* **Canary Protection:** The first 64 bytes of `stack_base` are initialized with a known magic bit pattern (`0xDEAD_BEEF_CAFE_BABE`). During diagnostics or when recycling, this watermark is verified to detect stack overflow.

```
┌─────────────────────────────────────────────────────────────┐ High Address
│ Initial Synthetic Stack Frame (Registers, Trampoline RIP)   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│                    ACTIVE FIBER STACK                       │
│                   (Grows Downward ▼)                        │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ Canary Guard Zone (64 Bytes: 0xDEAD_BEEF_CAFE_BABE)         │
└─────────────────────────────────────────────────────────────┘ Low Address (stack_base)
```

### B. Stack Recycling
When a fiber finishes (`.Completed`, `.Failed`, or `.Aborted`):
1. Its intrusive tree links (`parent`, `child`, `sibling`) are cleared.
2. Its `stored_context.temp_allocator` arena is reset to zero.
3. The `Fiber` struct and its stack are returned to the pool's free list in $O(1)$ time.

---

## Summary of the Design

| Feature | Old AST State-Machine | New Stackful Fiber Engine |
| :--- | :--- | :--- |
| **Control Flow** | Tagged-union graph (`seq`, `select`) | **Native Odin** (`if`, `for`, `switch`, locals) |
| **State Capture** | Manual `Rc(T)` payloads & destructors | **Native Stack Frame** (automatic lifetimes) |
| **`sync` / `race`** | AST evaluation & parent polling | **Zero-alloc Coordinators & Instant Preemption** |
| **Timer Lookups** | Frame-by-frame $O(N)$ linear scans | **$O(1)$ Wake & $O(\log N)$ Min-Heap** |
| **Cancellation** | Prone to orphan state leaks | **Guaranteed Hierarchical Subtree Unwinding** |

# High-Level API Design Specification
**Theme:** Direct imperative scripting, zero-boilerplate state capture, natural control flow (`for`, `if`, `defer`), and native SkookumScript concurrency (`sync`, `race`, `branch`).

---

## 1. The Core Mental Model

In this new architecture, gameplay code is written as **standard Odin procedures**. 
- **No AST tree-building (`seq`, `select`)**
- **No manual reference counting (`Rc_Header`, `rc_new`, `rc_dec`)**
- **No callback thunks**

Local variables live naturally on the fiber's stack and stay valid across yields. When a parent scope or entity dies, the scheduler automatically unwinds and reclaims the fiber hierarchy.

---

## 2. API Reference & Primitives

### A. Lifecycle & Scopes
Every coroutine can belong to a `Fiber_Scope` (e.g., embedded in an `Enemy` or `Player`). If the entity is destroyed, calling `scope_cancel` cancels all its active coroutines instantly.

```odin
// Spawn a detached or scoped root fiber (unified proc group)
spawn_typed :: proc(sched: ^Scheduler, entry: proc(f: ^Fiber, data: ^$T), data: ^T, scope: ^Fiber_Scope = nil, name: string = "") -> Fiber_Handle
spawn_nil   :: proc(sched: ^Scheduler, entry: proc(f: ^Fiber), scope: ^Fiber_Scope = nil, name: string = "") -> Fiber_Handle
spawn       :: proc{spawn_typed, spawn_nil}  // Call spawn(...) for both

// Cancel a specific fiber or an entire entity's scope
fiber_cancel :: proc(sched: ^Scheduler, handle: Fiber_Handle)
scope_cancel :: proc(sched: ^Scheduler, scope: ^Fiber_Scope)
scope_destroy :: proc(sched: ^Scheduler, scope: ^Fiber_Scope)  // sched is required
```

### B. Suspension & Timing Primitives
Suspends the calling fiber and yields execution back to the scheduler.

```odin
// Time-based waits
wait        :: proc(f: ^Fiber, seconds: f32)
wait_ptr    :: proc(f: ^Fiber, seconds_ptr: ^f32)

// Frame-based waits
wait_frames :: proc(f: ^Fiber, frames: int)
yield_frame :: proc(f: ^Fiber) // Equivalent to wait_frames(f, 1)

// Predicate-based wait (unified proc group)
wait_until_typed :: proc(f: ^Fiber, condition: proc(data: ^$T) -> bool, data: ^T)
wait_until_nil   :: proc(f: ^Fiber, condition: proc() -> bool)
wait_until       :: proc{wait_until_typed, wait_until_nil}  // Call wait_until(...) for both

// Smooth interpolation over time (blocks until completed)
tween       :: proc(f: ^Fiber, output: ^f32, start, target: f32, duration: f32, ease: Ease_Proc = nil)
```

---

## 3. Structured Concurrency: `sync`, `race`, and `branch`

### A. Type-Safe `branch()` Helper
`branch` packages an Odin procedure and its parameter into a branch descriptor. Because it is polymorphic, it provides **100% compile-time type safety** with no manual casts.

```odin
// Creates a branch descriptor with strongly-typed payload (unified proc group)
branch_typed :: proc(entry: proc(f: ^Fiber, data: ^$T), data: ^T, name: string = "") -> Branch_Desc
branch_nil   :: proc(entry: proc(f: ^Fiber), name: string = "") -> Branch_Desc
branch       :: proc{branch_typed, branch_nil}  // Call branch(...) for both
```

### B. `sync` (Join All)
Spawns $N$ branches in parallel and suspends the parent fiber. **Resumes only when all branches finish.**

```odin
sync :: proc(f: ^Fiber, branches: ..Branch_Desc)
```

### C. `race` (First to Finish Wins)
Spawns $N$ branches in parallel. **The first branch to finish aborts all competing sibling branches immediately.** Returns the index of the winning branch.

```odin
race :: proc(f: ^Fiber, branches: ..Branch_Desc) -> (winner_index: int)
```

---

## 4. Gameplay Code: Before vs. After

### Example 1: Wizard Ranged Attack (Telegraph $\rightarrow$ Shoot)

#### Old AST Approach:
```odin
// Required: Struct definition, rc_new, rc_dec, weak wrapper, thunking, nested sync/wait/run
Payload :: struct { game: ^Game_World, id: int }
p := rc_new(Payload{game, enemy_id})
defer rc_dec(p)

res := weak(
    seq(
        sync(
            run(proc(p: ^Payload) -> bool {
                if e := find_enemy(p.game, p.id); e != nil do e.telegraph_timer = 0.8
                return true
            }, p),
            wait(0.8),
        ),
        run(proc(p: ^Payload) -> bool {
            e := find_enemy(p.game, p.id)
            if e == nil do return true
            dir := linalg.normalize(p.game.player.pos - e.pos)
            spawn_fireball(p.game, e.pos, dir)
            return true
        }, p),
    ),
    is_alive,
    p,
)
```

#### New Fiber Approach:
```odin
wizard_attack :: proc(f: ^Fiber, ctx: ^Enemy_Ctx) {
    enemy := find_enemy(ctx.game, ctx.enemy_id)
    if enemy == nil do return

    // 1. Show telegraph and wait
    enemy.telegraph_timer = 0.8
    wait(f, 0.8)

    // 2. Shoot (State is preserved on the stack!)
    enemy = find_enemy(ctx.game, ctx.enemy_id)
    if enemy == nil do return

    dir := linalg.normalize(ctx.game.player.pos - enemy.pos)
    spawn_fireball(ctx.game, enemy.pos, dir)
}

// Spawning:
spawn(sched, wizard_attack, &enemy_ctx, scope = &enemy.scope)
```

---

### Example 2: Elite Charge Attack with Semaphore & Guaranteed Cleanup

Using native Odin `defer`, resource cleanup (such as releasing a charge slot or restoring speed) is **guaranteed to run**, even if the fiber is aborted mid-charge by a `race` or entity death.

```odin
elite_charge_behavior :: proc(f: ^Fiber, ctx: ^Enemy_Ctx) {
    // 1. Wait until a charge slot is available (Semaphore)
    wait_until(f, proc(g: ^Game_World) -> bool {
        if g.active_charges < 2 {
            g.active_charges += 1
            return true
        }
        return false
    }, ctx.game)

    // Guaranteed cleanup on return OR unexpected abort/cancellation!
    defer ctx.game.active_charges -= 1

    enemy := find_enemy(ctx.game, ctx.enemy_id)
    if enemy == nil do return

    // 2. Perform Dash
    enemy.speed *= 3.5
    defer {
        if e := find_enemy(ctx.game, ctx.enemy_id); e != nil {
            e.speed /= 3.5
        }
    }

    wait(f, 1.0) // Dash duration
}
```

---

### Example 3: The Complete Multi-Phase Boss AI

This demonstrates SkookumScript-style hierarchical concurrency. It runs simultaneous loops in parallel, switches phases based on health thresholds, and triggers visual cinematics with zero AST nodes.

```odin
boss_ai_timeline :: proc(f: ^Fiber, boss: ^Boss) {
    center_x := WW() / 2

    // ==========================================
    // PHASE 1: Attack and Patrol until HP < 400
    // ==========================================
    race(f,
        // Trigger condition to end Phase 1
        branch(proc(f: ^Fiber, b: ^Boss) {
            wait_until(f, proc(b: ^Boss) -> bool { return b.health < 400 }, b)
        }, boss, "Wait HP < 400"),

        // Active Phase 1 behaviors (both run simultaneously)
        branch(proc(f: ^Fiber, b: ^Boss) {
            sync(f,
                branch(boss_patrol_loop, b, "Patrol Sub-loop"),
                branch(boss_spiral_shoot_loop, b, "Spiral Shoot Sub-loop"),
            )
        }, boss, "Phase 1 Combat"),
    )

    // ==========================================
    // PHASE 2: Shield Charge & Super Explosion
    // ==========================================
    // 1. Center the boss
    tween(f, &boss.pos_x, boss.pos_x, center_x, 1.0, ease_in_out_cubic)

    // 2. Charge shield + shake camera simultaneously
    boss.shield_active = true
    sync(f,
        branch(proc(f: ^Fiber, game: ^Game_World) {
            apply_camera_shake(f, game, 15.0)
        }, boss.game),
        branch(proc(f: ^Fiber, b: ^Boss) {
            tween(f, &b.shield_power, 0.0, 1.0, 0.5)
            tween(f, &b.visual_scale, 1.0, 1.6, 1.5, ease_in_out_elastic)
            wait(f, 0.5)
        }, boss),
    )

    // 3. Discharge radial burst & disable shield
    spawn_radial_bullet_burst(boss, count = 24)
    boss.shield_active = false
    boss.shield_power = 0.0

    // ==========================================
    // PHASE 3: Enraged Rapid Fire Loop
    // ==========================================
    tween(f, &boss.visual_scale, 1.6, 1.3, 0.6, ease_in_out_cubic)
    sync(f,
        branch(boss_rapid_fire_loop, boss, "Rapid Targeted Fire"),
        branch(boss_ring_fire_loop, boss, "Periodic Ring Pulse"),
    )
}

// Subroutines are just standard infinite loops!
boss_patrol_loop :: proc(f: ^Fiber, boss: ^Boss) {
    center_x := WW() / 2
    for {
        tween(f, &boss.pos_x, center_x, center_x + 200.0, 3.0, ease_in_out_cubic)
        wait(f, 0.5)
        tween(f, &boss.pos_x, center_x + 200.0, center_x - 200.0, 6.0, ease_in_out_cubic)
        wait(f, 0.5)
        tween(f, &boss.pos_x, center_x - 200.0, center_x, 3.0, ease_in_out_cubic)
    }
}

boss_spiral_shoot_loop :: proc(f: ^Fiber, boss: ^Boss) {
    for {
        wait(f, 1.5)
        spawn_spiral_projectiles(boss)
    }
}
```

---

## 5. Summary of API Improvements

| Feature | Old AST State-Machine API | New Stackful Fiber API |
| :--- | :--- | :--- |
| **Code Style** | Tree assembly (`seq`, `select`, `loop`) | **Standard imperative Odin** (`for`, `if`, `defer`) |
| **Loops** | `loop(seq(...))` wrapper | `for { ... wait(f, 1.0) }` |
| **State Retention** | Manual heap allocations via `rc_new(Payload)` | **Native local variables on stack** |
| **Cleanup / Destructors** | Custom callback wrappers in `Rc_Header` | **Native Odin `defer` blocks** |
| **`sync` / `race`** | Nested node combinators | `sync(f, branch(...), branch(...))` |
| **Entity Lifetime** | Fragile `weak(..., is_alive)` polling | `scope_cancel(&entity.scope)` |

---

# 6. Modern Architectural Expansions

### A. The 3-Tier Multi-Domain Engine Clock
The engine provides three distinct temporal domains:
1. **Simulation Clock (`sim_time: f64`, `sim_delta: f32`, `time_scale: f32`, `is_paused: bool`)**: Pausable, scaleable clock for AI, combat, and tweens.
2. **Real Clock (`real_time: f64`, `real_delta: f32`, `real_ticks: u64`)**: Unscaled wall-clock time for UI menus, pause screens, and diagnostics (`wait_real`, `spawn_real`).
3. **Discrete Ticks (`sim_ticks: u64`, `tick_rate_hz: u32`, `frame_count: u64`)**: Zero-drift integer clock for deterministic physics and rollback netcode (`wait_ticks`, `scheduler_step_ticks`).

### B. Dual Min-Heap Architecture
- `timer_heap`: $O(\log N)$ min-heap for simulation timers.
- `real_timer_heap`: $O(\log N)$ min-heap for unpaused real-time timers.
- Sleeping fibers store cached heap indices, allowing $O(\log N)$ cancellation without linear scans.

### C. $O(1)$ Ring Buffer Channel & 16KB Generator Memory
- `Channel(T)` utilizes a circular ring buffer (`head`, `tail`, `count`) for $O(1)$ push/pop operations.
- `Generator(T)` allocates lightweight 16KB stacks, reducing per-generator footprint by 64x compared to full 1MB engine slabs.

### D. Inline 128-Byte By-Value Payloads (`spawn_val`)
- Transient parameters are copied into `fiber.payload: [128]u8`, validated via `#assert(size_of(T) <= FIBER_PAYLOAD_SIZE)`.
- Eliminates dangling stack pointers when spawning from transient procedures without dynamic heap allocations.

### E. Phase Director FSM (`Phase_Director`)
- Clean state machine for boss fights and cutscenes. Switching phases via `phase_switch` automatically cancels and cleans up all active coroutines belonging to the previous phase.

### F. Pure Concurrency Primitives (`fiber_join`, `Event(T)`, `Fiber_Semaphore`, `Fiber_Latch`)
- **Dynamic Task Join (`fiber_join(f, handle)`)**: Allows any fiber to await the terminal completion of an independent task handle (returning `true` on `.Completed` and `false` on abort/failure).
- **Typed Multicast Broadcast (`Event(T)`)**: 1-to-many publish-subscribe mechanism that broadcasts typed data across decoupled systems in a single tick without CPU polling.
- **Counting Semaphores (`Fiber_Semaphore`)**: Cooperative Dijkstra semaphore allowing up to $N$ concurrent permits for resource throttling (e.g. limiting simultaneous pathfinding queries or audio voices).
- **Countdown Latches (`Fiber_Latch`)**: Multi-system rendezvous barrier unblocking all waiting fibers once counted down $N$ times.

### G. Loading-Screen Pre-Warming & Diagnostics (`scheduler_prewarm`, `Pool_Stats`)
- **`scheduler_prewarm(sched, count)`**: Pre-allocates slab capacity during loading screens or boot, guaranteeing zero mid-game allocation spikes.
- **`scheduler_pool_stats(sched)` & Introspection**: Provides real-time pool metrics (active fibers, free stacks, memory in KB) and $O(1)$ circular handle history queries (`fiber_is_alive`, `fiber_status`).

### H. Multi-Channel Select & Explicit Cancellation Tokens (`chan_select_recv`, `Cancel_Token`)
- **Multi-Channel Select (`chan_select_recv`, `chan_try_select_recv`)**: Go-style CSP multiplexer that checks an arbitrary slice of typed channels (`[]^Channel(T)`) and suspends the calling fiber until any channel has a message available or is closed.
- **Explicit Cancellation Token (`Cancel_Token`)**: Decoupled, lightweight cancellation handle (`cancel_token_cancel`, `cancel_token_wait`, `cancel_token_is_cancelled`). Multiple unrelated fibers can await cancellation or check state without sharing an intrusive `Fiber_Scope`.

### I. Category User Tags & POSIX Guard Page Parity (`user_tag`, `scheduler_cancel_by_tag`, `mprotect`)
- **Category User Tags (`user_tag: u32`, `scheduler_cancel_by_tag`)**: 4-byte category tag embedded in `Fiber` allowing games to perform mass cancellations across entire subsystems (e.g. aborting all combat AI upon EMP while retaining navigation).
- **POSIX Hardware Guard Page Parity**: Linux and macOS allocate memory slabs via `posix.mmap` and configure the bottom 4KB page with `posix.mprotect(PROT_NONE)`, providing identical hardware MMU crash trapping to Windows `VirtualAlloc` + `PAGE_GUARD`.

### J. Infinite Loop Watchdog & Safety Harness (`docs/guides/GUIDE_FOOTGUNS.md`)
- **Debug Infinite Loop Watchdog**: Scheduler measures wall-clock time of each fiber slice in debug builds (`when ODIN_DEBUG`), panicking immediately with fiber handle and debug name if a fiber runs > 100ms without yielding.
- **Channel Auto-Wake & Timeouts**: `chan_destroy` automatically closes channels before memory deallocation to wake pending senders and receivers with `ok = false`, and `chan_recv_timeout` enables deadline-based message reception without hanging.
- **Footguns Prevention Guide**: Documented in [`docs/guides/GUIDE_FOOTGUNS.md`](docs/guides/GUIDE_FOOTGUNS.md).

### K. Zero-Shift Dispatch & Hardware Cache Physics (`docs/tech/TECH_MEMORY.md`, `docs/guides/GUIDE_PERFORMANCE.md`)
- **Zero-Shift Ready Queue Index Cursor**: Replaces $O(N^2)$ `pop_front` dynamic slice shifting with an $O(N)$ linear index cursor (`for i := 0; i < len(ready_queue); i += 1`), eliminating 50,000,000 memory moves per frame under high load and concluding with an $O(1)$ `clear(&sched.ready_queue)`.
- **In-Place Linear Waiter Partitioning**: Waking `frame_waiters`, `tick_waiters`, and `condition_waiters` uses a single-pass `write_idx` filter that streams through contiguous memory with maximum L1/L2 cache prefetching efficiency.
- **CPU Cache Hierarchy & Memory Wall**: Explains the physical memory latency barrier of 10,000 fibers ($320\text{ MB}$ exceeding L3 cache by $5\times\text{--}10\times$ and incurring ~50–80ns DRAM miss latency) vs. standard game production workloads ($1,000\text{ fibers} = 32\text{ MB}$, fitting 100% inside on-die L3 cache for sub-0.35ms frame step latency).

### L. Centralized Configuration, Packed Generational Handles & Intrusive Futex Queues ([`docs/tech/TECH_SDS_AND_HANDLES.md`](docs/tech/TECH_SDS_AND_HANDLES.md))
- **Centralized Compile-Time Configuration (`config.odin`)**: All engine tunables (stack sizes, slab counts, payload capacities, temporary arenas, canaries, and tick rates) are unified using Odin's `#config` directive, allowing zero-source-modification build overrides via `-define:KEY=VALUE`.
- **Packed Generational Handles ($O(1)$ Direct Slot Resolution)**: `Fiber_Handle` packs `u16 slot_index | u16 generation` into a 32-bit integer, transforming $O(N)$ linear handle searches into instant $O(1)$ direct array index lookups with 100% ABA and use-after-free protection.
- **Intrusive Waiter Queues (OS Kernel / Futex Pattern)**: Synchronization primitives (`Fiber_Mutex`, `Signal`, `Fiber_Semaphore`, `Fiber_Latch`, `Cancel_Token`, `Event(T)`, `Channel(T)`) embed doubly-linked intrusive links inside `Fiber` (`next_waiter`, `prev_waiter`). Delivers 100% zero heap allocations, unbounded waiter capacity, true Zero Is Initialization (ZII), and $O(1)$ in-place node removals (`wait_queue_remove`).
- **Complete Deep-Dive**: Documented in [`docs/tech/TECH_SDS_AND_HANDLES.md`](docs/tech/TECH_SDS_AND_HANDLES.md).
