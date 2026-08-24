package coroutine

import "base:runtime"
import "core:mem"
import win32 "core:sys/windows"

// ============================================================================
// Stack & Fiber Pool Implementation
// ============================================================================

fiber_pool_init :: proc(
    pool: ^Fiber_Pool,
    stack_size: uint = DEFAULT_STACK_SIZE,
    stacks_per_slab: int = 32,
    alloc_mode: Stack_Allocation_Mode = .Standard_Slab,
    allocator := context.allocator,
) {
    pool.stack_size = max(stack_size, 16 * 1024)
    // Ensure stack_size is aligned to 16 bytes
    if pool.stack_size % 16 != 0 {
        pool.stack_size = (pool.stack_size + 15) & ~uint(15)
    }
    pool.stacks_per_slab = max(stacks_per_slab, 1)
    pool.alloc_mode = alloc_mode
    pool.slabs = make([dynamic]rawptr, allocator)
    pool.free_fibers = make([dynamic]^Fiber, allocator)
    pool.all_fibers = make([dynamic]^Fiber, allocator)
    pool.next_handle_id = 1
}

fiber_pool_init_config :: proc(pool: ^Fiber_Pool, config: Fiber_Pool_Config) {
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    fiber_pool_init(
        pool,
        config.stack_size == 0 ? DEFAULT_STACK_SIZE : config.stack_size,
        config.stacks_per_slab == 0 ? 32 : config.stacks_per_slab,
        config.alloc_mode,
        allocator,
    )
}

fiber_pool_destroy :: proc(pool: ^Fiber_Pool, allocator := context.allocator) {
    for fiber in pool.all_fibers {
        free(fiber, allocator)
    }
    delete(pool.all_fibers)
    delete(pool.free_fibers)

    if pool.alloc_mode == .Virtual_Memory_OS {
        when ODIN_OS == .Windows {
            for slab in pool.slabs {
                win32.VirtualFree(slab, 0, win32.MEM_RELEASE)
            }
        } else {
            for slab in pool.slabs {
                mem.free(slab, allocator)
            }
        }
    } else {
        for slab in pool.slabs {
            mem.free(slab, allocator)
        }
    }
    delete(pool.slabs)
}

STACK_WATERMARK :: 0xAA

fiber_watermark_stack :: proc(fiber: ^Fiber) {
    if fiber.stack_base == nil do return
    bytes := ([^]u8)(fiber.stack_base)
    start_offset := CANARY_SIZE
    end_offset := int(fiber.stack_size)
    if end_offset > start_offset {
        mem.set(rawptr(uintptr(fiber.stack_base) + uintptr(start_offset)), STACK_WATERMARK, end_offset - start_offset)
    }
}

fiber_calc_stack_usage :: proc(fiber: ^Fiber) -> (used_bytes: uint, total_bytes: uint) {
    if fiber == nil || fiber.stack_base == nil do return 0, 0
    total_bytes = fiber.stack_size
    bytes := ([^]u8)(fiber.stack_base)
    start_offset := CANARY_SIZE

    for i in start_offset ..< int(fiber.stack_size) {
        if bytes[i] != STACK_WATERMARK {
            used_bytes = fiber.stack_size - uint(i)
            return used_bytes, total_bytes
        }
    }
    return 0, total_bytes
}

// Allocates a new slab of memory for stacks and fibers
@(private="file")
fiber_pool_grow :: proc(pool: ^Fiber_Pool, allocator := context.allocator) {
    slab_size := int(pool.stack_size) * pool.stacks_per_slab

    if pool.alloc_mode == .Virtual_Memory_OS {
        when ODIN_OS == .Windows {
            slab := win32.VirtualAlloc(nil, uint(slab_size), win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
            if slab == nil {
                panic("Failed to allocate virtual memory slab for fiber pool")
            }
            append(&pool.slabs, slab)

            for i in 0 ..< pool.stacks_per_slab {
                raw_base := rawptr(uintptr(slab) + uintptr(i * int(pool.stack_size)))
                // Protect lowest 4KB page as PAGE_GUARD
                old_protect: win32.DWORD
                win32.VirtualProtect(raw_base, 4096, win32.PAGE_GUARD | win32.PAGE_READWRITE, &old_protect)

                fiber := new(Fiber, allocator)
                fiber.stack_base = rawptr(uintptr(raw_base) + 4096)
                fiber.stack_size = pool.stack_size - 4096
                fiber.status = .Unused
                fiber.heap_index = -1
                fiber_watermark_stack(fiber)
                fiber_init_canary(fiber)

                append(&pool.all_fibers, fiber)
                append(&pool.free_fibers, fiber)
            }
            return
        }
    }

    // Standard slab allocation fallback
    slab, err := mem.alloc(slab_size, 16, allocator)
    if err != nil || slab == nil {
        panic("Failed to allocate memory slab for fiber pool")
    }
    append(&pool.slabs, slab)

    for i in 0 ..< pool.stacks_per_slab {
        stack_base := rawptr(uintptr(slab) + uintptr(i * int(pool.stack_size)))
        fiber := new(Fiber, allocator)
        fiber.stack_base = stack_base
        fiber.stack_size = pool.stack_size
        fiber.status = .Unused
        fiber.heap_index = -1
        fiber_watermark_stack(fiber)
        fiber_init_canary(fiber)

        append(&pool.all_fibers, fiber)
        append(&pool.free_fibers, fiber)
    }
}

fiber_init_canary :: proc(fiber: ^Fiber) {
    canary_ptr := ([^]u64)(fiber.stack_base)
    words := CANARY_SIZE / size_of(u64)
    for i in 0 ..< words {
        canary_ptr[i] = CANARY_MAGIC
    }
}

fiber_check_canary :: proc(fiber: ^Fiber) -> bool {
    if fiber.stack_base == nil do return true
    canary_ptr := ([^]u64)(fiber.stack_base)
    words := CANARY_SIZE / size_of(u64)
    for i in 0 ..< words {
        if canary_ptr[i] != CANARY_MAGIC {
            return false
        }
    }
    return true
}

fiber_pool_acquire :: proc(pool: ^Fiber_Pool, allocator := context.allocator) -> ^Fiber {
    if len(pool.free_fibers) == 0 {
        fiber_pool_grow(pool, allocator)
    }

    fiber := pop(&pool.free_fibers)
    fiber.handle = Fiber_Handle(pool.next_handle_id)
    pool.next_handle_id += 1
    if pool.next_handle_id == 0 do pool.next_handle_id = 1 // Avoid 0

    pool.handle_history[fiber.handle % 256] = Handle_Entry{
        handle = fiber.handle,
        status = .Ready,
    }

    // Reset fields
    fiber.status = .Ready
    fiber.parent = nil
    fiber.first_child = nil
    fiber.last_child = nil
    fiber.next_sibling = nil
    fiber.prev_sibling = nil
    fiber.child_count = 0
    fiber.join_coord = nil
    fiber.active_coord = {}
    fiber.branch_index = 0
    fiber.wake_time = 0
    fiber.wake_frame = 0
    fiber.heap_index = -1
    fiber.condition_fn = nil
    fiber.condition_data = nil
    fiber.entry_proc = nil
    fiber.user_data = nil
    fiber.user_fn = nil
    fiber.cleanup_proc = nil
    fiber.debug_name = ""
    fiber.start_time = 0
    fiber.stack_high_water = 0
    fiber.scope = nil

    // Initialize isolated temporary arena for this fiber
    mem.arena_init(&fiber.temp_arena, fiber.temp_arena_buffer[:])
    fiber.stored_context = context
    fiber.stored_context.temp_allocator = mem.arena_allocator(&fiber.temp_arena)

    // Watermark stack area and initialize canary
    fiber_watermark_stack(fiber)
    fiber_init_canary(fiber)

    // Synthesize initial stack frame
    fiber_synthesize_initial_stack(fiber)

    return fiber
}

fiber_pool_recycle :: proc(pool: ^Fiber_Pool, fiber: ^Fiber) {
    if fiber.status == .Unused do return

    // Verify stack overflow
    if !fiber_check_canary(fiber) {
        panic("Stack overflow detected in fiber! Canary corrupted.")
    }

    // Record high-water stack usage before recycle
    used, _ := fiber_calc_stack_usage(fiber)
    fiber.stack_high_water = used

    // Free isolated temporary arena
    mem.arena_free_all(&fiber.temp_arena)

    fiber.status = .Unused
    fiber.handle = 0
    fiber.parent = nil
    fiber.first_child = nil
    fiber.last_child = nil
    fiber.next_sibling = nil
    fiber.prev_sibling = nil
    fiber.child_count = 0
    fiber.join_coord = nil
    fiber.scope = nil

    append(&pool.free_fibers, fiber)
}

fiber_pool_prewarm :: proc(pool: ^Fiber_Pool, fiber_count: int, allocator := context.allocator) {
    for len(pool.all_fibers) < fiber_count {
        fiber_pool_grow(pool, allocator)
    }
}

fiber_pool_stats :: proc(pool: ^Fiber_Pool) -> Pool_Stats {
    total := len(pool.all_fibers)
    free_count := len(pool.free_fibers)
    active := total - free_count
    slabs := len(pool.slabs)
    slab_bytes := uint(pool.stack_size) * uint(pool.stacks_per_slab) * uint(slabs)

    return Pool_Stats{
        total_stacks     = total,
        active_fibers    = active,
        free_fibers      = free_count,
        slabs_count      = slabs,
        stack_size_bytes = pool.stack_size,
        total_memory_kb  = slab_bytes / 1024,
    }
}

// ============================================================================
// Initial Stack Synthesis
// ============================================================================

fiber_synthesize_initial_stack :: proc(fiber: ^Fiber) {
    top := uintptr(fiber.stack_base) + uintptr(fiber.stack_size)
    // Align top to 16 bytes
    top = top & ~uintptr(15)

    when ODIN_ARCH == .amd64 {
        when ODIN_OS == .Windows {
            // Windows x64 stack frame layout:
            // top - 8:   Dummy slot / alignment pad (so entry has RSP % 16 == 8)
            // top - 16:  fiber_trampoline_entry (return address for RET in fiber_context_switch)
            // top - 24:  Saved RBP = nil
            // top - 32:  Saved RBX = nil
            // top - 40:  Saved RSI = nil
            // top - 48:  Saved RDI = nil
            // top - 56:  Saved R12 = fiber pointer
            // top - 64:  Saved R13 = nil
            // top - 72:  Saved R14 = nil
            // top - 80:  Saved R15 = nil
            // top - 240: 160 bytes for XMM6..XMM15 (all 0)

            sp := top - 240
            mem.zero(rawptr(sp), 240)

            // Fill slots
            sp_words := ([^]rawptr)(rawptr(top - 80))
            // sp_words[0] -> top-80 (R15)
            // sp_words[1] -> top-72 (R14)
            // sp_words[2] -> top-64 (R13)
            // sp_words[3] -> top-56 (R12)
            // sp_words[4] -> top-48 (RDI)
            // sp_words[5] -> top-40 (RSI)
            // sp_words[6] -> top-32 (RBX)
            // sp_words[7] -> top-24 (RBP)
            // sp_words[8] -> top-16 (RET -> trampoline)
            // sp_words[9] -> top-8  (Dummy pad)

            sp_words[3] = rawptr(fiber) // R12
            sp_words[8] = rawptr(fiber_trampoline_entry)

            fiber.saved_sp = rawptr(sp)
        } else {
            // System V AMD64 ABI:
            // top - 8:  Dummy slot / alignment pad
            // top - 16: fiber_trampoline_entry (RET)
            // top - 24: Saved RBP = nil
            // top - 32: Saved RBX = nil
            // top - 40: Saved R12 = fiber pointer
            // top - 48: Saved R13 = nil
            // top - 56: Saved R14 = nil
            // top - 64: Saved R15 = nil

            sp := top - 64
            mem.zero(rawptr(sp), 64)

            sp_words := ([^]rawptr)(rawptr(sp))
            // sp_words[0] -> top-64 (R15)
            // sp_words[1] -> top-56 (R14)
            // sp_words[2] -> top-48 (R13)
            // sp_words[3] -> top-40 (R12)
            // sp_words[4] -> top-32 (RBX)
            // sp_words[5] -> top-24 (RBP)
            // sp_words[6] -> top-16 (RET)
            // sp_words[7] -> top-8  (Dummy)

            sp_words[3] = rawptr(fiber) // R12
            sp_words[6] = rawptr(fiber_trampoline_entry)

            fiber.saved_sp = rawptr(sp)
        }
    }
}

// ============================================================================
// Trampoline Entry
// ============================================================================

fiber_trampoline_entry :: proc "c" () {
    fiber: ^Fiber
    when ODIN_ARCH == .amd64 {
        #no_bounds_check {
            fiber = (^Fiber)(get_r12_reg())
        }
    }

    if fiber == nil do return

    // 1. Establish stored context
    context = fiber.stored_context

    // 2. Run user entry procedure
    if fiber.entry_proc != nil {
        fiber.entry_proc(fiber, fiber.user_data)
    }

    when ODIN_ARCH == .amd64 {
        #no_bounds_check {
            fiber = (^Fiber)(get_r12_reg())
        }
    }

    if fiber == nil do return

    // 3. Mark completed if not already aborted / failed
    if fiber.status == .Running {
        fiber.status = .Completed
    }

    // 4. Notify completion to coordinator & parent
    fiber_on_finish(fiber)

    // 5. Final yield to scheduler
    fiber_yield_final(fiber)
}

fiber_yield_final :: proc "c" (fiber: ^Fiber) {
    if fiber.sched != nil {
        fiber_context_switch(&fiber.saved_sp, fiber.sched.scheduler_sp)
    }
}
