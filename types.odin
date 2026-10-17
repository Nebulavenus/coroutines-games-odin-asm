package coroutine

import "base:runtime"
import "core:mem"

// ============================================================================
// Constants & Configuration Aliases
// ============================================================================

DEFAULT_STACK_SIZE :: STACK_SIZE // Default stack size from config.odin
// CANARY_SIZE and CANARY_MAGIC are defined in config.odin

// ============================================================================
// Enums & Handles
// ============================================================================

Fiber_Status :: enum u8 {
    Unused,            // In pool free list
    Ready,             // In ready queue, ready to be dispatched
    Running,           // Currently active on the CPU
    Sleeping_Time,     // Sleeping in clock domain timer min-heap (wait)
    Sleeping_Steps,    // Sleeping in clock domain step-counter queue (wait_steps / yield)
    Suspended_Join,    // Suspended waiting for children or events (sync / race / rush / event_wait)
    Completed,         // Naturally finished execution
    Failed,            // Encountered error / explicitly failed
    Aborted,           // Cancelled by parent or sibling race winner
}

// 32-bit Packed Generational Handle (16-bit Pool Index | 16-bit Generation Counter)
Fiber_Handle :: distinct u32

fiber_handle_pack :: #force_inline proc "contextless" (index: u16, gen: u16) -> Fiber_Handle {
    return Fiber_Handle(u32(index) | (u32(gen) << 16))
}

fiber_handle_index :: #force_inline proc "contextless" (h: Fiber_Handle) -> u16 {
    return u16(u32(h) & 0xFFFF)
}

fiber_handle_gen :: #force_inline proc "contextless" (h: Fiber_Handle) -> u16 {
    return u16((u32(h) >> 16) & 0xFFFF)
}

// Indexed User-Driven Clock Domains
Clock_ID :: distinct int

CLOCK_INHERIT :: Clock_ID(-1) // Inherit parent fiber's clock_id (Default for branches)
CLOCK_SIM     :: Clock_ID(0)  // Default simulation timeline
CLOCK_REAL    :: Clock_ID(1)  // Unpaused wall-clock timeline (UI, menus, network)
CLOCK_PHYS    :: Clock_ID(2)  // Fixed-timestep physics / discrete tick timeline

Clock_Domain :: struct {
    time:         f64,            // Accumulated seconds on this clock domain
    delta:        f32,            // Last step delta (seconds) on this clock domain
    steps:        u64,            // Total discrete steps/frames advanced on this clock domain
    timer_heap:   [dynamic]^Fiber,// Min-Heap sorted by wake_time
    step_waiters: [dynamic]^Fiber,// Fibers waiting on wake_step
}

Join_Kind :: enum u8 {
    Sync, // All children must finish; parent resumes when remaining == 0
    Race, // First child to succeed wins; immediately aborts all siblings; failures ignored unless all fail
    Rush, // First child to succeed wins; losers continue in background (Verse rush)
}

// ============================================================================
// Internal Fiber & Coordinator Structs
// ============================================================================

Join_Coordinator :: struct {
    id:              u64,             // Monotonic coordinator generation ID
    kind:            Join_Kind,
    parent:          ^Fiber,
    total_branches:  int,
    active_branches: int,
    winner:          ^Fiber,
    winner_index:    int,
    has_failed:      bool,
    completed:       bool,
}

MAX_FIBER_CLEANUPS :: 8

Fiber_Cleanup :: struct {
    proc_ptr:  proc(user_data: rawptr),
    user_data: rawptr,
}

Fiber_Scope :: struct {
    head:  ^Fiber,
    tail:  ^Fiber,
    count: int,
}

FIBER_PAYLOAD_SIZE :: PAYLOAD_SIZE

Branch_Desc :: struct {
    entry_proc:      proc(f: ^Fiber, user_data: rawptr),
    user_data:       rawptr,
    user_fn:         rawptr,
    payload_storage: [FIBER_PAYLOAD_SIZE]byte,
    has_payload:     bool,
    name:            string,
    clock_id:        Clock_ID,
}

// ============================================================================
// Intrusive Wait Queue (Doubly-Linked OS Kernel / Futex Pattern)
// ============================================================================

Wait_Queue :: struct {
    head: ^Fiber,
    tail: ^Fiber,
}

// ============================================================================
// Fiber Structure
// ============================================================================

when ODIN_ARCH == .wasm32 {
    ASYNCIFY_STORAGE_SIZE :: 4096
} else {
    ASYNCIFY_STORAGE_SIZE :: 8
}

Asyncify_Buffer :: struct {
    top:     u32,
    end:     u32,
    storage: [ASYNCIFY_STORAGE_SIZE]byte,
}

Fiber :: struct {
    // --- Execution Context & Stack ---
    handle:           Fiber_Handle,
    pool_index:       u16,             // Direct index in Fiber_Pool.all_fibers
    generation:       u16,             // Incremented upon each recycle / reuse
    saved_sp:         rawptr,          // Saved stack pointer (%rsp)
    stack_base:       rawptr,          // Lowest memory address of stack
    stack_size:       uint,            // Allocated stack size (e.g. 32KB)
    stored_context:   runtime.Context, // Odin runtime context (allocators, etc.)
    status:           Fiber_Status,
    scope:            ^Fiber_Scope,
    sched:            ^Scheduler,

    // --- WebAssembly Asyncify Execution State ---
    wasm_started:     bool,
    asyncify_buf:     Asyncify_Buffer,

    // --- Intrusive Tree Hierarchy (Structured Concurrency) ---
    parent:           ^Fiber,
    first_child:      ^Fiber,
    last_child:       ^Fiber,
    next_sibling:     ^Fiber,
    prev_sibling:     ^Fiber,
    child_count:      int,

    // --- Intrusive Scope Membership (Zero-Allocation Scopes) ---
    next_in_scope:    ^Fiber,
    prev_in_scope:    ^Fiber,

    // --- Intrusive Wait Queue Links (Zero-Allocation Synchronization) ---
    next_waiter:        ^Fiber,
    prev_waiter:        ^Fiber,
    current_wait_queue: ^Wait_Queue,

    // --- Concurrency & Join Coordination ---
    join_coord:       ^Join_Coordinator, // If this fiber is a branch in a sync/race
    join_coord_id:    u64,               // Generation ID of join_coord (prevents stale rush interference)
    active_coord:     Join_Coordinator,  // Embedded coordinator for when THIS fiber spawns children
    branch_index:     int,               // Index in parent's branch array

    // --- Wait / Wake Triggers ---
    clock_id:         Clock_ID,          // Target clock domain (default CLOCK_SIM = 0)
    wake_time:        f64,               // Target absolute timestamp for Sleeping_Time
    wake_step:        u64,               // Target step count for Sleeping_Steps
    heap_index:       int,               // Index in Clock_Domain.timer_heap (for O(log N) deletion on abort)

    // --- Built-in Zero-Drift Ticker (100% Shadow-Stack Safe on WebAssembly) ---
    ticker_interval:  f32,
    ticker_next_wake: f64,

    // --- User Entry & State ---
    entry_proc:       proc(f: ^Fiber, user_data: rawptr),
    user_data:        rawptr,
    user_fn:          rawptr,          // Function pointer for generic/value entry thunks
    payload_storage:  [FIBER_PAYLOAD_SIZE]byte, // Inline buffer for by-value parameters
    cleanups:         [MAX_FIBER_CLEANUPS]Fiber_Cleanup, // LIFO defer callbacks executed on abort/finish
    cleanup_count:    int,

    // --- Isolated Temporary Allocator ---
    temp_arena:        mem.Arena,
    temp_arena_buffer: [TEMP_ARENA_SIZE]byte, // Private scratchpad per fiber

    // --- Diagnostics & Profiling ---
    debug_name:       string,
    start_time:       f64,
    stack_high_water: uint,
}

// ============================================================================
// Synchronization & Concurrency Primitives (Intrusive / 100% Zero-Allocation)
// ============================================================================

Event :: struct($T: typeid) {
    waiters: Wait_Queue,
}

Signal :: Event(struct{})

Sticky_Event :: struct($T: typeid) {
    waiters:   Wait_Queue,
    has_value: bool,
    value:     T,
}

Sticky_Signal :: Sticky_Event(struct{})

// Lightweight Verse-style task(T) container (True ZII, backed by Sticky_Event(T))
Task :: struct($T: typeid) {
    handle: Fiber_Handle,
    result: Sticky_Event(T),
}

// --- Pool Memory Telemetry ---

Pool_Stats :: struct {
    total_stacks:     int,
    active_fibers:    int,
    free_fibers:      int,
    slabs_count:      int,
    stack_size_bytes: uint,
    total_memory_kb:  uint,
}

// --- Async Job Bridge ---

Async_State :: enum u8 {
    Pending,
    Completed,
    Failed,
}

Async_Token :: struct {
    state: Async_State, // Read and stored atomically
}

// ============================================================================
// Fiber Pool
// ============================================================================

Stack_Allocation_Mode :: enum u8 {
    Standard_Slab,      // Standard mem.alloc (100% portable, works on all platforms)
    Virtual_Memory_OS,  // OS-level pages with hardware PAGE_NOACCESS / PROT_NONE (Windows/Linux/macOS)
}

DEFAULT_ALLOC_MODE :: Stack_Allocation_Mode(DEFAULT_ALLOC_MODE_INT)

Fiber_Pool_Config :: struct {
    stack_size:      uint,
    stacks_per_slab: int,
    alloc_mode:      Stack_Allocation_Mode,
    allocator:       mem.Allocator,
}

FIBER_HANDLE_HISTORY_CAPACITY :: HANDLE_HISTORY_CAPACITY

Handle_Entry :: struct {
    handle: Fiber_Handle,
    status: Fiber_Status,
}

Fiber_Pool :: struct {
    stack_size:      uint,
    stacks_per_slab: int,
    alloc_mode:      Stack_Allocation_Mode,
    allocator:       mem.Allocator,
    slabs:           [dynamic]rawptr,
    free_fibers:     [dynamic]^Fiber,
    all_fibers:      [dynamic]^Fiber,
    handle_history:  [FIBER_HANDLE_HISTORY_CAPACITY]Handle_Entry,
}

// ============================================================================
// Scheduler
// ============================================================================

Scheduler :: struct {
    // Allocator Reference
    allocator:             mem.Allocator,

    // Ready Queue & Indexed Clock Domains
    ready_queue:           [dynamic]Fiber_Handle,
    clocks:                [MAX_CLOCKS]Clock_Domain,

    // Stack Allocator & Pool
    fiber_pool:            Fiber_Pool,

    // Execution Context
    scheduler_sp:          rawptr, // Saved %rsp of the scheduler main thread
    current_fiber:         ^Fiber, // Currently executing fiber

    // Concurrency Coordinator Generation Counter
    next_coord_id:         u64,

    // Debug Watchdog Timer (Detects non-yielding infinite loops)
    watchdog_enabled:      bool,
    watchdog_max_slice_ms: f64,
}

// Tree Traversal Visitor Callback
Fiber_Visitor :: #type proc(f: ^Fiber, depth: int, user_data: rawptr)
