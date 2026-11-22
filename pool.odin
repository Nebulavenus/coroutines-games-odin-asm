package coroutine

import "core:mem"

// ============================================================================
// Stack & Fiber Pool Implementation
// ============================================================================

@(private="package")
fiber_pool_init :: proc(
    pool: ^Fiber_Pool,
    stack_size: uint = DEFAULT_STACK_SIZE,
    stacks_per_slab: int = STACKS_PER_SLAB,
    alloc_mode: Stack_Allocation_Mode = DEFAULT_ALLOC_MODE,
    allocator := context.allocator,
) {
    if pool.slabs != nil || pool.all_fibers != nil || pool.free_fibers != nil {
        fiber_pool_destroy(pool)
    }
    when ODIN_ARCH == .wasm32 {
        pool.stack_size = max(uint(WASM_SHADOW_STACK_SIZE), 4 * 1024)
    } else {
        pool.stack_size = max(stack_size, 16 * 1024)
    }
    if pool.stack_size % 16 != 0 {
        pool.stack_size = (pool.stack_size + 15) & ~uint(15)
    }
    pool.stacks_per_slab = max(stacks_per_slab, 1)
    pool.alloc_mode = alloc_mode
    pool.allocator = allocator.procedure != nil ? allocator : context.allocator
    pool.slabs = make([dynamic]rawptr, pool.allocator)
    pool.fiber_slabs = make([dynamic][]Fiber, pool.allocator)
    pool.free_fibers = make([dynamic]^Fiber, pool.allocator)
    pool.all_fibers = make([dynamic]^Fiber, pool.allocator)
}

@(private="package")
fiber_pool_init_config :: proc(pool: ^Fiber_Pool, config: Fiber_Pool_Config) {
    allocator := config.allocator
    if allocator.procedure == nil {
        allocator = context.allocator
    }
    fiber_pool_init(
        pool,
        config.stack_size == 0 ? DEFAULT_STACK_SIZE : config.stack_size,
        config.stacks_per_slab == 0 ? STACKS_PER_SLAB : config.stacks_per_slab,
        config.alloc_mode,
        allocator,
    )
}

@(private="package")
fiber_pool_destroy :: proc(pool: ^Fiber_Pool) {
    if pool == nil do return
    alloc := pool.allocator.procedure != nil ? pool.allocator : context.allocator
    for fslab in pool.fiber_slabs {
        delete(fslab, alloc)
    }
    delete(pool.fiber_slabs)
    pool.fiber_slabs = nil
    delete(pool.all_fibers)
    delete(pool.free_fibers)
    pool.all_fibers = nil
    pool.free_fibers = nil

    when ODIN_ARCH == .wasm32 {
        for slab in pool.slabs {
            mem.free(slab, alloc)
        }
    } else {
        if pool.alloc_mode == .Virtual_Memory_OS {
            slab_size := uint(int(pool.stack_size) * pool.stacks_per_slab)
            for slab in pool.slabs {
                pool_vmem_free_slab(slab, slab_size, alloc)
            }
        } else {
            for slab in pool.slabs {
                mem.free(slab, alloc)
            }
        }
    }
    delete(pool.slabs)
    pool.slabs = nil
}

@(private="package")
STACK_WATERMARK :: 0xAA

@(private="package")
fiber_watermark_stack :: proc(fiber: ^Fiber) {
    if fiber.stack_base == nil do return
    start_offset := CANARY_SIZE
    end_offset := int(fiber.stack_size)
    if end_offset > start_offset {
        mem.set(rawptr(uintptr(fiber.stack_base) + uintptr(start_offset)), STACK_WATERMARK, end_offset - start_offset)
    }
}

fiber_calc_asyncify_usage :: proc(fiber: ^Fiber) -> (used_bytes: uint, total_bytes: uint) {
    if fiber == nil do return 0, 0
    when ODIN_ARCH == .wasm32 {
        total_bytes = ASYNCIFY_STORAGE_SIZE
        base := uintptr(&fiber.asyncify_buf.storage[0])
        top := uintptr(fiber.asyncify_buf.top)
        if fiber.wasm_started && top >= base {
            used := uint(top - base)
            used_bytes = min(used, total_bytes)
        }
        return used_bytes, total_bytes
    } else {
        return 0, 0
    }
}

fiber_calc_stack_usage :: proc(fiber: ^Fiber) -> (used_bytes: uint, total_bytes: uint) {
    if fiber == nil || fiber.stack_base == nil do return 0, 0
    total_bytes = fiber.stack_size

    if !fiber_check_canary(fiber) {
        return total_bytes, total_bytes
    }

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

@(private="file")
fiber_pool_grow :: proc(pool: ^Fiber_Pool, allocator := context.allocator) {
    alloc := pool.allocator.procedure != nil ? pool.allocator : (allocator.procedure != nil ? allocator : context.allocator)
    slab_size := uint(int(pool.stack_size) * pool.stacks_per_slab)

    slab: rawptr
    has_guard := false
    when ODIN_ARCH == .wasm32 {
        err: mem.Allocator_Error
        slab, err = mem.alloc(int(slab_size), 16, alloc)
        if err != nil || slab == nil {
            panic("Failed to allocate shadow stack slab for WebAssembly fiber pool")
        }
    } else {
        if pool.alloc_mode == .Virtual_Memory_OS {
            slab, has_guard = pool_vmem_alloc_slab(slab_size, pool.stack_size, pool.stacks_per_slab, alloc)
        } else {
            err: mem.Allocator_Error
            slab, err = mem.alloc(int(slab_size), 16, alloc)
            if err != nil || slab == nil {
                panic("Failed to allocate memory slab for fiber pool")
            }
        }
    }

    append(&pool.slabs, slab)
    fibers := make([]Fiber, pool.stacks_per_slab, alloc)
    append(&pool.fiber_slabs, fibers)

    guard_offset: uint = has_guard ? 4096 : 0
    for i in 0 ..< pool.stacks_per_slab {
        raw_base := rawptr(uintptr(slab) + uintptr(i * int(pool.stack_size)))
        fiber := &fibers[i]
        fiber.stack_base = rawptr(uintptr(raw_base) + uintptr(guard_offset))
        fiber.stack_size = pool.stack_size - guard_offset
        fiber.pool_index = u32(len(pool.all_fibers))
        fiber.generation = 1
        fiber.status = .Unused
        fiber.heap_index = -1
        fiber.step_index = -1
        fiber.async_index = -1
        fiber_watermark_stack(fiber)
        fiber_init_canary(fiber)

        append(&pool.all_fibers, fiber)
        append(&pool.free_fibers, fiber)
    }
}

@(private="package")
fiber_init_canary :: proc(fiber: ^Fiber) {
    if fiber.stack_base == nil do return
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

@(private="package")
fiber_pool_acquire :: proc(pool: ^Fiber_Pool, allocator := context.allocator) -> ^Fiber {
    alloc := pool.allocator.procedure != nil ? pool.allocator : (allocator.procedure != nil ? allocator : context.allocator)
    if len(pool.free_fibers) == 0 {
        fiber_pool_grow(pool, alloc)
    }

    fiber := pop(&pool.free_fibers)
    fiber.handle = fiber_handle_pack(fiber.pool_index, fiber.generation)

    fiber.status = .Ready
    fiber.parent = nil
    fiber.first_child = nil
    fiber.last_child = nil
    fiber.next_sibling = nil
    fiber.prev_sibling = nil
    fiber.child_count = 0
    fiber.join_coord = nil
    fiber.join_coord_id = 0
    fiber.active_coord = {}
    fiber.branch_index = 0
    fiber.clock_id = CLOCK_SIM
    fiber.wake_time = 0
    fiber.wake_step = 0
    fiber.heap_index = -1
    fiber.step_index = -1
    fiber.async_header = nil
    fiber.async_index = -1
    fiber.async_cancel_on_abort = false
    fiber.event_dest = nil
    fiber.ticker_interval = 0
    fiber.ticker_next_wake = 0
    fiber.entry_proc = nil
    fiber.user_data = nil
    fiber.user_fn = nil
    for i in 0 ..< MAX_FIBER_CLEANUPS {
        fiber.cleanups[i] = {}
    }
    fiber.cleanup_count = 0
    fiber.debug_name = ""
    fiber.start_time = 0
    fiber.stack_high_water = 0
    fiber.resume_count = 0
    fiber.scope = nil
    fiber.next_in_scope = nil
    fiber.prev_in_scope = nil
    fiber.next_waiter = nil
    fiber.prev_waiter = nil
    fiber.current_wait_queue = nil
    fiber.join_waiters = {}

    fiber.stored_context = context
    when TEMP_ARENA_SIZE > 0 {
        mem.arena_init(&fiber.temp_arena, fiber.temp_arena_buffer[:])
        fiber.stored_context.temp_allocator = mem.arena_allocator(&fiber.temp_arena)
    }

    fiber_watermark_stack(fiber)
    fiber_init_canary(fiber)
    fiber_synthesize_initial_stack(fiber)

    return fiber
}

@(private="package")
fiber_pool_recycle :: proc(pool: ^Fiber_Pool, fiber: ^Fiber) {
    if fiber.status == .Unused do return

    if !fiber_check_canary(fiber) {
        panic("Stack overflow detected in fiber! Canary corrupted.")
    }

    if fiber.handle != 0 {
        pool.handle_history[fiber_handle_history_slot(fiber.handle)] = Handle_Entry{
            handle = fiber.handle,
            status = fiber.status,
        }
    }

    used, _ := fiber_calc_stack_usage(fiber)
    fiber.stack_high_water = used

    when TEMP_ARENA_SIZE > 0 {
        mem.arena_free_all(&fiber.temp_arena)
    }

    fiber.generation += 1
    if fiber.generation == 0 do fiber.generation = 1 // Avoid 0

    fiber.status = .Unused
    fiber.handle = 0
    fiber.parent = nil
    fiber.first_child = nil
    fiber.last_child = nil
    fiber.next_sibling = nil
    fiber.prev_sibling = nil
    fiber.child_count = 0
    fiber.join_coord = nil
    fiber.join_coord_id = 0
    fiber.active_coord = {}
    fiber.branch_index = 0
    fiber.clock_id = CLOCK_SIM
    fiber.wake_time = 0
    fiber.wake_step = 0
    fiber.heap_index = -1
    fiber.step_index = -1
    fiber.async_header = nil
    fiber.async_index = -1
    fiber.async_cancel_on_abort = false
    fiber.event_dest = nil
    fiber.ticker_interval = 0
    fiber.ticker_next_wake = 0
    fiber.entry_proc = nil
    fiber.user_data = nil
    fiber.user_fn = nil
    for i in 0 ..< MAX_FIBER_CLEANUPS {
        fiber.cleanups[i] = {}
    }
    fiber.cleanup_count = 0
    fiber.scope = nil
    fiber.next_in_scope = nil
    fiber.prev_in_scope = nil
    fiber.next_waiter = nil
    fiber.prev_waiter = nil
    fiber.current_wait_queue = nil
    fiber.join_waiters = {}
    fiber.resume_count = 0

    append(&pool.free_fibers, fiber)
}

@(private="package")
fiber_pool_prewarm :: proc(pool: ^Fiber_Pool, fiber_count: int, allocator := context.allocator) {
    alloc := pool.allocator.procedure != nil ? pool.allocator : (allocator.procedure != nil ? allocator : context.allocator)
    for len(pool.all_fibers) < fiber_count {
        fiber_pool_grow(pool, alloc)
    }
}

@(private="package")
fiber_pool_stats :: proc(pool: ^Fiber_Pool) -> Pool_Stats {
    total := len(pool.all_fibers)
    free_count := len(pool.free_fibers)
    active := total - free_count
    slabs := len(pool.fiber_slabs)
    slab_bytes := uint(pool.stack_size) * uint(pool.stacks_per_slab) * uint(len(pool.slabs))
    fiber_bytes := uint(total) * size_of(Fiber)

    return Pool_Stats{
        total_stacks     = total,
        active_fibers    = active,
        free_fibers      = free_count,
        slabs_count      = slabs,
        stack_size_bytes = pool.stack_size,
        total_memory_kb  = (slab_bytes + fiber_bytes) / 1024,
    }
}

// ============================================================================
// Initial Stack Synthesis
// ============================================================================

@(private="package")
fiber_synthesize_initial_stack :: proc(fiber: ^Fiber) {
    top := uintptr(fiber.stack_base) + uintptr(fiber.stack_size)
    top = top & ~uintptr(15)

    when ODIN_ARCH == .wasm32 {
        fiber.wasm_started = false
        fiber.wasm_shadow_sp = rawptr(top)
        fiber.asyncify_buf.top = u32(uintptr(&fiber.asyncify_buf.storage[0]))
        fiber.asyncify_buf.end = u32(uintptr(&fiber.asyncify_buf.storage[0]) + ASYNCIFY_STORAGE_SIZE)
        fiber.saved_sp = fiber
    } else {

        when ODIN_ARCH == .amd64 {
            when ODIN_OS == .Windows {
                // Windows x64 frame (272B):
                // top - 8:      alignment pad (RSP % 16 == 8 on entry)
                // top - 16:     fiber_trampoline_entry (RET)
                // top - 24..80: RBP, RBX, RSI, RDI, R12 (fiber), R13, R14, R15
                // top - 88..112: TEB pad, DeallocationStack, StackLimit, StackBase (32B)
                // top - 272:    XMM6..XMM15 (160B)
                sp := top - 272
                mem.zero(rawptr(sp), 272)

                teb_words := ([^]rawptr)(rawptr(sp + 160))
                teb_words[0] = rawptr(top)
                teb_words[1] = fiber.stack_base
                teb_words[2] = fiber.stack_base

                sp_words := ([^]rawptr)(rawptr(top - 80))
                sp_words[3] = rawptr(fiber) // R12
                sp_words[8] = rawptr(fiber_trampoline_entry)

                fiber.saved_sp = rawptr(sp)
            } else {
                // System V AMD64 frame (64B):
                // top - 8:  alignment pad
                // top - 16: fiber_trampoline_entry (RET)
                // top - 24..64: RBP, RBX, R12 (fiber), R13, R14, R15
                sp := top - 64
                mem.zero(rawptr(sp), 64)

                sp_words := ([^]rawptr)(rawptr(sp))
                sp_words[3] = rawptr(fiber) // R12
                sp_words[6] = rawptr(fiber_trampoline_entry)

                fiber.saved_sp = rawptr(sp)
            }
        } else when ODIN_ARCH == .arm64 {
            // ARM64 AAPCS64 frame (160B):
            // sp + 0..95:  x29, x30 (LR), x19 (fiber), x20..x28
            // sp + 96..159: d8..d15
            sp := top - 160
            mem.zero(rawptr(sp), 160)

            sp_words := ([^]rawptr)(rawptr(sp))
            sp_words[0] = nil                            // x29 (FP)
            sp_words[1] = rawptr(fiber_trampoline_entry) // x30 (LR)
            sp_words[2] = rawptr(fiber)                  // x19

            fiber.saved_sp = rawptr(sp)
        } else when ODIN_ARCH == .riscv64 {
            // RISC-V 64 LP64D frame (208B):
            // sp + 0..103:  ra, s0, s1, s2 (fiber), s3..s11
            // sp + 104..199: fs0..fs11 (+ 8B pad)
            sp := top - 208
            mem.zero(rawptr(sp), 208)

            sp_words := ([^]rawptr)(rawptr(sp))
            sp_words[0] = rawptr(fiber_trampoline_entry) // ra
            sp_words[1] = nil                            // s0 (fp)
            sp_words[2] = nil                            // s1
            sp_words[3] = rawptr(fiber)                  // s2

            fiber.saved_sp = rawptr(sp)
        }
    }
}

// ============================================================================
// Trampoline Entry
// ============================================================================

@(private="package")
fiber_trampoline_entry :: proc "c" () {
    fiber: ^Fiber
    when ODIN_ARCH == .amd64 {
        #no_bounds_check {
            fiber = (^Fiber)(get_r12_reg())
        }
    } else when ODIN_ARCH == .arm64 {
        #no_bounds_check {
            fiber = (^Fiber)(get_x19_reg())
        }
    } else when ODIN_ARCH == .riscv64 {
        #no_bounds_check {
            fiber = (^Fiber)(get_s2_reg())
        }
    } else when ODIN_ARCH == .wasm32 {
        fiber = g_wasm_current_fiber
    }

    if fiber == nil do return

    context = fiber.stored_context

    if fiber.entry_proc != nil {
        fiber.entry_proc(fiber, fiber.user_data)
    }

    if fiber.status == .Running {
        fiber.status = .Completed
    }

    for i := fiber.cleanup_count - 1; i >= 0; i -= 1 {
        hook := fiber.cleanups[i]
        if hook.proc_ptr != nil {
            hook.proc_ptr(hook.user_data != nil ? hook.user_data : fiber.user_data)
        }
    }
    fiber.cleanup_count = 0

    fiber_on_finish(fiber)
    fiber_yield_final(fiber)
}

@(private="package")
fiber_yield_final :: proc "c" (fiber: ^Fiber) {
    when ODIN_ARCH == .wasm32 {
        return
    } else {
        if fiber.sched != nil {
            fiber_context_switch(&fiber.saved_sp, fiber.sched.scheduler_sp)
        }
    }
}

// ============================================================================
// Intrusive Wait_Queue Operations (Doubly-Linked OS Kernel / Futex Pattern)
// ============================================================================

wait_queue_init :: #force_inline proc "contextless" (q: ^Wait_Queue) {
    if q == nil do return
    q.head = nil
    q.tail = nil
}

wait_queue_destroy :: #force_inline proc "contextless" (q: ^Wait_Queue) {
    if q == nil do return
    wait_queue_clear(q)
}

wait_queue_is_empty :: #force_inline proc "contextless" (q: ^Wait_Queue) -> bool {
    return q == nil || q.head == nil
}

wait_queue_count :: #force_inline proc "contextless" (q: ^Wait_Queue) -> int {
    if q == nil || q.head == nil do return 0
    count := 0
    curr := q.head
    for curr != nil {
        count += 1
        curr = curr.next_waiter
    }
    return count
}

wait_queue_push_back :: proc "contextless" (q: ^Wait_Queue, f: ^Fiber) {
    if q == nil || f == nil do return
    f.next_waiter = nil
    f.prev_waiter = q.tail
    f.current_wait_queue = (^Wait_Queue)(rawptr(q))

    if q.tail != nil {
        q.tail.next_waiter = f
    } else {
        q.head = f
    }
    q.tail = f
}

wait_queue_pop_front :: proc "contextless" (q: ^Wait_Queue) -> (f: ^Fiber, ok: bool) {
    if q == nil || q.head == nil do return nil, false

    f = q.head
    q.head = f.next_waiter
    if q.head != nil {
        q.head.prev_waiter = nil
    } else {
        q.tail = nil
    }

    f.next_waiter = nil
    f.prev_waiter = nil
    f.current_wait_queue = nil
    return f, true
}

wait_queue_remove :: proc "contextless" (q: ^Wait_Queue, f: ^Fiber) -> bool {
    if q == nil || f == nil do return false
    if f.current_wait_queue != q do return false
    if f.prev_waiter == nil && f.next_waiter == nil && q.head != f do return false

    if f.prev_waiter != nil {
        f.prev_waiter.next_waiter = f.next_waiter
    } else if q.head == f {
        q.head = f.next_waiter
    }

    if f.next_waiter != nil {
        f.next_waiter.prev_waiter = f.prev_waiter
    } else if q.tail == f {
        q.tail = f.prev_waiter
    }

    f.next_waiter = nil
    f.prev_waiter = nil
    f.current_wait_queue = nil
    return true
}

wait_queue_clear :: proc "contextless" (q: ^Wait_Queue) {
    if q == nil do return
    curr := q.head
    for curr != nil {
        next := curr.next_waiter
        curr.next_waiter = nil
        curr.prev_waiter = nil
        curr.current_wait_queue = nil
        curr = next
    }
    q.head = nil
    q.tail = nil
}
