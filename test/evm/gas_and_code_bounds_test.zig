//! Bounds that must hold for any input:
//! - dynamic gas: a memory expansion cost of any size, up to the saturated
//!   `maxInt(u64)`, ends in out-of-gas for `i32` and `i64` gas alike, never in a
//!   trap or a wrapped subtraction;
//! - program counters: code up to the fork's real limit is analyzable, including
//!   the 33 bytes of lookahead the analyzer needs;
//! - `pretty_print`: bytecode of any shape and length prints without trapping.

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("voltaire");
const Address = primitives.Address;
const verified_ops = evm.verified_ops;

const sender = Address{ .bytes = [_]u8{0x51} ++ @as([19]u8, @splat(0)) };
const target = Address{ .bytes = [_]u8{0x7A} ++ @as([19]u8, @splat(0)) };
const coinbase = Address{ .bytes = [_]u8{0xC0} ++ @as([19]u8, @splat(0)) };
const zero_hash = @as([32]u8, @splat(0));

test "memory expansion cost above maxInt(i32) is refused for i32 gas and paid exactly for i64 gas" {
    inline for (.{ 32 * 1024 * 1024, 64 * 1024 * 1024 }) |limit| {
        const Memory = evm.Memory(.{ .memory_limit = limit });
        var memory = try Memory.init(testing.allocator);
        defer memory.deinit(testing.allocator);

        // 32 MiB is 2^20 words: 3 * 2^20 + 2^40 / 512 = 2,150,629,376 gas, which is
        // already above maxInt(i32) = 2,147,483,647.
        const cost = memory.get_expansion_cost(limit);
        try testing.expect(cost > std.math.maxInt(i32));
        try testing.expectEqual(@as(u64, if (limit == 32 * 1024 * 1024) 2_150_629_376 else 8_596_226_048), cost);

        // An i32 frame holding all the gas it can hold cannot pay, and is not
        // charged: narrowing the cost first would have trapped or wrapped.
        try testing.expectEqual(@as(?i32, null), verified_ops.chargeGasChecked(i32, std.math.maxInt(i32), cost));
        // An i64 frame with enough gas pays exactly the cost.
        const rich: i64 = std.math.maxInt(i64);
        try testing.expectEqual(@as(?i64, rich - @as(i64, @intCast(cost))), verified_ops.chargeGasChecked(i64, rich, cost));
        // One gas short is refused.
        try testing.expectEqual(@as(?i64, null), verified_ops.chargeGasChecked(i64, @as(i64, @intCast(cost)) - 1, cost));
    }
}

test "a saturated memory expansion cost stays unpayable when other costs are added" {
    const Memory = evm.Memory(.{});
    var memory = try Memory.init(testing.allocator);
    defer memory.deinit(testing.allocator);

    // Sizes whose word count cannot be computed cost maxInt(u64).
    const saturated = memory.get_expansion_cost(std.math.maxInt(usize));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), saturated);

    // Every composite charge of the handlers: expansion plus copy, log data,
    // keccak words, account access and call value costs.
    const extras = [_]u64{ 0, 3, 375, 2_600, 9_000, 25_000, 34_600, std.math.maxInt(u64) };
    for (extras) |extra| {
        const total = verified_ops.saturatingGasSum(saturated, extra);
        try testing.expectEqual(@as(u64, std.math.maxInt(u64)), total);
        try testing.expectEqual(@as(?i32, null), verified_ops.chargeGasChecked(i32, std.math.maxInt(i32), total));
        try testing.expectEqual(@as(?i64, null), verified_ops.chargeGasChecked(i64, std.math.maxInt(i64), total));
    }
}

test "every memory-expanding opcode halts cleanly on an unpayable size, on a 64 MiB memory limit" {
    // A limit above 32 MiB makes expansion costs exceed maxInt(i32), and the
    // operands below reach from "too expensive" to "not addressable at all".
    const Vm = evm.Evm(.{ .memory_limit = 64 * 1024 * 1024 });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const Shape = enum { offset_size, dest_src_len, extcodecopy, call_input, call_output };
    const opcodes = [_]struct { opcode: u8, shape: Shape }{
        .{ .opcode = 0xf3, .shape = .offset_size }, // RETURN
        .{ .opcode = 0xfd, .shape = .offset_size }, // REVERT
        .{ .opcode = 0x20, .shape = .offset_size }, // KECCAK256
        .{ .opcode = 0xa0, .shape = .offset_size }, // LOG0
        .{ .opcode = 0x37, .shape = .dest_src_len }, // CALLDATACOPY
        .{ .opcode = 0x39, .shape = .dest_src_len }, // CODECOPY
        .{ .opcode = 0x3e, .shape = .dest_src_len }, // RETURNDATACOPY
        .{ .opcode = 0x5e, .shape = .dest_src_len }, // MCOPY
        .{ .opcode = 0x3c, .shape = .extcodecopy }, // EXTCODECOPY
        .{ .opcode = 0xf1, .shape = .call_input }, // CALL
        .{ .opcode = 0xf1, .shape = .call_output },
        .{ .opcode = 0xf2, .shape = .call_input }, // CALLCODE
        .{ .opcode = 0xf4, .shape = .call_input }, // DELEGATECALL
        .{ .opcode = 0xfa, .shape = .call_output }, // STATICCALL
    };
    const sizes = [_]u256{
        48 * 1024 * 1024, // inside the limit, about 4.8 billion gas
        64 * 1024 * 1024, // exactly the limit, about 8.6 billion gas
        64 * 1024 * 1024 + 1, // one byte past the limit
        std.math.maxInt(u32),
        @as(u256, std.math.maxInt(u32)) + 1,
        std.math.maxInt(u64),
        @as(u256, 1) << 255,
        std.math.maxInt(u256),
    };
    for (opcodes) |op| {
        for (sizes) |size| {
            var code: [160]u8 = undefined;
            var len: usize = 0;
            // PUSH32 size.
            var size_push: [33]u8 = undefined;
            size_push[0] = 0x7f;
            std.mem.writeInt(u256, size_push[1..33], size, .big);
            const zero = [_]u8{ 0x60, 0x00 };
            const parts: []const []const u8 = switch (op.shape) {
                // size, offset
                .offset_size => &.{ &size_push, &zero },
                // len, src, dest
                .dest_src_len => &.{ &size_push, &zero, &zero },
                // len, src, dest, address
                .extcodecopy => &.{ &size_push, &zero, &zero, &zero },
                // out size, out offset, in size, in offset, [value], address, gas
                .call_input => if (op.opcode == 0xf4) &.{ &zero, &zero, &size_push, &zero, &zero, &zero } else &.{ &zero, &zero, &size_push, &zero, &zero, &zero, &zero },
                .call_output => if (op.opcode == 0xfa) &.{ &size_push, &zero, &zero, &zero, &zero, &zero } else &.{ &size_push, &zero, &zero, &zero, &zero, &zero, &zero },
            };
            for (parts) |part| {
                @memcpy(code[len..][0..part.len], part);
                len += part.len;
            }
            code[len] = op.opcode;
            code[len + 1] = 0x00;
            len += 2;

            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            try db.set_account(target.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(code[0..len]), .storage_root = zero_hash });

            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 10_000_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = 10_000_000 } });
            defer result.deinit(testing.allocator);

            // An exceptional halt of the frame: the transaction is included, uses
            // all of its gas and is not a host failure.
            try testing.expect(!result.success);
            try testing.expect(!result.reverted);
            try testing.expectEqual(@as(u64, 0), result.gas_left);
            try testing.expectEqual(@as(?[]const u8, null), result.error_info);
            try testing.expectEqual(@as(?anyerror, null), vm.host_failure);
            try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        }
    }
}

test "memory-expanding opcodes still charge exactly what they should when the frame can pay" {
    // CALLDATACOPY(0, 0, 0x8000) then RETURN(0, 0x20): 32 KiB is 1024 words.
    // Expansion 3 * 1024 + 1024^2 / 512 = 5120, copy 3 * 1024 = 3072, static
    // 3 + 3 + 3 + 3 (CALLDATACOPY) + 3 + 3 (RETURN is free) = 18.
    const code = [_]u8{ 0x61, 0x80, 0x00, 0x60, 0x00, 0x60, 0x00, 0x37, 0x60, 0x20, 0x60, 0x00, 0xf3 };
    const Vm = evm.Evm(.{});
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    const execution_gas: u64 = 5_120 + 3_072 + 18;
    for ([_]u64{ 21_000 + execution_gas - 1, 21_000 + execution_gas }) |gas_limit| {
        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        try db.set_account(target.bytes, .{ .balance = 0, .nonce = 1, .code_hash = try db.set_code(&code), .storage_root = zero_hash });
        var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = gas_limit, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = sender, .to = target, .value = 0, .input = &.{}, .gas = gas_limit } });
        defer result.deinit(testing.allocator);
        // One gas short halts; the exact amount succeeds with nothing left.
        try testing.expectEqual(gas_limit == 21_000 + execution_gas, result.success);
        try testing.expectEqual(@as(u64, 0), result.gas_left);
    }
}

test "PcType leaves 33 bytes of headroom and is u32 before Shanghai" {
    // Twelve sizes on seven forks, each a comptime fork comparison.
    @setEvalBranchQuota(50_000);
    const Case = struct { size: u32, expected: type };
    inline for (.{
        Case{ .size = 1, .expected = u8 },
        Case{ .size = 222, .expected = u8 },
        Case{ .size = 223, .expected = u12 },
        Case{ .size = 255, .expected = u12 },
        Case{ .size = 4062, .expected = u12 },
        Case{ .size = 4063, .expected = u16 },
        Case{ .size = 49152, .expected = u16 },
        Case{ .size = 65502, .expected = u16 },
        Case{ .size = 65503, .expected = u32 },
        Case{ .size = 65535, .expected = u32 },
        Case{ .size = 65536, .expected = u32 },
        Case{ .size = std.math.maxInt(u32), .expected = u32 },
    }) |case| {
        // Shanghai and later: init code is capped, so the configured sizes bound the code.
        inline for (.{ evm.Hardfork.SHANGHAI, evm.Hardfork.CANCUN, evm.Hardfork.OSAKA }) |hardfork| {
            const config = comptime evm.BytecodeConfig{ .hardfork = hardfork, .max_bytecode_size = case.size, .max_initcode_size = case.size };
            try testing.expectEqual(case.expected, config.PcType());
            // Whatever the type, it holds the largest code plus the lookahead.
            try testing.expect(@as(u64, case.size) + 33 <= std.math.maxInt(config.PcType()) or config.PcType() == u32);
        }
        // Before Shanghai init code has no size limit: always u32.
        inline for (.{ evm.Hardfork.FRONTIER, evm.Hardfork.SPURIOUS_DRAGON, evm.Hardfork.LONDON, evm.Hardfork.MERGE }) |hardfork| {
            const config = comptime evm.BytecodeConfig{ .hardfork = hardfork, .max_bytecode_size = case.size, .max_initcode_size = case.size };
            try testing.expectEqual(u32, config.PcType());
        }
    }
    // The frame uses the analyzer's type on every fork.
    try testing.expectEqual(u16, evm.Evm(.{}).Frame.PcType);
    try testing.expectEqual(u32, evm.Evm(.{ .eips = .{ .hardfork = .LONDON } }).Frame.PcType);
    try testing.expectEqual(u32, evm.Evm(.{ .eips = .{ .hardfork = .LONDON } }).Bytecode.PcType);
}

test "Bytecode.init accepts code up to maxInt(PcType) - 33 and rejects one byte more" {
    // u8 program counter: 222 bytes fit, 223 do not.
    {
        const Small = evm.Bytecode(.{ .max_bytecode_size = 222, .max_initcode_size = 222 });
        try testing.expectEqual(u8, Small.PcType);
        const code = @as([223]u8, @splat(0x5b));
        var fits = try Small.init(testing.allocator, code[0..222]);
        fits.deinit();
        try testing.expectError(error.InitcodeTooLarge, Small.init(testing.allocator, code[0..223]));
    }
    // u16 program counter (the default, Cancun): 65502 bytes fit, 65503 do not.
    {
        const Default = evm.Bytecode(.{});
        try testing.expectEqual(u16, Default.PcType);
        const code = try testing.allocator.alloc(u8, 65_503);
        defer testing.allocator.free(code);
        @memset(code, 0x5b);
        var fits = try Default.init(testing.allocator, code[0..65_502]);
        fits.deinit();
        try testing.expectError(error.InitcodeTooLarge, Default.init(testing.allocator, code));
    }
    // Before Shanghai the same 65503 bytes, and far more, are analyzable.
    {
        const London = evm.Bytecode(.{ .hardfork = .LONDON });
        const code = try testing.allocator.alloc(u8, 200_000);
        defer testing.allocator.free(code);
        @memset(code, 0x5b);
        for ([_]usize{ 65_502, 65_503, 65_535, 65_536, 200_000 }) |len| {
            var bytecode = try London.init(testing.allocator, code[0..len]);
            defer bytecode.deinit();
            try testing.expectEqual(len, @as(usize, bytecode.len()));
        }
    }
}

test "a creation transaction with 65,503 bytes of init code runs before Shanghai" {
    // 65,503 bytes is the first size a 16-bit program counter cannot analyze.
    // JUMPDEST ... JUMPDEST STOP: the init code runs to its last byte.
    const sizes = [_]usize{ 65_502, 65_503, 65_536, 100_000 };
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 1, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    inline for (.{ evm.Hardfork.FRONTIER, evm.Hardfork.SPURIOUS_DRAGON, evm.Hardfork.LONDON }) |hardfork| {
        const Vm = evm.Evm(.{ .eips = .{ .hardfork = hardfork } });
        const eips = evm.Eips{ .hardfork = hardfork };
        for (sizes) |size| {
            const init_code = try testing.allocator.alloc(u8, size);
            defer testing.allocator.free(init_code);
            @memset(init_code, 0x5b);
            init_code[size - 1] = 0x00;

            var db = evm.Database.init(testing.allocator);
            defer db.deinit();
            try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
            var vm = try Vm.init(testing.allocator, &db, block, .{ .gas_limit = 20_000_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
            defer vm.deinit();
            var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = init_code, .gas = 20_000_000 } });
            defer result.deinit(testing.allocator);

            try testing.expect(result.success);
            try testing.expectEqual(@as(?[]const u8, null), result.error_info);
            try testing.expect(result.created_address != null);
            // Intrinsic gas, plus one gas for each JUMPDEST executed.
            const intrinsic = eips.intrinsic_gas_cost(true) + eips.calldata_gas_cost(eips.tokens_in_calldata(init_code), true, init_code.len);
            try testing.expectEqual(@as(u64, 20_000_000) - intrinsic - (size - 1), result.gas_left);
        }
    }
}

test "Shanghai rejects a creation transaction above 49,152 bytes of init code and runs one at the limit" {
    const Shanghai = evm.Evm(.{ .eips = .{ .hardfork = .SHANGHAI } });
    const block = evm.BlockInfo{ .chain_id = 1, .number = 1, .timestamp = 1, .difficulty = 0, .gas_limit = 30_000_000, .coinbase = coinbase, .base_fee = 0, .prev_randao = zero_hash };
    for ([_]usize{ 49_152, 49_153, 65_503 }) |size| {
        const init_code = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(init_code);
        @memset(init_code, 0x5b);
        init_code[size - 1] = 0x00;

        var db = evm.Database.init(testing.allocator);
        defer db.deinit();
        try db.set_account(sender.bytes, .{ .balance = 1_000_000, .nonce = 0, .code_hash = zero_hash, .storage_root = zero_hash });
        var vm = try Shanghai.init(testing.allocator, &db, block, .{ .gas_limit = 20_000_000, .coinbase = coinbase, .chain_id = 1 }, 0, sender);
        defer vm.deinit();
        var result = vm.call(.{ .create = .{ .caller = sender, .value = 0, .init_code = init_code, .gas = 20_000_000 } });
        defer result.deinit(testing.allocator);

        if (size <= 49_152) {
            try testing.expect(result.success);
            try testing.expectEqual(@as(u64, 1), try db.get_nonce(sender.bytes));
        } else {
            try testing.expect(!result.success);
            try testing.expect(std.mem.indexOf(u8, result.error_info.?, "EIP-3860") != null);
            try testing.expectEqual(@as(u64, 0), try db.get_nonce(sender.bytes));
        }
    }
}

test "pretty_print saturates the stack requirement of a block of 10,923 LOG4" {
    // 10,923 * 6 = 65,538 stack items: one more block than a u16 can count.
    const Default = evm.Bytecode(.{});
    inline for (.{ 10_922, 10_923, 20_000, 65_502 }) |count| {
        const code = try testing.allocator.alloc(u8, count);
        defer testing.allocator.free(code);
        @memset(code, 0xa4);
        var bytecode = try Default.init(testing.allocator, code);
        defer bytecode.deinit();
        const text = try bytecode.pretty_print(testing.allocator);
        defer testing.allocator.free(text);
        try testing.expect(text.len > 0);
        // 10,922 * 6 = 65,532 still fits; everything above prints the clamp.
        const expected = if (count == 10_922) "stack: [65532, 0]" else "stack: [65535, 0]";
        try testing.expect(std.mem.indexOf(u8, text, expected) != null);
    }
}

test "pretty_print handles 100,000 LOG4 and other degenerate bytecode on a 32-bit program counter" {
    const Wide = evm.Bytecode(.{ .max_bytecode_size = 1 << 20, .max_initcode_size = 1 << 20 });
    try testing.expectEqual(u32, Wide.PcType);
    // LOG4 pops 6; DUP1 pushes 1; PUSH32 without its immediate; INVALID ends a block each.
    for ([_]u8{ 0xa4, 0x80, 0x7f, 0xfe }) |fill| {
        const code = try testing.allocator.alloc(u8, 100_000);
        defer testing.allocator.free(code);
        @memset(code, fill);
        var bytecode = Wide.init(testing.allocator, code) catch |err| {
            // Validation may refuse the code (a truncated PUSH32); it must not trap.
            try testing.expect(err != error.OutOfMemory);
            continue;
        };
        defer bytecode.deinit();
        const text = try bytecode.pretty_print(testing.allocator);
        defer testing.allocator.free(text);
        try testing.expect(text.len > 0);
        if (fill == 0xa4) try testing.expect(std.mem.indexOf(u8, text, "stack: [65535, 0]") != null);
        // The opcode table models DUP1 as a plain push (0 in, 1 out).
        if (fill == 0x80) try testing.expect(std.mem.indexOf(u8, text, "stack: [0, 65535]") != null);
    }
}
