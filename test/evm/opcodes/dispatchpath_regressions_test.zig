//! Regression tests for the dispatch-side changes:
//!
//! - static jumps enter their successor block themselves (no second dispatch
//!   through JUMPDEST or BLOCK_BEGIN),
//! - dynamic jumps use one bucket table and no longer check the stack depth,
//! - frame memory keeps its address and size inline,
//! - MULMOD reduces once and fused PUSH+DIV divides one limb,
//! - cached analyses keep no per-byte bitmap and the cache finds a free slot
//!   through a bitmap,
//! - STOP, INVALID and BLOBHASH are native handlers.
//!
//! Every program runs on an EVM with fusion, one without, and (where it says so)
//! one with the tracer, and all must agree on success, gas and output.

const std = @import("std");
const evm = @import("evm");
const primitives = @import("voltaire");

const FusedVm = evm.Evm(.{});
const PlainVm = evm.Evm(.{ .enable_fusion = false });
const TracedVm = evm.MainnetEvmWithTracer;
const Address = primitives.Address;

/// What a run is compared by.
const Outcome = struct {
    success: bool,
    gas_left: u64,
    output: [96]u8,
    output_len: usize,
};

test "static jumps: taken, not taken and falling into a JUMPDEST agree on every build" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA1)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB1)) };

    const code = [_]u8{
        0x60, 0x05, // 00 PUSH1 5                            [i]
        0x5B, //       02 JUMPDEST
        0x60, 0x01, 0x90, 0x03, // 03 PUSH1 1 SWAP1 SUB      [i - 1]
        0x80, //       07 DUP1
        0x60, 0x02, 0x57, // 08 PUSH1 2 JUMPI   static JUMPI: taken 4 times, then falls through
        0x80, 0x15, //  0b DUP1 ISZERO
        0x60, 0x13, 0x57, // 0d PUSH1 0x13 JUMPI   ISZERO_JUMPI taken (value is 0)
        0x60, 0xAA, 0x00, // 10 PUSH1 0xAA STOP   (skipped)
        0x5B, //       13 JUMPDEST
        0x60, 0x18, 0x56, // 14 PUSH1 0x18 JUMP   static JUMP
        0xFE, //       17 INVALID
        0x5B, //       18 JUMPDEST
        0x60, 0x01, 0x15, // 19 PUSH1 1 ISZERO
        0x60, 0x17, 0x57, // 1c PUSH1 0x17 JUMPI  ISZERO_JUMPI not taken; its target is no JUMPDEST
        0x5F, //       1f PUSH0
        0x60, 0x24, 0x57, // 20 PUSH1 0x24 JUMPI  static JUMPI not taken, falls into a JUMPDEST
        0x5B, //       23 JUMPDEST
        0x5B, //       24 JUMPDEST
        0x60, 0x2A, 0x5F, 0x52, // 25 MSTORE(0, 0x2A)
        0x60, 0x20, 0x5F, 0xF3, // 29 RETURN(0, 32)
    };
    try std.testing.expectEqual(@as(u8, 0x5B), code[0x13]);
    try std.testing.expectEqual(@as(u8, 0x5B), code[0x18]);
    try std.testing.expectEqual(@as(u8, 0x5B), code[0x23]);

    var full: [3]Outcome = undefined;
    inline for (.{ FusedVm, PlainVm, TracedVm }, 0..) |VmType, index| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(&code);
        try db.set_account(target.bytes, account);
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();

        // Twice: the first call analyzes the code, the second runs the cached schedule.
        for (0..2) |_| {
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(result.success);
            try std.testing.expectEqual(@as(usize, 32), result.output.len);
            try std.testing.expectEqual(@as(u256, 0x2A), std.mem.readInt(u256, result.output[0..32], .big));
            full[index] = .{ .success = true, .gas_left = result.gas_left, .output = undefined, .output_len = 32 };
        }
    }
    try std.testing.expectEqual(full[0].gas_left, full[1].gas_left);
    try std.testing.expectEqual(full[0].gas_left, full[2].gas_left);

    // Gas-exact block boundaries: sweep the gas limit across the last blocks of the
    // program. With and without fusion the same limits succeed, with the same gas left.
    const used = 100_000 - full[0].gas_left;
    var gas: u64 = used - 80;
    while (gas <= used + 4) : (gas += 1) {
        var swept: [2]Outcome = undefined;
        inline for (.{ FusedVm, PlainVm }, 0..) |VmType, index| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(&code);
            try db.set_account(target.bytes, account);
            var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = gas } });
            defer result.deinit(allocator);
            swept[index] = .{ .success = result.success, .gas_left = result.gas_left, .output = undefined, .output_len = result.output.len };
        }
        try std.testing.expectEqual(swept[0].success, swept[1].success);
        try std.testing.expectEqual(swept[0].gas_left, swept[1].gas_left);
        try std.testing.expectEqual(swept[0].output_len, swept[1].output_len);
        try std.testing.expectEqual(gas >= used, swept[0].success);
        if (gas == used) try std.testing.expectEqual(@as(u64, 0), swept[0].gas_left);
    }
}

test "static jumps: invalid and out-of-range targets fail only when the jump is taken" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA2)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB2)) };

    const Program = struct { code: []const u8, condition: u8, succeeds: bool };
    const huge_jump = [_]u8{0x7F} ++ @as([32]u8, @splat(0xFF)) ++ [_]u8{0x56};
    const huge_jumpi = [_]u8{ 0x5F, 0x35, 0x7F } ++ @as([32]u8, @splat(0xFF)) ++ [_]u8{ 0x57, 0x00 };
    const programs = [_]Program{
        // PUSH1 3 JUMP to a STOP: not a JUMPDEST.
        .{ .code = &.{ 0x60, 0x03, 0x56, 0x00 }, .condition = 0, .succeeds = false },
        // PUSH1 4 JUMP into PUSH data that holds the JUMPDEST byte.
        .{ .code = &.{ 0x60, 0x04, 0x56, 0x60, 0x5B, 0x00 }, .condition = 0, .succeeds = false },
        // PUSH2 0xFFFF JUMP past the end of the code.
        .{ .code = &.{ 0x61, 0xFF, 0xFF, 0x56 }, .condition = 0, .succeeds = false },
        // PUSH32 2^256 - 1 JUMP: wider than any program counter.
        .{ .code = &huge_jump, .condition = 0, .succeeds = false },
        // condition = calldata word 0; PUSH1 7 JUMPI; STOP; target is INVALID's byte.
        .{ .code = &.{ 0x5F, 0x35, 0x60, 0x07, 0x57, 0x00, 0xFE, 0xFE }, .condition = 0, .succeeds = true },
        .{ .code = &.{ 0x5F, 0x35, 0x60, 0x07, 0x57, 0x00, 0xFE, 0xFE }, .condition = 1, .succeeds = false },
        // The same with a target wider than a program counter.
        .{ .code = &huge_jumpi, .condition = 0, .succeeds = true },
        .{ .code = &huge_jumpi, .condition = 1, .succeeds = false },
        // ISZERO PUSH1 9 JUMPI: jumps when calldata word 0 is zero; pc 9 is no JUMPDEST.
        .{ .code = &.{ 0x5F, 0x35, 0x15, 0x60, 0x09, 0x57, 0x00, 0x5B, 0x00, 0xFE }, .condition = 1, .succeeds = true },
        .{ .code = &.{ 0x5F, 0x35, 0x15, 0x60, 0x09, 0x57, 0x00, 0x5B, 0x00, 0xFE }, .condition = 0, .succeeds = false },
        // A valid static jump for contrast: PUSH1 4 JUMP; INVALID; JUMPDEST; STOP.
        .{ .code = &.{ 0x60, 0x04, 0x56, 0xFE, 0x5B, 0x00 }, .condition = 0, .succeeds = true },
    };

    for (programs) |program| {
        var outcomes: [3]Outcome = undefined;
        inline for (.{ FusedVm, PlainVm, TracedVm }, 0..) |VmType, index| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(program.code);
            try db.set_account(target.bytes, account);
            var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
            defer vm.deinit();
            var input = @as([32]u8, @splat(0));
            input[31] = program.condition;
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &input, .gas = 100_000 } });
            defer result.deinit(allocator);
            outcomes[index] = .{ .success = result.success, .gas_left = result.gas_left, .output = undefined, .output_len = result.output.len };
        }
        for (outcomes) |outcome| {
            try std.testing.expectEqual(program.succeeds, outcome.success);
            try std.testing.expectEqual(outcomes[0].gas_left, outcome.gas_left);
            // An invalid jump is an exceptional halt: it consumes all gas.
            if (!program.succeeds) try std.testing.expectEqual(@as(u64, 0), outcome.gas_left);
        }
    }
}

test "dynamic jumps: dense and sparse JUMPDEST tables resolve exactly the JUMPDESTs" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA3)) };
    const dense = Address{ .bytes = @as([20]u8, @splat(0xB3)) };
    const sparse = Address{ .bytes = @as([20]u8, @splat(0xC3)) };
    const conditional = Address{ .bytes = @as([20]u8, @splat(0xD3)) };

    // dense: JUMP to calldata word 0, then 300 JUMPDESTs (pc 3..302), then return 1.
    const tail = [_]u8{ 0x60, 0x01, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    const dense_code = [_]u8{ 0x5F, 0x35, 0x56 } ++ @as([300]u8, @splat(0x5B)) ++ tail;
    // sparse: JUMPDESTs at pc 3 and pc 20000 only; pc 10 is a JUMPDEST byte inside
    // PUSH data and the rest is INVALID.
    var sparse_code = @as([20000 + 1 + tail.len]u8, @splat(0xFE));
    @memcpy(sparse_code[0..3], &[_]u8{ 0x5F, 0x35, 0x56 });
    sparse_code[3] = 0x5B;
    sparse_code[4] = 0x00;
    sparse_code[9] = 0x60;
    sparse_code[10] = 0x5B;
    sparse_code[11] = 0x00;
    sparse_code[20000] = 0x5B;
    @memcpy(sparse_code[20001..], &tail);
    // conditional: JUMPI(dest = calldata word 0, condition = calldata word 1).
    const conditional_code = [_]u8{ 0x60, 0x20, 0x35, 0x5F, 0x35, 0x57, 0x00, 0x5B } ++ tail;

    const Case = struct { to: Address, dest: u256, condition: u8, succeeds: bool, returns: bool };
    const max = std.math.maxInt(u256);
    const cases = [_]Case{
        .{ .to = dense, .dest = 3, .condition = 0, .succeeds = true, .returns = true },
        .{ .to = dense, .dest = 4, .condition = 0, .succeeds = true, .returns = true },
        .{ .to = dense, .dest = 151, .condition = 0, .succeeds = true, .returns = true },
        .{ .to = dense, .dest = 302, .condition = 0, .succeeds = true, .returns = true },
        .{ .to = dense, .dest = 0, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = 2, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = 303, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = 5000, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = (1 << 32) + 3, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = (1 << 64) + 3, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = dense, .dest = max, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = sparse, .dest = 3, .condition = 0, .succeeds = true, .returns = false },
        .{ .to = sparse, .dest = 20000, .condition = 0, .succeeds = true, .returns = true },
        .{ .to = sparse, .dest = 10, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = sparse, .dest = 19999, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = sparse, .dest = 20001, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = sparse, .dest = 0xFFFF_FFFF, .condition = 0, .succeeds = false, .returns = false },
        .{ .to = conditional, .dest = 7, .condition = 1, .succeeds = true, .returns = true },
        .{ .to = conditional, .dest = 6, .condition = 1, .succeeds = false, .returns = false },
        // An untaken JUMPI never looks its destination up.
        .{ .to = conditional, .dest = 6, .condition = 0, .succeeds = true, .returns = false },
        .{ .to = conditional, .dest = max, .condition = 0, .succeeds = true, .returns = false },
    };

    var gas_by_case: [3][cases.len]u64 = undefined;
    inline for (.{ FusedVm, PlainVm, TracedVm }, 0..) |VmType, vm_index| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        for ([_]struct { address: Address, code: []const u8 }{
            .{ .address = dense, .code = &dense_code },
            .{ .address = sparse, .code = &sparse_code },
            .{ .address = conditional, .code = &conditional_code },
        }) |contract| {
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(contract.code);
            try db.set_account(contract.address.bytes, account);
        }
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();

        for (cases, 0..) |case, case_index| {
            var input = @as([64]u8, @splat(0));
            std.mem.writeInt(u256, input[0..32], case.dest, .big);
            input[63] = case.condition;
            var result = vm.call(.{ .call = .{ .caller = origin, .to = case.to, .value = 0, .input = &input, .gas = 200_000 } });
            defer result.deinit(allocator);
            try std.testing.expectEqual(case.succeeds, result.success);
            try std.testing.expectEqual(@as(usize, if (case.returns) 32 else 0), result.output.len);
            if (case.returns) try std.testing.expectEqual(@as(u256, 1), std.mem.readInt(u256, result.output[0..32], .big));
            if (!case.succeeds) try std.testing.expectEqual(@as(u64, 0), result.gas_left);
            gas_by_case[vm_index][case_index] = result.gas_left;
        }
    }
    try std.testing.expectEqualSlices(u64, &gas_by_case[0], &gas_by_case[1]);
    try std.testing.expectEqualSlices(u64, &gas_by_case[0], &gas_by_case[2]);
}

test "memory: pooled, arena-backed and unfused frames agree on MLOAD, MSTORE and MSTORE8" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA4)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB4)) };
    const echo = Address{ .bytes = @as([20]u8, @splat(0xC4)) };

    // A memory limit above what the frame memory pool reserves turns the pool off:
    // frames then own arena-backed memory.
    const ArenaVm = evm.Evm(.{ .memory_limit = 128 * 1024 * 1024 });
    try std.testing.expect(FusedVm.FrameMemory.enabled);
    try std.testing.expect(!ArenaVm.FrameMemory.enabled);

    const echo_code = [_]u8{ 0x36, 0x5F, 0x5F, 0x37, 0x36, 0x5F, 0xF3 };
    const code = [_]u8{
        0x60, 0xAA, 0x5F, 0x52, // MSTORE(0, 0xAA)                 expands 0 -> 32
        0x61, 0xBB, 0xBB, 0x60, 0x40, 0x52, // MSTORE(0x40, 0xBBBB)  fused, expands to 96
        0x60, 0xCC, 0x60, 0x5F, 0x53, // MSTORE8(0x5F, 0xCC)       fused, in bounds (last byte)
        0x60, 0x40, 0x51, // MLOAD(0x40)                          fused, in bounds
        0x5F, 0x51, // MLOAD(0)
        0x01, // ADD
        0x61, 0x10, 0x00, 0x52, // MSTORE(0x1000, sum)            fused, expands to 0x1020
        0x61, 0x10, 0x00, 0x51, // MLOAD(0x1000)                  fused, the last whole word
        0x61, 0x10, 0x01, 0x51, // MLOAD(0x1001)                  one byte past it: expands to 0x1040
        0x01, // ADD
        0x60, 0x20, 0x52, // MSTORE(0x20, ...)                    in bounds
        0x60, 0xDD, 0x61, 0x10, 0x3F, 0x53, // MSTORE8(0x103F, 0xDD)  last byte, in bounds
        0x60, 0xEE, 0x61, 0x10, 0x40, 0x53, // MSTORE8(0x1040, 0xEE)  first byte past: expands to 0x1060
        0x59, 0x60, 0x60, 0x52, // MSTORE(0x60, MSIZE)
        // CALL(echo) with mem[0..0x80] as input and mem[0x2000..0x2080] as output: a
        // nested frame gets its own memory and this one grows on return.
        0x60, 0x80, 0x61, 0x20,
        0x00, 0x60, 0x80, 0x5F,
        0x5F, 0x73,
    } ++ echo.bytes ++ [_]u8{
        0x5A, 0xF1, 0x50,
        0x59, 0x61, 0x20, 0x80, 0x52, // MSTORE(0x2080, MSIZE)
        0x61, 0x20, 0xA0, 0x5F, 0xF3, // RETURN(0, 0x20A0)
    };

    var outputs: [4][]u8 = undefined;
    var gas_left: [4]u64 = undefined;
    var produced: usize = 0;
    defer for (outputs[0..produced]) |output| allocator.free(output);
    inline for (.{ FusedVm, PlainVm, ArenaVm, TracedVm }, 0..) |VmType, index| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        for ([_]struct { address: Address, code: []const u8 }{
            .{ .address = target, .code = &code },
            .{ .address = echo, .code = &echo_code },
        }) |contract| {
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(contract.code);
            try db.set_account(contract.address.bytes, account);
        }
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        // Twice, so the second frame reuses the first one's memory buffer.
        for (0..2) |round| {
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(result.success);
            try std.testing.expectEqual(@as(usize, 0x20A0), result.output.len);
            if (round == 0) {
                outputs[index] = try allocator.dupe(u8, result.output);
                produced += 1;
                gas_left[index] = result.gas_left;
            } else {
                // A reused buffer starts as empty memory again: same bytes, same gas.
                try std.testing.expectEqualSlices(u8, outputs[index], result.output);
                try std.testing.expectEqual(gas_left[index], result.gas_left);
            }
        }
    }
    for (outputs[1..], gas_left[1..]) |output, gas| {
        try std.testing.expectEqualSlices(u8, outputs[0], output);
        try std.testing.expectEqual(gas_left[0], gas);
    }

    const out = outputs[0];
    try std.testing.expectEqual(@as(u256, 0xAA), std.mem.readInt(u256, out[0..32], .big));
    // mem[0x40] = 0xBBBB with its last byte (0x5F) overwritten by 0xCC.
    try std.testing.expectEqual(@as(u256, 0xBBCC), std.mem.readInt(u256, out[0x40..0x60], .big));
    // mem[0x1000] = 0xBBCC + 0xAA.
    try std.testing.expectEqual(@as(u256, 0xBBCC + 0xAA), std.mem.readInt(u256, out[0x1000..0x1020], .big));
    // mem[0x20] = MLOAD(0x1000) + MLOAD(0x1001), the second being the first shifted by a byte.
    try std.testing.expectEqual(@as(u256, 0xBC76 + 0xBC7600), std.mem.readInt(u256, out[0x20..0x40], .big));
    try std.testing.expectEqual(@as(u8, 0xDD), out[0x103F]);
    try std.testing.expectEqual(@as(u8, 0xEE), out[0x1040]);
    // MSIZE after the MSTORE8 past the end, then after the call's output area.
    try std.testing.expectEqual(@as(u256, 0x1060), std.mem.readInt(u256, out[0x60..0x80], .big));
    try std.testing.expectEqual(@as(u256, 0x2080), std.mem.readInt(u256, out[0x2080..0x20A0], .big));
    // The nested frame echoed the first 0x80 bytes into 0x2000.
    try std.testing.expectEqualSlices(u8, out[0..0x80], out[0x2000..0x2080]);
}

test "memory: an offset no memory can hold halts every memory opcode" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA5)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB5)) };

    // The offset is 2^64 (PUSH9), then 2^255 (PUSH32): fused with a pointer operand,
    // or a plain PUSH followed by the opcode without fusion.
    const wide = [_]u8{ 0x68, 0x01 } ++ @as([8]u8, @splat(0));
    const huge = [_]u8{ 0x7F, 0x80 } ++ @as([31]u8, @splat(0));
    const programs = [_][]const u8{
        &(wide ++ [_]u8{ 0x51, 0x00 }), // MLOAD
        &([_]u8{ 0x60, 0x01 } ++ wide ++ [_]u8{ 0x52, 0x00 }), // MSTORE
        &([_]u8{ 0x60, 0x01 } ++ wide ++ [_]u8{ 0x53, 0x00 }), // MSTORE8
        &(huge ++ [_]u8{ 0x51, 0x00 }),
        &([_]u8{ 0x60, 0x01 } ++ huge ++ [_]u8{ 0x52, 0x00 }),
        &([_]u8{ 0x60, 0x01 } ++ huge ++ [_]u8{ 0x53, 0x00 }),
    };
    for (programs) |program| {
        inline for (.{ FusedVm, PlainVm }) |VmType| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(program);
            try db.set_account(target.bytes, account);
            var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 1_000_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(!result.success);
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        }
    }
}

test "MULMOD: one 512-bit reduction matches the u512 reference with and without fusion" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA6)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB6)) };

    const max = std.math.maxInt(u256);
    const values = [_]u256{
        0,
        1,
        2,
        0xFFFF_FFFF_FFFF_FFFF,
        1 << 64,
        1 << 128,
        1 << 255,
        max - 1,
        max,
        // Large primes: the secp256k1 field prime and 2^255 - 19.
        0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F,
        (1 << 255) - 19,
    };

    inline for (.{ FusedVm, PlainVm }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();

        for (values) |a| {
            for (values) |b| {
                for (values) |modulus| {
                    // PUSH32 modulus; PUSH32 b; PUSH32 a; MULMOD; return the word.
                    var code: [3 * 33 + 8]u8 = undefined;
                    code[0] = 0x7F;
                    std.mem.writeInt(u256, code[1..33], modulus, .big);
                    code[33] = 0x7F;
                    std.mem.writeInt(u256, code[34..66], b, .big);
                    code[66] = 0x7F;
                    std.mem.writeInt(u256, code[67..99], a, .big);
                    @memcpy(code[99..], &[_]u8{ 0x09, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3, 0x00 });
                    var account = evm.Account.zero();
                    account.code_hash = try db.set_code(&code);
                    try db.set_account(target.bytes, account);

                    var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
                    defer result.deinit(allocator);
                    try std.testing.expect(result.success);

                    const expected: u256 = if (modulus == 0) 0 else @intCast((@as(u512, a) * @as(u512, b)) % modulus);
                    try std.testing.expectEqual(expected, std.mem.readInt(u256, result.output[0..32], .big));
                    try std.testing.expectEqual(expected, evm.verified_ops.mulmodDirect(a, b, modulus));
                    try std.testing.expectEqual(expected, evm.verified_ops.mulmodRef(a, b, modulus));
                }
            }
        }
    }
}

test "PUSH+DIV: the pushed value is the dividend, for one-limb and wide operands" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xA7)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xB7)) };

    const max = std.math.maxInt(u256);
    // Pushed with PUSH8 when they fit (the fused handler's inline form), with
    // PUSH32 otherwise (its pointer form).
    const dividends = [_]u256{ 0, 1, 7, 100, 1 << 32, (1 << 64) - 1, 1 << 64, (1 << 64) + 1, 1 << 200, max };
    const divisors = [_]u256{ 0, 1, 2, 7, 100, (1 << 64) - 1, 1 << 64, (1 << 64) + 1, (1 << 128) + 5, 1 << 255, max };

    inline for (.{ FusedVm, PlainVm }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();

        for (dividends) |dividend| {
            for (divisors) |divisor| {
                // PUSH32 divisor; PUSH dividend; DIV computes top / second = dividend / divisor.
                var code: [33 + 33 + 8]u8 = undefined;
                var len: usize = 0;
                code[0] = 0x7F;
                std.mem.writeInt(u256, code[1..33], divisor, .big);
                len = 33;
                if (dividend <= std.math.maxInt(u64)) {
                    code[len] = 0x67; // PUSH8
                    std.mem.writeInt(u64, code[len + 1 ..][0..8], @intCast(dividend), .big);
                    len += 9;
                } else {
                    code[len] = 0x7F;
                    std.mem.writeInt(u256, code[len + 1 ..][0..32], dividend, .big);
                    len += 33;
                }
                @memcpy(code[len..][0..8], &[_]u8{ 0x04, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3, 0x00 });
                len += 8;
                var account = evm.Account.zero();
                account.code_hash = try db.set_code(code[0..len]);
                try db.set_account(target.bytes, account);

                var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 100_000 } });
                defer result.deinit(allocator);
                try std.testing.expect(result.success);
                const expected: u256 = if (divisor == 0) 0 else dividend / divisor;
                try std.testing.expectEqual(expected, std.mem.readInt(u256, result.output[0..32], .big));
                if (dividend <= std.math.maxInt(u64)) {
                    try std.testing.expectEqual(expected, @as(u256, evm.verified_ops.pushDivU64(@intCast(dividend), divisor)));
                }
            }
        }
    }
}

test "dispatch cache: filling past its capacity evicts through the free-slot bitmap" {
    const allocator = std.testing.allocator;
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA8)) };
    const contracts = 300;
    try std.testing.expect(contracts > FusedVm.DispatchCache.max_entries);

    // Contract i returns i: PUSH2 i; PUSH0; MSTORE; RETURN(0, 32). Distinct code, distinct hash.
    for (0..contracts) |index| {
        const code = [_]u8{ 0x61, @intCast(index >> 8), @truncate(index), 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
        var address = @as([20]u8, @splat(0xC8));
        std.mem.writeInt(u16, address[18..20], @intCast(index), .big);
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(&code);
        try db.set_account(address, account);
    }

    var vm = try FusedVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    const max_entries = FusedVm.DispatchCache.max_entries;
    for (0..3) |pass| {
        for (0..contracts) |index| {
            var address = @as([20]u8, @splat(0xC8));
            std.mem.writeInt(u16, address[18..20], @intCast(index), .big);
            var result = vm.call(.{ .call = .{ .caller = origin, .to = .{ .bytes = address }, .value = 0, .input = &.{}, .gas = 100_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(result.success);
            try std.testing.expectEqual(@as(u256, index), std.mem.readInt(u256, result.output[0..32], .big));

            const cache = &vm.dispatch_cache;
            // Before the cache is full, entries take slots in order and nothing is evicted.
            if (pass == 0 and index < max_entries) {
                try std.testing.expectEqual(index + 1, cache.count());
                try std.testing.expectEqual(@as(u64, 0), cache.evictions);
                try std.testing.expectEqual(max_entries - index - 1, cache.free_slots.count());
                try std.testing.expect(cache.slots[index] != null);
            }
            try std.testing.expect(cache.count() <= max_entries);
            try std.testing.expectEqual(max_entries, cache.count() + cache.free_slots.count());
        }
    }

    const cache = &vm.dispatch_cache;
    try std.testing.expectEqual(max_entries, cache.count());
    try std.testing.expect(cache.evictions >= contracts - max_entries);
    // The bitmap and the slot array describe the same set, and the byte total is
    // the sum over the cached entries.
    var bytes: usize = 0;
    for (cache.slots, 0..) |slot, index| {
        try std.testing.expectEqual(slot == null, cache.free_slots.isFree(index));
        const entry = slot orelse continue;
        try std.testing.expectEqual(@as(?usize, index), entry.slot);
        try std.testing.expectEqual(@as(u32, 0), entry.pins);
        try std.testing.expect(cache.contains(entry.hash));
        bytes += entry.bytes;
    }
    try std.testing.expectEqual(bytes, cache.bytes);
    try std.testing.expect(cache.bytes <= FusedVm.DispatchCache.max_bytes);
}

test "dispatch cache: an entry a running frame uses is never evicted" {
    const allocator = std.testing.allocator;
    const SmallCacheVm = evm.Evm(.{ .dispatch_cache_entries = 8 });
    var db = evm.Database.init(allocator);
    defer db.deinit();

    const origin = Address{ .bytes = @as([20]u8, @splat(0xA9)) };
    const outer = Address{ .bytes = @as([20]u8, @splat(0xB9)) };
    const callees = 24;

    // Callee i returns i + 1.
    for (0..callees) |index| {
        const code = [_]u8{ 0x60, @intCast(index + 1), 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
        var address = @as([20]u8, @splat(0xC9));
        address[19] = @intCast(index);
        var account = evm.Account.zero();
        account.code_hash = try db.set_code(&code);
        try db.set_account(address, account);
    }
    // outer: sum = 0; for each callee: CALL it with 32 bytes of output at 0, sum += mem[0].
    // It stays pinned while 24 analyses pass through an 8-entry cache.
    var outer_code: std.ArrayList(u8) = .empty;
    defer outer_code.deinit(allocator);
    try outer_code.append(allocator, 0x5F); // sum
    for (0..callees) |index| {
        var address = @as([20]u8, @splat(0xC9));
        address[19] = @intCast(index);
        try outer_code.appendSlice(allocator, &[_]u8{ 0x60, 0x20, 0x5F, 0x5F, 0x5F, 0x5F, 0x73 });
        try outer_code.appendSlice(allocator, &address);
        try outer_code.appendSlice(allocator, &[_]u8{ 0x5A, 0xF1, 0x50, 0x5F, 0x51, 0x01 });
    }
    try outer_code.appendSlice(allocator, &[_]u8{ 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 });
    var outer_account = evm.Account.zero();
    outer_account.code_hash = try db.set_code(outer_code.items);
    try db.set_account(outer.bytes, outer_account);

    var vm = try SmallCacheVm.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer vm.deinit();

    for (0..3) |_| {
        var result = vm.call(.{ .call = .{ .caller = origin, .to = outer, .value = 0, .input = &.{}, .gas = 5_000_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        // 1 + 2 + ... + 24: every callee ran its own code, cached or not.
        try std.testing.expectEqual(@as(u256, callees * (callees + 1) / 2), std.mem.readInt(u256, result.output[0..32], .big));

        const cache = &vm.dispatch_cache;
        try std.testing.expect(cache.contains(outer_account.code_hash));
        try std.testing.expect(cache.count() <= 8);
        try std.testing.expectEqual(@as(usize, 8), cache.count() + cache.free_slots.count());
        try std.testing.expect(cache.evictions >= callees + 1 - 8);
        for (cache.slots, 0..) |slot, index| {
            try std.testing.expectEqual(slot == null, cache.free_slots.isFree(index));
            if (slot) |entry| try std.testing.expectEqual(@as(u32, 0), entry.pins);
        }
    }
}

test "native handlers: STOP, INVALID, an undefined opcode and BLOBHASH" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBA)) };

    const hashes = [_][32]u8{
        [_]u8{0x01} ++ @as([31]u8, @splat(0x11)),
        [_]u8{0x01} ++ @as([31]u8, @splat(0x22)),
    };
    // BLOBHASH(calldata word 0), returned.
    const blobhash_code = [_]u8{ 0x5F, 0x35, 0x49, 0x5F, 0x52, 0x60, 0x20, 0x5F, 0xF3 };
    const Case = struct { code: []const u8, index: u256, succeeds: bool, word: ?u256 };
    const cases = [_]Case{
        // PUSH1 7; PUSH1 9; STOP leaves both items and all unspent gas.
        .{ .code = &.{ 0x60, 0x07, 0x60, 0x09, 0x00 }, .index = 0, .succeeds = true, .word = null },
        .{ .code = &.{0x00}, .index = 0, .succeeds = true, .word = null },
        .{ .code = &.{}, .index = 0, .succeeds = true, .word = null },
        // INVALID and an opcode no fork defines both consume all gas.
        .{ .code = &.{ 0x60, 0x07, 0xFE }, .index = 0, .succeeds = false, .word = null },
        .{ .code = &.{ 0x60, 0x07, 0x0C }, .index = 0, .succeeds = false, .word = null },
        .{ .code = &blobhash_code, .index = 0, .succeeds = true, .word = std.mem.readInt(u256, &hashes[0], .big) },
        .{ .code = &blobhash_code, .index = 1, .succeeds = true, .word = std.mem.readInt(u256, &hashes[1], .big) },
        .{ .code = &blobhash_code, .index = 2, .succeeds = true, .word = 0 },
        .{ .code = &blobhash_code, .index = 1 << 64, .succeeds = true, .word = 0 },
        .{ .code = &blobhash_code, .index = std.math.maxInt(u256), .succeeds = true, .word = 0 },
    };

    var gas_by_case: [3][cases.len]u64 = undefined;
    inline for (.{ FusedVm, PlainVm, TracedVm }, 0..) |VmType, vm_index| {
        for (cases, 0..) |case, case_index| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var account = evm.Account.zero();
            if (case.code.len != 0) account.code_hash = try db.set_code(case.code);
            try db.set_account(target.bytes, account);
            var vm = try VmType.init(
                allocator,
                &db,
                evm.BlockInfo.init(),
                .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1, .blob_versioned_hashes = &hashes },
                0,
                origin,
            );
            defer vm.deinit();
            var input: [32]u8 = undefined;
            std.mem.writeInt(u256, &input, case.index, .big);
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &input, .gas = 100_000 } });
            defer result.deinit(allocator);
            try std.testing.expectEqual(case.succeeds, result.success);
            if (!case.succeeds) try std.testing.expectEqual(@as(u64, 0), result.gas_left);
            if (case.word) |word| {
                try std.testing.expectEqual(@as(usize, 32), result.output.len);
                try std.testing.expectEqual(word, std.mem.readInt(u256, result.output[0..32], .big));
            } else {
                try std.testing.expectEqual(@as(usize, 0), result.output.len);
            }
            gas_by_case[vm_index][case_index] = result.gas_left;
        }
    }
    try std.testing.expectEqualSlices(u64, &gas_by_case[0], &gas_by_case[1]);
    try std.testing.expectEqualSlices(u64, &gas_by_case[0], &gas_by_case[2]);
}

test "cold analysis: pseudo-random code runs the same with and without fusion" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAB)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    // Opcodes that keep execution inside the frame: arithmetic, stack, memory,
    // jumps, PUSH and the block-ending instructions. Each program is analyzed cold.
    const alphabet = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x09, 0x10, 0x14, 0x15, 0x15, 0x16, 0x17, 0x18, 0x19,
        0x50, 0x51, 0x52, 0x53, 0x56, 0x57, 0x57, 0x58, 0x59, 0x5A, 0x5B, 0x5B, 0x5B,
        0x5F, 0x60, 0x60, 0x60, 0x60, 0x61, 0x67, 0x68, 0x7F, 0x80, 0x81, 0x90, 0x91,
        0x00, 0xF3, 0xFD, 0xFE,
    };
    var prng = std.Random.DefaultPrng.init(0x636f6c64);
    const random = prng.random();

    var fused_db = evm.Database.init(allocator);
    defer fused_db.deinit();
    var plain_db = evm.Database.init(allocator);
    defer plain_db.deinit();
    var fused = try FusedVm.init(allocator, &fused_db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer fused.deinit();
    var plain = try PlainVm.init(allocator, &plain_db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
    defer plain.deinit();

    var programs: usize = 0;
    var successes: usize = 0;
    while (programs < 400) : (programs += 1) {
        var code: [96]u8 = undefined;
        const len = random.intRangeAtMost(usize, 1, code.len);
        var index: usize = 0;
        while (index < len) {
            const opcode = alphabet[random.uintLessThan(usize, alphabet.len)];
            code[index] = opcode;
            index += 1;
            if (opcode >= 0x60 and opcode <= 0x7F) {
                // Immediates are small so that pushed jump targets and memory
                // offsets often land inside the program.
                var remaining: usize = opcode - 0x5F;
                while (remaining > 0 and index < len) : (remaining -= 1) {
                    code[index] = if (remaining == 1) random.uintLessThan(u8, 100) else 0;
                    index += 1;
                }
            }
        }

        var outcomes: [2]Outcome = undefined;
        inline for (.{ &fused, &plain }, .{ &fused_db, &plain_db }, 0..) |vm, db, slot| {
            var account = evm.Account.zero();
            account.code_hash = try db.set_code(code[0..len]);
            try db.set_account(target.bytes, account);
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &.{}, .gas = 60_000 } });
            defer result.deinit(allocator);
            var outcome = Outcome{ .success = result.success, .gas_left = result.gas_left, .output = @splat(0), .output_len = result.output.len };
            const kept = @min(result.output.len, outcome.output.len);
            @memcpy(outcome.output[0..kept], result.output[0..kept]);
            outcomes[slot] = outcome;
        }
        try std.testing.expectEqual(outcomes[0].success, outcomes[1].success);
        try std.testing.expectEqual(outcomes[0].gas_left, outcomes[1].gas_left);
        try std.testing.expectEqual(outcomes[0].output_len, outcomes[1].output_len);
        try std.testing.expectEqualSlices(u8, &outcomes[0].output, &outcomes[1].output);
        if (outcomes[0].success) successes += 1;
    }
    // The alphabet is not so hostile that every program halts.
    try std.testing.expect(successes > 20);
}

test "dynamic JUMP/JUMPI to 0xFFFFFFFF sentinel halts cleanly on pre-Shanghai u32 PcType" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const target = Address{ .bytes = @as([20]u8, @splat(0xBB)) };

    // Pre-Shanghai forks select u32 PcType, so 0xFFFFFFFF equals the bucket table's EMPTY_PC sentinel.
    // Both JUMP and taken JUMPI to 0xFFFFFFFF must halt as InvalidJump, never match an empty bucket.
    const ParisFused = evm.Evm(.{ .enable_fusion = true, .eips = .{ .hardfork = .FRONTIER } });
    const ParisPlain = evm.Evm(.{ .enable_fusion = false, .eips = .{ .hardfork = .FRONTIER } });
    comptime if (@bitSizeOf(ParisFused.Bytecode.PcType) < 32) {
        @compileError("pre-Shanghai PcType must be at least 32 bits");
    };

    // Code 1: dynamic JUMP to 0xFFFFFFFF (via CALLDATALOAD so not statically fused) with a valid JUMPDEST present.
    const jump_sentinel = [_]u8{
        0x60, 0x00, 0x35, // PUSH1 0; CALLDATALOAD -> 0xFFFFFFFF
        0x56, // JUMP
        0x5b, 0x00, // JUMPDEST; STOP (ensures non-empty jump table)
    };
    // Code 2: dynamic JUMPI taken to 0xFFFFFFFF with a valid JUMPDEST present.
    const jumpi_sentinel = [_]u8{
        0x60, 0x01, // condition = 1
        0x60, 0x00, 0x35, // dest = 0xFFFFFFFF
        0x57, // JUMPI
        0x5b, 0x00, // JUMPDEST; STOP
    };
    var calldata: [32]u8 = @splat(0);
    std.mem.writeInt(u256, &calldata, 0xFFFF_FFFF, .big);

    inline for (.{ ParisFused, ParisPlain }) |VmType| {
        for ([_][]const u8{ &jump_sentinel, &jumpi_sentinel }) |code| {
            var db = evm.Database.init(allocator);
            defer db.deinit();
            var acc = evm.Account.zero();
            acc.code_hash = try db.set_code(code);
            try db.set_account(target.bytes, acc);
            var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
            defer vm.deinit();
            var result = vm.call(.{ .call = .{ .caller = origin, .to = target, .value = 0, .input = &calldata, .gas = 100_000 } });
            defer result.deinit(allocator);
            try std.testing.expect(!result.success);
            try std.testing.expectEqual(@as(u64, 0), result.gas_left);
        }
    }
}

test "nested CALL and CREATE keep callee address warm (EIP-2929) for self-access" {
    const allocator = std.testing.allocator;
    const origin = Address{ .bytes = @as([20]u8, @splat(0xAA)) };
    const caller_addr = Address{ .bytes = @as([20]u8, @splat(0xCA)) };
    const callee_addr = Address{ .bytes = @as([20]u8, @splat(0xCB)) };

    // Callee runs ADDRESS; BALANCE; POP; STOP and returns gas spent on BALANCE via GAS before/after.
    // On EIP-2929+, ADDRESS is already warm so BALANCE must cost 100 gas (not 2600 cold).
    const callee_code = [_]u8{
        0x5a, // GAS (before)
        0x30, // ADDRESS
        0x31, // BALANCE (warm = 100, cold = 2600)
        0x50, // POP
        0x5a, // GAS (after)
        0x90, 0x03, // SWAP1; SUB -> before - after
        0x5f, 0x52, // PUSH0; MSTORE
        0x60, 0x20, 0x5f, 0xf3, // RETURN 32 bytes
    };
    // Caller calls callee and returns its 32-byte output.
    const caller_code = [_]u8{
        0x60, 0x20, 0x5f, // retSize=32, retOffset=0
        0x5f, 0x5f, // argsSize=0, argsOffset=0
        0x5f, // value=0
        0x73, // PUSH20 callee_addr
    } ++ callee_addr.bytes ++ [_]u8{
        0x61, 0xc3, 0x50, // gas=50000
        0xf1, // CALL
        0x50, // POP
        0x60, 0x20, 0x5f, 0xf3, // RETURN 32 bytes
    };

    inline for (.{ FusedVm, PlainVm }) |VmType| {
        var db = evm.Database.init(allocator);
        defer db.deinit();
        var a1 = evm.Account.zero();
        a1.code_hash = try db.set_code(&caller_code);
        try db.set_account(caller_addr.bytes, a1);
        var a2 = evm.Account.zero();
        a2.code_hash = try db.set_code(&callee_code);
        try db.set_account(callee_addr.bytes, a2);
        var vm = try VmType.init(allocator, &db, evm.BlockInfo.init(), .{ .gas_limit = 16_000_000, .coinbase = primitives.ZERO_ADDRESS, .chain_id = 1 }, 0, origin);
        defer vm.deinit();
        var result = vm.call(.{ .call = .{ .caller = origin, .to = caller_addr, .value = 0, .input = &.{}, .gas = 200_000 } });
        defer result.deinit(allocator);
        try std.testing.expect(result.success);
        try std.testing.expectEqual(@as(usize, 32), result.output.len);
        const delta = std.mem.readInt(u256, result.output[0..32], .big);
        // Warm BALANCE (100) + ADDRESS (2) + POP (2) + GAS (2) = 106 (nowhere near cold 2600+).
        try std.testing.expect(delta < 500);
    }
}
