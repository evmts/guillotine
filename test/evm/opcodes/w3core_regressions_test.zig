//! Wave 3 regression tests for the core rules that are not reachable from an
//! inline test of a file `src/root.zig` imports:
//!
//! - W3-7: EIP-7685 request types are unique and strictly ascending.
//! - W3-10: undefined, fork-disabled and withdrawn opcodes end a basic block and
//!   charge nothing; trailing bytes add no gas and no stack requirement.
//! - W3-12: a byte that names no synthetic opcode maps to the invalid handler.
//! - W3-14: `disable_balance_checks` never traps, Petersburg has no EIP-1283,
//!   `Eips.overrides` reach every EIP check, and there is no init code size limit
//!   before Shanghai.
//!
//! Run with `zig build test-opcodes -Dtest-filter='W3-'`.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const Address = primitives.Address;

test "W3-7: computeRequestsHash rejects a duplicate request type" {
    const first = [_]u8{ 0x00, 0xAA };
    const second = [_]u8{ 0x00, 0xBB };
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &first, &second }),
    );

    // The same request twice, and a duplicate that carries no data, are refused too.
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &first, &first }),
    );
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &.{0x01}, &.{0x01} }),
    );
    // A duplicate after a valid prefix, and a duplicate of the highest type.
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &.{ 0x00, 0x01 }, &.{ 0x01, 0x02 }, &.{ 0x01, 0x03 } }),
    );
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &.{ 0xFF, 0x01 }, &.{ 0xFF, 0x02 } }),
    );
}

test "W3-7: computeRequestsHash rejects out-of-order types and accepts strictly ascending ones" {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const deposit = [_]u8{ 0x00, 0xAA, 0xBB };
    const withdrawal = [_]u8{ 0x01, 0xCC };
    const consolidation = [_]u8{ 0x02, 0xDD };

    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &withdrawal, &deposit }),
    );
    try std.testing.expectError(
        error.RequestTypesNotAscending,
        evm.eips.computeRequestsHash(&.{ &deposit, &consolidation, &withdrawal }),
    );

    // Strictly ascending, with a gap: sha256(sha256(deposit) ++ sha256(consolidation)).
    var deposit_digest: [32]u8 = undefined;
    Sha256.hash(&deposit, &deposit_digest, .{});
    var withdrawal_digest: [32]u8 = undefined;
    Sha256.hash(&withdrawal, &withdrawal_digest, .{});
    var consolidation_digest: [32]u8 = undefined;
    Sha256.hash(&consolidation, &consolidation_digest, .{});

    var with_gap: [32]u8 = undefined;
    Sha256.hash(&(deposit_digest ++ consolidation_digest), &with_gap, .{});
    try std.testing.expectEqualSlices(
        u8,
        &with_gap,
        &(try evm.eips.computeRequestsHash(&.{ &deposit, &consolidation })),
    );

    var all_three: [32]u8 = undefined;
    Sha256.hash(&(deposit_digest ++ withdrawal_digest ++ consolidation_digest), &all_three, .{});
    try std.testing.expectEqualSlices(
        u8,
        &all_three,
        &(try evm.eips.computeRequestsHash(&.{ &deposit, &withdrawal, &consolidation })),
    );

    // One request, and the two ends of the type range, are in order.
    _ = try evm.eips.computeRequestsHash(&.{&deposit});
    _ = try evm.eips.computeRequestsHash(&.{ &.{ 0x00, 0x01 }, &.{ 0xFF, 0x01 } });
}

test "W3-10: calculateBlockInfo stops at undefined and withdrawn opcodes" {
    const allocator = std.testing.allocator;
    const Bc = evm.Bytecode(.{ .hardfork = .CANCUN, .fusions_enabled = false });

    // PUSH1 1, alone: 3 gas, no input, one item pushed.
    const prefix = [_]u8{ 0x60, 0x01 };
    var prefix_bytecode = try Bc.init(allocator, &prefix);
    defer prefix_bytecode.deinit();
    const expected = Bc.Iterator.calculateBlockInfo(&prefix_bytecode, 0, 0);
    try std.testing.expectEqual(@as(u32, 3), expected.gas);
    try std.testing.expectEqual(@as(i16, 0), expected.min_stack);
    try std.testing.expectEqual(@as(i16, 1), expected.max_stack);

    // After the halting byte: gas (SLOAD, CALL), stack inputs (seven for CALL) and
    // stack growth (PUSH1 x3) that must not reach the block.
    const dead_tail = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x60, 0x04, 0x01, 0x54, 0xF1, 0x50, 0x50 };
    inline for (.{ 0x0C, 0x0D, 0x21, 0xEF, 0xF6, 0xF7, 0xFE }) |halting| {
        const code = prefix ++ [_]u8{halting} ++ dead_tail;
        var bytecode = try Bc.init(allocator, &code);
        defer bytecode.deinit();
        try std.testing.expectEqual(expected, Bc.Iterator.calculateBlockInfo(&bytecode, 0, 0));
        try std.testing.expect(Bc.Iterator.halts_as_invalid[halting]);

        // A block that starts on the halting byte charges and requires nothing.
        const at_start = [_]u8{halting} ++ dead_tail;
        var start_bytecode = try Bc.init(allocator, &at_start);
        defer start_bytecode.deinit();
        const empty = Bc.Iterator.calculateBlockInfo(&start_bytecode, 0, 0);
        try std.testing.expectEqual(@as(u32, 0), empty.gas);
        try std.testing.expectEqual(@as(i16, 0), empty.min_stack);
        try std.testing.expectEqual(@as(i16, 0), empty.max_stack);
    }

    // A defined opcode in the same place is part of the block.
    const live = prefix ++ [_]u8{0x50} ++ dead_tail; // POP
    var live_bytecode = try Bc.init(allocator, &live);
    defer live_bytecode.deinit();
    try std.testing.expect(Bc.Iterator.calculateBlockInfo(&live_bytecode, 0, 0).gas > expected.gas);
    try std.testing.expect(!Bc.Iterator.halts_as_invalid[0x50]);
}

test "W3-10: calculateBlockInfo stops at an opcode the fork has not introduced" {
    const allocator = std.testing.allocator;
    // PUSH1 1; PUSH0; PUSH1 2; ADD; ADD
    const push0_code = [_]u8{ 0x60, 0x01, 0x5F, 0x60, 0x02, 0x01, 0x01 };
    // PUSH1 1; TLOAD; PUSH1 2; ADD; POP
    const tload_code = [_]u8{ 0x60, 0x01, 0x5C, 0x60, 0x02, 0x01, 0x50 };

    // PUSH0 is undefined on Paris: the block is PUSH1 1 alone.
    const Paris = evm.Bytecode(.{ .hardfork = .MERGE, .fusions_enabled = false });
    var paris = try Paris.init(allocator, &push0_code);
    defer paris.deinit();
    const paris_info = Paris.Iterator.calculateBlockInfo(&paris, 0, 0);
    try std.testing.expectEqual(@as(u32, 3), paris_info.gas);
    try std.testing.expectEqual(@as(i16, 0), paris_info.min_stack);
    try std.testing.expectEqual(@as(i16, 1), paris_info.max_stack);
    try std.testing.expect(Paris.Iterator.halts_as_invalid[0x5F]);

    // From Shanghai PUSH0 is an instruction: 3 + 2 + 3 + 3 + 3 gas, three items at most.
    const Shanghai = evm.Bytecode(.{ .hardfork = .SHANGHAI, .fusions_enabled = false });
    var shanghai = try Shanghai.init(allocator, &push0_code);
    defer shanghai.deinit();
    const shanghai_info = Shanghai.Iterator.calculateBlockInfo(&shanghai, 0, 0);
    try std.testing.expectEqual(@as(u32, 14), shanghai_info.gas);
    try std.testing.expectEqual(@as(i16, 3), shanghai_info.max_stack);
    try std.testing.expect(!Shanghai.Iterator.halts_as_invalid[0x5F]);

    // TLOAD is undefined on Shanghai: the block is PUSH1 1 alone.
    var shanghai_tload = try Shanghai.init(allocator, &tload_code);
    defer shanghai_tload.deinit();
    const shanghai_tload_info = Shanghai.Iterator.calculateBlockInfo(&shanghai_tload, 0, 0);
    try std.testing.expectEqual(@as(u32, 3), shanghai_tload_info.gas);
    try std.testing.expectEqual(@as(i16, 1), shanghai_tload_info.max_stack);
    try std.testing.expect(Shanghai.Iterator.halts_as_invalid[0x5C]);

    // From Cancun TLOAD is an instruction and the rest of the block counts.
    const Cancun = evm.Bytecode(.{ .hardfork = .CANCUN, .fusions_enabled = false });
    var cancun = try Cancun.init(allocator, &tload_code);
    defer cancun.deinit();
    try std.testing.expect(Cancun.Iterator.calculateBlockInfo(&cancun, 0, 0).gas > shanghai_tload_info.gas);
    try std.testing.expect(!Cancun.Iterator.halts_as_invalid[0x5C]);
}

test "W3-10: the withdrawn AUTH and AUTHCALL carry INVALID's table entry and handler" {
    const invalid_info = evm.opcode_data.OPCODE_INFO[0xFE];
    try std.testing.expectEqual(@as(@TypeOf(invalid_info.gas_cost), 0), invalid_info.gas_cost);
    for ([_]u8{ 0xF6, 0xF7 }) |withdrawn| {
        const info = evm.opcode_data.OPCODE_INFO[withdrawn];
        try std.testing.expectEqual(invalid_info.gas_cost, info.gas_cost);
        try std.testing.expectEqual(invalid_info.stack_inputs, info.stack_inputs);
        try std.testing.expectEqual(invalid_info.stack_outputs, info.stack_outputs);
    }

    const FrameType = evm.Evm(.{}).Frame;
    const invalid = evm.frame_handlers.invalidHandler(FrameType);
    for ([_]u8{ 0x0C, 0xEF, 0xF6, 0xF7, 0xFE }) |opcode| {
        try std.testing.expectEqual(invalid, FrameType.opcode_handlers[opcode]);
    }
}

test "W3-10: a traced run that reaches an undefined opcode halts there without a tracer divergence" {
    const allocator = std.testing.allocator;
    const validating: evm.TracerConfig = .{ .enabled = true, .enable_validation = true };
    const Traced = evm.Evm(.{ .enable_fusion = false, .tracer_config = validating });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };

    // PUSH1 1; POP; <halting byte>; then bytes that are never reached. The first
    // block is PUSH1 and POP alone: the dead tail (ADD on an empty stack, SLOAD,
    // CALL) adds no gas and no stack requirement to it.
    inline for (.{ 0x0C, 0xEF, 0xF6, 0xF7 }, 0..) |halting, index| {
        const target = Address{ .bytes = @as([20]u8, @splat(0xB0 + index)) };
        const code = [_]u8{ 0x60, 0x01, 0x50, halting, 0x01, 0x01, 0x54, 0xF1 };

        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, contract);

        var vm = try Traced.init(
            allocator,
            &db,
            evm.BlockInfo.init(),
            .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            origin,
        );
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);

        // The undefined opcode halts the frame and consumes all of its gas.
        try std.testing.expect(!result.success);
        try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        try std.testing.expectEqual(@as(u64, 0), vm.tracer.failed_checks);
    }
}

test "W3-12: a byte that names no synthetic opcode maps to the invalid handler" {
    const FrameType = evm.Evm(.{}).Frame;
    const Synthetic = evm.OpcodeSynthetic.OpcodeSynthetic;
    const invalid = evm.frame_handlers.invalidHandler(FrameType);

    try std.testing.expectEqual(invalid, evm.frame_handlers.getSyntheticHandlerForByte(FrameType, 0xFF));
    try std.testing.expectEqual(invalid, evm.frame_handlers.getSyntheticHandlerForByte(FrameType, 0x00));

    var byte: u16 = 0;
    while (byte <= 0xFF) : (byte += 1) {
        const handler = evm.frame_handlers.getSyntheticHandlerForByte(FrameType, @intCast(byte));
        if (std.enums.fromInt(Synthetic, @as(u8, @intCast(byte))) == null) {
            try std.testing.expectEqual(invalid, handler);
        }
    }

    // Every synthetic opcode resolves to the handler its tag names.
    inline for (comptime std.meta.tags(Synthetic)) |tag| {
        try std.testing.expectEqual(
            evm.frame_handlers.getSyntheticHandler(FrameType, tag),
            evm.frame_handlers.getSyntheticHandlerForByte(FrameType, @backingInt(tag)),
        );
    }
}

test "W3-14: an underfunded transfer with balance checks disabled saturates instead of trapping" {
    const allocator = std.testing.allocator;
    const Unchecked = evm.Evm(.{ .disable_balance_checks = true });
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA4)) };
    const caller_contract = Address{ .bytes = @as([20]u8, @splat(0xB4)) };
    const recipient = Address{ .bytes = @as([20]u8, @splat(0xC4)) };

    // CALL(gas, recipient, value = 5, no input, no output); return the success flag.
    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, // retSize retOffset argsSize argsOffset
        0x60, 0x05, // value
        0x73,
    } ++ recipient.bytes ++ [_]u8{
        0x5A, // GAS
        0xF1, // CALL
        0x60, 0x00, 0x52, // MSTORE(0, success)
        0x60, 0x20, 0x60, 0x00, 0xF3, // RETURN(0, 32)
    };

    var db = evm.Database.init(allocator);
    defer db.deinit();
    var contract = evm.Account.zero();
    contract.balance = 2; // less than the 5 it sends
    contract.code_hash = try db.set_code(&code);
    try db.set_account(caller_contract.bytes, contract);

    var vm = try Unchecked.init(
        allocator,
        &db,
        evm.BlockInfo.init(),
        .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
        0,
        origin,
    );
    defer vm.deinit();
    var result = vm.call(.{ .call = .{ .caller = origin, .to = caller_contract, .value = 0, .input = &.{}, .gas = 200_000 } });
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 32), result.output.len);
    try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, result.output[0..32], .big));
    // The sender is debited down to zero, never below; the recipient gets the value.
    try std.testing.expectEqual(@as(u256, 0), (try db.get_account(caller_contract.bytes)).?.balance);
    try std.testing.expectEqual(@as(u256, 5), (try db.get_account(recipient.bytes)).?.balance);

    // A transaction whose own value exceeds the origin's balance: same rule.
    const payee = Address{ .bytes = @as([20]u8, @splat(0xD4)) };
    var top_level = vm.call(.{ .call = .{ .caller = origin, .to = payee, .value = 1000, .input = &.{}, .gas = 100_000 } });
    defer top_level.deinit(allocator);
    try std.testing.expect(top_level.success);
    try std.testing.expectEqual(@as(u256, 1000), (try db.get_account(payee.bytes)).?.balance);
    if (try db.get_account(origin.bytes)) |origin_account| {
        try std.testing.expectEqual(@as(u256, 0), origin_account.balance);
    }
}

test "W3-14: CREATE with an endowment the creator cannot fund honors disable_balance_checks" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA5)) };
    const factory = Address{ .bytes = @as([20]u8, @splat(0xB5)) };

    // CREATE(value = 7, empty init code); return the created address.
    const code = [_]u8{
        0x60, 0x00, 0x60, 0x00, 0x60, 0x07, 0xF0, // size offset value CREATE
        0x60, 0x00, 0x52, // MSTORE(0, address)
        0x60, 0x20, 0x60, 0x00, 0xF3, // RETURN(0, 32)
    };

    const Checked = evm.Evm(.{});
    const Unchecked = evm.Evm(.{ .disable_balance_checks = true });
    inline for (.{ Checked, Unchecked }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var contract = evm.Account.zero();
        contract.nonce = 1;
        contract.balance = 3; // less than the endowment of 7
        contract.code_hash = try db.set_code(&code);
        try db.set_account(factory.bytes, contract);

        var vm = try VmType.init(
            allocator,
            &db,
            evm.BlockInfo.init(),
            .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            origin,
        );
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = factory, .value = 0, .input = &.{}, .gas = 500_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 32), result.output.len);
        const created_word = std.mem.readInt(u256, result.output[0..32], .big);
        const factory_after = (try db.get_account(factory.bytes)).?;

        if (VmType == Checked) {
            // The creation fails before it touches state: zero on the stack, the
            // nonce and the balance as they were.
            try std.testing.expectEqual(@as(u256, 0), created_word);
            try std.testing.expectEqual(@as(u64, 1), factory_after.nonce);
            try std.testing.expectEqual(@as(u256, 3), factory_after.balance);
        } else {
            // The balance condition is waived: the creation goes ahead, the creator
            // is debited down to zero and the new account holds the endowment.
            try std.testing.expect(created_word != 0);
            try std.testing.expectEqual(@as(u64, 2), factory_after.nonce);
            try std.testing.expectEqual(@as(u256, 0), factory_after.balance);
            const created = try Address.getContractAddress(allocator, factory, 1);
            try std.testing.expectEqual(@as(u256, 7), (try db.get_account(created.bytes)).?.balance);
        }
    }
}

test "W3-14: Petersburg and every later fork have EIP-1283 disabled" {
    try std.testing.expect((evm.Eips{ .hardfork = .CONSTANTINOPLE }).is_eip_active(1283));
    try std.testing.expect(!(evm.Eips{ .hardfork = .BYZANTIUM }).is_eip_active(1283));

    inline for (comptime std.meta.tags(evm.Hardfork)) |fork| {
        if (comptime fork.isAtLeast(.PETERSBURG)) {
            const rules = evm.Eips{ .hardfork = fork };
            try std.testing.expect(!rules.is_eip_active(1283));
            try std.testing.expect(std.mem.indexOfScalar(u16, rules.get_active_eips(), 1283) == null);
        }
    }

    // Net gas metering returns with EIP-2200 in Istanbul, under its own number.
    try std.testing.expect(!(evm.Eips{ .hardfork = .PETERSBURG }).is_eip_active(2200));
    try std.testing.expect((evm.Eips{ .hardfork = .ISTANBUL }).is_eip_active(2200));

    // An SSTORE that leaves the slot unchanged: 200 gas under net metering
    // (Constantinople), the flat 5000 reset price on Petersburg.
    const constantinople = (evm.Eips{ .hardfork = .CONSTANTINOPLE }).sstore_gas_cost(1, 1, 1, false);
    const petersburg = (evm.Eips{ .hardfork = .PETERSBURG }).sstore_gas_cost(1, 1, 1, false);
    try std.testing.expectEqual(@as(u64, 200), constantinople.gas);
    try std.testing.expectEqual(@as(u64, 5000), petersburg.gas);
}

test "W3-14: Eips.overrides reach every EIP helper" {
    // EIP-2929 access costs switched on before Berlin.
    const istanbul_2929 = evm.Eips{ .hardfork = .ISTANBUL, .overrides = &.{.{ .eip = 2929, .enabled = true }} };
    try std.testing.expectEqual(@as(u64, 2100), istanbul_2929.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 100), istanbul_2929.eip_2929_warm_storage_read_cost());
    try std.testing.expectEqual(@as(u64, 2600), istanbul_2929.eip_2929_cold_account_access_cost());
    try std.testing.expectEqual(@as(u64, 100), istanbul_2929.eip_2929_warm_account_access_cost());
    const istanbul = evm.Eips{ .hardfork = .ISTANBUL };
    try std.testing.expectEqual(@as(u64, 200), istanbul.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 700), istanbul.eip_2929_cold_account_access_cost());

    // EIP-2929 switched off on Berlin.
    const berlin_no_2929 = evm.Eips{ .hardfork = .BERLIN, .overrides = &.{.{ .eip = 2929, .enabled = false }} };
    try std.testing.expectEqual(@as(u64, 200), berlin_no_2929.eip_2929_cold_sload_cost());
    try std.testing.expectEqual(@as(u64, 700), berlin_no_2929.eip_2929_warm_account_access_cost());

    // EIP-3529 refund cap: one fifth with it, one half without.
    const london = evm.Eips{ .hardfork = .LONDON };
    const london_no_3529 = evm.Eips{ .hardfork = .LONDON, .overrides = &.{.{ .eip = 3529, .enabled = false }} };
    const berlin_3529 = evm.Eips{ .hardfork = .BERLIN, .overrides = &.{.{ .eip = 3529, .enabled = true }} };
    try std.testing.expectEqual(@as(u64, 20), london.eip_3529_gas_refund_cap(100, 100));
    try std.testing.expectEqual(@as(u64, 50), london_no_3529.eip_3529_gas_refund_cap(100, 100));
    try std.testing.expectEqual(@as(u64, 20), berlin_3529.eip_3529_gas_refund_cap(100, 100));

    // EIP-7702 authorization costs and delegation.
    const cancun_7702 = evm.Eips{ .hardfork = .CANCUN, .overrides = &.{.{ .eip = 7702, .enabled = true }} };
    const prague_no_7702 = evm.Eips{ .hardfork = .PRAGUE, .overrides = &.{.{ .eip = 7702, .enabled = false }} };
    try std.testing.expectEqual(@as(i64, 12500), cancun_7702.eip_7702_per_auth_base_cost());
    try std.testing.expectEqual(@as(i64, 25000), cancun_7702.eip_7702_per_empty_account_cost());
    try std.testing.expectEqual(@as(i64, 0), prague_no_7702.eip_7702_per_auth_base_cost());
    try std.testing.expectEqual(@as(i64, 0), prague_no_7702.eip_7702_per_empty_account_cost());

    const authority = Address{ .bytes = @as([20]u8, @splat(0x11)) };
    const delegate = Address{ .bytes = @as([20]u8, @splat(0x22)) };
    var delegated = evm.Account.zero();
    delegated.delegated_address = delegate;
    try std.testing.expectEqualSlices(
        u8,
        &delegate.bytes,
        &cancun_7702.eip_7702_get_effective_code_address(delegated, authority).bytes,
    );
    try std.testing.expectEqualSlices(
        u8,
        &authority.bytes,
        &prague_no_7702.eip_7702_get_effective_code_address(delegated, authority).bytes,
    );

    // System contract addresses follow their EIPs.
    const shanghai_4788 = evm.Eips{ .hardfork = .SHANGHAI, .overrides = &.{.{ .eip = 4788, .enabled = true }} };
    const cancun_no_4788 = evm.Eips{ .hardfork = .CANCUN, .overrides = &.{.{ .eip = 4788, .enabled = false }} };
    try std.testing.expect(shanghai_4788.eip_4788_is_beacon_roots_address(evm.beacon_roots.BEACON_ROOTS_ADDRESS));
    try std.testing.expect(!cancun_no_4788.eip_4788_is_beacon_roots_address(evm.beacon_roots.BEACON_ROOTS_ADDRESS));
    const cancun_2935 = evm.Eips{ .hardfork = .CANCUN, .overrides = &.{.{ .eip = 2935, .enabled = true }} };
    const history = evm.historical_block_hashes.HISTORY_CONTRACT_ADDRESS;
    try std.testing.expect(cancun_2935.eip_2935_is_historical_block_hashes_address(history));
    try std.testing.expect(!(evm.Eips{ .hardfork = .CANCUN }).eip_2935_is_historical_block_hashes_address(history));
}

test "W3-14: an EIP-6780 override decides SELFDESTRUCT in the EVM" {
    const allocator = std.testing.allocator;
    const Cancun = evm.Evm(.{ .eips = .{ .hardfork = .CANCUN } });
    const CancunWithout6780 = evm.Evm(.{ .eips = .{
        .hardfork = .CANCUN,
        .overrides = &.{.{ .eip = 6780, .enabled = false }},
    } });

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA6)) };
    const doomed = Address{ .bytes = @as([20]u8, @splat(0xB6)) };
    const beneficiary = Address{ .bytes = @as([20]u8, @splat(0xC6)) };
    // SELFDESTRUCT(beneficiary)
    const code = [_]u8{0x73} ++ beneficiary.bytes ++ [_]u8{0xFF};

    inline for (.{ Cancun, CancunWithout6780 }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var account = evm.Account.zero();
        account.balance = 9;
        account.code_hash = try db.set_code(&code);
        try db.set_account(doomed.bytes, account);
        try db.set_storage(doomed.bytes, 1, 11);

        var vm = try VmType.init(
            allocator,
            &db,
            evm.BlockInfo.init(),
            .{ .gas_limit = 100_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 },
            0,
            origin,
        );
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = doomed, .value = 0, .input = &.{}, .gas = 100_000 } });
        defer result.deinit(allocator);

        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(u256, 9), (try db.get_account(beneficiary.bytes)).?.balance);
        if (VmType == Cancun) {
            // EIP-6780: a contract that existed before the transaction only pays out.
            try std.testing.expect(db.account_exists(doomed.bytes));
            try std.testing.expectEqual(@as(u256, 11), try db.get_storage(doomed.bytes, 1));
        } else {
            // With EIP-6780 switched off the account is destroyed, as before Cancun.
            try std.testing.expect(!db.account_exists(doomed.bytes));
            try std.testing.expectEqual(@as(u256, 0), try db.get_storage(doomed.bytes, 1));
        }
    }
}

test "W3-14: there is no init code size limit before Shanghai" {
    inline for (.{ .FRONTIER, .SPURIOUS_DRAGON, .LONDON, .MERGE }) |fork| {
        const rules = evm.Eips{ .hardfork = fork };
        try std.testing.expectEqual(@as(?u64, null), rules.size_limit());
    }
    inline for (.{ .SHANGHAI, .CANCUN, .PRAGUE, .OSAKA }) |fork| {
        const rules = evm.Eips{ .hardfork = fork };
        try std.testing.expectEqual(@as(?u64, 0xC000), rules.size_limit());
        // Twice the EIP-170 limit on deployed code, which is a different rule.
        try std.testing.expectEqual(@as(u64, rules.eip_170_max_code_size()) * 2, rules.size_limit().?);
    }

    // The limit follows EIP-3860 itself, not the fork name.
    const london_3860 = evm.Eips{ .hardfork = .LONDON, .overrides = &.{.{ .eip = 3860, .enabled = true }} };
    const shanghai_no_3860 = evm.Eips{ .hardfork = .SHANGHAI, .overrides = &.{.{ .eip = 3860, .enabled = false }} };
    try std.testing.expectEqual(@as(?u64, 0xC000), london_3860.size_limit());
    try std.testing.expectEqual(@as(?u64, null), shanghai_no_3860.size_limit());

    // The EIP-170 limit on deployed code is unaffected: none before Spurious Dragon.
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), (evm.Eips{ .hardfork = .HOMESTEAD }).eip_170_max_code_size());
    try std.testing.expectEqual(@as(u32, 0x6000), (evm.Eips{ .hardfork = .LONDON }).eip_170_max_code_size());
}
