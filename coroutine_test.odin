#+build !js
package coroutine

import "core:testing"
import "core:fmt"
import "core:math/rand"
import "core:math"
import "core:mem"
import x86 "core:rexcode/isa/x86"
import arm64 "core:rexcode/isa/arm64"
import riscv "core:rexcode/isa/riscv"


// ============================================================================
// Test 1: Basic Fiber Execution
// ============================================================================

@(test)
test_basic_spawn_and_run :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ran_typed := false
    spawn(&sched, proc(f: ^Fiber, p: ^bool) {
        p^ = true
    }, &ran_typed)

    testing.expect(t, !ran_typed, "Fiber should not have run before scheduler_step")

    scheduler_step(&sched, 0.016)
    testing.expect(t, ran_typed, "Fiber should have run and finished")
}


// ============================================================================
// Test 2: Local Variables Preserved Across Yields
// ============================================================================

@(test)
test_stack_local_variables_across_yields :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [3]int
    spawn(&sched, proc(f: ^Fiber, res: ^[3]int) {
        local_a := 100
        local_b := 200
        local_c := 300

        res[0] = local_a + 1
        yield_frame(f)

        res[1] = local_b + local_a
        yield_frame(f)

        res[2] = local_a + local_b + local_c
    }, &results)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, results[0], 101)
    testing.expect_value(t, results[1], 0)
    testing.expect_value(t, results[2], 0)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, results[0], 101)
    testing.expect_value(t, results[1], 300)
    testing.expect_value(t, results[2], 0)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, results[0], 101)
    testing.expect_value(t, results[1], 300)
    testing.expect_value(t, results[2], 600)
}


// ============================================================================
// Test 3: Wait Seconds & Timer Min-Heap
// ============================================================================

@(test)
test_wait_seconds_timer_heap :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    step_stage := 0
    spawn(&sched, proc(f: ^Fiber, stage: ^int) {
        stage^ = 1
        wait(f, 0.5)
        stage^ = 2
        wait(f, 1.0)
        stage^ = 3
    }, &step_stage)

    scheduler_step(&sched, 0.016) // t = 0.016
    testing.expect_value(t, step_stage, 1)

    scheduler_step(&sched, 0.400) // t = 0.416 (not yet 0.5)
    testing.expect_value(t, step_stage, 1)

    scheduler_step(&sched, 0.100) // t = 0.516 (wakes up, waits 1.0 until t = 1.516)
    testing.expect_value(t, step_stage, 2)

    scheduler_step(&sched, 0.500) // t = 1.016
    testing.expect_value(t, step_stage, 2)

    scheduler_step(&sched, 0.600) // t = 1.616
    testing.expect_value(t, step_stage, 3)
}


// ============================================================================
// Test 4: Wait Frames
// ============================================================================

@(test)
test_wait_frames :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    counter := 0
    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        c^ += 1
        wait_frames(f, 3)
        c^ += 10
    }, &counter)

    scheduler_step(&sched, 0.016) // frame 1 -> counter = 1, sleeps until frame 4
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016) // frame 2
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016) // frame 3
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016) // frame 4 -> wakes up -> counter = 11
    testing.expect_value(t, counter, 11)
}


// ============================================================================
// Test 6: Structured Concurrency - `sync` (Join All)
// ============================================================================

@(test)
test_structured_sync :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Sync_State :: struct {
        a_done: bool,
        b_done: bool,
        all_done: bool,
        sync_ok: bool,
    }

    state := Sync_State{}

    spawn(&sched, proc(f: ^Fiber, s: ^Sync_State) {
        s.sync_ok = sync(f,
            branch(proc(f: ^Fiber, s: ^Sync_State) {
                wait_frames(f, 2)
                s.a_done = true
            }, s, "Branch A"),
            branch(proc(f: ^Fiber, s: ^Sync_State) {
                wait_frames(f, 4)
                s.b_done = true
            }, s, "Branch B"),
        )

        s.all_done = true
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1: Parent spawns children & suspends
    testing.expect_value(t, state.a_done, false)
    testing.expect_value(t, state.b_done, false)
    testing.expect_value(t, state.all_done, false)

    scheduler_step(&sched, 0.016) // Frame 2
    scheduler_step(&sched, 0.016) // Frame 3: Branch A finishes
    testing.expect_value(t, state.a_done, true)
    testing.expect_value(t, state.b_done, false)
    testing.expect_value(t, state.all_done, false)

    scheduler_step(&sched, 0.016) // Frame 4
    scheduler_step(&sched, 0.016) // Frame 5: Branch B finishes -> Parent wakes
    testing.expect_value(t, state.a_done, true)
    testing.expect_value(t, state.b_done, true)
    testing.expect_value(t, state.all_done, true)
    testing.expect_value(t, state.sync_ok, true)
}


// ============================================================================
// Test 7: Structured Concurrency - `race` (First to Finish Wins)
// ============================================================================

@(test)
test_structured_race :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Race_State :: struct {
        slow_completed: bool,
        fast_completed: bool,
        winner_idx: int,
    }

    state := Race_State{winner_idx = -1}

    spawn(&sched, proc(f: ^Fiber, s: ^Race_State) {
        w := race(f,
            branch(proc(f: ^Fiber, s: ^Race_State) {
                wait_frames(f, 5)
                s.slow_completed = true
            }, s, "Slow Branch"),
            branch(proc(f: ^Fiber, s: ^Race_State) {
                wait_frames(f, 2)
                s.fast_completed = true
            }, s, "Fast Branch"),
        )
        s.winner_idx = w
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1: Spawn branches
    testing.expect_value(t, state.winner_idx, -1)

    scheduler_step(&sched, 0.016) // Frame 2
    scheduler_step(&sched, 0.016) // Frame 3: Fast Branch (index 1) completes!
    testing.expect_value(t, state.fast_completed, true)
    testing.expect_value(t, state.slow_completed, false)
    testing.expect_value(t, state.winner_idx, 1)

    // Run more frames to verify Slow Branch was aborted and NEVER runs
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, state.slow_completed, false)
}


// ============================================================================
// Test 8: Scope Cancellation
// ============================================================================

@(test)
test_scope_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    progress := 0

    spawn(&sched, proc(f: ^Fiber, p: ^int) {
        for {
            p^ += 1
            yield_frame(f)
        }
    }, &progress, &scope)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 1)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 2)

    // Cancel the entire scope (e.g. entity died)
    scope_cancel(&sched, &scope)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 2) // Should not increase anymore
}


// ============================================================================
// Test 9: Native Defer Cleanup on Return and Destruction
// ============================================================================

@(test)
test_cleanup_proc_and_defer :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    cleaned_up := false
    handle := spawn(&sched, proc(f: ^Fiber, c: ^bool) {
        fiber_defer(f, proc(data: rawptr) {
            ptr := (^bool)(data)
            ptr^ = true
        }, c)
        wait_frames(f, 100)
    }, &cleaned_up)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, cleaned_up, false)

    // Cancel fiber mid-sleep
    fiber_cancel(&sched, handle)

    testing.expect_value(t, cleaned_up, true)
}


// ============================================================================
// Test 11: Stack Canary Guard Verification
// ============================================================================

@(test)
test_stack_canary_guard :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    canary_ok := false
    spawn(&sched, proc(f: ^Fiber, ok: ^bool) {
        ok^ = fiber_check_canary(f)
    }, &canary_ok)

    scheduler_step(&sched, 0.016)
    testing.expect(t, canary_ok, "Canary should be intact")
}


// ============================================================================
// Test 12: Nested Structured Concurrency (Race containing Sync)
// ============================================================================

@(test)
test_nested_race_with_sync_branch :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Nested_State :: struct {
        sync_a_done: bool,
        sync_b_done: bool,
        timer_done:  bool,
        winner_idx:  int,
    }

    state := Nested_State{winner_idx = -1}

    spawn(&sched, proc(f: ^Fiber, s: ^Nested_State) {
        w := race(f,
            // Branch 0: Finishes after 2 frames
            branch(proc(f: ^Fiber, s: ^Nested_State) {
                wait_frames(f, 2)
                s.timer_done = true
            }, s, "Timer Branch"),

            // Branch 1: Sync of two sub-tasks (each takes 5 frames)
            branch(proc(f: ^Fiber, s: ^Nested_State) {
                sync(f,
                    branch(proc(f: ^Fiber, s: ^Nested_State) {
                        wait_frames(f, 5)
                        s.sync_a_done = true
                    }, s, "Sub-task A"),
                    branch(proc(f: ^Fiber, s: ^Nested_State) {
                        wait_frames(f, 5)
                        s.sync_b_done = true
                    }, s, "Sub-task B"),
                )
            }, s, "Sync Branch"),
        )
        s.winner_idx = w
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1
    testing.expect_value(t, state.winner_idx, -1)

    scheduler_step(&sched, 0.016) // Frame 2
    scheduler_step(&sched, 0.016) // Frame 3: Timer finishes (winner = 0)
    testing.expect_value(t, state.timer_done, true)
    testing.expect_value(t, state.winner_idx, 0)
    testing.expect_value(t, state.sync_a_done, false)
    testing.expect_value(t, state.sync_b_done, false)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, state.sync_a_done, false)
    testing.expect_value(t, state.sync_b_done, false)
}


// ============================================================================
// Test 14: Multiple Concurrent Independent Coroutines
// ============================================================================

@(test)
test_many_concurrent_fibers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    TOTAL_FIBERS :: 100
    counters: [TOTAL_FIBERS]int

    for i in 0 ..< TOTAL_FIBERS {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            c^ += 1
            yield_frame(f)
            c^ += 2
            yield_frame(f)
            c^ += 3
        }, &counters[i])
    }

    scheduler_step(&sched, 0.016) // Frame 1
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 1)
    }

    scheduler_step(&sched, 0.016) // Frame 2
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 3)
    }

    scheduler_step(&sched, 0.016) // Frame 3
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 6)
    }
}


// ============================================================================
// Test 15: Deep 4-Tier Nested Hierarchy (Sync -> Race -> Sync)
// ============================================================================

@(test)
test_deep_nested_hierarchy_sync_race_sync :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Deep_State :: struct {
        tier4_a_done: bool,
        tier4_b_done: bool,
        tier3_timer_done: bool,
        tier2_sync_done: bool,
        root_done: bool,
    }

    state := Deep_State{}

    spawn(&sched, proc(f: ^Fiber, s: ^Deep_State) {
        // Tier 1: Root Sync
        sync(f,
            // Tier 2: Branch A (Race between sub-sync and timer)
            branch(proc(f: ^Fiber, s: ^Deep_State) {
                race(f,
                    // Tier 3: Quick timer winner
                    branch(proc(f: ^Fiber, s: ^Deep_State) {
                        wait_frames(f, 2)
                        s.tier3_timer_done = true
                    }, s, "Tier 3 Timer"),

                    // Tier 3: Sub-Sync containing Tier 4 tasks
                    branch(proc(f: ^Fiber, s: ^Deep_State) {
                        sync(f,
                            branch(proc(f: ^Fiber, s: ^Deep_State) {
                                wait_frames(f, 10)
                                s.tier4_a_done = true
                            }, s, "Tier 4 Task A"),
                            branch(proc(f: ^Fiber, s: ^Deep_State) {
                                wait_frames(f, 10)
                                s.tier4_b_done = true
                            }, s, "Tier 4 Task B"),
                        )
                    }, s, "Tier 3 Sync"),
                )
            }, s, "Tier 2 Race"),

            // Tier 2: Branch B (Standard sync task)
            branch(proc(f: ^Fiber, s: ^Deep_State) {
                wait_frames(f, 3)
                s.tier2_sync_done = true
            }, s, "Tier 2 Sync B"),
        )

        s.root_done = true
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1: Spawn tree
    testing.expect_value(t, state.root_done, false)

    scheduler_step(&sched, 0.016) // Frame 2
    scheduler_step(&sched, 0.016) // Frame 3: Tier 3 Timer completes -> Race completes!
    testing.expect_value(t, state.tier3_timer_done, true)
    testing.expect_value(t, state.tier4_a_done, false)
    testing.expect_value(t, state.tier4_b_done, false)
    testing.expect_value(t, state.root_done, false)

    scheduler_step(&sched, 0.016) // Frame 4: Tier 2 Sync B completes -> Root wakes!
    testing.expect_value(t, state.tier2_sync_done, true)
    testing.expect_value(t, state.root_done, true)
    testing.expect_value(t, state.tier4_a_done, false)
    testing.expect_value(t, state.tier4_b_done, false)
}


// ============================================================================
// Test 16: Sync Failure Propagation
// ============================================================================

@(test)
test_sync_failure_propagation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Sync_Fail_State :: struct {
        branch_a_done: bool,
        branch_b_failed: bool,
        sync_succeeded: bool,
    }

    state := Sync_Fail_State{}

    spawn(&sched, proc(f: ^Fiber, s: ^Sync_Fail_State) {
        s.sync_succeeded = sync(f,
            branch(proc(f: ^Fiber, s: ^Sync_Fail_State) {
                wait_frames(f, 2)
                s.branch_a_done = true
            }, s, "Branch A"),
            branch(proc(f: ^Fiber, s: ^Sync_Fail_State) {
                yield_frame(f)
                f.status = .Failed // Explicit failure
                s.branch_b_failed = true
            }, s, "Branch B"),
        )
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1
    scheduler_step(&sched, 0.016) // Frame 2: Branch B fails
    testing.expect_value(t, state.branch_b_failed, true)

    scheduler_step(&sched, 0.016) // Frame 3: Branch A finishes -> Sync finishes
    testing.expect_value(t, state.branch_a_done, true)
    testing.expect_value(t, state.sync_succeeded, false) // Should report failure!
}


// ============================================================================
// Test 17: Race with Simultaneous Finishers (Tie-Break Verification)
// ============================================================================

@(test)
test_race_all_simultaneous_finish :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Race_Tie_State :: struct {
        winner: int,
        executed_count: int,
    }

    state := Race_Tie_State{winner = -1}

    spawn(&sched, proc(f: ^Fiber, s: ^Race_Tie_State) {
        s.winner = race(f,
            branch(proc(f: ^Fiber, s: ^Race_Tie_State) {
                wait_frames(f, 1)
                s.executed_count += 1
            }, s, "Branch 0"),
            branch(proc(f: ^Fiber, s: ^Race_Tie_State) {
                wait_frames(f, 1)
                s.executed_count += 1
            }, s, "Branch 1"),
            branch(proc(f: ^Fiber, s: ^Race_Tie_State) {
                wait_frames(f, 1)
                s.executed_count += 1
            }, s, "Branch 2"),
        )
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1: Spawn all
    testing.expect_value(t, state.winner, -1)

    scheduler_step(&sched, 0.016) // Frame 2: All 3 ready at the exact same frame!
    // Exactly one winner must be elected, and parent wakes up
    testing.expect(t, state.winner >= 0 && state.winner <= 2, "Winner must be a valid branch index")
    testing.expect_value(t, state.executed_count, 1) // Only the winning branch should complete its post-wait code
}


// ============================================================================
// Test 18: Race Loser with Subtree Aborts All Descendants
// ============================================================================

@(test)
test_race_loser_with_children_aborts_all_descendants :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Descendant_State :: struct {
        fast_done:         bool,
        grandchild_1_done: bool,
        grandchild_2_done: bool,
        grandchild_cleaned_up: bool,
    }

    state := Descendant_State{}

    spawn(&sched, proc(f: ^Fiber, s: ^Descendant_State) {
        race(f,
            // Branch 0: Wins after 1 frame
            branch(proc(f: ^Fiber, s: ^Descendant_State) {
                yield_frame(f)
                s.fast_done = true
            }, s, "Fast Winner"),

            // Branch 1: Spawns sub-children and grandchildren
            branch(proc(f: ^Fiber, s: ^Descendant_State) {
                sync(f,
                    branch(proc(f: ^Fiber, s: ^Descendant_State) {
                        fiber_defer(f, proc(data: rawptr) {
                            ptr := (^Descendant_State)(data)
                            ptr.grandchild_cleaned_up = true
                        }, s)
                        wait_frames(f, 10)
                        s.grandchild_1_done = true
                    }, s, "Grandchild 1"),
                    branch(proc(f: ^Fiber, s: ^Descendant_State) {
                        wait_frames(f, 10)
                        s.grandchild_2_done = true
                    }, s, "Grandchild 2"),
                )
            }, s, "Losing Parent Subtree"),
        )
    }, &state)

    scheduler_step(&sched, 0.016) // Frame 1: Spawn all
    scheduler_step(&sched, 0.016) // Frame 2: Fast winner finishes -> aborts Branch 1 and all its grandchildren!

    testing.expect_value(t, state.fast_done, true)
    testing.expect_value(t, state.grandchild_cleaned_up, true) // Destructor ran!
    testing.expect_value(t, state.grandchild_1_done, false)
    testing.expect_value(t, state.grandchild_2_done, false)

    // Ensure grandchildren never wake up in later frames
    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, state.grandchild_1_done, false)
    testing.expect_value(t, state.grandchild_2_done, false)
}


// ============================================================================
// Test 19: 1,000 Random Timers Chronological Sort Validation
// ============================================================================

@(test)
test_timer_heap_1000_random_sort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, DEFAULT_STACK_SIZE, 64)
    defer scheduler_destroy(&sched)

    TOTAL_TIMERS :: 1000
    wake_history: [dynamic]f64
    wake_history = make([dynamic]f64)
    defer delete(wake_history)

    Timer_Entry :: struct {
        target_time: f32,
        history_ptr: ^[dynamic]f64,
    }

    entries: [TOTAL_TIMERS]Timer_Entry

    for i in 0 ..< TOTAL_TIMERS {
        // Random wait between 0.05 and 3.0 seconds
        dur := rand.float32_range(0.05, 3.0)
        entries[i] = Timer_Entry{
            target_time = dur,
            history_ptr = &wake_history,
        }

        spawn(&sched, proc(f: ^Fiber, e: ^Timer_Entry) {
            wait(f, e.target_time)
            append(e.history_ptr, current_time(f))
        }, &entries[i])
    }

    // Step scheduler progressively
    for t_step := 0; t_step < 100; t_step += 1 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, len(wake_history), TOTAL_TIMERS)

    // Verify monotonic non-decreasing order of waking
    for i in 0 ..< len(wake_history) - 1 {
        t0 := wake_history[i]
        t1 := wake_history[i + 1]
        testing.expect(t, t0 <= t1, fmt.tprintf("Timer %d (%.3f) woke after timer %d (%.3f)", i, t0, i + 1, t1))
    }
}


// ============================================================================
// Test 20: Random Timer Heap Cancellations Preserves Rebalance
// ============================================================================

@(test)
test_timer_heap_random_cancellations :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, DEFAULT_STACK_SIZE, 64)
    defer scheduler_destroy(&sched)

    TOTAL :: 200
    handles: [TOTAL]Fiber_Handle
    woke: [TOTAL]bool

    for i in 0 ..< TOTAL {
        dur := rand.float32_range(0.1, 2.0)
        handles[i] = spawn(&sched, proc(f: ^Fiber, w: ^bool) {
            wait(f, f32(f.start_time) + 0.5)
            w^ = true
        }, &woke[i])
    }

    // Advance 1 step so all are in timer min-heap
    scheduler_step(&sched, 0.016)

    // Randomly cancel 100 of them
    cancelled_count := 0
    is_cancelled: [TOTAL]bool
    for i in 0 ..< TOTAL {
        if i % 2 == 0 {
            fiber_cancel(&sched, handles[i])
            is_cancelled[i] = true
            cancelled_count += 1
        }
    }

    // Step to completion
    for _ in 0 ..< 60 {
        scheduler_step(&sched, 0.05)
    }

    // Verify cancelled did not wake and non-cancelled did wake
    for i in 0 ..< TOTAL {
        if is_cancelled[i] {
            testing.expect_value(t, woke[i], false)
        } else {
            testing.expect_value(t, woke[i], true)
        }
    }
}


// ============================================================================
// Test 22: Multi-Slab Pool Expansion & Stack Reclaim
// ============================================================================

@(test)
test_pool_multi_slab_expansion_and_reclaim :: proc(t: ^testing.T) {
    sched: Scheduler
    // Small slab size (8 stacks per slab) to force multiple slab allocations
    scheduler_init(&sched, 16 * 1024, 8)
    defer scheduler_destroy(&sched)

    TOTAL_FIBERS :: 120 // Requires 15 slabs
    completed := 0

    for _ in 0 ..< TOTAL_FIBERS {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            yield_frame(f)
            c^ += 1
        }, &completed)
    }

    testing.expect(t, len(sched.fiber_pool.slabs) >= 15, "Pool should have grown to at least 15 slabs")

    scheduler_step(&sched, 0.016) // Frame 1: run to yield
    scheduler_step(&sched, 0.016) // Frame 2: wake and complete

    testing.expect_value(t, completed, TOTAL_FIBERS)
    testing.expect_value(t, len(sched.fiber_pool.free_fibers), len(sched.fiber_pool.all_fibers))
}


// ============================================================================
// Test 23: Fiber Lifecycle Generation Re-use (10 Cycles)
// ============================================================================

@(test)
test_fiber_lifecycle_generation_reuse :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, DEFAULT_STACK_SIZE, 32)
    defer scheduler_destroy(&sched)

    BATCH_SIZE :: 30
    CYCLES :: 10

    for cycle := 0; cycle < CYCLES; cycle += 1 {
        count := 0
        for i in 0 ..< BATCH_SIZE {
            spawn(&sched, proc(f: ^Fiber, c: ^int) {
                local_var := 42
                yield_frame(f)
                c^ += local_var
            }, &count)
        }

        scheduler_step(&sched, 0.016)
        scheduler_step(&sched, 0.016)

        testing.expect_value(t, count, BATCH_SIZE * 42)
    }
}


// ============================================================================
// Test 24: Local Variable Isolation on Stack across 50 Interleaved Fibers
// ============================================================================

@(test)
test_local_variable_isolation_many_fibers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    COUNT :: 50
    success_flags: [COUNT]bool

    for i in 0 ..< COUNT {
        spawn(&sched, proc(f: ^Fiber, ok: ^bool) {
            // Allocate distinct array on this fiber's stack
            arr: [64]u64
            for j in 0 ..< 64 {
                arr[j] = u64(uintptr(f)) + u64(j)
            }

            // Yield multiple times
            for _ in 0 ..< 5 {
                yield_frame(f)
            }

            // Validate that other interleaved fibers did not corrupt our stack memory
            is_valid := true
            for j in 0 ..< 64 {
                if arr[j] != u64(uintptr(f)) + u64(j) {
                    is_valid = false
                    break
                }
            }
            ok^ = is_valid
        }, &success_flags[i])
    }

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }

    for i in 0 ..< COUNT {
        testing.expect_value(t, success_flags[i], true)
    }
}


// ============================================================================
// Test 26: 10,000 Consecutive Yield Re-entrancy Loop
// ============================================================================

@(test)
test_10k_yield_loop :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ITERATIONS :: 10000
    loop_count := 0
    canary_intact := false

    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        for i in 0 ..< ITERATIONS {
            c^ = i + 1
            yield_frame(f)
        }
    }, &loop_count)

    for _ in 0 ..< ITERATIONS {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, loop_count, ITERATIONS)
}


// ============================================================================
// Test 27: Zero and Negative Duration Waits Boundary Safety
// ============================================================================

@(test)
test_zero_and_negative_waits :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    completed := 0
    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        wait(f, 0.0)
        c^ += 1
        wait(f, -5.0)
        c^ += 1
        wait_frames(f, 0)
        c^ += 1
        wait_frames(f, -10)
        c^ += 1
    }, &completed)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, completed, 4)
}


// ============================================================================
// Test 28: Per-Fiber Temp Allocator Isolation Across Yields
// ============================================================================

@(test)
test_fiber_temp_allocator_isolation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [2]int

    // Fiber 0: Allocates dynamic array using context.temp_allocator
    spawn(&sched, proc(f: ^Fiber, res: ^[2]int) {
        temp_slice := make([]int, 10, context.temp_allocator)
        for i in 0 ..< 10 do temp_slice[i] = i * 10

        // Yield multiple times
        yield_frame(f)
        yield_frame(f)

        // Verify values survived yields intact without corruption
        sum := 0
        for val in temp_slice do sum += val
        res[0] = sum
    }, &results)

    // Fiber 1: Also allocates from its own context.temp_allocator
    spawn(&sched, proc(f: ^Fiber, res: ^[2]int) {
        temp_slice := make([]int, 5, context.temp_allocator)
        for i in 0 ..< 5 do temp_slice[i] = 100

        yield_frame(f)

        sum := 0
        for val in temp_slice do sum += val
        res[1] = sum
    }, &results)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, results[0], 450)
    testing.expect_value(t, results[1], 500)
}


// ============================================================================
// Test 29: with_timeout - Successful Completion Before Deadline
// ============================================================================

@(test)
test_with_timeout_completion :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    State :: struct {
        finished:  bool,
        timed_out: bool,
    }
    state := State{}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.timed_out = with_timeout(f, 0.5, branch(proc(f: ^Fiber, s: ^State) {
            wait(f, 0.1)
            s.finished = true
        }, s, "Quick Task"))
    }, &state)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, state.finished, true)
    testing.expect_value(t, state.timed_out, false)
}


// ============================================================================
// Test 30: with_timeout - Expiration Aborts Hanging Task
// ============================================================================

@(test)
test_with_timeout_expired :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    State :: struct {
        finished:  bool,
        timed_out: bool,
    }
    state := State{}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.timed_out = with_timeout(f, 0.1, branch(proc(f: ^Fiber, s: ^State) {
            wait(f, 2.0) // Takes much longer than timeout
            s.finished = true
        }, s, "Slow Task"))
    }, &state)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, state.finished, false)
    testing.expect_value(t, state.timed_out, true)
}


// ============================================================================
// Test 31: Signal Event Broadcast Wakes All Waiters
// ============================================================================

@(test)
test_signal_broadcast :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    woken_count := 0

    Signal_Payload :: struct {
        count: ^int,
        sig:   ^Signal,
    }
    payload := Signal_Payload{count = &woken_count, sig = &sig}

    // Spawn 3 fibers waiting on the signal
    for _ in 0 ..< 3 {
        spawn(&sched, proc(f: ^Fiber, p: ^Signal_Payload) {
            signal_wait(f, p.sig)
            p.count^ += 1
        }, &payload)
    }

    scheduler_step(&sched, 0.016) // Put all into signal.waiters
    testing.expect_value(t, signal_waiter_count(&sig), 3)
    testing.expect_value(t, woken_count, 0)

    // Emit signal
    signal_emit(&sched, &sig)
    testing.expect_value(t, signal_waiter_count(&sig), 0)

    scheduler_step(&sched, 0.016) // Execute ready fibers
    testing.expect_value(t, woken_count, 3)
}


// ============================================================================
// Test 33: Stack Watermark & Usage Profiler Calculation
// ============================================================================

@(test)
test_stack_watermark_usage_calculation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    used_recorded: uint = 0
    total_recorded: uint = 0

    Stack_Usage_Data :: struct {
        used:  ^uint,
        total: ^uint,
    }
    usage_data := Stack_Usage_Data{used = &used_recorded, total = &total_recorded}

    spawn(&sched, proc(f: ^Fiber, out: ^Stack_Usage_Data) {
        local_buffer: [512]u8
        sum := 0
        for i in 0 ..< 512 {
            local_buffer[i] = u8((i + 1) % 255)
        }
        for i in 0 ..< 512 {
            sum += int(local_buffer[i])
        }
        if sum == 0 {
            out.used^ = 9999
        }

        used, total := fiber_calc_stack_usage(f)
        out.used^ = used
        out.total^ = total
    }, &usage_data)

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, total_recorded, DEFAULT_STACK_SIZE)
    testing.expect(t, used_recorded >= 240, fmt.tprintf("Expected >= 240 bytes used (initial frame + locals), got %v", used_recorded))
    testing.expect(t, used_recorded < 32 * 1024, "Used bytes must be less than 32KB")
}


// ============================================================================
// Test 34: Async Token Bridge (External Worker Simulation)
// ============================================================================

@(test)
test_async_token_bridge :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    token: Async_Token
    async_token_init(&token)

    State :: struct {
        token:     ^Async_Token,
        completed: bool,
        success:   bool,
    }
    state := State{token = &token}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.success = await_async(f, s.token)
        s.completed = true
    }, &state)

    // Step 1: Fiber starts and suspends because token is Pending
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.completed, false)

    // Simulate background worker thread finishing work
    async_token_complete(&token, true)

    // Step 2: Scheduler evaluates condition, detects completion, and resumes fiber
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.completed, true)
    testing.expect_value(t, state.success, true)
}


// ============================================================================
// Test 39: Configurable Virtual Memory Guard Page Allocation
// ============================================================================

@(test)
test_virtual_memory_guard_pages :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, alloc_mode = .Virtual_Memory_OS)
    defer scheduler_destroy(&sched)

    ran := false
    spawn(&sched, proc(f: ^Fiber, r: ^bool) {
        r^ = true
        yield_frame(f)
    }, &ran)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, ran, true)
}


// ============================================================================
// Test 40: Spawn by Value - Primitives
// ============================================================================

Test_Val_Primitive :: struct {
    intensity: f32,
    out:       ^f32,
}

@(test)
test_spawn_by_value_primitives :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    out_1: f32 = 0.0
    out_2: f32 = 0.0

    spawn_fn :: proc(f: ^Fiber, p: Test_Val_Primitive) {
        yield_frame(f)
        p.out^ = p.intensity * 2.0
    }

    spawn(&sched, spawn_fn, Test_Val_Primitive{intensity = 12.5, out = &out_1})
    spawn(&sched, spawn_fn, Test_Val_Primitive{intensity = 50.0, out = &out_2})

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, out_1, 0.0)
    testing.expect_value(t, out_2, 0.0)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, out_1, 25.0)
    testing.expect_value(t, out_2, 100.0)
}


// ============================================================================
// Test 41: Spawn by Value - Composite Struct
// ============================================================================

Test_Payload_Struct :: struct {
    pos:    [2]f32,
    speed:  f32,
    id:     int,
    active: bool,
    out:    ^[2]f32,
}

@(test)
test_spawn_by_value_struct :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    res1: [2]f32
    res2: [2]f32

    spawn_struct_fn :: proc(f: ^Fiber, p: Test_Payload_Struct) {
        yield_frame(f)
        if p.active {
            p.out^ = p.pos + {p.speed, p.speed}
        }
    }

    p1 := Test_Payload_Struct{pos = {10, 20}, speed = 100.0, id = 1, active = true, out = &res1}
    p2 := Test_Payload_Struct{pos = {30, 40}, speed = 200.0, id = 2, active = true, out = &res2}

    spawn(&sched, spawn_struct_fn, p1)
    spawn(&sched, spawn_struct_fn, p2)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, res1.x, 110.0)
    testing.expect_value(t, res1.y, 120.0)
    testing.expect_value(t, res2.x, 230.0)
    testing.expect_value(t, res2.y, 240.0)
}


// ============================================================================
// Test 42: Spawn by Value - Concurrency & Zero Crosstalk
// ============================================================================

@(test)
test_spawn_by_value_concurrency_no_crosstalk :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    FIBER_COUNT :: 32
    results: [FIBER_COUNT]int

    Worker_Arg :: struct {
        idx: int,
        out: ^[FIBER_COUNT]int,
    }

    worker :: proc(f: ^Fiber, arg: Worker_Arg) {
        for _ in 0 ..< 3 {
            yield_frame(f)
        }
        arg.out[arg.idx] = (arg.idx + 1) * 10
    }

    for i in 0 ..< FIBER_COUNT {
        spawn(&sched, worker, Worker_Arg{idx = i, out = &results})
    }

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    for i in 0 ..< FIBER_COUNT {
        testing.expect_value(t, results[i], (i + 1) * 10)
    }
}


// ============================================================================
// Test 43: Branch by Value - Sync
// ============================================================================

@(test)
test_branch_by_value_sync :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [3]int

    Branch_Val_Arg :: struct {
        multiplier: int,
        out:        ^int,
    }

    branch_task :: proc(f: ^Fiber, arg: Branch_Val_Arg) {
        yield_frame(f)
        arg.out^ = arg.multiplier * 10
    }

    spawn(&sched, proc(f: ^Fiber, res: ^[3]int) {
        sync(f,
            branch(branch_task, Branch_Val_Arg{10, &res[0]}, "Branch 1"),
            branch(branch_task, Branch_Val_Arg{20, &res[1]}, "Branch 2"),
            branch(branch_task, Branch_Val_Arg{30, &res[2]}, "Branch 3"),
        )
    }, &results)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, results[0], 100)
    testing.expect_value(t, results[1], 200)
    testing.expect_value(t, results[2], 300)
}


// ============================================================================
// Test 44: Branch by Value - Race
// ============================================================================

@(test)
test_branch_by_value_race :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winner_value := -1

    Race_Val_Arg :: struct {
        val: int,
        out: ^int,
    }

    fast_task :: proc(f: ^Fiber, arg: Race_Val_Arg) {
        yield_frame(f)
        arg.out^ = arg.val
    }

    slow_task :: proc(f: ^Fiber, arg: Race_Val_Arg) {
        for _ in 0 ..< 10 {
            yield_frame(f)
        }
        arg.out^ = arg.val
    }

    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        race(f,
            branch(slow_task, Race_Val_Arg{999, win}, "Slow Branch"),
            branch(fast_task, Race_Val_Arg{42, win}, "Fast Branch"),
        )
    }, &winner_value)

    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, winner_value, 42)
}


// ============================================================================
// Test 45: Ephemeral Stack Safety (Dangling Pointer Prevention)
// ============================================================================

@(test)
test_spawn_by_value_ephemeral_stack_safety :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [4]f32

    spawn_from_ephemeral_stack :: proc(sched: ^Scheduler, out: ^[4]f32) {
        for i in 0 ..< 4 {
            ephemeral_intensity: f32 = f32(i + 1) * 7.5

            Arg :: struct {
                intensity: f32,
                out_slot:  ^f32,
            }

            spawn(sched, proc(f: ^Fiber, arg: Arg) {
                yield_frame(f)
                yield_frame(f)
                arg.out_slot^ = arg.intensity
            }, Arg{ephemeral_intensity, &out[i]})
        }

        trash_stack: [2048]byte
        for &b, idx in &trash_stack {
            b = u8(idx & 0xFF)
        }
    }

    spawn_from_ephemeral_stack(&sched, &results)

    deep_stack_call :: proc(depth: int) -> int {
        arr: [256]int
        for i in 0 ..< 256 do arr[i] = depth * i
        if depth <= 0 do return arr[10]
        return arr[5] + deep_stack_call(depth - 1)
    }
    _ = deep_stack_call(10)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, results[0], 7.5)
    testing.expect_value(t, results[1], 15.0)
    testing.expect_value(t, results[2], 22.5)
    testing.expect_value(t, results[3], 30.0)
}


// ============================================================================
// Test 47: Direct Procedure Passing in with_timeout Overloads
// ============================================================================

@(test)
test_with_timeout_proc_overloads :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [3]bool

    // 1. Direct nil-proc with timeout (should time out)
    spawn(&sched, proc(f: ^Fiber, res: ^[3]bool) {
        timed_out := with_timeout(f, 0.05, proc(f: ^Fiber) {
            wait(f, 0.5) // Exceeds timeout
        })
        res[0] = timed_out
    }, &results)

    // 2. Direct ptr-proc completing in time (should NOT time out)
    speed: f32 = 100.0
    spawn(&sched, proc(f: ^Fiber, res: ^[3]bool) {
        spd := f32(100.0)
        timed_out := with_timeout(f, 0.5, proc(f: ^Fiber, s: ^f32) {
            wait(f, 0.05)
            s^ = 200.0
        }, &spd)
        res[1] = timed_out
    }, &results)

    // 3. Direct val-proc completing in time (should NOT time out)
    spawn(&sched, proc(f: ^Fiber, res: ^[3]bool) {
        timed_out := with_timeout(f, 0.5, proc(f: ^Fiber, val: int) {
            wait(f, 0.05)
        }, 42)
        res[2] = timed_out
    }, &results)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, results[0], true)  // Timed out
    testing.expect_value(t, results[1], false) // Finished in time
    testing.expect_value(t, results[2], false) // Finished in time
}


// ============================================================================
// Test 50: Scope Query Helpers & Scope Destroy
// ============================================================================

@(test)
test_scope_query_helpers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope

    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)

    h1 := spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)

    h2 := spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)

    testing.expect_value(t, scope_active_count(&scope), 2)
    testing.expect_value(t, scope_is_busy(&scope), true)
    testing.expect_value(t, scope_is_empty(&scope), false)

    // Cancel 1 handle
    fiber_cancel(&sched, h1)
    scheduler_step(&sched, 0.016) // Cleans up cancelled fiber and unlinks from scope

    testing.expect_value(t, scope_active_count(&scope), 1)

    // Destroy scope completely with scheduler
    scope_destroy(&sched, &scope)
    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
}


// ============================================================================
// Test 51: Fiber Time Accessor Helpers (delta_time, current_time, current_frame)
// ============================================================================

@(test)
test_fiber_time_accessors :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    captured_dt: f32 = 0.0
    captured_time: f64 = 0.0
    captured_frame: u64 = 0

    spawn(&sched, proc(f: ^Fiber) {
        yield_frame(f)
    })

    State :: struct {
        dt:    ^f32,
        time:  ^f64,
        frame: ^u64,
    }

    spawn(&sched, proc(f: ^Fiber, s: State) {
        yield_frame(f)
        s.dt^ = delta_time(f)
        s.time^ = current_time(f)
        s.frame^ = current_frame(f)
    }, State{&captured_dt, &captured_time, &captured_frame})

    scheduler_step(&sched, 0.033) // frame 1, dt = 0.033
    scheduler_step(&sched, 0.016) // frame 2, dt = 0.016

    testing.expect_value(t, captured_dt, f32(0.016))
    testing.expect(t, math.abs(captured_time - (0.033 + 0.016)) < 0.001, "Expected current_time ~ 0.049")
    testing.expect_value(t, captured_frame, u64(2))
}


// ============================================================================
// Test 52: scope_wait (Wait for Entire Scope Completion)
// ============================================================================

@(test)
test_scope_wait :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    wave_scope: Fiber_Scope
    defer scope_destroy(&sched, &wave_scope)

    enemies_done: [3]bool
    boss_started := false

    // Spawn 3 wave enemies with staggered durations
    for i in 0 ..< 3 {
        idx := i
        spawn(&sched, proc(f: ^Fiber, flag: ^bool) {
            wait(f, f32(1 + f.branch_index) * 0.05)
            flag^ = true
        }, &enemies_done[i], scope = &wave_scope)
    }

    // Spawn master supervisor waiting for entire wave scope
    Supervisor_Arg :: struct {
        scope:   ^Fiber_Scope,
        flag:    ^[3]bool,
        started: ^bool,
    }

    spawn(&sched, proc(f: ^Fiber, arg: Supervisor_Arg) {
        scope_wait(f, arg.scope)
        // All enemies must be done when supervisor resumes
        if arg.flag[0] && arg.flag[1] && arg.flag[2] {
            arg.started^ = true
        }
    }, Supervisor_Arg{&wave_scope, &enemies_done, &boss_started})

    // Step scheduler until wave finishes
    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, enemies_done[0], true)
    testing.expect_value(t, enemies_done[1], true)
    testing.expect_value(t, enemies_done[2], true)
    testing.expect_value(t, boss_started, true)
}


// ============================================================================
// Test 56: Fallback Control Flow (Sequential Branch Fallback on Failure)
// ============================================================================

@(test)
test_fallback_control_flow :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Results :: struct {
        success:    bool,
        action_idx: int,
    }

    res: Results

    spawn(&sched, proc(f: ^Fiber, r: ^Results) {
        ok, idx := fallback(f,
            branch(proc(f: ^Fiber) {
                // Branch 0: Fails immediately
                fail(f)
            }, "Try Melee (Fails)"),
            branch(proc(f: ^Fiber) {
                // Branch 1: Fails after small delay
                wait(f, 0.02)
                fail(f)
            }, "Try Snipe (Fails)"),
            branch(proc(f: ^Fiber) {
                // Branch 2: Succeeds
                wait(f, 0.02)
            }, "Fallback Patrol (Succeeds)"),
        )
        r.success = ok
        r.action_idx = idx
    }, &res)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, res.success, true)
    testing.expect_value(t, res.action_idx, 2)
}


// ============================================================================
// Test 57: Rush Concurrency (Parallel Success Preemption Ignoring Failures)
// ============================================================================

@(test)
test_race_preemption_ignoring_failures :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winning_branch: int = -99

    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        winner := race(f,
            branch(proc(f: ^Fiber) {
                // Branch 0: Fails quickly at 0.02s (failure is ignored!)
                wait(f, 0.02)
                fail(f)
            }, "Quest A (Fails early)"),
            branch(proc(f: ^Fiber) {
                // Branch 1: Succeeds at 0.06s (First to SUCCEED wins!)
                wait(f, 0.06)
            }, "Quest B (Succeeds first)"),
            branch(proc(f: ^Fiber) {
                // Branch 2: Would succeed at 0.20s, but is aborted by Branch 1
                wait(f, 0.20)
            }, "Quest C (Aborted)"),
        )
        win^ = winner
    }, &winning_branch)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, winning_branch, 1)
}


// ============================================================================
// Test 60: fail Primitive & Sync Error Propagation
// ============================================================================

@(test)
test_fail_primitive :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    all_passed := true

    spawn(&sched, proc(f: ^Fiber, res: ^bool) {
        ok := sync(f,
            branch(proc(f: ^Fiber) {
                wait(f, 0.01)
            }),
            branch(proc(f: ^Fiber) {
                fail(f) // Marks sync coordination as failed
            }),
        )
        res^ = ok
    }, &all_passed)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, all_passed, false)
}


// ============================================================================
// Test 61: Fallback All Failing & Value-Based Payload Branches
// ============================================================================

@(test)
test_fallback_all_failing_and_by_value :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // 1. All branches fail -> returns (false, -1)
    all_failed_res: bool = true
    all_failed_idx: int = 99

    spawn(&sched, proc(f: ^Fiber, out: ^[2]int) {
        ok, idx := fallback(f,
            branch(proc(f: ^Fiber) { fail(f) }),
            branch(proc(f: ^Fiber) { fail(f) }),
            branch(proc(f: ^Fiber) { fail(f) }),
        )
        out[0] = ok ? 1 : 0
        out[1] = idx
    }, &[2]int{1, 99})

    // 2. By-value branch passing
    Arg :: struct {
        val: int,
        out: ^int,
    }
    val_res: int = 0
    spawn(&sched, proc(f: ^Fiber, out: ^int) {
        ok, idx := fallback(f,
            branch(proc(f: ^Fiber, a: Arg) {
                if a.val < 10 do fail(f)
            }, Arg{val = 5, out = out}),
            branch(proc(f: ^Fiber, a: Arg) {
                if a.val >= 10 {
                    a.out^ = a.val * 2
                }
            }, Arg{val = 20, out = out}),
        )
        if !ok do out^ = -1
    }, &val_res)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, val_res, 40)
}


// ============================================================================
// Test 62: Rush 5 Parallel Branches & All Failing Edge Case
// ============================================================================

@(test)
test_race_5_branches_and_all_failing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winner_5: int = -99
    all_fail_winner: int = 99

    // 5 branches: 0, 1 fail early; 2 takes long; 3 finishes successfully first; 4 takes longest
    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        w := race(f,
            branch(proc(f: ^Fiber) { wait(f, 0.02); fail(f) }, "Branch 0 (Fails)"),
            branch(proc(f: ^Fiber) { wait(f, 0.03); fail(f) }, "Branch 1 (Fails)"),
            branch(proc(f: ^Fiber) { wait(f, 0.25) }, "Branch 2 (Long)"),
            branch(proc(f: ^Fiber) { wait(f, 0.06) }, "Branch 3 (First Success)"),
            branch(proc(f: ^Fiber) { wait(f, 0.50) }, "Branch 4 (Longest)"),
        )
        win^ = w
    }, &winner_5)

    // All branches fail -> returns -1
    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        w := race(f,
            branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }),
            branch(proc(f: ^Fiber) { wait(f, 0.02); fail(f) }),
            branch(proc(f: ^Fiber) { wait(f, 0.03); fail(f) }),
        )
        win^ = w
    }, &all_fail_winner)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, winner_5, 3)
    testing.expect_value(t, all_fail_winner, -1)
}


// ============================================================================
// Test 65: Deeply Nested Concurrency Combinators (Sync { Rush, Fallback, Race })
// ============================================================================

@(test)
test_nested_concurrency_combinators :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    all_ok := false

    spawn(&sched, proc(f: ^Fiber, out_ok: ^bool) {
        // Sync outer join
        res := sync(f,
            // Branch 0: Nested Race
            branch(proc(f: ^Fiber) {
                winner := race(f,
                    branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.04) }),
                )
                if winner != 1 do fail(f)
            }, "Nested Race"),

            // Branch 1: Nested Fallback
            branch(proc(f: ^Fiber) {
                ok, idx := fallback(f,
                    branch(proc(f: ^Fiber) { fail(f) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.02) }),
                )
                if !ok || idx != 1 do fail(f)
            }, "Nested Fallback"),

            // Branch 2: Nested Race
            branch(proc(f: ^Fiber) {
                winner := race(f,
                    branch(proc(f: ^Fiber) { wait(f, 0.02) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.50) }),
                )
                if winner != 0 do fail(f)
            }, "Nested Race"),
        )

        out_ok^ = res
    }, &all_ok)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, all_ok, true)
}


// ============================================================================
// Test 71: Dynamic Task Joining (fiber_join on normal completion)
// ============================================================================

@(test)
test_fiber_join_normal_completion :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    target_done := false
    joiner_success := false

    target_handle := spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.05)
        done^ = true
    }, &target_done)

    spawn(&sched, proc(f: ^Fiber, args: ^[2]rawptr) {
        h := (cast(^Fiber_Handle)args[0])^
        s := cast(^bool)args[1]
        ok := fiber_join(f, h)
        if ok do s^ = true
    }, &[2]rawptr{&target_handle, &joiner_success})

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, target_done)
    testing.expect(t, joiner_success)
}


// ============================================================================
// Test 72: Dynamic Task Joining (fiber_join on cancelled target)
// ============================================================================

@(test)
test_fiber_join_cancelled_target :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    join_result := true

    target_handle := spawn(&sched, proc(f: ^Fiber) {
        for {
            yield_frame(f)
        }
    })

    spawn(&sched, proc(f: ^Fiber, args: ^[2]rawptr) {
        h := (cast(^Fiber_Handle)args[0])^
        res := cast(^bool)args[1]
        res^ = fiber_join(f, h)
    }, &[2]rawptr{&target_handle, &join_result})

    scheduler_step(&sched, 0.01)
    testing.expect(t, fiber_is_alive(&sched, target_handle))

    // Abort target
    fiber_cancel(&sched, target_handle)

    // Step scheduler
    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, !fiber_is_alive(&sched, target_handle))
    testing.expect_value(t, join_result, false)
}


// ============================================================================
// Test 73: Dynamic Task Joining (fiber_join on already completed fiber)
// ============================================================================

@(test)
test_fiber_join_already_finished :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    target_handle := spawn(&sched, proc(f: ^Fiber) {
        // Finishes immediately
    })

    scheduler_step(&sched, 0.01)
    testing.expect(t, !fiber_is_alive(&sched, target_handle))

    joiner_done := false
    spawn(&sched, proc(f: ^Fiber, args: ^[2]rawptr) {
        h := (cast(^Fiber_Handle)args[0])^
        done := cast(^bool)args[1]
        ok := fiber_join(f, h)
        if ok do done^ = true
    }, &[2]rawptr{&target_handle, &joiner_done})

    scheduler_step(&sched, 0.01)
    testing.expect(t, joiner_done)
}


// ============================================================================
// Test 74: Typed Multicast Event (Event(T) 1-to-many publish-subscribe)
// ============================================================================

@(test)
test_event_typed_multicast :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(string)
    event_init(&ev)
    defer event_destroy(&ev)

    received: [3]string

    for i in 0 ..< 3 {
        Test_Listener :: struct {
            ev:  ^Event(string),
            dst: ^string,
        }
        listener_data := Test_Listener{ev = &ev, dst = &received[i]}
        spawn_val(&sched, proc(f: ^Fiber, data: Test_Listener) {
            msg, ok := event_wait(f, data.ev)
            if ok do data.dst^ = msg
        }, listener_data)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, event_waiter_count(&ev), 3)
    testing.expect(t, event_has_waiters(&ev))

    // Broadcast message to all 3 listeners
    event_emit(&sched, &ev, "Multicast Payload 100")

    scheduler_step(&sched, 0.01)

    for i in 0 ..< 3 {
        testing.expect_value(t, received[i], "Multicast Payload 100")
    }
    testing.expect_value(t, event_waiter_count(&ev), 0)
}


// ============================================================================
// Test 75: Typed Multicast Event (Empty emit safety)
// ============================================================================

@(test)
test_event_empty_emit :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    // Emit with 0 listeners should not crash
    event_emit(&sched, &ev, 999)
    testing.expect_value(t, event_waiter_count(&ev), 0)
    testing.expect(t, !event_has_waiters(&ev))
}


// ============================================================================
// Test 79: Pool Pre-Warming (scheduler_prewarm / fiber_pool_prewarm)
// ============================================================================

@(test)
test_scheduler_prewarm :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    testing.expect_value(t, len(sched.fiber_pool.all_fibers), 0)

    // Pre-warm to 80 fibers (allocates 3 slabs: 32 * 3 = 96 stacks)
    scheduler_prewarm(&sched, 80)
    testing.expect(t, len(sched.fiber_pool.all_fibers) >= 80)
    testing.expect(t, len(sched.fiber_pool.free_fibers) >= 80)
}


// ============================================================================
// Test 80: Handle Introspection & Telemetry (fiber_is_alive & fiber_status)
// ============================================================================

@(test)
test_handle_introspection_and_status :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    handle := spawn(&sched, proc(f: ^Fiber) {
        wait(f, 0.05)
    })

    testing.expect(t, fiber_is_alive(&sched, handle))
    status, ok := fiber_status(&sched, handle)
    testing.expect(t, ok)
    testing.expect(t, status == .Ready)

    scheduler_step(&sched, 0.01)
    status, ok = fiber_status(&sched, handle)
    testing.expect(t, ok)
    testing.expect(t, status == .Sleeping_Time)

    // Advance time until finish
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, !fiber_is_alive(&sched, handle))
}


// ============================================================================
// Test 81: Memory Telemetry & Statistics (scheduler_pool_stats)
// ============================================================================

@(test)
test_scheduler_pool_stats :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.total_stacks, 0)
    testing.expect_value(t, stats.active_fibers, 0)
    testing.expect_value(t, stats.free_fibers, 0)
    testing.expect_value(t, stats.slabs_count, 0)

    // Spawn 3 active fibers (allocates first slab)
    spawn(&sched, proc(f: ^Fiber) { wait(f, 1.0) })
    spawn(&sched, proc(f: ^Fiber) { wait(f, 1.0) })
    spawn(&sched, proc(f: ^Fiber) { wait(f, 1.0) })

    stats = scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.total_stacks, 32)
    testing.expect_value(t, stats.active_fibers, 3)
    testing.expect_value(t, stats.free_fibers, 29)
    testing.expect_value(t, stats.slabs_count, 1)
    testing.expect(t, stats.total_memory_kb > 0)
}


// ============================================================================
// Test 85: Scope Active Handles Count and Tracking
// ============================================================================

@(test)
test_scope_hierarchy_multi_fiber_active_count :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    testing.expect_value(t, scope_active_count(&scope), 0)

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)

    testing.expect_value(t, scope_active_count(&scope), 2)
}


// ============================================================================
// Test 86: Signal Multicast Wait and Broadcast
// ============================================================================

@(test)
test_signal_multicast_wait_and_broadcast :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    w1_done := false
    w2_done := false
    w3_done := false

    Signal_Env :: struct {
        sig:  ^Signal,
        done: ^bool,
    }

    spawn_val(&sched, proc(f: ^Fiber, env: Signal_Env) {
        signal_wait(f, env.sig)
        env.done^ = true
    }, Signal_Env{&sig, &w1_done})

    spawn_val(&sched, proc(f: ^Fiber, env: Signal_Env) {
        signal_wait(f, env.sig)
        env.done^ = true
    }, Signal_Env{&sig, &w2_done})

    spawn_val(&sched, proc(f: ^Fiber, env: Signal_Env) {
        signal_wait(f, env.sig)
        env.done^ = true
    }, Signal_Env{&sig, &w3_done})

    scheduler_step(&sched, 0.01)
    testing.expect(t, !w1_done)
    testing.expect(t, !w2_done)
    testing.expect(t, !w3_done)
    testing.expect_value(t, signal_waiter_count(&sig), 3)

    // Broadcast signal
    signal_emit(&sched, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect(t, w1_done)
    testing.expect(t, w2_done)
    testing.expect(t, w3_done)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}


// ============================================================================
// Test 87: Scope Cancellation Preserves Independent Entity Scopes
// ============================================================================

@(test)
test_scope_cancellation_preserves_independent_scopes :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope_a, scope_b: Fiber_Scope
    defer {
        scope_destroy(&sched, &scope_a)
        scope_destroy(&sched, &scope_b)
    }

    ran_a := false
    ran_b := false

    spawn_ptr(&sched, proc(f: ^Fiber, ran: ^bool) {
        wait(f, 0.05)
        ran^ = true
    }, &ran_a, scope = &scope_a)

    spawn_ptr(&sched, proc(f: ^Fiber, ran: ^bool) {
        wait(f, 0.05)
        ran^ = true
    }, &ran_b, scope = &scope_b)

    scheduler_step(&sched, 0.01)

    // Cancel Scope A only! Scope B must remain unaffected.
    cancelled_a := scope_cancel(&sched, &scope_a)
    testing.expect_value(t, cancelled_a, 1)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !ran_a)
    testing.expect(t, ran_b)
}


// ============================================================================
// Test 88: Interruption Race & Stun Auto-Recovery (Verse/Skookum Pattern)
// ============================================================================

@(test)
test_race_stun_interruption_and_recovery :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    stun_signal: Signal
    defer signal_destroy(&stun_signal)

    attacks_executed := 0
    stuns_handled := 0

    Combat_Actor :: struct {
        sched:            ^Scheduler,
        stun_sig:         ^Signal,
        attacks_executed: ^int,
        stuns_handled:    ^int,
    }

    actor := Combat_Actor{
        sched            = &sched,
        stun_sig         = &stun_signal,
        attacks_executed = &attacks_executed,
        stuns_handled    = &stuns_handled,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, a: ^Combat_Actor) {
        for _ in 0 ..< 2 {
            winner := race(f,
                branch(proc(f: ^Fiber, a: ^Combat_Actor) {
                    for {
                        a.attacks_executed^ += 1
                        wait(f, 0.05)
                    }
                }, a, name = "Attack Loop"),

                branch(proc(f: ^Fiber, sig: ^Signal) {
                    signal_wait(f, sig)
                }, a.stun_sig, name = "Stun Watcher"),
            )

            if winner == 1 {
                a.stuns_handled^ += 1
                wait(f, 0.02) // Stun duration
            }
        }
    }, &actor)

    // Run for a bit -> attacks execute
    scheduler_step(&sched, 0.06)
    testing.expect(t, attacks_executed >= 1)
    testing.expect_value(t, stuns_handled, 0)

    // Trip EMP/Stun signal: aborts attack branch in race and enters recovery!
    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, stuns_handled, 1)

    // Wait past stun recovery: loop restarts attack branch
    prev_attacks := attacks_executed
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect(t, attacks_executed > prev_attacks)
}


// ============================================================================
// Test 89: Scope Cancel Immediate Multi-Fiber Abort
// ============================================================================

@(test)
test_scope_cancel_immediate_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    combat_scope: Fiber_Scope
    defer scope_destroy(&sched, &combat_scope)

    combat_1_done := false
    combat_2_done := false
    movement_done := false

    spawn_ptr(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.1)
        done^ = true
    }, &combat_1_done, scope = &combat_scope)

    spawn_ptr(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.1)
        done^ = true
    }, &combat_2_done, scope = &combat_scope)

    spawn_ptr(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.05)
        done^ = true
    }, &movement_done) // Unscoped / Independent

    scheduler_step(&sched, 0.01)

    // Cancel all combat scope fibers
    cancelled := scope_cancel(&sched, &combat_scope)
    testing.expect_value(t, cancelled, 2)

    // Advance time
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    // Movement fiber finished normally; combat fibers were cancelled!
    testing.expect(t, movement_done)
    testing.expect(t, !combat_1_done)
    testing.expect(t, !combat_2_done)
}


// ============================================================================
// Test 90: Subscope Isolated Behavior Cancellation (Pattern B)
// ============================================================================

@(test)
test_subscope_isolated_behavior_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Monster :: struct {
        entity_scope: Fiber_Scope,
        attack_scope: Fiber_Scope,
        is_alive:     bool,
        attack_count: int,
    }

    m := Monster{is_alive = true}
    defer {
        scope_destroy(&sched, &m.entity_scope)
        scope_destroy(&sched, &m.attack_scope)
    }

    // Passive movement in entity scope
    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Monster) {
        for m.is_alive {
            wait(f, 0.02)
        }
    }, &m, scope = &m.entity_scope)

    // Attacks in attack subscope
    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Monster) {
        for m.is_alive {
            m.attack_count += 1
            wait(f, 0.05)
        }
    }, &m, scope = &m.attack_scope)

    scheduler_step(&sched, 0.06)
    testing.expect(t, m.attack_count >= 1)

    // Stun only attacks by cancelling attack_scope; entity_scope remains active!
    cancelled_attacks := scope_cancel(&sched, &m.attack_scope)
    testing.expect_value(t, cancelled_attacks, 1)

    // Entity scope is still running
    testing.expect(t, scope_is_busy(&m.entity_scope))
    testing.expect(t, !scope_is_busy(&m.attack_scope))
}


// ============================================================================
// Test 95: Cancel Fiber Waiting on Signal (signal_wait)
// ============================================================================

@(test)
test_cancel_fiber_waiting_on_signal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    h := spawn_ptr(&sched, proc(f: ^Fiber, sig: ^Signal) {
        signal_wait(f, sig)
    }, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 1)

    // Cancel the waiting fiber
    fiber_cancel(&sched, h)

    // Now emit the signal -> should execute cleanly without error
    signal_emit(&sched, &sig)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}


// ============================================================================
// Test 96: Cancel Fiber Waiting on Event (event_wait)
// ============================================================================

@(test)
test_cancel_fiber_waiting_on_event :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    received := 0
    Event_Test_Ctx :: struct {
        ev:       ^Event(int),
        received: ^int,
    }
    ctx := Event_Test_Ctx{ev = &ev, received = &received}

    h := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Event_Test_Ctx) {
        val, ok := event_wait(f, c.ev)
        if ok do c.received^ = val
    }, &ctx)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, event_waiter_count(&ev), 1)

    // Cancel the listener fiber
    fiber_cancel(&sched, h)

    // Emit event -> should cleanly ignore cancelled fiber
    event_emit(&sched, &ev, 999)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, event_waiter_count(&ev), 0)
}


// ============================================================================
// Test 97: Cancel Scope Inside Nested Sync Branches
// ============================================================================

@(test)
test_scope_cancel_inside_nested_sync :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    worker_scope: Fiber_Scope
    defer scope_destroy(&sched, &worker_scope)

    sync_completed := false
    branch1_done := false
    branch2_done := false

    spawn_ptr(&sched, proc(f: ^Fiber, done: ^bool) {
        sync(f,
            branch(proc(f: ^Fiber, d: ^bool) {
                wait(f, 0.5)
                d^ = true
            }, (^bool)(f.user_data), name = "Worker Branch 1"),
            branch(proc(f: ^Fiber, d: ^bool) {
                wait(f, 0.5)
                d^ = true
            }, (^bool)(f.user_data), name = "Worker Branch 2"),
        )
        done^ = true
    }, &sync_completed, scope = &worker_scope)

    scheduler_step(&sched, 0.01)

    // Cancel worker scope (cancels parent and both active sync children)
    cancelled := scope_cancel(&sched, &worker_scope)
    testing.expect_value(t, cancelled, 1)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect(t, !branch1_done)
    testing.expect(t, !branch2_done)
    testing.expect(t, !sync_completed)
}


// ============================================================================
// Test 98: Cancel Scope Inside Nested Race Branches
// ============================================================================

@(test)
test_scope_cancel_inside_nested_race :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    race_scope: Fiber_Scope
    defer scope_destroy(&sched, &race_scope)

    winner_idx := -99

    spawn_ptr(&sched, proc(f: ^Fiber, win: ^int) {
        idx := race(f,
            branch(proc(f: ^Fiber) { wait(f, 0.5) }, name = "Sub 1"),
            branch(proc(f: ^Fiber) { wait(f, 0.5) }, name = "Sub 2"),
        )
        win^ = idx
    }, &winner_idx, scope = &race_scope)

    scheduler_step(&sched, 0.01)

    // Cancel race scope
    cancelled := scope_cancel(&sched, &race_scope)
    testing.expect_value(t, cancelled, 1)
}


// ============================================================================
// Test 99: Fallback Resilience After Scope Cancellation
// ============================================================================

@(test)
test_fallback_resilience_after_scope_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    fb_scope: Fiber_Scope
    defer scope_destroy(&sched, &fb_scope)

    runs := 0
    fb_proc :: proc(f: ^Fiber, r: ^int) {
        for {
            succeeded, idx := fallback(f,
                branch(proc(f: ^Fiber) {
                    fail(f)
                }, name = "Option A"),
                branch(proc(f: ^Fiber, r: ^int) {
                    r^ += 1
                    wait(f, 0.05)
                }, r, name = "Option B"),
            )
            wait(f, 0.05)
        }
    }

    h := spawn_ptr(&sched, fb_proc, &runs, scope = &fb_scope)
    scheduler_step(&sched, 0.06)
    testing.expect(t, runs >= 1)

    // Cancel and restart (cancels both parent and active child branch)
    cancelled := scope_cancel(&sched, &fb_scope)
    testing.expect(t, cancelled >= 1)

    // Respawn
    spawn_ptr(&sched, fb_proc, &runs, scope = &fb_scope)
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.06)
    }

    testing.expect(t, runs >= 2)
}


// ============================================================================
// Test 100: Branch Name and Debug Tree Preservation
// ============================================================================

Name_Test_Result :: struct {
    branch1_name: string,
    branch2_name: string,
}

@(test)
test_branch_name_and_debug_tree_preservation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results := Name_Test_Result{}

    spawn_ptr(&sched, proc(f: ^Fiber, res: ^Name_Test_Result) {
        sync(f,
            branch(proc(f: ^Fiber, res: ^Name_Test_Result) {
                res.branch1_name = f.debug_name
                wait(f, 0.1)
            }, res, name = "First Worker Branch"),
            branch(proc(f: ^Fiber, res: ^Name_Test_Result) {
                res.branch2_name = f.debug_name
                wait(f, 0.1)
            }, res, name = "Second Worker Branch"),
        )
    }, &results)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, results.branch1_name, "First Worker Branch")
    testing.expect_value(t, results.branch2_name, "Second Worker Branch")
}


// ============================================================================
// Test 102: Signal Multicast Cascade with Pruned Waiters
// ============================================================================

@(test)
test_signal_multicast_cascade_with_dynamic_waiters :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    Signal_Cascade_Ctx :: struct {
        sig:   ^Signal,
        count: ^int,
    }

    woken_count := 0
    ctxs: [8]Signal_Cascade_Ctx
    handles: [8]Fiber_Handle

    for i in 0 ..< 8 {
        ctxs[i] = Signal_Cascade_Ctx{sig = &sig, count = &woken_count}
        handles[i] = spawn_ptr(&sched, proc(f: ^Fiber, c: ^Signal_Cascade_Ctx) {
            signal_wait(f, c.sig)
            c.count^ += 1
        }, &ctxs[i])
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 8)

    // Abort 3 waiters before signal emission
    fiber_cancel(&sched, handles[1])
    fiber_cancel(&sched, handles[3])
    fiber_cancel(&sched, handles[5])

    // Emit the signal -> remaining 5 fibers should wake cleanly
    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, woken_count, 5)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}


// ============================================================================
// Test 103: Bottom-Up Guaranteed Cleanup on Deep Hierarchy Abort
// ============================================================================

Cleanup_Tracker :: struct {
    parent_cleaned:      bool,
    child_cleaned:       bool,
    grandchild_cleaned:  bool,
}

@(test)
test_fiber_set_cleanup_deep_hierarchy_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    tracker := Cleanup_Tracker{}

    parent_h := spawn_ptr(&sched, proc(f: ^Fiber, tr: ^Cleanup_Tracker) {
        fiber_set_cleanup(f, proc(user_data: rawptr) {
            t := (^Cleanup_Tracker)(user_data)
            t.parent_cleaned = true
        }, tr)

        sync(f,
            branch(proc(f: ^Fiber, tr: ^Cleanup_Tracker) {
                fiber_set_cleanup(f, proc(user_data: rawptr) {
                    t := (^Cleanup_Tracker)(user_data)
                    t.child_cleaned = true
                }, tr)

                sync(f,
                    branch(proc(f: ^Fiber, tr: ^Cleanup_Tracker) {
                        fiber_set_cleanup(f, proc(user_data: rawptr) {
                            t := (^Cleanup_Tracker)(user_data)
                            t.grandchild_cleaned = true
                        }, tr)
                        wait(f, 10.0)
                    }, tr, name = "Grandchild"),
                )
            }, tr, name = "Child"),
        )
    }, &tracker)

    scheduler_step(&sched, 0.01)

    // Abort the top-level parent -> cleans up grandchild, child, and parent
    fiber_cancel(&sched, parent_h)

    testing.expect(t, tracker.grandchild_cleaned)
    testing.expect(t, tracker.child_cleaned)
    testing.expect(t, tracker.parent_cleaned)
}


// ============================================================================
// Test 106: Event Multicast with Dead Listener Pruning
// ============================================================================

@(test)
test_event_multicast_dynamic_subscribe_during_emit :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(string)
    event_init(&ev)
    defer event_destroy(&ev)

    Event_Multi_Ctx :: struct {
        ev:    ^Event(string),
        count: ^int,
    }

    received_count := 0
    ctxs: [6]Event_Multi_Ctx
    handles: [6]Fiber_Handle

    for i in 0 ..< 6 {
        ctxs[i] = Event_Multi_Ctx{ev = &ev, count = &received_count}
        handles[i] = spawn_ptr(&sched, proc(f: ^Fiber, c: ^Event_Multi_Ctx) {
            msg, ok := event_wait(f, c.ev)
            if ok && msg == "PULSE" {
                c.count^ += 1
            }
        }, &ctxs[i])
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, event_waiter_count(&ev), 6)

    // Cancel 2 listeners
    fiber_cancel(&sched, handles[0])
    fiber_cancel(&sched, handles[4])

    // Emit event
    event_emit(&sched, &ev, "PULSE")
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, received_count, 4)
    testing.expect_value(t, event_waiter_count(&ev), 0)
}


// ============================================================================
// Test 109: Prewarm Slab Allocation and Dynamic Slab Recycling Invariants
// ============================================================================

@(test)
test_scheduler_prewarm_slab_expansion_under_load :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Pre-warm 32 fibers
    scheduler_prewarm(&sched, 32)
    stats1 := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats1.total_stacks, 32)
    testing.expect_value(t, stats1.active_fibers, 0)
    testing.expect_value(t, stats1.free_fibers, 32)

    // Spawn 40 fibers (exceeds 32 -> triggers dynamic 2nd slab allocation)
    for _ in 0 ..< 40 {
        spawn(&sched, proc(f: ^Fiber) {
            wait(f, 0.02)
        })
    }

    scheduler_step(&sched, 0.005)
    stats2 := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats2.total_stacks, 64)
    testing.expect_value(t, stats2.active_fibers, 40)
    testing.expect_value(t, stats2.slabs_count, 2)

    // Let all 40 finish
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    stats3 := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats3.active_fibers, 0)
    testing.expect_value(t, stats3.free_fibers, 64)
}


// ============================================================================
// Test 110: Composite Fallback & Rush Coordination with Branch Interruption
// ============================================================================

@(test)
test_rush_and_fallback_with_signal_interruption :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    interrupt_sig: Signal
    defer signal_destroy(&interrupt_sig)

    outcome := "INITIAL"

    Interrupt_Ctx :: struct {
        sig: ^Signal,
        out: ^string,
    }

    ctx := Interrupt_Ctx{sig = &interrupt_sig, out = &outcome}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Interrupt_Ctx) {
        // Fallback strategy: try fast rush first; if interrupted, fallback to safe recovery
        succeeded, fb_idx := fallback(f,
            // Option 1: Rush between two fast paths raced against interrupt signal
            branch(proc(f: ^Fiber, c: ^Interrupt_Ctx) {
                winner := race(f,
                    branch(proc(f: ^Fiber) {
                        winner_rush := rush(f,
                            branch(proc(f: ^Fiber) { wait(f, 0.5) }, name = "Slow path 1"),
                            branch(proc(f: ^Fiber) { wait(f, 0.5) }, name = "Slow path 2"),
                        )
                        if winner_rush < 0 do fail(f)
                    }, name = "Inner Rush"),
                    branch(proc(f: ^Fiber, sig: ^Signal) {
                        signal_wait(f, sig)
                    }, c.sig, name = "Interrupt Watcher"),
                )
                if winner == 1 {
                    fail(f) // Interrupted -> fail to trigger fallback!
                } else {
                    c.out^ = "RUSH_WON"
                }
            }, c, name = "Composite Rush"),

            // Option 2: Fallback safe recovery
            branch(proc(f: ^Fiber, c: ^Interrupt_Ctx) {
                c.out^ = "FALLBACK_RECOVERY"
            }, c, name = "Safe Recovery"),
        )
    }, &ctx)

    scheduler_step(&sched, 0.01)

    // Trip interrupt signal to force fallback recovery
    signal_emit(&sched, &interrupt_sig)

    // Step scheduler to allow fallback recovery
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, outcome, "FALLBACK_RECOVERY")
}


// ============================================================================
// Test 116: Scheduler Watchdog Configuration & Dynamic Adjustments
// ============================================================================

@(test)
test_watchdog_configuration_and_disable :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    testing.expect_value(t, sched.watchdog_max_slice_ms, 100.0)

    // Adjust watchdog
    scheduler_set_watchdog(&sched, enabled = false, max_slice_ms = 50.0)
    testing.expect(t, !sched.watchdog_enabled)
    testing.expect_value(t, sched.watchdog_max_slice_ms, 50.0)

    scheduler_set_watchdog(&sched, enabled = true, max_slice_ms = 250.0)
    testing.expect(t, sched.watchdog_enabled)
    testing.expect_value(t, sched.watchdog_max_slice_ms, 250.0)
}


// ============================================================================
// Test 119: Scope Destruction Prevents Stale Entity Pointer Access
// ============================================================================

Test_Monster :: struct {
    hp:    int,
    scope: Fiber_Scope,
}

@(test)
test_scope_destroy_prevents_stale_pointer_access :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    monster := new(Test_Monster)
    monster.hp = 100

    touched_after_death := false

    Monster_Attack_Ctx :: struct {
        m:       ^Test_Monster,
        touched: ^bool,
    }

    ctx := Monster_Attack_Ctx{m = monster, touched = &touched_after_death}

    // Fiber bound to monster.scope
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Monster_Attack_Ctx) {
        wait(f, 0.1)
        // If not cancelled, touches memory:
        c.m.hp = 0
        c.touched^ = true
    }, &ctx, scope = &monster.scope)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, scope_active_count(&monster.scope), 1)

    // Monster dies after 0.02s -> scope destroyed
    scope_destroy(&sched, &monster.scope)
    free(monster) // Memory wiped!

    // Advance time past 0.1s
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    // Fiber was cancelled on scope_destroy and never touched dead monster!
    testing.expect(t, !touched_after_death)
}


// ============================================================================
// Test 120: Fiber Temporary Allocator Memory Isolation
// ============================================================================

@(test)
test_temp_allocator_isolation_invariants :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    f1_alloc_ok := false
    f2_alloc_ok := false

    spawn_ptr(&sched, proc(f: ^Fiber, ok: ^bool) {
        data := make([]byte, 1024, context.temp_allocator)
        for i in 0 ..< len(data) do data[i] = 0xAA
        wait(f, 0.02)
        // Verify contents unchanged
        all_valid := true
        for b in data do if b != 0xAA do all_valid = false
        ok^ = all_valid
    }, &f1_alloc_ok)

    spawn_ptr(&sched, proc(f: ^Fiber, ok: ^bool) {
        data := make([]byte, 2048, context.temp_allocator)
        for i in 0 ..< len(data) do data[i] = 0xBB
        wait(f, 0.02)
        all_valid := true
        for b in data do if b != 0xBB do all_valid = false
        ok^ = all_valid
    }, &f2_alloc_ok)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, f1_alloc_ok)
    testing.expect(t, f2_alloc_ok)
}


// ============================================================================
// Test 124: Multicast Event Broadcast (Event(T))
// ============================================================================

@(test)
test_event_multicast_broadcast_and_clear :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    woken_count := 0

    // Spawn 3 waiting fibers
    for _ in 0 ..< 3 {
        spawn_ptr(&sched, proc(f: ^Fiber, p: ^struct { ev: ^Event(int), count: ^int }) {
            val, ok := event_wait(f, p.ev)
            if ok && val == 42 {
                p.count^ += 1
            }
        }, &struct { ev: ^Event(int), count: ^int }{ &ev, &woken_count })
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 0)
    testing.expect_value(t, event_waiter_count(&ev), 3)

    // Broadcast event
    event_emit(&sched, &ev, 42)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 3)
    testing.expect_value(t, event_waiter_count(&ev), 0)
}


// ============================================================================
// Test 125: Generational Handle History Capacity (>256 slots)
// ============================================================================

@(test)
test_generational_handle_history_capacity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    handles: [300]Fiber_Handle

    // Rapidly spawn and complete 300 fibers
    for i in 0 ..< 300 {
        handles[i] = spawn_nil(&sched, proc(f: ^Fiber) {
            // Immediate completion
        })
    }

    // Step once to complete all
    scheduler_step(&sched, 0.01)

    // Verify all 300 handles record .Completed correctly in history
    for h, i in handles {
        status, found := fiber_status(&sched, h)
        testing.expect(t, found, "Handle must be found in extended history")
        testing.expect_value(t, status, Fiber_Status.Completed)
    }
}


// ============================================================================
// Test 130: Generic Hierarchy Tree Traversal (scheduler_walk_tree)
// ============================================================================

@(test)
test_scheduler_walk_tree_traversal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Spawn a root with 2 children via sync
    spawn_nil(&sched, proc(f: ^Fiber) {
        sync(f,
            branch(proc(f: ^Fiber) { wait(f, 0.05) }, name = "Child A"),
            branch(proc(f: ^Fiber) { wait(f, 0.05) }, name = "Child B"),
        )
    }, name = "Root Fiber")

    // Run 1 frame so children are spawned and attached to tree
    scheduler_step(&sched, 0.01)

    Tree_Record :: struct {
        name:  string,
        depth: int,
    }
    visited := make([dynamic]Tree_Record, context.temp_allocator)

    scheduler_walk_tree(&sched, proc(f: ^Fiber, depth: int, user_data: rawptr) {
        list := cast(^[dynamic]Tree_Record)user_data
        name := f.debug_name != "" ? f.debug_name : "Fiber"
        append(list, Tree_Record{name = name, depth = depth})
    }, &visited)

    // Root (depth 0), Child A (depth 1), Child B (depth 1)
    testing.expect_value(t, len(visited), 3)
    testing.expect_value(t, visited[0].name, "Root Fiber")
    testing.expect_value(t, visited[0].depth, 0)
    testing.expect_value(t, visited[1].name, "Child A")
    testing.expect_value(t, visited[1].depth, 1)
    testing.expect_value(t, visited[2].name, "Child B")
    testing.expect_value(t, visited[2].depth, 1)
}


// ============================================================================
// Test 132: Structured Task Preemption via race and Signal
// ============================================================================

@(test)
test_structured_task_preemption_via_race_and_signal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    task_completed := false
    was_cancelled := false

    Spawn_Ctx :: struct {
        sig:       ^Signal,
        completed: ^bool,
        cancelled: ^bool,
    }
    ctx := Spawn_Ctx{sig = &sig, completed = &task_completed, cancelled = &was_cancelled}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
        winner := race(f,
            branch(proc(f: ^Fiber, comp: ^bool) {
                wait(f, 0.10)
                comp^ = true
            }, c.completed, name = "Long Task"),

            branch(proc(f: ^Fiber, sig: ^Signal) {
                signal_wait(f, sig)
            }, c.sig, name = "Signal Watcher"),
        )

        c.cancelled^ = (winner == 1)
    }, &ctx)

    // Step 0.02s
    for _ in 0 ..< 2 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !task_completed)
    testing.expect(t, !was_cancelled)

    // Trigger signal mid-task
    signal_emit(&sched, &sig)

    // Step to let race resolve
    scheduler_step(&sched, 0.01)

    testing.expect(t, was_cancelled)
    testing.expect(t, !task_completed)
}


// ============================================================================
// Test 137: Dynamic Fiber Renaming (fiber_set_name & fiber_name)
// ============================================================================

@(test)
test_fiber_dynamic_renaming :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    recorded_names: [dynamic]string
    defer delete(recorded_names)

    spawn_ptr(&sched, proc(f: ^Fiber, names: ^[dynamic]string) {
        append(names, fiber_name(f))

        fiber_set_name(f, "Phase 2: Nova Charge")
        append(names, fiber_name(f))

        fiber_set_name(f, "Phase 3: Enraged")
        append(names, fiber_name(f))
    }, &recorded_names, name = "Phase 1: Patrol")

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, len(recorded_names), 3)
    testing.expect_value(t, recorded_names[0], "Phase 1: Patrol")
    testing.expect_value(t, recorded_names[1], "Phase 2: Nova Charge")
    testing.expect_value(t, recorded_names[2], "Phase 3: Enraged")
}


// ============================================================================
// Test 139: PLAN 5 Packed Generational Handles Bitwise Operations
// ============================================================================

@(test)
test_plan5_packed_generational_handles_bitwise :: proc(t: ^testing.T) {
    // 1. Pack index 0, gen 1
    h1 := fiber_handle_pack(0, 1)
    testing.expect_value(t, fiber_handle_index(h1), 0)
    testing.expect_value(t, fiber_handle_gen(h1), 1)

    // 2. Pack index 512, gen 42
    h2 := fiber_handle_pack(512, 42)
    testing.expect_value(t, fiber_handle_index(h2), 512)
    testing.expect_value(t, fiber_handle_gen(h2), 42)

    // 3. Max boundaries: index 65535, gen 65535
    h_max := fiber_handle_pack(65535, 65535)
    testing.expect_value(t, fiber_handle_index(h_max), 65535)
    testing.expect_value(t, fiber_handle_gen(h_max), 65535)
    testing.expect_value(t, u32(h_max), 0xFFFF_FFFF)
}


// ============================================================================
// Test 140: PLAN 5 Handle Slot Reuse and ABA Invalidation Safety
// ============================================================================

@(test)
test_plan5_handle_slot_reuse_and_aba_safety :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Spawn fiber 1
    h1 := spawn_nil(&sched, proc(f: ^Fiber) {
        // Runs and finishes
    })

    idx1 := fiber_handle_index(h1)
    gen1 := fiber_handle_gen(h1)

    testing.expect(t, fiber_is_alive(&sched, h1))
    scheduler_step(&sched, 0.01) // Run to completion & recycle

    testing.expect(t, !fiber_is_alive(&sched, h1))
    status1, ok1 := fiber_status(&sched, h1)
    testing.expect(t, ok1)
    testing.expect_value(t, status1, Fiber_Status.Completed)

    // Spawn fiber 2: must reuse the exact same slot index with an incremented generation!
    h2 := spawn_nil(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    })

    idx2 := fiber_handle_index(h2)
    gen2 := fiber_handle_gen(h2)

    testing.expect_value(t, idx2, idx1)
    testing.expect_value(t, gen2, gen1 + 1)

    // Stale handle h1 must NOT be alive and fiber_find_by_handle must return nil for h1
    testing.expect(t, !fiber_is_alive(&sched, h1))
    testing.expect(t, fiber_find_by_handle(&sched, h1) == nil)

    // Active handle h2 must be alive and fiber_find_by_handle must find it in O(1)
    testing.expect(t, fiber_is_alive(&sched, h2))
    f2 := fiber_find_by_handle(&sched, h2)
    testing.expect(t, f2 != nil)
    testing.expect_value(t, f2.handle, h2)
}


// ============================================================================
// Test 141: Intrusive Wait_Queue Zero-Allocation Doubly-Linked Operations
// ============================================================================

@(test)
test_plan5_intrusive_wait_queue_operations :: proc(t: ^testing.T) {
    // 1. True ZII: default zero-initialized struct is immediately ready
    q: Wait_Queue
    testing.expect(t, wait_queue_is_empty(&q))
    testing.expect_value(t, wait_queue_count(&q), 0)

    dummy_fibers: [10]Fiber
    for i in 0 ..< 10 {
        dummy_fibers[i].handle = fiber_handle_pack(u16(i), 1)
    }

    // 2. Push 10 fibers to tail (unbounded, 100% zero-allocation)
    for i in 0 ..< 10 {
        wait_queue_push_back(&q, &dummy_fibers[i])
    }
    testing.expect(t, !wait_queue_is_empty(&q))
    testing.expect_value(t, wait_queue_count(&q), 10)
    testing.expect_value(t, q.head, &dummy_fibers[0])
    testing.expect_value(t, q.tail, &dummy_fibers[9])

    // 3. Remove Head node (&dummy_fibers[0]) in O(1) in-place
    removed_head := wait_queue_remove(&q, &dummy_fibers[0])
    testing.expect(t, removed_head)
    testing.expect_value(t, wait_queue_count(&q), 9)
    testing.expect_value(t, q.head, &dummy_fibers[1])
    testing.expect(t, dummy_fibers[0].next_waiter == nil)
    testing.expect(t, dummy_fibers[0].prev_waiter == nil)

    // 4. Remove Middle node (&dummy_fibers[5]) in O(1) in-place
    removed_mid := wait_queue_remove(&q, &dummy_fibers[5])
    testing.expect(t, removed_mid)
    testing.expect_value(t, wait_queue_count(&q), 8)
    testing.expect(t, dummy_fibers[5].next_waiter == nil)
    testing.expect(t, dummy_fibers[5].prev_waiter == nil)

    // 5. Remove Tail node (&dummy_fibers[9]) in O(1) in-place
    removed_tail := wait_queue_remove(&q, &dummy_fibers[9])
    testing.expect(t, removed_tail)
    testing.expect_value(t, wait_queue_count(&q), 7)
    testing.expect_value(t, q.tail, &dummy_fibers[8])
    testing.expect(t, dummy_fibers[9].next_waiter == nil)
    testing.expect(t, dummy_fibers[9].prev_waiter == nil)

    // 6. Pop remaining elements in exact FIFO order: 1, 2, 3, 4, 6, 7, 8
    expected_order := [7]^Fiber{
        &dummy_fibers[1],
        &dummy_fibers[2],
        &dummy_fibers[3],
        &dummy_fibers[4],
        &dummy_fibers[6],
        &dummy_fibers[7],
        &dummy_fibers[8],
    }
    for expected in expected_order {
        f, ok := wait_queue_pop_front(&q)
        testing.expect(t, ok)
        testing.expect_value(t, f, expected)
        testing.expect(t, f.next_waiter == nil)
        testing.expect(t, f.prev_waiter == nil)
    }
    testing.expect(t, wait_queue_is_empty(&q))
    testing.expect_value(t, wait_queue_count(&q), 0)
    testing.expect(t, q.head == nil)
    testing.expect(t, q.tail == nil)
}


// ============================================================================
// Test 142: PLAN 5 O(1) Generational Lookups Under High Fiber Load
// ============================================================================

@(test)
test_plan5_o1_handle_lookups_under_high_fiber_load :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Prewarm and spawn 256 fibers
    FIBER_COUNT :: 256
    handles: [FIBER_COUNT]Fiber_Handle

    for i in 0 ..< FIBER_COUNT {
        handles[i] = spawn_nil(&sched, proc(f: ^Fiber) {
            wait(f, 100.0)
        })
    }

    scheduler_step(&sched, 0.01)

    // Verify all 256 fibers can be looked up instantly in O(1) time
    for h in handles {
        f := fiber_find_by_handle(&sched, h)
        testing.expect(t, f != nil)
        testing.expect_value(t, f.handle, h)
        testing.expect(t, fiber_is_alive(&sched, h))
        slot := fiber_handle_index(h)
        testing.expect_value(t, sched.fiber_pool.all_fibers[slot].handle, h)
    }

    // Cancel even-indexed fibers (128 fibers)
    for i := 0; i < FIBER_COUNT; i += 2 {
        fiber_cancel(&sched, handles[i])
        testing.expect(t, !fiber_is_alive(&sched, handles[i]))
        testing.expect(t, fiber_find_by_handle(&sched, handles[i]) == nil)
    }

    // Odd-indexed fibers must remain alive and instant to find
    for i := 1; i < FIBER_COUNT; i += 2 {
        testing.expect(t, fiber_is_alive(&sched, handles[i]))
        f := fiber_find_by_handle(&sched, handles[i])
        testing.expect(t, f != nil)
        testing.expect_value(t, f.handle, handles[i])
    }
}


// ============================================================================
// Test 143: PLAN 5 Config Constants & Static Bounds Integration
// ============================================================================

@(test)
test_plan5_config_constants_integration :: proc(t: ^testing.T) {
    testing.expect(t, STACK_SIZE >= 16 * 1024)
    testing.expect_value(t, STACK_SIZE % 16, 0)
    testing.expect(t, STACKS_PER_SLAB >= 1)
    testing.expect(t, PAYLOAD_SIZE >= 64)
    testing.expect(t, TEMP_ARENA_SIZE >= 1024)
    testing.expect_value(t, CANARY_SIZE, 64)
    testing.expect_value(t, u64(CANARY_MAGIC), 0xDEAD_BEEF_CAFE_BABE)
    testing.expect_value(t, HANDLE_HISTORY_CAPACITY, 2048)
}


// ============================================================================
// Test 144: Wait_Queue Auto-Unlinking on Fiber Abort (Queue Preserved)
// ============================================================================

@(test)
test_wait_queue_auto_unlinking_on_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    // Fiber 1 waits on sig
    h1 := spawn_ptr(&sched, proc(f: ^Fiber, sig: ^Signal) {
        signal_wait(f, sig)
    }, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 1)

    // Abort Fiber 1
    fiber_cancel(&sched, h1)

    // Wait_Queue must be automatically unlinked and empty!
    testing.expect_value(t, signal_waiter_count(&sig), 0)

    // Fiber 2 now waits on sig
    f2_woken := false
    spawn_ptr(&sched, proc(f: ^Fiber, env: ^struct { sig: ^Signal, woken: ^bool }) {
        signal_wait(f, env.sig)
        env.woken^ = true
    }, &struct { sig: ^Signal, woken: ^bool }{&sig, &f2_woken})

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 1)
    testing.expect(t, !f2_woken)

    // Trigger signal -> Fiber 2 must wake cleanly!
    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)
    testing.expect(t, f2_woken)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}


// ============================================================================
// Test 145: Scope-Based Multi-Cycle EMP Stun and Recovery
// ============================================================================

@(test)
test_scope_multi_cycle_emp_stun_and_recovery :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sentry_scope: Fiber_Scope
    defer scope_destroy(&sched, &sentry_scope)

    // Cycle 1: Spawn 4 sentries under sentry_scope
    sentries_active := 0
    for _ in 0 ..< 4 {
        spawn_ptr(&sched, proc(f: ^Fiber, count: ^int) {
            count^ += 1
            wait(f, 10.0) // Long patrol
        }, &sentries_active, scope = &sentry_scope)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, sentries_active, 4)
    testing.expect_value(t, scope_active_count(&sentry_scope), 4)

    // Fire EMP disruption: cancel entire sentry scope!
    cancelled := scope_cancel(&sched, &sentry_scope)
    testing.expect_value(t, cancelled, 4)
    testing.expect_value(t, scope_active_count(&sentry_scope), 0)

    // Cycle 2: Respawn clean sentries under the same scope
    sentries_cycle2 := 0
    for _ in 0 ..< 4 {
        spawn_ptr(&sched, proc(f: ^Fiber, count: ^int) {
            count^ += 1
            wait(f, 0.05)
        }, &sentries_cycle2, scope = &sentry_scope)
    }

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect_value(t, sentries_cycle2, 4)
}


// ============================================================================
// Test 146: Interruption Race & Attack Recovery Loop (Signal + Race)
// ============================================================================

@(test)
test_interruption_race_attack_recovery_loop :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    stun_signal: Signal
    defer signal_destroy(&stun_signal)

    Env :: struct {
        shots_fired: int,
        stuns:       int,
        running:     bool,
        stun_sig:    ^Signal,
    }

    env := Env{running = true, stun_sig = &stun_signal}

    spawn_ptr(&sched, proc(f: ^Fiber, e: ^Env) {
        for e.running {
            winner := race(f,
                branch(proc(f: ^Fiber, e: ^Env) {
                    for {
                        e.shots_fired += 1
                        wait(f, 0.05)
                    }
                }, e, name = "Shot Loop"),

                branch(proc(f: ^Fiber, sig: ^Signal) {
                    signal_wait(f, sig)
                }, e.stun_sig, name = "Stun Watcher"),
            )

            if winner == 1 && e.running {
                e.stuns += 1
                wait(f, 0.1) // Stun duration
            }
        }
    }, &env)

    // Step to let shots fire (advance multiple frames)
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect(t, env.shots_fired >= 2)
    testing.expect_value(t, env.stuns, 0)

    // Pulse 1: EMP Stun Signal!
    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, env.stuns, 1)

    // Wait out stun duration (0.1s)
    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.05)
    }
    shots_after_stun1 := env.shots_fired

    // Step further: Attacks must have resumed!
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect(t, env.shots_fired > shots_after_stun1)

    // Pulse 2: Second EMP Stun Signal!
    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, env.stuns, 2)

    env.running = false
}


// ============================================================================
// Test 155: with_timeout By-Value Inline Payload Branching
// ============================================================================

@(test)
test_with_timeout_by_value_branching :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Timeout_Test_Ctx :: struct {
        t:         ^testing.T,
        completed: bool,
    }
    ctx := Timeout_Test_Ctx{t = t}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Timeout_Test_Ctx) {
        // Fast task finishes before 0.1s timeout
        to1 := with_timeout(f, 0.1, proc(f: ^Fiber) {
            wait(f, 0.02)
        }, "Fast Task")
        testing.expect(c.t, !to1)

        // Slow task times out after 0.02s
        to2 := with_timeout(f, 0.02, proc(f: ^Fiber) {
            wait(f, 0.2)
        }, "Slow Task")
        testing.expect(c.t, to2)

        c.completed = true
    }, &ctx)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect(t, ctx.completed)
}


// ============================================================================
// Test 156: fiber_calc_stack_usage Canary Watermark Breach Detection
// ============================================================================

@(test)
test_fiber_calc_stack_usage_canary_breach_detection :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    f := fiber_pool_acquire(&sched.fiber_pool)
    defer {
        // Restore canary before recycle to satisfy panic assert
        fiber_init_canary(f)
        fiber_pool_recycle(&sched.fiber_pool, f)
    }

    used, total := fiber_calc_stack_usage(f)
    testing.expect_value(t, total, f.stack_size)
    testing.expect(t, used < total)

    // Intentionally corrupt canary watermark
    canary_ptr := ([^]u64)(f.stack_base)
    canary_ptr[0] = 0xDEADBEEFCAFE1234

    // Profiler must immediately detect breached watermark and report 100% stack consumption!
    breached_used, breached_total := fiber_calc_stack_usage(f)
    testing.expect_value(t, breached_used, breached_total)
    testing.expect_value(t, breached_total, f.stack_size)
}


// ============================================================================
// Test 162: Intrusive Doubly-Linked Fiber_Scope Zero-Allocation Lifecycle
// ============================================================================

@(test)
test_intrusive_fiber_scope_lifecycle :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // True ZII declaration - zero allocation
    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)

    f1_done := false
    f2_done := false
    f3_done := false

    // Spawn 3 fibers attached to scope
    spawn_ptr(&sched, proc(f: ^Fiber, d: ^bool) {
        wait(f, 0.02)
        d^ = true
    }, &f1_done, scope = &scope, name = "Fiber 1")

    spawn_ptr(&sched, proc(f: ^Fiber, d: ^bool) {
        wait(f, 0.04)
        d^ = true
    }, &f2_done, scope = &scope, name = "Fiber 2")

    spawn_ptr(&sched, proc(f: ^Fiber, d: ^bool) {
        wait(f, 0.06)
        d^ = true
    }, &f3_done, scope = &scope, name = "Fiber 3")

    testing.expect_value(t, scope_active_count(&scope), 3)
    testing.expect_value(t, scope_is_busy(&scope), true)
    testing.expect_value(t, scope_is_empty(&scope), false)

    // Step 1: fibers start and enter sleep
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, f1_done, false)
    testing.expect_value(t, scope_active_count(&scope), 3)

    // Step 2: 0.03s -> total 0.04s >= 0.03s wake time -> Fiber 1 finishes naturally and unlinks in O(1)
    scheduler_step(&sched, 0.03)
    testing.expect_value(t, f1_done, true)
    testing.expect_value(t, f2_done, false)
    testing.expect_value(t, f3_done, false)
    testing.expect_value(t, scope_active_count(&scope), 2)

    // Cancel remaining 2 fibers mid-flight
    cancelled := scope_cancel(&sched, &scope)
    testing.expect_value(t, cancelled, 2)
    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
    testing.expect(t, scope.head == nil)
    testing.expect(t, scope.tail == nil)

    // Step further: canceled fibers should never execute finish callbacks
    scheduler_step(&sched, 0.10)
    testing.expect_value(t, f2_done, false)
    testing.expect_value(t, f3_done, false)
}


// ============================================================================
// Test 167: Fiber Cleanup Callback Preserves User Data
// ============================================================================

@(test)
test_fiber_cleanup_preserves_user_data :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    entry_data := 777
    cleanup_called := false
    cleanup_received_val := 0
    entry_read_val := 0

    Cleanup_Context :: struct {
        called: ^bool,
        out:    ^int,
        val:    int,
    }
    cctx := Cleanup_Context{called = &cleanup_called, out = &cleanup_received_val, val = 999}

    Worker_Context :: struct {
        data_in:  ^int,
        data_out: ^int,
    }
    wctx := Worker_Context{data_in = &entry_data, data_out = &entry_read_val}

    worker_h := spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Worker_Context) {
        ctx.data_out^ = ctx.data_in^
    }, &wctx, name = "Clean Worker")

    if fiber := fiber_find_by_handle(&sched, worker_h); fiber != nil {
        fiber_set_cleanup(fiber, proc(user_data: rawptr) {
            ctx := (^Cleanup_Context)(user_data)
            ctx.called^ = true
            ctx.out^ = ctx.val
        }, &cctx)
    }

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, entry_read_val, 777)
    testing.expect_value(t, cleanup_called, true)
    testing.expect_value(t, cleanup_received_val, 999)
    testing.expect_value(t, entry_data, 777)
}


// ============================================================================
// Test 169: Scheduler Destroy External Scope Detachment Safety
// ============================================================================

@(test)
test_scheduler_destroy_scope_detachment :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)

    scope: Fiber_Scope

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    }, scope = &scope, name = "Scoped Fiber 1")

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    }, scope = &scope, name = "Scoped Fiber 2")

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    }, scope = &scope, name = "Scoped Fiber 3")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, scope_active_count(&scope), 3)

    // Destroy scheduler while scope has active fibers
    scheduler_destroy(&sched)

    // Scope must be completely detached and zeroed
    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
    testing.expect(t, scope.head == nil)
    testing.expect(t, scope.tail == nil)
}


// ============================================================================
// Test 170: Ready Queue Generational Handle ABA & Pointer Recycling Guard
// ============================================================================

@(test)
test_ready_queue_generational_aba_guard :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    exec_counts := [3]int{0, 0, 0}

    // Spawn fiber 1: will run first, cancel fiber 2, and spawn fiber 3 (which reuses fiber 2's pool slot)
    Spawn_Ctx :: struct {
        sched:       ^Scheduler,
        counts:      ^[3]int,
        target_h:    Fiber_Handle,
    }

    ctx := Spawn_Ctx{
        sched  = &sched,
        counts = &exec_counts,
    }

    // Fiber 1
    h1 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
        c.counts[0] += 1
        // Cancel fiber 2 which is sitting in the ready queue after fiber 1
        fiber_cancel(c.sched, c.target_h)
        // Immediately spawn fiber 3 - will acquire the recycled slot of fiber 2
        spawn_ptr(c.sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
            c.counts[2] += 1
        }, c, name = "Spawned Replacement Fiber 3")
    }, &ctx, name = "Fiber 1")

    // Fiber 2 (queued right after fiber 1)
    h2 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
        c.counts[1] += 1
    }, &ctx, name = "Fiber 2")

    ctx.target_h = h2

    // Step scheduler: fiber 1 executes, cancels fiber 2, and spawns fiber 3.
    // Fiber 2's stale ready queue slot must be safely skipped, and fiber 3 must run exactly once!
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, exec_counts[0], 1) // Fiber 1 ran once
    testing.expect_value(t, exec_counts[1], 0) // Fiber 2 was canceled and never ran
    testing.expect_value(t, exec_counts[2], 1) // Fiber 3 ran exactly once (no double execution!)
}


// ============================================================================
// Test 177: Race Join Coordinator Independent Sibling Non-Interference
// ============================================================================

@(test)
test_race_join_independent_sibling_non_interference :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    independent_child_completed := false
    race_winner := -1

    Sibling_Ctx :: struct {
        indep_completed: ^bool,
        winner:          ^int,
    }
    ctx := Sibling_Ctx{
        indep_completed = &independent_child_completed,
        winner          = &race_winner,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Sibling_Ctx) {
        // 1. Spawn independent child fiber that should NOT be aborted by subsequent race
        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.debug_name = "Independent Child"
        child.stored_context = context
        child.user_data = rawptr(c.indep_completed)
        child.entry_proc = proc(cf: ^Fiber, ud: rawptr) {
            wait(cf, 0.1) // Sleeps longer than race
            flag := (^bool)(ud)
            flag^ = true
        }
        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child.handle)

        // 2. Run race between two short branches
        w := race(f,
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.01) // Wins fast
            }, name = "Fast Branch"),
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.5) // Loses
            }, name = "Slow Branch"),
        )
        c.winner^ = w

        // 3. Wait for the independent child to finish
        wait(f, 0.15)
    }, &ctx, name = "Parent Runner")

    // Run simulation
    for _ in 0 ..< 20 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, race_winner, 0)
    testing.expect_value(t, independent_child_completed, true)
}


// ============================================================================
// Test 178: Rush Join Coordinator Independent Sibling Non-Interference
// ============================================================================

@(test)
test_rush_join_independent_sibling_non_interference :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    independent_child_completed := false
    rush_winner := -1

    Sibling_Ctx :: struct {
        indep_completed: ^bool,
        winner:          ^int,
    }
    ctx := Sibling_Ctx{
        indep_completed = &independent_child_completed,
        winner          = &rush_winner,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Sibling_Ctx) {
        // 1. Spawn independent child fiber attached to parent
        child := fiber_pool_acquire(&f.sched.fiber_pool)
        child.sched = f.sched
        child.debug_name = "Independent Child"
        child.stored_context = context
        child.user_data = rawptr(c.indep_completed)
        child.entry_proc = proc(cf: ^Fiber, ud: rawptr) {
            wait(cf, 0.1)
            flag := (^bool)(ud)
            flag^ = true
        }
        fiber_link_child(f, child)
        append(&f.sched.ready_queue, child.handle)

        // 2. Run rush join where branch 0 fails and branch 1 succeeds
        w := rush(f,
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.01)
                fiber_abort_tree(bf.sched, bf) // Fails
            }, name = "Failing Branch"),
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.02) // Succeeds
            }, name = "Winning Branch"),
        )
        c.winner^ = w

        wait(f, 0.15)
    }, &ctx, name = "Parent Runner")

    for _ in 0 ..< 20 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, rush_winner, 1)
    testing.expect_value(t, independent_child_completed, true)
}


// ============================================================================
// Test 183: Self-Join Deadlock Rejection Guard
// ============================================================================

@(test)
test_fiber_self_join_deadlock_guard :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    join_result := true

    spawn(&sched, proc(f: ^Fiber, res: ^bool) {
        // Attempt self-join
        ok := fiber_join(f, f.handle)
        res^ = ok
    }, &join_result, name = "Self Joiner")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, join_result, false)
}


// ============================================================================
// Test 187: Multi-ISA Machine Code Disassembly Validation via core:rexcode
// ============================================================================

@(test)
test_multi_isa_byte_opcodes_disassembly_validation :: proc(t: ^testing.T) {
    // 1. AMD64 Windows Context Switch Machine Code
    amd64_win_bytes := []u8{
        0x55,                                           // push rbp
        0x53,                                           // push rbx
        0x56,                                           // push rsi
        0x57,                                           // push rdi
        0x41, 0x54,                                     // push r12
        0x41, 0x55,                                     // push r13
        0x41, 0x56,                                     // push r14
        0x41, 0x57,                                     // push r15
        0x48, 0x81, 0xEC, 0xA0, 0x00, 0x00, 0x00,       // sub rsp, 160
        0x44, 0x0F, 0x7F, 0x7C, 0x24, 0x00,             // movdqu [rsp + 0x00], xmm15
        0x44, 0x0F, 0x7F, 0x74, 0x24, 0x10,             // movdqu [rsp + 0x10], xmm14
        0x44, 0x0F, 0x7F, 0x6C, 0x24, 0x20,             // movdqu [rsp + 0x20], xmm13
        0x44, 0x0F, 0x7F, 0x64, 0x24, 0x30,             // movdqu [rsp + 0x30], xmm12
        0x44, 0x0F, 0x7F, 0x5C, 0x24, 0x40,             // movdqu [rsp + 0x40], xmm11
        0x44, 0x0F, 0x7F, 0x54, 0x24, 0x50,             // movdqu [rsp + 0x50], xmm10
        0x44, 0x0F, 0x7F, 0x4C, 0x24, 0x60,             // movdqu [rsp + 0x60], xmm9
        0x44, 0x0F, 0x7F, 0x44, 0x24, 0x70,             // movdqu [rsp + 0x70], xmm8
        0x0F, 0x7F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00, // movdqu [rsp + 0x80], xmm7
        0x0F, 0x7F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00, // movdqu [rsp + 0x90], xmm6
        0x48, 0x89, 0x21,                               // mov [rcx], rsp
        0x48, 0x89, 0xD4,                               // mov rsp, rdx
        0x0F, 0x6F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00, // movdqu xmm6,  [rsp + 0x90]
        0x0F, 0x6F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00, // movdqu xmm7,  [rsp + 0x80]
        0x44, 0x0F, 0x6F, 0x44, 0x24, 0x70,             // movdqu xmm8,  [rsp + 0x70]
        0x44, 0x0F, 0x6F, 0x4C, 0x24, 0x60,             // movdqu xmm9,  [rsp + 0x60]
        0x44, 0x0F, 0x6F, 0x54, 0x24, 0x50,             // movdqu xmm10, [rsp + 0x50]
        0x44, 0x0F, 0x6F, 0x5C, 0x24, 0x40,             // movdqu xmm11, [rsp + 0x40]
        0x44, 0x0F, 0x6F, 0x64, 0x24, 0x30,             // movdqu xmm12, [rsp + 0x30]
        0x44, 0x0F, 0x6F, 0x6C, 0x24, 0x20,             // movdqu xmm13, [rsp + 0x20]
        0x44, 0x0F, 0x6F, 0x74, 0x24, 0x10,             // movdqu xmm14, [rsp + 0x10]
        0x44, 0x0F, 0x6F, 0x7C, 0x24, 0x00,             // movdqu xmm15, [rsp + 0x00]
        0x48, 0x81, 0xC4, 0xA0, 0x00, 0x00, 0x00,       // add rsp, 160
        0x41, 0x5F,                                     // pop r15
        0x41, 0x5E,                                     // pop r14
        0x41, 0x5D,                                     // pop r13
        0x41, 0x5C,                                     // pop r12
        0x5F,                                           // pop rdi
        0x5E,                                           // pop rsi
        0x5B,                                           // pop rbx
        0x5D,                                           // pop rbp
        0xC3,                                           // ret
    }

    x86_insts:  [dynamic]x86.Instruction
    x86_info:   [dynamic]x86.Instruction_Info
    x86_labels: [dynamic]x86.Label_Definition
    x86_errors: [dynamic]x86.Error
    defer {
        delete(x86_insts)
        delete(x86_info)
        delete(x86_labels)
        delete(x86_errors)
    }
    x86.decode(amd64_win_bytes, nil, &x86_insts, &x86_info, &x86_labels, &x86_errors)
    testing.expect_value(t, len(x86_errors), 0)
    testing.expect_value(t, len(x86_insts), 41)

    // 2. ARM64 (AArch64) Context Switch Machine Code
    arm64_bytes := []u8{
        0xFF, 0x83, 0x02, 0xD1, // sub sp, sp, #160
        0xFD, 0x7B, 0x00, 0xA9, // stp x29, x30, [sp, #0]
        0xF3, 0x53, 0x01, 0xA9, // stp x19, x20, [sp, #16]
        0xF5, 0x5B, 0x02, 0xA9, // stp x21, x22, [sp, #32]
        0xF7, 0x63, 0x03, 0xA9, // stp x23, x24, [sp, #48]
        0xF9, 0x6B, 0x04, 0xA9, // stp x25, x26, [sp, #64]
        0xFB, 0x73, 0x05, 0xA9, // stp x27, x28, [sp, #80]
        0xE8, 0x27, 0x06, 0x6D, // stp d8,  d9,  [sp, #96]
        0xEA, 0x2F, 0x07, 0x6D, // stp d10, d11, [sp, #112]
        0xEC, 0x37, 0x08, 0x6D, // stp d12, d13, [sp, #128]
        0xEE, 0x3F, 0x09, 0x6D, // stp d14, d15, [sp, #144]
        0xE2, 0x03, 0x00, 0x91, // mov x2, sp
        0x02, 0x00, 0x00, 0xF9, // str x2, [x0]
        0x3F, 0x00, 0x00, 0x91, // mov sp, x1
        0xEE, 0x3F, 0x49, 0x6D, // ldp d14, d15, [sp, #144]
        0xEC, 0x37, 0x48, 0x6D, // ldp d12, d13, [sp, #128]
        0xEA, 0x2F, 0x47, 0x6D, // ldp d10, d11, [sp, #112]
        0xE8, 0x27, 0x46, 0x6D, // ldp d8,  d9,  [sp, #96]
        0xFB, 0x73, 0x45, 0xA9, // ldp x27, x28, [sp, #80]
        0xF9, 0x6B, 0x44, 0xA9, // ldp x25, x26, [sp, #64]
        0xF7, 0x63, 0x43, 0xA9, // ldp x23, x24, [sp, #48]
        0xF5, 0x5B, 0x42, 0xA9, // ldp x21, x22, [sp, #32]
        0xF3, 0x53, 0x41, 0xA9, // ldp x19, x20, [sp, #16]
        0xFD, 0x7B, 0x40, 0xA9, // ldp x29, x30, [sp, #0]
        0xFF, 0x83, 0x02, 0x91, // add sp, sp, #160
        0xC0, 0x03, 0x5F, 0xD6, // ret
    }

    arm64_insts:  [dynamic]arm64.Instruction
    arm64_info:   [dynamic]arm64.Instruction_Info
    arm64_labels: [dynamic]arm64.Label_Definition
    arm64_errors: [dynamic]arm64.Error
    defer {
        delete(arm64_insts)
        delete(arm64_info)
        delete(arm64_labels)
        delete(arm64_errors)
    }
    arm64.decode(arm64_bytes, nil, &arm64_insts, &arm64_info, &arm64_labels, &arm64_errors)
    testing.expect_value(t, len(arm64_errors), 0)
    testing.expect_value(t, len(arm64_insts), 26)

    // 3. RISC-V 64 Context Switch Machine Code
    riscv_bytes := []u8{
        0x13, 0x01, 0x01, 0xF3, // addi sp, sp, -208
        0x23, 0x30, 0x11, 0x00, // sd ra, 0(sp)
        0x23, 0x34, 0x81, 0x00, // sd s0, 8(sp)
        0x23, 0x38, 0x91, 0x00, // sd s1, 16(sp)
        0x23, 0x3C, 0x21, 0x01, // sd s2, 24(sp)
        0x23, 0x30, 0x31, 0x03, // sd s3, 32(sp)
        0x23, 0x34, 0x41, 0x03, // sd s4, 40(sp)
        0x23, 0x38, 0x51, 0x03, // sd s5, 48(sp)
        0x23, 0x3C, 0x61, 0x03, // sd s6, 56(sp)
        0x23, 0x30, 0x71, 0x05, // sd s7, 64(sp)
        0x23, 0x34, 0x81, 0x05, // sd s8, 72(sp)
        0x23, 0x38, 0x91, 0x05, // sd s9, 80(sp)
        0x23, 0x3C, 0xA1, 0x05, // sd s10, 88(sp)
        0x23, 0x30, 0xB1, 0x07, // sd s11, 96(sp)
        0x27, 0x34, 0x81, 0x06, // fsd fs0, 104(sp)
        0x27, 0x38, 0x91, 0x06, // fsd fs1, 112(sp)
        0x27, 0x3C, 0x21, 0x07, // fsd fs2, 120(sp)
        0x27, 0x30, 0x31, 0x09, // fsd fs3, 128(sp)
        0x27, 0x34, 0x41, 0x09, // fsd fs4, 136(sp)
        0x27, 0x38, 0x51, 0x09, // fsd fs5, 144(sp)
        0x27, 0x3C, 0x61, 0x09, // fsd fs6, 152(sp)
        0x27, 0x30, 0x71, 0x0B, // fsd fs7, 160(sp)
        0x27, 0x34, 0x81, 0x0B, // fsd fs8, 168(sp)
        0x27, 0x38, 0x91, 0x0B, // fsd fs9, 176(sp)
        0x27, 0x3C, 0xA1, 0x0B, // fsd fs10, 184(sp)
        0x27, 0x30, 0xB1, 0x0D, // fsd fs11, 192(sp)
        0x23, 0x30, 0x25, 0x00, // sd sp, 0(a0)
        0x13, 0x81, 0x05, 0x00, // mv sp, a1 (addi sp, a1, 0)
        0x07, 0x3E, 0x01, 0x0C, // fld fs11, 192(sp)
        0x87, 0x3E, 0x81, 0x0B, // fld fs10, 184(sp)
        0x07, 0x3E, 0x01, 0x0B, // fld fs9, 176(sp)
        0x87, 0x3E, 0x81, 0x0A, // fld fs8, 168(sp)
        0x07, 0x3E, 0x01, 0x0A, // fld fs7, 160(sp)
        0x87, 0x3E, 0x81, 0x09, // fld fs6, 152(sp)
        0x07, 0x3E, 0x01, 0x09, // fld fs5, 144(sp)
        0x87, 0x3E, 0x81, 0x08, // fld fs4, 136(sp)
        0x07, 0x3E, 0x01, 0x08, // fld fs3, 128(sp)
        0x87, 0x3E, 0x81, 0x07, // fld fs2, 120(sp)
        0x07, 0x3E, 0x01, 0x07, // fld fs1, 112(sp)
        0x87, 0x34, 0x81, 0x06, // fld fs0, 104(sp)
        0x83, 0x3D, 0x01, 0x06, // ld s11, 96(sp)
        0x03, 0x3D, 0x81, 0x05, // ld s10, 88(sp)
        0x83, 0x3C, 0x01, 0x05, // ld s9, 80(sp)
        0x03, 0x3C, 0x81, 0x04, // ld s8, 72(sp)
        0x83, 0x3B, 0x01, 0x04, // ld s7, 64(sp)
        0x03, 0x3B, 0x81, 0x03, // ld s6, 56(sp)
        0x83, 0x3A, 0x01, 0x03, // ld s5, 48(sp)
        0x03, 0x3A, 0x81, 0x02, // ld s4, 40(sp)
        0x83, 0x39, 0x01, 0x02, // ld s3, 32(sp)
        0x03, 0x39, 0x81, 0x01, // ld s2, 24(sp)
        0x83, 0x34, 0x01, 0x01, // ld s1, 16(sp)
        0x03, 0x34, 0x81, 0x00, // ld s0, 8(sp)
        0x83, 0x30, 0x01, 0x00, // ld ra, 0(sp)
        0x13, 0x01, 0x01, 0x0D, // addi sp, sp, 208
        0x67, 0x80, 0x00, 0x00, // ret
    }

    riscv_insts:  [dynamic]riscv.Instruction
    riscv_info:   [dynamic]riscv.Instruction_Info
    riscv_labels: [dynamic]riscv.Label_Definition
    riscv_errors: [dynamic]riscv.Error
    defer {
        delete(riscv_insts)
        delete(riscv_info)
        delete(riscv_labels)
        delete(riscv_errors)
    }
    riscv.decode(riscv_bytes, nil, &riscv_insts, &riscv_info, &riscv_labels, &riscv_errors)
    testing.expect_value(t, len(riscv_errors), 0)
    testing.expect_value(t, len(riscv_insts), 55)
}


// Test 188: High-Level Inline Assembly Stack and Register Extractors
@(test)
test_high_level_inline_asm_stack_and_register_extractors :: proc(t: ^testing.T) {
    local_var: u64 = 0xDEADBEEF
    local_addr := uintptr(&local_var)

    when ODIN_ARCH == .amd64 {
        sp := get_rsp()
        testing.expect(t, sp != nil, "get_rsp() must return a non-nil active stack pointer")
        sp_addr := uintptr(sp)
        diff := sp_addr > local_addr ? sp_addr - local_addr : local_addr - sp_addr
        testing.expect(t, diff < 4096, "get_rsp() must be within active stack frame")

        r12 := get_r12_reg()
        _ = r12
    } else when ODIN_ARCH == .arm64 {
        sp := get_sp()
        testing.expect(t, sp != nil, "get_sp() must return a non-nil active stack pointer")
        sp_addr := uintptr(sp)
        diff := sp_addr > local_addr ? sp_addr - local_addr : local_addr - sp_addr
        testing.expect(t, diff < 4096, "get_sp() must be within active stack frame")

        x19 := get_x19_reg()
        _ = x19
    } else when ODIN_ARCH == .riscv64 {
        sp := get_sp()
        testing.expect(t, sp != nil, "get_sp() must return a non-nil active stack pointer")
        sp_addr := uintptr(sp)
        diff := sp_addr > local_addr ? sp_addr - local_addr : local_addr - sp_addr
        testing.expect(t, diff < 4096, "get_sp() must be within active stack frame")

        s2 := get_s2_reg()
        _ = s2
    }
}

// ============================================================================
// Multi-Clock Domain, QoL, Re-init & Fuzzing Tests
// ============================================================================

@(test)
test_real_time_clock_ignores_pause_and_scale :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        sim_done:  bool,
        real_done: bool,
    }
    st: State

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait(f, 1.0)
        s.sim_done = true
    }, &st, clock = CLOCK_SIM)

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait(f, 1.0)
        s.real_done = true
    }, &st, clock = CLOCK_REAL)

    // Start both fibers at t=0 so they enter wait(f, 1.0)
    scheduler_run(&sched)

    // Advance only CLOCK_REAL (simulating a paused CLOCK_SIM)
    clock_advance(&sched, CLOCK_REAL, 0.6)
    scheduler_run(&sched)
    testing.expect(t, !st.sim_done && !st.real_done, "Neither should be done at 0.6s")

    clock_advance(&sched, CLOCK_REAL, 0.5)
    scheduler_run(&sched)
    testing.expect(t, st.real_done, "Real-time fiber should complete even while sim clock is not advanced")
    testing.expect(t, !st.sim_done, "Sim fiber must remain asleep while sim clock is paused")

    // Advance CLOCK_SIM at 0.5x scale: 1.0s wall * 0.5 = 0.5s sim -> not done yet
    clock_advance(&sched, CLOCK_SIM, 1.0 * 0.5)
    scheduler_run(&sched)
    testing.expect(t, !st.sim_done, "Sim fiber at 0.5x scale should only be at 0.5s sim time")

    clock_advance(&sched, CLOCK_SIM, 1.0 * 0.5)
    scheduler_run(&sched)
    testing.expect(t, st.sim_done, "Sim fiber should complete at 1.0s sim time")
}

@(test)
test_fixed_tick_clock_precision :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        step_at_wake: u64,
        done:         bool,
    }
    st: State

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait_steps(f, 5)
        s.step_at_wake = current_steps(f)
        s.done = true
    }, &st, clock = CLOCK_PHYS)

    // Start fiber (enters wait_steps(5) on step 1)
    clock_advance(&sched, CLOCK_PHYS, 1.0 / 60.0, steps = 1)
    scheduler_run(&sched)
    testing.expect(t, !st.done, "Should be waiting for 5 physics steps")

    // Advance 4 steps -> total 5 steps (target is 1 + 5 = 6)
    clock_advance(&sched, CLOCK_PHYS, 4.0 / 60.0, steps = 4)
    scheduler_run(&sched)
    testing.expect(t, !st.done, "Should still be waiting after 4 steps")

    // Advance 1 more step -> wakes up!
    clock_advance(&sched, CLOCK_PHYS, 1.0 / 60.0, steps = 1)
    scheduler_run(&sched)
    testing.expect(t, st.done, "Should wake on the 5th step")
    testing.expect_value(t, st.step_at_wake, u64(6))
}

@(test)
test_with_timeout_real_during_pause :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    Result :: struct {
        timed_out: bool,
        finished:  bool,
    }
    res: Result

    spawn(&sched, proc(f: ^Fiber, r: ^Result) {
        // Sim work takes 2.0 sim seconds, but timeout is on CLOCK_REAL (0.5s)
        r.timed_out = with_timeout(f, 0.5, branch(proc(f: ^Fiber) {
            wait(f, 2.0)
        }), timeout_clock = CLOCK_REAL)
        r.finished = true
    }, &res, clock = CLOCK_SIM)

    // Step 1: spawn and enter with_timeout
    clock_advance(&sched, CLOCK_SIM, 0.01)
    clock_advance(&sched, CLOCK_REAL, 0.01)
    scheduler_run(&sched)
    testing.expect(t, !res.finished, "Should be running")

    // Sim is paused (only advance CLOCK_REAL by 0.6s)
    clock_advance(&sched, CLOCK_REAL, 0.6)
    scheduler_run(&sched)
    testing.expect(t, res.finished, "with_timeout on CLOCK_REAL must fire even while CLOCK_SIM is paused")
    testing.expect(t, res.timed_out, "with_timeout must report true (timed out)")
}

@(test)
test_clock_queries_inside_fiber :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    Obs :: struct {
        dt_sim:   f32,
        t_sim:    f64,
        steps:    u64,
        cid:      Clock_ID,
    }
    obs: Obs

    spawn(&sched, proc(f: ^Fiber, o: ^Obs) {
        yield(f)
        o.dt_sim = delta_time(f)
        o.t_sim  = current_time(f)
        o.steps  = current_steps(f)
        o.cid    = fiber_clock(f)
    }, &obs, clock = CLOCK_SIM)

    scheduler_step(&sched, 0.1, CLOCK_SIM)
    scheduler_step(&sched, 0.1, CLOCK_SIM)

    testing.expect(t, abs(obs.dt_sim - 0.1) < 1e-5, "dt_sim should be 0.1")
    testing.expect(t, abs(obs.t_sim - 0.2) < 1e-6, "t_sim should be 0.2")
    testing.expect_value(t, obs.steps, u64(2))
    testing.expect_value(t, obs.cid, CLOCK_SIM)
}

@(test)
test_multi_clock_simultaneous_advance :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        sim_woke:  bool,
        real_woke: bool,
        tick_woke: bool,
    }
    st: State

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait(f, 0.25)
        s.sim_woke = true
    }, &st, clock = CLOCK_SIM)

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait(f, 0.5)
        s.real_woke = true
    }, &st, clock = CLOCK_REAL)

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait_steps(f, 3)
        s.tick_woke = true
    }, &st, clock = CLOCK_PHYS)

    // Step 0: start all three fibers so they enter their wait states
    clock_advance(&sched, CLOCK_SIM, 0.0, steps = 0)
    clock_advance(&sched, CLOCK_REAL, 0.0, steps = 0)
    clock_advance(&sched, CLOCK_PHYS, 0.0, steps = 0)
    scheduler_run(&sched)
    testing.expect(t, !st.sim_woke && !st.real_woke && !st.tick_woke, "None should wake at t=0")

    // Advance all 3 clocks together: sim +0.3s, real +0.6s, phys +3 steps
    clock_advance(&sched, CLOCK_SIM, 0.3, steps = 1)
    clock_advance(&sched, CLOCK_REAL, 0.6, steps = 1)
    clock_advance(&sched, CLOCK_PHYS, 0.05, steps = 3)
    scheduler_run(&sched)

    testing.expect(t, st.sim_woke, "Sim timer (0.25s <= 0.30s) should wake")
    testing.expect(t, st.real_woke, "Real timer (0.50s <= 0.60s) should wake")
    testing.expect(t, st.tick_woke, "Tick timer (3 steps) should wake")
}

@(test)
test_ticker_zero_drift_accumulation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        ticks:      int,
        wake_times: [4]f64,
    }
    st: State

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        for i in 0 ..< 4 {
            ticker_wait(f, 0.1)
            s.wake_times[i] = current_time(f)
            s.ticks += 1
        }
    }, &st)

    // Start at t=0
    scheduler_step(&sched, 0.0)
    // Step with uneven frame deltas (0.13s, 0.11s, 0.09s, 0.08s) -> total 0.41s
    scheduler_step(&sched, 0.13) // t=0.13 -> wakes tick 1 (scheduled for 0.10)
    testing.expect_value(t, st.ticks, 1)

    scheduler_step(&sched, 0.11) // t=0.24 -> wakes tick 2 (scheduled for 0.20, not 0.23!)
    testing.expect_value(t, st.ticks, 2)

    scheduler_step(&sched, 0.09) // t=0.33 -> wakes tick 3 (scheduled for 0.30)
    testing.expect_value(t, st.ticks, 3)

    scheduler_step(&sched, 0.08) // t=0.41 -> wakes tick 4 (scheduled for 0.40)
    testing.expect_value(t, st.ticks, 4)
}

@(test)
test_mixed_clock_race_real_vs_sim :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        winner: int,
        done:   bool,
    }
    st := State{winner = -1}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.winner = race(f,
            branch(proc(f: ^Fiber) {
                wait(f, 0.5) // Sim clock branch
            }, clock = CLOCK_SIM),
            branch(proc(f: ^Fiber) {
                wait(f, 0.5) // Real clock branch
            }, clock = CLOCK_REAL),
        )
        s.done = true
    }, &st)

    clock_advance(&sched, CLOCK_SIM, 0.0)
    clock_advance(&sched, CLOCK_REAL, 0.0)
    scheduler_run(&sched)

    // Sim is paused (only advance CLOCK_REAL) -> branch 1 (CLOCK_REAL) must win
    clock_advance(&sched, CLOCK_REAL, 0.6)
    scheduler_run(&sched)

    testing.expect(t, st.done, "Race should complete via real-time branch")
    testing.expect_value(t, st.winner, 1)
    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.active_fibers, 0)
}

@(test)
test_qol_overloads_and_accessors :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    State :: struct {
        counter: int,
    }
    st: State

    h := spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.counter += 1
        ok := sync(f,
            branch(proc(f: ^Fiber, s2: ^State) {
                wait(f, 0.05)
                s2.counter += 10
            }, s),
            branch(proc(f: ^Fiber, s2: ^State) {
                yield(f)
                s2.counter += 100
            }, s),
            branch(proc(f: ^Fiber) {
                yield(f)
            }),
        )
        if ok {
            s.counter += 1000
        }
    }, &st, name = "root_qol")

    scheduler_step(&sched, 0.01)
    testing.expect(t, fiber_is_alive(&sched, h), "Fiber should be alive")

    scheduler_step(&sched, 0.06)
    testing.expect(t, !fiber_is_alive(&sched, h), "Fiber should have completed")
    testing.expect_value(t, st.counter, 1111)

    // Scheduler time & step accessors
    testing.expect(t, abs(scheduler_time(&sched, CLOCK_SIM) - 0.07) < 1e-6, "sim_time should be 0.07")
    testing.expect_value(t, scheduler_steps(&sched, CLOCK_SIM), u64(2))
}

@(test)
test_reinit_and_reuse_primitives :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 16)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    ev: Event(int)
    event_init(&ev)
    tok: Async_Token
    async_token_init(&tok)

    // First round
    State :: struct {
        sig:  ^Signal,
        ev:   ^Event(int),
        tok:  ^Async_Token,
        val:  int,
        done: int,
    }
    st := State{sig = &sig, ev = &ev, tok = &tok}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        signal_wait(f, s.sig)
        v, _ := event_wait(f, s.ev)
        s.val = v
        if await_async(f, s.tok) {
            s.done += 1
        }
    }, &st)

    scheduler_step(&sched, 0.01)
    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)
    event_emit(&sched, &ev, 42)
    scheduler_step(&sched, 0.01)
    async_token_complete(&tok, true)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, st.done, 1)
    testing.expect_value(t, st.val, 42)

    // Re-initialize and reuse all primitives for a second round
    signal_init(&sig)
    event_init(&ev)
    async_token_init(&tok)

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        signal_wait(f, s.sig)
        v, _ := event_wait(f, s.ev)
        s.val = v
        if await_async(f, s.tok) {
            s.done += 1
        }
    }, &st)

    scheduler_step(&sched, 0.01)
    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)
    event_emit(&sched, &ev, 99)
    scheduler_step(&sched, 0.01)
    async_token_complete(&tok, true)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, st.done, 2)
    testing.expect_value(t, st.val, 99)
}

@(test)
test_fuzz_scheduler_invariants :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 128)
    defer scheduler_destroy(&sched)

    Fuzz_Shared :: struct {
        rng_state: u64,
        sig:       Signal,
        ev:        Event(int),
        scope_a:   Fiber_Scope,
        scope_b:   Fiber_Scope,
        cond_flag: bool,
        completed: int,
        aborted:   int,
    }

    xorshift64 :: proc(state: ^u64) -> u64 {
        x := state^
        x ~= x << 13
        x ~= x >> 7
        x ~= x << 17
        state^ = x
        return x
    }

    shared := Fuzz_Shared{rng_state = 0xCAFE_BABE_1337_BEEF}
    signal_init(&shared.sig)
    event_init(&shared.ev)

    fuzz_worker :: proc(f: ^Fiber, s: ^Fuzz_Shared) {
        fiber_set_cleanup(f, proc(raw: rawptr) {
            sh := cast(^Fuzz_Shared)raw
            sh.aborted += 1
        }, s)

        action := xorshift64(&s.rng_state) % 9
        switch action {
        case 0:
            yield(f)
            wait(f, 0.02)
        case 1:
            wait(f, 0.05)
            yield(f)
        case 2:
            wait_steps(f, 2)
        case 3:
            signal_wait(f, &s.sig)
        case 4:
            _, _ = event_wait(f, &s.ev)
        case 5:
            for !s.cond_flag {
                yield(f)
            }
        case 6:
            _ = sync(f,
                branch(proc(f: ^Fiber, sh: ^Fuzz_Shared) {
                    wait(f, 0.01)
                    yield(f)
                }, s),
                branch(proc(f: ^Fiber, sh: ^Fuzz_Shared) {
                    yield(f)
                }, s),
            )
        case 7:
            _ = race(f,
                branch(proc(f: ^Fiber) {
                    wait(f, 0.01)
                }),
                branch(proc(f: ^Fiber) {
                    wait(f, 0.10)
                }),
            )
        case 8:
            _ = with_timeout(f, 0.02, branch(proc(f: ^Fiber) {
                wait(f, 0.05)
            }))
        }

        // Clear cleanup if completing normally so `aborted` only counts aborts
        fiber_cleanup_pop(f)
        s.completed += 1
    }

    handles: [dynamic]Fiber_Handle
    defer delete(handles)

    for step in 0 ..< 250 {
        // Randomly spawn 1..3 fibers
        spawn_count := int(xorshift64(&shared.rng_state) % 3) + 1
        for _ in 0 ..< spawn_count {
            st := scheduler_pool_stats(&sched)
            if st.active_fibers < 100 {
                sc_choice := xorshift64(&shared.rng_state) % 3
                sc: ^Fiber_Scope = nil
                if sc_choice == 1 { sc = &shared.scope_a }
                if sc_choice == 2 { sc = &shared.scope_b }
                use_real := (xorshift64(&shared.rng_state) % 4) == 0
                cid := CLOCK_REAL if use_real else CLOCK_SIM
                h := spawn(&sched, fuzz_worker, &shared, scope = sc, clock = cid)
                append(&handles, h)
            }
        }

        // Randomly emit signals/events or toggle condition
        if (xorshift64(&shared.rng_state) % 5) == 0 {
            signal_emit(&sched, &shared.sig)
        }
        if (xorshift64(&shared.rng_state) % 5) == 0 {
            event_emit(&sched, &shared.ev, step)
        }
        shared.cond_flag = (xorshift64(&shared.rng_state) % 3) == 0

        // Randomly cancel a handle or scope
        if len(handles) > 0 && (xorshift64(&shared.rng_state) % 4) == 0 {
            idx := int(xorshift64(&shared.rng_state) % u64(len(handles)))
            fiber_cancel(&sched, handles[idx])
        }
        if (xorshift64(&shared.rng_state) % 15) == 0 {
            scope_cancel(&sched, &shared.scope_a)
        }
        if (xorshift64(&shared.rng_state) % 20) == 0 {
            scope_cancel(&sched, &shared.scope_b)
        }

        // Step clocks
        dt := f32(xorshift64(&shared.rng_state)%30+1) * 0.001
        paused := (xorshift64(&shared.rng_state) % 10) == 0
        clock_advance(&sched, CLOCK_REAL, dt, steps = 1)
        if !paused {
            clock_advance(&sched, CLOCK_SIM, dt, steps = 1)
        }
        scheduler_run(&sched)
    }

    // Drain remaining fibers: cancel scopes, emit signals, set cond_flag, step forward
    shared.cond_flag = true
    scope_cancel(&sched, &shared.scope_a)
    scope_cancel(&sched, &shared.scope_b)
    for h in handles {
        fiber_cancel(&sched, h)
    }
    for _ in 0 ..< 20 {
        signal_emit(&sched, &shared.sig)
        event_emit(&sched, &shared.ev, 0)
        clock_advance(&sched, CLOCK_REAL, 0.1, steps = 1)
        clock_advance(&sched, CLOCK_SIM, 0.1, steps = 1)
        scheduler_run(&sched)
    }

    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.active_fibers, 0)
    testing.expect_value(t, stats.free_fibers, 128)
    testing.expect(t, shared.completed + shared.aborted > 100, "Should have processed many fibers")
}

@(test)
test_fuzz_deep_cancel_and_pool_exhaustion :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 65536, 32)
    defer scheduler_destroy(&sched)

    State :: struct {
        rng:     u64,
        cleaned: int,
    }
    st := State{rng = 0x9988_7766_5544_3322}

    nested_entry :: proc(f: ^Fiber, s: ^State) {
        fiber_set_cleanup(f, proc(raw: rawptr) {
            st_ptr := cast(^State)raw
            st_ptr.cleaned += 1
        }, s)

        // Spawn nested race/sync if pool has room
        pstats := scheduler_pool_stats(f.sched)
        if pstats.active_fibers < 24 {
            _ = race(f,
                branch(proc(f: ^Fiber, st_inner: ^State) {
                    fiber_set_cleanup(f, proc(raw: rawptr) {
                        (cast(^State)raw).cleaned += 1
                    }, st_inner)
                    wait(f, 0.05)
                }, s),
                branch(proc(f: ^Fiber, st_inner: ^State) {
                    fiber_set_cleanup(f, proc(raw: rawptr) {
                        (cast(^State)raw).cleaned += 1
                    }, st_inner)
                    wait(f, 0.02)
                }, s),
            )
        } else {
            wait(f, 0.02)
        }
    }

    scope: Fiber_Scope
    for i in 0 ..< 60 {
        pstats := scheduler_pool_stats(&sched)
        if pstats.active_fibers <= 26 {
            spawn(&sched, nested_entry, &st, scope = &scope)
        }
        scheduler_step(&sched, 0.01)
        if i % 7 == 0 {
            scope_cancel(&sched, &scope)
        }
    }

    scope_cancel(&sched, &scope)
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.1)
    }

    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.active_fibers, 0)
    testing.expect_value(t, stats.free_fibers, 32)
    testing.expect(t, st.cleaned > 0, "Cleanup callbacks must have executed")
}

// ============================================================================
// Standalone Test Runner (for cross-arch QEMU execution)
// ============================================================================

run_all_coroutine_tests :: proc(t: ^testing.T = nil, verbose := false) -> (passed: int, failed: int) {
    runner_t: testing.T
    active_t := t != nil ? t : &runner_t
    tests := []struct{ name: string, fn: proc(^testing.T) } {
        { "test_basic_spawn_and_run", test_basic_spawn_and_run },
        { "test_stack_local_variables_across_yields", test_stack_local_variables_across_yields },
        { "test_wait_seconds_timer_heap", test_wait_seconds_timer_heap },
        { "test_wait_frames", test_wait_frames },
        { "test_structured_sync", test_structured_sync },
        { "test_structured_race", test_structured_race },
        { "test_scope_cancellation", test_scope_cancellation },
        { "test_cleanup_proc_and_defer", test_cleanup_proc_and_defer },
        { "test_stack_canary_guard", test_stack_canary_guard },
        { "test_nested_race_with_sync_branch", test_nested_race_with_sync_branch },
        { "test_many_concurrent_fibers", test_many_concurrent_fibers },
        { "test_deep_nested_hierarchy_sync_race_sync", test_deep_nested_hierarchy_sync_race_sync },
        { "test_sync_failure_propagation", test_sync_failure_propagation },
        { "test_race_all_simultaneous_finish", test_race_all_simultaneous_finish },
        { "test_race_loser_with_children_aborts_all_descendants", test_race_loser_with_children_aborts_all_descendants },
        { "test_timer_heap_1000_random_sort", test_timer_heap_1000_random_sort },
        { "test_timer_heap_random_cancellations", test_timer_heap_random_cancellations },
        { "test_pool_multi_slab_expansion_and_reclaim", test_pool_multi_slab_expansion_and_reclaim },
        { "test_fiber_lifecycle_generation_reuse", test_fiber_lifecycle_generation_reuse },
        { "test_local_variable_isolation_many_fibers", test_local_variable_isolation_many_fibers },
        { "test_10k_yield_loop", test_10k_yield_loop },
        { "test_zero_and_negative_waits", test_zero_and_negative_waits },
        { "test_fiber_temp_allocator_isolation", test_fiber_temp_allocator_isolation },
        { "test_with_timeout_completion", test_with_timeout_completion },
        { "test_with_timeout_expired", test_with_timeout_expired },
        { "test_signal_broadcast", test_signal_broadcast },
        { "test_stack_watermark_usage_calculation", test_stack_watermark_usage_calculation },
        { "test_async_token_bridge", test_async_token_bridge },
        { "test_virtual_memory_guard_pages", test_virtual_memory_guard_pages },
        { "test_spawn_by_value_primitives", test_spawn_by_value_primitives },
        { "test_spawn_by_value_struct", test_spawn_by_value_struct },
        { "test_spawn_by_value_concurrency_no_crosstalk", test_spawn_by_value_concurrency_no_crosstalk },
        { "test_branch_by_value_sync", test_branch_by_value_sync },
        { "test_branch_by_value_race", test_branch_by_value_race },
        { "test_spawn_by_value_ephemeral_stack_safety", test_spawn_by_value_ephemeral_stack_safety },
        { "test_with_timeout_proc_overloads", test_with_timeout_proc_overloads },
        { "test_scope_query_helpers", test_scope_query_helpers },
        { "test_fiber_time_accessors", test_fiber_time_accessors },
        { "test_scope_wait", test_scope_wait },
        { "test_fallback_control_flow", test_fallback_control_flow },
        { "test_race_preemption_ignoring_failures", test_race_preemption_ignoring_failures },
        { "test_fail_primitive", test_fail_primitive },
        { "test_fallback_all_failing_and_by_value", test_fallback_all_failing_and_by_value },
        { "test_race_5_branches_and_all_failing", test_race_5_branches_and_all_failing },
        { "test_nested_concurrency_combinators", test_nested_concurrency_combinators },
        { "test_fiber_join_normal_completion", test_fiber_join_normal_completion },
        { "test_fiber_join_cancelled_target", test_fiber_join_cancelled_target },
        { "test_fiber_join_already_finished", test_fiber_join_already_finished },
        { "test_event_typed_multicast", test_event_typed_multicast },
        { "test_event_empty_emit", test_event_empty_emit },
        { "test_scheduler_prewarm", test_scheduler_prewarm },
        { "test_handle_introspection_and_status", test_handle_introspection_and_status },
        { "test_scheduler_pool_stats", test_scheduler_pool_stats },
        { "test_scope_hierarchy_multi_fiber_active_count", test_scope_hierarchy_multi_fiber_active_count },
        { "test_signal_multicast_wait_and_broadcast", test_signal_multicast_wait_and_broadcast },
        { "test_scope_cancellation_preserves_independent_scopes", test_scope_cancellation_preserves_independent_scopes },
        { "test_race_stun_interruption_and_recovery", test_race_stun_interruption_and_recovery },
        { "test_scope_cancel_immediate_abort", test_scope_cancel_immediate_abort },
        { "test_subscope_isolated_behavior_cancellation", test_subscope_isolated_behavior_cancellation },
        { "test_cancel_fiber_waiting_on_signal", test_cancel_fiber_waiting_on_signal },
        { "test_cancel_fiber_waiting_on_event", test_cancel_fiber_waiting_on_event },
        { "test_scope_cancel_inside_nested_sync", test_scope_cancel_inside_nested_sync },
        { "test_scope_cancel_inside_nested_race", test_scope_cancel_inside_nested_race },
        { "test_fallback_resilience_after_scope_cancellation", test_fallback_resilience_after_scope_cancellation },
        { "test_branch_name_and_debug_tree_preservation", test_branch_name_and_debug_tree_preservation },
        { "test_signal_multicast_cascade_with_dynamic_waiters", test_signal_multicast_cascade_with_dynamic_waiters },
        { "test_fiber_set_cleanup_deep_hierarchy_abort", test_fiber_set_cleanup_deep_hierarchy_abort },
        { "test_event_multicast_dynamic_subscribe_during_emit", test_event_multicast_dynamic_subscribe_during_emit },
        { "test_scheduler_prewarm_slab_expansion_under_load", test_scheduler_prewarm_slab_expansion_under_load },
        { "test_rush_and_fallback_with_signal_interruption", test_rush_and_fallback_with_signal_interruption },
        { "test_watchdog_configuration_and_disable", test_watchdog_configuration_and_disable },
        { "test_scope_destroy_prevents_stale_pointer_access", test_scope_destroy_prevents_stale_pointer_access },
        { "test_temp_allocator_isolation_invariants", test_temp_allocator_isolation_invariants },
        { "test_event_multicast_broadcast_and_clear", test_event_multicast_broadcast_and_clear },
        { "test_generational_handle_history_capacity", test_generational_handle_history_capacity },
        { "test_scheduler_walk_tree_traversal", test_scheduler_walk_tree_traversal },
        { "test_structured_task_preemption_via_race_and_signal", test_structured_task_preemption_via_race_and_signal },
        { "test_fiber_dynamic_renaming", test_fiber_dynamic_renaming },
        { "test_plan5_packed_generational_handles_bitwise", test_plan5_packed_generational_handles_bitwise },
        { "test_plan5_handle_slot_reuse_and_aba_safety", test_plan5_handle_slot_reuse_and_aba_safety },
        { "test_plan5_intrusive_wait_queue_operations", test_plan5_intrusive_wait_queue_operations },
        { "test_plan5_o1_handle_lookups_under_high_fiber_load", test_plan5_o1_handle_lookups_under_high_fiber_load },
        { "test_plan5_config_constants_integration", test_plan5_config_constants_integration },
        { "test_wait_queue_auto_unlinking_on_abort", test_wait_queue_auto_unlinking_on_abort },
        { "test_scope_multi_cycle_emp_stun_and_recovery", test_scope_multi_cycle_emp_stun_and_recovery },
        { "test_interruption_race_attack_recovery_loop", test_interruption_race_attack_recovery_loop },
        { "test_with_timeout_by_value_branching", test_with_timeout_by_value_branching },
        { "test_fiber_calc_stack_usage_canary_breach_detection", test_fiber_calc_stack_usage_canary_breach_detection },
        { "test_intrusive_fiber_scope_lifecycle", test_intrusive_fiber_scope_lifecycle },
        { "test_fiber_cleanup_preserves_user_data", test_fiber_cleanup_preserves_user_data },
        { "test_scheduler_destroy_scope_detachment", test_scheduler_destroy_scope_detachment },
        { "test_ready_queue_generational_aba_guard", test_ready_queue_generational_aba_guard },
        { "test_race_join_independent_sibling_non_interference", test_race_join_independent_sibling_non_interference },
        { "test_rush_join_independent_sibling_non_interference", test_rush_join_independent_sibling_non_interference },
        { "test_fiber_self_join_deadlock_guard", test_fiber_self_join_deadlock_guard },
        { "test_multi_isa_byte_opcodes_disassembly_validation", test_multi_isa_byte_opcodes_disassembly_validation },
        { "test_high_level_inline_asm_stack_and_register_extractors", test_high_level_inline_asm_stack_and_register_extractors },
        { "test_real_time_clock_ignores_pause_and_scale", test_real_time_clock_ignores_pause_and_scale },
        { "test_fixed_tick_clock_precision", test_fixed_tick_clock_precision },
        { "test_with_timeout_real_during_pause", test_with_timeout_real_during_pause },
        { "test_clock_queries_inside_fiber", test_clock_queries_inside_fiber },
        { "test_multi_clock_simultaneous_advance", test_multi_clock_simultaneous_advance },
        { "test_ticker_zero_drift_accumulation", test_ticker_zero_drift_accumulation },
        { "test_mixed_clock_race_real_vs_sim", test_mixed_clock_race_real_vs_sim },
        { "test_qol_overloads_and_accessors", test_qol_overloads_and_accessors },
        { "test_reinit_and_reuse_primitives", test_reinit_and_reuse_primitives },
        { "test_fuzz_scheduler_invariants", test_fuzz_scheduler_invariants },
        { "test_fuzz_deep_cancel_and_pool_exhaustion", test_fuzz_deep_cancel_and_pool_exhaustion },
        { "test_heterogeneous_scope_cancellation", test_heterogeneous_scope_cancellation },
        { "test_time_scaling_and_pause", test_time_scaling_and_pause },
        { "test_real_time_clock_while_paused", test_real_time_clock_while_paused },
        { "test_fixed_integer_tick_clock", test_fixed_integer_tick_clock },
        { "test_dual_clock_time_scaling", test_dual_clock_time_scaling },
        { "test_multi_clock_heap_integrity", test_multi_clock_heap_integrity },
        { "test_scope_mass_cancel_mixed_states", test_scope_mass_cancel_mixed_states },
        { "test_primitives_custom_arena_allocation_fidelity", test_primitives_custom_arena_allocation_fidelity },
        { "test_headless_boss_ai_fuzzing_simulation", test_headless_boss_ai_fuzzing_simulation },
        { "test_phase_transition_emp_coincidence_fuzzing", test_phase_transition_emp_coincidence_fuzzing },
        { "test_wait_queue_defensive_and_paused_dispatch", test_wait_queue_defensive_and_paused_dispatch },
        { "test_time_scale_defensive_clamping", test_time_scale_defensive_clamping },
        { "test_scheduler_destroy_wait_queue_unlinking", test_scheduler_destroy_wait_queue_unlinking },
        { "test_spawn_real_val_while_paused", test_spawn_real_val_while_paused },
        { "test_real_time_fiber_paused_yield", test_real_time_fiber_paused_yield },
        { "test_real_time_ticker_paused_zero_freeze", test_real_time_ticker_paused_zero_freeze },
        { "test_fiber_pool_recycle_wake_clock_sanitization", test_fiber_pool_recycle_wake_clock_sanitization },
        { "test_fiber_owned_ticker_zero_drift_and_rebase", test_fiber_owned_ticker_zero_drift_and_rebase },
        { "test_scheduler_reinit_no_memory_leak", test_scheduler_reinit_no_memory_leak },
        { "test_api_qol_fiber_overloads_and_nested_cleanup_chaining", test_api_qol_fiber_overloads_and_nested_cleanup_chaining },
        { "test_verse_rush_losers_continue", test_verse_rush_losers_continue },
        { "test_verse_rush_failure_recovery_and_parent_rejoin", test_verse_rush_failure_recovery_and_parent_rejoin },
        { "test_branch_scoped_background_and_parent_abort", test_branch_scoped_background_and_parent_abort },
        { "test_sticky_event_and_sticky_signal", test_sticky_event_and_sticky_signal },
        { "test_yield_now_same_tick_interleave", test_yield_now_same_tick_interleave },
        { "test_rush_active_coord_reentry", test_rush_active_coord_reentry },
        { "test_fiber_defer_lifo_order", test_fiber_defer_lifo_order },
        { "test_combinator_with_helpers", test_combinator_with_helpers },
        { "test_branch_primitives_and_with_signal", test_branch_primitives_and_with_signal },
        { "test_task_future", test_task_future },
    }
    total := len(tests)
    for test, i in tests {
        sub_t: testing.T
        test.fn(&sub_t)
        if sub_t.error_count == 0 {
            passed += 1
            if verbose {
                fmt.printf("  [PASS] [%3d/%3d] %s\n", i + 1, total, test.name)
            }
        } else {
            failed += 1
            if t != nil do t.error_count += sub_t.error_count
            fmt.printf("  [FAIL] [%3d/%3d] %s (errors: %d)\n", i + 1, total, test.name, sub_t.error_count)
        }
    }
    return passed, failed
}

// ============================================================================
// Restored Core Tests (Adapted to Indexed Clock_Domain Architecture)
// ============================================================================

@(test)
test_heterogeneous_scope_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    sig: Signal
    defer signal_destroy(&sig)

    // 1. Fiber in Sleeping_Time (CLOCK_SIM)
    spawn(&sched, proc(f: ^Fiber) { wait(f, 100.0) }, scope = &scope)

    // 2. Fiber in Sleeping_Steps (CLOCK_SIM)
    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 500) }, scope = &scope)

    // 3. Fiber waiting on Signal
    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        signal_wait(f, s)
    }, &sig, scope = &scope)

    // 4. Fiber in Suspended_Join (sync)
    spawn(&sched, proc(f: ^Fiber) {
        sync(f,
            branch(proc(f: ^Fiber) { wait_steps(f, 100) }),
            branch(proc(f: ^Fiber) { wait_steps(f, 100) }),
        )
    }, scope = &scope)

    scheduler_step(&sched, 0.016)

    testing.expect(t, len(sched.clocks[CLOCK_SIM].timer_heap) > 0, "Timer heap should have waiter")
    testing.expect(t, len(sched.clocks[CLOCK_SIM].step_waiters) > 0, "Step waiters should have waiter")
    testing.expect_value(t, signal_waiter_count(&sig), 1)

    scope_cancel(&sched, &scope)

    testing.expect_value(t, len(sched.clocks[CLOCK_SIM].timer_heap), 0)
    testing.expect_value(t, len(sched.clocks[CLOCK_SIM].step_waiters), 0)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}

@(test)
test_time_scaling_and_pause :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    done := false
    spawn(&sched, proc(f: ^Fiber, d: ^bool) {
        wait(f, 1.0)
        d^ = true
    }, &done)

    // Scale to 2.0x -> 0.3s wall time * 2.0 = 0.6s sim time
    scheduler_step(&sched, 0.0)       // start fiber
    scheduler_step(&sched, 0.3 * 2.0) // sim_time = 0.6s
    testing.expect_value(t, done, false)

    // Pause via dt = 0.0
    scheduler_step(&sched, 0.0) // sim_time stays 0.6s
    testing.expect_value(t, done, false)

    // Resume at 2.0x -> 0.25s wall time * 2.0 = +0.5s sim time (total 1.1s)
    scheduler_step(&sched, 0.25 * 2.0)
    testing.expect_value(t, done, true)
}

@(test)
test_real_time_clock_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    real_fiber_done := false
    sim_fiber_done := false

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.10)
        done^ = true
    }, &real_fiber_done, clock = CLOCK_REAL)

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.10)
        done^ = true
    }, &sim_fiber_done, clock = CLOCK_SIM)

    // Start both fibers
    scheduler_run(&sched)

    // Pause sim clock by only advancing CLOCK_REAL
    for _ in 0 ..< 3 {
        clock_advance(&sched, CLOCK_REAL, 0.05)
        scheduler_run(&sched)
    }

    testing.expect_value(t, real_fiber_done, true)
    testing.expect_value(t, sim_fiber_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].time, 0.0)
    testing.expect(t, sched.clocks[CLOCK_REAL].time >= 0.14)

    // Advance CLOCK_SIM
    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect_value(t, sim_fiber_done, true)
}

@(test)
test_fixed_integer_tick_clock :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    tick50_done := false
    tick100_done := false

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait_steps(f, 50)
        done^ = true
    }, &tick50_done, clock = CLOCK_PHYS)

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait_steps(f, 100)
        done^ = true
    }, &tick100_done, clock = CLOCK_PHYS)

    // Step 1: 30 ticks (fibers start and register wait_steps for 30+50=80 and 30+100=130)
    clock_advance(&sched, CLOCK_PHYS, 0.5, steps = 30)
    scheduler_run(&sched)
    testing.expect_value(t, tick50_done, false)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_PHYS].steps, 30)

    // Step 2: 50 more ticks (steps = 80) -> Fiber 1 wakes!
    clock_advance(&sched, CLOCK_PHYS, 0.8, steps = 50)
    scheduler_run(&sched)
    testing.expect_value(t, tick50_done, true)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_PHYS].steps, 80)

    // Step 3: 50 more ticks (steps = 130) -> Fiber 2 wakes!
    clock_advance(&sched, CLOCK_PHYS, 0.8, steps = 50)
    scheduler_run(&sched)
    testing.expect_value(t, tick100_done, true)
    testing.expect_value(t, sched.clocks[CLOCK_PHYS].steps, 130)
}

@(test)
test_dual_clock_time_scaling :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Dual_Obs :: struct {
        sim_dt:  f32,
        real_dt: f32,
        sim_t:   f64,
        real_t:  f64,
    }
    obs: Dual_Obs

    spawn(&sched, proc(f: ^Fiber, d: ^Dual_Obs) {
        yield(f)
        d.sim_dt = delta_time(f)
        d.sim_t  = current_time(f)
    }, &obs, clock = CLOCK_SIM)

    spawn(&sched, proc(f: ^Fiber, d: ^Dual_Obs) {
        yield(f)
        d.real_dt = delta_time(f)
        d.real_t  = current_time(f)
    }, &obs, clock = CLOCK_REAL)

    // Step 1 (CLOCK_SIM at 0.5x scale -> 0.05s, CLOCK_REAL at 1.0x -> 0.10s)
    clock_advance(&sched, CLOCK_SIM, 0.10 * 0.5)
    clock_advance(&sched, CLOCK_REAL, 0.10)
    scheduler_run(&sched)

    // Step 2
    clock_advance(&sched, CLOCK_SIM, 0.10 * 0.5)
    clock_advance(&sched, CLOCK_REAL, 0.10)
    scheduler_run(&sched)

    testing.expect(t, abs(obs.real_dt - 0.10) < 0.001)
    testing.expect(t, abs(obs.sim_dt - 0.05) < 0.001)
    testing.expect(t, abs(obs.real_t - 0.20) < 0.001)
    testing.expect(t, abs(obs.sim_t - 0.10) < 0.001)
}

@(test)
test_multi_clock_heap_integrity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    completed_count := 0

    for _ in 0 ..< 20 {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            wait(f, 0.02)
            c^ += 1
        }, &completed_count, clock = CLOCK_REAL)
    }

    for _ in 0 ..< 20 {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            wait(f, 0.02)
            c^ += 1
        }, &completed_count, clock = CLOCK_SIM)
    }

    for _ in 0 ..< 20 {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            wait_steps(f, 3)
            c^ += 1
        }, &completed_count, clock = CLOCK_PHYS)
    }

    for _ in 0 ..< 5 {
        clock_advance(&sched, CLOCK_REAL, 0.01)
        clock_advance(&sched, CLOCK_SIM, 0.01)
        clock_advance(&sched, CLOCK_PHYS, 0.01, steps = 1)
        scheduler_run(&sched)
    }

    testing.expect_value(t, completed_count, 60)
    testing.expect_value(t, len(sched.clocks[CLOCK_REAL].timer_heap), 0)
    testing.expect_value(t, len(sched.clocks[CLOCK_SIM].timer_heap), 0)
    testing.expect_value(t, len(sched.clocks[CLOCK_PHYS].step_waiters), 0)
}

@(test)
test_scope_mass_cancel_mixed_states :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    mixed_scope: Fiber_Scope
    defer scope_destroy(&sched, &mixed_scope)

    sig: Signal
    defer signal_destroy(&sig)

    // 1: Sleeping_Time on CLOCK_SIM
    spawn(&sched, proc(f: ^Fiber) { wait(f, 5.0) }, scope = &mixed_scope, clock = CLOCK_SIM)
    // 2: Sleeping_Time on CLOCK_REAL
    spawn(&sched, proc(f: ^Fiber) { wait(f, 5.0) }, scope = &mixed_scope, clock = CLOCK_REAL)
    // 3: Sleeping_Steps on CLOCK_SIM
    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 100) }, scope = &mixed_scope, clock = CLOCK_SIM)
    // 4: Sleeping_Steps on CLOCK_PHYS
    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 100) }, scope = &mixed_scope, clock = CLOCK_PHYS)
    // 5: Waiting on Signal
    spawn(&sched, proc(f: ^Fiber, s: ^Signal) { signal_wait(f, s) }, &sig, scope = &mixed_scope)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, scope_active_count(&mixed_scope), 5)

    cancelled := scope_cancel(&sched, &mixed_scope)
    testing.expect_value(t, cancelled, 5)
    testing.expect_value(t, scope_active_count(&mixed_scope), 0)
}

@(test)
test_primitives_custom_arena_allocation_fidelity :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    arena_alloc := mem.tracking_allocator(&track)

    {
        ev: Event(int)
        event_init(&ev)
        event_destroy(&ev)
    }
    {
        sig: Signal
        signal_init(&sig)
        signal_destroy(&sig)
    }
    {
        sched: Scheduler
        context.allocator = arena_alloc
        scheduler_init(&sched, 65536, 16)
        scheduler_destroy(&sched)
    }

    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, track.current_memory_allocated, 0)
}

@(test)
test_headless_boss_ai_fuzzing_simulation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Fuzz_Boss :: struct {
        hp:          f32,
        alive:       bool,
        phase:       int,
        shots_fired: int,
        stuns:       int,
        stun_signal: Signal,
    }

    fuzz_patrol_subloop :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.alive {
            wait(f, 0.1)
        }
    }

    fuzz_spiral_shoot :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.alive {
            ticker_wait(f, 0.04)
            b.shots_fired += 1
        }
    }

    fuzz_targeted_burst :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.alive {
            ticker_wait(f, 0.08)
            b.shots_fired += 2
        }
    }

    fuzz_attack_loop_p1 :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.hp > 700.0 && b.alive {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    sync(f,
                        branch(fuzz_spiral_shoot, b, "Spiral"),
                        branch(fuzz_targeted_burst, b, "Burst"),
                    )
                }, b, "P1 Attack Subtree"),
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P1 Stun Watcher"),
            )
            if winner == 1 && b.hp > 700.0 && b.alive {
                b.stuns += 1
                wait(f, 0.15)
            }
        }
    }

    fuzz_attack_loop_p2 :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.hp > 350.0 && b.alive {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    sync(f,
                        branch(fuzz_spiral_shoot, b, "Enraged Spiral"),
                        branch(fuzz_targeted_burst, b, "Enraged Burst"),
                    )
                }, b, "P2 Attack Subtree"),
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P2 Stun Watcher"),
            )
            if winner == 1 && b.hp > 350.0 && b.alive {
                b.stuns += 1
                wait(f, 0.15)
            }
        }
    }

    fuzz_attack_loop_p3 :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        for b.alive {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    sync(f,
                        branch(fuzz_spiral_shoot, b, "Berserk Spiral"),
                        branch(fuzz_targeted_burst, b, "Berserk Burst"),
                    )
                }, b, "P3 Attack Subtree"),
                branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P3 Stun Watcher"),
            )
            if winner == 1 && b.alive {
                b.stuns += 1
                wait(f, 0.10)
            }
        }
    }

    fuzz_boss_master :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        b.phase = 1
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                for b.hp > 700.0 && b.alive { yield(f) }
            }, b, "HP < 700"),
            branch(fuzz_patrol_subloop, b, "Patrol P1"),
            branch(fuzz_attack_loop_p1, b, "Attacks P1"),
        )
        if !b.alive do return

        b.phase = 2
        wait(f, 0.1)
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                for b.hp > 350.0 && b.alive { yield(f) }
            }, b, "HP < 350"),
            branch(fuzz_patrol_subloop, b, "Patrol P2"),
            branch(fuzz_attack_loop_p2, b, "Attacks P2"),
        )
        if !b.alive do return

        b.phase = 3
        wait(f, 0.1)
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                for b.alive { yield(f) }
            }, b, "Death Trigger"),
            branch(fuzz_patrol_subloop, b, "Patrol P3"),
            branch(fuzz_attack_loop_p3, b, "Attacks P3"),
        )
    }

    boss := Fuzz_Boss{hp = 1000.0, alive = true, phase = 1}
    defer signal_destroy(&boss.stun_signal)

    spawn(&sched, fuzz_boss_master, &boss)

    rng_state: u64 = 0x853C49E6748FEA9B
    xorshift64 :: proc(state: ^u64) -> u64 {
        x := state^
        x ~= x << 13
        x ~= x >> 7
        x ~= x << 17
        state^ = x
        return x
    }

    total_emp_pulses := 0
    for _ in 0 ..< 2000 {
        r := xorshift64(&rng_state)
        dt := (5.0 + f32(r % 25)) / 1000.0
        if boss.alive {
            boss.hp -= 0.65
            if boss.hp <= 0.0 do boss.alive = false
        }
        if (r % 25) == 0 && boss.alive {
            signal_emit(&sched, &boss.stun_signal)
            total_emp_pulses += 1
        }
        scheduler_step(&sched, dt)

        stats := scheduler_pool_stats(&sched)
        testing.expect(t, stats.active_fibers <= 16)
        testing.expect_value(t, stats.total_stacks, stats.active_fibers + stats.free_fibers)
    }

    testing.expect(t, !boss.alive)
    testing.expect_value(t, boss.phase, 3)
    testing.expect(t, total_emp_pulses >= 10)
    testing.expect(t, boss.stuns >= 5)
    testing.expect(t, boss.shots_fired >= 100)

    final_stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, final_stats.active_fibers, 0)
}

@(test)
test_phase_transition_emp_coincidence_fuzzing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Boss_State :: struct {
        hp:                 f32,
        phase:              int,
        alive:              bool,
        p1_attacks_spawned: int,
        p2_attacks_spawned: int,
        p3_attacks_spawned: int,
        phase1_in_p2_error: bool,
        phase2_in_p3_error: bool,
        stun_signal:        Signal,
    }

    b_state := Boss_State{hp = 1000.0, phase = 1, alive = true}
    defer signal_destroy(&b_state.stun_signal)

    p1_attack_proc :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 1 {
            b.p1_attacks_spawned += 1
            wait(f, 0.05)
            if b.phase != 1 do b.phase1_in_p2_error = true
        }
    }

    p2_attack_proc :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 2 {
            b.p2_attacks_spawned += 1
            wait(f, 0.05)
            if b.phase != 2 do b.phase2_in_p3_error = true
        }
    }

    p3_attack_proc :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 3 {
            b.p3_attacks_spawned += 1
            wait(f, 0.05)
        }
    }

    p1_loop :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.hp > 700.0 && b.alive && b.phase == 1 {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    sync(f,
                        branch(p1_attack_proc, b, "P1 Attack A"),
                        branch(p1_attack_proc, b, "P1 Attack B"),
                    )
                }, b, "P1 Attacks"),
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P1 Stun"),
            )
            if winner == 1 && b.hp > 700.0 && b.alive && b.phase == 1 {
                wait(f, 0.2)
            }
        }
    }

    p2_loop :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.hp > 350.0 && b.alive && b.phase == 2 {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    sync(f,
                        branch(p2_attack_proc, b, "P2 Attack A"),
                        branch(p2_attack_proc, b, "P2 Attack B"),
                    )
                }, b, "P2 Attacks"),
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P2 Stun"),
            )
            if winner == 1 && b.hp > 350.0 && b.alive && b.phase == 2 {
                wait(f, 0.2)
            }
        }
    }

    p3_loop :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 3 {
            winner := race(f,
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    sync(f,
                        branch(p3_attack_proc, b, "P3 Attack A"),
                        branch(p3_attack_proc, b, "P3 Attack B"),
                    )
                }, b, "P3 Attacks"),
                branch(proc(f: ^Fiber, b: ^Boss_State) {
                    signal_wait(f, &b.stun_signal)
                }, b, "P3 Stun"),
            )
            if winner == 1 && b.alive && b.phase == 3 {
                wait(f, 0.1)
            }
        }
    }

    boss_ai_timeline :: proc(f: ^Fiber, b: ^Boss_State) {
        b.phase = 1
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                for b.hp > 700.0 && b.alive { yield(f) }
            }, b, "HP < 700 Trigger"),
            branch(p1_loop, b, "P1 Loop"),
        )
        if !b.alive do return

        b.phase = 2
        wait(f, 0.1)
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                for b.hp > 350.0 && b.alive { yield(f) }
            }, b, "HP < 350 Trigger"),
            branch(p2_loop, b, "P2 Loop"),
        )
        if !b.alive do return

        b.phase = 3
        wait(f, 0.1)
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                for b.alive { yield(f) }
            }, b, "Death Trigger"),
            branch(p3_loop, b, "P3 Loop"),
        )
    }

    spawn(&sched, boss_ai_timeline, &b_state)

    for frame in 0 ..< 1000 {
        if b_state.alive {
            b_state.hp -= 1.3
            if b_state.hp <= 0 do b_state.alive = false
        }
        if (b_state.hp >= 690.0 && b_state.hp <= 710.0) || (b_state.hp >= 340.0 && b_state.hp <= 360.0) || (frame % 20 == 0) {
            signal_emit(&sched, &b_state.stun_signal)
        }
        scheduler_step(&sched, 0.016)
        testing.expect(t, !b_state.phase1_in_p2_error)
        testing.expect(t, !b_state.phase2_in_p3_error)
    }

    testing.expect(t, !b_state.alive)
    testing.expect_value(t, b_state.phase, 3)
    testing.expect(t, b_state.p1_attacks_spawned > 0)
    testing.expect(t, b_state.p2_attacks_spawned > 0)
    testing.expect(t, b_state.p3_attacks_spawned > 0)

    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.active_fibers, 0)
}

@(test)
test_wait_queue_defensive_and_paused_dispatch :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    q1, q2: Wait_Queue
    f: Fiber
    f.handle = 1

    wait_queue_push_back(&q1, &f)
    testing.expect_value(t, f.current_wait_queue, &q1)

    // Cross-queue removal must fail defensively
    removed_wrong := wait_queue_remove(&q2, &f)
    testing.expect(t, !removed_wrong)
    testing.expect_value(t, f.current_wait_queue, &q1)

    removed_ok := wait_queue_remove(&q1, &f)
    testing.expect(t, removed_ok)
    testing.expect_value(t, f.current_wait_queue, nil)
}

@(test)
test_time_scale_defensive_clamping :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    clock_advance(&sched, CLOCK_SIM, 2.5)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].delta, f32(2.5))
    testing.expect(t, abs(sched.clocks[CLOCK_SIM].time - 2.5) < 1e-5)

    // Negative dt clamps to 0.0 to protect min-heap monotonicity
    clock_advance(&sched, CLOCK_SIM, -5.0)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].delta, f32(0.0))
    testing.expect(t, abs(sched.clocks[CLOCK_SIM].time - 2.5) < 1e-5)

    // NaN dt clamps to 0.0
    nan_val := math.nan_f32()
    clock_advance(&sched, CLOCK_SIM, nan_val)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].delta, f32(0.0))
    testing.expect(t, abs(sched.clocks[CLOCK_SIM].time - 2.5) < 1e-5)
}

@(test)
test_scheduler_destroy_wait_queue_unlinking :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        signal_wait(f, s)
    }, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, sig.waiters.head != nil, true)

    // Destroy scheduler while fiber is still in sig.waiters
    scheduler_destroy(&sched)

    // Outliving signal waiters list must have been unlinked to prevent UAF!
    testing.expect_value(t, sig.waiters.head == nil, true)
    testing.expect_value(t, sig.waiters.tail == nil, true)
}

@(test)
test_spawn_real_val_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Payload :: struct {
        x:     int,
        y:     int,
        out_x: ^int,
        out_y: ^int,
    }

    res_x, res_y: int = 0, 0
    p := Payload{x = 42, y = 84, out_x = &res_x, out_y = &res_y}

    spawn(&sched, proc(f: ^Fiber, data: Payload) {
        wait(f, 0.05)
        data.out_x^ = data.x
        data.out_y^ = data.y
    }, p, clock = CLOCK_REAL)

    // Advance only CLOCK_REAL while CLOCK_SIM is not stepped
    for _ in 0 ..< 10 {
        clock_advance(&sched, CLOCK_REAL, 0.02)
        scheduler_run(&sched)
    }

    testing.expect_value(t, res_x, 42)
    testing.expect_value(t, res_y, 84)
}

@(test)
test_real_time_fiber_paused_yield :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    step_count := 0
    spawn(&sched, proc(f: ^Fiber, counter: ^int) {
        for i := 0; i < 5; i += 1 {
            counter^ += 1
            if i % 2 == 0 {
                yield(f)
            } else {
                wait(f, 0.0)
            }
        }
    }, &step_count, name = "Realtime Paused Worker", clock = CLOCK_REAL)

    for _ in 0 ..< 6 {
        clock_advance(&sched, CLOCK_REAL, 0.016)
        scheduler_run(&sched)
    }

    testing.expect_value(t, step_count, 5)
}

@(test)
test_real_time_ticker_paused_zero_freeze :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ticks := 0
    spawn(&sched, proc(f: ^Fiber, counter: ^int) {
        for i := 0; i < 4; i += 1 {
            ticker_wait(f, 0.01)
            counter^ += 1
        }
    }, &ticks, name = "Realtime Ticker Worker", clock = CLOCK_REAL)

    for _ in 0 ..< 6 {
        clock_advance(&sched, CLOCK_REAL, 0.016)
        scheduler_run(&sched)
    }

    testing.expect_value(t, ticks, 4)
}

@(test)
test_fiber_pool_recycle_wake_clock_sanitization :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    real_clock_observed: Clock_ID = -1
    sim_clock_observed: Clock_ID = -1

    h_real := spawn(&sched, proc(f: ^Fiber, out: ^Clock_ID) {
        out^ = f.clock_id
    }, &real_clock_observed, name = "Real Worker", clock = CLOCK_REAL)

    scheduler_step(&sched, 0.016)

    h_sim := spawn(&sched, proc(f: ^Fiber, out: ^Clock_ID) {
        out^ = f.clock_id
    }, &sim_clock_observed, name = "Sim Worker")

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, real_clock_observed, CLOCK_REAL)
    testing.expect_value(t, sim_clock_observed, CLOCK_SIM)
    testing.expect_value(t, fiber_is_alive(&sched, h_real), false)
    testing.expect_value(t, fiber_is_alive(&sched, h_sim), false)
}

@(test)
test_fiber_owned_ticker_zero_drift_and_rebase :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ticks := 0
    spawn(&sched, proc(f: ^Fiber, count: ^int) {
        for {
            ticker_wait(f, 0.05)
            count^ += 1
        }
    }, &ticks)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect_value(t, ticks, 4)

    fiber_a_ticks := 0
    fiber_b_ticks := 0

    spawn(&sched, proc(f: ^Fiber, a_ptr: ^int) {
        for {
            ticker_wait(f, 0.02)
            a_ptr^ += 1
        }
    }, &fiber_a_ticks)

    spawn(&sched, proc(f: ^Fiber, b_ptr: ^int) {
        for {
            ticker_wait(f, 0.04)
            b_ptr^ += 1
        }
    }, &fiber_b_ticks)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect_value(t, fiber_a_ticks, 4)
    testing.expect_value(t, fiber_b_ticks, 2)
}

@(test)
test_scheduler_reinit_no_memory_leak :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    alloc := mem.tracking_allocator(&track)
    context.allocator = alloc

    sched: Scheduler
    scheduler_init(&sched, alloc_mode = .Standard_Slab, allocator = alloc)
    scheduler_prewarm(&sched, 64)

    scope: Fiber_Scope
    sig: Signal
    defer signal_destroy(&sig)

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)
    spawn(&sched, proc(f: ^Fiber) {
        yield(f)
    }, scope = &scope)
    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        signal_wait(f, s)
    }, &sig, scope = &scope)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, scope_active_count(&scope), 3)

    // Re-initialize without calling scheduler_destroy first
    scheduler_init(&sched, alloc_mode = .Standard_Slab, allocator = alloc)
    scheduler_prewarm(&sched, 64)

    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect(t, sig.waiters.head == nil)

    scheduler_destroy(&sched)
    scheduler_destroy(&sched)

    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, len(track.bad_free_array), 0)
}

@(test)
test_api_qol_fiber_overloads_and_nested_cleanup_chaining :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    QoL_Ctx :: struct {
        sig:          Signal,
        ev:           Event(int),
        child_scope:  Fiber_Scope,
        target_h:     Fiber_Handle,
        ev_received:  int,
        sig_woke:     bool,
        status_alive: bool,
        status_val:   Fiber_Status,
    }
    qctx: QoL_Ctx
    signal_init(&qctx.sig)
    defer signal_destroy(&qctx.sig)
    event_init(&qctx.ev)
    defer event_destroy(&qctx.ev)

    qctx.target_h = spawn(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    })

    spawn(&sched, proc(f: ^Fiber, c: ^QoL_Ctx) {
        wait(f, 10.0)
    }, &qctx, scope = &qctx.child_scope)

    spawn(&sched, proc(f: ^Fiber, c: ^QoL_Ctx) {
        signal_wait(f, &c.sig)
        c.sig_woke = true
    }, &qctx)

    spawn(&sched, proc(f: ^Fiber, c: ^QoL_Ctx) {
        if val, ok := event_wait(f, &c.ev); ok {
            c.ev_received = val
        }
    }, &qctx)

    scheduler_step(&sched, 0.01)

    spawn(&sched, proc(f: ^Fiber, c: ^QoL_Ctx) {
        c.status_alive = fiber_is_alive(f, c.target_h)
        st, _ := fiber_status(f, c.target_h)
        c.status_val = st

        signal_emit(f, &c.sig)
        event_emit(f, &c.ev, 777)

        fiber_cancel(f, c.target_h)
        scope_cancel(f, &c.child_scope)
        scope_destroy(f, &c.child_scope)
    }, &qctx)

    scheduler_step(&sched, 0.01)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, qctx.status_alive, true)
    testing.expect_value(t, qctx.status_val, Fiber_Status.Sleeping_Time)
    testing.expect_value(t, qctx.sig_woke, true)
    testing.expect_value(t, qctx.ev_received, 777)
    testing.expect_value(t, fiber_is_alive(&sched, qctx.target_h), false)
    testing.expect_value(t, scope_active_count(&qctx.child_scope), 0)
}

// ============================================================================
// Verse Concurrency Semantics & Latched State Tests
// ============================================================================

@(test)
test_verse_rush_losers_continue :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Rush_Test_Ctx :: struct {
        winner:       int,
        branch0_done: bool,
        branch1_done: bool,
        branch2_done: bool,
    }
    ctx: Rush_Test_Ctx
    ctx.winner = -1

    spawn(&sched, proc(f: ^Fiber, c: ^Rush_Test_Ctx) {
        // Verse rush: first branch to finish wakes parent, losers continue in background!
        w := rush(f,
            branch(proc(f: ^Fiber, c: ^Rush_Test_Ctx) {
                wait(f, 0.02)
                c.branch0_done = true
            }, c, "Branch 0 (Fastest)"),
            branch(proc(f: ^Fiber, c: ^Rush_Test_Ctx) {
                wait(f, 0.05)
                c.branch1_done = true
            }, c, "Branch 1 (Medium)"),
            branch(proc(f: ^Fiber, c: ^Rush_Test_Ctx) {
                wait(f, 0.08)
                c.branch2_done = true
            }, c, "Branch 2 (Slowest)"),
        )
        c.winner = w

        // Parent was woken at 0.02s! Now parent waits until 0.10s to give losers time to complete
        wait(f, 0.08)
    }, &ctx)

    // Prime root fiber at t=0.0 so rush branches start at t=0.0
    scheduler_step(&sched, 0.0)

    // Step 0.02s: Branch 0 completes, rush wakes parent
    scheduler_step(&sched, 0.025)
    testing.expect_value(t, ctx.winner, 0)
    testing.expect_value(t, ctx.branch0_done, true)
    testing.expect_value(t, ctx.branch1_done, false)
    testing.expect_value(t, ctx.branch2_done, false)

    // Advance past 0.05s: Branch 1 should complete in background without being cancelled
    scheduler_step(&sched, 0.035)
    testing.expect_value(t, ctx.branch1_done, true)
    testing.expect_value(t, ctx.branch2_done, false)

    // Advance past 0.08s: Branch 2 should complete in background
    scheduler_step(&sched, 0.035)
    testing.expect_value(t, ctx.branch2_done, true)
}

@(test)
test_verse_rush_failure_recovery_and_parent_rejoin :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Rush_Adv_Ctx :: struct {
        winner_rush: int,
        sync_ok:     bool,
        loser_done:  bool,
    }
    ctx: Rush_Adv_Ctx
    ctx.winner_rush = -99

    spawn(&sched, proc(f: ^Fiber, c: ^Rush_Adv_Ctx) {
        // 1. Rush where branch 0 fails early, branch 1 succeeds at 0.03s, branch 2 takes 0.10s
        w := rush(f,
            branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }, "Branch 0 (Fails)"),
            branch(proc(f: ^Fiber) { wait(f, 0.03) }, "Branch 1 (Succeeds)"),
            branch(proc(f: ^Fiber, c: ^Rush_Adv_Ctx) {
                wait(f, 0.10)
                c.loser_done = true
            }, c, "Branch 2 (Loser Background)"),
        )
        c.winner_rush = w

        // 2. Parent immediately enters a sync join while Branch 2 is still running in background!
        s_ok := sync(f,
            branch(proc(f: ^Fiber) { wait(f, 0.04) }, "Sync Child A"),
            branch(proc(f: ^Fiber) { wait(f, 0.04) }, "Sync Child B"),
        )
        c.sync_ok = s_ok

        // Wait a bit to ensure Branch 2 finishes in background
        wait(f, 0.05)
    }, &ctx)

    // Prime at t=0.0
    scheduler_step(&sched, 0.0)

    // Step to 0.04s: Branch 0 failed, Branch 1 succeeded at 0.03s -> winner_rush must be 1!
    scheduler_step(&sched, 0.04)
    testing.expect_value(t, ctx.winner_rush, 1)
    testing.expect_value(t, ctx.sync_ok, false)
    testing.expect_value(t, ctx.loser_done, false)

    // Step to 0.09s: Parent's sync (0.04s long) completes; Branch 2 (0.10s) still running
    scheduler_step(&sched, 0.05)
    testing.expect_value(t, ctx.sync_ok, true)
    testing.expect_value(t, ctx.loser_done, false)

    // Step to 0.15s: Branch 2 finishes in background without issues
    scheduler_step(&sched, 0.06)
    testing.expect_value(t, ctx.loser_done, true)
}

@(test)
test_branch_scoped_background_and_parent_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Scoped_Ctx :: struct {
        child1_step1: bool,
        child1_step2: bool,
        child2_val:   int,
        parent_done:  bool,
    }
    ctx: Scoped_Ctx

    spawn(&sched, proc(f: ^Fiber, c: ^Scoped_Ctx) {
        // 1. Fire-and-forget child 1
        branch_scoped(f, proc(child: ^Fiber, c: ^Scoped_Ctx) {
            wait(child, 0.02)
            c.child1_step1 = true
            wait(child, 0.10) // Would complete at 0.12s, but parent exits at 0.05s!
            c.child1_step2 = true
        }, c, "Scoped Child 1")

        // 2. Fire-and-forget child 2 (by value)
        Payload :: struct {
            val:  int,
            dest: ^int,
        }
        branch_scoped(f, proc(child: ^Fiber, p: Payload) {
            p.dest^ = p.val * 2
        }, Payload{val = 21, dest = &c.child2_val}, "Scoped Child 2")

        // Parent does NOT wait on children; parent does its own short work
        wait(f, 0.05)
        c.parent_done = true
        // Parent exits here! Scoped Child 1 must be auto-aborted by fiber_cleanup_and_recycle!
    }, &ctx)

    // Prime root fiber at t=0.0: Child 2 runs immediately, Child 1 waits for 0.02s
    scheduler_step(&sched, 0.0)
    testing.expect_value(t, ctx.child2_val, 42)
    testing.expect_value(t, ctx.child1_step1, false)

    // Step to 0.03s: Child 1 step 1 finishes, parent still alive
    scheduler_step(&sched, 0.03)
    testing.expect_value(t, ctx.child1_step1, true)
    testing.expect_value(t, ctx.parent_done, false)

    // Step past 0.05s: Parent exits, aborting Child 1
    scheduler_step(&sched, 0.03)
    testing.expect_value(t, ctx.parent_done, true)
    testing.expect_value(t, ctx.child1_step2, false)

    // Step well past 0.12s to ensure Child 1 was truly aborted and does not run step 2
    scheduler_step(&sched, 0.20)
    testing.expect_value(t, ctx.child1_step2, false)
}

@(test)
test_sticky_event_and_sticky_signal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Sticky_Signal
    sticky_signal_init(&sig)
    defer sticky_signal_destroy(&sig)

    ev: Sticky_Event(int)
    sticky_event_init(&ev)
    defer sticky_event_destroy(&ev)

    Test_Ctx :: struct {
        sig:            ^Sticky_Signal,
        ev:             ^Sticky_Event(int),
        sig_early_woke: bool,
        sig_late_woke:  bool,
        ev_early_val:   int,
        ev_late_val:    int,
    }
    ctx: Test_Ctx
    ctx.sig = &sig
    ctx.ev = &ev

    // Early waiters (before emit)
    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        sticky_signal_wait(f, c.sig)
        c.sig_early_woke = true
    }, &ctx)

    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        if val, ok := sticky_event_wait(f, c.ev); ok {
            c.ev_early_val = val
        }
    }, &ctx)

    // Step once: early waiters are suspended
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.sig_early_woke, false)
    testing.expect_value(t, ctx.ev_early_val, 0)
    testing.expect_value(t, sticky_signal_is_set(&sig), false)
    testing.expect_value(t, sticky_event_is_set(&ev), false)

    // Emit both sticky primitives
    sticky_signal_emit(&sched, &sig)
    sticky_event_emit(&sched, &ev, 999)

    testing.expect_value(t, sticky_signal_is_set(&sig), true)
    testing.expect_value(t, sticky_event_is_set(&ev), true)
    peek_val, peek_ok := sticky_event_peek(&ev)
    testing.expect_value(t, peek_ok, true)
    testing.expect_value(t, peek_val, 999)

    // Step: early waiters wake up
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.sig_early_woke, true)
    testing.expect_value(t, ctx.ev_early_val, 999)

    // Late waiters (after emit): must NOT suspend, should return immediately!
    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        sticky_signal_wait(f, c.sig)
        c.sig_late_woke = true
    }, &ctx)

    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        if val, ok := sticky_event_wait(f, c.ev); ok {
            c.ev_late_val = val
        }
    }, &ctx)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.sig_late_woke, true)
    testing.expect_value(t, ctx.ev_late_val, 999)

    // Test reset
    sticky_signal_reset(&sig)
    sticky_event_reset(&ev)
    testing.expect_value(t, sticky_signal_is_set(&sig), false)
    testing.expect_value(t, sticky_event_is_set(&ev), false)
}

@(test)
test_yield_now_same_tick_interleave :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    trace: [dynamic]int
    defer delete(trace)

    spawn(&sched, proc(f: ^Fiber, tr: ^[dynamic]int) {
        append(tr, 1)
        yield_now(f)
        append(tr, 3)
        yield_now(f)
        append(tr, 5)
    }, &trace)

    spawn(&sched, proc(f: ^Fiber, tr: ^[dynamic]int) {
        append(tr, 2)
        yield_now(f)
        append(tr, 4)
        yield_now(f)
        append(tr, 6)
    }, &trace)

    // Single step with dt=0.0: all interleaved steps must run in the EXACT SAME frame/tick!
    scheduler_step(&sched, 0.0)

    testing.expect_value(t, len(trace), 6)
    if len(trace) == 6 {
        testing.expect_value(t, trace[0], 1)
        testing.expect_value(t, trace[1], 2)
        testing.expect_value(t, trace[2], 3)
        testing.expect_value(t, trace[3], 4)
        testing.expect_value(t, trace[4], 5)
        testing.expect_value(t, trace[5], 6)
    }
}

@(test)
test_rush_active_coord_reentry :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    rush_winner := -1
    rush_loser_finished := false
    race_winner_index := -1
    race_loser_aborted := false

    Data_Box :: struct {
        p_rush_winner:        ^int,
        p_rush_loser:         ^bool,
        p_race_winner:        ^int,
        p_race_loser_aborted: ^bool,
    }

    box := Data_Box{
        p_rush_winner        = &rush_winner,
        p_rush_loser         = &rush_loser_finished,
        p_race_winner        = &race_winner_index,
        p_race_loser_aborted = &race_loser_aborted,
    }

    spawn(&sched, proc(f: ^Fiber, b: ^Data_Box) {
        // Step 1: Execute a rush where branch 0 wins immediately, leaving branch 1 running in background
        w := rush(f,
            branch(proc(f: ^Fiber) {
                // Winner finishes immediately
            }),
            branch(proc(f: ^Fiber, p_fin: ^bool) {
                wait_steps(f, 3)
                p_fin^ = true
            }, b.p_rush_loser),
        )
        b.p_rush_winner^ = w

        // Step 2: Immediately execute a race!
        // This overwrites f.active_coord with a new coord_id.
        // It must NOT cancel the earlier rush loser, nor should the rush loser's completion interfere with this race.
        race_w := race(f,
            branch(proc(f: ^Fiber, p_idx: ^int) {
                wait_steps(f, 1)
                p_idx^ = 0
            }, b.p_race_winner),
            branch(proc(f: ^Fiber, p_ab: ^bool) {
                fiber_defer(f, proc(user_data: rawptr) {
                    ptr := (^bool)(user_data)
                    ptr^ = true
                }, p_ab)
                wait_steps(f, 10)
            }, b.p_race_loser_aborted),
        )
        b.p_race_winner^ = race_w
        wait_steps(f, 5)
    }, &box)

    // Step 0: Parent runs rush (branch 0 wins), enters race
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, rush_winner, 0)
    testing.expect_value(t, rush_loser_finished, false)

    // Step 1: Race branch 0 finishes and wins, aborts race branch 1
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, race_winner_index, 0)
    testing.expect_value(t, race_loser_aborted, true)
    testing.expect_value(t, rush_loser_finished, false) // Rush loser STILL alive!

    // Step 2 & 3: Advance until rush loser finishes
    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, rush_loser_finished, true)
}

@(test)
test_fiber_defer_lifo_order :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    trace: [dynamic]int
    defer delete(trace)

    // Sub-test 1: Clean finish executes defers in LIFO order (3 -> 2 -> 1)
    spawn(&sched, proc(f: ^Fiber, tr: ^[dynamic]int) {
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 1)
        }, tr)
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 2)
        }, tr)
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 3)
        }, tr)
    }, &trace)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, len(trace), 3)
    if len(trace) == 3 {
        testing.expect_value(t, trace[0], 3)
        testing.expect_value(t, trace[1], 2)
        testing.expect_value(t, trace[2], 1)
    }

    clear(&trace)

    // Sub-test 2: Cancellation/abort also executes defers in LIFO order (3 -> 2 -> 1)
    h := spawn(&sched, proc(f: ^Fiber, tr: ^[dynamic]int) {
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 1)
        }, tr)
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 2)
        }, tr)
        fiber_defer(f, proc(user_data: rawptr) {
            append((^[dynamic]int)(user_data), 3)
        }, tr)
        wait_steps(f, 100)
    }, &trace)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, len(trace), 0)

    fiber_cancel(&sched, h)
    testing.expect_value(t, len(trace), 3)
    if len(trace) == 3 {
        testing.expect_value(t, trace[0], 3)
        testing.expect_value(t, trace[1], 2)
        testing.expect_value(t, trace[2], 1)
    }
}

@(test)
test_combinator_with_helpers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Test_Context :: struct {
        sync_ok:  bool,
        sync_a:   bool,
        sync_b:   bool,
        race_won: int,
    }

    ctx: Test_Context

    spawn(&sched, proc(f: ^Fiber, c: ^Test_Context) {
        // sync_with passing shared context pointer directly
        ok := sync_with(f, c,
            proc(f: ^Fiber, c: ^Test_Context) {
                c.sync_a = true
            },
            proc(f: ^Fiber, c: ^Test_Context) {
                c.sync_b = true
            },
        )
        c.sync_ok = ok

        // race_with
        w := race_with(f, c,
            proc(f: ^Fiber, c: ^Test_Context) {
                wait_steps(f, 5)
            },
            proc(f: ^Fiber, c: ^Test_Context) {
                // wins immediately
            },
        )
        c.race_won = w

        // parameterless procs in sync
        _ = sync(f,
            proc(f: ^Fiber) {
                // parameterless arm 0
            },
            proc(f: ^Fiber) {
                // parameterless arm 1
            },
        )
    }, &ctx)

    scheduler_step(&sched, 0.016)
    testing.expect(t, ctx.sync_ok)
    testing.expect_value(t, ctx.sync_a, true)
    testing.expect_value(t, ctx.sync_b, true)
    testing.expect_value(t, ctx.race_won, 1)
}

@(test)
test_branch_primitives_and_with_signal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)

    Signal_Test_Pkg :: struct {
        sig: ^Signal,
        res: ^bool,
    }

    interrupted1 := false
    pkg1 := Signal_Test_Pkg{sig = &sig, res = &interrupted1}
    spawn(&sched, proc(f: ^Fiber, p: ^Signal_Test_Pkg) {
        p.res^ = with_signal(f, p.sig, proc(f: ^Fiber) {
            wait_steps(f, 10)
        })
    }, &pkg1)

    // Emitter fiber
    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        wait_steps(f, 2)
        signal_emit(f, s)
    }, &sig)

    // Step 0..3
    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, interrupted1, true)

    // Now test with_signal when task finishes normally WITHOUT interruption:
    interrupted2 := true
    pkg2 := Signal_Test_Pkg{sig = &sig, res = &interrupted2}
    spawn(&sched, proc(f: ^Fiber, p: ^Signal_Test_Pkg) {
        p.res^ = with_signal(f, p.sig, proc(f: ^Fiber) {
            wait_steps(f, 1)
        })
    }, &pkg2)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, interrupted2, false)
}

@(test)
test_task_future :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    task: Task(int)
    task_init(&task)

    // Worker fiber computes value and completes the task
    spawn(&sched, proc(f: ^Fiber, tk: ^Task(int)) {
        wait_steps(f, 2)
        task_complete(f, tk, 42)
    }, &task)

    Await_Box :: struct {
        val1: int,
        ok1:  bool,
        val2: int,
        ok2:  bool,
    }

    box: Await_Box

    Data_Pkg :: struct {
        task: ^Task(int),
        box:  ^Await_Box,
    }

    pkg := Data_Pkg{task = &task, box = &box}

    // Awaiter fiber awaits task before it's completed
    spawn(&sched, proc(f: ^Fiber, p: ^Data_Pkg) {
        val, ok := task_await(f, p.task)
        p.box.val1 = val
        p.box.ok1 = ok
    }, &pkg)

    testing.expect_value(t, task_is_ready(&task), false)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, task_is_ready(&task), true)
    testing.expect(t, box.ok1)
    testing.expect_value(t, box.val1, 42)

    // Awaiter fiber awaits task AFTER it is already completed (latched state instant return!)
    spawn(&sched, proc(f: ^Fiber, p: ^Data_Pkg) {
        val, ok := task_await(f, p.task)
        p.box.val2 = val
        p.box.ok2 = ok
    }, &pkg)

    scheduler_step(&sched, 0.016)
    testing.expect(t, box.ok2)
    testing.expect_value(t, box.val2, 42)

    // Also test spawn_task one-liner helper:
    task2: Task(string)
    spawn_task(&sched, &task2, proc(f: ^Fiber) -> string {
        wait_steps(f, 1)
        return "verse_task_result"
    })

    task2_res: string
    task2_ok:  bool
    Task2_Pkg :: struct {
        tk:  ^Task(string),
        res: ^string,
        ok:  ^bool,
    }
    t2_pkg := Task2_Pkg{tk = &task2, res = &task2_res, ok = &task2_ok}
    spawn(&sched, proc(f: ^Fiber, p: ^Task2_Pkg) {
        val, ok := task_await(f, p.tk)
        p.res^ = val
        p.ok^ = ok
    }, &t2_pkg)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect(t, task2_ok)
    testing.expect_value(t, task2_res, "verse_task_result")
}
