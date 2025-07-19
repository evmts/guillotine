const std = @import("std");
const crypto = std.crypto;
const testing = std.testing;

// Hash types
pub const Hash = [32]u8;
pub const B256 = Hash;
pub const BlockHash = Hash;
pub const TxHash = Hash;
pub const StorageKey = Hash;
pub const StorageValue = Hash;
pub const Selector = [4]u8;

// Keccak256 implementation
const Keccak256 = crypto.hash.sha3.Keccak256;

// Constants
pub const ZERO_HASH: Hash = [_]u8{0} ** 32;
pub const EMPTY_KECCAK256: Hash = [32]u8{
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
    0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
    0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
};

// Hash creation functions
pub fn zero() Hash {
    return ZERO_HASH;
}

pub fn from_bytes(bytes: [32]u8) Hash {
    return bytes;
}

pub fn from_slice(slice: []const u8) !Hash {
    if (slice.len != 32) return error.InvalidLength;
    var hash: Hash = undefined;
    @memcpy(&hash, slice);
    return hash;
}

pub fn from_hex(hex: []const u8) !Hash {
    if (hex.len < 2 or !std.mem.eql(u8, hex[0..2], "0x"))
        return error.InvalidHexFormat;

    if (hex.len != 66) return error.InvalidHexLength; // 0x + 64 hex chars

    var hash: Hash = undefined;
    _ = std.fmt.hexToBytes(&hash, hex[2..]) catch return error.InvalidHexString;
    return hash;
}

pub fn from_hex_comptime(comptime hex: []const u8) Hash {
    if (hex.len < 2 or !std.mem.eql(u8, hex[0..2], "0x"))
        @compileError("hex must start with '0x'");

    if (hex.len != 66) @compileError("hex must be 66 characters long");

    var hash: Hash = undefined;
    _ = std.fmt.hexToBytes(&hash, hex[2..]) catch @compileError("invalid hex string");
    return hash;
}

// Hash utility functions
pub fn to_hex(hash: Hash) [66]u8 {
    var result: [66]u8 = undefined;
    result[0] = '0';
    result[1] = 'x';
    const hex = std.fmt.bytesToHex(&hash, .lower);
    @memcpy(result[2..], &hex);
    return result;
}

pub fn to_hex_upper(hash: Hash) [66]u8 {
    var result: [66]u8 = undefined;
    result[0] = '0';
    result[1] = 'x';
    const hex = std.fmt.bytesToHex(&hash, .upper);
    @memcpy(result[2..], &hex);
    return result;
}

pub fn is_zero(hash: Hash) bool {
    return std.mem.eql(u8, &hash, &ZERO_HASH);
}

pub fn equal(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}

// Keccak256 hashing functions
pub fn keccak256(data: []const u8) Hash {
    var hash: Hash = undefined;
    Keccak256.hash(data, &hash, .{});
    return hash;
}

pub fn keccak256_empty() Hash {
    return EMPTY_KECCAK256;
}

// EIP-191 message hashing
pub fn eip191_hash_message(message: []const u8, allocator: std.mem.Allocator) !Hash {
    const prefix = "\x19Ethereum Signed Message:\n";
    const length_str = try std.fmt.allocPrint(allocator, "{d}", .{message.len});
    defer allocator.free(length_str);

    const total_len = prefix.len + length_str.len + message.len;
    const full_message = try allocator.alloc(u8, total_len);
    defer allocator.free(full_message);

    @memcpy(full_message[0..prefix.len], prefix);
    @memcpy(full_message[prefix.len .. prefix.len + length_str.len], length_str);
    @memcpy(full_message[prefix.len + length_str.len ..], message);

    return keccak256(full_message);
}

// Selector creation (for function signatures)
pub fn selector_from_signature(signature: []const u8) Selector {
    const hash = keccak256(signature);
    return hash[0..4].*;
}

// Hash comparison and ordering
pub fn compare(a: Hash, b: Hash) std.math.Order {
    return std.mem.order(u8, &a, &b);
}

pub fn less_than(a: Hash, b: Hash) bool {
    return compare(a, b) == .lt;
}

pub fn greater_than(a: Hash, b: Hash) bool {
    return compare(a, b) == .gt;
}

// Hash arithmetic (for Merkle tree operations)
pub fn xor(a: Hash, b: Hash) Hash {
    var result: Hash = undefined;
    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        result[idx] = a[idx] ^ b[idx];
    }
    return result;
}

pub fn bit_and(a: Hash, b: Hash) Hash {
    var result: Hash = undefined;
    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        result[idx] = a[idx] & b[idx];
    }
    return result;
}

pub fn bit_or(a: Hash, b: Hash) Hash {
    var result: Hash = undefined;
    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        result[idx] = a[idx] | b[idx];
    }
    return result;
}

pub fn bit_not(a: Hash) Hash {
    var result: Hash = undefined;
    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        result[idx] = ~a[idx];
    }
    return result;
}

// Hash to/from integer conversion
pub fn to_u256(hash: Hash) u256 {
    var result = @as(u256, 0);
    for (hash) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

pub fn from_u256(value: u256) Hash {
    var hash: Hash = undefined;
    var v = value;
    var i: isize = -32;
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + 32));
        hash[31 - idx] = @truncate(v & 0xFF);
        v >>= 8;
    }
    return hash;
}

// Tests
test "hash creation and conversion" {
    // Test zero hash
    const zero_hash = zero();
    try testing.expect(is_zero(zero_hash));

    // Test from_bytes
    const test_bytes = [_]u8{ 0x12, 0x34 } ++ [_]u8{0} ** 30;
    const hash_from_bytes = from_bytes(test_bytes);
    try testing.expectEqual(test_bytes, hash_from_bytes);

    // Test hex conversion
    const hex_str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    const hash_from_hex = try from_hex(hex_str);
    const hex_result = to_hex(hash_from_hex);
    try testing.expectEqualStrings(hex_str, &hex_result);
}

test "keccak256 hashing" {
    // Test empty string hash
    const empty_hash = keccak256("");
    try testing.expectEqual(EMPTY_KECCAK256, empty_hash);

    // Test known hash
    const hello_hash = keccak256("hello");
    const expected_hex = "0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8";
    const expected_hash = try from_hex(expected_hex);
    try testing.expectEqual(expected_hash, hello_hash);
}

test "hash comparison and arithmetic" {
    const hash1 = from_u256(0x1234);
    const hash2 = from_u256(0x5678);

    // Test comparison
    try testing.expect(less_than(hash1, hash2));
    try testing.expect(greater_than(hash2, hash1));
    try testing.expect(!equal(hash1, hash2));

    // Test XOR
    const xor_result = xor(hash1, hash2);
    const expected_xor = from_u256(0x1234 ^ 0x5678);
    try testing.expectEqual(expected_xor, xor_result);
}

test "selector creation" {
    const signature = "transfer(address,uint256)";
    const selector = selector_from_signature(signature);
    const expected = [4]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try testing.expectEqual(expected, selector);
}

test "u256 conversion" {
    const value = 0x123456789abcdef0;
    const hash = from_u256(value);
    const converted_back = to_u256(hash);
    try testing.expectEqual(value, converted_back);
}

test "EIP-191 message hashing" {
    const allocator = testing.allocator;
    const message = "Hello, Ethereum!";
    const hash = try eip191_hash_message(message, allocator);

    // The hash should not be zero
    try testing.expect(!is_zero(hash));

    // Should be deterministic
    const hash2 = try eip191_hash_message(message, allocator);
    try testing.expectEqual(hash, hash2);
}

// Additional tests from hash_utils_test.zig
test "create zero hash" {
    const zero_hash = zero();
    try testing.expect(is_zero(zero_hash));
    try testing.expectEqualSlices(u8, &ZERO_HASH, &zero_hash);
}

test "hash from bytes" {
    const test_bytes = [_]u8{ 0x12, 0x34 } ++ [_]u8{0} ** 30;
    const hash_from_bytes = from_bytes(test_bytes);
    try testing.expectEqual(test_bytes, hash_from_bytes);
}

test "hash from slice" {
    const slice: []const u8 = &[_]u8{ 0xde, 0xad, 0xbe, 0xef } ++ [_]u8{0} ** 28;
    const hash_from_slice = try from_slice(slice);
    try testing.expectEqualSlices(u8, slice, &hash_from_slice);
}

test "hash from slice invalid length" {
    const slice: []const u8 = &[_]u8{ 0xde, 0xad, 0xbe, 0xef }; // Only 4 bytes
    const result = from_slice(slice);
    try testing.expectError(error.InvalidLength, result);
}

test "hash from hex" {
    const hex_str = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    const hash_from_hex = try from_hex(hex_str);

    const expected_bytes = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
    };
    try testing.expectEqual(expected_bytes, hash_from_hex);
}

test "hash to hex" {
    const test_hash = from_bytes([_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
    });

    const hex_result = to_hex(test_hash);
    const expected = "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef";
    try testing.expectEqualStrings(expected, &hex_result);
}

test "hash to hex uppercase" {
    const test_hash = from_bytes([_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
    });

    const hex_result = to_hex_upper(test_hash);
    const expected = "0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF";
    try testing.expectEqualStrings(expected, &hex_result);
}

test "keccak256 empty string" {
    const empty_hash = keccak256("");
    try testing.expectEqual(EMPTY_KECCAK256, empty_hash);
    try testing.expectEqual(keccak256_empty(), empty_hash);
}

test "keccak256 known values" {
    // Test "hello" hash
    const hello_hash = keccak256("hello");
    const expected_hello = try from_hex("0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8");
    try testing.expectEqual(expected_hello, hello_hash);

    // Test "Hello World!"
    const hello_world_hash = keccak256("Hello World!");
    const expected_hw_bytes = [_]u8{
        0x3e, 0xa2, 0xf1, 0xd0, 0xab, 0xf3, 0xfc, 0x66,
        0xcf, 0x29, 0xee, 0xbb, 0x70, 0xcb, 0xd4, 0xe7,
        0xfe, 0x76, 0x2e, 0xf8, 0xa0, 0x9b, 0xcc, 0x06,
        0xc8, 0xed, 0xf6, 0x41, 0x23, 0x0a, 0xfe, 0xc0,
    };
    try testing.expectEqual(expected_hw_bytes, hello_world_hash);
}

test "keccak256 with bytes input" {
    const bytes = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const bytes_hash = keccak256(&bytes);

    // Should produce consistent hash
    const bytes_hash2 = keccak256(&bytes);
    try testing.expectEqual(bytes_hash, bytes_hash2);
}

test "eip191 hash message with different lengths" {
    const allocator = testing.allocator;

    // Test empty message
    const empty_hash = try eip191_hash_message("", allocator);
    try testing.expect(!is_zero(empty_hash));

    // Test longer message
    const long_message = "This is a much longer message that should still hash correctly";
    const long_hash = try eip191_hash_message(long_message, allocator);
    try testing.expect(!is_zero(long_hash));

    // Different messages should produce different hashes
    try testing.expect(!equal(empty_hash, long_hash));
}

test "selector from signature" {
    // Test standard ERC20 transfer function
    const transfer_sig = "transfer(address,uint256)";
    const selector = selector_from_signature(transfer_sig);
    const expected_selector = [4]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try testing.expectEqual(expected_selector, selector);

    // Test balanceOf function
    const balance_sig = "balanceOf(address)";
    const balance_selector = selector_from_signature(balance_sig);
    const expected_balance = [4]u8{ 0x70, 0xa0, 0x82, 0x31 };
    try testing.expectEqual(expected_balance, balance_selector);
}

test "hash comparison and ordering" {
    const hash1 = from_u256(0x1234);
    const hash2 = from_u256(0x5678);
    const hash3 = from_u256(0x1234); // Same as hash1

    // Test equality
    try testing.expect(equal(hash1, hash3));
    try testing.expect(!equal(hash1, hash2));

    // Test comparison
    try testing.expect(less_than(hash1, hash2));
    try testing.expect(!less_than(hash2, hash1));
    try testing.expect(!less_than(hash1, hash3)); // Equal values

    try testing.expect(greater_than(hash2, hash1));
    try testing.expect(!greater_than(hash1, hash2));

    // Test compare function
    try testing.expectEqual(std.math.Order.lt, compare(hash1, hash2));
    try testing.expectEqual(std.math.Order.gt, compare(hash2, hash1));
    try testing.expectEqual(std.math.Order.eq, compare(hash1, hash3));
}

test "hash bitwise operations" {
    const hash1 = from_u256(0x1234);
    const hash2 = from_u256(0x5678);

    // Test XOR
    const xor_result = xor(hash1, hash2);
    const expected_xor = from_u256(0x1234 ^ 0x5678);
    try testing.expectEqual(expected_xor, xor_result);

    // Test AND
    const and_result = bit_and(hash1, hash2);
    const expected_and = from_u256(0x1234 & 0x5678);
    try testing.expectEqual(expected_and, and_result);

    // Test OR
    const or_result = bit_or(hash1, hash2);
    const expected_or = from_u256(0x1234 | 0x5678);
    try testing.expectEqual(expected_or, or_result);

    // Test NOT
    const not_result = bit_not(hash1);
    const value_1234 = 0x1234;
    const expected_not = from_u256(~value_1234);
    try testing.expectEqual(expected_not, not_result);
}

test "hash to/from u256 conversion" {
    const test_values = [_]u256{
        0,
        1,
        0x123456789abcdef0,
        std.math.maxInt(u256),
    };

    for (test_values) |value| {
        const hash_val = from_u256(value);
        const converted_back = to_u256(hash_val);
        try testing.expectEqual(value, converted_back);
    }
}

test "hash invalid hex format" {
    // Missing 0x prefix
    const result1 = from_hex("1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
    try testing.expectError(error.InvalidHexFormat, result1);

    // Invalid length
    const result2 = from_hex("0x1234");
    try testing.expectError(error.InvalidHexLength, result2);

    // Invalid characters
    const result3 = from_hex("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdeg");
    try testing.expectError(error.InvalidHexString, result3);
}

test "hash from hex comptime" {
    const comptime_hash = from_hex_comptime("0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef");
    const expected_bytes = [_]u8{
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
        0x12, 0x34, 0x56, 0x78, 0x90, 0xab, 0xcd, 0xef,
    };
    try testing.expectEqual(expected_bytes, comptime_hash);
}

test "well known hash values" {
    // Test that constants are correct
    try testing.expectEqual(@as(usize, 32), ZERO_HASH.len);
    try testing.expect(is_zero(ZERO_HASH));

    // Empty keccak256 should be a specific value
    const empty_keccak = keccak256("");
    try testing.expectEqual(EMPTY_KECCAK256, empty_keccak);

    // Verify the constant matches expected value
    const expected_empty = [32]u8{
        0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
        0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
        0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
        0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
    };
    try testing.expectEqual(expected_empty, EMPTY_KECCAK256);
}
