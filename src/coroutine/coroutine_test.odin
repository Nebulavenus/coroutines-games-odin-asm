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
    defer scope_destroy(&scope, &sched)

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
        wait_cond(f, proc() -> bool { return true })
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
    defer scope_destroy(&scope, &sched)

    dummy_cond := false

    // 1. Fiber in Sleeping_Time
    spawn_nil(&sched, proc(f: ^Fiber) { wait(f, 100.0) }, scope = &scope)

    // 2. Fiber in Sleeping_Frames
    spawn_nil(&sched, proc(f: ^Fiber) { wait_frames(f, 500) }, scope = &scope)

    // 3. Fiber in Waiting_Condition
    spawn(&sched, proc(f: ^Fiber, cond_ptr: ^bool) {
        wait_until(f, proc(c: ^bool) -> bool { return c^ }, cond_ptr)
    }, &dummy_cond, scope = &scope)

    // 4. Fiber in Suspended_Join (sync)
    spawn_nil(&sched, proc(f: ^Fiber) {
        sync(f,
            branch_nil(proc(f: ^Fiber) { wait_frames(f, 100) }),
            branch_nil(proc(f: ^Fiber) { wait_frames(f, 100) }),
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
