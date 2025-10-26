const std = @import("std");
const validation = @import("validation.zig");
const Provider = @import("provider.zig").Provider;
const Address = @import("primitives").Address;

test "provider - reject empty URL" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidResponse, Provider.init(allocator, ""));
}

test "provider - accept valid URL" {
    const allocator = std.testing.allocator;
    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();
    try std.testing.expect(provider.url.len > 0);
}

test "provider - reject empty method in request" {
    const allocator = std.testing.allocator;
    var provider = try Provider.init(allocator, "https://eth.llamarpc.com");
    defer provider.deinit();

    try std.testing.expectError(error.InvalidResponse, provider.request("", null));
}

test "validation - edge case block number zero" {
    try validation.validateBlockNumber(0);
}

test "validation - edge case max reasonable block" {
    try validation.validateBlockNumber(999_999_999);
}

test "validation - reject block number above max" {
    try std.testing.expectError(validation.ValidationError.OutOfRange, validation.validateBlockNumber(1_000_000_001));
}

test "validation - accept all standard block tags" {
    try validation.validateBlockTag("latest");
    try validation.validateBlockTag("earliest");
    try validation.validateBlockTag("pending");
    try validation.validateBlockTag("safe");
    try validation.validateBlockTag("finalized");
}

test "validation - accept block tag as hex number" {
    try validation.validateBlockTag("0x0");
    try validation.validateBlockTag("0x1");
    try validation.validateBlockTag("0xFFFFFFFF");
}

test "validation - reject invalid block tags" {
    try std.testing.expectError(validation.ValidationError.InvalidHexString, validation.validateBlockTag("invalid"));
    try std.testing.expectError(validation.ValidationError.InvalidHexString, validation.validateBlockTag("0xGGG"));
    try std.testing.expectError(validation.ValidationError.EmptyString, validation.validateBlockTag(""));
}

test "validation - address with 0x prefix" {
    try validation.validateAddress("0x742d35Cc6634C0532925a3b844Bc454e4438f44e");
}

test "validation - address without 0x prefix" {
    try validation.validateAddress("742d35Cc6634C0532925a3b844Bc454e4438f44e");
}

test "validation - reject short address" {
    try std.testing.expectError(validation.ValidationError.InvalidAddress, validation.validateAddress("0x123"));
}

test "validation - reject long address" {
    try std.testing.expectError(validation.ValidationError.InvalidAddress, validation.validateAddress("0x742d35Cc6634C0532925a3b844Bc454e4438f44e00"));
}

test "validation - reject address with non-hex characters" {
    try std.testing.expectError(validation.ValidationError.InvalidAddress, validation.validateAddress("0x742d35Cc6634C0532925a3b844Bc454e4438f44g"));
}

test "validation - transaction hash with 0x prefix" {
    const hash = "0x" ++ "a" ** 64;
    try validation.validateTransactionHash(hash);
}

test "validation - transaction hash without 0x prefix" {
    const hash = "a" ** 64;
    try validation.validateTransactionHash(hash);
}

test "validation - reject short transaction hash" {
    const hash = "0x" ++ "a" ** 63;
    try std.testing.expectError(validation.ValidationError.InvalidTransactionHash, validation.validateTransactionHash(hash));
}

test "validation - reject long transaction hash" {
    const hash = "0x" ++ "a" ** 65;
    try std.testing.expectError(validation.ValidationError.InvalidTransactionHash, validation.validateTransactionHash(hash));
}

test "validation - reject transaction hash with non-hex" {
    const hash = "0x" ++ "g" ** 64;
    try std.testing.expectError(validation.ValidationError.InvalidTransactionHash, validation.validateTransactionHash(hash));
}

test "validation - parseHexU64 with quotes" {
    const result = try validation.parseHexU64("\"0x539\"");
    try std.testing.expectEqual(@as(u64, 1337), result);
}

test "validation - parseHexU64 without quotes" {
    const result = try validation.parseHexU64("0x539");
    try std.testing.expectEqual(@as(u64, 1337), result);
}

test "validation - parseHexU64 zero value" {
    const result = try validation.parseHexU64("0x0");
    try std.testing.expectEqual(@as(u64, 0), result);
}

test "validation - parseHexU64 max uint32" {
    const result = try validation.parseHexU64("0xFFFFFFFF");
    try std.testing.expectEqual(@as(u64, 0xFFFFFFFF), result);
}

test "validation - parseHexU256 small value" {
    const result = try validation.parseHexU256("0x1");
    try std.testing.expectEqual(@as(u256, 1), result);
}

test "validation - parseHexU256 zero value" {
    const result = try validation.parseHexU256("0x0");
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "validation - parseHexU256 large value" {
    const result = try validation.parseHexU256("0xFFFFFFFFFFFFFFFF");
    try std.testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), result);
}

test "validation - hex number uppercase" {
    try validation.validateHexNumber("0xABCDEF");
}

test "validation - hex number lowercase" {
    try validation.validateHexNumber("0xabcdef");
}

test "validation - hex number mixed case" {
    try validation.validateHexNumber("0xAbCdEf");
}

test "validation - hex number no prefix" {
    try validation.validateHexNumber("abcdef");
}

test "validation - reject hex number too long" {
    const long_hex = "0x" ++ "0" ** 65;
    try std.testing.expectError(validation.ValidationError.StringTooLong, validation.validateHexNumber(long_hex));
}

test "validation - reject empty hex after prefix" {
    try std.testing.expectError(validation.ValidationError.InvalidHexString, validation.validateHexNumber("0x"));
}

test "validation - reject empty hex string" {
    try std.testing.expectError(validation.ValidationError.EmptyString, validation.validateHexNumber(""));
}

test "validation - JSON field extraction" {
    const allocator = std.testing.allocator;
    const json_str = "{\"result\":\"0x539\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const field = try validation.validateJsonField(parsed.value, "result");
    const value = try validation.validateJsonString(field);
    try std.testing.expectEqualStrings("0x539", value);
}

test "validation - JSON number extraction" {
    const allocator = std.testing.allocator;
    const json_str = "{\"code\":-32600}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const field = try validation.validateJsonField(parsed.value, "code");
    const value = try validation.validateJsonNumber(field);
    try std.testing.expectEqual(@as(i64, -32600), value);
}

test "validation - reject missing JSON field" {
    const allocator = std.testing.allocator;
    const json_str = "{\"result\":\"0x539\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectError(validation.ValidationError.MissingField, validation.validateJsonField(parsed.value, "error"));
}

test "validation - reject wrong JSON type for string" {
    const value = std.json.Value{ .integer = 123 };
    try std.testing.expectError(validation.ValidationError.InvalidFieldType, validation.validateJsonString(value));
}

test "validation - reject wrong JSON type for number" {
    const value = std.json.Value{ .string = "not_a_number" };
    try std.testing.expectError(validation.ValidationError.InvalidFieldType, validation.validateJsonNumber(value));
}
