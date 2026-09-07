#+build wasm32
package coroutine

when ODIN_ARCH == .wasm32 {

foreign import asyncify "asyncify"

@(default_calling_convention = "c")
foreign asyncify {
    @(link_name = "start_unwind")
    _raw_start_unwind :: proc(buf: rawptr) ---
    @(link_name = "stop_unwind")
    _raw_stop_unwind  :: proc() ---
    @(link_name = "start_rewind")
    _raw_start_rewind :: proc(buf: rawptr) ---
    @(link_name = "stop_rewind")
    _raw_stop_rewind  :: proc() ---
}

// Package-level execution state on WebAssembly
g_wasm_in_fiber:      bool   = false
g_wasm_current_fiber: ^Fiber = nil
g_wasm_is_rewinding:  bool   = false

// Leaf yield function: called by an active fiber to yield execution back to the host/scheduler.
// Because it calls both _raw_start_unwind and _raw_stop_rewind, Binaryen recognizes it
// as top-most runtime (isTopMostRuntime) and does NOT instrument it.
// When unwinding: start_unwind is called, and the stack unwinds back to the scheduler.
// When rewinding: this exact call is reached again, where stop_rewind is called to conclude rewinding.
wasm_yield_leaf :: #force_no_inline proc(buf: ^Asyncify_Buffer) {
    if g_wasm_is_rewinding {
        g_wasm_is_rewinding = false
        _raw_stop_rewind()
        return
    }

    buf.top = u32(uintptr(&buf.storage[0]))
    buf.end = u32(uintptr(&buf.storage[0]) + ASYNCIFY_STORAGE_SIZE)
    _raw_start_unwind(buf)
}

// Uninstrumented scheduler dispatcher:
// Calls _raw_start_rewind and _raw_stop_unwind, making it bottom-most runtime (isBottomMostRuntime).
wasm_dispatch_fiber :: proc(f: ^Fiber) {
    g_wasm_current_fiber = f
    if !f.wasm_started {
        f.wasm_started = true
        fiber_trampoline_entry()
    } else {
        g_wasm_is_rewinding = true
        _raw_start_rewind(&f.asyncify_buf)
        fiber_trampoline_entry()
    }
    _raw_stop_unwind()
}

// Universal context switch procedure on WebAssembly
fiber_context_switch :: proc(from_sp: ^rawptr, to_sp: rawptr) {
    if !g_wasm_in_fiber {
        // Called from Scheduler on the main host thread
        f := (^Fiber)(to_sp)
        if f == nil && g_wasm_current_fiber != nil {
            f = g_wasm_current_fiber
        }
        if f == nil do return

        g_wasm_in_fiber = true
        wasm_dispatch_fiber(f)
        g_wasm_in_fiber = false
    } else {
        // Called from within an active Fiber yielding back to the scheduler
        f := g_wasm_current_fiber
        if f == nil do return

        wasm_yield_leaf(&f.asyncify_buf)
    }
}

get_sp :: proc "contextless" () -> rawptr {
    return nil
}

} // when ODIN_ARCH == .wasm32
