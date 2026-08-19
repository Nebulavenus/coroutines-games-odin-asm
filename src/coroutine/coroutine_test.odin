package coroutine

import "core:testing"
import "core:fmt"

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
    }

    state := Sync_State{}

    spawn(&sched, proc(f: ^Fiber, s: ^Sync_State) {
        sync(f,
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
    defer scope_destroy(&scope)

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
