package coroutine

import "base:runtime"

// ============================================================================
// Low-Level ASM Context Switch Implementation (ARM64 / AArch64)
// ============================================================================

when ODIN_ARCH == .arm64 {
    // ARM64 Context Switch (AAPCS64 Standard Calling Convention):
    // Preserves:
    // - GPRs: x19 through x28 (10 registers * 8 bytes = 80 bytes)
    // - FP/LR: x29 (Frame Pointer) + x30 (Link Register / Return Address) (16 bytes)
    // - SIMD:  d8 through d15 (8 registers * 8 bytes = 64 bytes)
    // Frame Size: 160 bytes (strictly 16-byte aligned)
    fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
        from_rsp = %x0,
        to_rsp   = %x1,
        #preserve %sp,
        #clobber memory,
        #clobber %x2,
        #clobber %x3,
        #clobber %x4,
        #clobber %x5,
        #clobber %x6,
        #clobber %x7,
        #clobber %x8,
        #clobber %x9,
        #clobber %x10,
        #clobber %x11,
        #clobber %x12,
        #clobber %x13,
        #clobber %x14,
        #clobber %x15,
        #clobber %x16,
        #clobber %x17,
        #clobber %x30,
        #clobber %v0,
        #clobber %v1,
        #clobber %v2,
        #clobber %v3,
        #clobber %v4,
        #clobber %v5,
        #clobber %v6,
        #clobber %v7,
        #clobber %v16,
        #clobber %v17,
        #clobber %v18,
        #clobber %v19,
        #clobber %v20,
        #clobber %v21,
        #clobber %v22,
        #clobber %v23,
        #clobber %v24,
        #clobber %v25,
        #clobber %v26,
        #clobber %v27,
        #clobber %v28,
        #clobber %v29,
        #clobber %v30,
        #clobber %v31,
    ] {
        // 1. Allocate 160-byte stack frame (#byte avoids implicit ~{sp} clobber warning in LLVM AArch64 backend)
        #byte 0xFF, 0x83, 0x02, 0xD1 // sub sp, sp, #160

        // 2. Capture resume address (.switch_done) into Link Register (x30)
        adr %x30, .switch_done

        // 3. Save Callee-Saved GPRs (x29, x30, x19..x28)
        stp %x29, %x30, [%sp]
        stp %x19, %x20, [%sp + 16]
        stp %x21, %x22, [%sp + 32]
        stp %x23, %x24, [%sp + 48]
        stp %x25, %x26, [%sp + 64]
        stp %x27, %x28, [%sp + 80]

        // 4. Save Callee-Saved SIMD/FP Registers (d8..d15; 64-bit d-register views are not in Odin's ARM64 register_strings)
        #byte 0xE8, 0x27, 0x06, 0x6D // stp d8,  d9,  [sp, #96]
        #byte 0xEA, 0x2F, 0x07, 0x6D // stp d10, d11, [sp, #112]
        #byte 0xEC, 0x37, 0x08, 0x6D // stp d12, d13, [sp, #128]
        #byte 0xEE, 0x3F, 0x09, 0x6D // stp d14, d15, [sp, #144]

        // 5. Swap Stack Pointers (*from_rsp = sp; sp = to_rsp)
        mov %x2, %sp
        str %x2, [from_rsp]
        #byte 0x3F, 0x00, 0x00, 0x91 // mov sp, x1

        // 6. Restore Callee-Saved SIMD/FP Registers (d14..d8)
        #byte 0xEE, 0x3F, 0x49, 0x6D // ldp d14, d15, [sp, #144]
        #byte 0xEC, 0x37, 0x48, 0x6D // ldp d12, d13, [sp, #128]
        #byte 0xEA, 0x2F, 0x47, 0x6D // ldp d10, d11, [sp, #112]
        #byte 0xE8, 0x27, 0x46, 0x6D // ldp d8,  d9,  [sp, #96]

        // 7. Restore Callee-Saved GPRs (x27..x19, x29, x30)
        ldp %x27, %x28, [%sp + 80]
        ldp %x25, %x26, [%sp + 64]
        ldp %x23, %x24, [%sp + 48]
        ldp %x21, %x22, [%sp + 32]
        ldp %x19, %x20, [%sp + 16]
        ldp %x29, %x30, [%sp]

        // 8. Deallocate 160-byte stack frame and return to target fiber (cbz links CFG block to .switch_done; %x2 != 0)
        #byte 0xFF, 0x83, 0x02, 0x91 // add sp, sp, #160
        cbz %x2, .switch_done
        ret
    .switch_done:
    }

    // High-Level Inline ASM: Universal Self-Identity Register Extractor (%x19)
    get_x19_reg :: asm() -> (res: rawptr) [ res = %x19 ] {
        mov res, %x19
    }

    // Read active CPU stack pointer using high-level inline assembly
    get_sp :: asm() -> (sp: rawptr) [
        sp = %x0,
        #preserve %sp,
    ] {
        mov sp, %sp
    }
}
