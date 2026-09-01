package coroutine

import "base:runtime"

// ============================================================================
// Low-Level ASM Context Switch Implementation (RISC-V 64 / RV64GC)
// ============================================================================

when ODIN_ARCH == .riscv64 {
    // RISC-V 64 Context Switch (LP64D Standard ABI):
    // Preserves:
    // - GPRs: ra (x1), s0 (x8 / fp), s1 (x9), s2-s11 (x18-x27) (13 GPRs * 8 bytes = 104 bytes)
    // - FPRs: fs0-fs1 (f8-f9), fs2-fs11 (f18-f27) (12 FPRs * 8 bytes = 96 bytes)
    // Frame Size: 104 + 96 = 200 bytes -> padded to 208 bytes (16-byte aligned)
    fiber_context_switch :: asm(from_rsp: ^rawptr, to_rsp: rawptr) [
        from_rsp = %a0,
        to_rsp   = %a1,
        #volatile,
        #clobber memory,
        #clobber %t0,
        #clobber %t1,
        #clobber %t2,
        #clobber %t3,
        #clobber %t4,
        #clobber %t5,
        #clobber %t6,
        #clobber %a2,
        #clobber %a3,
        #clobber %a4,
        #clobber %a5,
        #clobber %a6,
        #clobber %a7,
    ] {
        // 0. Trampoline Call: sets Link Register (ra) to point to .switch_done
        #byte 0xEF, 0x00, 0x80, 0x00 // jal ra, +8 (.switch_body)
        #byte 0x6F, 0x00, 0x00, 0x0E // j   .switch_done (+224 bytes = 56 instructions)

        // .switch_body:
        // 1. Allocate 208 bytes stack frame
        #byte 0x13, 0x01, 0x01, 0xF3 // addi sp, sp, -208

        // 2. Save Callee-Saved GPRs (104 bytes)
        #byte 0x23, 0x30, 0x11, 0x00 // sd ra, 0(sp)
        #byte 0x23, 0x34, 0x81, 0x00 // sd s0, 8(sp)
        #byte 0x23, 0x38, 0x91, 0x00 // sd s1, 16(sp)
        #byte 0x23, 0x3C, 0x21, 0x01 // sd s2, 24(sp)
        #byte 0x23, 0x30, 0x31, 0x03 // sd s3, 32(sp)
        #byte 0x23, 0x34, 0x41, 0x03 // sd s4, 40(sp)
        #byte 0x23, 0x38, 0x51, 0x03 // sd s5, 48(sp)
        #byte 0x23, 0x3C, 0x61, 0x03 // sd s6, 56(sp)
        #byte 0x23, 0x30, 0x71, 0x05 // sd s7, 64(sp)
        #byte 0x23, 0x34, 0x81, 0x05 // sd s8, 72(sp)
        #byte 0x23, 0x38, 0x91, 0x05 // sd s9, 80(sp)
        #byte 0x23, 0x3C, 0xA1, 0x05 // sd s10, 88(sp)
        #byte 0x23, 0x30, 0xB1, 0x07 // sd s11, 96(sp)

        // 3. Save Callee-Saved FPRs (96 bytes)
        #byte 0x27, 0x34, 0x81, 0x06 // fsd fs0, 104(sp)
        #byte 0x27, 0x38, 0x91, 0x06 // fsd fs1, 112(sp)
        #byte 0x27, 0x3C, 0x21, 0x07 // fsd fs2, 120(sp)
        #byte 0x27, 0x30, 0x31, 0x09 // fsd fs3, 128(sp)
        #byte 0x27, 0x34, 0x41, 0x09 // fsd fs4, 136(sp)
        #byte 0x27, 0x38, 0x51, 0x09 // fsd fs5, 144(sp)
        #byte 0x27, 0x3C, 0x61, 0x09 // fsd fs6, 152(sp)
        #byte 0x27, 0x30, 0x71, 0x0B // fsd fs7, 160(sp)
        #byte 0x27, 0x34, 0x81, 0x0B // fsd fs8, 168(sp)
        #byte 0x27, 0x38, 0x91, 0x0B // fsd fs9, 176(sp)
        #byte 0x27, 0x3C, 0xA1, 0x0B // fsd fs10, 184(sp)
        #byte 0x27, 0x30, 0xB1, 0x0D // fsd fs11, 192(sp)

        // 4. Swap Stack Pointers (*from_rsp = sp; sp = to_rsp)
        #byte 0x23, 0x30, 0x25, 0x00 // sd sp, 0(a0)
        #byte 0x13, 0x81, 0x05, 0x00 // mv sp, a1 (addi sp, a1, 0)

        // 5. Restore Callee-Saved FPRs
        #byte 0x07, 0x3E, 0x01, 0x0C // fld fs11, 192(sp)
        #byte 0x87, 0x3E, 0x81, 0x0B // fld fs10, 184(sp)
        #byte 0x07, 0x3E, 0x01, 0x0B // fld fs9, 176(sp)
        #byte 0x87, 0x3E, 0x81, 0x0A // fld fs8, 168(sp)
        #byte 0x07, 0x3E, 0x01, 0x0A // fld fs7, 160(sp)
        #byte 0x87, 0x3E, 0x81, 0x09 // fld fs6, 152(sp)
        #byte 0x07, 0x3E, 0x01, 0x09 // fld fs5, 144(sp)
        #byte 0x87, 0x3E, 0x81, 0x08 // fld fs4, 136(sp)
        #byte 0x07, 0x3E, 0x01, 0x08 // fld fs3, 128(sp)
        #byte 0x87, 0x3E, 0x81, 0x07 // fld fs2, 120(sp)
        #byte 0x07, 0x3E, 0x01, 0x07 // fld fs1, 112(sp)
        #byte 0x87, 0x34, 0x81, 0x06 // fld fs0, 104(sp)

        // 6. Restore Callee-Saved GPRs
        #byte 0x83, 0x3D, 0x01, 0x06 // ld s11, 96(sp)
        #byte 0x03, 0x3D, 0x81, 0x05 // ld s10, 88(sp)
        #byte 0x83, 0x3C, 0x01, 0x05 // ld s9, 80(sp)
        #byte 0x03, 0x3C, 0x81, 0x04 // ld s8, 72(sp)
        #byte 0x83, 0x3B, 0x01, 0x04 // ld s7, 64(sp)
        #byte 0x03, 0x3B, 0x81, 0x03 // ld s6, 56(sp)
        #byte 0x83, 0x3A, 0x01, 0x03 // ld s5, 48(sp)
        #byte 0x03, 0x3A, 0x81, 0x02 // ld s4, 40(sp)
        #byte 0x83, 0x39, 0x01, 0x02 // ld s3, 32(sp)
        #byte 0x03, 0x39, 0x81, 0x01 // ld s2, 24(sp)
        #byte 0x83, 0x34, 0x01, 0x01 // ld s1, 16(sp)
        #byte 0x03, 0x34, 0x81, 0x00 // ld s0, 8(sp)
        #byte 0x83, 0x30, 0x01, 0x00 // ld ra, 0(sp)

        // 7. Deallocate stack frame
        #byte 0x13, 0x01, 0x01, 0x0D // addi sp, sp, 208

        // 8. Return to target fiber (jalr zero, 0(ra))
        #byte 0x67, 0x80, 0x00, 0x00 // ret
    }

    // High-Level Inline ASM: Universal Self-Identity Register Extractor (%s2 / x18)
    get_s2_reg :: asm() -> (res: rawptr) [ res = %s2 ] {
        addi res, %s2, 0
    }
}
