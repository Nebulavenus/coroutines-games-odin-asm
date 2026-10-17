package main

import "core:fmt"
import coroutine "../.."
import sync "../../sync"

assert :: proc(cond: bool, msg: string) {
    if !cond {
        fmt.eprintf("[ASSERTION FAILED]: %s\n", msg)
        panic(msg)
    }
}

// ----------------------------------------------------------------------------
// Test 1: Minimal Fiber Spawn, Execution & Natural Finish
// ----------------------------------------------------------------------------
test_minimal_spawn :: proc() {
    fmt.print("  [Test 1] Minimal Fiber Spawn & Natural Finish... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    executed := false
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, executed: ^bool) {
        executed^ = true
    }, &executed)

    assert(!executed, "Fiber should not execute before scheduler_step")
    coroutine.scheduler_step(&sched, 0.016)
    assert(executed, "Fiber must execute and complete upon scheduler_step")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 2: Local Variables Preserved Across Asyncify Yields
// ----------------------------------------------------------------------------
test_stack_local_variables :: proc() {
    fmt.print("  [Test 2] Local Variables Preserved Across Yields... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    stage := 0
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, stage: ^int) {
        local_a := 100
        local_b := 200
        stage^ = 1

        coroutine.wait(f, 0.050)

        assert(local_a == 100, "local_a corrupted after yield")
        assert(local_b == 200, "local_b corrupted after yield")
        stage^ = 2
    }, &stage)

    coroutine.scheduler_step(&sched, 0.016) // t = 0.016
    assert(stage == 1, "Expected stage 1 before sleep elapsed")

    coroutine.scheduler_step(&sched, 0.016) // t = 0.032
    assert(stage == 1, "Expected stage 1 still sleeping")

    coroutine.scheduler_step(&sched, 0.040) // t = 0.072 (wakes up past 0.066!)
    assert(stage == 2, "Expected stage 2 after sleep completed")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 3: Multiple Concurrent Fibers Interleaved Round-Robin
// ----------------------------------------------------------------------------
test_multiple_concurrent_fibers :: proc() {
    fmt.print("  [Test 3] Multiple Concurrent Fibers Interleaving... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    history: [dynamic]int
    defer delete(history)

    Fiber_Arg :: struct {
        id:      int,
        history: ^[dynamic]int,
    }

    arg1 := Fiber_Arg{id = 1, history = &history}
    arg2 := Fiber_Arg{id = 2, history = &history}

    worker :: proc(f: ^coroutine.Fiber, arg: ^Fiber_Arg) {
        append(arg.history, arg.id * 10 + 1)
        coroutine.wait_frames(f, 1)
        append(arg.history, arg.id * 10 + 2)
        coroutine.wait_frames(f, 1)
        append(arg.history, arg.id * 10 + 3)
    }

    coroutine.spawn(&sched, worker, &arg1)
    coroutine.spawn(&sched, worker, &arg2)

    coroutine.scheduler_step(&sched, 0.016) // Both run step 1
    coroutine.scheduler_step(&sched, 0.016) // Both run step 2
    coroutine.scheduler_step(&sched, 0.016) // Both run step 3

    assert(len(history) == 6, "Expected 6 entries in interleaved history")
    assert(history[0] == 11 && history[1] == 21, "Expected first step interleaving")
    assert(history[2] == 12 && history[3] == 22, "Expected second step interleaving")
    assert(history[4] == 13 && history[5] == 23, "Expected third step interleaving")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 4: Structured Concurrency - sync() Combinator
// ----------------------------------------------------------------------------
test_structured_sync :: proc() {
    fmt.print("  [Test 4] Structured Concurrency: sync() Combinator... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    branch_a_done := false
    branch_b_done := false
    parent_resumed := false

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, state: ^[3]^bool) {
        coroutine.sync(f,
            coroutine.branch(proc(child: ^coroutine.Fiber, p: ^bool) {
                coroutine.wait(child, 0.020)
                p^ = true
            }, state[0]),
            coroutine.branch(proc(child: ^coroutine.Fiber, p: ^bool) {
                coroutine.wait(child, 0.040)
                p^ = true
            }, state[1]),
        )
        state[2]^ = true
    }, &[3]^bool{&branch_a_done, &branch_b_done, &parent_resumed})

    coroutine.scheduler_step(&sched, 0.016) // t = 0.016
    assert(!branch_a_done && !branch_b_done && !parent_resumed, "No branch should finish yet")

    coroutine.scheduler_step(&sched, 0.024) // t = 0.040 (Branch A wait(0.020) woke at 0.036!)
    assert(branch_a_done && !branch_b_done && !parent_resumed, "Branch A should finish, parent still waiting")

    coroutine.scheduler_step(&sched, 0.024) // t = 0.064 (Branch B wait(0.040) woke at 0.056!)
    assert(branch_a_done && branch_b_done && parent_resumed, "Both branches and parent must be done")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 5: Structured Concurrency - race() Combinator & Loser Cancellation
// ----------------------------------------------------------------------------
test_structured_race :: proc() {
    fmt.print("  [Test 5] Structured Concurrency: race() Winner Cancels Loser... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    fast_done := false
    slow_done := false
    winner_idx := -1

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, state: ^[3]rawptr) {
        w_idx := (cast(^int)state[2])
        w := coroutine.race(f,
            coroutine.branch(proc(child: ^coroutine.Fiber, p: ^bool) {
                coroutine.wait(child, 0.020) // Faster
                p^ = true
            }, cast(^bool)state[0]),
            coroutine.branch(proc(child: ^coroutine.Fiber, p: ^bool) {
                coroutine.wait(child, 0.100) // Slower
                p^ = true
            }, cast(^bool)state[1]),
        )
        w_idx^ = w
    }, &[3]rawptr{&fast_done, &slow_done, &winner_idx})

    coroutine.scheduler_step(&sched, 0.016) // t = 0.016
    assert(winner_idx == -1, "Race should still be running")

    coroutine.scheduler_step(&sched, 0.020) // t = 0.036 (Fast branch completes!)
    assert(winner_idx == 0, "Expected branch 0 to win the race")
    assert(fast_done, "Fast branch must be marked done")
    assert(!slow_done, "Slow branch must have been cancelled without completing")

    coroutine.scheduler_step(&sched, 0.200) // Advance far into future
    assert(!slow_done, "Slow branch must remain dead and never run again")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 6: CSP Channels - Unbuffered Symmetrical Rendezvous
// ----------------------------------------------------------------------------
test_csp_channels :: proc() {
    fmt.print("  [Test 6] CSP Channel: Symmetrical Rendezvous... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    chan: sync.Channel(int)
    sync.chan_init(&chan, 0, context.allocator)
    defer sync.chan_destroy(&chan)

    received_val := -1

    // Receiver fiber
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, pair: ^[2]rawptr) {
        ch := (cast(^sync.Channel(int))pair[0])
        val_ptr := (cast(^int)pair[1])
        v, ok := sync.chan_recv(f, ch)
        if ok {
            val_ptr^ = v
        }
    }, &[2]rawptr{&chan, &received_val})

    coroutine.scheduler_step(&sched, 0.016)
    assert(received_val == -1, "Receiver should be blocked waiting for sender")

    // Sender fiber
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ch: ^sync.Channel(int)) {
        sync.chan_send(f, ch, 42)
    }, &chan)

    coroutine.scheduler_step(&sched, 0.016)
    assert(received_val == 42, "Receiver must receive sent value through channel rendezvous")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 7: Multi-Domain Clocks (Simulated Scaled Time vs Real-Time)
// ----------------------------------------------------------------------------
test_multi_domain_clocks :: proc() {
    fmt.print("  [Test 7] Multi-Domain Clocks: Time Scaling & Real Time... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    sim_done := false
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, p: ^bool) {
        coroutine.wait(f, 0.100) // Needs 0.100s of simulated time (0.200s real time)
        p^ = true
    }, &sim_done, clock = coroutine.CLOCK_SIM)

    coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, 0.100)
    coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, 0.100 * 0.5)
    coroutine.scheduler_run(&sched) // dt = 0.100, sim_dt = 0.050 (fiber spawned & sets wake_time = 0.050 + 0.100 = 0.150)
    assert(!sim_done, "Fiber should still be sleeping under 0.5x time scale")

    coroutine.clock_advance(&sched, coroutine.CLOCK_REAL, 0.210)
    coroutine.clock_advance(&sched, coroutine.CLOCK_SIM, 0.210 * 0.5)
    coroutine.scheduler_run(&sched) // dt = 0.210, sim_dt = 0.105 (total sim = 0.155 >= 0.150)
    assert(sim_done, "Fiber must wake up after reaching target simulated time")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 8: Structured Scopes & Group Abort
// ----------------------------------------------------------------------------
test_scope_abort :: proc() {
    fmt.print("  [Test 8] Structured Fiber_Scope: Cancellation & Tree Pruning... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    scope: coroutine.Fiber_Scope
    defer coroutine.scope_destroy(&sched, &scope)

    f1_done := false
    f2_done := false

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, p: ^bool) {
        coroutine.wait(f, 1.0)
        p^ = true
    }, &f1_done, &scope)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, p: ^bool) {
        coroutine.wait(f, 2.0)
        p^ = true
    }, &f2_done, &scope)

    coroutine.scheduler_step(&sched, 0.016)
    assert(coroutine.scope_active_count(&scope) == 2, "Scope must track 2 active fibers")

    // Cancel all fibers in the scope
    coroutine.scope_cancel(&sched, &scope)
    assert(coroutine.scope_active_count(&scope) == 0, "All fibers must be pruned from scope")

    coroutine.scheduler_step(&sched, 5.0) // Step past original sleep durations
    assert(!f1_done && !f2_done, "Aborted fibers must never execute their wake callbacks")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 9: Signal Synchronization (signal_wait & signal_emit)
// ----------------------------------------------------------------------------
test_signal_primitives :: proc() {
    fmt.print("  [Test 9] Signal Primitives: FIFO Wake & Waiter Tracking... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    sig: coroutine.Signal
    coroutine.signal_init(&sig)
    defer coroutine.signal_destroy(&sig)

    w1_done := false
    w2_done := false

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, env: ^[2]rawptr) {
        sig_ptr := cast(^coroutine.Signal)env[0]
        p_done := cast(^bool)env[1]
        coroutine.signal_wait(f, sig_ptr)
        p_done^ = true
    }, &[2]rawptr{&sig, &w1_done})

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, env: ^[2]rawptr) {
        sig_ptr := cast(^coroutine.Signal)env[0]
        p_done := cast(^bool)env[1]
        coroutine.signal_wait(f, sig_ptr)
        p_done^ = true
    }, &[2]rawptr{&sig, &w2_done})

    coroutine.scheduler_step(&sched, 0.016)
    assert(!w1_done && !w2_done, "Waiters must remain suspended before signal is emitted")
    assert(coroutine.signal_waiter_count(&sig) == 2, "Expected 2 active signal waiters")

    coroutine.signal_emit(&sched, &sig)
    assert(coroutine.signal_waiter_count(&sig) == 0, "All waiters must be drained to ready queue")

    coroutine.scheduler_step(&sched, 0.016)
    assert(w1_done && w2_done, "Both waiters must execute to completion after emit")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 10: Nested Race with Sync Loser Cancellation (Boss AI Pattern)
// ----------------------------------------------------------------------------
test_nested_race_sync_signal_abort :: proc() {
    fmt.print("  [Test 10] Nested race() Cancels Nested sync() with Child Tickers... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    Boss_Sim :: struct {
        stun_signal: coroutine.Signal,
        attack_a_ticks: int,
        attack_b_ticks: int,
        winner_idx: int,
    }

    sim: Boss_Sim
    sim.winner_idx = -1
    coroutine.signal_init(&sim.stun_signal)
    defer coroutine.signal_destroy(&sim.stun_signal)

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, s: ^Boss_Sim) {
        w := coroutine.race(f,
            // Branch 0: Nested sync with 2 infinite attack subloops
            coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Boss_Sim) {
                coroutine.sync(f,
                    coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Boss_Sim) {
                        for {
                            coroutine.ticker_wait(child, 0.04)
                            s.attack_a_ticks += 1
                        }
                    }, s, "Attack Loop A"),
                    coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Boss_Sim) {
                        for {
                            coroutine.wait(child, 0.08)
                            s.attack_b_ticks += 1
                        }
                    }, s, "Attack Loop B"),
                )
            }, s, "Sync Attack Container"),
            // Branch 1: Stun signal watcher
            coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Boss_Sim) {
                coroutine.signal_wait(f, &s.stun_signal)
            }, s, "Stun Watcher"),
        )
        s.winner_idx = w
    }, &sim)

    // Run for 0.12s -> both attacks should have fired at least once
    coroutine.scheduler_step(&sched, 0.05)
    coroutine.scheduler_step(&sched, 0.05)
    coroutine.scheduler_step(&sched, 0.05)
    assert(sim.attack_a_ticks >= 2, "Attack A must have ticked at least twice")
    assert(sim.attack_b_ticks >= 1, "Attack B must have ticked at least once")
    assert(sim.winner_idx == -1, "Race must still be active")

    ticks_a_before := sim.attack_a_ticks
    ticks_b_before := sim.attack_b_ticks

    // Player presses EMP: emit stun signal
    coroutine.signal_emit(&sched, &sim.stun_signal)
    coroutine.scheduler_step(&sched, 0.016)

    assert(sim.winner_idx == 1, "Stun signal watcher must have won the race")

    // Advance 1.0 full second into future: Attack subloops must be DEAD and never tick again!
    for _ in 0 ..< 20 {
        coroutine.scheduler_step(&sched, 0.05)
    }

    assert(sim.attack_a_ticks == ticks_a_before, "Attack A must NEVER tick after being aborted")
    assert(sim.attack_b_ticks == ticks_b_before, "Attack B must NEVER tick after being aborted")
    assert(len(sched.clocks[coroutine.CLOCK_SIM].timer_heap) == 0, "Timer heap must be completely clean with 0 leaked nodes")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 11: Ticker Zero-Drift & Abort in Nested Loop
// ----------------------------------------------------------------------------
test_ticker_zero_drift_and_abort :: proc() {
    fmt.print("  [Test 11] Ticker Precision, Zero-Drift & Safe Scope Abort... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    scope: coroutine.Fiber_Scope

    ticks := 0
    h := coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, t_count: ^int) {
        for {
            coroutine.ticker_wait(f, 0.02)
            t_count^ += 1
        }
    }, &ticks, scope = &scope)

    // Run 5 steps of 0.02s = 0.10s:
    // T = 0.02s: fiber initializes ticker, sets next_wake = 0.04s, sleeps
    // T = 0.04s: tick 1, sleeps until 0.06s
    // T = 0.06s: tick 2, sleeps until 0.08s
    // T = 0.08s: tick 3, sleeps until 0.10s
    // T = 0.10s: tick 4, sleeps until 0.12s
    for _ in 0 ..< 5 {
        coroutine.scheduler_step(&sched, 0.02)
    }
    assert(ticks == 4, "Expected exactly 4 discrete ticks after 0.10s (first tick fires at 0.04s)")

    // 6th step (T = 0.12s): tick 5
    coroutine.scheduler_step(&sched, 0.02)
    assert(ticks == 5, "Expected exactly 5 discrete ticks at 0.12s")

    // Cancel fiber via scope
    coroutine.scope_cancel(&sched, &scope)
    assert(coroutine.scope_active_count(&scope) == 0, "Scope must have 0 active fibers")

    // Step into future
    for _ in 0 ..< 10 {
        coroutine.scheduler_step(&sched, 0.02)
    }
    assert(ticks == 5, "Ticks must remain frozen at 5 after cancellation")
    assert(len(sched.clocks[coroutine.CLOCK_SIM].timer_heap) == 0, "No leftover timer nodes in heap")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 12: Rapid EMP Signal Fuzzing (Multi-Round AI Hierarchy)
// ----------------------------------------------------------------------------
test_rapid_signal_emp_fuzzing :: proc() {
    fmt.print("  [Test 12] Multi-Round EMP Stun AI Fuzzing & Memory Invariants... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    Fuzz_AI :: struct {
        stun_sig: coroutine.Signal,
        stuns_handled: int,
        rounds_completed: int,
        total_projectiles: int,
    }

    ai: Fuzz_AI
    coroutine.signal_init(&ai.stun_sig)
    defer coroutine.signal_destroy(&ai.stun_sig)

    // Spawn AI master fiber executing 3 consecutive attack-stun rounds
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, s: ^Fuzz_AI) {
        for s.rounds_completed < 3 {
            winner := coroutine.race(f,
                coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Fuzz_AI) {
                    coroutine.sync(f,
                        coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Fuzz_AI) {
                            for {
                                coroutine.ticker_wait(child, 0.02)
                                s.total_projectiles += 1
                            }
                        }, s, "Barrage Loop"),
                        coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Fuzz_AI) {
                            for {
                                coroutine.wait(child, 0.05)
                                s.total_projectiles += 2
                            }
                        }, s, "Burst Loop"),
                    )
                }, s, "Attack Combinator"),
                coroutine.branch(proc(f: ^coroutine.Fiber, s: ^Fuzz_AI) {
                    coroutine.signal_wait(f, &s.stun_sig)
                }, s, "Stun Watcher"),
            )

            if winner == 1 {
                s.stuns_handled += 1
                // Boss stunned for 0.10s
                coroutine.wait(f, 0.10)
            }
            s.rounds_completed += 1
        }
    }, &ai)

    // Simulate 300 frames with rapid EMP presses
    for frame := 1; frame <= 300; frame += 1 {
        // Press EMP at frame 20, 60, 100
        if frame == 20 || frame == 60 || frame == 100 {
            coroutine.signal_emit(&sched, &ai.stun_sig)
        }
        coroutine.scheduler_step(&sched, 0.016)
    }

    assert(ai.rounds_completed == 3, "All 3 rounds must cleanly complete")
    assert(ai.stuns_handled >= 1, "At least 1 stun must have been processed")

    // Verify fiber pool invariants: all temporary fibers must be recycled!
    stats := coroutine.scheduler_pool_stats(&sched)
    assert(stats.active_fibers == 0, "Zero fibers should remain active after AI finishes")
    assert(len(sched.clocks[coroutine.CLOCK_SIM].timer_heap) == 0, "Zero timer nodes left in heap")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 13: Verse rush() Combinator — First to Succeed Wins, Losers Continue in Background
// ----------------------------------------------------------------------------
test_verse_rush_losers_continue :: proc() {
    fmt.print("  [Test 13] Verse rush(): Losers Continue in Background... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    Rush_State :: struct {
        fast_done:  bool,
        slow_done:  bool,
        winner_idx: int,
    }
    state := Rush_State{winner_idx = -1}

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, s: ^Rush_State) {
        w := coroutine.rush(f,
            coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Rush_State) {
                coroutine.wait(child, 0.020) // Fast branch: 20ms
                s.fast_done = true
            }, s),
            coroutine.branch(proc(child: ^coroutine.Fiber, s: ^Rush_State) {
                coroutine.wait(child, 0.080) // Slow branch: 80ms
                s.slow_done = true
            }, s),
        )
        s.winner_idx = w

        // Parent resumes immediately when fast branch succeeds:
        assert(s.winner_idx == 0, "Fast branch must win rush")
        assert(s.fast_done, "Fast branch must be done")
        assert(!s.slow_done, "Slow branch must NOT be done yet")

        // Wait long enough for slow branch to also finish in background:
        coroutine.wait(f, 0.100)
        assert(s.slow_done, "Slow branch MUST have completed in background without being aborted!")
    }, &state)

    for _ in 0 ..< 15 {
        coroutine.scheduler_step(&sched, 0.016)
    }

    assert(state.fast_done && state.slow_done, "Both branches must complete under rush")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 14: Verse branch_scoped() — Parent-Bound Fire-and-Forget Subtasks
// ----------------------------------------------------------------------------
test_branch_scoped_background_and_parent_abort :: proc() {
    fmt.print("  [Test 14] Verse branch_scoped(): Parent-Bound Lifecycle... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    child_ticks := 0

    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, ct: ^int) {
        // Launch background subtask bound to f:
        coroutine.branch_scoped(f, proc(child: ^coroutine.Fiber, ct: ^int) {
            for {
                coroutine.wait(child, 0.016)
                ct^ += 1
            }
        }, ct)

        // Parent runs for 3 ticks then exits naturally:
        coroutine.wait(f, 0.050)
    }, &child_ticks)

    // Step scheduler for parent lifetime:
    for _ in 0 ..< 5 {
        coroutine.scheduler_step(&sched, 0.016)
    }

    ticks_at_exit := child_ticks
    assert(ticks_at_exit >= 2, "Scoped child must run while parent is alive")

    // Advance scheduler further: parent is gone, child MUST be aborted!
    for _ in 0 ..< 5 {
        coroutine.scheduler_step(&sched, 0.016)
    }

    assert(child_ticks == ticks_at_exit, "Scoped child must not run after parent exits")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 15: Latched State — Sticky_Event(T) and Sticky_Signal
// ----------------------------------------------------------------------------
test_sticky_event_and_signal :: proc() {
    fmt.print("  [Test 15] Latched State: Sticky_Event & Sticky_Signal... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    ready_sig: coroutine.Sticky_Signal
    val_ev:    coroutine.Sticky_Event(int)

    // Emit before any fiber awaits:
    coroutine.sticky_signal_emit(&sched, &ready_sig)
    coroutine.sticky_event_emit(&sched, &val_ev, 99)

    sig_received := false
    ev_val := 0

    // Late-joining fiber awaits already-signaled sticky primitives:
    coroutine.spawn(&sched, proc(f: ^coroutine.Fiber, data: ^[4]rawptr) {
        sig := cast(^coroutine.Sticky_Signal)data[0]
        ev := cast(^coroutine.Sticky_Event(int))data[1]
        sig_rcv := cast(^bool)data[2]
        out_v := cast(^int)data[3]

        // Must return immediately without suspending:
        coroutine.sticky_signal_wait(f, sig)
        sig_rcv^ = true

        val, ok := coroutine.sticky_event_wait(f, ev)
        if ok {
            out_v^ = val
        }
    }, &[4]rawptr{&ready_sig, &val_ev, &sig_received, &ev_val})

    coroutine.scheduler_step(&sched, 0.016)

    assert(sig_received, "Sticky_Signal must unblock late joiner immediately")
    assert(ev_val == 99, "Sticky_Event must deliver cached payload immediately")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Test 16: In-Frame Timeslice — yield_now() Cooperative Sharing
// ----------------------------------------------------------------------------
test_yield_now_same_tick :: proc() {
    fmt.print("  [Test 16] In-Frame Timeslice: yield_now() Same-Tick Interleave... ")
    sched: coroutine.Scheduler
    coroutine.scheduler_init(&sched)
    defer coroutine.scheduler_destroy(&sched)

    history: [8]int
    count := 0

    Yield_Data :: struct {
        id:      int,
        history: ^[8]int,
        count:   ^int,
    }
    d1 := Yield_Data{1, &history, &count}
    d2 := Yield_Data{2, &history, &count}

    worker :: proc(f: ^coroutine.Fiber, d: ^Yield_Data) {
        for _ in 0 ..< 2 {
            if d.count^ < 8 {
                d.history[d.count^] = d.id
                d.count^ += 1
            }
            coroutine.yield_now(f) // Relinquishes timeslice in same frame
        }
    }

    coroutine.spawn(&sched, worker, &d1)
    coroutine.spawn(&sched, worker, &d2)

    // Step scheduler for EXACTLY 1 frame:
    coroutine.scheduler_step(&sched, 0.016)

    // In 1 single frame step, both fibers interleaved execution via yield_now:
    assert(count == 4, "Both fibers must complete their yield_now iterations in the same frame")
    assert(history[0] == 1 && history[1] == 2 && history[2] == 1 && history[3] == 2, "Fibers must alternate via yield_now")
    fmt.println("OK")
}

// ----------------------------------------------------------------------------
// Main Headless Test Runner
// ----------------------------------------------------------------------------
main :: proc() {
    fmt.println("=================================================================================")
    fmt.println("   WEBASSEMBLY (js_wasm32) COMPLETE COROUTINE PRIMITIVES TEST SUITE             ")
    fmt.println("=================================================================================")
    fmt.println()

    test_minimal_spawn()
    test_stack_local_variables()
    test_multiple_concurrent_fibers()
    test_structured_sync()
    test_structured_race()
    test_csp_channels()
    test_multi_domain_clocks()
    test_scope_abort()
    test_signal_primitives()
    test_nested_race_sync_signal_abort()
    test_ticker_zero_drift_and_abort()
    test_rapid_signal_emp_fuzzing()
    test_verse_rush_losers_continue()
    test_branch_scoped_background_and_parent_abort()
    test_sticky_event_and_signal()
    test_yield_now_same_tick()

    fmt.println()
    fmt.println("=================================================================================")
    fmt.println("ALL 16 WEBASSEMBLY COROUTINE TEST SUITES PASSED (0 FAILURES)")
    fmt.println("=================================================================================")
}
