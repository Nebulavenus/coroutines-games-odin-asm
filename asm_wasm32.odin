#+build wasm32
package coroutine

when ODIN_ARCH == .wasm32 {

foreign import asyncify "asyncify"
foreign import wasm_sp "coro_sp"

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

@(default_calling_convention = "c")
foreign wasm_sp {
    @(link_name = "get_sp")
    _raw_get_sp :: proc() -> u32 ---
    @(link_name = "set_sp")
    _raw_set_sp :: proc(sp: u32) ---
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
    host_sp := _raw_get_sp()
    _raw_set_sp(u32(uintptr(f.wasm_shadow_sp)))
    if !f.wasm_started {
        f.wasm_started = true
        fiber_trampoline_entry()
    } else {
        g_wasm_is_rewinding = true
        _raw_start_rewind(&f.asyncify_buf)
        fiber_trampoline_entry()
    }
    _raw_stop_unwind()
    f.wasm_shadow_sp = rawptr(uintptr(_raw_get_sp()))
    _raw_set_sp(host_sp)
    if f.asyncify_buf.top > f.asyncify_buf.end {
        panic("WebAssembly Asyncify_Buffer overflow! Increase -define:CORO_ASYNCIFY_STORAGE_SIZE.")
    }
    if !fiber_check_canary(f) {
        panic("WebAssembly fiber shadow stack overflow! Increase -define:CORO_WASM_SHADOW_STACK_SIZE.")
    }
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
    return rawptr(uintptr(_raw_get_sp()))
}

}
