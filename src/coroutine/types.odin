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
    Unused,            // In pool free list
    Ready,             // In ready queue, ready to be dispatched
    Running,           // Currently active on the CPU
    Sleeping_Time,     // Sleeping in timer min-heap (wait / wait_seconds)
    Sleeping_Real_Time,// Sleeping in real-time min-heap (wait_real)
    Sleeping_Ticks,    // Sleeping in integer tick waiter queue (wait_ticks)
    Sleeping_Frames,   // Sleeping in frame-counter queue (wait_frames)
    Waiting_Condition, // Polling a predicate each frame (wait_until)
    Suspended_Join,    // Suspended waiting for children (sync / race / rush / fallback)
    Completed,         // Naturally finished execution
    Failed,            // Encountered error / explicitly failed
    Aborted,           // Cancelled by parent or sibling race winner
}

Fiber_Handle :: distinct u32

Time_Clock :: enum u8 {
    Sim_Scaled,  // Scaled by time_scale and halted by is_paused (Default for gameplay)
    Real_Time,   // Always runs at 1.0x real wall-clock speed (UI, menus, network)
    Fixed_Tick,  // Driven by fixed integer discrete ticks (Physics, replays, netcode)
}

Scheduler_Clock :: struct {
    // --- Real / Wall Clock (Unscaled & Unpaused) ---
    real_time:         f64,     // Absolute real-world seconds since start
    real_delta:        f32,     // Real-world frame delta (seconds)
    real_ticks:        u64,     // Real-world millisecond integer timestamp

    // --- Simulation Clock (Scaled & Pausable) ---
    sim_time:          f64,     // Scaled simulation seconds since start
    sim_delta:         f32,     // Scaled delta for this step
    time_scale:        f32,     // Multiplier (1.0 = normal, 0.5 = slow-mo, 2.0 = fast)
    is_paused:         bool,    // Freeze sim_time when true

    // --- Discrete Simulation Ticks (Deterministic Integer Clock) ---
    sim_ticks:         u64,     // Integer simulation ticks (e.g. 1 tick = 1 ms or 1 fixed tick)
    tick_rate_hz:      u32,     // e.g. 60 Hz, 120 Hz, or 1000 Hz (default: 1000 = 1 tick per ms)
    frame_count:       u64,     // Total scheduler steps executed
}

Join_Kind :: enum u8 {
    Sync,     // All children must finish; parent resumes when remaining == 0
    Race,     // First child to finish wins; immediately aborts all siblings
    Rush,     // First child to SUCCEED wins; aborts siblings; failures ignored unless all fail
    Fallback, // Sequential execution of branches until first success
}

// ============================================================================
// Internal Fiber & Coordinator Structs
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

Phase_Director :: struct {
    sched:         ^Scheduler,
    current_scope: Fiber_Scope,
    current_phase: int,
    phase_name:    string,
}

FIBER_PAYLOAD_SIZE :: 128

Branch_Desc :: struct {
    entry_proc:      proc(f: ^Fiber, user_data: rawptr),
    user_data:       rawptr,
    user_fn:         rawptr,
    payload_storage: [FIBER_PAYLOAD_SIZE]byte,
    has_payload:     bool,
    tag:             u32,
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
    wake_time:        f64,               // Target absolute timestamp for Sleeping_Time / Sleeping_Real_Time
    wake_ticks:       u64,               // Target absolute tick count for Sleeping_Ticks
    wake_frame:       u64,               // Target engine frame for Sleeping_Frames
    wake_clock:       Time_Clock,        // Target clock domain (.Sim_Scaled, .Real_Time, .Fixed_Tick)
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
    user_tag:         u32,             // User-assigned category tag for mass cancellation / filtering

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

// --- 1-to-Many Typed Multicast Event ---

Event :: struct($T: typeid) {
    waiters:   [dynamic]^Fiber,
    allocator: mem.Allocator,
}

// --- Counting Semaphore (Up to N Concurrent Permits) ---

Fiber_Semaphore :: struct {
    permits:     int,
    max_permits: int,
    waiters:     [dynamic]^Fiber,
    allocator:   mem.Allocator,
}

// --- Countdown Latch / Barrier ---

Fiber_Latch :: struct {
    count:     int,
    waiters:   [dynamic]^Fiber,
    allocator: mem.Allocator,
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
    state:        Async_State, // Read and stored atomically
    waiter_fiber: ^Fiber,
}

// --- CSP Typed Channels ---

Channel :: struct($T: typeid) {
    buffer:       []T,              // Fixed circular ring buffer slice
    head:         int,              // Pop/read index
    tail:         int,              // Push/write index
    count:        int,              // Number of active items in ring buffer
    capacity:     int,              // Configured capacity (0 for unbuffered rendezvous)
    send_waiters: [dynamic]^Fiber,  // Fibers blocked on chan_send
    recv_waiters: [dynamic]^Fiber,  // Fibers blocked on chan_recv
    is_closed:    bool,             // Closed state flag
    allocator:    mem.Allocator,    // Backing memory allocator
}

// --- Explicit Cancellation Token ---

Cancel_Token :: struct {
    is_cancelled: bool,
    waiters:      [dynamic]^Fiber,
    allocator:    mem.Allocator,
}

// --- Zero-Drift Periodic Ticker ---

Ticker :: struct {
    interval:  f32,
    next_wake: f64,
    use_real:  bool,
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

FIBER_HANDLE_HISTORY_CAPACITY :: 2048

Handle_Entry :: struct {
    handle: Fiber_Handle,
    status: Fiber_Status,
}

Fiber_Pool :: struct {
    stack_size:      uint,
    stacks_per_slab: int,
    alloc_mode:      Stack_Allocation_Mode,
    slabs:           [dynamic]rawptr,
    free_fibers:     [dynamic]^Fiber,
    all_fibers:      [dynamic]^Fiber,
    next_handle_id:  u32,
    handle_history:  [FIBER_HANDLE_HISTORY_CAPACITY]Handle_Entry,
}

// ============================================================================
// Scheduler
// ============================================================================

Scheduler :: struct {
    // Queues
    ready_queue:       [dynamic]^Fiber,
    timer_heap:        [dynamic]^Fiber, // Min-Heap sorted by wake_time (Simulation Clock)
    real_timer_heap:   [dynamic]^Fiber, // Min-Heap sorted by wake_time (Real/Wall Clock)
    tick_waiters:      [dynamic]^Fiber, // Waiting on integer simulation ticks
    frame_waiters:     [dynamic]^Fiber, // Waiting on frame count
    condition_waiters: [dynamic]^Fiber, // Waiting on boolean predicates

    // Stack Allocator & Pool
    fiber_pool:        Fiber_Pool,

    // 3-Tier Multi-Domain Clock
    clock:             Scheduler_Clock,

    // Execution Context
    scheduler_sp:          rawptr, // Saved %rsp of the scheduler main thread
    current_fiber:         ^Fiber, // Currently executing fiber

    // Debug Watchdog Timer (Detects non-yielding infinite loops)
    watchdog_enabled:      bool,
    watchdog_max_slice_ms: f64,
}

// Tree Traversal Visitor Callback
Fiber_Visitor :: #type proc(f: ^Fiber, depth: int, user_data: rawptr)
