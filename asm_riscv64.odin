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
        #preserve %ra,
        #preserve %sp,
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
        // 1. Allocate 208-byte stack frame and capture resume address (.switch_done) into ra
        addi %sp, %sp, -208
        lla %ra, .switch_done

        // 2. Save Callee-Saved GPRs (104 bytes)
        sd %ra,  [%sp + 0]
        sd %s0,  [%sp + 8]
        sd %s1,  [%sp + 16]
        sd %s2,  [%sp + 24]
        sd %s3,  [%sp + 32]
        sd %s4,  [%sp + 40]
        sd %s5,  [%sp + 48]
        sd %s6,  [%sp + 56]
        sd %s7,  [%sp + 64]
        sd %s8,  [%sp + 72]
        sd %s9,  [%sp + 80]
        sd %s10, [%sp + 88]
        sd %s11, [%sp + 96]

        // 3. Save Callee-Saved FPRs (96 bytes; check_register types 64-bit regs as integer t_u64)
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
        sd %sp, [from_rsp + 0]
        addi %sp, to_rsp, 0

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
        ld %s11, [%sp + 96]
        ld %s10, [%sp + 88]
        ld %s9,  [%sp + 80]
        ld %s8,  [%sp + 72]
        ld %s7,  [%sp + 64]
        ld %s6,  [%sp + 56]
        ld %s5,  [%sp + 48]
        ld %s4,  [%sp + 40]
        ld %s3,  [%sp + 32]
        ld %s2,  [%sp + 24]
        ld %s1,  [%sp + 16]
        ld %s0,  [%sp + 8]
        ld %ra,  [%sp + 0]

        // 7. Deallocate stack frame and return to target fiber (beq links CFG block to .switch_done; %sp != 0)
        addi %sp, %sp, 208
        beq %sp, %zero, .switch_done
        jalr %zero, %ra, 0
    .switch_done:
    }

    // High-Level Inline ASM: Universal Self-Identity Register Extractor (%s2 / x18)
    get_s2_reg :: asm() -> (res: rawptr) [ res = %s2 ] {
        addi res, %s2, 0
    }

    // Read active CPU stack pointer using high-level inline assembly
    get_sp :: asm() -> (sp: rawptr) [
        sp = %a0,
        #preserve %sp,
    ] {
        addi sp, %sp, 0
    }
}
