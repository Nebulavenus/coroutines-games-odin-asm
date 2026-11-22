package coroutine

// ============================================================================
// Low-Level ASM Context Switch Implementation (AMD64)
// ============================================================================

when ODIN_ARCH == .amd64 {
    when ODIN_OS == .Windows {
        // Windows x64 ABI Context Switch (272B frame):
        // Preserves:
        // - GPRs: RBP, RBX, RSI, RDI, R12, R13, R14, R15 (8 * 8 = 64 bytes)
        // - XMM:  XMM6 through XMM15 (10 * 16 = 160 bytes)
        // - TEB:  StackBase, StackLimit, DeallocationStack (24 bytes + 8 bytes pad = 32 bytes)
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
            // 0. Push resume address (.switch_done) as saved RIP on current fiber's stack
            lea %rax, [.switch_done]
            push %rax

            // 1. Save Callee-Saved GPRs (64 bytes)
            push %rbp
            push %rbx
            push %rsi
            push %rdi
            push %r12
            push %r13
            push %r14
            push %r15

            // 2. Save Callee-Saved XMM Registers (160 bytes) & TEB Stack Bounds (32 bytes)
            sub %rsp, 192
            movdqu [%rsp + 0],   %xmm15
            movdqu [%rsp + 16],  %xmm14
            movdqu [%rsp + 32],  %xmm13
            movdqu [%rsp + 48],  %xmm12
            movdqu [%rsp + 64],  %xmm11
            movdqu [%rsp + 80],  %xmm10
            movdqu [%rsp + 96],  %xmm9
            movdqu [%rsp + 112], %xmm8
            movdqu [%rsp + 128], %xmm7
            movdqu [%rsp + 144], %xmm6

            #byte 0x65, 0x48, 0x8B, 0x04, 0x25, 0x30, 0x00, 0x00, 0x00
            mov %r8,  [%rax + 0x08]
            mov %r9,  [%rax + 0x10]
            mov %r10, [%rax + 0x1478]
            mov [%rsp + 160], %r8
            mov [%rsp + 168], %r9
            mov [%rsp + 176], %r10

            // 3. Swap Stack Pointers (*from_rsp = rsp; rsp = to_rsp)
            mov [from_rsp], %rsp
            xchg %rsp, to_rsp

            mov %r8,  [%rsp + 160]
            mov %r9,  [%rsp + 168]
            mov %r10, [%rsp + 176]
            mov [%rax + 0x08],   %r8
            mov [%rax + 0x10],   %r9
            mov [%rax + 0x1478], %r10

            // 4. Restore Callee-Saved XMM Registers (160 bytes)
            movdqu %xmm6,  [%rsp + 144]
            movdqu %xmm7,  [%rsp + 128]
            movdqu %xmm8,  [%rsp + 112]
            movdqu %xmm9,  [%rsp + 96]
            movdqu %xmm10, [%rsp + 80]
            movdqu %xmm11, [%rsp + 64]
            movdqu %xmm12, [%rsp + 48]
            movdqu %xmm13, [%rsp + 32]
            movdqu %xmm14, [%rsp + 16]
            movdqu %xmm15, [%rsp + 0]
            add %rsp, 192

            // 5. Restore Callee-Saved GPRs (64 bytes)
            pop %r15
            pop %r14
            pop %r13
            pop %r12
            pop %rdi
            pop %rsi
            pop %rbx
            pop %rbp

            // 6. Return to target fiber's saved RIP (jz links CFG block to .switch_done; ZF=0 after add %rsp, 192)
            jz .switch_done
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
            #preserve %rbp,
            #preserve %rbx,
            #align_stack,
            #volatile,
            #clobber %rax,
            #clobber %rcx,
            #clobber %rdx,
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
            #clobber %xmm6,
            #clobber %xmm7,
            #clobber %xmm8,
            #clobber %xmm9,
            #clobber %xmm10,
            #clobber %xmm11,
            #clobber %xmm12,
            #clobber %xmm13,
            #clobber %xmm14,
            #clobber %xmm15,
            #clobber %flags,
            #clobber memory,
        ] {
            // 0. Push resume address (.switch_done) as saved RIP on current fiber's stack
            lea %rax, [.switch_done]
            push %rax

            // 1. Save Callee-Saved Registers (48 bytes)
            push %rbp
            push %rbx
            push %r12
            push %r13
            push %r14
            push %r15

            // 2. Swap Stack Pointers (*from_rsp = rsp; rsp = to_rsp)
            mov [from_rsp], %rsp
            mov %rsp, to_rsp

            // 3. Restore Callee-Saved Registers for target fiber (48 bytes)
            pop %r15
            pop %r14
            pop %r13
            pop %r12
            pop %rbx
            pop %rbp

            // 4. Jump to target fiber's saved RIP (test+jz links CFG block to .switch_done; ZF=0 since rsp != 0)
            test %rsp, %rsp
            jz .switch_done
            ret
        .switch_done:
        }
    }

    get_r12_reg :: asm() -> (res: rawptr) [ res = %r12 ] {
        mov res, %r12
    }

    get_rsp :: asm() -> (sp: rawptr) [
        sp = %rax,
        #volatile,
    ] {
        mov sp, %rsp
    }
}
