package main

import "core:fmt"
import "core:time"
import "core:os"

import coroutine "../.."
import coro_sync "../../sync"

main :: proc() {
	verbose := false
	for arg in os.args[1:] {
		if arg == "-v" || arg == "--verbose" {
			verbose = true
		}
	}

	fmt.println("================================================================================")
	fmt.println("   MULTI-ISA COMPLETE TEST SUITE EXECUTION IN STANDALONE / QEMU HARNESS         ")
	fmt.println("================================================================================")
	fmt.println()

	t0 := time.now()
	core_passed, core_failed := coroutine.run_all_coroutine_tests(verbose = verbose)
	sync_passed, sync_failed := coro_sync.run_all_sync_tests(verbose = verbose)
	passed := core_passed + sync_passed
	failed := core_failed + sync_failed
	elapsed := time.since(t0)
	elapsed_ms := time.duration_milliseconds(elapsed)

	fmt.println()
	fmt.println("================================================================================")
	fmt.printf("FULL TEST SUITE COMPLETE: %d / %d PASSED (%d core + %d sync, %d FAILED) in %.2f ms\n", passed, passed + failed, core_passed, sync_passed, failed, elapsed_ms)
	fmt.println("================================================================================")

	if failed > 0 {
		os.exit(1)
	}
}
