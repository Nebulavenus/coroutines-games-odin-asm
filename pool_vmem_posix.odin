#+build linux, darwin, freebsd
package coroutine

import "core:mem"
import "core:sys/posix"

when ODIN_OS == .Linux || ODIN_OS == .Darwin || ODIN_OS == .FreeBSD {

@(private="package")
pool_vmem_alloc_slab :: proc(slab_size: uint, stack_size: uint, stacks_per_slab: int, alloc: mem.Allocator) -> (slab: rawptr, has_guard: bool) {
    _ = alloc
    slab_addr := posix.mmap(nil, slab_size, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS}, -1, 0)
    if slab_addr == posix.MAP_FAILED {
        panic("Failed to allocate mmap virtual memory slab for fiber pool")
    }
    slab = rawptr(slab_addr)
    for i in 0 ..< stacks_per_slab {
        raw_base := rawptr(uintptr(slab) + uintptr(i * int(stack_size)))
        posix.mprotect(raw_base, 4096, {})
    }
    return slab, true
}

@(private="package")
pool_vmem_free_slab :: proc(slab: rawptr, slab_size: uint, alloc: mem.Allocator) {
    _ = alloc
    posix.munmap(slab, slab_size)
}

}
