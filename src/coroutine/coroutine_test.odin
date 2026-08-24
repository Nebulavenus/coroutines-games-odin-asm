package coroutine

import "core:testing"
import "core:fmt"
import "core:math/rand"
import "core:math"

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

    sched.is_paused = true
    scheduler_step(&sched, 0.5)
    testing.expect_value(t, counter, 0)

    sched.is_paused = false
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 1)

    sched.time_scale = 2.0
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
            append(e.history_ptr, f.sched.current_time)
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
    testing.expect_value(t, len(sig.waiters), 3)
    testing.expect_value(t, woken_count, 0)

    // Emit signal
    signal_emit(&sched, &sig)
    testing.expect_value(t, len(sig.waiters), 0)

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

g_test66_flag: bool

@(test)
test_scheduler_step_while_paused :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sched.is_paused = true

    counter := 0
    g_test66_flag = false

    // Fiber 1: Waits on timer and spawns child fiber
    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        wait(f, 0.05)
        c^ += 1
        spawn(f.sched, proc(f2: ^Fiber) {
            wait(f2, 0.05)
            g_test66_flag = true
        })
    }, &counter)

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
    testing.expect_value(t, g_test66_flag, true)
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
    sched.is_paused = true

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
    sched.is_paused = false
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
