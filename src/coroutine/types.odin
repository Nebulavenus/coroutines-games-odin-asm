package coroutine

import "base:runtime"
import "core:mem"

// ============================================================================
// Constants
// ============================================================================

DEFAULT_STACK_SIZE :: 32 * 1024 // 32 KB per fiber stack
CANARY_SIZE        :: 64        // 64-byte canary at the base of each stack
CANARY_MAGIC       :: 0xDEAD_BEEF_CAFE_BABE

// ============================================================================
// Enums & Handles
// ============================================================================

Fiber_Status :: enum u8 {
    Unused,            // In stack pool / free list
    Ready,             // In ready queue, ready to be dispatched
    Running,           // Currently active on the CPU
    Sleeping_Time,     // Sleeping in timer min-heap (wait / wait_seconds)
    Sleeping_Frames,   // Sleeping in frame-counter queue (wait_frames)
    Waiting_Condition, // Polling a predicate each frame (wait_until)
    Suspended_Join,    // Suspended waiting for children (sync / race)
    Completed,         // Naturally finished execution
    Failed,            // Encountered error / explicitly failed
    Aborted,           // Cancelled by parent or sibling race winner
}

Fiber_Handle :: distinct u32

Join_Kind :: enum u8 {
    Sync, // All children must finish; parent resumes when remaining == 0
    Race, // First child to finish wins; immediately aborts all siblings
}

// ============================================================================
// Coordinators & Scope
// ============================================================================

Join_Coordinator :: struct {
    kind:            Join_Kind,
    parent:          ^Fiber,
    total_branches:  int,
    active_branches: int,
    winner:          ^Fiber,
    winner_index:    int,
    has_failed:      bool,
    completed:       bool,
}

Fiber_Scope :: struct {
    handles: [dynamic]Fiber_Handle,
}

FIBER_PAYLOAD_SIZE :: 128

Branch_Desc :: struct {
    entry_proc:      proc(f: ^Fiber, user_data: rawptr),
    user_data:       rawptr,
    user_fn:         rawptr,
    payload_storage: [FIBER_PAYLOAD_SIZE]byte,
    has_payload:     bool,
    name:            string,
}

// ============================================================================
// Fiber Structure
// ============================================================================

Fiber :: struct {
    // --- Execution Context & Stack ---
    handle:           Fiber_Handle,
    saved_sp:         rawptr,          // Saved stack pointer (%rsp)
    stack_base:       rawptr,          // Lowest memory address of stack
    stack_size:       uint,            // Allocated stack size (e.g. 32KB)
    stored_context:   runtime.Context, // Odin runtime context (allocators, etc.)
    status:           Fiber_Status,
    scope:            ^Fiber_Scope,
    sched:            ^Scheduler,

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
    branch_index:     int,               // Index in parent's branch array

    // --- Wait / Wake Triggers ---
    wake_time:        f64,               // Target absolute timestamp for Sleeping_Time
    wake_frame:       u64,               // Target engine frame for Sleeping_Frames
    heap_index:       int,               // Index in Timer Min-Heap (for O(log N) deletion on abort)

    // Condition polling
    condition_fn:     proc(user_data: rawptr) -> bool,
    condition_data:   rawptr,

    // --- User Entry & State ---
    entry_proc:       proc(f: ^Fiber, user_data: rawptr),
    user_data:        rawptr,
    user_fn:          rawptr,          // Function pointer for generic/value entry thunks
    payload_storage:  [FIBER_PAYLOAD_SIZE]byte, // Inline buffer for by-value parameters
    cleanup_proc:     proc(user_data: rawptr), // Run on abort/finish if registered

    // --- Isolated Temporary Allocator ---
    temp_arena:        mem.Arena,
    temp_arena_buffer: [4 * 1024]byte, // 4KB private scratchpad per fiber

    // --- Diagnostics & Profiling ---
    debug_name:       string,
    start_time:       f64,
    stack_high_water: uint,
}

// ============================================================================
// Synchronization & Concurrency Primitives
// ============================================================================

Signal :: struct {
    waiters: [dynamic]^Fiber,
}

Fiber_Mutex :: struct {
    locked:  bool,
    waiters: [dynamic]^Fiber,
}

// --- Async Job Bridge ---

Async_State :: enum u8 {
    Pending,
    Completed,
    Failed,
}

Async_Token :: struct {
    state:        Async_State, // Read and stored atomically
    waiter_fiber: ^Fiber,
}

// --- CSP Typed Channels ---

Channel :: struct($T: typeid) {
    buffer:       [dynamic]T,
    capacity:     int,
    send_waiters: [dynamic]^Fiber,
    recv_waiters: [dynamic]^Fiber,
    is_closed:    bool,
    allocator:    mem.Allocator,
}

// --- Stateful Pull Generators ---

Generator :: struct($T: typeid) {
    sched:         Scheduler,
    handle:        Fiber_Handle,
    current_value: T,
    has_value:     bool,
    is_done:       bool,
    entry:         proc(f: ^Fiber, g: ^Generator(T)),
    user_data:     rawptr,
}

// ============================================================================
// Fiber Pool
// ============================================================================

Stack_Allocation_Mode :: enum u8 {
    Standard_Slab,      // Standard mem.alloc (100% portable, works on all platforms)
    Virtual_Memory_OS,  // OS-level pages with hardware PAGE_GUARD (Windows/Linux/macOS)
}

Fiber_Pool_Config :: struct {
    stack_size:      uint,
    stacks_per_slab: int,
    alloc_mode:      Stack_Allocation_Mode,
    allocator:       mem.Allocator,
}

Fiber_Pool :: struct {
    stack_size:      uint,
    stacks_per_slab: int,
    alloc_mode:      Stack_Allocation_Mode,
    slabs:           [dynamic]rawptr,
    free_fibers:     [dynamic]^Fiber,
    all_fibers:      [dynamic]^Fiber,
    next_handle_id:  u32,
}

// ============================================================================
// Scheduler
// ============================================================================

Scheduler :: struct {
    // Queues
    ready_queue:       [dynamic]^Fiber,
    timer_heap:        [dynamic]^Fiber, // Min-Heap sorted by wake_time
    frame_waiters:     [dynamic]^Fiber, // Waiting on frame count
    condition_waiters: [dynamic]^Fiber, // Waiting on boolean predicates

    // Stack Allocator & Pool
    fiber_pool:        Fiber_Pool,

    // Engine Time
    current_time:      f64,
    current_frame:     u64,
    delta_time:        f32,
    time_scale:        f32,
    is_paused:         bool,

    // Execution Context
    scheduler_sp:      rawptr, // Saved %rsp of the scheduler main thread
    current_fiber:     ^Fiber, // Currently executing fiber
}
