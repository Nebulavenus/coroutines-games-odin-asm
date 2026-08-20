package coroutine

import "base:runtime"

// ============================================================================
// Low-Level ASM Context Switch Implementation
// ============================================================================

when ODIN_ARCH == .amd64 {
    when ODIN_OS == .Windows {
        // Windows x64 ABI Context Switch:
        // Preserves:
        // - GPRs: RBP, RBX, RSI, RDI, R12, R13, R14, R15 (8 * 8 = 64 bytes)
        // - XMM:  XMM6 through XMM15 (10 * 16 = 160 bytes)
        fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
            from_rsp = %rcx,
            to_rsp   = %rdx,
            #volatile,
            #clobber flags,
            #clobber memory,
            #clobber %rax,
            #clobber %rcx,
            #clobber %rdx,
            #clobber %r8,
            #clobber %r9,
            #clobber %r10,
            #clobber %r11,
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

        .switch_done:
        }
    } else {
        // System V AMD64 ABI Context Switch (Linux / macOS):
        // Preserves:
        // - GPRs: RBP, RBX, R12, R13, R14, R15 (6 * 8 = 48 bytes)
        fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
            from_rsp = %rdi,
            to_rsp   = %rsi,
            #volatile,
            #clobber flags,
            #clobber memory,
            #clobber %rax,
            #clobber %rcx,
            #clobber %rdx,
            #clobber %rsi,
            #clobber %rdi,
            #clobber %r8,
            #clobber %r9,
            #clobber %r10,
            #clobber %r11,
        ] {
            call .switch_body
            jmp .switch_done

        .switch_body:
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

        .switch_done:
        }
    }

    get_r12_reg :: asm() -> (res: rawptr) [ res = %r12 ] {
        mov res, %r12
    }
}
