const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "DIV: basic (10 / 2 = 5)" {
    try run_div_test(std.testing.allocator, 10, 2);
}

fn run_div_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for DIV test
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a
    if (a == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, a, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push b
    if (b == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, b, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // DIV opcode
    try buf.append(allocator, 0x04);
    
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

test "DIV: division by zero (42 / 0 = 0)" {
    try run_div_test(std.testing.allocator, 42, 0);
}

test "DIV: zero divided (0 / 5 = 0)" {
    try run_div_test(std.testing.allocator, 0, 5);
}

test "DIV: zero divided by zero (0 / 0 = 0)" {
    try run_div_test(std.testing.allocator, 0, 0);
}

test "DIV: division by one (123 / 1 = 123)" {
    try run_div_test(std.testing.allocator, 123, 1);
}

test "DIV: one divided (1 / 456 = 0)" {
    try run_div_test(std.testing.allocator, 1, 456);
}

test "DIV: exact division (56 / 8 = 7)" {
    try run_div_test(std.testing.allocator, 56, 8);
}

test "DIV: larger numbers beyond u64" {
    const large_dividend = (@as(u256, 1) << 80) + 12345678901234567890;
    const large_divisor = (@as(u256, 1) << 70) + 987654321;
    try run_div_test(std.testing.allocator, large_dividend, large_divisor);
}

test "DIV: powers of 2 (65536 / 256 = 256)" {
    try run_div_test(std.testing.allocator, 65536, 256);
}

test "DIV: beyond u64 boundary" {
    const beyond_u64 = (@as(u256, std.math.maxInt(u64)) << 10) + 0xDEADBEEF;
    const divisor = (@as(u256, 1) << 73) + 0xCAFEBABE;
    try run_div_test(std.testing.allocator, beyond_u64, divisor);
}

test "DIV: exactly u64 max divided by 2" {
    const u64_max = @as(u256, std.math.maxInt(u64));
    try run_div_test(std.testing.allocator, u64_max, 2);
}

test "DIV: large 128-bit division" {
    const large_128 = @as(u256, 1) << 128;
    try run_div_test(std.testing.allocator, large_128, large_128);
}

test "DIV: MAX_U256 divided by 2" {
    try run_div_test(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "DIV: MAX_U256 divided by MAX_U256" {
    try run_div_test(std.testing.allocator, std.math.maxInt(u256), std.math.maxInt(u256));
}

test "DIV: half MAX times 2 divided by 4" {
    const half_max = std.math.maxInt(u256) / 2;
    try run_div_test(std.testing.allocator, half_max * 2, 4);
}

test "DIV: with remainder (144 / 12 = 12)" {
    try run_div_test(std.testing.allocator, 144, 12);
}

test "DIV: prime division (221 / 17 = 13)" {
    try run_div_test(std.testing.allocator, 221, 17);
}

test "DIV: fibonacci division (273 / 21 = 13)" {
    try run_div_test(std.testing.allocator, 273, 21);
}

test "DIV: power of 2 shifts" {
    const pow_32 = @as(u256, 1) << 32;
    const pow_16 = @as(u256, 1) << 16;
    try run_div_test(std.testing.allocator, pow_32, pow_16);
}

test "DIV: near 256-bit boundary" {
    const near_max = std.math.maxInt(u256) / 3;
    try run_div_test(std.testing.allocator, near_max * 3, 3);
}

test "DIV: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_div_test(std.testing.allocator, pattern1, pattern2);
}

test "DIV: all 1s in lower 64 bits" {
    const all_ones_64 = (@as(u256, 1) << 64) - 1;
    try run_div_test(std.testing.allocator, all_ones_64, 2);
}

test "DIV: sequential values (9900 / 100 = 99)" {
    try run_div_test(std.testing.allocator, 9900, 100);
}

test "DIV: large 256-bit sequential" {
    const large = (@as(u256, 1) << 200) + (@as(u256, 1) << 150);
    const divisor = (@as(u256, 1) << 100) + (@as(u256, 1) << 50);
    try run_div_test(std.testing.allocator, large, divisor);
}

test "DIV: edge case with quotient 1" {
    const edge = (@as(u256, 1) << 128) - 1;
    try run_div_test(std.testing.allocator, edge, edge);
}

test "DIV: very large 256-bit divisor" {
    const dividend = (@as(u256, 1) << 250) + (@as(u256, 0xDEADBEEFCAFEBABE) << 180);
    const large_divisor = (@as(u256, 1) << 240) + (@as(u256, 0xFEEDFACE) << 170);
    try run_div_test(std.testing.allocator, dividend, large_divisor);
}

test "DIV: small dividend, large divisor" {
    const large = @as(u256, 1) << 100;
    try run_div_test(std.testing.allocator, 100, large);
}

test "DIV: power of 10 division" {
    const pow10 = 10000000000; // 10^10
    try run_div_test(std.testing.allocator, pow10 * 123, pow10);
}

test "DIV: remainder truncated (15 / 4 = 3)" {
    try run_div_test(std.testing.allocator, 15, 4);
}

test "DIV: remainder truncated large (999999 / 1000000 = 0)" {
    try run_div_test(std.testing.allocator, 999999, 1000000);
}

fn run_div_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for DIV test with jump to prevent fusion
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    // Push a
    if (a == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, a, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Push b
    if (b == 0) {
        try buf.append(allocator, 0x5f); // PUSH0
    } else {
        var tmp: [32]u8 = [_]u8{0} ** 32;
        std.mem.writeInt(u256, &tmp, b, .big);
        const first_non_zero = std.mem.indexOfNonePos(u8, &tmp, 0, &[_]u8{0}) orelse 32;
        const slice = tmp[first_non_zero..];
        if (slice.len > 0 and slice.len <= 32) {
            const op: u8 = 0x60 + @as(u8, @intCast(slice.len - 1));
            try buf.append(allocator, op);
            try buf.appendSlice(allocator, slice);
        }
    }
    
    // Jump to DIV (prevents fusion)
    // First calculate the jump destination
    // We need PUSH1 (1) + dest byte (1) + JUMP (1) + JUMPDEST (1) = 4 bytes ahead
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + DIV
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x04); // DIV opcode
    
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

test "DIV with JUMP: basic (10 / 2 = 5)" {
    try run_div_test_with_jump(std.testing.allocator, 10, 2);
}

test "DIV with JUMP: division by zero (100 / 0 = 0)" {
    try run_div_test_with_jump(std.testing.allocator, 100, 0);
}

test "DIV with JUMP: large numbers beyond u64" {
    const huge_num = (@as(u256, 1) << 128) + (@as(u256, 1) << 96) + 999999999999;
    const big_divisor = (@as(u256, 1) << 65) + 12345;
    try run_div_test_with_jump(std.testing.allocator, huge_num, big_divisor);
}

test "DIV with JUMP: MAX_U256 divided by 2" {
    try run_div_test_with_jump(std.testing.allocator, std.math.maxInt(u256), 2);
}

test "DIV with JUMP: beyond u64 boundary" {
    const beyond_u64 = (@as(u256, std.math.maxInt(u64)) + 1) << 32;
    const divisor = (@as(u256, 1) << 80) + 0xFEEDFACE;
    try run_div_test_with_jump(std.testing.allocator, beyond_u64, divisor);
}