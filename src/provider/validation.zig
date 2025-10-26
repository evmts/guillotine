const std = @import("std");
const Address = @import("primitives").Address;

pub const ValidationError = error{
    InvalidAddress,
    InvalidBlockNumber,
    InvalidBlockTag,
    InvalidHexString,
    InvalidU256,
    InvalidTransactionHash,
    EmptyString,
    StringTooLong,
    InvalidJson,
    MissingField,
    InvalidFieldType,
    OutOfRange,
};

/// Validate Ethereum address (20 bytes, 0x prefix optional)
pub fn validateAddress(addr_str: []const u8) ValidationError!void {
    if (addr_str.len == 0) return ValidationError.EmptyString;

    const hex = if (std.mem.startsWith(u8, addr_str, "0x"))
        addr_str[2..]
    else
        addr_str;

    if (hex.len != 40) return ValidationError.InvalidAddress;

    for (hex) |c| {
        if (!std.ascii.isHex(c)) {
            return ValidationError.InvalidAddress;
        }
    }
}

/// Validate block tag (latest, earliest, pending, or hex number)
pub fn validateBlockTag(tag: []const u8) ValidationError!void {
    if (tag.len == 0) return ValidationError.EmptyString;

    if (std.mem.eql(u8, tag, "latest") or
        std.mem.eql(u8, tag, "earliest") or
        std.mem.eql(u8, tag, "pending") or
        std.mem.eql(u8, tag, "safe") or
        std.mem.eql(u8, tag, "finalized"))
    {
        return;
    }

    return validateHexNumber(tag);
}

/// Validate hex number string
pub fn validateHexNumber(hex_str: []const u8) ValidationError!void {
    if (hex_str.len == 0) return ValidationError.EmptyString;

    const hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    if (hex.len == 0) return ValidationError.InvalidHexString;
    if (hex.len > 64) return ValidationError.StringTooLong;

    for (hex) |c| {
        if (!std.ascii.isHex(c)) {
            return ValidationError.InvalidHexString;
        }
    }
}

/// Validate transaction hash (32 bytes, 64 hex chars)
pub fn validateTransactionHash(hash: []const u8) ValidationError!void {
    if (hash.len == 0) return ValidationError.EmptyString;

    const hex = if (std.mem.startsWith(u8, hash, "0x"))
        hash[2..]
    else
        hash;

    if (hex.len != 64) return ValidationError.InvalidTransactionHash;

    for (hex) |c| {
        if (!std.ascii.isHex(c)) {
            return ValidationError.InvalidTransactionHash;
        }
    }
}

/// Validate u64 is within reasonable range for block number
pub fn validateBlockNumber(block_num: u64) ValidationError!void {
    const MAX_REASONABLE_BLOCK = 1_000_000_000;
    if (block_num > MAX_REASONABLE_BLOCK) {
        return ValidationError.OutOfRange;
    }
}

/// Parse and validate hex string to u64
pub fn parseHexU64(hex_str: []const u8) ValidationError!u64 {
    const trimmed = std.mem.trim(u8, hex_str, "\"");
    try validateHexNumber(trimmed);

    const hex = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;

    return std.fmt.parseInt(u64, hex, 16) catch ValidationError.InvalidHexString;
}

/// Parse and validate hex string to u256
pub fn parseHexU256(hex_str: []const u8) ValidationError!u256 {
    const trimmed = std.mem.trim(u8, hex_str, "\"");
    try validateHexNumber(trimmed);

    const hex = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;

    return std.fmt.parseInt(u256, hex, 16) catch ValidationError.InvalidU256;
}

/// Validate JSON response has required field
pub fn validateJsonField(parsed: std.json.Value, field_name: []const u8) ValidationError!std.json.Value {
    const obj = switch (parsed) {
        .object => |o| o,
        else => return ValidationError.InvalidJson,
    };

    return obj.get(field_name) orelse ValidationError.MissingField;
}

/// Validate JSON field is string type
pub fn validateJsonString(value: std.json.Value) ValidationError![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => ValidationError.InvalidFieldType,
    };
}

/// Validate JSON field is number type
pub fn validateJsonNumber(value: std.json.Value) ValidationError!i64 {
    return switch (value) {
        .integer => |i| i,
        else => ValidationError.InvalidFieldType,
    };
}

test "validateAddress - valid addresses" {
    try validateAddress("0x742d35Cc6634C0532925a3b844Bc454e4438f44e");
    try validateAddress("742d35Cc6634C0532925a3b844Bc454e4438f44e");
    try validateAddress("0x0000000000000000000000000000000000000000");
}

test "validateAddress - invalid addresses" {
    try std.testing.expectError(ValidationError.EmptyString, validateAddress(""));
    try std.testing.expectError(ValidationError.InvalidAddress, validateAddress("0x123"));
    try std.testing.expectError(ValidationError.InvalidAddress, validateAddress("0x742d35Cc6634C0532925a3b844Bc454e4438f44g"));
    try std.testing.expectError(ValidationError.InvalidAddress, validateAddress("not_hex"));
}

test "validateBlockTag - valid tags" {
    try validateBlockTag("latest");
    try validateBlockTag("earliest");
    try validateBlockTag("pending");
    try validateBlockTag("safe");
    try validateBlockTag("finalized");
    try validateBlockTag("0x0");
    try validateBlockTag("0x123");
    try validateBlockTag("0xabcdef");
}

test "validateBlockTag - invalid tags" {
    try std.testing.expectError(ValidationError.EmptyString, validateBlockTag(""));
    try std.testing.expectError(ValidationError.InvalidHexString, validateBlockTag("invalid"));
    try std.testing.expectError(ValidationError.InvalidHexString, validateBlockTag("0xGGG"));
}

test "validateHexNumber - valid hex" {
    try validateHexNumber("0x0");
    try validateHexNumber("0x123");
    try validateHexNumber("0xabcdef");
    try validateHexNumber("0xABCDEF");
    try validateHexNumber("123");
    try validateHexNumber("abcdef");
}

test "validateHexNumber - invalid hex" {
    try std.testing.expectError(ValidationError.EmptyString, validateHexNumber(""));
    try std.testing.expectError(ValidationError.InvalidHexString, validateHexNumber("0x"));
    try std.testing.expectError(ValidationError.InvalidHexString, validateHexNumber("0xGGG"));
    try std.testing.expectError(ValidationError.InvalidHexString, validateHexNumber("not_hex"));
    try std.testing.expectError(ValidationError.StringTooLong, validateHexNumber("0x" ++ "0" ** 65));
}

test "validateTransactionHash - valid hashes" {
    const valid_hash = "0x" ++ "a" ** 64;
    try validateTransactionHash(valid_hash);
    try validateTransactionHash(valid_hash[2..]);
}

test "validateTransactionHash - invalid hashes" {
    try std.testing.expectError(ValidationError.EmptyString, validateTransactionHash(""));
    try std.testing.expectError(ValidationError.InvalidTransactionHash, validateTransactionHash("0x123"));
    try std.testing.expectError(ValidationError.InvalidTransactionHash, validateTransactionHash("0x" ++ "a" ** 63));
    try std.testing.expectError(ValidationError.InvalidTransactionHash, validateTransactionHash("0x" ++ "g" ** 64));
}

test "validateBlockNumber - valid block numbers" {
    try validateBlockNumber(0);
    try validateBlockNumber(1);
    try validateBlockNumber(1_000_000);
    try validateBlockNumber(999_999_999);
}

test "validateBlockNumber - invalid block numbers" {
    try std.testing.expectError(ValidationError.OutOfRange, validateBlockNumber(1_000_000_001));
    try std.testing.expectError(ValidationError.OutOfRange, validateBlockNumber(std.math.maxInt(u64)));
}

test "parseHexU64 - valid parsing" {
    try std.testing.expectEqual(@as(u64, 0), try parseHexU64("0x0"));
    try std.testing.expectEqual(@as(u64, 1), try parseHexU64("0x1"));
    try std.testing.expectEqual(@as(u64, 255), try parseHexU64("0xff"));
    try std.testing.expectEqual(@as(u64, 255), try parseHexU64("0xFF"));
    try std.testing.expectEqual(@as(u64, 256), try parseHexU64("0x100"));
    try std.testing.expectEqual(@as(u64, 1337), try parseHexU64("\"0x539\""));
}

test "parseHexU64 - invalid parsing" {
    try std.testing.expectError(ValidationError.EmptyString, parseHexU64(""));
    try std.testing.expectError(ValidationError.InvalidHexString, parseHexU64("0xGGG"));
    try std.testing.expectError(ValidationError.InvalidHexString, parseHexU64("not_hex"));
}

test "parseHexU256 - valid parsing" {
    try std.testing.expectEqual(@as(u256, 0), try parseHexU256("0x0"));
    try std.testing.expectEqual(@as(u256, 1), try parseHexU256("0x1"));
    try std.testing.expectEqual(@as(u256, 255), try parseHexU256("0xff"));
}

test "parseHexU256 - invalid parsing" {
    try std.testing.expectError(ValidationError.EmptyString, parseHexU256(""));
    try std.testing.expectError(ValidationError.InvalidHexString, parseHexU256("0xGGG"));
}

test "validateJsonField - valid field" {
    const allocator = std.testing.allocator;
    const json_str = "{\"test\":\"value\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    _ = try validateJsonField(parsed.value, "test");
}

test "validateJsonField - missing field" {
    const allocator = std.testing.allocator;
    const json_str = "{\"test\":\"value\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expectError(ValidationError.MissingField, validateJsonField(parsed.value, "missing"));
}

test "validateJsonString - valid string" {
    const value = std.json.Value{ .string = "test" };
    const result = try validateJsonString(value);
    try std.testing.expectEqualStrings("test", result);
}

test "validateJsonString - invalid type" {
    const value = std.json.Value{ .integer = 123 };
    try std.testing.expectError(ValidationError.InvalidFieldType, validateJsonString(value));
}

test "validateJsonNumber - valid number" {
    const value = std.json.Value{ .integer = 123 };
    const result = try validateJsonNumber(value);
    try std.testing.expectEqual(@as(i64, 123), result);
}

test "validateJsonNumber - invalid type" {
    const value = std.json.Value{ .string = "not_a_number" };
    try std.testing.expectError(ValidationError.InvalidFieldType, validateJsonNumber(value));
}
