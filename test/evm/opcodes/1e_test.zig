const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

test "CLZ opcode Osaka values, gas and Prague rejection" {
    const allocator = std.testing.allocator;
    inline for (.{ evm.Hardfork.PRAGUE, evm.Hardfork.OSAKA }) |fork| {
        inline for (.{ false, true }) |fusion| {
            const Engine = evm.Evm(.{ .eips = .{ .hardfork = fork }, .enable_fusion = fusion });
            try std.testing.expectEqual(fork, Engine.Frame.config.hardfork);
            for (0..257) |leading| {
                var database = evm.Database.init(allocator);
                defer database.deinit();
                const caller = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 19 };
                const contract = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 19 };
                // PUSH32 word; CLZ; MSTORE(0); RETURN(0,32). The word is pushed
                // rather than read from calldata so EIP-7623 calldata floor gas,
                // a transaction-level charge MinimalEvm does not model, stays
                // out of this opcode differential.
                const word: u256 = if (leading == 256) 0 else @as(u256, 1) << @intCast(255 - leading);
                var code_buffer: [42]u8 = undefined;
                code_buffer[0] = 0x7f;
                std.mem.writeInt(u256, code_buffer[1..33], word, .big);
                code_buffer[33..42].* = .{ 0x1e, 0x60, 0, 0x52, 0x60, 0x20, 0x60, 0, 0xf3 };
                const code: []const u8 = &code_buffer;
                const hash = try database.set_code(code);
                try database.set_account(contract.bytes, .{
                    .balance = 0,
                    .nonce = 0,
                    .code_hash = hash,
                    .storage_root = [_]u8{0} ** 32,
                });
                try database.set_account(caller.bytes, .{
                    .balance = 1_000_000,
                    .nonce = 0,
                    .code_hash = [_]u8{0} ** 32,
                    .storage_root = [_]u8{0} ** 32,
                });
                var engine = try Engine.init(allocator, &database, .{
                    .chain_id = 1,
                    .number = 24_000_000,
                    .timestamp = 1_764_798_551,
                    .difficulty = 0,
                    .gas_limit = 60_000_000,
                    .coinbase = primitives.ZERO_ADDRESS,
                    .base_fee = 7,
                    .prev_randao = [_]u8{0} ** 32,
                    .blob_base_fee = 1,
                    .blob_versioned_hashes = &.{},
                }, .{ .gas_limit = 22_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, caller);
                defer engine.deinit();
                var result = engine.call(.{ .call = .{
                    .caller = caller,
                    .to = contract,
                    .value = 0,
                    .input = &.{},
                    .gas = 22_000,
                } });
                defer result.deinit(allocator);
                const reference = try evm.MinimalEvm.initPtr(allocator);
                defer reference.deinitPtr(allocator);
                reference.setHardfork(fork);
                // Both entry points charge 21,000 intrinsic gas, leaving
                // 1,000 gas for execution.
                const reference_result = try reference.execute(code, 22_000, caller, contract, 0, &.{});
                try std.testing.expectEqual(result.success, reference_result.success);
                try std.testing.expectEqual(result.gas_left, reference_result.gas_left);
                try std.testing.expectEqualSlices(u8, result.output, reference_result.output);
                if (fork == .PRAGUE) {
                    try std.testing.expect(!result.success);
                    try std.testing.expectEqual(@as(u64, 0), result.gas_left);
                } else {
                    try std.testing.expect(result.success);
                    var expected: [32]u8 = undefined;
                    std.mem.writeInt(u256, &expected, @intCast(leading), .big);
                    try std.testing.expectEqualSlices(u8, &expected, result.output);
                    // PUSH32 3 + CLZ 5 + PUSH1 3 + MSTORE 3 + memory 3
                    // + PUSH1 3 + PUSH1 3 + RETURN 0 = 23 execution gas.
                    try std.testing.expectEqual(@as(u64, 977), result.gas_left);
                }
            }
        }
    }
}

test "CLZ metadata and fork registry" {
    try std.testing.expectEqual(@as(u8, 0x1e), @intFromEnum(evm.Opcode.CLZ));
    try std.testing.expect(evm.Opcode.CLZ.isBitwise());
    const info = evm.OpcodeData.OPCODE_INFO[0x1e];
    try std.testing.expectEqual(@as(u16, 5), info.gas_cost);
    try std.testing.expectEqual(@as(u4, 1), info.stack_inputs);
    try std.testing.expectEqual(@as(u4, 1), info.stack_outputs);
    const osaka = evm.Eips{ .hardfork = .OSAKA };
    const prague = evm.Eips{ .hardfork = .PRAGUE };
    try std.testing.expect(osaka.is_eip_active(7939));
    try std.testing.expect(!prague.is_eip_active(7939));
}

test "CLZ exact budget, underflow, full stack and static execution" {
    const allocator = std.testing.allocator;
    var full_stack: [3074]u8 = undefined;
    for (0..1024) |i| {
        full_stack[i * 2] = 0x60;
        full_stack[i * 2 + 1] = 0;
    }
    full_stack[2048] = 0x1e;
    @memset(full_stack[2049..3073], 0x50);
    full_stack[3073] = 0;
    const Case = struct { code: []const u8, gas: u64, success: bool, remaining: u64 };
    const cases = [_]Case{
        .{ .code = &.{ 0x1e, 0x00 }, .gas = 21_100, .success = false, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x1e, 0 }, .gas = 21_007, .success = false, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x1e, 0 }, .gas = 21_008, .success = true, .remaining = 0 },
        .{ .code = &full_stack, .gas = 26_125, .success = true, .remaining = 0 },
        // Returning CLZ results exposed omitted expansion charges in fused
        // memory operations. Cover each operation and an already-expanded word.
        .{ .code = &.{ 0x60, 0, 0x51, 0 }, .gas = 21_009, .success = true, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x51, 0 }, .gas = 21_008, .success = false, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x60, 0, 0x52, 0 }, .gas = 21_012, .success = true, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x60, 0, 0x53, 0 }, .gas = 21_012, .success = true, .remaining = 0 },
        .{ .code = &.{ 0x60, 0, 0x51, 0x50, 0x60, 0, 0x51, 0 }, .gas = 21_017, .success = true, .remaining = 0 },
    };
    inline for (.{ false, true }) |fusion| {
        for (cases) |case| {
            for ([_]bool{ false, true }) |is_static| {
                var database = evm.Database.init(allocator);
                defer database.deinit();
                const caller = primitives.Address.fromU256(0x100);
                const contract = primitives.Address.fromU256(0x200);
                const hash = try database.set_code(case.code);
                try database.set_account(contract.bytes, .{
                    .balance = 0,
                    .nonce = 0,
                    .code_hash = hash,
                    .storage_root = [_]u8{0} ** 32,
                });
                var engine = try evm.Evm(.{ .eips = .{ .hardfork = .OSAKA }, .enable_fusion = fusion }).init(allocator, &database, .{
                    .chain_id = 1,
                    .number = 24_000_000,
                    .timestamp = 1_764_798_551,
                    .difficulty = 0,
                    .gas_limit = 60_000_000,
                    .coinbase = primitives.ZERO_ADDRESS,
                    .base_fee = 0,
                    .prev_randao = [_]u8{0} ** 32,
                    .blob_base_fee = 1,
                    .blob_versioned_hashes = &.{},
                }, .{ .gas_limit = case.gas, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, caller);
                defer engine.deinit();
                const params: evm.CallParams = if (is_static)
                    .{ .staticcall = .{ .caller = caller, .to = contract, .input = &.{}, .gas = case.gas } }
                else
                    .{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &.{}, .gas = case.gas } };
                var result = engine.call(params);
                defer result.deinit(allocator);
                if (case.success != result.success or case.remaining != result.gas_left) {
                    std.debug.print("CLZ/memory case: gas={d}, fusion={}, static={}, code={x}\n", .{ case.gas, fusion, is_static, case.code });
                }
                try std.testing.expectEqual(case.success, result.success);
                try std.testing.expectEqual(case.remaining, result.gas_left);
            }
        }
    }
}
