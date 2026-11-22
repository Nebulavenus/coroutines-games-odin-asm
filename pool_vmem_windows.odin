#+build windows
package coroutine

import "core:mem"
import win32 "core:sys/windows"

when ODIN_OS == .Windows {

@(private="package")
pool_vmem_alloc_slab :: proc(slab_size: uint, stack_size: uint, stacks_per_slab: int, alloc: mem.Allocator) -> (slab: rawptr, has_guard: bool) {
    _ = alloc
    slab = win32.VirtualAlloc(nil, slab_size, win32.MEM_COMMIT | win32.MEM_RESERVE, win32.PAGE_READWRITE)
    if slab == nil {
        panic("Failed to allocate virtual memory slab for fiber pool")
    }
    for i in 0 ..< stacks_per_slab {
        raw_base := rawptr(uintptr(slab) + uintptr(i * int(stack_size)))
        old_protect: win32.DWORD
        win32.VirtualProtect(raw_base, 4096, win32.PAGE_NOACCESS, &old_protect)
    }
    return slab, true
}

@(private="package")
pool_vmem_free_slab :: proc(slab: rawptr, slab_size: uint, alloc: mem.Allocator) {
    _ = slab_size
    _ = alloc
    win32.VirtualFree(slab, 0, win32.MEM_RELEASE)
}

}
