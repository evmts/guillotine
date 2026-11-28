//! Wave 3 regression tests for the tracer:
//!
//! - W3-1: the MinimalEvm sidecar reads pre-existing accounts, code and storage from
//!   the real database; a failed check is recorded and never aborts the process;
//!   sidecar setup failures and step errors are explicit diagnostic states.
//! - W3-13: advanced-trace records are completed per call frame, schedule indices
//!   count items, a gas difference at a block boundary is a failed check, and the
//!   copy, BLOCKHASH, RETURN and REVERT handlers reach the tracer on every exit.
//! - W3-15: trace capture has a step and byte budget and reports truncation.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Address = primitives.Address;

const validating: evm.TracerConfig = .{ .enabled = true, .enable_validation = true };
const ValidatedVm = evm.Evm(.{ .tracer_config = validating });
const ValidatedPlainVm = evm.Evm(.{ .enable_fusion = false, .tracer_config = validating });

test "W3-1: traced SLOAD, BALANCE, SELFBALANCE and EXTCODESIZE see pre-existing database state" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB1)) };
    const other_bytes: [20]u8 = @splat(0xC1);
    const other_code = [_]u8{ 0x60, 0x00, 0x00 };

    // SLOAD(1) + BALANCE(other) + SELFBALANCE + EXTCODESIZE(other), returned as one word.
    const code = [_]u8{ 0x60, 0x01, 0x54, 0x73 } ++ other_bytes ++ [_]u8{ 0x31, 0x47, 0x73 } ++ other_bytes ++
        [_]u8{ 0x3B, 0x01, 0x01, 0x01, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    // The state the same call leaves behind without a tracer: the reference every
    // traced run must reproduce exactly.
    var untraced_root: [32]u8 = undefined;
    inline for (.{ evm.MainnetEvm, evm.MainnetEvmWithTracer, ValidatedVm, ValidatedPlainVm }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.balance = 5000;
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);
        try db.set_storage(target.bytes, 1, 0x77);
        var other = evm.Account.zero();
        other.balance = 999;
        other.code_hash = try db.set_code(&other_code);
        try db.set_account(other_bytes, other);

        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 32), result.output.len);
        try std.testing.expectEqual(@as(u256, 0x77 + 999 + 5000 + 3), std.mem.readInt(u256, result.output[0..32], .big));
        if (VmType == evm.MainnetEvm) {
            untraced_root = try db.get_state_root();
            continue;
        }
        try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
        try std.testing.expectEqual(evm.tracer.FailureKind.none, vm.tracer.last_failure.kind);
        try std.testing.expectEqual(evm.tracer.SidecarState.active, vm.tracer.sidecar_state);
        try std.testing.expectEqual(@as(u64, 0), vm.tracer.state_bridge.read_errors);
        // The sidecar only read: the database holds exactly what the untraced call
        // leaves (the call itself changes account state, so the root is compared with it).
        try std.testing.expectEqualSlices(u8, &untraced_root, &(try db.get_state_root()));
        try std.testing.expectEqual(@as(u256, 0x77), try db.get_storage(target.bytes, 1));
        try std.testing.expectEqual(@as(u256, 999), try db.get_balance(other_bytes));
    }
}

test "W3-1: a sidecar SSTORE over pre-existing storage stays out of the database and matches Frame" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA2)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB2)) };

    // SLOAD(1); PUSH1 1; ADD; PUSH1 1; SSTORE; SLOAD(1); PUSH0; MSTORE; RETURN(0, 32)
    const code = [_]u8{
        0x60, 0x01, 0x54, 0x60, 0x01, 0x01, 0x60, 0x01, 0x55,
        0x60, 0x01, 0x54, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3,
    };
    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, contract);
    try db.set_storage(target.bytes, 1, 41);

    var vm = try ValidatedPlainVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 42), std.mem.readInt(u256, result.output[0..32], .big));
    try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
    // Exactly one write reached the database: Frame's. Had the sidecar's SSTORE gone
    // through as well, it would have run first and Frame would have stored 43.
    try std.testing.expectEqual(@as(u256, 42), try db.get_storage(target.bytes, 1));
}

test "W3-1: a divergence from the sidecar is recorded in failed_checks and never aborts" {
    const allocator = std.testing.allocator;
    // With gas checks off Frame charges nothing while the sidecar charges every
    // instruction: a synthetic, guaranteed divergence at the jump and at the exit.
    const Diverging = evm.Evm(.{ .enable_fusion = false, .disable_gas_checks = true, .tracer_config = validating });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA3)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB3)) };
    // PUSH1 1; PUSH1 2; ADD; POP; PUSH1 9; JUMP; INVALID; JUMPDEST; STOP
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x50, 0x60, 0x09, 0x56, 0x5B, 0x00 };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, contract);

    var vm = try Diverging.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    // The divergence is the point of this test: record it without failing the run on its log line.
    vm.tracer.failure_log_level = .warn;
    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    // The process is alive, the call's own result is intact, and the mismatch is on record.
    try std.testing.expect(result.success);
    try std.testing.expect(vm.tracer.failed_checks >= 2);
    try std.testing.expectEqual(evm.tracer.FailureKind.gas_divergence, vm.tracer.last_failure.kind);
    try std.testing.expect(std.mem.indexOf(u8, vm.tracer.last_failure.message(), "Gas divergence") != null);
}

test "W3-1: Tracer.assert and Tracer.fail record a structured failure without panicking" {
    var tracer = evm.Tracer.init(std.testing.allocator, validating);
    defer tracer.deinit();
    tracer.failure_log_level = .warn;
    try std.testing.expectEqual(@as(u64, 0), tracer.failed_checks);
    try std.testing.expectEqual(evm.tracer.FailureKind.none, tracer.last_failure.kind);

    tracer.assert(true, "holds");
    try std.testing.expectEqual(@as(u64, 0), tracer.failed_checks);

    tracer.assert(false, "stack invariant broken");
    try std.testing.expectEqual(@as(u64, 1), tracer.failed_checks);
    try std.testing.expectEqual(evm.tracer.FailureKind.assertion, tracer.last_failure.kind);
    try std.testing.expectEqualStrings("ASSERTION FAILED: stack invariant broken", tracer.last_failure.message());

    tracer.failKind(.stack_divergence, "stack differs at {d}", .{7});
    try std.testing.expectEqual(@as(u64, 2), tracer.failed_checks);
    try std.testing.expectEqual(evm.tracer.FailureKind.stack_divergence, tracer.last_failure.kind);
    try std.testing.expectEqualStrings("stack differs at 7", tracer.last_failure.message());

    // A message longer than the record is cut, not overflowed.
    const long: [400]u8 = @splat('x');
    tracer.fail("{s}", .{&long});
    try std.testing.expectEqual(@as(u64, 3), tracer.failed_checks);
    try std.testing.expect(tracer.last_failure.message().len <= evm.Tracer.FailureRecord.capacity);
    try std.testing.expect(tracer.last_failure.message().len > 0);
}

test "W3-1: a sidecar that cannot be created is reported as setup_failed and the call still runs" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA4)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB4)) };
    const code = [_]u8{ 0x60, 0x2A, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    // Fail the sidecar's setup at each of its first allocations in turn.
    var fail_index: usize = 0;
    while (fail_index < 6) : (fail_index += 1) {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);

        var vm = try ValidatedPlainVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        vm.tracer.allocator = failing.allocator();
        defer vm.tracer.allocator = allocator;
        vm.tracer.failure_log_level = .warn;

        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 0x2A), std.mem.readInt(u256, result.output[0..32], .big));
        if (!failing.has_induced_failure) break;
        try std.testing.expectEqual(evm.tracer.SidecarState.setup_failed, vm.tracer.sidecar_state);
        try std.testing.expect(vm.tracer.minimal_evm == null);
        try std.testing.expectEqual(@as(u64, 1), vm.tracer.failed_checks);
        try std.testing.expectEqual(evm.tracer.FailureKind.sidecar_setup_failed, vm.tracer.last_failure.kind);
    }
    // At least the first allocation failure was exercised.
    try std.testing.expect(fail_index > 0);
}

test "W3-1: an embedded tracer reports validation_disabled and runs no sidecar" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA5)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB5)) };
    const code = [_]u8{ 0x60, 0x01, 0x54, 0x00 };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, contract);
    try db.set_storage(target.bytes, 1, 5);

    var vm = try ValidatedVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    vm.tracer.embedded = true;
    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(evm.tracer.SidecarState.validation_disabled, vm.tracer.sidecar_state);
    try std.testing.expect(vm.tracer.minimal_evm == null);
    try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
}

test "W3-1: a sidecar step error is compared with how Frame exits" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA6)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB6)) };

    const Case = struct { code: []const u8, gas: u64, success: bool, state: evm.tracer.SidecarState };
    const cases = [_]Case{
        // PUSH1 1; INVALID: both interpreters halt on the same instruction.
        .{ .code = &.{ 0x60, 0x01, 0xFE }, .gas = 100_000, .success = false, .state = .sidecar_step_error },
        // PUSH1 4; JUMP; STOP: both refuse the jump to a non-JUMPDEST.
        .{ .code = &.{ 0x60, 0x04, 0x56, 0x00, 0x00 }, .gas = 100_000, .success = false, .state = .sidecar_step_error },
        // REVERT(0, 0): both revert; a revert is not a step error.
        .{ .code = &.{ 0x5F, 0x5F, 0xFD }, .gas = 100_000, .success = false, .state = .active },
        // Out of gas at block entry: Frame halts before the sidecar reaches the
        // instruction it cannot pay for. That is agreement, not a divergence.
        .{ .code = &.{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }, .gas = 21_005, .success = false, .state = .active },
        // RETURN of a range no gas can pay for: an error exit of RETURN itself.
        .{ .code = &.{ 0x63, 0xFF, 0xFF, 0xFF, 0xFF, 0x5F, 0xF3 }, .gas = 100_000, .success = false, .state = .sidecar_step_error },
        // STOP: both succeed.
        .{ .code = &.{ 0x60, 0x01, 0x50, 0x00 }, .gas = 100_000, .success = true, .state = .active },
    };
    inline for (.{ ValidatedVm, ValidatedPlainVm }) |VmType| {
        for (cases) |case| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var contract = evm.Account.zero();
            contract.code_hash = try db.set_code(case.code);
            try db.set_account(target.bytes, contract);

            var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = case.gas } });
            defer result.deinit(allocator);

            try std.testing.expectEqual(case.success, result.success);
            try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
            try std.testing.expectEqual(case.state, vm.tracer.sidecar_state);
            try std.testing.expectEqual(case.state == .sidecar_step_error, vm.tracer.sidecar_error != null);
        }
    }
}

test "W3-13: gas agrees at JUMP and JUMPI boundaries and a mismatch there is a failed check" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA7)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB7)) };
    // CALLDATASIZE; PUSH1 5; ADD; JUMP (dynamic, to 5); JUMPDEST; PUSH1 1; CALLDATASIZE;
    // PUSH1 14; ADD; JUMPI (dynamic, taken); INVALID; JUMPDEST; STOP
    const code = [_]u8{ 0x36, 0x60, 0x05, 0x01, 0x56, 0x5B, 0x60, 0x01, 0x36, 0x60, 0x0E, 0x01, 0x57, 0xFE, 0x5B, 0x00 };
    try std.testing.expectEqual(@as(u8, 0x5B), code[5]);
    try std.testing.expectEqual(@as(u8, 0x5B), code[14]);

    const Charged = ValidatedPlainVm;
    const Uncharged = evm.Evm(.{ .enable_fusion = false, .disable_gas_checks = true, .tracer_config = validating });
    inline for (.{ Charged, Uncharged }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);

        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        // Only the uncharged variant diverges, and it does so on purpose.
        if (VmType == Uncharged) vm.tracer.failure_log_level = .warn;
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);

        if (VmType == Charged) {
            try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
        } else {
            // JUMP boundary, JUMPI boundary and frame exit each count once.
            try std.testing.expectEqual(@as(u64, 3), vm.tracer.failed_checks);
            try std.testing.expectEqual(evm.tracer.FailureKind.gas_divergence, vm.tracer.last_failure.kind);
        }
    }
}

test "W3-13: advanced trace keeps parent and child records apart across a nested call" {
    const allocator = std.testing.allocator;
    const Advanced = evm.Evm(.{
        .enable_fusion = false,
        .tracer_config = .{ .enabled = true, .enable_advanced_trace = true },
    });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA8)) };
    const parent = Address{ .bytes = @as([20]u8, @splat(0xB8)) };
    const child_bytes: [20]u8 = @splat(0xC8);

    // Child: PUSH1 1; PUSH1 2; ADD; POP; STOP
    const child_code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x50, 0x00 };
    // Parent: PUSH1 7; five PUSH0 (retSize, retOffset, argsSize, argsOffset, value);
    // PUSH20 child; GAS; CALL; ADD; POP; STOP
    const parent_code = [_]u8{ 0x60, 0x07, 0x5F, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 } ++ child_bytes ++
        [_]u8{ 0x5A, 0xF1, 0x01, 0x50, 0x00 };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var parent_account = evm.Account.zero();
    parent_account.code_hash = try db.set_code(&parent_code);
    try db.set_account(parent.bytes, parent_account);
    var child_account = evm.Account.zero();
    child_account.code_hash = try db.set_code(&child_code);
    try db.set_account(child_bytes, child_account);

    var vm = try Advanced.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = parent, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);

    const steps = vm.tracer.advanced_steps.items;
    // Parent: PUSH1, 5 x PUSH0, PUSH20, GAS, CALL, ADD, POP, STOP, plus the two block
    // entries the dispatch schedule adds after GAS and after CALL (both end a gas
    // block). Child: 5 instructions.
    const block_begin: u16 = 0x100 + 0xCE; // UnifiedOpcode.BLOCK_BEGIN
    try std.testing.expectEqual(@as(usize, 12 + 2 + 5), steps.len);
    try std.testing.expect(!vm.tracer.isTruncated());

    // Schedule indices count items, not bytes: PUSH1 is a handler plus one metadata item.
    try std.testing.expectEqual(@as(u32, 0), steps[0].schedule_index);
    try std.testing.expectEqual(@as(u32, 2), steps[1].schedule_index);
    try std.testing.expectEqual(@as(u32, 3), steps[2].schedule_index);

    // steps[8] enters the block that starts at CALL and charges its static gas, the
    // 100 gas of a warm account access.
    try std.testing.expectEqual(block_begin, steps[8].opcode);
    try std.testing.expectEqual(@as(u64, 100), steps[8].gas_cost);
    // steps[9] is the parent's CALL; the child's five records follow it.
    const call = steps[9];
    try std.testing.expectEqual(steps[8].gas_after, call.gas_before);
    try std.testing.expectEqual(@as(u16, 0xF1), call.opcode);
    try std.testing.expectEqual(@as(u16, 1), call.depth);
    try std.testing.expectEqual(@as(u32, 8), call.stack_size_before);
    try std.testing.expectEqual(@as(u32, 2), call.stack_size_after);
    // Completed from the parent frame after the child returned: the cold part of the
    // account access (2600 - 100) plus the child's 3 + 3 + 3 + 2 gas.
    try std.testing.expectEqual(@as(u64, 2500 + 11), call.gas_cost);
    try std.testing.expectEqual(call.gas_before - 2511, call.gas_after);

    for (steps[10..15], [_]u16{ 0x60, 0x60, 0x01, 0x50, 0x00 }) |child, opcode| {
        try std.testing.expectEqual(@as(u16, 2), child.depth);
        try std.testing.expectEqual(opcode, child.opcode);
        // A child record keeps the child's gas: nothing from the parent frame leaks in.
        try std.testing.expectEqual(child.gas_before, child.gas_after);
        try std.testing.expectEqual(@as(u64, 0), child.gas_cost);
        try std.testing.expect(child.gas_before < call.gas_before);
    }
    try std.testing.expectEqual(@as(u32, 0), steps[10].schedule_index);
    // The child's terminal STOP is completed, not left zeroed.
    try std.testing.expectEqual(@as(u32, 0), steps[14].stack_size_before);
    try std.testing.expectEqual(@as(u32, 0), steps[14].stack_size_after);
    try std.testing.expect(steps[14].gas_after > 0);

    // The parent resumes with the gas its CALL record ends with.
    const resumed = steps[15];
    try std.testing.expectEqual(block_begin, resumed.opcode);
    try std.testing.expectEqual(@as(u16, 1), resumed.depth);
    try std.testing.expectEqual(call.gas_after, resumed.gas_before);
    const add = steps[16];
    try std.testing.expectEqual(@as(u16, 0x01), add.opcode);
    try std.testing.expectEqual(@as(u16, 1), add.depth);
    try std.testing.expectEqual(resumed.gas_after, add.gas_before);
    try std.testing.expectEqual(@as(u32, 2), add.stack_size_before);
    try std.testing.expectEqual(@as(u32, 1), add.stack_size_after);
    try std.testing.expect(add.schedule_index > call.schedule_index);
    // The parent's terminal STOP is completed as well.
    const stop = steps[18];
    try std.testing.expectEqual(@as(u16, 0x00), stop.opcode);
    try std.testing.expectEqual(stop.gas_before, stop.gas_after);
    try std.testing.expectEqual(result.gas_left, @as(u64, @intCast(stop.gas_after)));
}

test "W3-13: CALLDATACOPY and CODECOPY trace records carry dynamic gas and memory growth" {
    const allocator = std.testing.allocator;
    const Capturing = evm.Evm(.{
        .enable_fusion = false,
        .tracer_config = .{ .enabled = true, .enable_step_capture = true, .enable_advanced_trace = true },
    });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA9)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB9)) };
    // CALLDATACOPY(dest 0, offset 0, length 64); CODECOPY(dest 64, offset 0, length 32); STOP
    const code = [_]u8{ 0x60, 0x40, 0x5F, 0x5F, 0x37, 0x60, 0x20, 0x5F, 0x60, 0x40, 0x39, 0x00 };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, contract);

    var vm = try Capturing.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);
    try std.testing.expect(result.success);

    // Per-instruction steps: static 3 + copy 3 per word + memory expansion.
    const steps = vm.tracer.steps.items;
    try std.testing.expectEqual(@as(usize, 9), steps.len);
    const calldatacopy = steps[3];
    try std.testing.expectEqual(@as(u8, 0x37), calldatacopy.opcode);
    try std.testing.expectEqual(@as(u64, 3 + 6 + 6), calldatacopy.gas_cost);
    try std.testing.expectEqual(calldatacopy.gas_before - 15, calldatacopy.gas_after);
    try std.testing.expectEqual(@as(usize, 0), calldatacopy.memory_size_before);
    try std.testing.expectEqual(@as(usize, 64), calldatacopy.memory_size_after);
    const codecopy = steps[7];
    try std.testing.expectEqual(@as(u8, 0x39), codecopy.opcode);
    try std.testing.expectEqual(@as(u64, 3 + 3 + 3), codecopy.gas_cost);
    try std.testing.expectEqual(@as(usize, 64), codecopy.memory_size_before);
    try std.testing.expectEqual(@as(usize, 96), codecopy.memory_size_after);
    // The step after a copy starts with the gas the copy ended with.
    try std.testing.expectEqual(calldatacopy.gas_after, steps[4].gas_before);

    // Advanced records: Frame prepaid the static gas with the block, so a copy's own
    // record shows the dynamic part.
    const advanced = vm.tracer.advanced_steps.items;
    try std.testing.expectEqual(@as(usize, 9), advanced.len);
    try std.testing.expectEqual(@as(u16, 0x37), advanced[3].opcode);
    try std.testing.expectEqual(@as(u64, 12), advanced[3].gas_cost);
    try std.testing.expectEqual(@as(u32, 3), advanced[3].stack_size_before);
    try std.testing.expectEqual(@as(u32, 0), advanced[3].stack_size_after);
    try std.testing.expectEqual(@as(u32, 0), advanced[3].memory_size_before);
    try std.testing.expectEqual(@as(u32, 64), advanced[3].memory_size_after);
    try std.testing.expectEqual(@as(u16, 0x39), advanced[7].opcode);
    try std.testing.expectEqual(@as(u64, 6), advanced[7].gas_cost);
    try std.testing.expectEqual(@as(u32, 96), advanced[7].memory_size_after);
}

test "W3-13: copy, BLOCKHASH, RETURN and REVERT handlers stay level with the sidecar on every exit" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBA)) };

    const Case = struct { code: []const u8, success: bool };
    const cases = [_]Case{
        // CALLDATACOPY(0, 0, 32); CODECOPY(32, 0, 32); BLOCKHASH(0); POP; zero-length
        // CALLDATACOPY and CODECOPY; RETURN(0, 64)
        .{ .code = &.{
            0x60, 0x20, 0x5F, 0x5F, 0x37, 0x60, 0x20, 0x5F, 0x60, 0x20, 0x39, 0x5F, 0x40, 0x50,
            0x5F, 0x5F, 0x5F, 0x37, 0x5F, 0x5F, 0x5F, 0x39, 0x60, 0x40, 0x5F, 0xF3,
        }, .success = true },
        // CALLDATACOPY of a range no gas can pay for.
        .{ .code = &.{ 0x63, 0xFF, 0xFF, 0xFF, 0xFF, 0x5F, 0x5F, 0x37, 0x00 }, .success = false },
        // CODECOPY of a range no gas can pay for.
        .{ .code = &.{ 0x63, 0xFF, 0xFF, 0xFF, 0xFF, 0x5F, 0x5F, 0x39, 0x00 }, .success = false },
        // REVERT of a range no gas can pay for.
        .{ .code = &.{ 0x63, 0xFF, 0xFF, 0xFF, 0xFF, 0x5F, 0xFD }, .success = false },
        // REVERT(0, 32) after MSTORE.
        .{ .code = &.{ 0x60, 0x2A, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xFD }, .success = false },
    };
    for (cases) |case| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(case.code);
        try db.set_account(target.bytes, contract);

        var vm = try ValidatedPlainVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{ 1, 2, 3 }, .gas = 100_000 } });
        defer result.deinit(allocator);

        try std.testing.expectEqual(case.success, result.success);
        try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
    }
}

test "W3-15: max_steps bounds both capture lists and leaves the execution result unchanged" {
    const allocator = std.testing.allocator;
    const Unbounded = evm.Evm(.{
        .enable_fusion = false,
        .tracer_config = .{ .enabled = true, .enable_step_capture = true, .enable_advanced_trace = true },
    });
    const Bounded = evm.Evm(.{
        .enable_fusion = false,
        .tracer_config = .{ .enabled = true, .enable_step_capture = true, .enable_advanced_trace = true, .max_steps = 3 },
    });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAB)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBB)) };
    // PUSH1 1; PUSH1 2; ADD; PUSH1 3; MUL; PUSH0; MSTORE; RETURN(0, 32)
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x03, 0x02, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    var gas_left: [2]u64 = undefined;
    inline for (.{ Unbounded, Bounded }, 0..) |VmType, index| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);

        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 9), std.mem.readInt(u256, result.output[0..32], .big));
        gas_left[index] = result.gas_left;

        if (VmType == Unbounded) {
            try std.testing.expectEqual(@as(usize, 10), vm.tracer.steps.items.len);
            try std.testing.expectEqual(@as(usize, 10), vm.tracer.advanced_steps.items.len);
            try std.testing.expect(!vm.tracer.isTruncated());
            try std.testing.expectEqual(evm.TracerConfig.TruncationReason.none, vm.tracer.truncationReason());
        } else {
            try std.testing.expectEqual(@as(usize, 3), vm.tracer.steps.items.len);
            try std.testing.expect(vm.tracer.advanced_steps.items.len <= 3);
            try std.testing.expect(vm.tracer.isTruncated());
            try std.testing.expectEqual(evm.TracerConfig.TruncationReason.max_steps, vm.tracer.truncationReason());
            // The captured prefix is intact.
            try std.testing.expectEqual(@as(u8, 0x60), vm.tracer.steps.items[0].opcode);
            try std.testing.expectEqual(@as(u8, 0x01), vm.tracer.steps.items[2].opcode);
            // Clearing the trace clears the truncation status with it.
            vm.tracer.clearSteps();
            try std.testing.expect(!vm.tracer.isTruncated());
            try std.testing.expectEqual(evm.TracerConfig.TruncationReason.none, vm.tracer.truncationReason());
        }
    }
    try std.testing.expectEqual(gas_left[0], gas_left[1]);
}

test "W3-15: max_bytes bounds retained trace data and leaves the execution result unchanged" {
    const allocator = std.testing.allocator;
    const step_size = @sizeOf(evm.Tracer.ExecutionStep);
    const Bounded = evm.Evm(.{
        .enable_fusion = false,
        // Room for two steps with empty stacks and a third with one word, not more.
        .tracer_config = .{ .enabled = true, .enable_step_capture = true, .max_bytes = 3 * step_size + 32 },
    });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAC)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBC)) };
    // PUSH0; POP; PUSH1 1; PUSH1 2; ADD; PUSH0; MSTORE; RETURN(0, 32)
    const code = [_]u8{ 0x5F, 0x50, 0x60, 0x01, 0x60, 0x02, 0x01, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.code_hash = try db.set_code(&code);
    try db.set_account(target.bytes, contract);

    var vm = try Bounded.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(u256, 3), std.mem.readInt(u256, result.output[0..32], .big));
    // PUSH0 (empty stack), POP (one word), PUSH1 (empty stack) fit; the fourth step,
    // with one word on the stack, would exceed the budget.
    try std.testing.expectEqual(@as(usize, 3), vm.tracer.steps.items.len);
    try std.testing.expect(vm.tracer.captured_bytes <= 3 * step_size + 32);
    try std.testing.expect(vm.tracer.isTruncated());
    try std.testing.expectEqual(evm.TracerConfig.TruncationReason.max_bytes, vm.tracer.truncationReason());
}

test "W3-15: an allocation failure during capture marks the trace truncated and leaks nothing" {
    const allocator = std.testing.allocator;
    const Capturing = evm.Evm(.{
        .enable_fusion = false,
        .tracer_config = .{ .enabled = true, .enable_step_capture = true, .enable_advanced_trace = true },
    });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAD)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBD)) };
    const code = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x60, 0x03, 0x02, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };

    var fail_index: usize = 0;
    var truncated_runs: usize = 0;
    while (fail_index < 64) : (fail_index += 1) {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);

        var vm = try Capturing.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        vm.tracer.allocator = failing.allocator();
        defer vm.tracer.allocator = allocator;

        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);

        // Whatever the tracer lost, the execution result is the same.
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 9), std.mem.readInt(u256, result.output[0..32], .big));
        if (!failing.has_induced_failure) {
            try std.testing.expect(!vm.tracer.isTruncated());
            break;
        }
        try std.testing.expect(vm.tracer.isTruncated());
        try std.testing.expectEqual(evm.TracerConfig.TruncationReason.out_of_memory, vm.tracer.truncationReason());
        try std.testing.expect(vm.tracer.steps.items.len < 10 or vm.tracer.advanced_steps.items.len < 10);
        truncated_runs += 1;
    }
    try std.testing.expect(truncated_runs > 0);
}
