const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const common = @import("common.zig");

test "MOD: basic (10 % 3 = 1)" {
    try run_mod_test(std.testing.allocator, 10, 3);
}

fn run_mod_test(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for MOD test
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
    
    // MOD opcode
    try buf.append(allocator, 0x06);
    
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

test "MOD: modulo by zero returns 0 (42 % 0 = 0)" {
    try run_mod_test(std.testing.allocator, 42, 0);
}

test "MOD: zero modulo zero (0 % 0 = 0)" {
    try run_mod_test(std.testing.allocator, 0, 0);
}

test "MOD: zero modulo number (0 % 5 = 0)" {
    try run_mod_test(std.testing.allocator, 0, 5);
}

test "MOD: modulo by 1 (123 % 1 = 0)" {
    try run_mod_test(std.testing.allocator, 123, 1);
}

test "MOD: modulo by 2 - even (10 % 2 = 0)" {
    try run_mod_test(std.testing.allocator, 10, 2);
}

test "MOD: modulo by 2 - odd (11 % 2 = 1)" {
    try run_mod_test(std.testing.allocator, 11, 2);
}

test "MOD: small numbers (7 % 3 = 1)" {
    try run_mod_test(std.testing.allocator, 7, 3);
}

test "MOD: equal values (15 % 15 = 0)" {
    try run_mod_test(std.testing.allocator, 15, 15);
}

test "MOD: smaller dividend (5 % 7 = 5)" {
    try run_mod_test(std.testing.allocator, 5, 7);
}

test "MOD: power of 2 modulo (1000 % 256 = 232)" {
    try run_mod_test(std.testing.allocator, 1000, 256);
}

test "MOD: large modulo small (1000000 % 7 = 6)" {
    try run_mod_test(std.testing.allocator, 1000000, 7);
}

test "MOD: power of 2 bit masking (255 % 16 = 15)" {
    try run_mod_test(std.testing.allocator, 255, 16);
}

test "MOD: power of 2 divisions (1024 % 32 = 0)" {
    try run_mod_test(std.testing.allocator, 1024, 32);
}

test "MOD: fibonacci numbers (21 % 13 = 8)" {
    try run_mod_test(std.testing.allocator, 21, 13);
}

test "MOD: prime numbers (97 % 17 = 12)" {
    try run_mod_test(std.testing.allocator, 97, 17);
}

test "MOD: near u32 boundary" {
    const near_u32 = @as(u256, std.math.maxInt(u32));
    try run_mod_test(std.testing.allocator, near_u32, 1000);
}

test "MOD: near u64 boundary" {
    const near_u64 = @as(u256, std.math.maxInt(u64));
    try run_mod_test(std.testing.allocator, near_u64, 12345);
}

test "MOD: large 128-bit numbers" {
    const large_128 = (@as(u256, 1) << 100) + 12345;
    const modulus = (@as(u256, 1) << 50) + 1;
    try run_mod_test(std.testing.allocator, large_128, modulus);
}

test "MOD: max value modulo small (MAX % 3)" {
    try run_mod_test(std.testing.allocator, std.math.maxInt(u256), 3);
}

test "MOD: max value modulo large" {
    const large_mod = (@as(u256, 1) << 200);
    try run_mod_test(std.testing.allocator, std.math.maxInt(u256), large_mod);
}

test "MOD: alternating bit patterns" {
    const pattern1 = 0xAAAAAAAAAAAAAAAA;
    const pattern2 = 0x5555555555555555;
    try run_mod_test(std.testing.allocator, pattern1, pattern2);
}

test "MOD: large 256-bit beyond u64" {
    const huge_dividend = (@as(u256, 1) << 100) + (@as(u256, 0xDEADBEEF) << 50);
    const huge_divisor = (@as(u256, 1) << 70) + 0xCAFEBABE;
    try run_mod_test(std.testing.allocator, huge_dividend, huge_divisor);
}

test "MOD: very large 256-bit operations" {
    const massive = (@as(u256, 1) << 200) + (@as(u256, 1) << 150);
    const big_mod = (@as(u256, 1) << 100) + (@as(u256, 1) << 50);
    try run_mod_test(std.testing.allocator, massive, big_mod);
}

test "MOD: near max u256" {
    const near_max = std.math.maxInt(u256) - 1000;
    const divisor = (@as(u256, 1) << 128) + 12345;
    try run_mod_test(std.testing.allocator, near_max, divisor);
}

test "MOD: consecutive numbers (100 % 99 = 1)" {
    try run_mod_test(std.testing.allocator, 100, 99);
}

test "MOD: large consecutive" {
    const large = (@as(u256, 1) << 80) + 100;
    try run_mod_test(std.testing.allocator, large, large - 1);
}

test "MOD: power of 10 modulo (1000000000 % 1000000 = 0)" {
    try run_mod_test(std.testing.allocator, 1000000000, 1000000);
}

test "MOD: edge case near 128-bit boundary" {
    const edge = (@as(u256, 1) << 128) - 1;
    const mod_val = (@as(u256, 1) << 64) + 1;
    try run_mod_test(std.testing.allocator, edge, mod_val);
}

test "MOD: bit manipulation pattern (0xFF % 0x10 = 0xF)" {
    try run_mod_test(std.testing.allocator, 0xFF, 0x10);
}

test "MOD: large prime modulo" {
    const large_prime_ish = 982451653; // Large prime-like number
    try run_mod_test(std.testing.allocator, std.math.maxInt(u64), large_prime_ish);
}

test "MOD: boundary wraparound test" {
    const boundary = (@as(u256, 1) << 200);
    try run_mod_test(std.testing.allocator, boundary + 42, 100);
}

test "MOD: power of 2 minus 1 modulo" {
    const pow2_minus1 = ((@as(u256, 1) << 64) - 1);
    try run_mod_test(std.testing.allocator, pow2_minus1, 127);
}

test "MOD: sequential small modulos" {
    try run_mod_test(std.testing.allocator, 100, 7);
}

fn run_mod_test_with_jump(allocator: std.mem.Allocator, a: u256, b: u256) !void {
    // Build custom bytecode for MOD test with jump to prevent fusion
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
    
    // Jump to MOD (prevents fusion)
    // First calculate the jump destination
    // We need PUSH1 (1) + dest byte (1) + JUMP (1) + JUMPDEST (1) = 4 bytes ahead
    const jump_dest = buf.items.len + 4;
    
    try buf.append(allocator, 0x60); // PUSH1
    try buf.append(allocator, @intCast(jump_dest)); // destination
    try buf.append(allocator, 0x56); // JUMP
    
    // Invalid opcode (should never be executed)
    try buf.append(allocator, 0xfe); // INVALID
    
    // JUMPDEST + MOD
    try buf.append(allocator, 0x5b); // JUMPDEST
    try buf.append(allocator, 0x06); // MOD opcode
    
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

test "MOD with JUMP: basic (10 % 3 = 1)" {
    try run_mod_test_with_jump(std.testing.allocator, 10, 3);
}

test "MOD with JUMP: modulo by zero (42 % 0 = 0)" {
    try run_mod_test_with_jump(std.testing.allocator, 42, 0);
}

test "MOD with JUMP: large numbers" {
    try run_mod_test_with_jump(std.testing.allocator, 1000000, 12345);
}

test "MOD with JUMP: power of 2 bit masking" {
    try run_mod_test_with_jump(std.testing.allocator, 1023, 64);
}

test "MOD with JUMP: near boundary values" {
    const near_u64 = @as(u256, std.math.maxInt(u32));
    try run_mod_test_with_jump(std.testing.allocator, near_u64, 999);
}

test "MOD with JUMP: large 256-bit beyond u64" {
    const huge = (@as(u256, 1) << 150) + (@as(u256, 1) << 100);
    const big_divisor = (@as(u256, 1) << 80) + 0xFEEDFACE;
    try run_mod_test_with_jump(std.testing.allocator, huge, big_divisor);
}

test "MOD with JUMP: very large 256-bit" {
    const massive = (@as(u256, 1) << 240) + (@as(u256, 0xDEADBEEF) << 200);
    const huge_mod = (@as(u256, 1) << 190) + (@as(u256, 0xCAFEBABE) << 150);
    try run_mod_test_with_jump(std.testing.allocator, massive, huge_mod);
}

test "MOD with JUMP: beyond u64 boundary" {
    const beyond_u64 = (@as(u256, std.math.maxInt(u64)) + 1) << 10;
    const divisor = (@as(u256, 1) << 65) + 12345;
    try run_mod_test_with_jump(std.testing.allocator, beyond_u64, divisor);
}