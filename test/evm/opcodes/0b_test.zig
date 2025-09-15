const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "SIGNEXTEND: extend byte 0 of 0xFF" {
    try run_signextend_test(std.testing.allocator, 0, 0xFF);
}

fn run_signextend_test(allocator: std.mem.Allocator, byte_num: u256, value: u256) !void {
    // Build custom bytecode for SIGNEXTEND test
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push byte_num (which byte to extend from)
    if (byte_num == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, byte_num, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push value to extend
    if (value == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, value, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // SIGNEXTEND opcode
    try buf.append(allocator, 0x0b);
    
    // Store result and return
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN
    
    const bytecode = try buf.toOwnedSlice(allocator);
    defer allocator.free(bytecode);
    
    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode);
    
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var guillotine_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer guillotine_evm.deinit();
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

test "SIGNEXTEND: extend byte 0 of 0x7F (positive)" {
    try run_signextend_test(std.testing.allocator, 0, 0x7F);
}

test "SIGNEXTEND: extend byte 0 of 0x80 (negative)" {
    try run_signextend_test(std.testing.allocator, 0, 0x80);
}

test "SIGNEXTEND: extend byte 1 of 0xFFFF" {
    try run_signextend_test(std.testing.allocator, 1, 0xFFFF);
}

test "SIGNEXTEND: extend byte 1 of 0x7FFF (positive)" {
    try run_signextend_test(std.testing.allocator, 1, 0x7FFF);
}

test "SIGNEXTEND: extend byte 1 of 0x8000 (negative)" {
    try run_signextend_test(std.testing.allocator, 1, 0x8000);
}

test "SIGNEXTEND: extend byte 2 of 0xFFFFFF" {
    try run_signextend_test(std.testing.allocator, 2, 0xFFFFFF);
}

test "SIGNEXTEND: extend byte 3 of 0xFFFFFFFF" {
    try run_signextend_test(std.testing.allocator, 3, 0xFFFFFFFF);
}

test "SIGNEXTEND: extend byte 7 of 0xFFFFFFFFFFFFFFFF" {
    try run_signextend_test(std.testing.allocator, 7, 0xFFFFFFFFFFFFFFFF);
}

test "SIGNEXTEND: extend byte 0 of zero" {
    try run_signextend_test(std.testing.allocator, 0, 0);
}

test "SIGNEXTEND: extend byte 31 (no change)" {
    try run_signextend_test(std.testing.allocator, 31, 0x123456789ABCDEF0);
}

test "SIGNEXTEND: extend byte > 31 (no change)" {
    try run_signextend_test(std.testing.allocator, 32, 0x123456789ABCDEF0);
}

test "SIGNEXTEND: extend byte 255 (no change)" {
    try run_signextend_test(std.testing.allocator, 255, 0x123456789ABCDEF0);
}

test "SIGNEXTEND: extend byte 0 of 0x01" {
    try run_signextend_test(std.testing.allocator, 0, 0x01);
}

test "SIGNEXTEND: extend byte 0 of 0xFE" {
    try run_signextend_test(std.testing.allocator, 0, 0xFE);
}

test "SIGNEXTEND: extend byte 1 of 0x0100" {
    try run_signextend_test(std.testing.allocator, 1, 0x0100);
}

test "SIGNEXTEND: extend byte 1 of 0xFF00" {
    try run_signextend_test(std.testing.allocator, 1, 0xFF00);
}

test "SIGNEXTEND: extend byte 15 of large number" {
    const large = (@as(u256, 0x8000) << 120) | 0x123456789ABCDEF;
    try run_signextend_test(std.testing.allocator, 15, large);
}

test "SIGNEXTEND: extend byte 15 positive large number" {
    const large = (@as(u256, 0x7FFF) << 120) | 0x123456789ABCDEF;
    try run_signextend_test(std.testing.allocator, 15, large);
}

test "SIGNEXTEND: extend with MAX byte number" {
    try run_signextend_test(std.testing.allocator, std.math.maxInt(u256), 0xFF);
}

test "SIGNEXTEND: extend byte 30 of near-max value" {
    const near_max = std.math.maxInt(u256) - 0xFF;
    try run_signextend_test(std.testing.allocator, 30, near_max);
}

test "SIGNEXTEND: alternating bit pattern byte 0" {
    try run_signextend_test(std.testing.allocator, 0, 0xAA);
}

test "SIGNEXTEND: alternating bit pattern byte 1" {
    try run_signextend_test(std.testing.allocator, 1, 0xAAAA);
}

test "SIGNEXTEND: all ones pattern byte 3" {
    try run_signextend_test(std.testing.allocator, 3, 0xFFFFFFFF);
}

test "SIGNEXTEND: mixed pattern byte 7" {
    try run_signextend_test(std.testing.allocator, 7, 0xDEADBEEFCAFEBABE);
}

test "SIGNEXTEND: power of 2 minus 1 byte 3" {
    try run_signextend_test(std.testing.allocator, 3, ((@as(u256, 1) << 32) - 1));
}

test "SIGNEXTEND: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64));
    try run_signextend_test(std.testing.allocator, 7, near_u64);
}

test "SIGNEXTEND: exactly u64 max byte 8" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_signextend_test(std.testing.allocator, 8, u64_max);
}

test "SIGNEXTEND: 256-bit value byte 31" {
    const max_256 = std.math.maxInt(u256);
    try run_signextend_test(std.testing.allocator, 31, max_256);
}

fn run_signextend_test_with_jump(allocator: std.mem.Allocator, byte_num: u256, value: u256) !void {
    // Build custom bytecode for SIGNEXTEND test with jump to prevent fusion
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push byte_num (which byte to extend from)
    if (byte_num == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, byte_num, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push value to extend
    if (value == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, value, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Calculate jump destination (current position + 3 for PUSH1 + 1 byte + JUMP)
    const jump_dest = buf.items.len + 3;
    
    // Jump to SIGNEXTEND (prevents fusion)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // JUMPDEST + SIGNEXTEND
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x0b); // SIGNEXTEND opcode
    
    // Store result and return
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (memory offset)
    try buf.append(allocator, 0x52); // MSTORE
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x20); // 32 (length)
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, 0x00); // 0 (offset)
    try buf.append(allocator, 0xf3); // RETURN
    
    const bytecode = try buf.toOwnedSlice(allocator);
    defer allocator.free(bytecode);
    
    // Setup Guillotine EVM
    var database = evm.Database.init(allocator);
    defer database.deinit();
    
    const caller_address = primitives.Address{ .bytes = [_]u8{0x10} ++ [_]u8{0} ** 18 ++ [_]u8{0x01} };
    const contract_address = primitives.Address{ .bytes = [_]u8{0x20} ++ [_]u8{0} ** 18 ++ [_]u8{0x02} };
    
    const code_hash = try database.set_code(bytecode);
    
    try database.set_account(contract_address.bytes, .{
        .balance = 0,
        .nonce = 0,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    try database.set_account(caller_address.bytes, .{
        .balance = std.math.maxInt(u256),
        .nonce = 0,
        .code_hash = [_]u8{0} ** 32,
        .storage_root = [_]u8{0} ** 32,
    });
    
    const block_info = evm.BlockInfo{
        .chain_id = 1,
        .number = 20_000_000,
        .timestamp = 1_800_000_000,
        .difficulty = 0,
        .gas_limit = 1_000_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .base_fee = 7,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 1000000000,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm.TransactionContext{
        .gas_limit = 1_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    
    var guillotine_evm = try evm.Evm(.{}).init(
        allocator,
        &database,
        block_info,
        tx_context,
        0,
        caller_address,
        .CANCUN
    );
    defer guillotine_evm.deinit();
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller_address,
            .to = contract_address,
            .value = 0,
            .input = &.{},
            .gas = 1_000_000,
        },
    };
    
    var guillotine_result = guillotine_evm.call(call_params);
    defer guillotine_result.deinit(allocator);
}

test "SIGNEXTEND with JUMP: basic byte 0 of 0xFF" {
    try run_signextend_test_with_jump(std.testing.allocator, 0, 0xFF);
}

test "SIGNEXTEND with JUMP: byte 1 of 0x8000" {
    try run_signextend_test_with_jump(std.testing.allocator, 1, 0x8000);
}

test "SIGNEXTEND with JUMP: byte 7 of large value" {
    try run_signextend_test_with_jump(std.testing.allocator, 7, 0xDEADBEEFCAFEBABE);
}

test "SIGNEXTEND with JUMP: byte 31 of MAX" {
    try run_signextend_test_with_jump(std.testing.allocator, 31, std.math.maxInt(u256));
}

test "SIGNEXTEND with JUMP: edge case byte > 31" {
    try run_signextend_test_with_jump(std.testing.allocator, 100, 0x123456789ABCDEF0);
}