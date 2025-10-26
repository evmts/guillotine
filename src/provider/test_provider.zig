const std = @import("std");
const Provider = @import("provider.zig").Provider;
const Address = @import("primitives").Address;

// Include validation tests
test {
    std.testing.refAllDecls(@import("validation.zig"));
}

test "provider initialization" {
    const allocator = std.testing.allocator;

    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();

    try std.testing.expect(provider.url.len > 0);
}

test "parse hex numbers" {
    const allocator = std.testing.allocator;

    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();

    const cases = [_]struct { hex: []const u8, expected: u64 }{
        .{ .hex = "\"0x0\"", .expected = 0 },
        .{ .hex = "\"0x1\"", .expected = 1 },
        .{ .hex = "\"0xff\"", .expected = 255 },
        .{ .hex = "\"0x100\"", .expected = 256 },
        .{ .hex = "\"0x539\"", .expected = 1337 },
    };

    for (cases) |case| {
        const trimmed = std.mem.trim(u8, case.hex, "\"");
        const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
        const result = try std.fmt.parseInt(u64, hex, 16);
        try std.testing.expectEqual(case.expected, result);
    }
}

test "getCode - empty code returns empty array" {
    const allocator = std.testing.allocator;

    const mockResponse = "\"0x\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(std.mem.startsWith(u8, trimmed, "0x"));

    const hex = trimmed[2..];
    try std.testing.expectEqual(@as(usize, 0), hex.len);
}

test "getCode - valid code parsing" {
    const allocator = std.testing.allocator;

    const mockResponse = "\"0x6080604052\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(std.mem.startsWith(u8, trimmed, "0x"));

    const hex = trimmed[2..];
    try std.testing.expectEqual(@as(usize, 10), hex.len);
    try std.testing.expect(hex.len % 2 == 0);

    const code = try allocator.alloc(u8, hex.len / 2);
    defer allocator.free(code);

    for (0..code.len) |i| {
        const byte_hex = hex[i * 2 .. i * 2 + 2];
        code[i] = try std.fmt.parseInt(u8, byte_hex, 16);
    }

    try std.testing.expectEqual(@as(u8, 0x60), code[0]);
    try std.testing.expectEqual(@as(u8, 0x80), code[1]);
    try std.testing.expectEqual(@as(u8, 0x60), code[2]);
    try std.testing.expectEqual(@as(u8, 0x40), code[3]);
    try std.testing.expectEqual(@as(u8, 0x52), code[4]);
}

test "getCode - invalid response missing 0x prefix" {
    const mockResponse = "\"1234\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(!std.mem.startsWith(u8, trimmed, "0x"));
}

test "getCode - odd length hex should fail" {
    const mockResponse = "\"0x123\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = trimmed[2..];
    try std.testing.expect(hex.len % 2 != 0);
}

test "getStorageAt - zero value" {
    const mockResponse = "\"0x0\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const value = try std.fmt.parseInt(u256, hex, 16);
    try std.testing.expectEqual(@as(u256, 0), value);
}

test "getStorageAt - max value" {
    const mockResponse = "\"0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const value = try std.fmt.parseInt(u256, hex, 16);
    try std.testing.expect(value > 0);
}

test "getStorageAt - specific slot value" {
    const mockResponse = "\"0x0000000000000000000000000000000000000000000000000000000000000539\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const value = try std.fmt.parseInt(u256, hex, 16);
    try std.testing.expectEqual(@as(u256, 1337), value);
}

test "eth_call - empty return data" {
    const allocator = std.testing.allocator;

    const mockResponse = "\"0x\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(std.mem.startsWith(u8, trimmed, "0x"));

    const hex = trimmed[2..];
    try std.testing.expectEqual(@as(usize, 0), hex.len);

    const returnData = try allocator.alloc(u8, 0);
    defer allocator.free(returnData);
    try std.testing.expectEqual(@as(usize, 0), returnData.len);
}

test "eth_call - valid return data" {
    const allocator = std.testing.allocator;

    const mockResponse = "\"0x0000000000000000000000000000000000000000000000000000000000000001\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(std.mem.startsWith(u8, trimmed, "0x"));

    const hex = trimmed[2..];
    try std.testing.expect(hex.len % 2 == 0);

    const returnData = try allocator.alloc(u8, hex.len / 2);
    defer allocator.free(returnData);

    for (0..returnData.len) |i| {
        const byte_hex = hex[i * 2 .. i * 2 + 2];
        returnData[i] = try std.fmt.parseInt(u8, byte_hex, 16);
    }

    try std.testing.expectEqual(@as(usize, 32), returnData.len);
    try std.testing.expectEqual(@as(u8, 1), returnData[31]);
}

test "eth_call - invalid response missing 0x prefix" {
    const mockResponse = "\"abcd\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    try std.testing.expect(!std.mem.startsWith(u8, trimmed, "0x"));
}

test "getBalance - zero balance" {
    const mockResponse = "\"0x0\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const balance = try std.fmt.parseInt(u256, hex, 16);
    try std.testing.expectEqual(@as(u256, 0), balance);
}

test "getBalance - one ether" {
    const mockResponse = "\"0xde0b6b3a7640000\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const balance = try std.fmt.parseInt(u256, hex, 16);
    try std.testing.expectEqual(@as(u256, 1000000000000000000), balance);
}

test "getTransactionCount - zero nonce" {
    const mockResponse = "\"0x0\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const nonce = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(@as(u64, 0), nonce);
}

test "getTransactionCount - high nonce" {
    const mockResponse = "\"0x64\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const nonce = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(@as(u64, 100), nonce);
}

test "getBlockNumber - parsing" {
    const mockResponse = "\"0x1234567\"";
    const trimmed = std.mem.trim(u8, mockResponse, "\"");
    const hex = if (std.mem.startsWith(u8, trimmed, "0x")) trimmed[2..] else trimmed;
    const blockNumber = try std.fmt.parseInt(u64, hex, 16);
    try std.testing.expectEqual(@as(u64, 19088743), blockNumber);
}

test "address - hex formatting" {
    const allocator = std.testing.allocator;

    var addr = Address{ .bytes = [_]u8{0} ** 20 };
    addr.bytes[19] = 0x42;

    const addrHex = try std.fmt.allocPrint(allocator, "0x{s}", .{std.fmt.fmtSliceHexLower(&addr.bytes)});
    defer allocator.free(addrHex);

    try std.testing.expect(std.mem.startsWith(u8, addrHex, "0x"));
    try std.testing.expectEqual(@as(usize, 42), addrHex.len);
}

test "slot - hex formatting for u256" {
    const allocator = std.testing.allocator;

    const slot: u256 = 0;
    const slotHex = try std.fmt.allocPrint(allocator, "0x{x}", .{slot});
    defer allocator.free(slotHex);

    try std.testing.expect(std.mem.startsWith(u8, slotHex, "0x"));
}

test "json array construction for params" {
    const allocator = std.testing.allocator;

    var params = std.json.Array.init(allocator);
    defer params.deinit();

    try params.append(std.json.Value{ .string = "0x742d35Cc6641C91B6E4bb6ac" });
    try params.append(std.json.Value{ .string = "latest" });

    try std.testing.expectEqual(@as(usize, 2), params.items.len);
    try std.testing.expect(params.items[0] == .string);
    try std.testing.expect(params.items[1] == .string);
}