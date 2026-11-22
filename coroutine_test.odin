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
        yield(f)

        res[1] = local_b + local_a
        yield(f)

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

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, step_stage, 1)

    scheduler_step(&sched, 0.400)
    testing.expect_value(t, step_stage, 1)

    scheduler_step(&sched, 0.100)
    testing.expect_value(t, step_stage, 2)

    scheduler_step(&sched, 0.500)
    testing.expect_value(t, step_stage, 2)

    scheduler_step(&sched, 0.600)
    testing.expect_value(t, step_stage, 3)
}

@(test)
test_wait_frames :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    counter := 0
    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        c^ += 1
        wait_steps(f, 3)
        c^ += 10
    }, &counter)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 1)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, counter, 11)
}

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
                wait_steps(f, 2)
                s.a_done = true
            }, s, "Branch A"),
            branch(proc(f: ^Fiber, s: ^Sync_State) {
                wait_steps(f, 4)
                s.b_done = true
            }, s, "Branch B"),
        )

        s.all_done = true
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.a_done, false)
    testing.expect_value(t, state.b_done, false)
    testing.expect_value(t, state.all_done, false)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.a_done, true)
    testing.expect_value(t, state.b_done, false)
    testing.expect_value(t, state.all_done, false)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.a_done, true)
    testing.expect_value(t, state.b_done, true)
    testing.expect_value(t, state.all_done, true)
    testing.expect_value(t, state.sync_ok, true)
}

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
                wait_steps(f, 5)
                s.slow_completed = true
            }, s, "Slow Branch"),
            branch(proc(f: ^Fiber, s: ^Race_State) {
                wait_steps(f, 2)
                s.fast_completed = true
            }, s, "Fast Branch"),
        )
        s.winner_idx = w
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.winner_idx, -1)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.fast_completed, true)
    testing.expect_value(t, state.slow_completed, false)
    testing.expect_value(t, state.winner_idx, 1)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, state.slow_completed, false)
}

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
            yield(f)
        }
    }, &progress, &scope)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 1)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 2)

    scope_cancel(&sched, &scope)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, progress, 2)
}

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
        wait_steps(f, 100)
    }, &cleaned_up)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, cleaned_up, false)

    fiber_cancel(&sched, handle)

    testing.expect_value(t, cleaned_up, true)
}

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
            branch(proc(f: ^Fiber, s: ^Nested_State) {
                wait_steps(f, 2)
                s.timer_done = true
            }, s, "Timer Branch"),

            branch(proc(f: ^Fiber, s: ^Nested_State) {
                sync(f,
                    branch(proc(f: ^Fiber, s: ^Nested_State) {
                        wait_steps(f, 5)
                        s.sync_a_done = true
                    }, s, "Sub-task A"),
                    branch(proc(f: ^Fiber, s: ^Nested_State) {
                        wait_steps(f, 5)
                        s.sync_b_done = true
                    }, s, "Sub-task B"),
                )
            }, s, "Sync Branch"),
        )
        s.winner_idx = w
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.winner_idx, -1)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
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
            yield(f)
            c^ += 2
            yield(f)
            c^ += 3
        }, &counters[i])
    }

    scheduler_step(&sched, 0.016)
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 1)
    }

    scheduler_step(&sched, 0.016)
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 3)
    }

    scheduler_step(&sched, 0.016)
    for i in 0 ..< TOTAL_FIBERS {
        testing.expect_value(t, counters[i], 6)
    }
}

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
        sync(f,
            branch(proc(f: ^Fiber, s: ^Deep_State) {
                race(f,
                    branch(proc(f: ^Fiber, s: ^Deep_State) {
                        wait_steps(f, 2)
                        s.tier3_timer_done = true
                    }, s, "Tier 3 Timer"),

                    branch(proc(f: ^Fiber, s: ^Deep_State) {
                        sync(f,
                            branch(proc(f: ^Fiber, s: ^Deep_State) {
                                wait_steps(f, 10)
                                s.tier4_a_done = true
                            }, s, "Tier 4 Task A"),
                            branch(proc(f: ^Fiber, s: ^Deep_State) {
                                wait_steps(f, 10)
                                s.tier4_b_done = true
                            }, s, "Tier 4 Task B"),
                        )
                    }, s, "Tier 3 Sync"),
                )
            }, s, "Tier 2 Race"),

            branch(proc(f: ^Fiber, s: ^Deep_State) {
                wait_steps(f, 3)
                s.tier2_sync_done = true
            }, s, "Tier 2 Sync B"),
        )

        s.root_done = true
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.root_done, false)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.tier3_timer_done, true)
    testing.expect_value(t, state.tier4_a_done, false)
    testing.expect_value(t, state.tier4_b_done, false)
    testing.expect_value(t, state.root_done, false)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.tier2_sync_done, true)
    testing.expect_value(t, state.root_done, true)
    testing.expect_value(t, state.tier4_a_done, false)
    testing.expect_value(t, state.tier4_b_done, false)
}

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
                wait_steps(f, 2)
                s.branch_a_done = true
            }, s, "Branch A"),
            branch(proc(f: ^Fiber, s: ^Sync_Fail_State) {
                yield(f)
                f.status = .Failed
                s.branch_b_failed = true
            }, s, "Branch B"),
        )
    }, &state)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.branch_b_failed, true)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.branch_a_done, true)
    testing.expect_value(t, state.sync_succeeded, false)
}

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
                wait_steps(f, 1)
                s.executed_count += 1
            }, s, "Branch 0"),
            branch(proc(f: ^Fiber, s: ^Race_Tie_State) {
                wait_steps(f, 1)
                s.executed_count += 1
            }, s, "Branch 1"),
            branch(proc(f: ^Fiber, s: ^Race_Tie_State) {
                wait_steps(f, 1)
                s.executed_count += 1
            }, s, "Branch 2"),
        )
    }, &state)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.winner, -1)

    scheduler_step(&sched, 0.016)
    testing.expect(t, state.winner >= 0 && state.winner <= 2, "Winner must be a valid branch index")
    testing.expect_value(t, state.executed_count, 1)
}

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
            branch(proc(f: ^Fiber, s: ^Descendant_State) {
                yield(f)
                s.fast_done = true
            }, s, "Fast Winner"),

            branch(proc(f: ^Fiber, s: ^Descendant_State) {
                sync(f,
                    branch(proc(f: ^Fiber, s: ^Descendant_State) {
                        fiber_defer(f, proc(data: rawptr) {
                            ptr := (^Descendant_State)(data)
                            ptr.grandchild_cleaned_up = true
                        }, s)
                        wait_steps(f, 10)
                        s.grandchild_1_done = true
                    }, s, "Grandchild 1"),
                    branch(proc(f: ^Fiber, s: ^Descendant_State) {
                        wait_steps(f, 10)
                        s.grandchild_2_done = true
                    }, s, "Grandchild 2"),
                )
            }, s, "Losing Parent Subtree"),
        )
    }, &state)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, state.fast_done, true)
    testing.expect_value(t, state.grandchild_cleaned_up, true)
    testing.expect_value(t, state.grandchild_1_done, false)
    testing.expect_value(t, state.grandchild_2_done, false)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, state.grandchild_1_done, false)
    testing.expect_value(t, state.grandchild_2_done, false)
}

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

    for t_step := 0; t_step < 100; t_step += 1 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, len(wake_history), TOTAL_TIMERS)

    for i in 0 ..< len(wake_history) - 1 {
        t0 := wake_history[i]
        t1 := wake_history[i + 1]
        testing.expect(t, t0 <= t1, fmt.tprintf("Timer %d (%.3f) woke after timer %d (%.3f)", i, t0, i + 1, t1))
    }
}

@(test)
test_timer_heap_random_cancellations :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, DEFAULT_STACK_SIZE, 64)
    defer scheduler_destroy(&sched)

    TOTAL :: 200
    handles: [TOTAL]Fiber_Handle
    woke: [TOTAL]bool

    for i in 0 ..< TOTAL {
        _ = rand.float32_range(0.1, 2.0)
        handles[i] = spawn(&sched, proc(f: ^Fiber, w: ^bool) {
            wait(f, f32(f.start_time) + 0.5)
            w^ = true
        }, &woke[i])
    }

    scheduler_step(&sched, 0.016)

    cancelled_count := 0
    is_cancelled: [TOTAL]bool
    for i in 0 ..< TOTAL {
        if i % 2 == 0 {
            fiber_cancel(&sched, handles[i])
            is_cancelled[i] = true
            cancelled_count += 1
        }
    }

    for _ in 0 ..< 60 {
        scheduler_step(&sched, 0.05)
    }

    for i in 0 ..< TOTAL {
        if is_cancelled[i] {
            testing.expect_value(t, woke[i], false)
        } else {
            testing.expect_value(t, woke[i], true)
        }
    }
}

@(test)
test_pool_multi_slab_expansion_and_reclaim :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, 16 * 1024, 8)
    defer scheduler_destroy(&sched)

    TOTAL_FIBERS :: 120
    completed := 0

    for _ in 0 ..< TOTAL_FIBERS {
        spawn(&sched, proc(f: ^Fiber, c: ^int) {
            yield(f)
            c^ += 1
        }, &completed)
    }

    testing.expect(t, len(sched.fiber_pool.slabs) >= 15, "Pool should have grown to at least 15 slabs")

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, completed, TOTAL_FIBERS)
    testing.expect_value(t, len(sched.fiber_pool.free_fibers), len(sched.fiber_pool.all_fibers))
}

@(test)
test_fiber_lifecycle_generation_reuse :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, DEFAULT_STACK_SIZE, 32)
    defer scheduler_destroy(&sched)

    BATCH_SIZE :: 30
    CYCLES :: 10

    for cycle := 0; cycle < CYCLES; cycle += 1 {
        count := 0
        for _ in 0 ..< BATCH_SIZE {
            spawn(&sched, proc(f: ^Fiber, c: ^int) {
                local_var := 42
                yield(f)
                c^ += local_var
            }, &count)
        }

        scheduler_step(&sched, 0.016)
        scheduler_step(&sched, 0.016)

        testing.expect_value(t, count, BATCH_SIZE * 42)
    }
}

@(test)
test_local_variable_isolation_many_fibers :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    COUNT :: 50
    success_flags: [COUNT]bool

    for i in 0 ..< COUNT {
        spawn(&sched, proc(f: ^Fiber, ok: ^bool) {
            arr: [64]u64
            for j in 0 ..< 64 {
                arr[j] = u64(uintptr(f)) + u64(j)
            }

            for _ in 0 ..< 5 {
                yield(f)
            }

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

@(test)
test_10k_yield_loop :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ITERATIONS :: 10000
    loop_count := 0

    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        for i in 0 ..< ITERATIONS {
            c^ = i + 1
            yield(f)
        }
    }, &loop_count)

    for _ in 0 ..< ITERATIONS {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, loop_count, ITERATIONS)
}

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
        wait_steps(f, 0)
        c^ += 1
        wait_steps(f, -10)
        c^ += 1
    }, &completed)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, completed, 4)
}

@(test)
test_fiber_temp_allocator_isolation :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [2]int

    spawn(&sched, proc(f: ^Fiber, res: ^[2]int) {
        temp_slice := make([]int, 10, context.temp_allocator)
        for i in 0 ..< 10 do temp_slice[i] = i * 10

        yield(f)
        yield(f)

        sum := 0
        for val in temp_slice do sum += val
        res[0] = sum
    }, &results)

    spawn(&sched, proc(f: ^Fiber, res: ^[2]int) {
        temp_slice := make([]int, 5, context.temp_allocator)
        for i in 0 ..< 5 do temp_slice[i] = 100

        yield(f)

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

@(test)
test_with_timeout_completion :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    State :: struct {
        finished: bool,
        outcome:  Timeout_Outcome,
    }
    state := State{}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.outcome = with_timeout(f, 0.5, branch(proc(f: ^Fiber, s: ^State) {
            wait(f, 0.1)
            s.finished = true
        }, s, "Quick Task"))
    }, &state)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, state.finished, true)
    testing.expect_value(t, state.outcome, Timeout_Outcome.Completed)
}

@(test)
test_with_timeout_expired :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    State :: struct {
        finished: bool,
        outcome:  Timeout_Outcome,
    }
    state := State{}

    spawn(&sched, proc(f: ^Fiber, s: ^State) {
        s.outcome = with_timeout(f, 0.1, branch(proc(f: ^Fiber, s: ^State) {
            wait(f, 2.0)
            s.finished = true
        }, s, "Slow Task"))
    }, &state)

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, state.finished, false)
    testing.expect_value(t, state.outcome, Timeout_Outcome.Timed_Out)
}

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

    for _ in 0 ..< 3 {
        spawn(&sched, proc(f: ^Fiber, p: ^Signal_Payload) {
            signal_wait(f, p.sig)
            p.count^ += 1
        }, &payload)
    }

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, signal_waiter_count(&sig), 3)
    testing.expect_value(t, woken_count, 0)

    signal_emit(&sched, &sig)
    testing.expect_value(t, signal_waiter_count(&sig), 0)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, woken_count, 3)
}

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

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.completed, false)

    async_token_complete(&token, true)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, state.completed, true)
    testing.expect_value(t, state.success, true)
}

@(test)
test_virtual_memory_guard_pages :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched, alloc_mode = .Virtual_Memory_OS)
    defer scheduler_destroy(&sched)

    ran := false
    spawn(&sched, proc(f: ^Fiber, r: ^bool) {
        r^ = true
        yield(f)
    }, &ran)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, ran, true)
}

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
        yield(f)
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
        yield(f)
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
            yield(f)
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
        yield(f)
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
        yield(f)
        arg.out^ = arg.val
    }

    slow_task :: proc(f: ^Fiber, arg: Race_Val_Arg) {
        for _ in 0 ..< 10 {
            yield(f)
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
                yield(f)
                yield(f)
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

@(test)
test_with_timeout_proc_overloads :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    results: [3]Timeout_Outcome

    spawn(&sched, proc(f: ^Fiber, res: ^[3]Timeout_Outcome) {
        res[0] = with_timeout(f, 0.05, proc(f: ^Fiber) {
            wait(f, 0.5)
        })
    }, &results)

    spawn(&sched, proc(f: ^Fiber, res: ^[3]Timeout_Outcome) {
        spd := f32(100.0)
        res[1] = with_timeout(f, 0.5, proc(f: ^Fiber, s: ^f32) {
            wait(f, 0.05)
            s^ = 200.0
        }, &spd)
    }, &results)

    spawn(&sched, proc(f: ^Fiber, res: ^[3]Timeout_Outcome) {
        res[2] = with_timeout(f, 0.5, proc(f: ^Fiber, val: int) {
            wait(f, 0.05)
        }, 42)
    }, &results)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, results[0], Timeout_Outcome.Timed_Out)
    testing.expect_value(t, results[1], Timeout_Outcome.Completed)
    testing.expect_value(t, results[2], Timeout_Outcome.Completed)
}

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

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 1.0)
    }, scope = &scope)

    testing.expect_value(t, scope_active_count(&scope), 2)
    testing.expect_value(t, scope_is_busy(&scope), true)
    testing.expect_value(t, scope_is_empty(&scope), false)

    fiber_cancel(&sched, h1)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, scope_active_count(&scope), 1)

    scope_destroy(&sched, &scope)
    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
}

@(test)
test_fiber_time_accessors :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    captured_dt: f32 = 0.0
    captured_time: f64 = 0.0
    captured_frame: u64 = 0

    spawn(&sched, proc(f: ^Fiber) {
        yield(f)
    })

    State :: struct {
        dt:    ^f32,
        time:  ^f64,
        frame: ^u64,
    }

    spawn(&sched, proc(f: ^Fiber, s: State) {
        yield(f)
        s.dt^ = delta_time(f)
        s.time^ = current_time(f)
        s.frame^ = current_steps(f)
    }, State{&captured_dt, &captured_time, &captured_frame})

    scheduler_step(&sched, 0.033)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, captured_dt, f32(0.016))
    testing.expect(t, math.abs(captured_time - (0.033 + 0.016)) < 0.001, "Expected current_time ~ 0.049")
    testing.expect_value(t, captured_frame, u64(2))
}

@(test)
test_scope_wait :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    wave_scope: Fiber_Scope
    defer scope_destroy(&sched, &wave_scope)

    enemies_done: [3]bool
    boss_started := false

    for i in 0 ..< 3 {
        spawn(&sched, proc(f: ^Fiber, flag: ^bool) {
            wait(f, f32(1 + f.branch_index) * 0.05)
            flag^ = true
        }, &enemies_done[i], scope = &wave_scope)
    }

    Supervisor_Arg :: struct {
        scope:   ^Fiber_Scope,
        flag:    ^[3]bool,
        started: ^bool,
    }

    spawn(&sched, proc(f: ^Fiber, arg: Supervisor_Arg) {
        scope_wait(f, arg.scope)
        if arg.flag[0] && arg.flag[1] && arg.flag[2] {
            arg.started^ = true
        }
    }, Supervisor_Arg{&wave_scope, &enemies_done, &boss_started})

    for _ in 0 ..< 15 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect_value(t, enemies_done[0], true)
    testing.expect_value(t, enemies_done[1], true)
    testing.expect_value(t, enemies_done[2], true)
    testing.expect_value(t, boss_started, true)
}

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
                fail(f)
            }, "Try Melee (Fails)"),
            branch(proc(f: ^Fiber) {
                wait(f, 0.02)
                fail(f)
            }, "Try Snipe (Fails)"),
            branch(proc(f: ^Fiber) {
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

@(test)
test_race_preemption_ignoring_failures :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winning_branch: int = -99

    spawn(&sched, proc(f: ^Fiber, win: ^int) {
        winner := race(f,
            branch(proc(f: ^Fiber) {
                wait(f, 0.02)
                fail(f)
            }, "Quest A (Fails early)"),
            branch(proc(f: ^Fiber) {
                wait(f, 0.06)
            }, "Quest B (Succeeds first)"),
            branch(proc(f: ^Fiber) {
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
                fail(f)
            }),
        )
        res^ = ok
    }, &all_passed)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, all_passed, false)
}

@(test)
test_fallback_all_failing_and_by_value :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    spawn(&sched, proc(f: ^Fiber, out: ^[2]int) {
        ok, idx := fallback(f,
            branch(proc(f: ^Fiber) { fail(f) }),
            branch(proc(f: ^Fiber) { fail(f) }),
            branch(proc(f: ^Fiber) { fail(f) }),
        )
        out[0] = ok ? 1 : 0
        out[1] = idx
    }, &[2]int{1, 99})

    Arg :: struct {
        val: int,
        out: ^int,
    }
    val_res: int = 0
    spawn(&sched, proc(f: ^Fiber, out: ^int) {
        ok, _ := fallback(f,
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

@(test)
test_race_5_branches_and_all_failing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    winner_5: int = -99
    all_fail_winner: int = 99

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

@(test)
test_nested_concurrency_combinators :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    all_ok := false

    spawn(&sched, proc(f: ^Fiber, out_ok: ^bool) {
        res := sync(f,
            branch(proc(f: ^Fiber) {
                winner := race(f,
                    branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.04) }),
                )
                if winner != 1 do fail(f)
            }, "Nested Race"),

            branch(proc(f: ^Fiber) {
                ok, idx := fallback(f,
                    branch(proc(f: ^Fiber) { fail(f) }),
                    branch(proc(f: ^Fiber) { wait(f, 0.02) }),
                )
                if !ok || idx != 1 do fail(f)
            }, "Nested Fallback"),

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

@(test)
test_fiber_join_cancelled_target :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    join_result := true

    target_handle := spawn(&sched, proc(f: ^Fiber) {
        for {
            yield(f)
        }
    })

    spawn(&sched, proc(f: ^Fiber, args: ^[2]rawptr) {
        h := (cast(^Fiber_Handle)args[0])^
        res := cast(^bool)args[1]
        res^ = fiber_join(f, h)
    }, &[2]rawptr{&target_handle, &join_result})

    scheduler_step(&sched, 0.01)
    testing.expect(t, fiber_is_alive(&sched, target_handle))

    fiber_cancel(&sched, target_handle)

    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, !fiber_is_alive(&sched, target_handle))
    testing.expect_value(t, join_result, false)
}

@(test)
test_fiber_join_already_finished :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    target_handle := spawn(&sched, proc(f: ^Fiber) {
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

    event_emit(&sched, &ev, "Multicast Payload 100")

    scheduler_step(&sched, 0.01)

    for i in 0 ..< 3 {
        testing.expect_value(t, received[i], "Multicast Payload 100")
    }
    testing.expect_value(t, event_waiter_count(&ev), 0)
}

@(test)
test_event_empty_emit :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    event_emit(&sched, &ev, 999)
    testing.expect_value(t, event_waiter_count(&ev), 0)
    testing.expect(t, !event_has_waiters(&ev))
}

@(test)
test_scheduler_prewarm :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    testing.expect_value(t, len(sched.fiber_pool.all_fibers), 0)

    scheduler_prewarm(&sched, 80)
    testing.expect(t, len(sched.fiber_pool.all_fibers) >= 80)
    testing.expect(t, len(sched.fiber_pool.free_fibers) >= 80)
}

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

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, !fiber_is_alive(&sched, handle))
}

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

    signal_emit(&sched, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect(t, w1_done)
    testing.expect(t, w2_done)
    testing.expect(t, w3_done)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}

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

    cancelled_a := scope_cancel(&sched, &scope_a)
    testing.expect_value(t, cancelled_a, 1)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !ran_a)
    testing.expect(t, ran_b)
}

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
                wait(f, 0.02)
            }
        }
    }, &actor)

    scheduler_step(&sched, 0.06)
    testing.expect(t, attacks_executed >= 1)
    testing.expect_value(t, stuns_handled, 0)

    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, stuns_handled, 1)

    prev_attacks := attacks_executed
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect(t, attacks_executed > prev_attacks)
}

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
    }, &movement_done)

    scheduler_step(&sched, 0.01)

    cancelled := scope_cancel(&sched, &combat_scope)
    testing.expect_value(t, cancelled, 2)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    testing.expect(t, movement_done)
    testing.expect(t, !combat_1_done)
    testing.expect(t, !combat_2_done)
}

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

    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Monster) {
        for m.is_alive {
            wait(f, 0.02)
        }
    }, &m, scope = &m.entity_scope)

    spawn_ptr(&sched, proc(f: ^Fiber, m: ^Monster) {
        for m.is_alive {
            m.attack_count += 1
            wait(f, 0.05)
        }
    }, &m, scope = &m.attack_scope)

    scheduler_step(&sched, 0.06)
    testing.expect(t, m.attack_count >= 1)

    cancelled_attacks := scope_cancel(&sched, &m.attack_scope)
    testing.expect_value(t, cancelled_attacks, 1)

    testing.expect(t, scope_is_busy(&m.entity_scope))
    testing.expect(t, !scope_is_busy(&m.attack_scope))
}

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

    fiber_cancel(&sched, h)

    signal_emit(&sched, &sig)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}

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

    fiber_cancel(&sched, h)

    event_emit(&sched, &ev, 999)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, event_waiter_count(&ev), 0)
}

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

    cancelled := scope_cancel(&sched, &worker_scope)
    testing.expect_value(t, cancelled, 1)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.05)
    }

    testing.expect(t, !branch1_done)
    testing.expect(t, !branch2_done)
    testing.expect(t, !sync_completed)
}

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

    cancelled := scope_cancel(&sched, &race_scope)
    testing.expect_value(t, cancelled, 1)
}

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
            _, _ = fallback(f,
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

    spawn_ptr(&sched, fb_proc, &runs, scope = &fb_scope)
    scheduler_step(&sched, 0.06)
    testing.expect(t, runs >= 1)

    cancelled := scope_cancel(&sched, &fb_scope)
    testing.expect(t, cancelled >= 1)

    spawn_ptr(&sched, fb_proc, &runs, scope = &fb_scope)
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.06)
    }

    testing.expect(t, runs >= 2)
}

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

    fiber_cancel(&sched, handles[1])
    fiber_cancel(&sched, handles[3])
    fiber_cancel(&sched, handles[5])

    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, woken_count, 5)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}

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
        fiber_defer(f, proc(user_data: rawptr) {
            t := (^Cleanup_Tracker)(user_data)
            t.parent_cleaned = true
        }, tr)

        sync(f,
            branch(proc(f: ^Fiber, tr: ^Cleanup_Tracker) {
                fiber_defer(f, proc(user_data: rawptr) {
                    t := (^Cleanup_Tracker)(user_data)
                    t.child_cleaned = true
                }, tr)

                sync(f,
                    branch(proc(f: ^Fiber, tr: ^Cleanup_Tracker) {
                        fiber_defer(f, proc(user_data: rawptr) {
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

    fiber_cancel(&sched, parent_h)

    testing.expect(t, tracker.grandchild_cleaned)
    testing.expect(t, tracker.child_cleaned)
    testing.expect(t, tracker.parent_cleaned)
}

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

    fiber_cancel(&sched, handles[0])
    fiber_cancel(&sched, handles[4])

    event_emit(&sched, &ev, "PULSE")
    scheduler_step(&sched, 0.01)

    testing.expect_value(t, received_count, 4)
    testing.expect_value(t, event_waiter_count(&ev), 0)
}

@(test)
test_scheduler_prewarm_slab_expansion_under_load :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scheduler_prewarm(&sched, 32)
    stats1 := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats1.total_stacks, 32)
    testing.expect_value(t, stats1.active_fibers, 0)
    testing.expect_value(t, stats1.free_fibers, 32)

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

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.01)
    }

    stats3 := scheduler_pool_stats(&sched)
    testing.expect_value(t, stats3.active_fibers, 0)
    testing.expect_value(t, stats3.free_fibers, 64)
}

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
        _, _ = fallback(f,
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
                    fail(f)
                } else {
                    c.out^ = "RUSH_WON"
                }
            }, c, name = "Composite Rush"),

            branch(proc(f: ^Fiber, c: ^Interrupt_Ctx) {
                c.out^ = "FALLBACK_RECOVERY"
            }, c, name = "Safe Recovery"),
        )
    }, &ctx)

    scheduler_step(&sched, 0.01)

    signal_emit(&sched, &interrupt_sig)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect_value(t, outcome, "FALLBACK_RECOVERY")
}

@(test)
test_watchdog_configuration_and_disable :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    testing.expect_value(t, sched.watchdog_max_slice_ms, 100.0)

    scheduler_set_watchdog(&sched, enabled = false, max_slice_ms = 50.0)
    testing.expect(t, !sched.watchdog_enabled)
    testing.expect_value(t, sched.watchdog_max_slice_ms, 50.0)

    scheduler_set_watchdog(&sched, enabled = true, max_slice_ms = 250.0)
    testing.expect(t, sched.watchdog_enabled)
    testing.expect_value(t, sched.watchdog_max_slice_ms, 250.0)
}

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

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Monster_Attack_Ctx) {
        wait(f, 0.1)
        c.m.hp = 0
        c.touched^ = true
    }, &ctx, scope = &monster.scope)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, scope_active_count(&monster.scope), 1)

    scope_destroy(&sched, &monster.scope)
    free(monster)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect(t, !touched_after_death)
}

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

@(test)
test_event_multicast_broadcast_and_clear :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    woken_count := 0

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

    event_emit(&sched, &ev, 42)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, woken_count, 3)
    testing.expect_value(t, event_waiter_count(&ev), 0)
}

@(test)
test_generational_handle_history_capacity :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    handles: [300]Fiber_Handle

    for i in 0 ..< 300 {
        handles[i] = spawn_nil(&sched, proc(f: ^Fiber) {
        })
    }

    scheduler_step(&sched, 0.01)

    for h in handles {
        status, found := fiber_status(&sched, h)
        testing.expect(t, found, "Handle must be found in extended history")
        testing.expect_value(t, status, Fiber_Status.Completed)
    }
}

@(test)
test_scheduler_walk_tree_traversal :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    spawn_nil(&sched, proc(f: ^Fiber) {
        sync(f,
            branch(proc(f: ^Fiber) { wait(f, 0.05) }, name = "Child A"),
            branch(proc(f: ^Fiber) { wait(f, 0.05) }, name = "Child B"),
        )
    }, name = "Root Fiber")

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

    testing.expect_value(t, len(visited), 3)
    testing.expect_value(t, visited[0].name, "Root Fiber")
    testing.expect_value(t, visited[0].depth, 0)
    testing.expect_value(t, visited[1].name, "Child A")
    testing.expect_value(t, visited[1].depth, 1)
    testing.expect_value(t, visited[2].name, "Child B")
    testing.expect_value(t, visited[2].depth, 1)
}

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

    for _ in 0 ..< 2 {
        scheduler_step(&sched, 0.01)
    }
    testing.expect(t, !task_completed)
    testing.expect(t, !was_cancelled)

    signal_emit(&sched, &sig)

    scheduler_step(&sched, 0.01)

    testing.expect(t, was_cancelled)
    testing.expect(t, !task_completed)
}

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

@(test)
test_plan5_packed_generational_handles_bitwise :: proc(t: ^testing.T) {
    h1 := fiber_handle_pack(0, 1)
    testing.expect_value(t, fiber_handle_index(h1), 0)
    testing.expect_value(t, fiber_handle_gen(h1), 1)

    h2 := fiber_handle_pack(512, 42)
    testing.expect_value(t, fiber_handle_index(h2), 512)
    testing.expect_value(t, fiber_handle_gen(h2), 42)

    h_large := fiber_handle_pack(100_000, 70_000)
    testing.expect_value(t, fiber_handle_index(h_large), u32(100_000))
    testing.expect_value(t, fiber_handle_gen(h_large), u32(70_000))

    h_max := fiber_handle_pack(0xFFFF_FFFF, 0xFFFF_FFFF)
    testing.expect_value(t, fiber_handle_index(h_max), u32(0xFFFF_FFFF))
    testing.expect_value(t, fiber_handle_gen(h_max), u32(0xFFFF_FFFF))
    testing.expect_value(t, u64(h_max), u64(0xFFFF_FFFF_FFFF_FFFF))
}

@(test)
test_plan5_handle_slot_reuse_and_aba_safety :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    h1 := spawn_nil(&sched, proc(f: ^Fiber) {
    })

    idx1 := fiber_handle_index(h1)
    gen1 := fiber_handle_gen(h1)

    testing.expect(t, fiber_is_alive(&sched, h1))
    scheduler_step(&sched, 0.01)

    testing.expect(t, !fiber_is_alive(&sched, h1))
    status1, ok1 := fiber_status(&sched, h1)
    testing.expect(t, ok1)
    testing.expect_value(t, status1, Fiber_Status.Completed)

    h2 := spawn_nil(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    })

    idx2 := fiber_handle_index(h2)
    gen2 := fiber_handle_gen(h2)

    testing.expect_value(t, idx2, idx1)
    testing.expect_value(t, gen2, gen1 + 1)

    testing.expect(t, !fiber_is_alive(&sched, h1))
    testing.expect(t, fiber_find_by_handle(&sched, h1) == nil)

    testing.expect(t, fiber_is_alive(&sched, h2))
    f2 := fiber_find_by_handle(&sched, h2)
    testing.expect(t, f2 != nil)
    testing.expect_value(t, f2.handle, h2)
}

@(test)
test_plan5_intrusive_wait_queue_operations :: proc(t: ^testing.T) {
    q: Wait_Queue
    testing.expect(t, wait_queue_is_empty(&q))
    testing.expect_value(t, wait_queue_count(&q), 0)

    dummy_fibers: [10]Fiber
    for i in 0 ..< 10 {
        dummy_fibers[i].handle = fiber_handle_pack(u32(i), 1)
    }

    for i in 0 ..< 10 {
        wait_queue_push_back(&q, &dummy_fibers[i])
    }
    testing.expect(t, !wait_queue_is_empty(&q))
    testing.expect_value(t, wait_queue_count(&q), 10)
    testing.expect_value(t, q.head, &dummy_fibers[0])
    testing.expect_value(t, q.tail, &dummy_fibers[9])

    removed_head := wait_queue_remove(&q, &dummy_fibers[0])
    testing.expect(t, removed_head)
    testing.expect_value(t, wait_queue_count(&q), 9)
    testing.expect_value(t, q.head, &dummy_fibers[1])
    testing.expect(t, dummy_fibers[0].next_waiter == nil)
    testing.expect(t, dummy_fibers[0].prev_waiter == nil)

    removed_mid := wait_queue_remove(&q, &dummy_fibers[5])
    testing.expect(t, removed_mid)
    testing.expect_value(t, wait_queue_count(&q), 8)
    testing.expect(t, dummy_fibers[5].next_waiter == nil)
    testing.expect(t, dummy_fibers[5].prev_waiter == nil)

    removed_tail := wait_queue_remove(&q, &dummy_fibers[9])
    testing.expect(t, removed_tail)
    testing.expect_value(t, wait_queue_count(&q), 7)
    testing.expect_value(t, q.tail, &dummy_fibers[8])
    testing.expect(t, dummy_fibers[9].next_waiter == nil)
    testing.expect(t, dummy_fibers[9].prev_waiter == nil)

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

@(test)
test_plan5_o1_handle_lookups_under_high_fiber_load :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    FIBER_COUNT :: 256
    handles: [FIBER_COUNT]Fiber_Handle

    for i in 0 ..< FIBER_COUNT {
        handles[i] = spawn_nil(&sched, proc(f: ^Fiber) {
            wait(f, 100.0)
        })
    }

    scheduler_step(&sched, 0.01)

    for h in handles {
        f := fiber_find_by_handle(&sched, h)
        testing.expect(t, f != nil)
        testing.expect_value(t, f.handle, h)
        testing.expect(t, fiber_is_alive(&sched, h))
        slot := fiber_handle_index(h)
        testing.expect_value(t, sched.fiber_pool.all_fibers[slot].handle, h)
    }

    for i := 0; i < FIBER_COUNT; i += 2 {
        fiber_cancel(&sched, handles[i])
        testing.expect(t, !fiber_is_alive(&sched, handles[i]))
        testing.expect(t, fiber_find_by_handle(&sched, handles[i]) == nil)
    }

    for i := 1; i < FIBER_COUNT; i += 2 {
        testing.expect(t, fiber_is_alive(&sched, handles[i]))
        f := fiber_find_by_handle(&sched, handles[i])
        testing.expect(t, f != nil)
        testing.expect_value(t, f.handle, handles[i])
    }
}

@(test)
test_plan5_config_constants_integration :: proc(t: ^testing.T) {
    testing.expect(t, STACK_SIZE >= 16 * 1024)
    testing.expect_value(t, STACK_SIZE % 16, 0)
    testing.expect(t, STACKS_PER_SLAB >= 1)
    testing.expect(t, PAYLOAD_SIZE >= 64)
    testing.expect(t, TEMP_ARENA_SIZE == 0 || TEMP_ARENA_SIZE >= 1024)
    testing.expect_value(t, CANARY_SIZE, 64)
    testing.expect_value(t, u64(CANARY_MAGIC), 0xDEAD_BEEF_CAFE_BABE)
    testing.expect_value(t, HANDLE_HISTORY_CAPACITY, 2048)
}

@(test)
test_wait_queue_auto_unlinking_on_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    h1 := spawn_ptr(&sched, proc(f: ^Fiber, sig: ^Signal) {
        signal_wait(f, sig)
    }, &sig)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 1)

    fiber_cancel(&sched, h1)

    testing.expect_value(t, signal_waiter_count(&sig), 0)

    f2_woken := false
    spawn_ptr(&sched, proc(f: ^Fiber, env: ^struct { sig: ^Signal, woken: ^bool }) {
        signal_wait(f, env.sig)
        env.woken^ = true
    }, &struct { sig: ^Signal, woken: ^bool }{&sig, &f2_woken})

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, signal_waiter_count(&sig), 1)
    testing.expect(t, !f2_woken)

    signal_emit(&sched, &sig)
    scheduler_step(&sched, 0.01)
    testing.expect(t, f2_woken)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
}

@(test)
test_scope_multi_cycle_emp_stun_and_recovery :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sentry_scope: Fiber_Scope
    defer scope_destroy(&sched, &sentry_scope)

    sentries_active := 0
    for _ in 0 ..< 4 {
        spawn_ptr(&sched, proc(f: ^Fiber, count: ^int) {
            count^ += 1
            wait(f, 10.0)
        }, &sentries_active, scope = &sentry_scope)
    }

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, sentries_active, 4)
    testing.expect_value(t, scope_active_count(&sentry_scope), 4)

    cancelled := scope_cancel(&sched, &sentry_scope)
    testing.expect_value(t, cancelled, 4)
    testing.expect_value(t, scope_active_count(&sentry_scope), 0)

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
                wait(f, 0.1)
            }
        }
    }, &env)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect(t, env.shots_fired >= 2)
    testing.expect_value(t, env.stuns, 0)

    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, env.stuns, 1)

    for _ in 0 ..< 3 {
        scheduler_step(&sched, 0.05)
    }
    shots_after_stun1 := env.shots_fired

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.05)
    }
    testing.expect(t, env.shots_fired > shots_after_stun1)

    signal_emit(&sched, &stun_signal)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, env.stuns, 2)

    env.running = false
}

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
        to1 := with_timeout(f, 0.1, proc(f: ^Fiber) {
            wait(f, 0.02)
        }, "Fast Task")
        testing.expect_value(c.t, to1, Timeout_Outcome.Completed)

        to2 := with_timeout(f, 0.02, proc(f: ^Fiber) {
            wait(f, 0.2)
        }, "Slow Task")
        testing.expect_value(c.t, to2, Timeout_Outcome.Timed_Out)

        c.completed = true
    }, &ctx)

    for _ in 0 ..< 10 {
        scheduler_step(&sched, 0.02)
    }

    testing.expect(t, ctx.completed)
}

@(test)
test_fiber_calc_stack_usage_canary_breach_detection :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    f := fiber_pool_acquire(&sched.fiber_pool)
    defer {
        fiber_init_canary(f)
        fiber_pool_recycle(&sched.fiber_pool, f)
    }

    used, total := fiber_calc_stack_usage(f)
    testing.expect_value(t, total, f.stack_size)
    testing.expect(t, used < total)

    canary_ptr := ([^]u64)(f.stack_base)
    canary_ptr[0] = 0xDEADBEEFCAFE1234

    breached_used, breached_total := fiber_calc_stack_usage(f)
    testing.expect_value(t, breached_used, breached_total)
    testing.expect_value(t, breached_total, f.stack_size)
}

@(test)
test_intrusive_fiber_scope_lifecycle :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)

    f1_done := false
    f2_done := false
    f3_done := false

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

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, f1_done, false)
    testing.expect_value(t, scope_active_count(&scope), 3)

    scheduler_step(&sched, 0.03)
    testing.expect_value(t, f1_done, true)
    testing.expect_value(t, f2_done, false)
    testing.expect_value(t, f3_done, false)
    testing.expect_value(t, scope_active_count(&scope), 2)

    cancelled := scope_cancel(&sched, &scope)
    testing.expect_value(t, cancelled, 2)
    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
    testing.expect(t, scope.head == nil)
    testing.expect(t, scope.tail == nil)

    scheduler_step(&sched, 0.10)
    testing.expect_value(t, f2_done, false)
    testing.expect_value(t, f3_done, false)
}

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
        fiber_defer(fiber, proc(user_data: rawptr) {
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

    scheduler_destroy(&sched)

    testing.expect_value(t, scope_active_count(&scope), 0)
    testing.expect_value(t, scope_is_busy(&scope), false)
    testing.expect_value(t, scope_is_empty(&scope), true)
    testing.expect(t, scope.head == nil)
    testing.expect(t, scope.tail == nil)
}

@(test)
test_ready_queue_generational_aba_guard :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    exec_counts := [3]int{0, 0, 0}

    Spawn_Ctx :: struct {
        sched:       ^Scheduler,
        counts:      ^[3]int,
        target_h:    Fiber_Handle,
    }

    ctx := Spawn_Ctx{
        sched  = &sched,
        counts = &exec_counts,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
        c.counts[0] += 1
        fiber_cancel(c.sched, c.target_h)
        spawn_ptr(c.sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
            c.counts[2] += 1
        }, c, name = "Spawned Replacement Fiber 3")
    }, &ctx, name = "Fiber 1")

    h2 := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Spawn_Ctx) {
        c.counts[1] += 1
    }, &ctx, name = "Fiber 2")

    ctx.target_h = h2

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, exec_counts[0], 1)
    testing.expect_value(t, exec_counts[1], 0)
    testing.expect_value(t, exec_counts[2], 1)
}

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

        w := race(f,
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.01)
            }, name = "Fast Branch"),
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.5)
            }, name = "Slow Branch"),
        )
        c.winner^ = w

        wait(f, 0.15)
    }, &ctx, name = "Parent Runner")

    for _ in 0 ..< 20 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, race_winner, 0)
    testing.expect_value(t, independent_child_completed, true)
}

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

        w := rush(f,
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.01)
                fiber_abort_tree(bf.sched, bf)
            }, name = "Failing Branch"),
            branch(proc(bf: ^Fiber) {
                wait(bf, 0.02)
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

@(test)
test_fiber_self_join_deadlock_guard :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    join_result := true

    spawn(&sched, proc(f: ^Fiber, res: ^bool) {
        ok := fiber_join(f, f.handle)
        res^ = ok
    }, &join_result, name = "Self Joiner")

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, join_result, false)
}

@(test)
test_multi_isa_byte_opcodes_disassembly_validation :: proc(t: ^testing.T) {
    amd64_win_bytes := []u8{
        0x55,
        0x53,
        0x56,
        0x57,
        0x41, 0x54,
        0x41, 0x55,
        0x41, 0x56,
        0x41, 0x57,
        0x48, 0x81, 0xEC, 0xA0, 0x00, 0x00, 0x00,
        0x44, 0x0F, 0x7F, 0x7C, 0x24, 0x00,
        0x44, 0x0F, 0x7F, 0x74, 0x24, 0x10,
        0x44, 0x0F, 0x7F, 0x6C, 0x24, 0x20,
        0x44, 0x0F, 0x7F, 0x64, 0x24, 0x30,
        0x44, 0x0F, 0x7F, 0x5C, 0x24, 0x40,
        0x44, 0x0F, 0x7F, 0x54, 0x24, 0x50,
        0x44, 0x0F, 0x7F, 0x4C, 0x24, 0x60,
        0x44, 0x0F, 0x7F, 0x44, 0x24, 0x70,
        0x0F, 0x7F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00,
        0x0F, 0x7F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00,
        0x48, 0x89, 0x21,
        0x48, 0x89, 0xD4,
        0x0F, 0x6F, 0xB4, 0x24, 0x90, 0x00, 0x00, 0x00,
        0x0F, 0x6F, 0xBC, 0x24, 0x80, 0x00, 0x00, 0x00,
        0x44, 0x0F, 0x6F, 0x44, 0x24, 0x70,
        0x44, 0x0F, 0x6F, 0x4C, 0x24, 0x60,
        0x44, 0x0F, 0x6F, 0x54, 0x24, 0x50,
        0x44, 0x0F, 0x6F, 0x5C, 0x24, 0x40,
        0x44, 0x0F, 0x6F, 0x64, 0x24, 0x30,
        0x44, 0x0F, 0x6F, 0x6C, 0x24, 0x20,
        0x44, 0x0F, 0x6F, 0x74, 0x24, 0x10,
        0x44, 0x0F, 0x6F, 0x7C, 0x24, 0x00,
        0x48, 0x81, 0xC4, 0xA0, 0x00, 0x00, 0x00,
        0x41, 0x5F,
        0x41, 0x5E,
        0x41, 0x5D,
        0x41, 0x5C,
        0x5F,
        0x5E,
        0x5B,
        0x5D,
        0xC3,
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

    arm64_bytes := []u8{
        0xFF, 0x83, 0x02, 0xD1,
        0xFD, 0x7B, 0x00, 0xA9,
        0xF3, 0x53, 0x01, 0xA9,
        0xF5, 0x5B, 0x02, 0xA9,
        0xF7, 0x63, 0x03, 0xA9,
        0xF9, 0x6B, 0x04, 0xA9,
        0xFB, 0x73, 0x05, 0xA9,
        0xE8, 0x27, 0x06, 0x6D,
        0xEA, 0x2F, 0x07, 0x6D,
        0xEC, 0x37, 0x08, 0x6D,
        0xEE, 0x3F, 0x09, 0x6D,
        0xE2, 0x03, 0x00, 0x91,
        0x02, 0x00, 0x00, 0xF9,
        0x3F, 0x00, 0x00, 0x91,
        0xEE, 0x3F, 0x49, 0x6D,
        0xEC, 0x37, 0x48, 0x6D,
        0xEA, 0x2F, 0x47, 0x6D,
        0xE8, 0x27, 0x46, 0x6D,
        0xFB, 0x73, 0x45, 0xA9,
        0xF9, 0x6B, 0x44, 0xA9,
        0xF7, 0x63, 0x43, 0xA9,
        0xF5, 0x5B, 0x42, 0xA9,
        0xF3, 0x53, 0x41, 0xA9,
        0xFD, 0x7B, 0x40, 0xA9,
        0xFF, 0x83, 0x02, 0x91,
        0xC0, 0x03, 0x5F, 0xD6,
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

    riscv_bytes := []u8{
        0x13, 0x01, 0x01, 0xF3,
        0x23, 0x30, 0x11, 0x00,
        0x23, 0x34, 0x81, 0x00,
        0x23, 0x38, 0x91, 0x00,
        0x23, 0x3C, 0x21, 0x01,
        0x23, 0x30, 0x31, 0x03,
        0x23, 0x34, 0x41, 0x03,
        0x23, 0x38, 0x51, 0x03,
        0x23, 0x3C, 0x61, 0x03,
        0x23, 0x30, 0x71, 0x05,
        0x23, 0x34, 0x81, 0x05,
        0x23, 0x38, 0x91, 0x05,
        0x23, 0x3C, 0xA1, 0x05,
        0x23, 0x30, 0xB1, 0x07,
        0x27, 0x34, 0x81, 0x06,
        0x27, 0x38, 0x91, 0x06,
        0x27, 0x3C, 0x21, 0x07,
        0x27, 0x30, 0x31, 0x09,
        0x27, 0x34, 0x41, 0x09,
        0x27, 0x38, 0x51, 0x09,
        0x27, 0x3C, 0x61, 0x09,
        0x27, 0x30, 0x71, 0x0B,
        0x27, 0x34, 0x81, 0x0B,
        0x27, 0x38, 0x91, 0x0B,
        0x27, 0x3C, 0xA1, 0x0B,
        0x27, 0x30, 0xB1, 0x0D,
        0x23, 0x30, 0x25, 0x00,
        0x13, 0x81, 0x05, 0x00,
        0x07, 0x3E, 0x01, 0x0C,
        0x87, 0x3E, 0x81, 0x0B,
        0x07, 0x3E, 0x01, 0x0B,
        0x87, 0x3E, 0x81, 0x0A,
        0x07, 0x3E, 0x01, 0x0A,
        0x87, 0x3E, 0x81, 0x09,
        0x07, 0x3E, 0x01, 0x09,
        0x87, 0x3E, 0x81, 0x08,
        0x07, 0x3E, 0x01, 0x08,
        0x87, 0x3E, 0x81, 0x07,
        0x07, 0x3E, 0x01, 0x07,
        0x87, 0x34, 0x81, 0x06,
        0x83, 0x3D, 0x01, 0x06,
        0x03, 0x3D, 0x81, 0x05,
        0x83, 0x3C, 0x01, 0x05,
        0x03, 0x3C, 0x81, 0x04,
        0x83, 0x3B, 0x01, 0x04,
        0x03, 0x3B, 0x81, 0x03,
        0x83, 0x3A, 0x01, 0x03,
        0x03, 0x3A, 0x81, 0x02,
        0x83, 0x39, 0x01, 0x02,
        0x03, 0x39, 0x81, 0x01,
        0x83, 0x34, 0x01, 0x01,
        0x03, 0x34, 0x81, 0x00,
        0x83, 0x30, 0x01, 0x00,
        0x13, 0x01, 0x01, 0x0D,
        0x67, 0x80, 0x00, 0x00,
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

    scheduler_run(&sched)

    clock_advance(&sched, CLOCK_REAL, 0.6)
    scheduler_run(&sched)
    testing.expect(t, !st.sim_done && !st.real_done, "Neither should be done at 0.6s")

    clock_advance(&sched, CLOCK_REAL, 0.5)
    scheduler_run(&sched)
    testing.expect(t, st.real_done, "Real-time fiber should complete even while sim clock is not advanced")
    testing.expect(t, !st.sim_done, "Sim fiber must remain asleep while sim clock is paused")

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

    clock_advance(&sched, CLOCK_PHYS, 1.0 / 60.0, steps = 1)
    scheduler_run(&sched)
    testing.expect(t, !st.done, "Should be waiting for 5 physics steps")

    clock_advance(&sched, CLOCK_PHYS, 4.0 / 60.0, steps = 4)
    scheduler_run(&sched)
    testing.expect(t, !st.done, "Should still be waiting after 4 steps")

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
        outcome:  Timeout_Outcome,
        finished: bool,
    }
    res: Result

    spawn(&sched, proc(f: ^Fiber, r: ^Result) {
        r.outcome = with_timeout(f, 0.5, branch(proc(f: ^Fiber) {
            wait(f, 2.0)
        }), timeout_clock = CLOCK_REAL)
        r.finished = true
    }, &res, clock = CLOCK_SIM)

    clock_advance(&sched, CLOCK_SIM, 0.01)
    clock_advance(&sched, CLOCK_REAL, 0.01)
    scheduler_run(&sched)
    testing.expect(t, !res.finished, "Should be running")

    clock_advance(&sched, CLOCK_REAL, 0.6)
    scheduler_run(&sched)
    testing.expect(t, res.finished, "with_timeout on CLOCK_REAL must fire even while CLOCK_SIM is paused")
    testing.expect_value(t, res.outcome, Timeout_Outcome.Timed_Out)
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

    clock_advance(&sched, CLOCK_SIM, 0.0, steps = 0)
    clock_advance(&sched, CLOCK_REAL, 0.0, steps = 0)
    clock_advance(&sched, CLOCK_PHYS, 0.0, steps = 0)
    scheduler_run(&sched)
    testing.expect(t, !st.sim_woke && !st.real_woke && !st.tick_woke, "None should wake at t=0")

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

    scheduler_step(&sched, 0.0)
    scheduler_step(&sched, 0.13)
    testing.expect_value(t, st.ticks, 1)

    scheduler_step(&sched, 0.11)
    testing.expect_value(t, st.ticks, 2)

    scheduler_step(&sched, 0.09)
    testing.expect_value(t, st.ticks, 3)

    scheduler_step(&sched, 0.08)
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
                wait(f, 0.5)
            }, clock = CLOCK_SIM),
            branch(proc(f: ^Fiber) {
                wait(f, 0.5)
            }, clock = CLOCK_REAL),
        )
        s.done = true
    }, &st)

    clock_advance(&sched, CLOCK_SIM, 0.0)
    clock_advance(&sched, CLOCK_REAL, 0.0)
    scheduler_run(&sched)

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
        fiber_defer(f, proc(raw: rawptr) {
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

        fiber_defer_cancel(f)
        s.completed += 1
    }

    handles: [dynamic]Fiber_Handle
    defer delete(handles)

    for step in 0 ..< 250 {
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

        if (xorshift64(&shared.rng_state) % 5) == 0 {
            signal_emit(&sched, &shared.sig)
        }
        if (xorshift64(&shared.rng_state) % 5) == 0 {
            event_emit(&sched, &shared.ev, step)
        }
        shared.cond_flag = (xorshift64(&shared.rng_state) % 3) == 0

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

        dt := f32(xorshift64(&shared.rng_state)%30+1) * 0.001
        paused := (xorshift64(&shared.rng_state) % 10) == 0
        clock_advance(&sched, CLOCK_REAL, dt, steps = 1)
        if !paused {
            clock_advance(&sched, CLOCK_SIM, dt, steps = 1)
        }
        scheduler_run(&sched)
    }

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
        fiber_defer(f, proc(raw: rawptr) {
            st_ptr := cast(^State)raw
            st_ptr.cleaned += 1
        }, s)

        pstats := scheduler_pool_stats(f.sched)
        if pstats.active_fibers < 24 {
            _ = race(f,
                branch(proc(f: ^Fiber, st_inner: ^State) {
                    fiber_defer(f, proc(raw: rawptr) {
                        (cast(^State)raw).cleaned += 1
                    }, st_inner)
                    wait(f, 0.05)
                }, s),
                branch(proc(f: ^Fiber, st_inner: ^State) {
                    fiber_defer(f, proc(raw: rawptr) {
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
        { "test_with_timeout_and_signal_task_failure", test_with_timeout_and_signal_task_failure },
        { "test_fiber_defer_cancel_and_run_top", test_fiber_defer_cancel_and_run_top },
        { "test_zero_polling_scope_wait_and_fiber_join", test_zero_polling_scope_wait_and_fiber_join },
        { "test_scheduler_step_returns_has_active_and_o1_step_abort", test_scheduler_step_returns_has_active_and_o1_step_abort },
        { "test_await_async_zero_context_switch_and_paused_clock", test_await_async_zero_context_switch_and_paused_clock },
        { "test_large_event_and_sticky_event_no_payload_aliasing", test_large_event_and_sticky_event_no_payload_aliasing },
        { "test_task_failure_and_cancellation_wakes_awaiters", test_task_failure_and_cancellation_wakes_awaiters },
        { "test_unbounded_sync_with_zero_stack_array", test_unbounded_sync_with_zero_stack_array },
        { "test_clock_pause_gates_advance_and_ready_queue", test_clock_pause_gates_advance_and_ready_queue },
        { "test_fiber_self_cancel_and_ancestor_cancel", test_fiber_self_cancel_and_ancestor_cancel },
        { "test_race_sibling_defer_cancels_other_sibling", test_race_sibling_defer_cancels_other_sibling },
        { "test_fail_runs_defer_before_guard_sibling_abort", test_fail_runs_defer_before_guard_sibling_abort },
        { "test_boss_demo_coroutine_patterns_stress", test_boss_demo_coroutine_patterns_stress },
        { "test_branch_event_sticky_join_scope_wait_heterogeneous_race", test_branch_event_sticky_join_scope_wait_heterogeneous_race },
        { "test_trace_hook_and_diagnostics", test_trace_hook_and_diagnostics },
        { "test_branch_task_and_branch_async", test_branch_task_and_branch_async },
        { "test_scheduler_next_wake_time_and_run_budget", test_scheduler_next_wake_time_and_run_budget },
        { "test_win64_teb_stack_bounds_and_chkstk_probe", test_win64_teb_stack_bounds_and_chkstk_probe },
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

    spawn(&sched, proc(f: ^Fiber) { wait(f, 100.0) }, scope = &scope)

    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 500) }, scope = &scope)

    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        signal_wait(f, s)
    }, &sig, scope = &scope)

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

    scheduler_step(&sched, 0.0)
    scheduler_step(&sched, 0.3 * 2.0)
    testing.expect_value(t, done, false)

    scheduler_step(&sched, 0.0)
    testing.expect_value(t, done, false)

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

    scheduler_run(&sched)

    for _ in 0 ..< 3 {
        clock_advance(&sched, CLOCK_REAL, 0.05)
        scheduler_run(&sched)
    }

    testing.expect_value(t, real_fiber_done, true)
    testing.expect_value(t, sim_fiber_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].time, 0.0)
    testing.expect(t, sched.clocks[CLOCK_REAL].time >= 0.14)

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

    clock_advance(&sched, CLOCK_PHYS, 0.5, steps = 30)
    scheduler_run(&sched)
    testing.expect_value(t, tick50_done, false)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_PHYS].steps, 30)

    clock_advance(&sched, CLOCK_PHYS, 0.8, steps = 50)
    scheduler_run(&sched)
    testing.expect_value(t, tick50_done, true)
    testing.expect_value(t, tick100_done, false)
    testing.expect_value(t, sched.clocks[CLOCK_PHYS].steps, 80)

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

    clock_advance(&sched, CLOCK_SIM, 0.10 * 0.5)
    clock_advance(&sched, CLOCK_REAL, 0.10)
    scheduler_run(&sched)

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

    spawn(&sched, proc(f: ^Fiber) { wait(f, 5.0) }, scope = &mixed_scope, clock = CLOCK_SIM)
    spawn(&sched, proc(f: ^Fiber) { wait(f, 5.0) }, scope = &mixed_scope, clock = CLOCK_REAL)
    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 100) }, scope = &mixed_scope, clock = CLOCK_SIM)
    spawn(&sched, proc(f: ^Fiber) { wait_steps(f, 100) }, scope = &mixed_scope, clock = CLOCK_PHYS)
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

    clock_advance(&sched, CLOCK_SIM, -5.0)
    testing.expect_value(t, sched.clocks[CLOCK_SIM].delta, f32(0.0))
    testing.expect(t, abs(sched.clocks[CLOCK_SIM].time - 2.5) < 1e-5)

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

    scheduler_destroy(&sched)

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

        wait(f, 0.08)
    }, &ctx)

    scheduler_step(&sched, 0.0)

    scheduler_step(&sched, 0.025)
    testing.expect_value(t, ctx.winner, 0)
    testing.expect_value(t, ctx.branch0_done, true)
    testing.expect_value(t, ctx.branch1_done, false)
    testing.expect_value(t, ctx.branch2_done, false)

    scheduler_step(&sched, 0.035)
    testing.expect_value(t, ctx.branch1_done, true)
    testing.expect_value(t, ctx.branch2_done, false)

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
        w := rush(f,
            branch(proc(f: ^Fiber) { wait(f, 0.01); fail(f) }, "Branch 0 (Fails)"),
            branch(proc(f: ^Fiber) { wait(f, 0.03) }, "Branch 1 (Succeeds)"),
            branch(proc(f: ^Fiber, c: ^Rush_Adv_Ctx) {
                wait(f, 0.10)
                c.loser_done = true
            }, c, "Branch 2 (Loser Background)"),
        )
        c.winner_rush = w

        s_ok := sync(f,
            branch(proc(f: ^Fiber) { wait(f, 0.04) }, "Sync Child A"),
            branch(proc(f: ^Fiber) { wait(f, 0.04) }, "Sync Child B"),
        )
        c.sync_ok = s_ok

        wait(f, 0.05)
    }, &ctx)

    scheduler_step(&sched, 0.0)

    scheduler_step(&sched, 0.04)
    testing.expect_value(t, ctx.winner_rush, 1)
    testing.expect_value(t, ctx.sync_ok, false)
    testing.expect_value(t, ctx.loser_done, false)

    scheduler_step(&sched, 0.05)
    testing.expect_value(t, ctx.sync_ok, true)
    testing.expect_value(t, ctx.loser_done, false)

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
        branch_scoped(f, proc(child: ^Fiber, c: ^Scoped_Ctx) {
            wait(child, 0.02)
            c.child1_step1 = true
            wait(child, 0.10)
            c.child1_step2 = true
        }, c, "Scoped Child 1")

        Payload :: struct {
            val:  int,
            dest: ^int,
        }
        branch_scoped(f, proc(child: ^Fiber, p: Payload) {
            p.dest^ = p.val * 2
        }, Payload{val = 21, dest = &c.child2_val}, "Scoped Child 2")

        wait(f, 0.05)
        c.parent_done = true
    }, &ctx)

    scheduler_step(&sched, 0.0)
    testing.expect_value(t, ctx.child2_val, 42)
    testing.expect_value(t, ctx.child1_step1, false)

    scheduler_step(&sched, 0.03)
    testing.expect_value(t, ctx.child1_step1, true)
    testing.expect_value(t, ctx.parent_done, false)

    scheduler_step(&sched, 0.03)
    testing.expect_value(t, ctx.parent_done, true)
    testing.expect_value(t, ctx.child1_step2, false)

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

    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        sticky_signal_wait(f, c.sig)
        c.sig_early_woke = true
    }, &ctx)

    spawn(&sched, proc(f: ^Fiber, c: ^Test_Ctx) {
        if val, ok := sticky_event_wait(f, c.ev); ok {
            c.ev_early_val = val
        }
    }, &ctx)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.sig_early_woke, false)
    testing.expect_value(t, ctx.ev_early_val, 0)
    testing.expect_value(t, sticky_signal_is_set(&sig), false)
    testing.expect_value(t, sticky_event_is_set(&ev), false)

    sticky_signal_emit(&sched, &sig)
    sticky_event_emit(&sched, &ev, 999)

    testing.expect_value(t, sticky_signal_is_set(&sig), true)
    testing.expect_value(t, sticky_event_is_set(&ev), true)
    peek_val, peek_ok := sticky_event_peek(&ev)
    testing.expect_value(t, peek_ok, true)
    testing.expect_value(t, peek_val, 999)

    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.sig_early_woke, true)
    testing.expect_value(t, ctx.ev_early_val, 999)

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
        w := rush(f,
            branch(proc(f: ^Fiber) {
            }),
            branch(proc(f: ^Fiber, p_fin: ^bool) {
                wait_steps(f, 3)
                p_fin^ = true
            }, b.p_rush_loser),
        )
        b.p_rush_winner^ = w

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

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, rush_winner, 0)
    testing.expect_value(t, rush_loser_finished, false)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, race_winner_index, 0)
    testing.expect_value(t, race_loser_aborted, true)
    testing.expect_value(t, rush_loser_finished, false)

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
        ok := sync_with(f, c,
            proc(f: ^Fiber, c: ^Test_Context) {
                c.sync_a = true
            },
            proc(f: ^Fiber, c: ^Test_Context) {
                c.sync_b = true
            },
        )
        c.sync_ok = ok

        w := race_with(f, c,
            proc(f: ^Fiber, c: ^Test_Context) {
                wait_steps(f, 5)
            },
            proc(f: ^Fiber, c: ^Test_Context) {
            },
        )
        c.race_won = w

        _ = sync(f,
            proc(f: ^Fiber) {
            },
            proc(f: ^Fiber) {
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
        res: ^Signal_Outcome,
    }

    outcome1: Signal_Outcome
    pkg1 := Signal_Test_Pkg{sig = &sig, res = &outcome1}
    spawn(&sched, proc(f: ^Fiber, p: ^Signal_Test_Pkg) {
        p.res^ = with_signal(f, p.sig, proc(f: ^Fiber) {
            wait_steps(f, 10)
        })
    }, &pkg1)

    spawn(&sched, proc(f: ^Fiber, s: ^Signal) {
        wait_steps(f, 2)
        signal_emit(f, s)
    }, &sig)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, outcome1, Signal_Outcome.Interrupted)

    outcome2: Signal_Outcome
    pkg2 := Signal_Test_Pkg{sig = &sig, res = &outcome2}
    spawn(&sched, proc(f: ^Fiber, p: ^Signal_Test_Pkg) {
        p.res^ = with_signal(f, p.sig, proc(f: ^Fiber) {
            wait_steps(f, 1)
        })
    }, &pkg2)

    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)
    testing.expect_value(t, outcome2, Signal_Outcome.Completed)
}

@(test)
test_task_future :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    task: Task(int)
    task_init(&task)

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

    spawn(&sched, proc(f: ^Fiber, p: ^Data_Pkg) {
        val, ok := task_await(f, p.task)
        p.box.val2 = val
        p.box.ok2 = ok
    }, &pkg)

    scheduler_step(&sched, 0.016)
    testing.expect(t, box.ok2)
    testing.expect_value(t, box.val2, 42)

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

@(test)
test_with_timeout_and_signal_task_failure :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    to_outcome := Timeout_Outcome.Completed
    spawn(&sched, proc(f: ^Fiber, out: ^Timeout_Outcome) {
        out^ = with_timeout(f, 5.0, proc(child: ^Fiber) {
            fail(child)
        })
    }, &to_outcome)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, to_outcome, Timeout_Outcome.Failed)
    testing.expect_value(t, scheduler_has_active(&sched), false)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    Sig_Box :: struct {
        sig: ^Signal,
        out: ^Signal_Outcome,
    }
    sig_outcome := Signal_Outcome.Completed
    sbox := Sig_Box{sig = &sig, out = &sig_outcome}
    spawn(&sched, proc(f: ^Fiber, b: ^Sig_Box) {
        b.out^ = with_signal(f, b.sig, proc(child: ^Fiber) {
            fail(child)
        })
    }, &sbox)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, sig_outcome, Signal_Outcome.Failed)
    testing.expect_value(t, signal_waiter_count(&sig), 0)
    testing.expect_value(t, scheduler_has_active(&sched), false)

    sticky: Sticky_Signal
    sticky_signal_init(&sticky)
    defer sticky_signal_destroy(&sticky)

    Sticky_Box :: struct {
        sig: ^Sticky_Signal,
        out: ^Signal_Outcome,
    }
    sticky_outcome := Signal_Outcome.Completed
    stbox := Sticky_Box{sig = &sticky, out = &sticky_outcome}
    spawn(&sched, proc(f: ^Fiber, b: ^Sticky_Box) {
        b.out^ = with_sticky_signal(f, b.sig, proc(child: ^Fiber) {
            fail(child)
        })
    }, &stbox)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, sticky_outcome, Signal_Outcome.Failed)

    sticky_signal_emit(&sched, &sticky)
    sticky_outcome = .Completed
    spawn(&sched, proc(f: ^Fiber, b: ^Sticky_Box) {
        b.out^ = with_sticky_signal(f, b.sig, proc(child: ^Fiber) {
            wait(child, 1.0)
        })
    }, &stbox)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, sticky_outcome, Signal_Outcome.Interrupted)
}

@(test)
test_fiber_defer_cancel_and_run_top :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Counters :: struct {
        a: int,
        b: int,
        c: int,
    }
    cnt: Counters

    spawn(&sched, proc(f: ^Fiber, c: ^Counters) {
        fiber_defer(f, proc(c: ^Counters) { c.a += 1 }, c)
        fiber_defer(f, proc(c: ^Counters) { c.b += 1 }, c)
        fiber_defer(f, proc(c: ^Counters) { c.c += 1 }, c)

        fiber_defer_cancel(f)
        fiber_defer_run_top(f)
        yield(f)
    }, &cnt)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, cnt.c, 0)
    testing.expect_value(t, cnt.b, 1)
    testing.expect_value(t, cnt.a, 0)

    scheduler_step(&sched, 0.016)
    testing.expect_value(t, cnt.c, 0)
    testing.expect_value(t, cnt.b, 1)
    testing.expect_value(t, cnt.a, 1)
}

@(test)
test_zero_polling_scope_wait_and_fiber_join :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    scope: Fiber_Scope
    scope_done := false
    Scope_Box :: struct {
        scope: ^Fiber_Scope,
        done:  ^bool,
    }
    sbox := Scope_Box{scope = &scope, done = &scope_done}

    spawn(&sched, proc(f: ^Fiber) {
        wait(f, 0.05)
    }, scope = &scope, clock = CLOCK_REAL)

    spawn(&sched, proc(f: ^Fiber, b: ^Scope_Box) {
        scope_wait(f, b.scope)
        b.done^ = true
    }, &sbox, clock = CLOCK_SIM)

    clock_advance(&sched, CLOCK_REAL, 0.01)
    scheduler_run(&sched)
    testing.expect(t, !scope_done)
    testing.expect_value(t, wait_queue_count(&scope.waiters), 1)

    clock_advance(&sched, CLOCK_REAL, 0.05)
    scheduler_run(&sched)
    testing.expect(t, scope_done)
    testing.expect_value(t, wait_queue_count(&scope.waiters), 0)

    target := spawn(&sched, proc(f: ^Fiber) {
        wait(f, 0.05)
    }, clock = CLOCK_REAL)

    Join_Box :: struct {
        target: Fiber_Handle,
        ok:     ^bool,
    }
    j1_ok := false
    j2_ok := false
    j3_ok := false
    jb1 := Join_Box{target = target, ok = &j1_ok}
    jb2 := Join_Box{target = target, ok = &j2_ok}
    jb3 := Join_Box{target = Fiber_Handle(0x1234_5678), ok = &j3_ok}

    spawn(&sched, proc(f: ^Fiber, b: ^Join_Box) {
        b.ok^ = fiber_join(f, b.target)
    }, &jb1, clock = CLOCK_SIM)
    j2_handle := spawn(&sched, proc(f: ^Fiber, b: ^Join_Box) {
        b.ok^ = fiber_join(f, b.target)
    }, &jb2, clock = CLOCK_SIM)
    spawn(&sched, proc(f: ^Fiber, b: ^Join_Box) {
        b.ok^ = fiber_join(f, b.target)
    }, &jb3, clock = CLOCK_SIM)

    clock_advance(&sched, CLOCK_REAL, 0.01)
    scheduler_run(&sched)
    testing.expect(t, !j1_ok)
    testing.expect(t, !j3_ok)

    fiber_cancel(&sched, j2_handle)

    clock_advance(&sched, CLOCK_REAL, 0.05)
    scheduler_run(&sched)
    testing.expect(t, j1_ok)
    testing.expect(t, !j2_ok)
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_scheduler_step_returns_has_active_and_o1_step_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    woken: [5]bool
    handles: [5]Fiber_Handle
    Step_Box :: struct {
        flag:  ^bool,
        steps: int,
    }
    boxes: [5]Step_Box
    for i in 0 ..< 5 {
        boxes[i] = Step_Box{flag = &woken[i], steps = 3 + i}
        handles[i] = spawn(&sched, proc(f: ^Fiber, b: ^Step_Box) {
            wait_steps(f, b.steps)
            b.flag^ = true
        }, &boxes[i])
    }

    testing.expect_value(t, scheduler_step(&sched, 0.016), true)
    fiber_cancel(&sched, handles[0])
    fiber_cancel(&sched, handles[2])
    fiber_cancel(&sched, handles[4])

    steps := 0
    for scheduler_step(&sched, 0.016) {
        steps += 1
        if steps > 20 do break
    }

    testing.expect_value(t, scheduler_has_active(&sched), false)
    testing.expect(t, !woken[0])
    testing.expect(t, woken[1])
    testing.expect(t, !woken[2])
    testing.expect(t, woken[3])
    testing.expect(t, !woken[4])
}

@(test)
test_await_async_zero_context_switch_and_paused_clock :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    tok1: Async_Token
    async_token_init(&tok1)
    res1 := false
    done1 := false

    Async_Box :: struct {
        tok:  ^Async_Token,
        res:  ^bool,
        done: ^bool,
    }
    box1 := Async_Box{tok = &tok1, res = &res1, done = &done1}
    spawn(&sched, proc(f: ^Fiber, b: ^Async_Box) {
        b.res^ = await_async(f, b.tok)
        b.done^ = true
    }, &box1, clock = CLOCK_SIM)

    tok2: Async_Token
    async_token_init(&tok2)
    h2 := spawn(&sched, proc(f: ^Fiber, tok: ^Async_Token) {
        _ = await_async(f, tok)
    }, &tok2, clock = CLOCK_SIM)

    scheduler_run(&sched)
    testing.expect(t, !done1)
    testing.expect_value(t, len(sched.async_waiters), 2)

    fiber_cancel(&sched, h2)
    testing.expect_value(t, len(sched.async_waiters), 1)

    scheduler_run(&sched)
    testing.expect(t, !done1)

    async_token_complete(&tok1, true)
    scheduler_run(&sched)
    testing.expect(t, done1)
    testing.expect(t, res1)
    testing.expect_value(t, len(sched.async_waiters), 0)
}

@(test)
test_large_event_and_sticky_event_no_payload_aliasing :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Big_Payload :: struct {
        tag:  u64,
        data: [64]u64,
    }
    Huge_Payload :: struct {
        tag:  u64,
        data: [512]u64,
    }

    ev_big: Event(Big_Payload)
    event_init(&ev_big)
    defer event_destroy(&ev_big)

    got_tag: u64 = 0
    got_last: u64 = 0
    spawn_val_preserved := false

    Val_Env :: struct {
        ev:        ^Event(Big_Payload),
        magic:     u64,
        out_tag:   ^u64,
        out_last:  ^u64,
        preserved: ^bool,
    }
    venv := Val_Env{
        ev        = &ev_big,
        magic     = 0xCAFE_1234_5678_9ABC,
        out_tag   = &got_tag,
        out_last  = &got_last,
        preserved = &spawn_val_preserved,
    }
    spawn_val(&sched, proc(f: ^Fiber, env: Val_Env) {
        p, ok := event_wait(f, env.ev)
        if ok {
            env.out_tag^ = p.tag
            env.out_last^ = p.data[63]
        }
        stored := (cast(^Val_Env)&f.payload_storage[0])^
        env.preserved^ = (stored.magic == 0xCAFE_1234_5678_9ABC)
    }, venv)

    scheduler_run(&sched)
    big := Big_Payload{tag = 77}
    big.data[63] = 9999
    event_emit(&sched, &ev_big, big)
    scheduler_run(&sched)

    testing.expect_value(t, got_tag, u64(77))
    testing.expect_value(t, got_last, u64(9999))
    testing.expect(t, spawn_val_preserved)

    ev_huge: Event(Huge_Payload)
    event_init(&ev_huge)
    defer event_destroy(&ev_huge)

    huge_tag: u64 = 0
    Huge_Box :: struct {
        ev:  ^Event(Huge_Payload),
        tag: ^u64,
    }
    hbox := Huge_Box{ev = &ev_huge, tag = &huge_tag}
    spawn(&sched, proc(f: ^Fiber, b: ^Huge_Box) {
        p, ok := event_wait(f, b.ev)
        if ok do b.tag^ = p.tag
    }, &hbox)
    h_abort := spawn(&sched, proc(f: ^Fiber, ev: ^Event(Huge_Payload)) {
        _, _ = event_wait(f, ev)
    }, &ev_huge)

    scheduler_run(&sched)
    fiber_cancel(&sched, h_abort)
    huge := Huge_Payload{tag = 4242}
    event_emit(&sched, &ev_huge, huge)
    scheduler_run(&sched)
    testing.expect_value(t, huge_tag, u64(4242))

    sticky_big: Sticky_Event(Big_Payload)
    sticky_event_init(&sticky_big)
    defer sticky_event_destroy(&sticky_big)

    sticky_out: u64 = 0
    Sticky_Box :: struct {
        ev:  ^Sticky_Event(Big_Payload),
        tag: ^u64,
    }
    sbox := Sticky_Box{ev = &sticky_big, tag = &sticky_out}
    spawn(&sched, proc(f: ^Fiber, b: ^Sticky_Box) {
        p, ok := sticky_event_wait(f, b.ev)
        if ok do b.tag^ = p.tag
    }, &sbox)
    scheduler_run(&sched)
    sticky_event_emit(&sched, &sticky_big, Big_Payload{tag = 888})
    scheduler_run(&sched)
    testing.expect_value(t, sticky_out, u64(888))
}

@(test)
test_task_failure_and_cancellation_wakes_awaiters :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    t_fail: Task(int)
    spawn_task(&sched, &t_fail, proc(f: ^Fiber) -> int {
        yield(f)
        fail(f)
        return 123
    })

    fail_done := false
    fail_ok := true
    Task_Await_Box :: struct {
        tk:   ^Task(int),
        done: ^bool,
        ok:   ^bool,
    }
    fb := Task_Await_Box{tk = &t_fail, done = &fail_done, ok = &fail_ok}
    spawn(&sched, proc(f: ^Fiber, b: ^Task_Await_Box) {
        _, ok := task_await(f, b.tk)
        b.ok^ = ok
        b.done^ = true
    }, &fb)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect(t, fail_done)
    testing.expect(t, !fail_ok)
    testing.expect_value(t, task_state(&t_fail), Task_State.Failed)
    testing.expect(t, task_is_ready(&t_fail))

    t_cancel: Task(int)
    h_cancel := spawn_task(&sched, &t_cancel, proc(f: ^Fiber) -> int {
        wait(f, 5.0)
        return 456
    })

    cancel_done := false
    cancel_ok := true
    cb := Task_Await_Box{tk = &t_cancel, done = &cancel_done, ok = &cancel_ok}
    spawn(&sched, proc(f: ^Fiber, b: ^Task_Await_Box) {
        _, ok := task_await(f, b.tk)
        b.ok^ = ok
        b.done^ = true
    }, &cb)

    scheduler_step(&sched, 0.016)
    testing.expect(t, !cancel_done)

    fiber_cancel(&sched, h_cancel)
    scheduler_run(&sched)
    testing.expect(t, cancel_done)
    testing.expect(t, !cancel_ok)
    testing.expect_value(t, task_state(&t_cancel), Task_State.Failed)

    Big_Result :: struct {
        id:   int,
        buf:  [64]u64,
    }
    t_big: Task(Big_Result)
    spawn_task(&sched, &t_big, proc(f: ^Fiber) -> Big_Result {
        yield(f)
        r := Big_Result{id = 99}
        r.buf[63] = 5555
        return r
    })

    big_id := 0
    big_last: u64 = 0
    Big_Box :: struct {
        tk:   ^Task(Big_Result),
        id:   ^int,
        last: ^u64,
    }
    bb := Big_Box{tk = &t_big, id = &big_id, last = &big_last}
    spawn(&sched, proc(f: ^Fiber, b: ^Big_Box) {
        r, ok := task_await(f, b.tk)
        if ok {
            b.id^ = r.id
            b.last^ = r.buf[63]
        }
    }, &bb)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, big_id, 99)
    testing.expect_value(t, big_last, u64(5555))
    testing.expect_value(t, task_state(&t_big), Task_State.Completed)
}

@(test)
test_unbounded_sync_with_zero_stack_array :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    count := 0
    inc :: proc(f: ^Fiber, c: ^int) {
        yield(f)
        c^ += 1
    }

    spawn(&sched, proc(f: ^Fiber, c: ^int) {
        ok := sync_with(f, c,
            inc, inc, inc, inc, inc, inc,
            inc, inc, inc, inc, inc, inc,
            inc, inc, inc, inc, inc, inc,
            inc, inc, inc, inc, inc, inc,
        )
        if !ok do c^ = -1
    }, &count)

    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }
    testing.expect_value(t, count, 24)
}

@(test)
test_clock_pause_gates_advance_and_ready_queue :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    Ctx :: struct {
        sig:          ^Signal,
        sim_ran:      int,
        sig_woke:     int,
        yield_now_ok: bool,
        real_ran:     int,
    }
    ctx := Ctx{sig = &sig}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        signal_wait(f, c.sig)
        c.sig_woke += 1
    }, &ctx, clock = CLOCK_SIM)

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        for _ in 0 ..< 3 {
            yield(f)
            c.real_ran += 1
        }
    }, &ctx, clock = CLOCK_REAL)

    scheduler_step(&sched, 0.016, CLOCK_SIM)

    clock_set_paused(&sched, CLOCK_SIM, true)
    testing.expect_value(t, clock_is_paused(&sched, CLOCK_SIM), true)

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        c.sim_ran += 1
        yield_now(f)
        c.yield_now_ok = true
    }, &ctx, clock = CLOCK_SIM)

    signal_emit(&sched, &sig)

    t_before := scheduler_time(&sched, CLOCK_SIM)
    s_before := scheduler_steps(&sched, CLOCK_SIM)

    for _ in 0 ..< 4 {
        clock_advance(&sched, CLOCK_SIM, 0.1)
        clock_advance(&sched, CLOCK_REAL, 0.016)
        scheduler_run(&sched)
    }

    testing.expect_value(t, scheduler_time(&sched, CLOCK_SIM), t_before)
    testing.expect_value(t, scheduler_steps(&sched, CLOCK_SIM), s_before)
    testing.expect_value(t, ctx.sim_ran, 0)
    testing.expect_value(t, ctx.sig_woke, 0)
    testing.expect_value(t, ctx.yield_now_ok, false)
    testing.expect_value(t, ctx.real_ran, 3)

    clock_set_paused(&sched, CLOCK_SIM, false)
    testing.expect_value(t, clock_is_paused(&sched, CLOCK_SIM), false)

    scheduler_step(&sched, 0.016, CLOCK_SIM)

    testing.expect_value(t, ctx.sim_ran, 1)
    testing.expect_value(t, ctx.sig_woke, 1)
    testing.expect_value(t, ctx.yield_now_ok, true)
}

@(test)
test_fiber_self_cancel_and_ancestor_cancel :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Self_Ctx :: struct {
        defer_ran:   bool,
        after_ran:   bool,
        self_handle: Fiber_Handle,
    }
    self_ctx: Self_Ctx

    h_self := spawn_ptr(&sched, proc(f: ^Fiber, c: ^Self_Ctx) {
        c.self_handle = f.handle
        fiber_defer(f, proc(c: ^Self_Ctx) {
            c.defer_ran = true
        }, c)
        fiber_cancel(f, f.handle)
        c.after_ran = true
    }, &self_ctx, name = "Self Canceller")

    scheduler_step(&sched, 0.016)

    testing.expect_value(t, self_ctx.defer_ran, true)
    testing.expect_value(t, self_ctx.after_ran, false)
    testing.expect_value(t, fiber_is_alive(&sched, h_self), false)
    st, ok := fiber_status(&sched, h_self)
    testing.expect_value(t, ok, true)
    testing.expect_value(t, st, Fiber_Status.Aborted)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    Anc_Ctx :: struct {
        scope:          ^Fiber_Scope,
        parent_defer:   bool,
        sibling_defer:  bool,
        child_defer:    bool,
        other_defer:    bool,
        child_after:    bool,
        waiter_woke:    bool,
    }
    anc_ctx := Anc_Ctx{scope = &scope}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Anc_Ctx) {
        fiber_defer(f, proc(c: ^Anc_Ctx) {
            c.other_defer = true
        }, c)
        wait(f, 10.0)
    }, &anc_ctx, scope = &scope, name = "Scope Peer")

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Anc_Ctx) {
        fiber_defer(f, proc(c: ^Anc_Ctx) {
            c.parent_defer = true
        }, c)
        sync_with(f, c,
            proc(cf: ^Fiber, c: ^Anc_Ctx) {
                fiber_defer(cf, proc(c: ^Anc_Ctx) {
                    c.sibling_defer = true
                }, c)
                wait(cf, 10.0)
            },
            proc(cf: ^Fiber, c: ^Anc_Ctx) {
                fiber_defer(cf, proc(c: ^Anc_Ctx) {
                    c.child_defer = true
                }, c)
                yield(cf)
                scope_cancel(cf, c.scope)
                c.child_after = true
            },
        )
    }, &anc_ctx, scope = &scope, name = "Scope Ancestor")

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Anc_Ctx) {
        scope_wait(f, c.scope)
        c.waiter_woke = true
    }, &anc_ctx, name = "Scope Waiter")

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, anc_ctx.other_defer, true)
    testing.expect_value(t, anc_ctx.parent_defer, true)
    testing.expect_value(t, anc_ctx.sibling_defer, true)
    testing.expect_value(t, anc_ctx.child_defer, true)
    testing.expect_value(t, anc_ctx.child_after, false)
    testing.expect_value(t, anc_ctx.waiter_woke, true)
    testing.expect_value(t, scope_is_empty(&scope), true)
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_race_sibling_defer_cancels_other_sibling :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Ctx :: struct {
        sched:       ^Scheduler,
        c_handle:    Fiber_Handle,
        b_defer_ran: bool,
        c_defer_ran: bool,
        spawned_ran: bool,
        winner:      int,
    }
    ctx := Ctx{sched = &sched, winner = -1}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        c.winner = race_with(f, c,
            proc(bf: ^Fiber, c: ^Ctx) {
                yield(bf)
            },
            proc(bf: ^Fiber, c: ^Ctx) {
                fiber_defer(bf, proc(c: ^Ctx) {
                    c.b_defer_ran = true
                    if c.c_handle != 0 {
                        fiber_cancel(c.sched, c.c_handle)
                    }
                    spawn_ptr(c.sched, proc(sf: ^Fiber, c: ^Ctx) {
                        c.spawned_ran = true
                    }, c)
                }, c)
                wait(bf, 5.0)
            },
            proc(bf: ^Fiber, c: ^Ctx) {
                c.c_handle = bf.handle
                fiber_defer(bf, proc(c: ^Ctx) {
                    c.c_defer_ran = true
                }, c)
                wait(bf, 5.0)
            },
        )
    }, &ctx)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ctx.winner, 0)
    testing.expect_value(t, ctx.b_defer_ran, true)
    testing.expect_value(t, ctx.c_defer_ran, true)
    testing.expect_value(t, ctx.spawned_ran, true)
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_fail_runs_defer_before_guard_sibling_abort :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    sig: Signal
    signal_init(&sig)
    defer signal_destroy(&sig)

    Ctx :: struct {
        sig:               ^Signal,
        primary_defer_ran: bool,
        outcome:           Signal_Outcome,
    }
    ctx := Ctx{sig = &sig}

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        c.outcome = with_signal(f, c.sig, proc(bf: ^Fiber, c: ^Ctx) {
            fiber_defer(bf, proc(c: ^Ctx) {
                c.primary_defer_ran = true
            }, c)
            yield(bf)
            fail(bf)
        }, c)
    }, &ctx)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ctx.primary_defer_ran, true)
    testing.expect_value(t, ctx.outcome, Signal_Outcome.Failed)
    testing.expect_value(t, signal_has_waiters(&sig), false)
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_boss_demo_coroutine_patterns_stress :: proc(t: ^testing.T) {
    CLOCK_PLAYER :: Clock_ID(3)

    Sim :: struct {
        sched:         Scheduler,
        boss_scope:    Fiber_Scope,
        player_scope:  Fiber_Scope,
        vfx_scope:     Fiber_Scope,
        stun_signal:   Signal,
        boss_hp:       f32,
        boss_phase:    int,
        boss_alive:    bool,
        boss_stunned:  bool,
        shield_alpha:  f32,
        player_speed:  f32,
        is_dashing:    bool,
        can_dash:      bool,
        shake_handle:  Fiber_Handle,
        shake_power:   f32,
        camera_offset: f32,
    }

    sim: Sim
    for _ in 0 ..< 3 {
        scheduler_init(&sim.sched)
        sim.boss_scope = {}
        sim.player_scope = {}
        sim.vfx_scope = {}
        signal_init(&sim.stun_signal)
        sim.boss_hp = 1000.0
        sim.boss_phase = 1
        sim.boss_alive = true
        sim.boss_stunned = false
        sim.shield_alpha = 0.0
        sim.player_speed = 320.0
        sim.is_dashing = false
        sim.can_dash = true
        sim.shake_handle = 0
        sim.shake_power = 0.0
        sim.camera_offset = 0.0

        spawn_ptr(&sim.sched, proc(f: ^Fiber, s: ^Sim) {
            s.boss_phase = 1
            race_with(f, s,
                proc(cf: ^Fiber, s: ^Sim) {
                    for s.boss_hp > 700.0 && s.boss_alive {
                        yield(cf)
                    }
                },
                proc(cf: ^Fiber, s: ^Sim) {
                    for s.boss_hp > 700.0 && s.boss_alive {
                        out := with_signal(cf, &s.stun_signal, proc(af: ^Fiber, s: ^Sim) {
                            sync_with(af, s,
                                proc(bf: ^Fiber, s: ^Sim) {
                                    for s.boss_alive { wait(bf, 0.25) }
                                },
                                proc(bf: ^Fiber, s: ^Sim) {
                                    for s.boss_alive { wait(bf, 0.4) }
                                },
                            )
                        }, s)
                        if out == .Interrupted && s.boss_hp > 700.0 && s.boss_alive {
                            s.boss_stunned = true
                            fiber_defer(cf, proc(s: ^Sim) { s.boss_stunned = false }, s)
                            wait(cf, 1.5)
                            fiber_defer_run_top(cf)
                        }
                    }
                },
            )
            if !s.boss_alive do return

            s.boss_phase = 2
            fiber_defer(f, proc(s: ^Sim) { s.shield_alpha = 0.0 }, s)
            s.shield_alpha = 0.85
            wait(f, 0.5)
            fiber_defer_run_top(f)
            if !s.boss_alive do return

            if s.boss_hp > 350.0 && s.boss_alive {
                race_with(f, s,
                    proc(cf: ^Fiber, s: ^Sim) {
                        for s.boss_hp > 350.0 && s.boss_alive { yield(cf) }
                    },
                    proc(cf: ^Fiber, s: ^Sim) {
                        for s.boss_alive { wait(cf, 0.2) }
                    },
                )
            }
            if !s.boss_alive do return

            s.boss_phase = 3
            for s.boss_alive {
                yield(f)
            }
        }, &sim, scope = &sim.boss_scope, clock = CLOCK_SIM)

        spawn_ptr(&sim.sched, proc(f: ^Fiber, s: ^Sim) {
            s.can_dash = false
            s.is_dashing = true
            s.player_speed = 320.0 * 3.2
            fiber_defer(f, proc(s: ^Sim) {
                s.player_speed = 320.0
                s.is_dashing = false
                s.can_dash = true
            }, s)
            wait(f, 0.18)
            s.player_speed = 320.0
            s.is_dashing = false
            wait(f, 0.8)
            fiber_defer_run_top(f)
        }, &sim, scope = &sim.player_scope, clock = CLOCK_PLAYER)

        clock_advance(&sim.sched, CLOCK_PLAYER, 1.0 / 60.0)
        clock_advance(&sim.sched, CLOCK_SIM, 1.0 / 60.0)
        scheduler_run(&sim.sched)
        testing.expect_value(t, sim.is_dashing, true)
        testing.expect(t, signal_has_waiters(&sim.stun_signal), "Phase 1 must listen for EMP stun")

        clock_set_paused(&sim.sched, CLOCK_SIM, true)
        clock_set_paused(&sim.sched, CLOCK_PLAYER, true)
        for _ in 0 ..< 5 {
            clock_advance(&sim.sched, CLOCK_REAL, 0.1)
            scheduler_run(&sim.sched)
        }
        testing.expect_value(t, sim.is_dashing, true)
        clock_set_paused(&sim.sched, CLOCK_SIM, false)
        clock_set_paused(&sim.sched, CLOCK_PLAYER, false)

        signal_emit(&sim.sched, &sim.stun_signal)
        clock_advance(&sim.sched, CLOCK_PLAYER, 1.0 / 60.0)
        clock_advance(&sim.sched, CLOCK_SIM, 1.0 / 60.0)
        scheduler_run(&sim.sched)
        testing.expect_value(t, sim.boss_stunned, true)

        sim.boss_hp = 300.0
        for _ in 0 ..< 40 {
            clock_advance(&sim.sched, CLOCK_PLAYER, 1.0 / 60.0)
            clock_advance(&sim.sched, CLOCK_SIM, 1.0 / 60.0)
            scheduler_run(&sim.sched)
        }
        testing.expect_value(t, sim.boss_stunned, false)
        testing.expect_value(t, sim.boss_phase, 3)
        testing.expect_value(t, sim.shield_alpha, f32(0.0))

        sim.boss_alive = false
        scope_cancel(&sim.sched, &sim.player_scope)
        scope_cancel(&sim.sched, &sim.boss_scope)
        scope_cancel(&sim.sched, &sim.vfx_scope)
        testing.expect_value(t, sim.player_speed, f32(320.0))
        testing.expect_value(t, sim.is_dashing, false)
        testing.expect_value(t, sim.can_dash, true)
        testing.expect_value(t, scheduler_has_active(&sim.sched), false)

        signal_destroy(&sim.stun_signal)
        scope_destroy(&sim.sched, &sim.vfx_scope)
        scope_destroy(&sim.sched, &sim.player_scope)
        scope_destroy(&sim.sched, &sim.boss_scope)
        scheduler_destroy(&sim.sched)
    }
}

@(test)
test_branch_event_sticky_join_scope_wait_heterogeneous_race :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    ev: Event(int)
    event_init(&ev)
    defer event_destroy(&ev)

    sev: Sticky_Event(f32)
    sticky_event_init(&sev)
    defer sticky_event_destroy(&sev)

    scope: Fiber_Scope
    defer scope_destroy(&sched, &scope)

    Ctx :: struct {
        ev:           ^Event(int),
        sev:          ^Sticky_Event(f32),
        scope:        ^Fiber_Scope,
        target:       Fiber_Handle,
        ev_val:       int,
        sev_val:      f32,
        race_winner:  int,
        sync_done:    bool,
    }
    ctx := Ctx{ev = &ev, sev = &sev, scope = &scope, race_winner = -1}

    ctx.target = spawn(&sched, proc(f: ^Fiber) {
        wait(f, 0.05)
    }, scope = &scope)

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        c.race_winner = race(f,
            branch_event(c.ev, &c.ev_val),
            branch_wait(1.0),
        )
        ok := sync(f,
            branch_sticky_event(c.sev, &c.sev_val),
            branch_join(c.target),
            branch_scope_wait(c.scope),
        )
        c.sync_done = ok
    }, &ctx)

    scheduler_step(&sched, 0.016)
    event_emit(&sched, &ev, 777)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, ctx.race_winner, 0)
    testing.expect_value(t, ctx.ev_val, 777)
    testing.expect_value(t, ctx.sync_done, false)

    sticky_event_emit(&sched, &sev, 3.5)
    for _ in 0 ..< 5 {
        scheduler_step(&sched, 0.016)
    }

    testing.expect_value(t, ctx.sync_done, true)
    testing.expect_value(t, ctx.sev_val, f32(3.5))
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_trace_hook_and_diagnostics :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    Trace_Counts :: struct {
        spawns:    int,
        resumes:   int,
        suspends:  int,
        completes: int,
        fails:     int,
        aborts:    int,
    }
    counts: Trace_Counts

    scheduler_set_trace_hook(&sched, proc(ev: Trace_Event, f: ^Fiber, ud: rawptr) {
        c := (^Trace_Counts)(ud)
        if c == nil || f == nil do return
        switch ev {
        case .Spawn:    c.spawns += 1
        case .Resume:   c.resumes += 1
        case .Suspend:  c.suspends += 1
        case .Complete: c.completes += 1
        case .Fail:     c.fails += 1
        case .Abort:    c.aborts += 1
        }
    }, &counts)

    Diag_Ctx :: struct {
        resumes_seen: u64,
        defer_peak:   int,
        defer_runs:   int,
    }
    dctx: Diag_Ctx

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Diag_Ctx) {
        for _ in 0 ..< 12 {
            fiber_defer(f, proc(c: ^Diag_Ctx) {
                c.defer_runs += 1
            }, c)
        }
        c.defer_peak = fiber_defer_count(f)
        yield(f)
        yield(f)
        c.resumes_seen = fiber_resume_count(f)
    }, &dctx, name = "Normal")

    spawn_nil(&sched, proc(f: ^Fiber) {
        yield(f)
        fail(f)
    }, name = "Failing")

    h_abort := spawn_nil(&sched, proc(f: ^Fiber) {
        wait(f, 10.0)
    }, name = "Aborting")

    scheduler_step(&sched, 0.016)
    fiber_cancel(&sched, h_abort)
    scheduler_step(&sched, 0.016)
    scheduler_step(&sched, 0.016)

    testing.expect_value(t, dctx.defer_peak, 12)
    testing.expect_value(t, dctx.defer_runs, 12)
    testing.expect_value(t, dctx.resumes_seen, u64(3))
    testing.expect_value(t, counts.spawns, 3)
    testing.expect_value(t, counts.resumes, 6)
    testing.expect_value(t, counts.suspends, 4)
    testing.expect_value(t, counts.completes, 1)
    testing.expect_value(t, counts.fails, 1)
    testing.expect_value(t, counts.aborts, 1)

    scheduler_set_trace_hook(&sched, nil, nil)
}

@(test)
test_branch_task_and_branch_async :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    tk_ok: Task(int)
    tk_fail: Task(int)
    tok_ok: Async_Token
    tok_fail: Async_Token
    async_token_init(&tok_ok)
    async_token_init(&tok_fail)

    spawn_task(&sched, &tk_ok, proc(f: ^Fiber) -> int {
        wait(f, 0.02)
        return 777
    })
    spawn_task(&sched, &tk_fail, proc(f: ^Fiber) -> int {
        wait(f, 0.01)
        fail(f)
        return 0
    })

    Ctx :: struct {
        tk_ok:    ^Task(int),
        tk_fail:  ^Task(int),
        tok_ok:   ^Async_Token,
        tok_fail: ^Async_Token,
        w1:       int,
        v1:       int,
        w2:       int,
        w3:       int,
        w4:       int,
    }
    ctx := Ctx{
        tk_ok    = &tk_ok,
        tk_fail  = &tk_fail,
        tok_ok   = &tok_ok,
        tok_fail = &tok_fail,
        w1       = -2,
        w2       = -2,
        w3       = -2,
        w4       = -2,
    }

    spawn_ptr(&sched, proc(f: ^Fiber, c: ^Ctx) {
        local_val := 0
        c.w1 = race(f,
            branch_task(c.tk_ok, &local_val),
            branch_wait(1.0),
        )
        c.v1 = local_val

        dummy := 0
        c.w2 = race(f,
            branch_task(c.tk_fail, &dummy),
            branch_wait(0.05),
        )

        c.w3 = race(f,
            branch_async(c.tok_ok),
            branch_wait(1.0),
        )

        c.w4 = race(f,
            branch_async(c.tok_fail),
            branch_wait(0.05),
        )
    }, &ctx)

    scheduler_step(&sched, 0.01)
    scheduler_step(&sched, 0.02)
    testing.expect_value(t, ctx.w1, 0)
    testing.expect_value(t, ctx.v1, 777)

    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect_value(t, ctx.w2, 1)

    async_token_complete(&tok_ok, true)
    scheduler_step(&sched, 0.01)
    testing.expect_value(t, ctx.w3, 0)

    async_token_complete(&tok_fail, false)
    for _ in 0 ..< 4 {
        scheduler_step(&sched, 0.02)
    }
    testing.expect_value(t, ctx.w4, 1)
    testing.expect_value(t, scheduler_has_active(&sched), false)
}

@(test)
test_scheduler_next_wake_time_and_run_budget :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    dt0, ok0 := scheduler_next_wake_time(&sched)
    testing.expect_value(t, ok0, false)
    testing.expect_value(t, dt0, f64(0.0))

    fired: [2]bool
    spawn_ptr(&sched, proc(f: ^Fiber, flag: ^bool) {
        wait(f, 0.5)
        flag^ = true
    }, &fired[0])
    spawn_ptr(&sched, proc(f: ^Fiber, flag: ^bool) {
        wait(f, 0.2)
        flag^ = true
    }, &fired[1])

    scheduler_run(&sched)

    dt1, ok1 := scheduler_next_wake_time(&sched)
    testing.expect_value(t, ok1, true)
    testing.expect(t, abs(dt1 - 0.2) < 0.0001, "Earliest timer must be 0.2s")

    clock_set_paused(&sched, CLOCK_SIM, true)
    _, ok_paused := scheduler_next_wake_time(&sched)
    testing.expect_value(t, ok_paused, false)
    clock_set_paused(&sched, CLOCK_SIM, false)

    scheduler_step(&sched, f32(dt1))
    testing.expect_value(t, fired[1], true)
    testing.expect_value(t, fired[0], false)

    dt2, ok2 := scheduler_next_wake_time(&sched)
    testing.expect_value(t, ok2, true)
    testing.expect(t, abs(dt2 - 0.3) < 0.0001, "Remaining timer must be 0.3s")

    scheduler_step(&sched, f32(dt2))
    testing.expect_value(t, fired[0], true)
    _, ok3 := scheduler_next_wake_time(&sched)
    testing.expect_value(t, ok3, false)

    Order_Ctx :: struct {
        order: [5]int,
        count: int,
    }
    octx: Order_Ctx
    Item :: struct {
        id:  int,
        ctx: ^Order_Ctx,
    }
    for i in 0 ..< 5 {
        spawn_val(&sched, proc(f: ^Fiber, it: Item) {
            it.ctx.order[it.ctx.count] = it.id
            it.ctx.count += 1
        }, Item{id = i, ctx = &octx})
    }

    r1, more1 := scheduler_run_budget(&sched, 2)
    testing.expect_value(t, r1, 2)
    testing.expect_value(t, more1, true)
    testing.expect_value(t, octx.count, 2)

    r2, more2 := scheduler_run_budget(&sched, 2)
    testing.expect_value(t, r2, 2)
    testing.expect_value(t, more2, true)
    testing.expect_value(t, octx.count, 4)

    r3, more3 := scheduler_run_budget(&sched, 2)
    testing.expect_value(t, r3, 1)
    testing.expect_value(t, more3, false)
    testing.expect_value(t, octx.count, 5)
    for i in 0 ..< 5 {
        testing.expect_value(t, octx.order[i], i)
    }
}

@(test)
test_win64_teb_stack_bounds_and_chkstk_probe :: proc(t: ^testing.T) {
    sched: Scheduler
    scheduler_init(&sched)
    defer scheduler_destroy(&sched)

    when ODIN_OS == .Windows && ODIN_ARCH == .amd64 {
        read_win64_teb_bounds :: asm() -> (base, limit, dealloc: rawptr) [
            #volatile,
            #clobber %rax,
            #clobber memory,
        ] {
            xor %rax, %rax
            #byte 0x65, 0x48, 0x8B, 0x04, 0x25, 0x30, 0x00, 0x00, 0x00
            mov base,    [%rax + 0x08]
            mov limit,   [%rax + 0x10]
            mov dealloc, [%rax + 0x1478]
        }

        host_base, host_limit, host_dealloc := read_win64_teb_bounds()

        Probe_Ctx :: struct {
            fiber_base:        rawptr,
            fiber_limit:       rawptr,
            fiber_dealloc:     rawptr,
            expected_base:     rawptr,
            expected_limit:    rawptr,
            checksum_ok:       bool,
        }
        pctx: Probe_Ctx

        spawn_ptr(&sched, proc(f: ^Fiber, c: ^Probe_Ctx) {
            big_buf: [10 * 1024]u8
            for i in 0 ..< len(big_buf) {
                big_buf[i] = u8((i * 7 + 3) & 0xFF)
            }
            yield(f)

            top := (uintptr(f.stack_base) + uintptr(f.stack_size)) & ~uintptr(15)
            c.expected_base = rawptr(top)
            c.expected_limit = f.stack_base
            c.fiber_base, c.fiber_limit, c.fiber_dealloc = read_win64_teb_bounds()

            ok := true
            for i in 0 ..< len(big_buf) {
                if big_buf[i] != u8((i * 7 + 3) & 0xFF) {
                    ok = false
                    break
                }
            }
            c.checksum_ok = ok
        }, &pctx)

        scheduler_step(&sched, 0.016)
        mid_base, mid_limit, mid_dealloc := read_win64_teb_bounds()
        testing.expect_value(t, mid_base, host_base)
        testing.expect_value(t, mid_limit, host_limit)
        testing.expect_value(t, mid_dealloc, host_dealloc)

        scheduler_step(&sched, 0.016)
        end_base, end_limit, end_dealloc := read_win64_teb_bounds()
        testing.expect_value(t, end_base, host_base)
        testing.expect_value(t, end_limit, host_limit)
        testing.expect_value(t, end_dealloc, host_dealloc)

        testing.expect_value(t, pctx.fiber_base, pctx.expected_base)
        testing.expect_value(t, pctx.fiber_limit, pctx.expected_limit)
        testing.expect_value(t, pctx.fiber_dealloc, pctx.expected_limit)
        testing.expect_value(t, pctx.checksum_ok, true)
    } else {
        checksum_ok := false
        spawn_ptr(&sched, proc(f: ^Fiber, ok_out: ^bool) {
            big_buf: [10 * 1024]u8
            for i in 0 ..< len(big_buf) {
                big_buf[i] = u8((i * 7 + 3) & 0xFF)
            }
            yield(f)
            ok := true
            for i in 0 ..< len(big_buf) {
                if big_buf[i] != u8((i * 7 + 3) & 0xFF) {
                    ok = false
                    break
                }
            }
            ok_out^ = ok
        }, &checksum_ok)

        scheduler_step(&sched, 0.016)
        scheduler_step(&sched, 0.016)
        testing.expect_value(t, checksum_ok, true)
    }
}
