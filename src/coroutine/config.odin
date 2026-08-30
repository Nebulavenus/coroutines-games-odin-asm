package coroutine

// ============================================================================
// ENGINE CONFIGURATION & STATIC BOUNDS (PLAN 5)
// ============================================================================
// All tunables can be overridden at compile time using Odin's -define flag:
//   e.g. odin build . -define:CORO_STACK_SIZE=65536 -define:CORO_PAYLOAD_SIZE=256
// ============================================================================

// --- 1. Memory & Stack Sizing ---
// Default stack size per fiber (in bytes). Must be >= 16KB and aligned to 16 bytes.
// Presets: 16KB for 2D/Indie, 32KB for 3D Action RPGs (default), 64KB for complex AI/renderers.
STACK_SIZE :: #config(CORO_STACK_SIZE, 32 * 1024)

// Number of stacks preallocated in each contiguous memory slab.
STACKS_PER_SLAB :: #config(CORO_STACKS_PER_SLAB, 32)

// Inline by-value parameter payload buffer size (in bytes).
// Embeds parameter structs directly into Fiber memory without heap allocation.
PAYLOAD_SIZE :: #config(CORO_PAYLOAD_SIZE, 128)

// Private per-fiber temporary arena buffer size (bound to context.temp_allocator).
TEMP_ARENA_SIZE :: #config(CORO_TEMP_ARENA_SIZE, 4 * 1024)

// --- 2. Safety, Canary & Diagnostics ---
// Size of the canary guard watermark at the base of each stack (in bytes).
CANARY_SIZE :: #config(CORO_CANARY_SIZE, 64)

// Magic 64-bit watermark value used to detect stack overflow corruptions.
CANARY_MAGIC :: #config(CORO_CANARY_MAGIC, 0xDEAD_BEEF_CAFE_BABE)

// Default stack allocation mode: 0 = .Standard_Slab (Heap), 1 = .Virtual_Memory_OS (PAGE_GUARD)
DEFAULT_ALLOC_MODE_INT :: #config(CORO_ALLOC_MODE, 0)

// Default watchdog runaway loop protection (enabled in debug mode by default).
WATCHDOG_ENABLED :: #config(CORO_WATCHDOG_ENABLED, ODIN_DEBUG)

// Maximum continuous execution time allowed for a single fiber tick (in milliseconds).
WATCHDOG_MAX_SLICE_MS :: #config(CORO_WATCHDOG_MAX_SLICE_MS, 100.0)

// --- 3. Clocks & Timers ---
// Discrete simulation tick frequency (Hz). Default: 1000 Hz = 1 integer tick per ms.
DEFAULT_TICK_RATE_HZ :: #config(CORO_TICK_RATE_HZ, 1000)

// --- 4. Static Capacity Bounds ---
// Capacity of the historical generational handle ring buffer for completed fibers.
HANDLE_HISTORY_CAPACITY :: #config(CORO_HANDLE_HISTORY_CAPACITY, 2048)
