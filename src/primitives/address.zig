const std = @import("std");
const crypto = std.crypto;
const rlp = @import("rlp.zig");

const starts_with = std.mem.startsWith;
const hex_to_bytes = std.fmt.hexToBytes;
const bytes_to_hex = std.fmt.bytesToHex;
const Case = std.fmt.Case;
const Keccak256 = crypto.hash.sha3.Keccak256;

pub const Address = [20]u8;

pub const ZERO_ADDRESS: Address = [20]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

// Error types for Address operations
pub const CalculateAddressError = std.mem.Allocator.Error || rlp.EncodeError;
pub const CalculateCreate2AddressError = std.mem.Allocator.Error;

pub fn zero() Address {
    return ZERO_ADDRESS;
}

pub const ZERO = ZERO_ADDRESS;

pub fn to_u256(addr: Address) u256 {
    var result: u256 = 0;
    for (addr) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

pub fn from_u256(value: u256) Address {
    var addr: Address = undefined;
    var v = value;
    for (0..20) |i| {
        addr[19 - i] = @truncate(v & 0xFF);
        v >>= 8;
    }
    return addr;
}

pub fn from_hex(hex_str: []const u8) !Address {
    if (hex_str.len != 42 or !starts_with(u8, hex_str, "0x")) {
        return error.InvalidHexFormat;
    }

    var addr: Address = undefined;
    _ = hex_to_bytes(&addr, hex_str[2..]) catch return error.InvalidHexString;
    return addr;
}

pub fn from_public_key(public_key_x: u256, public_key_y: u256) Address {
    var pub_key_bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, pub_key_bytes[0..32], public_key_x, .big);
    std.mem.writeInt(u256, pub_key_bytes[32..64], public_key_y, .big);

    var hash: [32]u8 = undefined;
    Keccak256.hash(&pub_key_bytes, &hash, .{});

    var address: Address = undefined;
    @memcpy(&address, hash[12..32]);
    return address;
}

pub fn to_hex(address: Address) [42]u8 {
    return address_to_hex(address);
}

pub fn to_checksum_hex(address: Address) [42]u8 {
    return address_to_checksum_hex(address);
}

pub fn is_zero(address: Address) bool {
    return std.mem.eql(u8, &address, &ZERO_ADDRESS);
}

pub fn equals(a: Address, b: Address) bool {
    return std.mem.eql(u8, &a, &b);
}

pub fn is_valid(addr_str: []const u8) bool {
    return is_valid_address(addr_str);
}

pub fn is_valid_checksum(addr_str: []const u8) bool {
    return is_valid_checksum_address(addr_str);
}

pub fn format(address: Address, uppercase: bool) [42]u8 {
    if (uppercase) {
        var result: [42]u8 = undefined;
        result[0] = '0';
        result[1] = 'x';
        const hex = bytes_to_hex(&address, .upper);
        @memcpy(result[2..], &hex);
        return result;
    } else {
        return address_to_hex(address);
    }
}

pub fn address_from_hex(comptime hex: [42]u8) Address {
    if (!starts_with(u8, &hex, "0x"))
        @compileError("hex must start with '0x'");

    var out: Address = undefined;
    hex_to_bytes(&out, hex[2..]) catch unreachable;
    return out;
}

pub fn address_from_public_key(public_key: PublicKey) Address {
    return public_key.to_address();
}

pub fn address_to_hex(address: Address) [42]u8 {
    var result: [42]u8 = undefined;
    result[0] = '0';
    result[1] = 'x';
    const hex = bytes_to_hex(&address, .lower);
    @memcpy(result[2..], &hex);
    return result;
}

pub fn address_to_checksum_hex(address: Address) [42]u8 {
    var result: [42]u8 = undefined;
    var hex_without_prefix: [40]u8 = undefined;

    result[0] = '0';
    result[1] = 'x';

    const lowercase = "0123456789abcdef";
    const uppercase = "0123456789ABCDEF";

    for (address, 0..) |b, i| {
        hex_without_prefix[i * 2] = lowercase[b >> 4];
        hex_without_prefix[i * 2 + 1] = lowercase[b & 15];
    }

    var hash: [32]u8 = undefined;
    Keccak256.hash(&hex_without_prefix, &hash, .{});

    for (address, 0..) |b, i| {
        const high_nibble = b >> 4;
        const low_nibble = b & 15;
        const high_hash = (hash[i] >> 4) & 0x0F;
        const low_hash = hash[i] & 0x0F;

        result[i * 2 + 2] = if (high_nibble > 9 and high_hash >= 8)
            uppercase[high_nibble]
        else
            lowercase[high_nibble];

        result[i * 2 + 3] = if (low_nibble > 9 and low_hash >= 8)
            uppercase[low_nibble]
        else
            lowercase[low_nibble];
    }

    return result;
}

pub const CompressedPublicKey = struct {
    prefix: u8,
    x: [32]u8,
};

pub const PublicKey = struct {
    prefix: u8,
    x: [32]u8,
    y: [32]u8,

    pub fn from_hex(hex: []const u8) !PublicKey {
        if (hex.len < 2 or !std.mem.eql(u8, hex[0..2], "0x"))
            return error.InvalidPublicKeyFormat;

        if (hex.len == 2 + 130) {
            if (hex[2] != '0' or hex[3] != '4')
                return error.InvalidPublicKeyPrefix;

            var key = PublicKey{
                .prefix = 0x04,
                .x = undefined,
                .y = undefined,
            };

            _ = hex_to_bytes(&key.x, hex[4..68]) catch return error.InvalidHexString;
            _ = hex_to_bytes(&key.y, hex[68..132]) catch return error.InvalidHexString;

            return key;
        } else if (hex.len == 2 + 128) {
            var key = PublicKey{
                .prefix = 0x04,
                .x = undefined,
                .y = undefined,
            };

            _ = hex_to_bytes(&key.x, hex[2..66]) catch return error.InvalidHexString;
            _ = hex_to_bytes(&key.y, hex[66..130]) catch return error.InvalidHexString;

            return key;
        }

        return error.InvalidPublicKeyLength;
    }

    fn to_address(self: PublicKey) Address {
        var hash: [32]u8 = undefined;
        var pubkey_bytes: [64]u8 = undefined;

        @memcpy(pubkey_bytes[0..32], &self.x);

        if (self.prefix == 0x04) {
            @memcpy(pubkey_bytes[32..64], &self.y);
        }

        Keccak256.hash(&pubkey_bytes, &hash, .{});

        var address: Address = undefined;
        @memcpy(&address, hash[12..32]);

        return address;
    }
};

pub fn is_valid_address(addr_str: []const u8) bool {
    if (addr_str.len != 42 or !starts_with(u8, addr_str, "0x"))
        return false;

    for (addr_str[2..]) |c| {
        const valid = switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => true,
            else => false,
        };
        if (!valid) return false;
    }

    return true;
}

pub fn is_valid_checksum_address(addr_str: []const u8) bool {
    if (!is_valid_address(addr_str))
        return false;

    var addr: Address = undefined;
    _ = hex_to_bytes(&addr, addr_str[2..]) catch return false;

    const checksummed = address_to_checksum_hex(addr);
    return std.mem.eql(u8, &checksummed, addr_str);
}

pub fn are_addresses_equal(a: []const u8, b: []const u8) !bool {
    if (!is_valid_address(a) or !is_valid_address(b))
        return error.InvalidAddress;

    var addr_a: Address = undefined;
    var addr_b: Address = undefined;

    _ = try hex_to_bytes(&addr_a, a[2..]);
    _ = try hex_to_bytes(&addr_b, b[2..]);

    return std.mem.eql(u8, &addr_a, &addr_b);
}

pub fn calculate_create_address(allocator: std.mem.Allocator, creator: Address, nonce: u64) CalculateAddressError!Address {
    // Convert nonce to bytes, stripping leading zeros
    var nonce_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &nonce_bytes, nonce, .big);

    // Find first non-zero byte
    var nonce_start: usize = 0;
    for (nonce_bytes) |byte| {
        if (byte != 0) break;
        nonce_start += 1;
    }

    // If nonce is 0, use empty slice
    const nonce_slice = if (nonce == 0) &[_]u8{} else nonce_bytes[nonce_start..];

    // Create a list for RLP encoding [creator_address, nonce]
    var list = std.ArrayList([]const u8).init(allocator);
    defer list.deinit();

    try list.append(&creator);
    try list.append(nonce_slice);

    // RLP encode the list
    const encoded = try rlp.encode(allocator, list.items);
    defer allocator.free(encoded);

    // Hash the RLP encoded data
    var hash: [32]u8 = undefined;
    Keccak256.hash(encoded, &hash, .{});

    // Take last 20 bytes as address
    var address: Address = undefined;
    @memcpy(&address, hash[12..32]);

    return address;
}

pub fn calculate_create2_address(allocator: std.mem.Allocator, creator: Address, salt: u256, init_code: []const u8) CalculateCreate2AddressError!Address {
    // First hash the init code
    var code_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &code_hash, .{});

    // Create the data to hash: 0xff ++ creator ++ salt ++ keccak256(init_code)
    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();

    // Add 0xff prefix
    try data.append(0xff);

    // Add creator address (20 bytes)
    try data.appendSlice(&creator);

    // Add salt (32 bytes, big-endian)
    var salt_bytes: [32]u8 = undefined;
    var temp_salt = salt;
    for (0..32) |i| {
        salt_bytes[31 - i] = @intCast(temp_salt & 0xFF);
        temp_salt >>= 8;
    }
    try data.appendSlice(&salt_bytes);

    // Add init code hash (32 bytes)
    try data.appendSlice(&code_hash);

    // Hash the combined data
    var hash: [32]u8 = undefined;
    Keccak256.hash(data.items, &hash, .{});

    // Take last 20 bytes as address
    var address: Address = undefined;
    @memcpy(&address, hash[12..32]);

    return address;
}

// Convenience function for CREATE address calculation without allocator
// Uses a fixed buffer for the RLP encoding
pub fn get_contract_address(creator: Address, nonce: u64) Address {
    const allocator = std.heap.page_allocator;
    return calculate_create_address(allocator, creator, nonce) catch unreachable;
}

// Convenience function for CREATE2 address calculation without allocator
// Expects pre-hashed init code
pub fn get_create2_address(creator: Address, salt: [32]u8, init_code_hash: [32]u8) Address {
    // Build the data to hash: 0xff ++ creator ++ salt ++ init_code_hash
    var data: [85]u8 = undefined;
    data[0] = 0xff;
    @memcpy(data[1..21], &creator);
    @memcpy(data[21..53], &salt);
    @memcpy(data[53..85], &init_code_hash);

    // Hash the data
    var hash: [32]u8 = undefined;
    Keccak256.hash(&data, &hash, .{});

    // Take last 20 bytes as address
    var address: Address = undefined;
    @memcpy(&address, hash[12..32]);

    return address;
}

test "PublicKey.from_hex" {
    const serialized = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const public_key = try PublicKey.from_hex(serialized);

    try std.testing.expectEqual(@as(u8, 0x04), public_key.prefix);

    const expected_x = [_]u8{ 0x83, 0x18, 0x53, 0x5b, 0x54, 0x10, 0x5d, 0x4a, 0x7a, 0xae, 0x60, 0xc0, 0x8f, 0xc4, 0x5f, 0x96, 0x87, 0x18, 0x1b, 0x4f, 0xdf, 0xc6, 0x25, 0xbd, 0x1a, 0x75, 0x3f, 0xa7, 0x39, 0x7f, 0xed, 0x75 };
    try std.testing.expectEqualSlices(u8, &expected_x, &public_key.x);

    const expected_y = [_]u8{ 0x35, 0x47, 0xf1, 0x1c, 0xa8, 0x69, 0x66, 0x46, 0xf2, 0xf3, 0xac, 0xb0, 0x8e, 0x31, 0x01, 0x6a, 0xfa, 0xc2, 0x3e, 0x63, 0x0c, 0x5d, 0x11, 0xf5, 0x9f, 0x61, 0xfe, 0xf5, 0x7b, 0x0d, 0x2a, 0xa5 };
    try std.testing.expectEqualSlices(u8, &expected_y, &public_key.y);
}

test "Address - checksumAddress" {
    const test_cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{
            .input = "0xa0cf798816d4b9b9866b5330eea46a18382f251e",
            .expected = "0xA0Cf798816D4b9b9866b5330EEa46a18382f251e",
        },
        .{
            .input = "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266",
            .expected = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
        },
        .{
            .input = "0x70997970c51812dc3a010c7d01b50e0d17dc79c8",
            .expected = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
        },
    };

    for (test_cases) |tc| {
        var addr: Address = undefined;
        _ = hex_to_bytes(&addr, tc.input[2..]) catch unreachable;

        const checksummed = address_to_checksum_hex(addr);

        try std.testing.expectEqualStrings(tc.expected, &checksummed);
    }
}

test "Address - fromPublicKey" {
    const serialized = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const public_key = try PublicKey.from_hex(serialized);

    const addr = address_from_public_key(public_key);

    var expected_addr: Address = undefined;
    _ = hex_to_bytes(&expected_addr, "f39fd6e51aad88f6f4ce6ab8827279cfffb92266") catch unreachable;

    try std.testing.expectEqualSlices(u8, &expected_addr, &addr);

    const addr_checksum = address_to_checksum_hex(addr);
    const expected_checksum = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    try std.testing.expectEqualStrings(expected_checksum, &addr_checksum);
}

test "Address - validation" {
    try std.testing.expect(is_valid_address("0xa0cf798816d4b9b9866b5330eea46a18382f251e"));
    try std.testing.expect(is_valid_address("0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));

    try std.testing.expect(!is_valid_address("x"));
    try std.testing.expect(!is_valid_address("0xa"));
    try std.testing.expect(!is_valid_address("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678az"));
    try std.testing.expect(!is_valid_address("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678aff"));
    try std.testing.expect(!is_valid_address("a5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expect(is_valid_checksum_address("0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));
    try std.testing.expect(!is_valid_checksum_address("0xa0cf798816d4b9b9866b5330eea46a18382f251e"));
    try std.testing.expect(!is_valid_checksum_address("0xA0CF798816D4B9B9866B5330EEA46A18382F251E"));
}

test "Address - equality" {
    try std.testing.expect(try are_addresses_equal("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994DB5b0d9A5eEdD10CabaB0813678AC"));

    try std.testing.expect(try are_addresses_equal("0xa0cf798816d4b9b9866b5330eea46a18382f251e", "0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));

    try std.testing.expect(try are_addresses_equal("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expect(!try are_addresses_equal("0xa0cf798816d4b9b9866b5330eea46a18382f251e", "0xA0Cf798816D4b9b9866b5330EEa46a18382f251f"));

    try std.testing.expectError(error.InvalidAddress, are_addresses_equal("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678az", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expectError(error.InvalidAddress, are_addresses_equal("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678aff"));
}

test "contract address generation - CREATE" {
    const deployer = try from_hex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const nonce: u64 = 0;

    const addr = get_contract_address(deployer, nonce);
    const expected = try from_hex("0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE with nonce 1" {
    const deployer = try from_hex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const nonce: u64 = 1;

    const addr = get_contract_address(deployer, nonce);
    const expected = try from_hex("0x343c43a37d37dff08ae8c4a11544c718abb4fcf8");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE multiple nonces" {
    const deployer = try from_hex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

    const test_cases = [_]struct {
        nonce: u64,
        expected: []const u8,
    }{
        .{ .nonce = 0, .expected = "0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d" },
        .{ .nonce = 1, .expected = "0x343c43a37d37dff08ae8c4a11544c718abb4fcf8" },
        .{ .nonce = 2, .expected = "0xf778b86fa74e846c4f0a1fbd1335fe81c00a0c91" },
        .{ .nonce = 3, .expected = "0xfffd933a0bc612844eaf0c6fe3e5b8e9b6c1d19c" },
    };

    for (test_cases) |tc| {
        const addr = get_contract_address(deployer, tc.nonce);
        const expected = try from_hex(tc.expected);
        try std.testing.expectEqual(expected, addr);
    }
}

test "contract address generation - CREATE2" {
    const deployer = try from_hex("0x0000000000000000000000000000000000000000");
    const salt = [_]u8{0} ** 32;
    const init_code_hash = [_]u8{0} ** 32;

    const addr = get_create2_address(deployer, salt, init_code_hash);
    const expected = try from_hex("0x4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE2 deterministic" {
    const deployer = try from_hex("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    const salt: [32]u8 = .{ 0x12, 0x34, 0x56, 0x78 } ++ .{0} ** 28;
    const init_code_hash: [32]u8 = .{ 0xab, 0xcd, 0xef } ++ .{0} ** 29;

    const addr = get_create2_address(deployer, salt, init_code_hash);

    // Should generate deterministic address
    const addr2 = get_create2_address(deployer, salt, init_code_hash);
    try std.testing.expectEqual(addr, addr2);
}

test "calculate_create_address with allocator" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

    const addr = try calculate_create_address(allocator, deployer, 0);
    const expected = try from_hex("0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d");
    try std.testing.expectEqual(expected, addr);
}

test "calculate_create_address with nonce 1" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

    const addr = try calculate_create_address(allocator, deployer, 1);
    // Verify it's a valid address length and different from nonce 0
    try std.testing.expect(addr.len == 20);

    const addr_nonce_0 = try calculate_create_address(allocator, deployer, 0);
    try std.testing.expect(!std.mem.eql(u8, &addr, &addr_nonce_0));
}

test "calculate_create_address with various nonces" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    const nonces = [_]u64{ 0, 1, 2, 10, 255, 256, 65535, 65536, 16777215, 16777216 };

    for (nonces) |nonce| {
        const addr = try calculate_create_address(allocator, deployer, nonce);
        try std.testing.expect(addr.len == 20);
    }
}

test "calculate_create_address deterministic with same inputs" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const nonce: u64 = 42;

    const addr1 = try calculate_create_address(allocator, deployer, nonce);
    const addr2 = try calculate_create_address(allocator, deployer, nonce);

    try std.testing.expectEqual(addr1, addr2);
}

test "calculate_create_address different with different nonce" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    const addr1 = try calculate_create_address(allocator, deployer, 1);
    const addr2 = try calculate_create_address(allocator, deployer, 2);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address different with different creator" {
    const allocator = std.testing.allocator;
    const nonce: u64 = 0;

    const creator1 = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const creator2 = try from_hex("0x8ba1f109551bD432803012645Hac136c69b95Ee4");

    const addr1 = try calculate_create_address(allocator, creator1, nonce);
    const addr2 = try calculate_create_address(allocator, creator2, nonce);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address with maximum nonce" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const max_nonce = std.math.maxInt(u64);

    const addr = try calculate_create_address(allocator, deployer, max_nonce);
    try std.testing.expect(addr.len == 20);
}

test "calculate_create_address with zero address creator" {
    const allocator = std.testing.allocator;
    const zero_address = try from_hex("0x0000000000000000000000000000000000000000");

    const addr1 = try calculate_create_address(allocator, zero_address, 0);
    const addr2 = try calculate_create_address(allocator, zero_address, 1);

    try std.testing.expect(addr1.len == 20);
    try std.testing.expect(addr2.len == 20);
    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address with maximum address creator" {
    const allocator = std.testing.allocator;
    const max_address = try from_hex("0xffffffffffffffffffffffffffffffffffffffff");

    const addr = try calculate_create_address(allocator, max_address, 0);
    try std.testing.expect(addr.len == 20);
}

test "calculate_create_address nonce encoding edge cases" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    // Test boundary values for nonce encoding
    const boundary_nonces = [_]u64{
        0, // Empty bytes
        1, // Single byte
        127, // Max single byte without high bit
        128, // First two-byte value
        255, // Max single byte
        256, // First true two-byte value
        65535, // Max two bytes
        65536, // First three-byte value
        16777215, // Max three bytes
        16777216, // First four-byte value
    };

    for (boundary_nonces) |nonce| {
        const addr = try calculate_create_address(allocator, deployer, nonce);
        try std.testing.expect(addr.len == 20);
    }
}

test "calculate_create_address sequential nonces produce different addresses" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    var prev_addr: ?Address = null;
    var nonce: u64 = 0;

    while (nonce < 10) : (nonce += 1) {
        const addr = try calculate_create_address(allocator, deployer, nonce);

        if (prev_addr) |prev| {
            try std.testing.expect(!std.mem.eql(u8, &prev, &addr));
        }

        prev_addr = addr;
    }
}

test "calculate_create2_address with allocator" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0;
    const init_code: []const u8 = "";

    const addr = try calculate_create2_address(allocator, deployer, salt, init_code);

    // Hash of empty init code
    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with non-zero salt" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0;
    const init_code: []const u8 = "";

    const addr = try calculate_create2_address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with non-zero address and salt" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x00000000000000000000000000000000000000000000000000000000cafebabe;
    const init_code: []const u8 = "";

    const addr = try calculate_create2_address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with init code" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0;
    const init_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    const addr = try calculate_create2_address(allocator, deployer, salt, &init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with complex init code" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0xdeadbeefcafebabe0123456789abcdef0123456789abcdef0123456789abcdef;
    const init_code = [_]u8{
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15, 0x61, 0x00, 0x1b,
        0x57, 0x60, 0x00, 0x80, 0xfd, 0x5b, 0x50, 0x60, 0x40, 0x51, 0x80,
    }; // More complex bytecode

    const addr = try calculate_create2_address(allocator, deployer, salt, &init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address maximum salt value" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0xffffffffffffffffffffffffffffffffffffffff");
    const salt: u256 = std.math.maxInt(u256);
    const init_code: []const u8 = "";

    const addr = try calculate_create2_address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address deterministic with same inputs" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x123456789abcdef0;
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0 };

    const addr1 = try calculate_create2_address(allocator, deployer, salt, &init_code);
    const addr2 = try calculate_create2_address(allocator, deployer, salt, &init_code);

    try std.testing.expectEqual(addr1, addr2);
}

test "calculate_create2_address different with different salt" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const init_code = [_]u8{ 0x60, 0x00 };

    const addr1 = try calculate_create2_address(allocator, deployer, 0x1, &init_code);
    const addr2 = try calculate_create2_address(allocator, deployer, 0x2, &init_code);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address different with different deployer" {
    const allocator = std.testing.allocator;
    const salt: u256 = 0x123456789abcdef0;
    const init_code = [_]u8{ 0x60, 0x00 };

    const deployer1 = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const deployer2 = try from_hex("0x8ba1f109551bD432803012645Hac136c69b95Ee4");

    const addr1 = try calculate_create2_address(allocator, deployer1, salt, &init_code);
    const addr2 = try calculate_create2_address(allocator, deployer2, salt, &init_code);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address different with different init code" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x123456789abcdef0;

    const init_code1 = [_]u8{ 0x60, 0x00 };
    const init_code2 = [_]u8{ 0x60, 0x01 };

    const addr1 = try calculate_create2_address(allocator, deployer, salt, &init_code1);
    const addr2 = try calculate_create2_address(allocator, deployer, salt, &init_code2);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address with large init code" {
    const allocator = std.testing.allocator;
    const deployer = try from_hex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0xdeadbeef;

    var large_init_code: [1024]u8 = undefined;
    for (&large_init_code, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const addr = try calculate_create2_address(allocator, deployer, salt, &large_init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&large_init_code, &expected_hash, .{});

    const expected_addr = get_create2_address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}
