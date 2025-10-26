const std = @import("std");
const primitives = @import("primitives");
const MinimalEvm = @import("minimal_evm.zig").MinimalEvm;
const Hardfork = @import("../eips_and_hardforks/eips.zig").Hardfork;

test "is_precompile returns true for ECRECOVER (0x01)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // ECRECOVER is at address 0x01
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 1;
    const ecrecover_addr = primitives.Address.Address{ .bytes = addr_bytes };

    try std.testing.expect(evm.is_precompile(ecrecover_addr));
}

test "is_precompile returns true for SHA256 (0x02)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // SHA256 is at address 0x02
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 2;
    const sha256_addr = primitives.Address.Address{ .bytes = addr_bytes };

    try std.testing.expect(evm.is_precompile(sha256_addr));
}

test "is_precompile returns true for RIPEMD160 (0x03)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // RIPEMD160 is at address 0x03
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 3;
    const ripemd_addr = primitives.Address.Address{ .bytes = addr_bytes };

    try std.testing.expect(evm.is_precompile(ripemd_addr));
}

test "is_precompile returns true for IDENTITY (0x04)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // IDENTITY is at address 0x04
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 4;
    const identity_addr = primitives.Address.Address{ .bytes = addr_bytes };

    try std.testing.expect(evm.is_precompile(identity_addr));
}

test "is_precompile returns false for non-precompile address" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // Random contract address
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[0] = 0xDE;
    addr_bytes[1] = 0xAD;
    addr_bytes[2] = 0xBE;
    addr_bytes[3] = 0xEF;
    const random_addr = primitives.Address.Address{ .bytes = addr_bytes };

    try std.testing.expect(!evm.is_precompile(random_addr));
}

test "is_precompile returns false for zero address" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    const zero_addr = primitives.ZERO_ADDRESS;
    try std.testing.expect(!evm.is_precompile(zero_addr));
}

test "is_precompile depends on hardfork" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // Set different hardforks and check precompile availability
    // MODEXP (0x05) should be available from Byzantium onwards
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 5;
    const modexp_addr = primitives.Address.Address{ .bytes = addr_bytes };

    // Pre-Byzantium (Homestead) - MODEXP not available
    evm.setHardfork(Hardfork.HOMESTEAD);
    try std.testing.expect(!evm.is_precompile(modexp_addr));

    // Byzantium+ - MODEXP available
    evm.setHardfork(Hardfork.BYZANTIUM);
    try std.testing.expect(evm.is_precompile(modexp_addr));
}

test "inner_call handles precompile IDENTITY (0x04)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // IDENTITY precompile just returns the input
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[19] = 4;
    const identity_addr = primitives.Address.Address{ .bytes = addr_bytes };

    const input = "Hello, World!";
    const gas: u64 = 100000;

    const result = try evm.inner_call(identity_addr, 0, input, gas);

    try std.testing.expect(result.success);
    try std.testing.expectEqualSlices(u8, input, result.output);
}

test "inner_call handles empty account (non-precompile, no code)" {
    const allocator = std.testing.allocator;
    var evm = try MinimalEvm.init(allocator);
    defer evm.deinit();

    // Random address with no code
    var addr_bytes: [20]u8 = [_]u8{0} ** 20;
    addr_bytes[0] = 0xCA;
    addr_bytes[1] = 0xFE;
    const empty_addr = primitives.Address.Address{ .bytes = addr_bytes };

    const input = "test";
    const gas: u64 = 100000;

    const result = try evm.inner_call(empty_addr, 0, input, gas);

    // Should succeed with no output (empty account)
    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 0), result.output.len);
    try std.testing.expectEqual(gas, result.gas_left);
}

// Note: pre_warm_transaction tests removed because the function is private.
// The functionality is tested indirectly through execute() which calls it.
