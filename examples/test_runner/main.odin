package main

import "core:fmt"
import "core:time"
import "core:os"

import coroutine "../../src/coroutine"

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
	passed, failed := coroutine.run_all_coroutine_tests(verbose = verbose)
	elapsed := time.since(t0)
	elapsed_ms := time.duration_milliseconds(elapsed)

	fmt.println()
	fmt.println("================================================================================")
	fmt.printf("FULL TEST SUITE COMPLETE: %d / %d PASSED (%d FAILED) in %.2f ms\n", passed, passed + failed, failed, elapsed_ms)
	fmt.println("================================================================================")

	if failed > 0 {
		os.exit(1)
	}
}
