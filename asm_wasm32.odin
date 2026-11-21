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

g_wasm_in_fiber:      bool   = false
g_wasm_current_fiber: ^Fiber = nil
g_wasm_is_rewinding:  bool   = false

// Binaryen treats procs calling both start_unwind and stop_rewind as top-most runtime (uninstrumented).
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

// Binaryen treats procs calling both start_rewind and stop_unwind as bottom-most runtime (uninstrumented).
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

fiber_context_switch :: proc(from_sp: ^rawptr, to_sp: rawptr) {
    if !g_wasm_in_fiber {
        f := (^Fiber)(to_sp)
        if f == nil && g_wasm_current_fiber != nil {
            f = g_wasm_current_fiber
        }
        if f == nil do return

        g_wasm_in_fiber = true
        wasm_dispatch_fiber(f)
        g_wasm_in_fiber = false
    } else {
        f := g_wasm_current_fiber
        if f == nil do return

        wasm_yield_leaf(&f.asyncify_buf)
    }
}

get_sp :: proc "contextless" () -> rawptr {
    return nil
}

}
