#+build !windows
#+build !linux
#+build !darwin
#+build !freebsd
package coroutine

import "core:mem"

when ODIN_OS != .Windows && ODIN_OS != .Linux && ODIN_OS != .Darwin && ODIN_OS != .FreeBSD {

@(private="package")
pool_vmem_alloc_slab :: proc(slab_size: uint, stack_size: uint, stacks_per_slab: int, alloc: mem.Allocator) -> (slab: rawptr, has_guard: bool) {
    _ = stack_size
    _ = stacks_per_slab
    err: mem.Allocator_Error
    slab, err = mem.alloc(int(slab_size), 16, alloc)
    if err != nil || slab == nil {
        panic("Failed to allocate memory slab for fiber pool")
    }
    return slab, false
}

@(private="package")
pool_vmem_free_slab :: proc(slab: rawptr, slab_size: uint, alloc: mem.Allocator) {
    _ = slab_size
    mem.free(slab, alloc)
}

}
