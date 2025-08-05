//! JSON Parsing Utilities - Ethereum JSON-RPC data format parsing
//!
//! Provides robust parsing functions for converting Ethereum JSON-RPC
//! hex-encoded data to native Zig types with comprehensive error handling.
//!
//! ## Ethereum Hex Encoding Standards
//! - Quantities: "0x" + hex digits, no leading zeros except "0x0"
//! - Data: "0x" + even number of hex digits
//! - Addresses: "0x" + exactly 40 hex digits (20 bytes)
//! - Hashes: "0x" + exactly 64 hex digits (32 bytes)
//!
//! ## Error Handling
//! All parsing functions return detailed errors for:
//! - Missing "0x" prefix
//! - Invalid hex characters
//! - Incorrect data length
//! - Numeric overflow
//!
//! ## Usage Example
//! ```zig
//! const value = try parseHexU64("0x1a2b3c");
//! const hash = try parseHexHash("0x1234...5678");
//! const data = try parseHexBytes(allocator, "0xdeadbeef");
//! defer allocator.free(data);
//! ```

const std = @import("std");
const testing = std.testing;
const Address = @import("address.zig").Address;
const crypto_pkg = @import("crypto");
const Hash = crypto_pkg.Hash;
const Allocator = std.mem.Allocator;

/// Errors that can occur during JSON parsing
pub const JsonParseError = error{
    InvalidHexPrefix,
    InvalidHexCharacter,
    InvalidLength,
    NumericOverflow,
    EmptyString,
    OutOfMemory,
};

/// Parse hex string to u8 value
pub fn parseHexU8(hex_str: []const u8) JsonParseError!u8 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    if (hex_part.len == 0) {
        return JsonParseError.EmptyString;
    }
    
    // Handle "0x0" special case
    if (std.mem.eql(u8, hex_part, "0")) {
        return 0;
    }
    
    // Parse hex digits
    var result: u8 = 0;
    for (hex_part) |c| {
        const digit = parseHexDigit(c) catch return JsonParseError.InvalidHexCharacter;
        if (result > (std.math.maxInt(u8) - digit) / 16) {
            return JsonParseError.NumericOverflow;
        }
        result = result * 16 + digit;
    }
    
    return result;
}

/// Parse hex string to u16 value
pub fn parseHexU16(hex_str: []const u8) JsonParseError!u16 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    if (hex_part.len == 0) {
        return JsonParseError.EmptyString;
    }
    
    if (std.mem.eql(u8, hex_part, "0")) {
        return 0;
    }
    
    var result: u16 = 0;
    for (hex_part) |c| {
        const digit = parseHexDigit(c) catch return JsonParseError.InvalidHexCharacter;
        if (result > (std.math.maxInt(u16) - digit) / 16) {
            return JsonParseError.NumericOverflow;
        }
        result = result * 16 + digit;
    }
    
    return result;
}

/// Parse hex string to u32 value
pub fn parseHexU32(hex_str: []const u8) JsonParseError!u32 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    if (hex_part.len == 0) {
        return JsonParseError.EmptyString;
    }
    
    if (std.mem.eql(u8, hex_part, "0")) {
        return 0;
    }
    
    var result: u32 = 0;
    for (hex_part) |c| {
        const digit = parseHexDigit(c) catch return JsonParseError.InvalidHexCharacter;
        if (result > (std.math.maxInt(u32) - digit) / 16) {
            return JsonParseError.NumericOverflow;
        }
        result = result * 16 + digit;
    }
    
    return result;
}

/// Parse hex string to u64 value
pub fn parseHexU64(hex_str: []const u8) JsonParseError!u64 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    if (hex_part.len == 0) {
        return JsonParseError.EmptyString;
    }
    
    if (std.mem.eql(u8, hex_part, "0")) {
        return 0;
    }
    
    var result: u64 = 0;
    for (hex_part) |c| {
        const digit = parseHexDigit(c) catch return JsonParseError.InvalidHexCharacter;
        if (result > (std.math.maxInt(u64) - digit) / 16) {
            return JsonParseError.NumericOverflow;
        }
        result = result * 16 + digit;
    }
    
    return result;
}

/// Parse hex string to u256 value
pub fn parseHexU256(hex_str: []const u8) JsonParseError!u256 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    if (hex_part.len == 0) {
        return JsonParseError.EmptyString;
    }
    
    if (std.mem.eql(u8, hex_part, "0")) {
        return 0;
    }
    
    // For u256, we need to be more careful about overflow
    if (hex_part.len > 64) { // 256 bits = 64 hex digits max
        return JsonParseError.NumericOverflow;
    }
    
    var result: u256 = 0;
    for (hex_part) |c| {
        const digit = parseHexDigit(c) catch return JsonParseError.InvalidHexCharacter;
        // Check for overflow before multiplication
        if (result > (std.math.maxInt(u256) - digit) / 16) {
            return JsonParseError.NumericOverflow;
        }
        result = result * 16 + digit;
    }
    
    return result;
}

/// Parse hex string to byte array (caller owns returned memory)
pub fn parseHexBytes(allocator: Allocator, hex_str: []const u8) JsonParseError![]u8 {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    
    // Handle empty data "0x"
    if (hex_part.len == 0) {
        return try allocator.alloc(u8, 0);
    }
    
    // Hex data must have even number of characters
    if (hex_part.len % 2 != 0) {
        return JsonParseError.InvalidLength;
    }
    
    const byte_count = hex_part.len / 2;
    var result = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(result);
    
    var i: usize = 0;
    while (i < hex_part.len) : (i += 2) {
        const high = parseHexDigit(hex_part[i]) catch return JsonParseError.InvalidHexCharacter;
        const low = parseHexDigit(hex_part[i + 1]) catch return JsonParseError.InvalidHexCharacter;
        result[i / 2] = (high << 4) | low;
    }
    
    return result;
}

/// Parse hex string to 32-byte hash
pub fn parseHexHash(hex_str: []const u8) JsonParseError!Hash {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    
    // Hash must be exactly 64 hex characters (32 bytes)
    if (hex_part.len != 64) {
        return JsonParseError.InvalidLength;
    }
    
    var hash_bytes: [32]u8 = undefined;
    
    var i: usize = 0;
    while (i < hex_part.len) : (i += 2) {
        const high = parseHexDigit(hex_part[i]) catch return JsonParseError.InvalidHexCharacter;
        const low = parseHexDigit(hex_part[i + 1]) catch return JsonParseError.InvalidHexCharacter;
        hash_bytes[i / 2] = (high << 4) | low;
    }
    
    return Hash{ .bytes = hash_bytes };
}

/// Parse hex string to 20-byte address
pub fn parseHexAddress(hex_str: []const u8) JsonParseError!Address {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return JsonParseError.InvalidHexPrefix;
    }
    
    const hex_part = hex_str[2..];
    
    // Address must be exactly 40 hex characters (20 bytes)
    if (hex_part.len != 40) {
        return JsonParseError.InvalidLength;
    }
    
    var addr_bytes: [20]u8 = undefined;
    
    var i: usize = 0;
    while (i < hex_part.len) : (i += 2) {
        const high = parseHexDigit(hex_part[i]) catch return JsonParseError.InvalidHexCharacter;
        const low = parseHexDigit(hex_part[i + 1]) catch return JsonParseError.InvalidHexCharacter;
        addr_bytes[i / 2] = (high << 4) | low;
    }
    
    return Address{ .bytes = addr_bytes };
}

/// Parse optional hex u64 (returns null for JSON null)
pub fn parseOptionalHexU64(hex_str: ?[]const u8) JsonParseError!?u64 {
    if (hex_str == null) return null;
    return try parseHexU64(hex_str.?);
}

/// Parse optional hex bytes (returns null for JSON null)
pub fn parseOptionalHexBytes(allocator: Allocator, hex_str: ?[]const u8) JsonParseError!?[]u8 {
    if (hex_str == null) return null;
    return try parseHexBytes(allocator, hex_str.?);
}

/// Parse optional hex address (returns null for JSON null)
pub fn parseOptionalHexAddress(hex_str: ?[]const u8) JsonParseError!?Address {
    if (hex_str == null) return null;
    return try parseHexAddress(hex_str.?);
}

/// Helper function to parse a single hex digit
fn parseHexDigit(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHexCharacter,
    };
}

/// Validate hex string format without parsing
pub fn validateHexString(hex_str: []const u8, expected_byte_length: ?usize) bool {
    if (hex_str.len < 2 or !std.mem.startsWith(u8, hex_str, "0x")) {
        return false;
    }
    
    const hex_part = hex_str[2..];
    
    // Check expected length if specified
    if (expected_byte_length) |expected| {
        if (hex_part.len != expected * 2) {
            return false;
        }
    } else {
        // For quantities, must have even length (except "0x0")
        if (hex_part.len % 2 != 0 and !std.mem.eql(u8, hex_part, "0")) {
            return false;
        }
    }
    
    // Validate all characters are hex digits
    for (hex_part) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    
    return true;
}

test "parseHexU8 valid values" {
    try testing.expectEqual(@as(u8, 0), try parseHexU8("0x0"));
    try testing.expectEqual(@as(u8, 1), try parseHexU8("0x1"));
    try testing.expectEqual(@as(u8, 15), try parseHexU8("0xf"));
    try testing.expectEqual(@as(u8, 15), try parseHexU8("0xF"));
    try testing.expectEqual(@as(u8, 255), try parseHexU8("0xff"));
    try testing.expectEqual(@as(u8, 255), try parseHexU8("0xFF"));
    try testing.expectEqual(@as(u8, 171), try parseHexU8("0xab"));
    try testing.expectEqual(@as(u8, 171), try parseHexU8("0xAB"));
}

test "parseHexU8 error cases" {
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexU8("ff"));
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexU8("x0"));
    try testing.expectError(JsonParseError.EmptyString, parseHexU8("0x"));
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexU8("0xgg"));
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexU8("0x1z"));
    try testing.expectError(JsonParseError.NumericOverflow, parseHexU8("0x100"));
    try testing.expectError(JsonParseError.NumericOverflow, parseHexU8("0xfff"));
}

test "parseHexU64 valid values" {
    try testing.expectEqual(@as(u64, 0), try parseHexU64("0x0"));
    try testing.expectEqual(@as(u64, 1), try parseHexU64("0x1"));
    try testing.expectEqual(@as(u64, 4095), try parseHexU64("0xfff"));
    try testing.expectEqual(@as(u64, 1000000), try parseHexU64("0xf4240"));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), try parseHexU64("0xffffffffffffffff"));
}

test "parseHexU64 error cases" {
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexU64("123"));
    try testing.expectError(JsonParseError.EmptyString, parseHexU64("0x"));
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexU64("0x123g"));
    try testing.expectError(JsonParseError.NumericOverflow, parseHexU64("0x10000000000000000"));
}

test "parseHexU256 valid values" {
    try testing.expectEqual(@as(u256, 0), try parseHexU256("0x0"));
    try testing.expectEqual(@as(u256, 1), try parseHexU256("0x1"));
    try testing.expectEqual(@as(u256, 1000000000000000000), try parseHexU256("0xde0b6b3a7640000"));
    
    // Test maximum u256 value
    const max_u256_hex = "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try testing.expectEqual(std.math.maxInt(u256), try parseHexU256(max_u256_hex));
}

test "parseHexU256 error cases" {
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexU256("123"));
    try testing.expectError(JsonParseError.EmptyString, parseHexU256("0x"));
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexU256("0x123g"));
    
    // Test overflow (more than 64 hex digits)
    const too_long = "0x1ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    try testing.expectError(JsonParseError.NumericOverflow, parseHexU256(too_long));
}

test "parseHexBytes valid data" {
    const allocator = testing.allocator;
    
    // Empty data
    const empty = try parseHexBytes(allocator, "0x");
    defer allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    
    // Single byte
    const single = try parseHexBytes(allocator, "0xff");
    defer allocator.free(single);
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqual(@as(u8, 0xff), single[0]);
    
    // Multiple bytes
    const multi = try parseHexBytes(allocator, "0xdeadbeef");
    defer allocator.free(multi);
    try testing.expectEqual(@as(usize, 4), multi.len);
    try testing.expectEqual(@as(u8, 0xde), multi[0]);
    try testing.expectEqual(@as(u8, 0xad), multi[1]);
    try testing.expectEqual(@as(u8, 0xbe), multi[2]);
    try testing.expectEqual(@as(u8, 0xef), multi[3]);
    
    // Mixed case
    const mixed = try parseHexBytes(allocator, "0xAbCdEf");
    defer allocator.free(mixed);
    try testing.expectEqual(@as(usize, 3), mixed.len);
    try testing.expectEqual(@as(u8, 0xab), mixed[0]);
    try testing.expectEqual(@as(u8, 0xcd), mixed[1]);
    try testing.expectEqual(@as(u8, 0xef), mixed[2]);
}

test "parseHexBytes error cases" {
    const allocator = testing.allocator;
    
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexBytes(allocator, "deadbeef"));
    try testing.expectError(JsonParseError.InvalidLength, parseHexBytes(allocator, "0xf")); // Odd length
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexBytes(allocator, "0xgg"));
}

test "parseHexHash valid hashes" {
    // Zero hash
    const zero_hash_str = "0x0000000000000000000000000000000000000000000000000000000000000000";
    const zero_hash = try parseHexHash(zero_hash_str);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 32, &zero_hash.bytes);
    
    // Non-zero hash
    const hash_str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    const hash = try parseHexHash(hash_str);
    const expected = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
    };
    try testing.expectEqualSlices(u8, &expected, &hash.bytes);
}

test "parseHexHash error cases" {
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexHash("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"));
    try testing.expectError(JsonParseError.InvalidLength, parseHexHash("0x123")); // Too short
    try testing.expectError(JsonParseError.InvalidLength, parseHexHash("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef00")); // Too long
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexHash("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdeg"));
}

test "parseHexAddress valid addresses" {
    // Zero address
    const zero_addr_str = "0x0000000000000000000000000000000000000000";
    const zero_addr = try parseHexAddress(zero_addr_str);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 20, &zero_addr.bytes);
    
    // Non-zero address
    const addr_str = "0x742d35Cc6634C0532925a3b844Bc9e7595f6E97b";
    const addr = try parseHexAddress(addr_str);
    const expected = [_]u8{
        0x74, 0x2d, 0x35, 0xcc, 0x66, 0x34, 0xc0, 0x53,
        0x29, 0x25, 0xa3, 0xb8, 0x44, 0xbc, 0x9e, 0x75,
        0x95, 0xf6, 0xe9, 0x7b,
    };
    try testing.expectEqualSlices(u8, &expected, &addr.bytes);
}

test "parseHexAddress error cases" {
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseHexAddress("742d35Cc6634C0532925a3b844Bc9e7595f6E97b"));
    try testing.expectError(JsonParseError.InvalidLength, parseHexAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f6E97")); // Too short
    try testing.expectError(JsonParseError.InvalidLength, parseHexAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f6E97b00")); // Too long
    try testing.expectError(JsonParseError.InvalidHexCharacter, parseHexAddress("0x742d35Cc6634C0532925a3b844Bc9e7595f6E97g"));
}

test "parseOptionalHexU64 with null and valid values" {
    // Test null case
    const null_result = try parseOptionalHexU64(null);
    try testing.expect(null_result == null);
    
    // Test valid case
    const valid_result = try parseOptionalHexU64("0x1234");
    try testing.expect(valid_result != null);
    try testing.expectEqual(@as(u64, 0x1234), valid_result.?);
    
    // Test error case
    try testing.expectError(JsonParseError.InvalidHexPrefix, parseOptionalHexU64("1234"));
}

test "parseOptionalHexBytes with null and valid values" {
    const allocator = testing.allocator;
    
    // Test null case
    const null_result = try parseOptionalHexBytes(allocator, null);
    try testing.expect(null_result == null);
    
    // Test valid case
    const valid_result = try parseOptionalHexBytes(allocator, "0xdeadbeef");
    try testing.expect(valid_result != null);
    defer allocator.free(valid_result.?);
    try testing.expectEqual(@as(usize, 4), valid_result.?.len);
    try testing.expectEqual(@as(u8, 0xde), valid_result.?[0]);
}

test "validateHexString format validation" {
    // Valid formats
    try testing.expect(validateHexString("0x0", null));
    try testing.expect(validateHexString("0x123", null));
    try testing.expect(validateHexString("0xabcdef", null));
    try testing.expect(validateHexString("0xABCDEF", null));
    
    // Valid with expected length
    try testing.expect(validateHexString("0xdeadbeef", 4)); // 4 bytes = 8 hex digits
    try testing.expect(validateHexString("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef", 32)); // 32 bytes
    
    // Invalid formats
    try testing.expect(!validateHexString("123", null)); // No prefix
    try testing.expect(!validateHexString("0x", null)); // Empty
    try testing.expect(!validateHexString("0xgg", null)); // Invalid character
    try testing.expect(!validateHexString("0x123g", null)); // Invalid character
    
    // Invalid lengths
    try testing.expect(!validateHexString("0xdeadbeef", 3)); // Wrong length
    try testing.expect(!validateHexString("0xdeadbeef", 5)); // Wrong length
}

test "hex parsing edge cases" {
    // Test leading zeros (should be valid)
    try testing.expectEqual(@as(u64, 1), try parseHexU64("0x01"));
    try testing.expectEqual(@as(u64, 1), try parseHexU64("0x001"));
    try testing.expectEqual(@as(u64, 1), try parseHexU64("0x0001"));
    
    // Test case insensitivity
    try testing.expectEqual(@as(u64, 0xabcdef), try parseHexU64("0xabcdef"));
    try testing.expectEqual(@as(u64, 0xabcdef), try parseHexU64("0xABCDEF"));
    try testing.expectEqual(@as(u64, 0xabcdef), try parseHexU64("0xAbCdEf"));
    
    // Test boundary values
    try testing.expectEqual(@as(u8, 0), try parseHexU8("0x0"));
    try testing.expectEqual(@as(u8, 255), try parseHexU8("0xff"));
    try testing.expectEqual(@as(u16, 0), try parseHexU16("0x0"));
    try testing.expectEqual(@as(u16, 65535), try parseHexU16("0xffff"));
}