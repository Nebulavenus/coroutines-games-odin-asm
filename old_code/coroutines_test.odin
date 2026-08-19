#+build windows
package main

import "core:fmt"
import "core:testing"
import hm "core:container/handle_map"

Test_Context :: struct {
    action_count:  int,
    was_completed: bool,
    was_failed:    bool,
    cleanup_val:   Status,
}

reset_context :: proc(ctx: ^Test_Context) {
    ctx.action_count = 0
    ctx.was_completed = false
    ctx.was_failed = false
    ctx.cleanup_val = .None
}

increment_action :: proc(ctx: ^Test_Context) -> bool {
    ctx.action_count += 1
    return true
}

fail_action :: proc(ctx: ^Test_Context) -> bool {
    ctx.was_failed = true
    return false
}

complete_action :: proc(ctx: ^Test_Context) -> bool {
    ctx.was_completed = true
    return true
}

@(test)
test_wait_and_callback_sequence :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Seq: incr -> wait 0.1s -> completed
    node := seq(run(increment_action, &ctx), wait(0.10), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.action_count, 1)
    testing.expect_value(t, ctx.was_completed, false)

    executor_step(&exec, 0.05)
    testing.expect_value(t, ctx.was_completed, false)

    executor_step(&exec, 0.06)
    testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_selector_fallback :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Select: Try to Fail -> Then Fallback to Complete
    node := select(run(fail_action, &ctx), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0)

    testing.expect_value(t, ctx.was_failed, true) // First branch ran and failed
    testing.expect_value(t, ctx.was_completed, true) // Second branch successfully executed
}

@(test)
test_parallel_race :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Race: Fast wait vs Slow wait
    // If fast wait wins, slow wait is aborted and the complete action triggers
    node := seq(race(wait(0.05), wait(1.00)), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    // 0.02s elapsed. No winner yet.
    executor_step(&exec, 0.02)
    testing.expect_value(t, ctx.was_completed, false)

    // Total 0.06s elapsed. 0.05s timer completed, winning the race.
    executor_step(&exec, 0.04)
    testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_parallel_sync :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Sync: Wait 0.05s AND Wait 0.20s
    node := seq(sync(wait(0.05), wait(0.20)), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    // Step past the first timer limit (0.05s)
    executor_step(&exec, 0.10)
    testing.expect_value(t, ctx.was_completed, false) // Still waiting for the second timer (0.20s)

    // Step past the second timer limit
    executor_step(&exec, 0.15)
    testing.expect_value(t, ctx.was_completed, true) // Both are done, sync finishes
}

@(test)
test_loop_termination_on_failure :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Loop that increments action count, then fails on the third iteration
    looping_counter_action :: proc(c: ^Test_Context) -> bool {
        c.action_count += 1
        return c.action_count < 3 // Return false (fail) on the 3rd step to terminate loop
    }

    node := loop(run(looping_counter_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0) // Frame 1: count = 1, returns true (running)
    testing.expect_value(t, ctx.action_count, 1)

    executor_step(&exec, 0.0) // Frame 2: count = 2, returns true (running)
    testing.expect_value(t, ctx.action_count, 2)

    executor_step(&exec, 0.0) // Frame 3: count = 3, returns false (fails, breaking loop)
    testing.expect_value(t, ctx.action_count, 3)

    // Step once more to verify execution has stopped
    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.action_count, 3) // Count should remain 3
}

@(test)
test_tween_interpolation :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    val: f32 = 0.0
    node := tween(0.0, 10.0, 1.0, &val)
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0)
    testing.expect(t, val == 0.0, "Expected initial value to be 0.0")

    executor_step(&exec, 0.5)
    testing.expect(t, val == 5.0, "Expected value to interpolate to 5.0")

    executor_step(&exec, 0.5)
    testing.expect(t, val == 10.0, "Expected final value to interpolate to 10.0")
}

@(test)
test_wait_until :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    condition_met := false
    check_condition :: proc(data: ^bool) -> bool {
        return data^
    }

    node := seq(wait_until(check_condition, &condition_met), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.was_completed, false)

    condition_met = true
    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_wait_until_with_zero_dt :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    condition := false
    check_cond :: proc(data: ^bool) -> bool {
        return data^
    }

    node := seq(wait_until(check_cond, &condition), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    // Step with zero dt (paused simulation)
    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.was_completed, false)

    condition = true
    executor_step(&exec, 0.0)
    testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_wait_forever :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Race: 0.1s wait vs "Forever" (huge value). 0.1s should always win.
    node := seq(race(wait(0.1), wait(1e30)), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.05)
    testing.expect_value(t, ctx.was_completed, false)

    executor_step(&exec, 0.1)
    testing.expect_value(t, ctx.was_completed, true)
}

@(test)
test_weak_guard :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    alive := true
    is_valid :: proc(data: ^bool) -> bool { return data^ }

    // Weak wraps an action. If 'alive' becomes false, Weak should abort child and fail.
    node := seq(weak(wait(1.0), is_valid, &alive), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.1)
    testing.expect_value(t, ctx.was_completed, false)

    alive = false
    executor_step(&exec, 0.1)
    // Sequence should have failed because Weak failed, so complete_action never runs.
    testing.expect_value(t, ctx.was_completed, false)
}

@(test)
test_suspended_status_behavior :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    // Sequence [ Wait(0.1) ]
    // Sequence should be .Suspended while Wait is .Running
    wait_h := wait(0.1)
    seq_h := seq(wait_h)
    enqueue_node(&exec, seq_h, {})

    executor_step(&exec, 0.0)

    // Check pool status
    s_node, _ := hm.get(&exec.pool, seq_h)
    w_node, _ := hm.get(&exec.pool, wait_h)

    testing.expect_value(t, s_node.status, Status.Suspended)
    testing.expect_value(t, w_node.status, Status.Running)

    // Check active queues
    // seq_h should NOT be in active_nodes (it's suspended)
    // wait_h SHOULD be in active_nodes

    found_seq := false
    found_wait := false
    for h in exec.active_nodes {
        if h == seq_h do found_seq = true
        if h == wait_h do found_wait = true
    }

    testing.expect_value(t, found_seq, false)
    testing.expect_value(t, found_wait, true)

    // Step to finish Wait
    executor_step(&exec, 0.11)

    // Now Sequence should be Completed and freed (since it's root)
    _, ok := hm.get(&exec.pool, seq_h)
    testing.expect_value(t, ok, false)
}

@(test)
test_payload_ref_counting :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    Counter :: struct {
        val: i32,
    }

    p := rc_new(Counter{val = 10})

    testing.expect_value(t, p.ref_count, 1)

    // Use run_managed which increments ref_count
    node := run(proc(c: ^Counter) -> bool {
        c.val += 1
        return true
    }, p)

    testing.expect_value(t, p.ref_count, 2)

    enqueue_node(&exec, node, {})
    executor_step(&exec, 0.0)

    // After step, node completes and is freed (since it's root)
    // node_free should decrement ref_count
    testing.expect_value(t, p.ref_count, 1)

    // Cleanup p manually since we still have a reference
    rc_dec(p)
}

@(test)
test_payload_explicit_managed :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    Counter :: struct {
        val: i32,
    }

    p := rc_new(Counter{val = 10})
    defer rc_dec(p)

    // run_managed should use the same payload
    node := run(proc(cp: ^Counter) -> bool {
        cp.val += 5
        return true
    }, p)

    // Verify internal payload
    n, _ := hm.get(&exec.pool, node)
    cb := n.data.(Callback_Node)
    testing.expect(t, cb.is_managed, "Payload should be managed")
    testing.expect(t, cb.payload == rawptr(p), "Payload should be the same")

    enqueue_node(&exec, node, {})
    executor_step(&exec, 0.0)

    // The shared payload was updated
    testing.expect_value(t, p.data.val, 15)
}

@(test)
test_payload_destructor :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    Dest_Context :: struct {
        freed: ^bool,
    }
    freed := false
    ctx := Dest_Context{freed = &freed}

    destructor :: proc(p: ^Dest_Context) {
        p.freed^ = true
    }

    p := rc_new(ctx, destructor)

    // Use run_managed
    node := run(proc(p: ^Dest_Context) -> bool {
        return true
    }, p)

    rc_dec(p) // We drop our reference

    enqueue_node(&exec, node, {})
    executor_step(&exec, 0.0)

    // Node is freed, triggering rc_dec, which triggers destructor because ref_count becomes 0
    testing.expect_value(t, freed, true)
}

@(test)
test_wait_frames :: proc(t: ^testing.T) {
    exec: Executor
    executor_init(&exec)
    context.user_ptr = &exec
    defer executor_destroy(&exec)

    ctx: Test_Context
    reset_context(&ctx)

    // Seq: wait 3 frames -> complete
    node := seq(wait_frames(3), run(complete_action, &ctx))
    enqueue_node(&exec, node, {})

    executor_step(&exec, 0.0) // wait 1 frame
    testing.expect_value(t, ctx.was_completed, false)

    executor_step(&exec, 0.0) // wait 2 frame
    testing.expect_value(t, ctx.was_completed, false)

    executor_step(&exec, 0.0) // ends, next node runs
    testing.expect_value(t, ctx.was_completed, true)
}
