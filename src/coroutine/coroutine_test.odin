package coroutine

import "core:testing"
import "core:fmt"
import "core:math/rand"
import "core:math"
import "core:mem"

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
// Test 5: Wait Until Condition
// ============================================================================

@(test)
test_wait_until_condition :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Cond_Data :: struct {
        flag: bool,
        completed: bool,
    }

    data := Cond_Data{flag = false, completed = false}

    spawn(&sched, proc(f: ^Fiber, d: ^Cond_Data) {
        wait_until(f, proc(d: ^Cond_Data) -> bool {
            return d.flag
        }, d)
        d.completed = true
    }, &data)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, data.completed, false)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, data.completed, false)

    data.flag = true
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, data.completed, true)
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
        f.cleanup_proc = proc(data: rawptr) {
            ptr := (^bool)(data)
            ptr^ = true
        }
        wait_frames(f, 100)
    }, &cleaned_up)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, cleaned_up, false)

    // Cancel fiber mid-sleep
    fiber_cancel(&sched, handle)

    testing.expect_value(t, cleaned_up, true)
}

// ============================================================================
// Test 10: Tween Interpolation
// ============================================================================

@(test)
test_tween_interpolation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    val: f32 = 0.0
    spawn(&sched, proc(f: ^Fiber, v: ^f32) {
        tween(f, v, 0.0, 100.0, 1.0, ease_linear)
    }, &val)

    scheduler_step(&sched, 0.0) // initial
    testing.expect_value(t, val, 0.0)

    scheduler_step(&sched, 0.5) // half way
    testing.expect(t, val >= 49.0 && val <= 51.0, fmt.tprintf("Expected ~50.0, got %v", val))

    scheduler_step(&sched, 0.5) // finished
    testing.expect_value(t, val, 100.0)
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
// Test 13: Time Scaling & Scheduler Pause
// ============================================================================

@(test)
test_time_scaling_and_pause :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    counter := 0
    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        c^ = 1
        wait(f, 1.0)
        c^ = 2
    }, &counter)

    scheduler_set_paused(&sched, true)
    scheduler_step(&sched, 0.5)
    testing.expect_value(t, counter, 0)

    scheduler_set_paused(&sched, false)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 1)

    scheduler_set_time_scale(&sched, 2.0)
    scheduler_step(&sched, 0.5)
    testing.expect_value(t, counter, 2)
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
                        f.cleanup_proc = proc(data: rawptr) {
                            ptr := (^Descendant_State)(data)
                            ptr.grandchild_cleaned_up = true
                        }
                        f.user_data = rawptr(s)
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
// Test 21: Immediate Condition Satisfaction (Zero-Frame Delay)
// ============================================================================

@(test)
test_condition_immediate_satisfaction :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    flag := true
    progress := 0

    spawn(&sched, proc(f: ^Fiber, p: ^int) {
        p^ = 1
        // Condition is already true! Should return immediately without suspending
        wait_until(f, proc() -> bool { return true })
        p^ = 2
    }, &progress)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 2) // Completed in single tick!
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
// Test 25: Heterogeneous Scope Mass Cancellation
// ============================================================================

@(test)
test_heterogeneous_scope_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    dummy_cond := false

    // 1. Fiber in Sleeping_Time
    spawn(&sched, proc(f: ^Fiber) { wait(f, 100.0) }, scope = &scope)

    // 2. Fiber in Sleeping_Frames
    spawn(&sched, proc(f: ^Fiber) { wait_frames(f, 500) }, scope = &scope)

    // 3. Fiber in Waiting_Condition
    spawn(&sched, proc(f: ^Fiber, cond_ptr: ^bool) {
        wait_until(f, proc(c: ^bool) -> bool { return c^ }, cond_ptr)
    }, &dummy_cond, scope = &scope)

    // 4. Fiber in Suspended_Join (sync)
    spawn(&sched, proc(f: ^Fiber) {
        sync(f,
            branch(proc(f: ^Fiber) { wait_frames(f, 100) }),
            branch(proc(f: ^Fiber) { wait_frames(f, 100) }),
        )
    }, scope = &scope)

    // Step 1 frame to put all fibers into their respective waiting queues
    scheduler_step(&sched, 0.016)

    testing.expect(t, len(sched.timer_heap) > 0, "Timer heap should have waiter")
    testing.expect(t, len(sched.frame_waiters) > 0, "Frame waiters should have waiter")
    testing.expect(t, len(sched.condition_waiters) > 0, "Condition waiters should have waiter")

    // Mass cancel scope
    scope_cancel(&sched, &scope)

    // Verify all queues are emptied of scope fibers
    testing.expect_value(t, len(sched.timer_heap), 0)
    testing.expect_value(t, len(sched.frame_waiters), 0)
    testing.expect_value(t, len(sched.condition_waiters), 0)
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
// Test 32: Fiber Mutex Mutual Exclusion & Queueing
// ============================================================================

@(test)
test_fiber_mutex_contention :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    execution_order: [dynamic]int
    execution_order = make([dynamic]int)
    defer delete(execution_order)

    Payload :: struct {
        id:        int,
        mutex:     ^Fiber_Mutex,
        log:       ^[dynamic]int,
    }

    p1 := Payload{id = 1, mutex = &m, log = &execution_order}
    p2 := Payload{id = 2, mutex = &m, log = &execution_order}

    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        mutex_lock(f, p.mutex)
        append(p.log, p.id) // Critical section start
        wait_frames(f, 3)
        append(p.log, p.id + 10) // Critical section end
        mutex_unlock(f.sched, p.mutex)
    }, &p1)

    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        mutex_lock(f, p.mutex)
        append(p.log, p.id)
        wait_frames(f, 1)
        append(p.log, p.id + 10)
        mutex_unlock(f.sched, p.mutex)
    }, &p2)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, len(execution_order), 4)
    // Fiber 1 must acquire, hold, and release BEFORE Fiber 2 enters critical section
    testing.expect_value(t, execution_order[0], 1)
    testing.expect_value(t, execution_order[1], 11)
    testing.expect_value(t, execution_order[2], 2)
    testing.expect_value(t, execution_order[3], 12)
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
// Test 35: CSP Unbuffered Channel Synchronous Rendezvous
// ============================================================================

@(test)
test_channel_synchronous_rendezvous :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    received_val := 0

    Payload :: struct {
        ch:  ^Channel(int),
        out: ^int,
    }
    payload := Payload{ch = &ch, out = &received_val}

    // Receiver fiber waits on channel
    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        val, ok := chan_recv(f, p.ch)
        if ok {
            p.out^ = val
        }
    }, &payload)

    // Sender fiber sends value
    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        chan_send(f, p.ch, 777)
    }, &payload)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, received_val, 777)
}

// ============================================================================
// Test 36: CSP Buffered Channel FIFO Ordering
// ============================================================================

@(test)
test_channel_buffered_fifo :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 3)
    defer chan_destroy(&ch)

    results: [dynamic]int
    results = make([dynamic]int)
    defer delete(results)

    Payload :: struct {
        ch:  ^Channel(int),
        res: ^[dynamic]int,
    }
    p := Payload{ch = &ch, res = &results}

    // Producer sends 3 items
    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        chan_send(f, p.ch, 10)
        chan_send(f, p.ch, 20)
        chan_send(f, p.ch, 30)
    }, &p)

    // Consumer reads 3 items
    spawn(&sched, proc(f: ^Fiber, p: ^Payload) {
        for _ in 0 ..< 3 {
            val, ok := chan_recv(f, p.ch)
            if ok {
                append(p.res, val)
            }
        }
    }, &p)

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, len(results), 3)
    testing.expect_value(t, results[0], 10)
    testing.expect_value(t, results[1], 20)
    testing.expect_value(t, results[2], 30)
}

// ============================================================================
// Test 37: Channel Close and Drain Remaining Items
// ============================================================================

@(test)
test_channel_close_and_drain :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(string)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    chan_try_send(&ch, "alpha")
    chan_try_send(&ch, "beta")
    chan_close(&ch)

    // Cannot send to closed channel
    testing.expect_value(t, chan_try_send(&ch, "gamma"), false)

    // Can still drain buffered values
    val1, ok1 := chan_try_recv(&ch)
    testing.expect_value(t, ok1, true)
    testing.expect_value(t, val1, "alpha")

    val2, ok2 := chan_try_recv(&ch)
    testing.expect_value(t, ok2, true)
    testing.expect_value(t, val2, "beta")

    // Empty and closed
    _, ok3 := chan_try_recv(&ch)
    testing.expect_value(t, ok3, false)
}

// ============================================================================
// Test 38: Stateful Pull-Based Generator Sequence
// ============================================================================

@(test)
test_generator_lazy_sequence :: proc(t: ^testing.T) {
    gen: Generator(int)
    generator_init(&gen, proc(f: ^Fiber, g: ^Generator(int)) {
        a, b := 0, 1
        for _ in 0 ..< 6 {
            yield_value(f, g, a)
            next := a + b
            a = b
            b = next
        }
    })
    defer generator_destroy(&gen)

    expected := [6]int{0, 1, 1, 2, 3, 5}
    for i in 0 ..< 6 {
        val, ok := generator_next(&gen)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, expected[i])
    }

    // Sequence exhausted
    _, ok_end := generator_next(&gen)
    testing.expect_value(t, ok_end, false)
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
// Test 46: Vector Tween Overloads ([2]f32, [3]f32, [4]f32)
// ============================================================================

@(test)
test_tween_vectors :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    v2_out: [2]f32
    v3_out: [3]f32
    v4_out: [4]f32

    spawn(&sched, proc(f: ^Fiber, p2: ^[2]f32) {
        tween(f, p2, [2]f32{0, 0}, [2]f32{100, 200}, 0.1)
    }, &v2_out)

    spawn(&sched, proc(f: ^Fiber, p3: ^[3]f32) {
        tween(f, p3, [3]f32{10, 20, 30}, [3]f32{40, 50, 60}, 0.1)
    }, &v3_out)

    spawn(&sched, proc(f: ^Fiber, p4: ^[4]f32) {
        tween(f, p4, [4]f32{1, 2, 3, 4}, [4]f32{5, 6, 7, 8}, 0.1)
    }, &v4_out)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, v2_out.x, 100.0)
    testing.expect_value(t, v2_out.y, 200.0)

    testing.expect_value(t, v3_out.x, 40.0)
    testing.expect_value(t, v3_out.y, 50.0)
    testing.expect_value(t, v3_out.z, 60.0)

    testing.expect_value(t, v4_out.x, 5.0)
    testing.expect_value(t, v4_out.y, 6.0)
    testing.expect_value(t, v4_out.z, 7.0)
    testing.expect_value(t, v4_out.w, 8.0)
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
// Test 48: wait_while Helper
// ============================================================================

@(test)
test_wait_while :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    State :: struct {
        is_charging: bool,
        finished:    bool,
    }

    state := State{is_charging = true, finished = false}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        wait_while(f, proc(s: ^State) -> bool {
            return s.is_charging
        }, s)
        s.finished = true
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.finished, false)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.finished, false)

    // Clear charging condition
    state.is_charging = false
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.finished, true)
}

// ============================================================================
// Test 49: wait_until by Value
// ============================================================================

@(test)
test_wait_until_val :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    threshold: f32 = 50.0
    ran := false

    spawn(&sched, proc(f: ^Fiber, r: ^bool) {
        current_val := f32(10.0)
        // Wait until predicate using captured value threshold
        wait_until(f, proc(thresh: f32) -> bool {
            return thresh >= 50.0
        }, f32(50.0))
        r^ = true
    }, &ran)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, ran, true)
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
// Test 53: Expanded Game-Juice Easing Functions (Bounce, Back, Elastic)
// ============================================================================

@(test)
test_expanded_easing_functions :: proc(t: ^testing.T) {
    // 1. Boundary tests (t=0 -> 0, t=1 -> 1)
    testing.expect(t, math.abs(ease_out_bounce(0.0) - 0.0) < 0.001, "ease_out_bounce(0) == 0")
    testing.expect(t, math.abs(ease_out_bounce(1.0) - 1.0) < 0.001, "ease_out_bounce(1) == 1")

    testing.expect(t, math.abs(ease_out_back(0.0) - 0.0) < 0.001, "ease_out_back(0) == 0")
    testing.expect(t, math.abs(ease_out_back(1.0) - 1.0) < 0.001, "ease_out_back(1) == 1")

    testing.expect(t, math.abs(ease_out_elastic(0.0) - 0.0) < 0.001, "ease_out_elastic(0) == 0")
    testing.expect(t, math.abs(ease_out_elastic(1.0) - 1.0) < 0.001, "ease_out_elastic(1) == 1")

    // 2. Overshoot properties (ease_out_back exceeds 1.0 before settling to 1.0)
    mid_back := ease_out_back(0.8)
    testing.expect(t, mid_back > 1.0, "ease_out_back overshoots past 1.0")

    // 3. Easing inside tween execution
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    out_val: f32 = 0.0
    spawn(&sched, proc(f: ^Fiber, out: ^f32) {
        tween(f, out, 0.0, 100.0, 0.1, ease_out_bounce)
    }, &out_val)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, out_val, 100.0)
}

// ============================================================================
// Test 54: Channel O(1) Circular Ring Buffer High-Throughput Wraparound
// ============================================================================

@(test)
test_channel_ring_buffer_wraparound :: proc(t: ^testing.T) {
    ch: Channel(int)
    chan_init(&ch, capacity = 4)
    defer chan_destroy(&ch)

    testing.expect_value(t, chan_is_empty(&ch), true)
    testing.expect_value(t, chan_is_full(&ch), false)
    testing.expect_value(t, chan_count(&ch), 0)

    // Push 4 items (fills buffer)
    for i in 0 ..< 4 {
        ok := chan_try_send(&ch, (i + 1) * 10)
        testing.expect_value(t, ok, true)
    }

    testing.expect_value(t, chan_is_full(&ch), true)
    testing.expect_value(t, chan_count(&ch), 4)

    // Cannot push into full channel
    testing.expect_value(t, chan_try_send(&ch, 999), false)

    // Stream 1,000 items continuously through 4-slot ring buffer
    for i in 4 ..< 1000 {
        // Pop oldest item
        val, ok := chan_try_recv(&ch)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, (i - 3) * 10)

        // Push new item
        send_ok := chan_try_send(&ch, (i + 1) * 10)
        testing.expect_value(t, send_ok, true)
    }

    // Drain final 4 items
    for i in 996 ..< 1000 {
        val, ok := chan_try_recv(&ch)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, (i + 1) * 10)
    }

    testing.expect_value(t, chan_is_empty(&ch), true)
    testing.expect_value(t, chan_count(&ch), 0)
}

// ============================================================================
// Test 55: Generator 16KB Lightweight Slab Memory Allocation
// ============================================================================

@(test)
test_generator_lightweight_memory :: proc(t: ^testing.T) {
    gen: Generator(int)
    generator_init(&gen, proc(f: ^Fiber, g: ^Generator(int)) {
        for i in 1 ..= 10 {
            yield_value(f, g, i * 100)
        }
    })
    defer generator_destroy(&gen)

    // Verify lightweight pool parameters (16KB stack, 1 stack per slab)
    testing.expect_value(t, gen.sched.fiber_pool.stack_size, uint(16 * 1024))
    testing.expect_value(t, gen.sched.fiber_pool.stacks_per_slab, 1)
    testing.expect_value(t, len(gen.sched.fiber_pool.slabs), 1)

    // Verify all 10 yielded values
    for i in 1 ..= 10 {
        val, ok := generator_next(&gen)
        testing.expect_value(t, ok, true)
        testing.expect_value(t, val, i * 100)
    }

    // Exhausted generator
    _, ok := generator_next(&gen)
    testing.expect_value(t, ok, false)
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
test_rush_success_preemption :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winning_branch: int = -99

    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        winner := rush(f,
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
// Test 58: Phase Director (FSM State Machine Lifecycle)
// ============================================================================

@(test)
test_phase_director_fsm :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    director: Phase_Director
    phase_director_init(&director, &sched)
    defer phase_director_destroy(&director)

    testing.expect_value(t, phase_current(&director), 0)
    testing.expect_value(t, phase_is_busy(&director), false)

    phase1_ran := false
    phase2_ran := false

    // Switch to Phase 1 (Spawns long combat loop)
    phase_switch(&director, 1, proc(f: ^Fiber, r: ^bool) {
        r^ = true
        for {
            yield_frame(f)
        }
    }, &phase1_ran, name = "Phase 1: Combat")

    testing.expect_value(t, phase_current(&director), 1)
    testing.expect_value(t, phase_name(&director), "Phase 1: Combat")
    testing.expect_value(t, phase_is_busy(&director), true)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, phase1_ran, true)

    // Switch to Phase 2 (Cancels Phase 1 immediately)
    phase_switch(&director, 2, proc(f: ^Fiber, r: ^bool) {
        r^ = true
    }, &phase2_ran, name = "Phase 2: Enraged")

    testing.expect_value(t, phase_current(&director), 2)
    testing.expect_value(t, phase_name(&director), "Phase 2: Enraged")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, phase2_ran, true)
}

// ============================================================================
// Test 59: Headless Simulation Runner (simulate_until)
// ============================================================================

@(test)
test_simulate_until_headless :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    counter: int = 0

    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        for _ in 0 ..< 100 {
            wait(f, 0.1) // 100 * 0.1s = 10.0 virtual seconds
            c^ += 1
        }
    }, &counter)

    // Run simulated 10 seconds of timeline instantaneously
    ok, sim_time := simulate_until(&sched, 0.016, 15.0, proc(c: ^int) -> bool {
        return c^ >= 50
    }, &counter)

    testing.expect_value(t, ok, true)
    testing.expect_value(t, counter, 50)
    testing.expect(t, sim_time >= 5.0 && sim_time <= 6.0, "Simulated time ~5.6s")
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
test_rush_5_branches_and_all_failing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winner_5: int = -99
    all_fail_winner: int = 99

    // 5 branches: 0, 1 fail early; 2 takes long; 3 finishes successfully first; 4 takes longest
    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        w := rush(f,
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
        w := rush(f,
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
// Test 63: Phase Director Rapid Multi-Phase Transitions (1 -> 2 -> 3 -> 4)
// ============================================================================

@(test)
test_phase_director_rapid_transitions :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    director: Phase_Director
    phase_director_init(&director, &sched)
    defer phase_director_destroy(&director)

    executed_phases: [5]bool

    // Rapidly switch through phases
    for p in 1 ..= 4 {
        phase_num := p
        phase_switch(&director, phase_num, proc(f: ^Fiber, d: ^[5]bool) {
            for {
                yield_frame(f)
            }
        }, &executed_phases, name = "Phase Step")

        testing.expect_value(t, phase_current(&director), phase_num)
        testing.expect_value(t, phase_is_busy(&director), true)
        scheduler_step(&sched, 0.016)
    }

    // Only 1 fiber should be active in current_scope
    testing.expect_value(t, scope_active_count(&director.current_scope), 1)

    // Destroy director
    phase_director_destroy(&director)
    testing.expect_value(t, scope_active_count(&director.current_scope), 0)
    testing.expect_value(t, phase_is_busy(&director), false)
}

// ============================================================================
// Test 64: Headless Simulation of Channel Producer-Consumer Pipeline
// ============================================================================

@(test)
test_simulate_until_channel_pipeline :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Context :: struct {
        ch:       Channel(int),
        received: int,
    }

    ctx: Context
    chan_init(&ctx.ch, capacity = 4)
    defer chan_destroy(&ctx.ch)

    // Producer fiber: pushes 30 items with small delays
    spawn(&sched, proc(f: ^Fiber, c: ^Context) {
        for i in 1 ..= 30 {
            wait(f, 0.02)
            chan_send(f, &c.ch, i)
        }
        chan_close(&c.ch)
    }, &ctx)

    // Consumer fiber: receives items
    spawn(&sched, proc(f: ^Fiber, c: ^Context) {
        for {
            _, ok := chan_recv(f, &c.ch)
            if !ok do break
            c.received += 1
        }
    }, &ctx)

    // Simulate entire 30-item pipeline in <1ms without window
    ok, sim_time := simulate_until(&sched, 0.016, 5.0, proc(c: ^Context) -> bool {
        return c.received >= 30
    }, &ctx)

    testing.expect_value(t, ok, true)
    testing.expect_value(t, ctx.received, 30)
    testing.expect(t, sim_time >= 0.5 && sim_time <= 2.0, "Pipeline completed in expected sim window")
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
            // Branch 0: Nested Rush
            branch(proc(f: ^Fiber) {
                winner := rush(f,
                    branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.04) }),
                )
                if winner != 1 do fail(f)
            }, "Nested Rush"),

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
// Test 66: Scheduler Step Execution While Paused (Debugger Manual Stepping)
// ============================================================================

@(test)
test_scheduler_step_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scheduler_set_paused(&sched, true)

    Test66_Ctx :: struct {
        counter:     ^int,
        child_woken: ^bool,
    }

    counter := 0
    child_woken := false
    ctx := Test66_Ctx{counter = &counter, child_woken = &child_woken}

    // Fiber 1: Waits on timer and spawns child fiber
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Test66_Ctx) {
        wait(f, 0.05)
        c.counter^ += 1
        spawn_ptr(f.sched, proc(f2: ^Fiber, c2: ^Test66_Ctx) {
            wait(f2, 0.05)
            c2.child_woken^ = true
        }, c)
    }, &ctx)

    // 1. Normal scheduler_step is skipped while is_paused == true
    scheduler_step(&sched, 0.50)
    testing.expect_value(t, counter, 0)

    // 2. Explicit scheduler_single_step forces simulation forward even while is_paused == true
    // Step A: 0.01s (Fiber 1 runs and registers timer for 0.01 + 0.05 = 0.06s)
    scheduler_single_step(&sched, 0.01)
    testing.expect_value(t, counter, 0)

    // Step B: 0.06s -> Total 0.07s (Fiber 1 wakes, increments counter to 1, spawns child for 0.07 + 0.05 = 0.12s)
    scheduler_single_step(&sched, 0.06)
    testing.expect_value(t, counter, 1)

    // Step C: 0.06s -> Total 0.13s (Child fiber wakes, sets flag)
    scheduler_single_step(&sched, 0.06)
    testing.expect_value(t, child_woken, true)
}

// ============================================================================
// Test 67: Real / Wall Clock While Game Is Paused
// ============================================================================

@(test)
test_real_time_clock_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    real_fiber_done := false
    sim_fiber_done := false

    // Real-Time UI Fiber (e.g. pause menu animation)
    spawn_real(&sched, proc(f: ^Fiber, done: ^bool) {
        wait_real(f, 0.10)
        done^ = true
    }, &real_fiber_done)

    // Sim-Time Gameplay Fiber (e.g. enemy attack)
    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait(f, 0.10)
        done^ = true
    }, &sim_fiber_done)

    // Pause the game simulation!
    scheduler_set_paused(&sched, true)

    // Step 3 times at 0.05s real time (total 0.15s real elapsed)
    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.05)
    }

    // Real-time fiber must be completed, but sim-time fiber must be FROZEN
    testing.expect_value(t, real_fiber_done, true)
    testing.expect_value(t, sim_fiber_done, false)
    testing.expect_value(t, sched.clock.sim_time, 0.0)
    testing.expect(t, sched.clock.real_time >= 0.14)

    // Unpause game
    scheduler_set_paused(&sched, false)
    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.05)
    }

    // Sim-time fiber now finishes
    testing.expect_value(t, sim_fiber_done, true)
}

// ============================================================================
// Test 68: Fixed Discrete Integer Simulation Ticks
// ============================================================================

@(test)
test_fixed_integer_tick_clock :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sched.clock.tick_rate_hz = 60 // 60 ticks per second (physics tick)

    tick50_done := false
    tick100_done := false

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait_ticks(f, 50)
        done^ = true
    }, &tick50_done)

    spawn(&sched, proc(f: ^Fiber, done: ^bool) {
        wait_ticks(f, 100)
        done^ = true
    }, &tick100_done)

    // Step 1: 30 ticks (sim_ticks = 30; fibers register wait_ticks for 30+50=80 and 30+100=130)
    scheduler_step_ticks(&sched, 30)
    testing.expect_value(t, tick50_done, false)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clock.sim_ticks, 30)

    // Step 2: 50 more ticks (sim_ticks = 80 >= 80) -> Fiber 1 wakes!
    scheduler_step_ticks(&sched, 50)
    testing.expect_value(t, tick50_done, true)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clock.sim_ticks, 80)

    // Step 3: 50 more ticks (sim_ticks = 130 >= 130) -> Fiber 2 wakes!
    scheduler_step_ticks(&sched, 50)
    testing.expect_value(t, tick100_done, true)
    testing.expect_value(t, sched.clock.sim_ticks, 130)
}

// ============================================================================
// Test 69: Dual-Clock Time Scaling & Multipliers
// ============================================================================

@(test)
test_dual_clock_time_scaling :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sched.clock.time_scale = 0.5 // Slow-motion 0.5x

    observed_sim_delta: f32 = 0.0
    observed_real_delta: f32 = 0.0
    observed_sim_time: f64 = 0.0
    observed_real_time: f64 = 0.0

    spawn(&sched, proc(f: ^Fiber, data: ^Test69_Data) {
        yield_frame(f)
        data.sim_dt = delta_time(f)
        data.real_dt = delta_real(f)
        data.sim_t = current_time(f)
        data.real_t = real_time(f)
    }, &Test69_Data{})

    // Frame 1
    scheduler_step(&sched, 0.10)
    // Frame 2
    data := Test69_Data{}
    spawn(&sched, proc(f: ^Fiber, d: ^Test69_Data) {
        d.sim_dt = delta_time(f)
        d.real_dt = delta_real(f)
        d.sim_t = current_time(f)
        d.real_t = real_time(f)
    }, &data)

    scheduler_step(&sched, 0.10)

    // Real delta is 0.10, Sim delta is 0.05 (0.5x scale)
    testing.expect(t, abs(data.real_dt - 0.10) < 0.001)
    testing.expect(t, abs(data.sim_dt - 0.05) < 0.001)
    testing.expect(t, abs(data.real_t - 0.20) < 0.001)
    testing.expect(t, abs(data.sim_t - 0.10) < 0.001)
}

Test69_Data :: struct {
    sim_dt:  f32,
    real_dt: f32,
    sim_t:   f64,
    real_t:  f64,
}

// ============================================================================
// Test 70: Multi-Clock Heap Integrity & Mixed Cancellation
// ============================================================================

@(test)
test_multi_clock_heap_integrity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    completed_count := 0

    // Spawn 20 real timers
    for i in 0 ..< 20 {
        spawn_real(&sched, proc(f: ^Fiber, c: ^int) {
            wait_real(f, 0.02)
            c^ += 1
        }, &completed_count)
    }

    // Spawn 20 sim timers
    for i in 0 ..< 20 {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            wait(f, 0.02)
            c^ += 1
        }, &completed_count)
    }

    // Spawn 20 tick waiters
    for i in 0 ..< 20 {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            wait_ticks(f, 20)
            c^ += 1
        }, &completed_count)
    }

    // Step scheduler forward
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.01)
    }

    // All 60 fibers should have woken and completed cleanly
    testing.expect_value(t, completed_count, 60)
    testing.expect_value(t, len(sched.real_timer_heap), 0)
    testing.expect_value(t, len(sched.timer_heap), 0)
    testing.expect_value(t, len(sched.tick_waiters), 0)
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
// Test 76: Counting Semaphore (Concurrency permit limiter)
// ============================================================================

@(test)
test_fiber_semaphore_concurrency_limit :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 2, max_permits = 2)
    defer semaphore_destroy(&sem)

    active_count := 0
    max_observed := 0
    total_completed := 0

    Sem_Worker :: struct {
        sem:             ^Fiber_Semaphore,
        active:          ^int,
        max_obs:         ^int,
        total_comp:      ^int,
    }

    worker_data := Sem_Worker{
        sem        = &sem,
        active     = &active_count,
        max_obs    = &max_observed,
        total_comp = &total_completed,
    }

    for _ in 0 ..< 6 {
        spawn_val(&sched, proc(f: ^Fiber, data: Sem_Worker) {
            semaphore_acquire(f, data.sem)
            data.active^ += 1
            if data.active^ > data.max_obs^ {
                data.max_obs^ = data.active^
            }

            wait(f, 0.02)

            data.active^ -= 1
            semaphore_release(f.sched, data.sem)
            data.total_comp^ += 1
        }, worker_data)
    }

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, total_completed, 6)
    testing.expect_value(t, max_observed, 2)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)
}

// ============================================================================
// Test 77: Counting Semaphore (try_acquire non-blocking)
// ============================================================================

@(test)
test_fiber_semaphore_try_acquire :: proc(t: ^testing.T) {
    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 1, max_permits = 1)
    defer semaphore_destroy(&sem)

    testing.expect(t, semaphore_try_acquire(&sem))
    testing.expect_value(t, semaphore_available_permits(&sem), 0)
    testing.expect(t, !semaphore_try_acquire(&sem)) // Depleted

    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    semaphore_release(&sched, &sem)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
    testing.expect(t, semaphore_try_acquire(&sem))
}

// ============================================================================
// Test 78: Countdown Latch / Barrier (Fiber_Latch)
// ============================================================================

@(test)
test_fiber_latch_barrier :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    latch: Fiber_Latch
    latch_init(&latch, initial_count = 3)
    defer latch_destroy(&latch)

    waiter_1_done := false
    waiter_2_done := false

    Latch_Waiter :: struct {
        latch: ^Fiber_Latch,
        done:  ^bool,
    }

    spawn_val(&sched, proc(f: ^Fiber, data: Latch_Waiter) {
        latch_wait(f, data.latch)
        data.done^ = true
    }, Latch_Waiter{&latch, &waiter_1_done})

    spawn_val(&sched, proc(f: ^Fiber, data: Latch_Waiter) {
        latch_wait(f, data.latch)
        data.done^ = true
    }, Latch_Waiter{&latch, &waiter_2_done})

    scheduler_step(&sched, 0.01)
    testing.expect(t, !waiter_1_done)
    testing.expect(t, !waiter_2_done)
    testing.expect_value(t, latch_get_count(&latch), 3)
    testing.expect(t, !latch_is_ready(&latch))

    // Count down 2
    latch_count_down(&sched, &latch, 2)
    scheduler_step(&sched, 0.01)
    testing.expect(t, !waiter_1_done)
    testing.expect_value(t, latch_get_count(&latch), 1)

    // Final count down -> 0 (unblocks both waiters)
    latch_count_down(&sched, &latch, 1)
    testing.expect(t, latch_is_ready(&latch))

    scheduler_step(&sched, 0.01)
    testing.expect(t, waiter_1_done)
    testing.expect(t, waiter_2_done)
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
// SUITE 13: PURE SYSTEMS ENHANCEMENTS (Tests 82-90)
// ============================================================================

// ============================================================================
// Test 82: Non-Blocking Multi-Channel Select (chan_try_select_recv)
// ============================================================================

@(test)
test_chan_try_select_recv :: proc(t: ^testing.T) {
    ch1, ch2, ch3: Channel(int)
    chan_init(&ch1, capacity = 4)
    chan_init(&ch2, capacity = 4)
    chan_init(&ch3, capacity = 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
        chan_destroy(&ch3)
    }

    ch_list := []^Channel(int){&ch1, &ch2, &ch3}

    // All empty -> returns ok = false, ready_index = -1
    idx, val, ok := chan_try_select_recv(ch_list)
    testing.expect(t, !ok)
    testing.expect_value(t, idx, -1)

    // Send item to ch2
    chan_try_send(&ch2, 42)

    idx, val, ok = chan_try_select_recv(ch_list)
    testing.expect(t, ok)
    testing.expect_value(t, idx, 1)
    testing.expect_value(t, val, 42)

    // Now empty again
    idx, val, ok = chan_try_select_recv(ch_list)
    testing.expect(t, !ok)
}

// ============================================================================
// Test 83: Blocking Multi-Channel Select (chan_select_recv)
// ============================================================================

@(test)
test_chan_select_recv_blocking :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch_a, ch_b: Channel(string)
    chan_init(&ch_a, capacity = 4)
    chan_init(&ch_b, capacity = 4)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
    }

    received_idx := -1
    received_val := ""
    received_ok := false

    Select_Env :: struct {
        ch_a: ^Channel(string),
        ch_b: ^Channel(string),
        out_idx: ^int,
        out_val: ^string,
        out_ok:  ^bool,
    }

    env := Select_Env{
        ch_a = &ch_a,
        ch_b = &ch_b,
        out_idx = &received_idx,
        out_val = &received_val,
        out_ok  = &received_ok,
    }

    // Consumer fiber waits on select
    spawn_val(&sched, proc(f: ^Fiber, env: Select_Env) {
        idx, val, ok := chan_select_recv(f, []^Channel(string){env.ch_a, env.ch_b})
        env.out_idx^ = idx
        env.out_val^ = val
        env.out_ok^  = ok
    }, env)

    scheduler_step(&sched, 0.01)
    testing.expect(t, !received_ok)

    // Send to ch_b from another fiber
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(string)) {
        wait(f, 0.05)
        chan_send(f, ch, "hello from channel B")
    }, &ch_b)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, received_ok)
    testing.expect_value(t, received_idx, 1)
    testing.expect_value(t, received_val, "hello from channel B")
}

// ============================================================================
// Test 84: Multi-Channel Select on Closed Channel
// ============================================================================

@(test)
test_chan_select_closed_channel :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch1, ch2: Channel(int)
    chan_init(&ch1, capacity = 4)
    chan_init(&ch2, capacity = 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
    }

    received_idx := -1
    received_ok := true

    Select_Close_Env :: struct {
        ch1: ^Channel(int),
        ch2: ^Channel(int),
        out_idx: ^int,
        out_ok:  ^bool,
    }

    env := Select_Close_Env{
        ch1 = &ch1,
        ch2 = &ch2,
        out_idx = &received_idx,
        out_ok  = &received_ok,
    }

    spawn_val(&sched, proc(f: ^Fiber, env: Select_Close_Env) {
        idx, _, ok := chan_select_recv(f, []^Channel(int){env.ch1, env.ch2})
        env.out_idx^ = idx
        env.out_ok^  = ok
    }, env)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, received_idx, -1)

    // Close ch2
    chan_close(&ch2)

    scheduler_step(&sched, 0.01)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, received_idx, 1)
    testing.expect(t, !received_ok)
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
// SUITE 14: SYNCHRONIZATION INTEGRATION & CANCELLATION ROBUSTNESS (Tests 91-100)
// ============================================================================

// ============================================================================
// Test 91: Cancel Fiber Waiting on Semaphore (semaphore_acquire)
// ============================================================================

@(test)
test_cancel_fiber_waiting_on_semaphore :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 0, max_permits = 2)
    defer semaphore_destroy(&sem)

    acquired := false
    h := spawn_ptr(&sched, proc(f: ^Fiber, sem: ^Fiber_Semaphore) {
        semaphore_acquire(f, sem)
    }, &sem)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_waiter_count(&sem), 1)

    // Abort the waiting fiber
    fiber_cancel(&sched, h)

    // Releasing permit should skip the aborted fiber and retain available permits
    semaphore_release(&sched, &sem, 1)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

// ============================================================================
// Test 92: Cancel Fiber Holding Semaphore with Cleanup (fiber_set_cleanup)
// ============================================================================

Sem_Cleanup_Ctx :: struct {
    sched: ^Scheduler,
    sem:   ^Fiber_Semaphore,
}

@(test)
test_cancel_fiber_holding_semaphore_with_cleanup :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 1, max_permits = 1)
    defer semaphore_destroy(&sem)

    ctx := Sem_Cleanup_Ctx{sched = &sched, sem = &sem}

    h := spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Sem_Cleanup_Ctx) {
        semaphore_acquire(f, ctx.sem)
        fiber_set_cleanup(f, proc(user_data: rawptr) {
            c := (^Sem_Cleanup_Ctx)(user_data)
            semaphore_release(c.sched, c.sem)
        }, ctx)
        wait(f, 5.0)
    }, &ctx)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    // Abort the fiber while holding the permit -> cleanup_proc runs and restores permit!
    fiber_cancel(&sched, h)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

// ============================================================================
// Test 93: Cancel Fiber Waiting on Mutex (mutex_lock)
// ============================================================================

@(test)
test_cancel_fiber_waiting_on_mutex :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    // Holder locks the mutex
    holder := spawn_ptr(&sched, proc(f: ^Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
        wait(f, 1.0)
        mutex_unlock(f.sched, m)
    }, &m)

    scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    // Waiter queues on the mutex
    waiter := spawn_ptr(&sched, proc(f: ^Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
        wait(f, 0.1)
        mutex_unlock(f.sched, m)
    }, &m)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel the waiter
    fiber_cancel(&sched, waiter)

    // Unlock by holder -> should not panic or wake cancelled fiber
    mutex_unlock(&sched, &m)
    testing.expect(t, !m.locked)
}

// ============================================================================
// Test 94: Cancel Fiber Waiting on Latch (latch_wait)
// ============================================================================

@(test)
test_cancel_fiber_waiting_on_latch :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    latch: Fiber_Latch
    latch_init(&latch, initial_count = 2)
    defer latch_destroy(&latch)

    Latch_Task_Ctx :: struct {
        latch: ^Fiber_Latch,
        done:  bool,
    }

    ctx1 := Latch_Task_Ctx{latch = &latch, done = false}
    ctx2 := Latch_Task_Ctx{latch = &latch, done = false}

    h1 := spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Latch_Task_Ctx) {
        latch_wait(f, ctx.latch)
        ctx.done = true
    }, &ctx1)

    h2 := spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Latch_Task_Ctx) {
        latch_wait(f, ctx.latch)
        ctx.done = true
    }, &ctx2)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, latch_waiter_count(&latch), 2)

    // Cancel h1
    fiber_cancel(&sched, h1)

    // Count down latch to 0
    latch_count_down(&sched, &latch, 2)
    scheduler_step(&sched, 0.01)

    testing.expect(t, !ctx1.done)
    testing.expect(t, ctx2.done)
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
// SUITE 15: HIGH-STRESS RESILIENCE & COMPOSITE INTEGRATION (Tests 101-110)
// ============================================================================

// ============================================================================
// Test 101: Multi-Channel Select Stress with Producer Scope Cancellation
// ============================================================================

@(test)
test_multi_channel_select_stress_with_producer_cancellation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    producer_a_scope: Fiber_Scope
    defer scope_destroy(&sched, &producer_a_scope)

    ch_a, ch_b: Channel(int)
    chan_init(&ch_a, capacity = 10)
    chan_init(&ch_b, capacity = 10)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
    }

    // Producer A: sends 1, 2, 3...
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        for i := 1; i <= 20; i += 1 {
            chan_send(f, ch, i)
            wait(f, 0.02)
        }
    }, &ch_a, scope = &producer_a_scope)

    // Producer B: sends 100, 200, 300...
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        for i := 1; i <= 20; i += 1 {
            chan_send(f, ch, i * 100)
            wait(f, 0.02)
        }
    }, &ch_b)

    Select_Consumer_Ctx :: struct {
        chans:        []^Channel(int),
        items_recv:   int,
        last_val:     int,
    }

    ctx := Select_Consumer_Ctx{
        chans = []^Channel(int){&ch_a, &ch_b},
        items_recv = 0,
        last_val = 0,
    }

    // Consumer fiber selects from both
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Select_Consumer_Ctx) {
        for {
            idx, val, ok := chan_select_recv(f, c.chans)
            if ok {
                c.items_recv += 1
                c.last_val = val
            }
        }
    }, &ctx)

    // Step a few frames
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect(t, ctx.items_recv >= 2)

    // Cancel Producer A via Scope
    cancelled_a := scope_cancel(&sched, &producer_a_scope)
    testing.expect_value(t, cancelled_a, 1)

    // Consumer should continue receiving from Producer B
    prev_count := ctx.items_recv
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect(t, ctx.items_recv > prev_count)
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
// Test 104: Semaphore Contention with Random Waiter Cancellations
// ============================================================================

@(test)
test_semaphore_high_contention_random_cancellations :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 3, max_permits = 3)
    defer semaphore_destroy(&sem)

    completed := 0
    handles: [12]Fiber_Handle

    Sem_Worker_Ctx :: struct {
        sem:       ^Fiber_Semaphore,
        completed: ^int,
        sched:     ^Scheduler,
    }

    ctx := Sem_Worker_Ctx{sem = &sem, completed = &completed, sched = &sched}

    for i in 0 ..< 12 {
        handles[i] = spawn_ptr(&sched, proc(f: ^Fiber, c: ^Sem_Worker_Ctx) {
            semaphore_acquire(f, c.sem)
            fiber_set_cleanup(f, proc(user_data: rawptr) {
                ctx := (^Sem_Worker_Ctx)(user_data)
                semaphore_release(ctx.sched, ctx.sem)
            }, c)
            wait(f, 0.05)
            semaphore_release(c.sched, c.sem)
            f.cleanup_proc = nil // Clear cleanup since released normally
            c.completed^ += 1
        }, &ctx)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    // Cancel 4 queued/active fibers
    fiber_cancel(&sched, handles[2])
    fiber_cancel(&sched, handles[5])
    fiber_cancel(&sched, handles[7])
    fiber_cancel(&sched, handles[9])

    // Step until all remaining fibers finish
    for _ in 0 ..< 25 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, completed, 8)
    testing.expect_value(t, semaphore_available_permits(&sem), 3)
}

// ============================================================================
// Test 105: Mutex Contention Churn with Intermediate Waiter Cancellations
// ============================================================================

@(test)
test_mutex_lock_unlock_cancellation_churn :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    completed := 0
    handles: [10]Fiber_Handle

    Mutex_Worker_Ctx :: struct {
        m:         ^Fiber_Mutex,
        completed: ^int,
        sched:     ^Scheduler,
    }

    ctx := Mutex_Worker_Ctx{m = &m, completed = &completed, sched = &sched}

    for i in 0 ..< 10 {
        handles[i] = spawn_ptr(&sched, proc(f: ^Fiber, c: ^Mutex_Worker_Ctx) {
            mutex_lock(f, c.m)
            fiber_set_cleanup(f, proc(user_data: rawptr) {
                ctx := (^Mutex_Worker_Ctx)(user_data)
                mutex_unlock(ctx.sched, ctx.m)
            }, c)
            wait(f, 0.03)
            mutex_unlock(c.sched, c.m)
            f.cleanup_proc = nil
            c.completed^ += 1
        }, &ctx)
    }

    scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    // Cancel 3 queued waiters
    fiber_cancel(&sched, handles[3])
    fiber_cancel(&sched, handles[6])
    fiber_cancel(&sched, handles[8])

    for _ in 0 ..< 30 {
        scheduler_step(&sched, 0.03)
    }

    testing.expect_value(t, completed, 7)
    testing.expect(t, !m.locked)
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
// Test 107: Latch Countdown with Interleaved Waiter Aborts
// ============================================================================

@(test)
test_latch_partial_countdown_with_waiter_cancellations :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    latch: Fiber_Latch
    latch_init(&latch, initial_count = 4)
    defer latch_destroy(&latch)

    Latch_Multi_Ctx :: struct {
        latch: ^Fiber_Latch,
        woken: ^int,
    }

    woken := 0
    ctxs: [4]Latch_Multi_Ctx
    handles: [4]Fiber_Handle

    for i in 0 ..< 4 {
        ctxs[i] = Latch_Multi_Ctx{latch = &latch, woken = &woken}
        handles[i] = spawn_ptr(&sched, proc(f: ^Fiber, c: ^Latch_Multi_Ctx) {
            latch_wait(f, c.latch)
            c.woken^ += 1
        }, &ctxs[i])
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, latch_waiter_count(&latch), 4)

    // Countdown 2
    latch_count_down(&sched, &latch, 2)
    testing.expect_value(t, latch_get_count(&latch), 2)
    testing.expect_value(t, woken, 0)

    // Abort waiter 1
    fiber_cancel(&sched, handles[1])

    // Final countdown of 2 -> reaches 0
    latch_count_down(&sched, &latch, 2)
    scheduler_step(&sched, 0.01)

    testing.expect(t, latch_is_ready(&latch))
    testing.expect_value(t, woken, 3)
}

// ============================================================================
// Test 108: Scope Mass Cancellation Across Mixed Scheduler Queues
// ============================================================================

@(test)
test_scope_mass_cancel_mixed_states :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    mixed_scope: Fiber_Scope
    defer scope_destroy(&sched, &mixed_scope)

    // Fiber 1: Sleeping_Time
    spawn(&sched, proc(f: ^Fiber) { wait(f, 5.0) }, scope = &mixed_scope)

    // Fiber 2: Sleeping_Real_Time
    spawn_real(&sched, proc(f: ^Fiber) { wait_real(f, 5.0) }, scope = &mixed_scope)

    // Fiber 3: Sleeping_Frames
    spawn(&sched, proc(f: ^Fiber) { wait_frames(f, 100) }, scope = &mixed_scope)

    // Fiber 4: Sleeping_Ticks
    spawn(&sched, proc(f: ^Fiber) { wait_ticks(f, 100) }, scope = &mixed_scope)

    // Fiber 5: Waiting_Condition
    flag := false
    spawn_ptr(&sched, proc(f: ^Fiber, fl: ^bool) {
        wait_while(f, proc(data: ^bool) -> bool { return !data^ }, fl)
    }, &flag, scope = &mixed_scope)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, scope_active_count(&mixed_scope), 5)

    // Cancel all 5 in various sleeping queues via scope
    cancelled := scope_cancel(&sched, &mixed_scope)
    testing.expect_value(t, cancelled, 5)
    testing.expect_value(t, scope_active_count(&mixed_scope), 0)
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
// SUITE 16: SAFETY HARNESS, TIMEOUTS & FOOTGUN GUARDS (Tests 111-120)
// ============================================================================

// ============================================================================
// Test 111: Channel Destruction Auto-Wakes Blocked Receivers (chan_destroy)
// ============================================================================

@(test)
test_chan_destroy_auto_wakes_blocked_receivers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch := new(Channel(int))
    chan_init(ch, capacity = 0) // Unbuffered rendezvous

    woken_count := 0
    ok_count := 0

    Chan_Unblock_Ctx :: struct {
        ch:    ^Channel(int),
        woken: ^int,
        ok_c:  ^int,
    }

    ctx := Chan_Unblock_Ctx{ch = ch, woken = &woken_count, ok_c = &ok_count}

    for _ in 0 ..< 4 {
        spawn_ptr(&sched, proc(f: ^Fiber, c: ^Chan_Unblock_Ctx) {
            val, ok := chan_recv(f, c.ch)
            c.woken^ += 1
            if ok do c.ok_c^ += 1
        }, &ctx)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(ch), 4)

    // Destroying the channel must auto-close and wake all 4 receivers with ok = false
    chan_destroy(ch)
    free(ch)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 4)
    testing.expect_value(t, ok_count, 0)
}

// ============================================================================
// Test 112: Channel Destruction Auto-Wakes Blocked Senders (chan_destroy)
// ============================================================================

@(test)
test_chan_destroy_auto_wakes_blocked_senders :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch := new(Channel(int))
    chan_init(ch, capacity = 1)

    woken_count := 0
    ok_count := 0

    Chan_Send_Unblock_Ctx :: struct {
        ch:    ^Channel(int),
        woken: ^int,
        ok_c:  ^int,
    }

    ctx := Chan_Send_Unblock_Ctx{ch = ch, woken = &woken_count, ok_c = &ok_count}

    // Fill the buffer
    chan_try_send(ch, 42)

    // Spawn senders that will block
    for _ in 0 ..< 3 {
        spawn_ptr(&sched, proc(f: ^Fiber, c: ^Chan_Send_Unblock_Ctx) {
            ok := chan_send(f, c.ch, 99)
            c.woken^ += 1
            if ok do c.ok_c^ += 1
        }, &ctx)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_send_waiter_count(ch), 3)

    // Destroy channel
    chan_destroy(ch)
    free(ch)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 3)
    testing.expect_value(t, ok_count, 0)
}

// ============================================================================
// Test 113: Channel Receive Timeout Success (chan_recv_timeout)
// ============================================================================

@(test)
test_chan_recv_timeout_success :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Timeout_Test_Ctx :: struct {
        ch:        ^Channel(int),
        val:       int,
        ok:        bool,
        timed_out: bool,
    }

    ctx := Recv_Timeout_Test_Ctx{ch = &ch}

    // Receiver with 0.5s timeout
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Recv_Timeout_Test_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 0.5)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
    }, &ctx)

    // Delayed producer sends after 0.05s
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        wait(f, 0.05)
        chan_send(f, ch, 777)
    }, &ch)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, ctx.val, 777)
    testing.expect(t, ctx.ok)
    testing.expect(t, !ctx.timed_out)
}

// ============================================================================
// Test 114: Channel Receive Timeout Expiration (chan_recv_timeout)
// ============================================================================

@(test)
test_chan_recv_timeout_expires :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Timeout_Expire_Ctx :: struct {
        ch:        ^Channel(int),
        val:       int,
        ok:        bool,
        timed_out: bool,
        finished:  bool,
    }

    ctx := Recv_Timeout_Expire_Ctx{ch = &ch}

    // Receiver with 0.05s timeout
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Recv_Timeout_Expire_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 0.05)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
        c.finished = true
    }, &ctx)

    // Step scheduler past 0.05s deadline
    for _ in 0 ..< 8 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect(t, ctx.finished)
    testing.expect(t, !ctx.ok)
    testing.expect(t, ctx.timed_out)
}

// ============================================================================
// Test 115: Channel Receive Timeout with Closed Channel
// ============================================================================

@(test)
test_chan_recv_timeout_closed_channel :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(string)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Recv_Closed_Ctx :: struct {
        ch:        ^Channel(string),
        val:       string,
        ok:        bool,
        timed_out: bool,
    }

    ctx := Recv_Closed_Ctx{ch = &ch}

    // Receiver waiting with 1.0s timeout
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Recv_Closed_Ctx) {
        val, ok, timed_out := chan_recv_timeout(f, c.ch, 1.0)
        c.val = val
        c.ok = ok
        c.timed_out = timed_out
    }, &ctx)

    scheduler_step(&sched, 0.01)

    // Close channel mid-wait
    chan_close(&ch)
    scheduler_step(&sched, 0.01)

    testing.expect(t, !ctx.ok)
    testing.expect(t, !ctx.timed_out)
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
// Test 117: Channel Close Multicast with Interleaved Receivers
// ============================================================================

@(test)
test_channel_close_multicast_with_interleaved_receivers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    Chan_Close_Multi_Ctx :: struct {
        ch:    ^Channel(int),
        count: ^int,
    }

    woken_count := 0
    ctxs: [5]Chan_Close_Multi_Ctx

    for i in 0 ..< 5 {
        ctxs[i] = Chan_Close_Multi_Ctx{ch = &ch, count = &woken_count}
        spawn_ptr(&sched, proc(f: ^Fiber, c: ^Chan_Close_Multi_Ctx) {
            chan_recv(f, c.ch)
            c.count^ += 1
        }, &ctxs[i])
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 5)

    chan_close(&ch)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, woken_count, 5)
}

// ============================================================================
// Test 118: Channel Timeout Receiving with Concurrent Producers
// ============================================================================

@(test)
test_chan_recv_timeout_concurrent_producers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 2)
    defer chan_destroy(&ch)

    Chan_Recv_Val_Ctx :: struct {
        ch:  ^Channel(int),
        val: ^int,
    }

    received_val := 0
    ctx := Chan_Recv_Val_Ctx{ch = &ch, val = &received_val}

    // Fast receiver with timeout
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Chan_Recv_Val_Ctx) {
        v, ok, timed_out := chan_recv_timeout(f, c.ch, 0.5)
        if ok do c.val^ = v
    }, &ctx)

    // Producer 1 (0.04s delay)
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        wait(f, 0.04)
        chan_send(f, ch, 111)
    }, &ch)

    // Producer 2 (0.08s delay)
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        wait(f, 0.08)
        chan_send(f, ch, 222)
    }, &ch)

    for _ in 0 ..< 8 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, received_val, 111)
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
// Test 121: Stale Waiter Abort Immunity in Mutex
// ============================================================================

@(test)
test_mutex_stale_waiter_abort_immunity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    F1_Ctx :: struct {
        m:    ^Fiber_Mutex,
        done: bool,
    }
    f1_ctx := F1_Ctx{ m = &m, done = false }

    f2_handle: Fiber_Handle

    F3_Ctx :: struct {
        done: bool,
    }
    f3_ctx := F3_Ctx{ done = false }

    // Fiber 1 holds lock
    spawn_ptr(&sched, proc(f: ^Fiber, p: ^F1_Ctx) {
        mutex_lock(f, p.m)
        wait(f, 0.04)
        mutex_unlock(f.sched, p.m)
        p.done = true
    }, &f1_ctx)

    // Fiber 2 blocks waiting for lock
    f2_handle = spawn_ptr(&sched, proc(f: ^Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
    }, &m)

    // Run 1 frame so f1 locks and f2 suspends into m.waiters
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel fiber 2 externally while in waiters queue
    fiber_cancel(&sched, f2_handle)
    testing.expect(t, !fiber_is_alive(&sched, f2_handle))

    // Fiber 3 is spawned (recycles fiber slot) and sleeps for 0.10s
    spawn_ptr(&sched, proc(f: ^Fiber, p: ^F3_Ctx) {
        wait(f, 0.10)
        p.done = true
    }, &f3_ctx)

    // Step past f1's release (0.04s + 0.01s initial = 0.05s)
    for _ in 0 ..< 6 {
        scheduler_step(&sched, 0.01)
    }

    // Fiber 1 finished and unlocked
    testing.expect(t, f1_ctx.done)
    // Fiber 3 should NOT have finished yet (needs 0.10s, only ~0.07s elapsed)
    testing.expect(t, !f3_ctx.done)

    // Step until Fiber 3 completes naturally
    for _ in 0 ..< 8 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, f3_ctx.done)
}

// ============================================================================
// Test 122: Scoped Mutex and Semaphore (with_mutex & with_semaphore)
// ============================================================================

@(test)
test_scoped_mutex_and_semaphore :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 1, 1)
    defer semaphore_destroy(&sem)

    Mutex_Test_Data :: struct {
        m:       ^Fiber_Mutex,
        counter: int,
    }
    m_data := Mutex_Test_Data{ m = &m, counter = 0 }

    // Spawn 2 fibers updating counter via with_mutex
    for _ in 0 ..< 2 {
        spawn_ptr(&sched, proc(f: ^Fiber, d: ^Mutex_Test_Data) {
            with_mutex(f, d.m, proc(f: ^Fiber, data: ^Mutex_Test_Data) {
                wait(f, 0.02)
                data.counter += 1
            }, d)
        }, &m_data)
    }

    // Run until mutex tasks finish
    for _ in 0 ..< 6 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect_value(t, m_data.counter, 2)
    testing.expect(t, !m.locked)

    // Test with_semaphore
    sem_executed := false
    spawn_ptr(&sched, proc(f: ^Fiber, p: ^struct { sem: ^Fiber_Semaphore, done: ^bool }) {
        with_semaphore(f, p.sem, proc(f: ^Fiber, done: ^bool) {
            wait(f, 0.02)
            done^ = true
        }, p.done)
    }, &struct { sem: ^Fiber_Semaphore, done: ^bool }{ &sem, &sem_executed })

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, sem_executed)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

// ============================================================================
// Test 123: Multi-Channel Select (chan_try_select_recv & chan_select_recv)
// ============================================================================

@(test)
test_multi_channel_select :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch1, ch2, ch3: Channel(int)
    chan_init(&ch1, 4)
    chan_init(&ch2, 4)
    chan_init(&ch3, 4)
    defer {
        chan_destroy(&ch1)
        chan_destroy(&ch2)
        chan_destroy(&ch3)
    }

    channels := [3]^Channel(int){&ch1, &ch2, &ch3}

    // 1. Try-select on empty channels
    idx, val, ok := chan_try_select_recv(channels[:])
    testing.expect_value(t, ok, false)
    testing.expect_value(t, idx, -1)

    // Push into channel 2
    chan_try_send(&ch2, 42)
    idx, val, ok = chan_try_select_recv(channels[:])
    testing.expect_value(t, ok, true)
    testing.expect_value(t, idx, 1)
    testing.expect_value(t, val, 42)

    // 2. Blocking chan_select_recv in a fiber
    Select_Context :: struct {
        channels:       []^Channel(int),
        received_idx:   int,
        received_val:   int,
        received_ok:    bool,
    }
    ctx := Select_Context{
        channels     = channels[:],
        received_idx = -1,
        received_val = 0,
        received_ok  = false,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Select_Context) {
        idx, v, ok_recv := chan_select_recv(f, c.channels)
        c.received_idx = idx
        c.received_val = v
        c.received_ok = ok_recv
    }, &ctx)

    scheduler_step(&sched, 0.01)
    testing.expect(t, !ctx.received_ok)

    // Producer sends to ch3
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        wait(f, 0.02)
        chan_send(f, ch, 999)
    }, &ch3)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, ctx.received_ok)
    testing.expect_value(t, ctx.received_idx, 2)
    testing.expect_value(t, ctx.received_val, 999)
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
// Test 126: Channel Stale Waiter Abort Immunity
// ============================================================================

@(test)
test_channel_stale_waiter_abort_immunity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, 0) // Rendezvous
    defer chan_destroy(&ch)

    f_recv_handle := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Channel(int)) {
        chan_recv(f, c)
    }, &ch)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 1)

    // Cancel receiver while waiting in recv_waiters
    fiber_cancel(&sched, f_recv_handle)

    // Send value to channel - should skip dead waiter and not panic/hang
    sent := chan_try_send(&ch, 100)
    testing.expect(t, !sent)
    testing.expect_value(t, chan_recv_waiter_count(&ch), 0)
}

// ============================================================================
// Test 127: By-Value Scoped Mutex (with_mutex_val)
// ============================================================================

@(test)
test_with_mutex_val :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    Value_Payload :: struct {
        m:     ^Fiber_Mutex,
        tag:   int,
        delta: f32,
    }

    spawn_val(&sched, proc(f: ^Fiber, p: Value_Payload) {
        with_mutex(f, p.m, proc(f: ^Fiber, val: Value_Payload) {
            wait(f, 0.02)
        }, p)
    }, Value_Payload{m = &m, tag = 10, delta = 5.5})

    scheduler_step(&sched, 0.01)
    testing.expect(t, m.locked)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !m.locked)
}

// ============================================================================
// Test 128: By-Value Scoped Semaphore (with_semaphore_val)
// ============================================================================

@(test)
test_with_semaphore_val :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 2, 2)
    defer semaphore_destroy(&sem)

    Value_Payload :: struct {
        sem: ^Fiber_Semaphore,
        id:  int,
    }

    // Spawn 2 fibers using with_semaphore_val
    for i in 0 ..< 2 {
        spawn_val(&sched, proc(f: ^Fiber, p: Value_Payload) {
            with_semaphore(f, p.sem, proc(f: ^Fiber, val: Value_Payload) {
                wait(f, 0.02)
            }, p)
        }, Value_Payload{sem = &sem, id = i})
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect_value(t, semaphore_available_permits(&sem), 2)
}

// ============================================================================
// Test 129: Multi-Channel Select Receive (chan_select_recv)
// ============================================================================

@(test)
test_chan_select_recv_multiplexing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch_a, ch_b, ch_c: Channel(int)
    chan_init(&ch_a, 1)
    chan_init(&ch_b, 1)
    chan_init(&ch_c, 1)
    defer {
        chan_destroy(&ch_a)
        chan_destroy(&ch_b)
        chan_destroy(&ch_c)
    }

    Select_Result :: struct {
        idx: int,
        val: int,
        ok:  bool,
    }
    res := Select_Result{idx = -1, val = -1, ok = false}
    channels := [3]^Channel(int){&ch_a, &ch_b, &ch_c}

    // Receiver fiber selects across all 3 channels
    spawn_ptr(&sched, proc(f: ^Fiber, p: ^struct { chs: []^Channel(int), r: ^Select_Result }) {
        idx, val, ok_recv := chan_select_recv(f, p.chs)
        p.r.idx = idx
        p.r.val = val
        p.r.ok = ok_recv
    }, &struct { chs: []^Channel(int), r: ^Select_Result }{ channels[:], &res })

    // Step 1: Fiber runs and yields since all channels are empty
    scheduler_step(&sched, 0.01)
    testing.expect(t, !res.ok)

    // Producer sends to ch_b
    chan_try_send(&ch_b, 777)

    // Step 2: Receiver receives from ch_b
    scheduler_step(&sched, 0.01)
    testing.expect(t, res.ok)
    testing.expect_value(t, res.idx, 1)
    testing.expect_value(t, res.val, 777)
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
// Test 131: Precision Drift-Compensated Ticker
// ============================================================================

@(test)
test_precision_drift_compensated_ticker :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Ticker_Ctx :: struct {
        ticks_completed: int,
        final_sim_time:  f64,
    }
    ctx := Ticker_Ctx{ticks_completed = 0, final_sim_time = 0.0}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ticker_Ctx) {
        ticker: Ticker
        ticker_init(&ticker, interval_seconds = 0.05)

        for _ in 0 ..< 5 {
            ticker_wait(f, &ticker)
            c.ticks_completed += 1
        }
        c.final_sim_time = f.sched.clock.sim_time
    }, &ctx)

    // Step by irregular delta-times (simulating variable frame drops)
    for _ in 0 ..< 30 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect_value(t, ctx.ticks_completed, 5)
    // 5 ticks of 0.05s = exactly 0.25s (with <= 1 frame step tolerance)
    testing.expect(t, ctx.final_sim_time >= 0.25 && ctx.final_sim_time <= 0.27)
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
// Test 133: Custom Allocator Fidelity for Synchronization Primitives
// ============================================================================

@(test)
test_primitives_custom_arena_allocation_fidelity :: proc(t: ^testing.T) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    arena_alloc := mem.tracking_allocator(&track)

    // 1. Event(T)
    {
        ev: Event(int)
        event_init(&ev)
        event_destroy(&ev)
    }

    // 2. Fiber_Semaphore
    {
        sem: Fiber_Semaphore
        semaphore_init(&sem, 2, 4)
        semaphore_destroy(&sem)
    }

    // 3. Fiber_Latch
    {
        latch: Fiber_Latch
        latch_init(&latch, 3)
        latch_destroy(&latch)
    }

    // 4. Signal
    {
        sig: Signal
        signal_init(&sig)
        signal_destroy(&sig)
    }

    // 5. Mutex
    {
        m: Fiber_Mutex
        mutex_init(&m)
        mutex_destroy(&m)
    }

    // 6. Channel(T) with custom allocator
    {
        ch: Channel(int)
        chan_init(&ch, capacity = 8, allocator = arena_alloc)
        chan_destroy(&ch)
    }

    // Verify zero leaks on custom allocator
    testing.expect_value(t, len(track.allocation_map), 0)
    testing.expect_value(t, track.current_memory_allocated, 0)
}

// ============================================================================
// Test 134: Headless Simulation Runner with Active Watchdog
// ============================================================================

@(test)
test_simulate_until_with_active_watchdog :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sched.watchdog_enabled = true

    counter := 0
    spawn_ptr(&sched, proc(f: ^Fiber, c: ^int) {
        for _ in 0 ..< 500 {
            yield_frame(f)
            c^ += 1
        }
    }, &counter)

    done, sim_time := simulate_until(&sched, 0.016, 10.0, proc(c: ^int) -> bool {
        return c^ >= 500
    }, &counter)

    testing.expect(t, done)
    testing.expect_value(t, counter, 500)
    testing.expect(t, sched.watchdog_enabled) // Watchdog should be restored after simulation
}

// ============================================================================
// Test 135: Condition Timeout (wait_until_timeout)
// ============================================================================

@(test)
test_wait_until_timeout_mechanics :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    door_unlocked := false
    success_met := false
    success_timeout := false

    timeout_met := false
    timeout_timed_out := false

    // Fiber 1: Condition met in 0.05s, timeout is 0.20s -> should succeed
    spawn_ptr(&sched, proc(f: ^Fiber, door: ^bool) {
        wait(f, 0.05)
        door^ = true
    }, &door_unlocked)

    Ctx1 :: struct {
        door:      ^bool,
        met:       ^bool,
        timed_out: ^bool,
    }
    ctx1 := Ctx1{door = &door_unlocked, met = &success_met, timed_out = &success_timeout}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx1) {
        met, timed_out := wait_until_timeout(f, proc(d: ^bool) -> bool {
            return d^
        }, c.door, 0.20)
        c.met^ = met
        c.timed_out^ = timed_out
    }, &ctx1)

    // Fiber 2: Condition never met, timeout is 0.05s -> should time out
    Ctx2 :: struct {
        met:       ^bool,
        timed_out: ^bool,
    }
    ctx2 := Ctx2{met = &timeout_met, timed_out = &timeout_timed_out}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx2) {
        met, timed_out := wait_until_timeout(f, proc() -> bool {
            return false
        }, 0.05)
        c.met^ = met
        c.timed_out^ = timed_out
    }, &ctx2)

    // Step 0.10s
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, success_met, "Fiber 1 condition should have been met")
    testing.expect(t, !success_timeout, "Fiber 1 should not have timed out")

    testing.expect(t, !timeout_met, "Fiber 2 condition should not be met")
    testing.expect(t, timeout_timed_out, "Fiber 2 should have timed out")
}

// ============================================================================
// Test 136: Condition While Timeout (wait_while_timeout)
// ============================================================================

@(test)
test_wait_while_timeout_mechanics :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    busy := true
    cleared_met := false
    cleared_timed_out := false

    timeout_met := false
    timeout_timed_out := false

    // Fiber 1: Busy clears in 0.04s, timeout is 0.20s -> should complete without timeout
    spawn_ptr(&sched, proc(f: ^Fiber, b: ^bool) {
        wait(f, 0.04)
        b^ = false
    }, &busy)

    Ctx1 :: struct {
        busy:      ^bool,
        met:       ^bool,
        timed_out: ^bool,
    }
    ctx1 := Ctx1{busy = &busy, met = &cleared_met, timed_out = &cleared_timed_out}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx1) {
        met, timed_out := wait_while_timeout(f, proc(b: ^bool) -> bool {
            return b^
        }, c.busy, 0.20)
        c.met^ = met
        c.timed_out^ = timed_out
    }, &ctx1)

    // Fiber 2: Always busy, timeout is 0.05s -> should time out
    Ctx2 :: struct {
        met:       ^bool,
        timed_out: ^bool,
    }
    ctx2 := Ctx2{met = &timeout_met, timed_out = &timeout_timed_out}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx2) {
        met, timed_out := wait_while_timeout(f, proc() -> bool {
            return true
        }, 0.05)
        c.met^ = met
        c.timed_out^ = timed_out
    }, &ctx2)

    // Step 0.10s
    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, cleared_met, "Fiber 1 wait_while should have completed")
    testing.expect(t, !cleared_timed_out, "Fiber 1 should not have timed out")

    testing.expect(t, !timeout_met, "Fiber 2 wait_while should not have completed naturally")
    testing.expect(t, timeout_timed_out, "Fiber 2 should have timed out")
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
// Test 138: Channel Capacity Inspection (chan_cap)
// ============================================================================

@(test)
test_chan_cap_inspection :: proc(t: ^testing.T) {
    // Unbuffered channel (rendezvous)
    ch_unbuf: Channel(int)
    chan_init(&ch_unbuf, 0)
    defer chan_destroy(&ch_unbuf)

    testing.expect_value(t, chan_cap(&ch_unbuf), 0)
    testing.expect_value(t, chan_count(&ch_unbuf), 0)

    // Buffered channel (capacity 16)
    ch_buf: Channel(f32)
    chan_init(&ch_buf, 16)
    defer chan_destroy(&ch_buf)

    testing.expect_value(t, chan_cap(&ch_buf), 16)
    testing.expect_value(t, chan_count(&ch_buf), 0)
    testing.expect(t, chan_is_empty(&ch_buf))
    testing.expect(t, !chan_is_full(&ch_buf))
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
// Test 147: Headless Boss AI Fuzzing Simulation with Signal EMP Pulses
// ============================================================================

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
        ticker: Ticker
        ticker_init(&ticker, 0.04)
        for b.alive {
            ticker_wait(f, &ticker)
            b.shots_fired += 1
        }
    }

    fuzz_targeted_burst :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        ticker: Ticker
        ticker_init(&ticker, 0.08)
        for b.alive {
            ticker_wait(f, &ticker)
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
                wait(f, 0.15) // Stun duration
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
                wait(f, 0.15) // Stun duration
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
                wait(f, 0.10) // Berserk stun duration
            }
        }
    }

    fuzz_boss_master :: proc(f: ^Fiber, b: ^Fuzz_Boss) {
        // Phase 1
        b.phase = 1
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                wait_while(f, proc(b: ^Fuzz_Boss) -> bool {
                    return b.hp > 700.0 && b.alive
                }, b)
            }, b, "HP < 700"),
            branch(fuzz_patrol_subloop, b, "Patrol P1"),
            branch(fuzz_attack_loop_p1, b, "Attacks P1"),
        )
        if !b.alive do return

        // Phase 2
        b.phase = 2
        wait(f, 0.1) // Phase transition
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                wait_while(f, proc(b: ^Fuzz_Boss) -> bool {
                    return b.hp > 350.0 && b.alive
                }, b)
            }, b, "HP < 350"),
            branch(fuzz_patrol_subloop, b, "Patrol P2"),
            branch(fuzz_attack_loop_p2, b, "Attacks P2"),
        )
        if !b.alive do return

        // Phase 3
        b.phase = 3
        wait(f, 0.1) // Berserk charge
        race(f,
            branch(proc(f: ^Fiber, b: ^Fuzz_Boss) {
                wait_while(f, proc(b: ^Fuzz_Boss) -> bool {
                    return b.alive
                }, b)
            }, b, "Death Trigger"),
            branch(fuzz_patrol_subloop, b, "Patrol P3"),
            branch(fuzz_attack_loop_p3, b, "Attacks P3"),
        )
    }

    boss := Fuzz_Boss{
        hp    = 1000.0,
        alive = true,
        phase = 1,
    }
    defer signal_destroy(&boss.stun_signal)

    spawn_ptr(&sched, fuzz_boss_master, &boss)

    // XorShift PRNG for deterministic reproducible fuzzing
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
    max_active_fibers := 0

    // Simulate 2,000 continuous frames of gameplay with fuzzing
    for frame in 0 ..< 2000 {
        r := xorshift64(&rng_state)

        // Fuzz frame delta between 5ms and 30ms
        dt_ms := 5.0 + f32(r % 25)
        dt := dt_ms / 1000.0

        // Deal continuous player damage to boss
        if boss.alive {
            boss.hp -= 0.65 // ~1300 total damage over 2000 frames
            if boss.hp <= 0.0 {
                boss.alive = false
            }
        }

        // Randomly trigger EMP parry pulse (approx every 15-40 frames)
        if (r % 25) == 0 && boss.alive {
            signal_emit(&sched, &boss.stun_signal)
            total_emp_pulses += 1
        }

        // Step the scheduler
        scheduler_step(&sched, dt)

        // Check invariants on every single frame!
        stats := scheduler_pool_stats(&sched)
        if stats.active_fibers > max_active_fibers {
            max_active_fibers = stats.active_fibers
        }

        // Active fibers must be strictly bounded (never leaks!)
        testing.expect(t, stats.active_fibers <= 16)
        testing.expect_value(t, stats.total_stacks, stats.active_fibers + stats.free_fibers)
    }

    // After 2,000 frames: Boss must be dead, all fibers recycled, 0 active fibers!
    testing.expect(t, !boss.alive)
    testing.expect_value(t, boss.phase, 3)
    testing.expect(t, total_emp_pulses >= 10)
    testing.expect(t, boss.stuns >= 5)
    testing.expect(t, boss.shots_fired >= 100)

    final_stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, final_stats.active_fibers, 0)
}

// ============================================================================
// Test 148: Phase Transition Race Tree Structured Teardown Fuzzing
// ============================================================================

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

    b_state := Boss_State{
        hp    = 1000.0,
        phase = 1,
        alive = true,
    }
    defer signal_destroy(&b_state.stun_signal)

    p1_attack_proc :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 1 {
            b.p1_attacks_spawned += 1
            wait(f, 0.05)
            if b.phase != 1 {
                b.phase1_in_p2_error = true
            }
        }
    }

    p2_attack_proc :: proc(f: ^Fiber, b: ^Boss_State) {
        for b.alive && b.phase == 2 {
            b.p2_attacks_spawned += 1
            wait(f, 0.05)
            if b.phase != 2 {
                b.phase2_in_p3_error = true
            }
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
                wait(f, 0.2) // Stun duration
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
                wait(f, 0.2) // Stun duration
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
        // Phase 1
        b.phase = 1
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                wait_while(f, proc(b: ^Boss_State) -> bool {
                    return b.hp > 700.0 && b.alive
                }, b)
            }, b, "HP < 700 Trigger"),
            branch(p1_loop, b, "P1 Loop"),
        )
        if !b.alive do return

        // Phase 2
        b.phase = 2
        wait(f, 0.1) // Cinematic transition
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                wait_while(f, proc(b: ^Boss_State) -> bool {
                    return b.hp > 350.0 && b.alive
                }, b)
            }, b, "HP < 350 Trigger"),
            branch(p2_loop, b, "P2 Loop"),
        )
        if !b.alive do return

        // Phase 3
        b.phase = 3
        wait(f, 0.1) // Cinematic transition
        race(f,
            branch(proc(f: ^Fiber, b: ^Boss_State) {
                wait_while(f, proc(b: ^Boss_State) -> bool {
                    return b.alive
                }, b)
            }, b, "Death Trigger"),
            branch(p3_loop, b, "P3 Loop"),
        )
    }

    spawn_ptr(&sched, boss_ai_timeline, &b_state)

    // Simulate 1,000 frames: EMP pulses are deliberately fired exactly when HP crosses 705->695 and 355->345!
    for frame in 0 ..< 1000 {
        // Deal damage
        if b_state.alive {
            b_state.hp -= 1.3 // ~1300 damage over 1000 frames
            if b_state.hp <= 0 do b_state.alive = false
        }

        // Fire EMP right on phase boundaries (705-695 and 355-345) and periodic frames
        if (b_state.hp >= 690.0 && b_state.hp <= 710.0) || (b_state.hp >= 340.0 && b_state.hp <= 360.0) || (frame % 20 == 0) {
            signal_emit(&sched, &b_state.stun_signal)
        }

        scheduler_step(&sched, 0.016)

        // Verify that during Phase 2, NO Phase 1 attack fibers ever executed
        testing.expect(t, !b_state.phase1_in_p2_error)
        testing.expect(t, !b_state.phase2_in_p3_error)
    }

    testing.expect(t, !b_state.alive)
    testing.expect_value(t, b_state.phase, 3)
    testing.expect(t, b_state.p1_attacks_spawned > 0)
    testing.expect(t, b_state.p2_attacks_spawned > 0)
    testing.expect(t, b_state.p3_attacks_spawned > 0)
    testing.expect(t, !b_state.phase1_in_p2_error)
    testing.expect(t, !b_state.phase2_in_p3_error)

    stats := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats.active_fibers, 0)
}

// ============================================================================
// Test 149: sim_ticks Continuous Synchronized Zero-Drift Math
// ============================================================================

@(test)
test_sim_ticks_continuous_zero_drift :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sched.clock.tick_rate_hz = 1000 // 1000 ticks/sec = 1ms per tick

    // Run 60 frames at 1/60 seconds (16.666... ms)
    dt := f32(1.0 / 60.0)
    for _ in 0 ..< 60 {
        scheduler_step(&sched, dt)
    }

    // After exactly 1.0 second (60 frames at 1/60s), sim_ticks MUST be 1000, not 960!
    testing.expect_value(t, sched.clock.sim_ticks, u64(1000))
}

// ============================================================================
// Test 150: Defensive Wait Queue Validation & Paused Zero-Shift Real-Time Dispatch
// ============================================================================

@(test)
test_wait_queue_defensive_and_paused_dispatch :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    q1, q2: Wait_Queue
    f: Fiber
    f.handle = 1

    // Push into q1
    wait_queue_push_back(&q1, &f)
    testing.expect_value(t, f.current_wait_queue, &q1)

    // Attempt to remove from q2 (cross-queue removal attempt must fail defensively)
    removed_wrong := wait_queue_remove(&q2, &f)
    testing.expect(t, !removed_wrong)
    testing.expect_value(t, f.current_wait_queue, &q1)

    // Remove from q1 succeeds
    removed_ok := wait_queue_remove(&q1, &f)
    testing.expect(t, removed_ok)
    testing.expect_value(t, f.current_wait_queue, nil)

    // Verify paused mode zero-shift ready queue execution
    sim_ran := false
    real_ran := false

    // Spawn a simulation fiber (should remain deferred when paused)
    spawn_ptr(&sched, proc(fib: ^Fiber, ran: ^bool) {
        ran^ = true
    }, &sim_ran)

    // Spawn a real-time fiber (should execute while paused)
    f_real := spawn_real(&sched, proc(fib: ^Fiber, ran: ^bool) {
        ran^ = true
    }, &real_ran)
    testing.expect(t, f_real != 0)

    scheduler_set_paused(&sched, true)
    scheduler_step(&sched, 0.016)

    testing.expect(t, !sim_ran)
    testing.expect(t, real_ran)

    // Unpause: deferred sim fiber executes
    scheduler_set_paused(&sched, false)
    scheduler_step(&sched, 0.016)
    testing.expect(t, sim_ran)
}

// ============================================================================
// Test 151: scheduler_set_time_scale Defensive Clamping (Negative & NaN)
// ============================================================================

@(test)
test_time_scale_defensive_clamping :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Positive scale
    scheduler_set_time_scale(&sched, 2.5)
    testing.expect_value(t, scheduler_time_scale(&sched), f32(2.5))

    // Zero scale (valid pause-like scale)
    scheduler_set_time_scale(&sched, 0.0)
    testing.expect_value(t, scheduler_time_scale(&sched), f32(0.0))

    // Negative scale (must clamp defensively to 0.0 to protect min-heap monotonicity)
    scheduler_set_time_scale(&sched, -5.0)
    testing.expect_value(t, scheduler_time_scale(&sched), f32(0.0))

    // NaN scale (must fall back defensively to 1.0)
    nan_val := math.nan_f32()
    scheduler_set_time_scale(&sched, nan_val)
    testing.expect_value(t, scheduler_time_scale(&sched), f32(1.0))
}

// ============================================================================
// Test 152: Generator O(1) Generational Lookup and Wait Queue Recycle Defense
// ============================================================================

@(test)
test_generator_o1_and_recycle_wait_queue_defense :: proc(t: ^testing.T) {
    // 1. Verify Generator O(1) execution
    gen: Generator(int)
    generator_init(&gen, proc(f: ^Fiber, g: ^Generator(int)) {
        for i in 10 ..= 30 {
            yield_value(f, g, i)
        }
    })
    defer generator_destroy(&gen)

    expected := 10
    for {
        val, ok := generator_next(&gen)
        if !ok do break
        testing.expect_value(t, val, expected)
        expected += 1
    }
    testing.expect_value(t, expected, 31)
    testing.expect(t, gen.is_done)

    // 2. Verify fiber_cleanup_and_recycle clears current_wait_queue defensively
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    q: Wait_Queue
    spawn(&sched, proc(f: ^Fiber, wq: ^Wait_Queue) {
        wait_queue_push_back(wq, f)
        yield_frame(f)
        // Normal completion will trigger fiber_cleanup_and_recycle with active wait queue
    }, &q)

    // Frame 1: fiber executes, pushes to wait queue, and yields
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, q.head != nil, true)

    // Frame 2: fiber completes and is recycled; verify it was cleanly unlinked from q
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, q.head == nil, true)
    testing.expect_value(t, q.tail == nil, true)
}

// ============================================================================
// Test 153: Unbuffered Channel chan_recv_timeout Deadlock Safety
// ============================================================================

@(test)
test_chan_recv_timeout_unbuffered_safety :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0) // Unbuffered rendezvous
    defer chan_destroy(&ch)

    timed_out := false
    val_received := 0

    Recv_Ctx :: struct {
        ch:           ^Channel(int),
        timed_out:    ^bool,
        val_received: ^int,
    }
    ctx := Recv_Ctx{ch = &ch, timed_out = &timed_out, val_received = &val_received}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Recv_Ctx) {
        val, ok, to := chan_recv_timeout(f, c.ch, 0.05)
        c.timed_out^ = to
        if ok do c.val_received^ = val
    }, &ctx)

    // Step scheduler past timeout without providing any sender
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }

    // Must cleanly time out and not hang
    testing.expect(t, timed_out)
    testing.expect_value(t, val_received, 0)
}

// ============================================================================
// Test 154: Queue Unlinking on scheduler_destroy (Zero Dangling Pointers)
// ============================================================================

@(test)
test_scheduler_destroy_wait_queue_unlinking :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)

    // Outliving Channel & Mutex
    ch: Channel(int)
    chan_init(&ch, capacity = 1)
    defer chan_destroy(&ch)

    mtx: Fiber_Mutex
    defer mutex_destroy(&mtx)

    // Spawn fiber that blocks on mutex
    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
        yield_frame(f)
    }, &mtx)

    // Spawn another fiber that blocks waiting for mutex release
    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Fiber_Mutex) {
        mutex_lock(f, m)
    }, &mtx)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, mtx.waiters.head != nil, true)

    // Destroy scheduler while fibers are still in mtx.waiters
    scheduler_destroy(&sched)

    // Outliving mutex waiters list must have been unlinked to prevent UAF!
    testing.expect_value(t, mtx.waiters.head == nil, true)
    testing.expect_value(t, mtx.waiters.tail == nil, true)
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
// Test 157: Symmetrical Unbuffered Channel Rendezvous (Sender Before Receiver)
// ============================================================================

@(test)
test_chan_unbuffered_sender_before_receiver :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    Sender_Ctx :: struct {
        ch:   ^Channel(int),
        sent: ^bool,
    }
    sent_flag := false

    // Spawn Sender FIRST (suspends waiting for receiver)
    spawn_val(&sched, proc(f: ^Fiber, ctx: Sender_Ctx) {
        ok := chan_send(f, ctx.ch, 999)
        if ok do ctx.sent^ = true
    }, Sender_Ctx{ch = &ch, sent = &sent_flag})

    // Step once: sender runs and suspends in send_waiters
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, sent_flag, false)
    testing.expect_value(t, chan_count(&ch), 1)

    Recv_Ctx :: struct {
        ch:       ^Channel(int),
        received: int,
        ok:       bool,
    }
    r_ctx := Recv_Ctx{ch = &ch, received = 0, ok = false}

    // Spawn Receiver SECOND
    spawn(&sched, proc(f: ^Fiber, ctx: ^Recv_Ctx) {
        val, ok := chan_recv(f, ctx.ch)
        ctx.received = val
        ctx.ok = ok
    }, &r_ctx)

    // Step scheduler: receiver runs, consumes value, unblocks sender
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, r_ctx.ok, true)
    testing.expect_value(t, r_ctx.received, 999)
    testing.expect_value(t, chan_count(&ch), 0)
}

// ============================================================================
// Test 158: Unbuffered Multi-Channel Select with Pre-Queued Sender
// ============================================================================

@(test)
test_chan_select_unbuffered_with_sender :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch1, ch2: Channel(int)
    chan_init(&ch1, capacity = 0)
    defer chan_destroy(&ch1)
    chan_init(&ch2, capacity = 0)
    defer chan_destroy(&ch2)

    // Sender queues message into unbuffered ch2
    spawn(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 777)
    }, &ch2)

    // Step scheduler so sender pushes into ch2
    scheduler_step(&sched, 0.016)

    // Receiver selects across [ch1, ch2]
    Select_Ctx :: struct {
        channels: [2]^Channel(int),
        idx:      int,
        val:      int,
        ok:       bool,
    }
    ctx := Select_Ctx{channels = {&ch1, &ch2}, idx = -1, val = 0, ok = false}

    spawn(&sched, proc(f: ^Fiber, c: ^Select_Ctx) {
        idx, val, ok := chan_select_recv(f, c.channels[:])
        c.idx = idx
        c.val = val
        c.ok = ok
    }, &ctx)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ctx.ok, true)
    testing.expect_value(t, ctx.idx, 1)
    testing.expect_value(t, ctx.val, 777)
}

// ============================================================================
// Test 159: spawn_real_val Inline Payload Execution While Paused
// ============================================================================

@(test)
test_spawn_real_val_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scheduler_set_paused(&sched, true)

    Payload :: struct {
        x:     int,
        y:     int,
        out_x: ^int,
        out_y: ^int,
    }

    res_x, res_y: int = 0, 0
    p := Payload{x = 42, y = 84, out_x = &res_x, out_y = &res_y}

    spawn_real(&sched, proc(f: ^Fiber, data: Payload) {
        wait_real(f, 0.05)
        data.out_x^ = data.x
        data.out_y^ = data.y
    }, p)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, res_x, 42)
    testing.expect_value(t, res_y, 84)
}

// ============================================================================
// Test 160: Defensive Non-Positive Counts in Semaphore & Latch
// ============================================================================

@(test)
test_defensive_semaphore_and_latch_non_positive :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Semaphore defensive checks
    sem: Fiber_Semaphore
    semaphore_init(&sem, initial_permits = 2, max_permits = 5)
    defer semaphore_destroy(&sem)

    semaphore_release(&sched, &sem, 0)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)

    semaphore_release(&sched, &sem, -3)
    testing.expect_value(t, semaphore_available_permits(&sem), 2)

    // Latch defensive checks
    latch: Fiber_Latch
    latch_init(&latch, initial_count = 4)
    defer latch_destroy(&latch)

    latch_count_down(&sched, &latch, 0)
    testing.expect_value(t, latch_get_count(&latch), 4)

    latch_count_down(&sched, &latch, -2)
    testing.expect_value(t, latch_get_count(&latch), 4)
}

// ============================================================================
// Test 161: simulate_until Execution Safety When Scheduler Starts Paused
// ============================================================================

@(test)
test_simulate_until_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scheduler_set_paused(&sched, true)

    done := false
    spawn(&sched, proc(f: ^Fiber, flag: ^bool) {
        wait(f, 0.05)
        flag^ = true
    }, &done)

    Sim_Ctx :: struct {
        flag: ^bool,
    }
    ctx := Sim_Ctx{flag = &done}

    met, elapsed := simulate_until(&sched, 0.01, 1.0, proc(c: ^Sim_Ctx) -> bool {
        return c.flag^
    }, &ctx)

    testing.expect_value(t, met, true)
    testing.expect_value(t, done, true)
    testing.expect(t, elapsed >= 0.05)
    // Verify original paused state was cleanly restored
    testing.expect_value(t, sched.clock.is_paused, true)
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
// Test 163: Unbuffered Channel Multi-Sender Rendezvous Safety (Zero Data Loss)
// ============================================================================

@(test)
test_chan_unbuffered_multi_sender_rendezvous :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    results: [dynamic]int
    defer delete(results)

    Send_Context :: struct {
        ch:  ^Channel(int),
        val: int,
    }
    s1 := Send_Context{ch = &ch, val = 100}
    s2 := Send_Context{ch = &ch, val = 200}
    s3 := Send_Context{ch = &ch, val = 300}

    // Spawn 3 concurrent senders on unbuffered channel
    spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s1, name = "Sender 1")

    spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s2, name = "Sender 2")

    spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Send_Context) {
        chan_send(f, ctx.ch, ctx.val)
    }, &s3, name = "Sender 3")

    Recv_Context :: struct {
        ch:      ^Channel(int),
        results: ^[dynamic]int,
    }
    rctx := Recv_Context{ch = &ch, results = &results}

    spawn_ptr(&sched, proc(f: ^Fiber, ctx: ^Recv_Context) {
        for i := 0; i < 3; i += 1 {
            val, ok := chan_recv(f, ctx.ch)
            if ok {
                append(ctx.results, val)
            }
        }
    }, &rctx, name = "Receiver")

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, len(results), 3)
    if len(results) == 3 {
        testing.expect_value(t, results[0], 100)
        testing.expect_value(t, results[1], 200)
        testing.expect_value(t, results[2], 300)
    }
    testing.expect_value(t, chan_count(&ch), 0)
}

// ============================================================================
// Test 164: Unbuffered Channel Sender Abort Cleanup (Ghost Message Prevention)
// ============================================================================

@(test)
test_chan_unbuffered_sender_abort_cleanup :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch: Channel(int)
    chan_init(&ch, capacity = 0)
    defer chan_destroy(&ch)

    sender_h := spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 999) // Will suspend waiting for receiver
    }, &ch, name = "Aborting Sender")

    // Step scheduler: sender puts 999 into buffer[0], count = 1, and suspends in send_waiters
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, chan_count(&ch), 1)
    testing.expect_value(t, chan_send_waiter_count(&ch), 1)

    // Abort the sender while waiting in rendezvous
    cancelled := fiber_cancel(&sched, sender_h)
    testing.expect_value(t, cancelled, true)
    // Cleanup proc must reset ch.count = 0 and remove from send_waiters
    testing.expect_value(t, chan_count(&ch), 0)
    testing.expect_value(t, chan_send_waiter_count(&ch), 0)

    // Now spawn a valid sender with 42
    spawn_ptr(&sched, proc(f: ^Fiber, ch: ^Channel(int)) {
        chan_send(f, ch, 42)
    }, &ch, name = "Valid Sender")

    received_val := 0
    Recv_Target :: struct {
        ch:  ^Channel(int),
        out: ^int,
    }
    target := Recv_Target{ch = &ch, out = &received_val}
    spawn_ptr(&sched, proc(f: ^Fiber, t: ^Recv_Target) {
        val, ok := chan_recv(f, t.ch)
        if ok {
            t.out^ = val
        }
    }, &target, name = "Actual Receiver")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, received_val, 42)
    testing.expect_value(t, chan_count(&ch), 0)
}

// ============================================================================
// Test 165: Real-Time Fiber Paused Yield Safety (No Freeze in Frame Waiters)
// ============================================================================

@(test)
test_real_time_fiber_paused_yield :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    // Pause simulation clock
    scheduler_set_paused(&sched, true)

    step_count := 0
    spawn_real(&sched, proc(f: ^Fiber, counter: ^int) {
        for i := 0; i < 5; i += 1 {
            counter^ += 1
            if i % 2 == 0 {
                yield_real(f)
            } else {
                wait_real(f, 0.0) // Must not freeze in frame_waiters when paused!
            }
        }
    }, &step_count, name = "Realtime Paused Worker")

    // Run 5 steps while paused
    for i := 0; i < 5; i += 1 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, step_count, 5)
}

// ============================================================================
// Test 166: Real-Time Ticker Paused Execution Safety
// ============================================================================

@(test)
test_real_time_ticker_paused_zero_freeze :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scheduler_set_paused(&sched, true)

    ticks := 0
    spawn_real(&sched, proc(f: ^Fiber, counter: ^int) {
        t: Ticker
        ticker_init(&t, 0.01, use_real_time = true)
        for i := 0; i < 4; i += 1 {
            ticker_wait(f, &t)
            counter^ += 1
        }
    }, &ticks, name = "Realtime Ticker Worker")

    for i := 0; i < 5; i += 1 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ticks, 4)
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
// Test 168: Fiber Pool Recycle Wake Clock Sanitization
// ============================================================================

@(test)
test_fiber_pool_recycle_wake_clock_sanitization :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    real_clock_observed: Time_Clock
    sim_clock_observed: Time_Clock

    // Spawn real-time fiber
    h_real := spawn_real(&sched, proc(f: ^Fiber, out: ^Time_Clock) {
        out^ = f.wake_clock
    }, &real_clock_observed, name = "Real Worker")

    scheduler_step(&sched, 0.016)

    // Now spawn a standard fiber which will acquire the recycled fiber
    h_sim := spawn(&sched, proc(f: ^Fiber, out: ^Time_Clock) {
        out^ = f.wake_clock
    }, &sim_clock_observed, name = "Sim Worker")

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, real_clock_observed, Time_Clock.Real_Time)
    testing.expect_value(t, sim_clock_observed, Time_Clock.Sim_Scaled)
    testing.expect_value(t, fiber_is_alive(&sched, h_real), false)
    testing.expect_value(t, fiber_is_alive(&sched, h_sim), false)
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
// Test 171: Paused State Condition Waiters Polling in scheduler_advance_real
// ============================================================================

@(test)
test_paused_condition_waiters_polling :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    token: Async_Token
    async_token_init(&token)

    completed := false

    // Real-time fiber waiting on async background task
    spawn_real(&sched, proc(f: ^Fiber, data: ^struct { tok: ^Async_Token, comp: ^bool }) {
        ok := await_async(f, data.tok)
        if ok {
            data.comp^ = true
        }
    }, &struct { tok: ^Async_Token, comp: ^bool }{tok = &token, comp = &completed}, name = "Async Awaiter")

    // Step 1: Start fiber, begins waiting on condition
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, completed, false)

    // Pause simulation
    scheduler_set_paused(&sched, true)
    testing.expect(t, scheduler_is_paused(&sched))

    // Complete token in background thread / host
    async_token_complete(&token, true)

    // Step while paused -> scheduler_advance_real must poll condition_waiters and complete real-time fiber
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, completed, true)
}

// ============================================================================
// Test 172: Automatic Abort Safety in with_mutex
// ============================================================================

@(test)
test_with_mutex_automatic_abort_cleanup :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    m: Fiber_Mutex
    mutex_init(&m)
    defer mutex_destroy(&m)

    worker2_completed := false

    Worker_Ctx :: struct {
        m:     ^Fiber_Mutex,
        comp:  ^bool,
    }
    ctx := Worker_Ctx{m = &m, comp = &worker2_completed}

    // Fiber 1: Enters with_mutex and sleeps
    h1 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Worker_Ctx) {
        with_mutex(f, c.m, proc(f: ^Fiber, c: ^Worker_Ctx) {
            wait(f, 10.0) // Long sleep while holding lock
        }, c)
    }, &ctx, name = "Lock Holder")

    // Fiber 2: Waits for the mutex
    h2 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Worker_Ctx) {
        with_mutex(f, c.m, proc(f: ^Fiber, c: ^Worker_Ctx) {
            c.comp^ = true
        }, c)
    }, &ctx, name = "Lock Waiter")

    scheduler_step(&sched, 0.016)
    testing.expect(t, m.locked)
    testing.expect_value(t, worker2_completed, false)
    testing.expect_value(t, mutex_waiter_count(&m), 1)

    // Cancel fiber 1 while it is holding with_mutex
    // Automatic abort cleanup must unlock m and hand it over to fiber 2!
    fiber_cancel(&sched, h1)
    testing.expect(t, m.locked) // Transferred to fiber 2

    // Step scheduler so fiber 2 executes
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, worker2_completed, true)
    testing.expect_value(t, m.locked, false)
}

// ============================================================================
// Test 173: Automatic Abort Safety in with_semaphore
// ============================================================================

@(test)
test_with_semaphore_automatic_abort_cleanup :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sem: Fiber_Semaphore
    semaphore_init(&sem, 1, 1)
    defer semaphore_destroy(&sem)

    worker2_completed := false

    Sem_Ctx :: struct {
        sem:   ^Fiber_Semaphore,
        comp:  ^bool,
    }
    ctx := Sem_Ctx{sem = &sem, comp = &worker2_completed}

    // Fiber 1 acquires permit via with_semaphore and sleeps
    h1 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Sem_Ctx) {
        with_semaphore(f, c.sem, proc(f: ^Fiber, c: ^Sem_Ctx) {
            wait(f, 10.0)
        }, c)
    }, &ctx, name = "Permit Holder")

    // Fiber 2 tries to acquire permit via with_semaphore
    h2 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Sem_Ctx) {
        with_semaphore(f, c.sem, proc(f: ^Fiber, c: ^Sem_Ctx) {
            c.comp^ = true
        }, c)
    }, &ctx, name = "Permit Waiter")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, semaphore_available_permits(&sem), 0)
    testing.expect_value(t, worker2_completed, false)
    testing.expect_value(t, semaphore_waiter_count(&sem), 1)

    // Abort fiber 1: automatic cleanup hook must restore permit and wake fiber 2
    fiber_cancel(&sched, h1)

    // Step scheduler so fiber 2 acquires permit and completes
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, worker2_completed, true)
    testing.expect_value(t, semaphore_available_permits(&sem), 1)
}

// ============================================================================
// Test 174: chan_select_recv Buffered Message Priority Over Closed Channel
// ============================================================================

@(test)
test_chan_select_recv_buffered_priority_over_closed :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ch_closed: Channel(int)
    chan_init(&ch_closed, 4)
    defer chan_destroy(&ch_closed)

    ch_data: Channel(int)
    chan_init(&ch_data, 4)
    defer chan_destroy(&ch_data)

    // Preload ch_data with values
    chan_try_send(&ch_data, 42)
    chan_try_send(&ch_data, 99)

    // Close ch_closed (empty closed channel)
    chan_close(&ch_closed)

    received_values := make([dynamic]int, context.allocator)
    defer delete(received_values)

    Select_Ctx :: struct {
        chans:    [2]^Channel(int),
        received: ^[dynamic]int,
    }
    ctx := Select_Ctx{
        chans    = {&ch_closed, &ch_data},
        received = &received_values,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Select_Ctx) {
        for {
            idx, val, ok := chan_select_recv(f, c.chans[:])
            if !ok {
                break // EOF / closed
            }
            append(c.received, val)
        }
    }, &ctx, name = "Select Consumer")

    // Run until select consumer consumes all buffered messages and exits
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, len(received_values), 2)
    testing.expect_value(t, received_values[0], 42)
    testing.expect_value(t, received_values[1], 99)
}



