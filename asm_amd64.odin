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
            // call .switch_body (offset: 5 bytes forward, over the jmp rel32)
            #byte 0xE8, 0x05, 0x00, 0x00, 0x00
            // jmp .switch_done (offset: 173 bytes forward = 0xAD 0x00 0x00 0x00)
            #byte 0xE9, 0xAD, 0x00, 0x00, 0x00

            // .switch_body:
            // 1. Save Callee-Saved GPRs (12 bytes)
            #byte 0x55                         // push %rbp
            #byte 0x53                         // push %rbx
            #byte 0x56                         // push %rsi
            #byte 0x57                         // push %rdi
            #byte 0x41, 0x54                   // push %r12
            #byte 0x41, 0x55                   // push %r13
            #byte 0x41, 0x56                   // push %r14
            #byte 0x41, 0x57                   // push %r15

            // 2. Save Callee-Saved XMM Registers (160 bytes)
            #byte 0x48, 0x81, 0xEC, 0xA0, 0x00, 0x00, 0x00 // sub %rsp, 160 (7 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x7C, 0x24, 0x00       // movdqu [%rsp + 0x00], %xmm15 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x74, 0x24, 0x10       // movdqu [%rsp + 0x10], %xmm14 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x6C, 0x24, 0x20       // movdqu [%rsp + 0x20], %xmm13 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x64, 0x24, 0x30       // movdqu [%rsp + 0x30], %xmm12 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x5C, 0x24, 0x40       // movdqu [%rsp + 0x40], %xmm11 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x54, 0x24, 0x50       // movdqu [%rsp + 0x50], %xmm10 (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x4C, 0x24, 0x60       // movdqu [%rsp + 0x60], %xmm9  (6 bytes)
            #byte 0x44, 0x0F, 0x7F, 0x44, 0x24, 0x70       // movdqu [%rsp + 0x70], %xmm8  (6 bytes)
            #byte 0x0F, 0x7F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00 // movdqu [%rsp + 0x80], %xmm7 (8 bytes)
            #byte 0x0F, 0x7F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00 // movdqu [%rsp + 0x90], %xmm6 (8 bytes)

            // 3. Swap Stack Pointers (6 bytes)
            #byte 0x48, 0x89, 0x21             // mov [%rcx], %rsp (3 bytes)
            #byte 0x48, 0x89, 0xD4             // mov %rsp, %rdx   (3 bytes)

            // 4. Restore Callee-Saved XMM Registers (64 + 7 = 71 bytes)
            #byte 0x0F, 0x6F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00 // movdqu %xmm6,  [%rsp + 0x90] (8 bytes)
            #byte 0x0F, 0x6F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00 // movdqu %xmm7,  [%rsp + 0x80] (8 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x44, 0x24, 0x70       // movdqu %xmm8,  [%rsp + 0x70] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x4C, 0x24, 0x60       // movdqu %xmm9,  [%rsp + 0x60] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x54, 0x24, 0x50       // movdqu %xmm10, [%rsp + 0x50] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x5C, 0x24, 0x40       // movdqu %xmm11, [%rsp + 0x40] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x64, 0x24, 0x30       // movdqu %xmm12, [%rsp + 0x30] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x6C, 0x24, 0x20       // movdqu %xmm13, [%rsp + 0x20] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x74, 0x24, 0x10       // movdqu %xmm14, [%rsp + 0x10] (6 bytes)
            #byte 0x44, 0x0F, 0x6F, 0x7C, 0x24, 0x00       // movdqu %xmm15, [%rsp + 0x00] (6 bytes)
            #byte 0x48, 0x81, 0xC4, 0xA0, 0x00, 0x00, 0x00 // add %rsp, 160 (7 bytes)

            // 5. Restore Callee-Saved GPRs (12 bytes)
            #byte 0x41, 0x5F                   // pop %r15
            #byte 0x41, 0x5E                   // pop %r14
            #byte 0x41, 0x5D                   // pop %r13
            #byte 0x41, 0x5C                   // pop %r12
            #byte 0x5F                         // pop %rdi
            #byte 0x5E                         // pop %rsi
            #byte 0x5B                         // pop %rbx
            #byte 0x5D                         // pop %rbp

            // 6. Return to target fiber's saved RIP
            #byte 0xC3                         // ret

            // .switch_done:
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
            // call .switch_body (offset: 5 bytes forward, over the jmp rel32)
            #byte 0xE8, 0x05, 0x00, 0x00, 0x00
            // jmp .switch_done (offset: 27 bytes forward = 0x1B 0x00 0x00 0x00)
            #byte 0xE9, 0x1B, 0x00, 0x00, 0x00

            // .switch_body:
            // 1. Save Callee-Saved Registers (10 bytes)
            #byte 0x55                         // push %rbp
            #byte 0x53                         // push %rbx
            #byte 0x41, 0x54                   // push %r12
            #byte 0x41, 0x55                   // push %r13
            #byte 0x41, 0x56                   // push %r14
            #byte 0x41, 0x57                   // push %r15

            // 2. Swap Stack Pointers (6 bytes)
            #byte 0x48, 0x89, 0x27             // mov [%rdi], %rsp
            #byte 0x48, 0x89, 0xF4             // mov %rsp, %rsi

            // 3. Restore Callee-Saved Registers for target fiber (10 bytes)
            #byte 0x41, 0x5F                   // pop %r15
            #byte 0x41, 0x5E                   // pop %r14
            #byte 0x41, 0x5D                   // pop %r13
            #byte 0x41, 0x5C                   // pop %r12
            #byte 0x5B                         // pop %rbx
            #byte 0x5D                         // pop %rbp

            // 4. Jump to target fiber's saved RIP (1 byte)
            #byte 0xC3                         // ret

            // .switch_done:
        }
    }

    get_r12_reg :: asm() -> (res: rawptr) [ res = %r12 ] {
        mov res, %r12
    }

    // Read the active CPU stack pointer using high-level inline assembly effective address arithmetic
    get_rsp :: asm() -> (sp: rawptr) [ #volatile ] {
        lea sp, [%rsp]
    }
}
