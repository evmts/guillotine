const std = @import("std");
const crypto = std.crypto;
const rlp = @import("rlp.zig");

const starts_with = std.mem.startsWith;
const hex_to_bytes = std.fmt.hexToBytes;
const bytes_to_hex = std.fmt.bytesToHex;
const Case = std.fmt.Case;
const Keccak256 = crypto.hash.sha3.Keccak256;

pub const Address = @This();

bytes: [20]u8,

/// Format address for std.fmt output
pub fn format(
    self: Address,
    comptime fmt: []const u8,
    options: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    _ = fmt;
    _ = options;
    const hex = addressToHex(self);
    try writer.writeAll(&hex);
}

/// Format address as number for std.fmt hex output
pub fn formatNumber(
    self: Address,
    writer: anytype,
    options: std.fmt.Number,
) !void {
    _ = options;
    const hex = addressToHex(self);
    try writer.writeAll(&hex);
}

pub const ZERO_ADDRESS: Address = .{ .bytes = [20]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };

// Error types for Address operations
pub const CalculateAddressError = std.mem.Allocator.Error || rlp.EncodeError;
pub const CalculateCreate2AddressError = std.mem.Allocator.Error;

pub fn zero() Address {
    return ZERO_ADDRESS;
}

pub const ZERO = ZERO_ADDRESS;

pub fn toU256(addr: Address) u256 {
    var result: u256 = 0;
    for (addr.bytes) |byte| {
        result = (result << 8) | byte;
    }
    return result;
}

pub fn fromU256(value: u256) Address {
    var addr: Address = undefined;
    var v = value;
    for (0..20) |i| {
        addr.bytes[19 - i] = @truncate(v & 0xFF);
        v >>= 8;
    }
    return addr;
}

pub fn fromHex(hex_str: []const u8) !Address {
    // Accept with or without 0x prefix
    var slice = hex_str;
    if (slice.len >= 2 and (slice[0] == '0' and (slice[1] == 'x' or slice[1] == 'X'))) {
        if (slice.len != 42) return error.InvalidHexFormat;
        slice = slice[2..];
    } else {
        if (slice.len != 40) return error.InvalidHexFormat;
    }

    var addr: Address = undefined;
    _ = hex_to_bytes(&addr.bytes, slice) catch return error.InvalidHexString;
    return addr;
}

pub fn fromPublicKey(public_key_x: u256, public_key_y: u256) Address {
    var pub_key_bytes: [64]u8 = undefined;
    std.mem.writeInt(u256, pub_key_bytes[0..32], public_key_x, .big);
    std.mem.writeInt(u256, pub_key_bytes[32..64], public_key_y, .big);

    var hash: [32]u8 = undefined;
    Keccak256.hash(&pub_key_bytes, &hash, .{});

    var address: Address = undefined;
    @memcpy(&address.bytes, hash[12..32]);
    return address;
}

pub fn toHex(address: Address) [42]u8 {
    return addressToHex(address);
}

pub fn toChecksumHex(address: Address) [42]u8 {
    return addressToChecksumHex(address);
}

pub fn isZero(address: Address) bool {
    return std.mem.eql(u8, &address.bytes, &ZERO_ADDRESS.bytes);
}

pub fn equals(a: Address, b: Address) bool {
    return std.mem.eql(u8, &a.bytes, &b.bytes);
}

pub fn eql(self: Address, other: Address) bool {
    return equals(self, other);
}

pub const FromBytesError = error{InvalidAddressLength};

pub fn fromBytes(bytes: []const u8) FromBytesError!Address {
    if (bytes.len != 20) return error.InvalidAddressLength;
    var addr: Address = undefined;
    @memcpy(&addr.bytes, bytes[0..20]);
    return addr;
}

pub fn isValid(addr_str: []const u8) bool {
    return isValidAddress(addr_str);
}

pub fn isValidChecksum(addr_str: []const u8) bool {
    return isValidChecksumAddress(addr_str);
}

pub fn formatWithCase(address: Address, uppercase: bool) [42]u8 {
    if (uppercase) {
        var result: [42]u8 = undefined;
        result[0] = '0';
        result[1] = 'x';
        const hex = bytes_to_hex(&address.bytes, .upper);
        @memcpy(result[2..], &hex);
        return result;
    } else {
        return addressToHex(address);
    }
}

pub fn addressFromHex(comptime hex: [42]u8) Address {
    if (!starts_with(u8, &hex, "0x"))
        @compileError("hex must start with '0x'");

    var out: Address = undefined;
    _ = hex_to_bytes(&out.bytes, hex[2..]) catch {
        @compileError("invalid hex string in addressFromHex");
    };
    return out;
}

pub fn addressFromPublicKey(public_key: PublicKey) Address {
    return public_key.toAddress();
}

pub fn addressToHex(address: Address) [42]u8 {
    var result: [42]u8 = undefined;
    result[0] = '0';
    result[1] = 'x';
    const hex = bytes_to_hex(&address.bytes, .lower);
    @memcpy(result[2..], &hex);
    return result;
}

pub fn addressToChecksumHex(address: Address) [42]u8 {
    var result: [42]u8 = undefined;
    result[0] = '0';
    result[1] = 'x';

    // 1) Lowercase hex string of address (no prefix)
    var lower_hex: [40]u8 = undefined;
    const lower_alphabet = "0123456789abcdef";
    for (address.bytes, 0..) |b, i| {
        lower_hex[i * 2] = lower_alphabet[b >> 4];
        lower_hex[i * 2 + 1] = lower_alphabet[b & 0x0F];
    }

    // 2) keccak256 of the lowercase hex string, then hex-encode the hash
    var hash_bytes: [32]u8 = undefined;
    Keccak256.hash(&lower_hex, &hash_bytes, .{});
    const hash_hex = std.fmt.bytesToHex(&hash_bytes, .lower);

    // 3) For each nibble, if hash nibble >= 8 and char is alpha, uppercase
    var out_no_prefix: [40]u8 = lower_hex; // start as lowercase
    for (lower_hex, 0..) |ch, idx| {
        if (ch >= 'a' and ch <= 'f') {
            const hv = hash_hex[idx];
            // hv is an ASCII hex char; convert to its numeric value
            const hv_nibble: u8 = switch (hv) {
                '0'...'9' => hv - '0',
                'a'...'f' => hv - 'a' + 10,
                'A'...'F' => hv - 'A' + 10,
                else => 0,
            };
            if (hv_nibble >= 8) {
                out_no_prefix[idx] = ch - 32; // to uppercase
            }
        }
    }

    @memcpy(result[2..], &out_no_prefix);
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

    pub fn fromHex(hex: []const u8) !PublicKey {
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

    fn toAddress(self: PublicKey) Address {
        var hash: [32]u8 = undefined;
        var pubkey_bytes: [64]u8 = undefined;

        @memcpy(pubkey_bytes[0..32], &self.x);

        if (self.prefix == 0x04) {
            @memcpy(pubkey_bytes[32..64], &self.y);
        }

        Keccak256.hash(&pubkey_bytes, &hash, .{});

        var address: Address = undefined;
        @memcpy(&address.bytes, hash[12..32]);

        return address;
    }
};

pub fn isValidAddress(addr_str: []const u8) bool {
    // Support with or without 0x prefix
    var slice = addr_str;
    if (slice.len >= 2 and (slice[0] == '0' and (slice[1] == 'x' or slice[1] == 'X'))) {
        if (slice.len != 42) return false;
        slice = slice[2..];
    } else {
        if (slice.len != 40) return false;
    }

    for (slice) |c| {
        const valid = switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => true,
            else => false,
        };
        if (!valid) return false;
    }

    return true;
}

pub fn isValidChecksumAddress(addr_str: []const u8) bool {
    if (!isValidAddress(addr_str))
        return false;

    // Normalize to ensure we compare like-for-like
    if (starts_with(u8, addr_str, "0x") or starts_with(u8, addr_str, "0X")) {
        var addr: Address = undefined;
        _ = hex_to_bytes(&addr.bytes, addr_str[2..]) catch return false;
        const checksummed = addressToChecksumHex(addr);
        return std.mem.eql(u8, &checksummed, addr_str);
    } else {
        var addr: Address = undefined;
        _ = hex_to_bytes(&addr.bytes, addr_str) catch return false;
        const checksummed = addressToChecksumHex(addr);
        // Compare without 0x prefix
        return std.mem.eql(u8, checksummed[2..], addr_str);
    }
}

pub fn areAddressesEqual(a: []const u8, b: []const u8) !bool {
    if (!isValidAddress(a) or !isValidAddress(b))
        return error.InvalidAddress;

    var addr_a: Address = undefined;
    var addr_b: Address = undefined;

    _ = try hex_to_bytes(&addr_a.bytes, a[2..]);
    _ = try hex_to_bytes(&addr_b.bytes, b[2..]);

    return std.mem.eql(u8, &addr_a.bytes, &addr_b.bytes);
}

pub fn calculateCreateAddress(allocator: std.mem.Allocator, creator: Address, nonce: u64) CalculateAddressError!Address {
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
    var list = std.ArrayList([]const u8){};
    defer list.deinit(allocator);

    try list.append(allocator, &creator.bytes);
    try list.append(allocator, nonce_slice);

    // RLP encode the list
    const encoded = try rlp.encode(allocator, list.items);
    defer allocator.free(encoded);

    // Hash the RLP encoded data
    var hash: [32]u8 = undefined;
    Keccak256.hash(encoded, &hash, .{});

    // Take last 20 bytes as address
    var address: Address = undefined;
    @memcpy(&address.bytes, hash[12..32]);

    return address;
}

pub fn calculateCreate2Address(allocator: std.mem.Allocator, creator: Address, salt: u256, init_code: []const u8) CalculateCreate2AddressError!Address {
    // First hash the init code
    var code_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &code_hash, .{});

    // Create the data to hash: 0xff ++ creator ++ salt ++ keccak256(init_code)
    var data = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer data.deinit();

    // Add 0xff prefix
    try data.append(0xff);

    // Add creator address (20 bytes)
    try data.appendSlice(&creator.bytes);

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
    @memcpy(&address.bytes, hash[12..32]);

    return address;
}

// Convenience function for CREATE address calculation
pub fn getContractAddress(allocator: std.mem.Allocator, creator: Address, nonce: u64) CalculateAddressError!Address {
    return calculateCreateAddress(allocator, creator, nonce);
}

// Convenience function for CREATE2 address calculation without allocator
// Expects pre-hashed init code
pub fn getCreate2Address(creator: Address, salt: [32]u8, init_code_hash: [32]u8) Address {
    // Build the data to hash: 0xff ++ creator ++ salt ++ init_code_hash
    var data: [85]u8 = undefined;
    data[0] = 0xff;
    @memcpy(data[1..21], &creator.bytes);
    @memcpy(data[21..53], &salt);
    @memcpy(data[53..85], &init_code_hash);

    // Hash the data
    var hash: [32]u8 = undefined;
    Keccak256.hash(&data, &hash, .{});

    // Take last 20 bytes as address
    var address: Address = undefined;
    @memcpy(&address.bytes, hash[12..32]);

    return address;
}

test "PublicKey.fromHex" {
    const serialized = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const public_key = try PublicKey.fromHex(serialized);

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
        _ = try hex_to_bytes(&addr.bytes, tc.input[2..]);

        const checksummed = addressToChecksumHex(addr);

        try std.testing.expectEqualStrings(tc.expected, &checksummed);
    }
}

test "Address - fromPublicKey" {
    const serialized = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const public_key = try PublicKey.fromHex(serialized);

    const addr = addressFromPublicKey(public_key);

    var expected_addr: Address = undefined;
    _ = try hex_to_bytes(&expected_addr.bytes, "f39fd6e51aad88f6f4ce6ab8827279cfffb92266");

    try std.testing.expectEqualSlices(u8, &expected_addr.bytes, &addr.bytes);

    const addr_checksum = addressToChecksumHex(addr);
    const expected_checksum = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

    try std.testing.expectEqualStrings(expected_checksum, &addr_checksum);
}

test "Address - validation" {
    try std.testing.expect(isValidAddress("0xa0cf798816d4b9b9866b5330eea46a18382f251e"));
    try std.testing.expect(isValidAddress("0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));

    try std.testing.expect(!isValidAddress("x"));
    try std.testing.expect(!isValidAddress("0xa"));
    try std.testing.expect(!isValidAddress("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678az"));
    try std.testing.expect(!isValidAddress("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678aff"));
    try std.testing.expect(!isValidAddress("a5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expect(isValidChecksumAddress("0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));
    try std.testing.expect(!isValidChecksumAddress("0xa0cf798816d4b9b9866b5330eea46a18382f251e"));
    try std.testing.expect(!isValidChecksumAddress("0xA0CF798816D4B9B9866B5330EEA46A18382F251E"));
}

test "Address - equality" {
    try std.testing.expect(try areAddressesEqual("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994DB5b0d9A5eEdD10CabaB0813678AC"));

    try std.testing.expect(try areAddressesEqual("0xa0cf798816d4b9b9866b5330eea46a18382f251e", "0xA0Cf798816D4b9b9866b5330EEa46a18382f251e"));

    try std.testing.expect(try areAddressesEqual("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expect(!try areAddressesEqual("0xa0cf798816d4b9b9866b5330eea46a18382f251e", "0xA0Cf798816D4b9b9866b5330EEa46a18382f251f"));

    try std.testing.expectError(error.InvalidAddress, areAddressesEqual("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678az", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac"));

    try std.testing.expectError(error.InvalidAddress, areAddressesEqual("0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678ac", "0xa5cc3c03994db5b0d9a5eEdD10Cabab0813678aff"));
}

test "contract address generation - CREATE" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const nonce: u64 = 0;

    const addr = try getContractAddress(allocator, deployer, nonce);
    const expected = try fromHex("0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE with nonce 1" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const nonce: u64 = 1;

    const addr = try getContractAddress(allocator, deployer, nonce);
    const expected = try fromHex("0x343c43a37d37dff08ae8c4a11544c718abb4fcf8");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE multiple nonces" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

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
        const addr = try getContractAddress(allocator, deployer, tc.nonce);
        const expected = try fromHex(tc.expected);
        try std.testing.expectEqual(expected, addr);
    }
}

test "contract address generation - CREATE2" {
    const deployer = try fromHex("0x0000000000000000000000000000000000000000");
    const salt = [_]u8{0} ** 32;
    const init_code_hash = [_]u8{0} ** 32;

    const addr = getCreate2Address(deployer, salt, init_code_hash);
    const expected = try fromHex("0x4d1a2e2bb4f88f0250f26ffff098b0b30b26bf38");
    try std.testing.expectEqual(expected, addr);
}

test "contract address generation - CREATE2 deterministic" {
    const deployer = try fromHex("0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    const salt: [32]u8 = .{ 0x12, 0x34, 0x56, 0x78 } ++ .{0} ** 28;
    const init_code_hash: [32]u8 = .{ 0xab, 0xcd, 0xef } ++ .{0} ** 29;

    const addr = getCreate2Address(deployer, salt, init_code_hash);

    // Should generate deterministic address
    const addr2 = getCreate2Address(deployer, salt, init_code_hash);
    try std.testing.expectEqual(addr, addr2);
}

test "calculate_create_address with allocator" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

    const addr = try calculateCreateAddress(allocator, deployer, 0);
    const expected = try fromHex("0xcd234a471b72ba2f1ccf0a70fcaba648a5eecd8d");
    try std.testing.expectEqual(expected, addr);
}

test "calculate_create_address with nonce 1" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");

    const addr = try calculateCreateAddress(allocator, deployer, 1);
    // Verify it's a valid address length and different from nonce 0
    try std.testing.expect(addr.len == 20);

    const addr_nonce_0 = try calculateCreateAddress(allocator, deployer, 0);
    try std.testing.expect(!std.mem.eql(u8, &addr, &addr_nonce_0));
}

test "calculate_create_address with various nonces" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    const nonces = [_]u64{ 0, 1, 2, 10, 255, 256, 65535, 65536, 16777215, 16777216 };

    for (nonces) |nonce| {
        const addr = try calculateCreateAddress(allocator, deployer, nonce);
        try std.testing.expect(addr.len == 20);
    }
}

test "calculate_create_address deterministic with same inputs" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const nonce: u64 = 42;

    const addr1 = try calculateCreateAddress(allocator, deployer, nonce);
    const addr2 = try calculateCreateAddress(allocator, deployer, nonce);

    try std.testing.expectEqual(addr1, addr2);
}

test "calculate_create_address different with different nonce" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    const addr1 = try calculateCreateAddress(allocator, deployer, 1);
    const addr2 = try calculateCreateAddress(allocator, deployer, 2);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address different with different creator" {
    const allocator = std.testing.allocator;
    const nonce: u64 = 0;

    const creator1 = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const creator2 = try fromHex("0x8ba1f109551bD432803012645Hac136c69b95Ee4");

    const addr1 = try calculateCreateAddress(allocator, creator1, nonce);
    const addr2 = try calculateCreateAddress(allocator, creator2, nonce);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address with maximum nonce" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const max_nonce = std.math.maxInt(u64);

    const addr = try calculateCreateAddress(allocator, deployer, max_nonce);
    try std.testing.expect(addr.len == 20);
}

test "calculate_create_address with zero address creator" {
    const allocator = std.testing.allocator;
    const zero_address = try fromHex("0x0000000000000000000000000000000000000000");

    const addr1 = try calculateCreateAddress(allocator, zero_address, 0);
    const addr2 = try calculateCreateAddress(allocator, zero_address, 1);

    try std.testing.expect(addr1.len == 20);
    try std.testing.expect(addr2.len == 20);
    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create_address with maximum address creator" {
    const allocator = std.testing.allocator;
    const max_address = try fromHex("0xffffffffffffffffffffffffffffffffffffffff");

    const addr = try calculateCreateAddress(allocator, max_address, 0);
    try std.testing.expect(addr.len == 20);
}

test "calculate_create_address nonce encoding edge cases" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

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
        const addr = try calculateCreateAddress(allocator, deployer, nonce);
        try std.testing.expect(addr.len == 20);
    }
}

test "calculate_create_address sequential nonces produce different addresses" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");

    var prev_addr: ?Address = null;
    var nonce: u64 = 0;

    while (nonce < 10) : (nonce += 1) {
        const addr = try calculateCreateAddress(allocator, deployer, nonce);

        if (prev_addr) |prev| {
            try std.testing.expect(!std.mem.eql(u8, &prev, &addr));
        }

        prev_addr = addr;
    }
}

test "calculate_create2_address with allocator" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0;
    const init_code: []const u8 = "";

    const addr = try calculateCreate2Address(allocator, deployer, salt, init_code);

    // Hash of empty init code
    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with non-zero salt" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0;
    const init_code: []const u8 = "";

    const addr = try calculateCreate2Address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with non-zero address and salt" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x00000000000000000000000000000000000000000000000000000000cafebabe;
    const init_code: []const u8 = "";

    const addr = try calculateCreate2Address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with init code" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x0000000000000000000000000000000000000000");
    const salt: u256 = 0;
    const init_code = [_]u8{ 0x60, 0x80, 0x60, 0x40, 0x52 }; // Simple bytecode

    const addr = try calculateCreate2Address(allocator, deployer, salt, &init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address with complex init code" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0xdeadbeefcafebabe0123456789abcdef0123456789abcdef0123456789abcdef;
    const init_code = [_]u8{
        0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15, 0x61, 0x00, 0x1b,
        0x57, 0x60, 0x00, 0x80, 0xfd, 0x5b, 0x50, 0x60, 0x40, 0x51, 0x80,
    }; // More complex bytecode

    const addr = try calculateCreate2Address(allocator, deployer, salt, &init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address maximum salt value" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0xffffffffffffffffffffffffffffffffffffffff");
    const salt: u256 = std.math.maxInt(u256);
    const init_code: []const u8 = "";

    const addr = try calculateCreate2Address(allocator, deployer, salt, init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "calculate_create2_address deterministic with same inputs" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x123456789abcdef0;
    const init_code = [_]u8{ 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0xf0 };

    const addr1 = try calculateCreate2Address(allocator, deployer, salt, &init_code);
    const addr2 = try calculateCreate2Address(allocator, deployer, salt, &init_code);

    try std.testing.expectEqual(addr1, addr2);
}

test "calculate_create2_address different with different salt" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const init_code = [_]u8{ 0x60, 0x00 };

    const addr1 = try calculateCreate2Address(allocator, deployer, 0x1, &init_code);
    const addr2 = try calculateCreate2Address(allocator, deployer, 0x2, &init_code);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address different with different deployer" {
    const allocator = std.testing.allocator;
    const salt: u256 = 0x123456789abcdef0;
    const init_code = [_]u8{ 0x60, 0x00 };

    const deployer1 = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const deployer2 = try fromHex("0x8ba1f109551bD432803012645Hac136c69b95Ee4");

    const addr1 = try calculateCreate2Address(allocator, deployer1, salt, &init_code);
    const addr2 = try calculateCreate2Address(allocator, deployer2, salt, &init_code);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address different with different init code" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0x123456789abcdef0;

    const init_code1 = [_]u8{ 0x60, 0x00 };
    const init_code2 = [_]u8{ 0x60, 0x01 };

    const addr1 = try calculateCreate2Address(allocator, deployer, salt, &init_code1);
    const addr2 = try calculateCreate2Address(allocator, deployer, salt, &init_code2);

    try std.testing.expect(!std.mem.eql(u8, &addr1, &addr2));
}

test "calculate_create2_address with large init code" {
    const allocator = std.testing.allocator;
    const deployer = try fromHex("0x742d35Cc6632C0532925a3b8D39c0E6cfC8C74E4");
    const salt: u256 = 0xdeadbeef;

    var large_init_code: [1024]u8 = undefined;
    for (&large_init_code, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const addr = try calculateCreate2Address(allocator, deployer, salt, &large_init_code);

    var expected_hash: [32]u8 = undefined;
    Keccak256.hash(&large_init_code, &expected_hash, .{});

    const expected_addr = getCreate2Address(deployer, @bitCast(salt), expected_hash);
    try std.testing.expectEqual(expected_addr, addr);
}

test "Address - fromBytes with invalid lengths" {
    const too_short = [_]u8{0x01} ** 19;
    const result1 = fromBytes(&too_short);
    try std.testing.expectError(error.InvalidAddressLength, result1);

    const too_long = [_]u8{0x01} ** 21;
    const result2 = fromBytes(&too_long);
    try std.testing.expectError(error.InvalidAddressLength, result2);

    const empty = [_]u8{};
    const result3 = fromBytes(&empty);
    try std.testing.expectError(error.InvalidAddressLength, result3);

    const valid = [_]u8{0x01} ** 20;
    const result4 = try fromBytes(&valid);
    try std.testing.expectEqual(@as(usize, 20), result4.bytes.len);
}

test "Address - toU256 and fromU256 conversions" {
    const zero_addr = zero();
    const zero_u256 = toU256(zero_addr);
    try std.testing.expectEqual(@as(u256, 0), zero_u256);

    const zero_back = fromU256(zero_u256);
    try std.testing.expectEqual(zero_addr, zero_back);

    const test_addr = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const test_u256 = toU256(test_addr);
    const test_back = fromU256(test_u256);
    try std.testing.expectEqual(test_addr, test_back);

    const max_u256: u256 = (@as(u256, 1) << 160) - 1;
    const max_addr = fromU256(max_u256);
    const max_u256_back = toU256(max_addr);
    try std.testing.expectEqual(max_u256, max_u256_back);

    const overflow_u256: u256 = (@as(u256, 1) << 160);
    const overflow_addr = fromU256(overflow_u256);
    try std.testing.expectEqual(zero_addr, overflow_addr);
}

test "Address - isZero function" {
    const zero_addr = zero();
    try std.testing.expect(isZero(zero_addr));

    const zero_addr_const = ZERO_ADDRESS;
    try std.testing.expect(isZero(zero_addr_const));

    const non_zero = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    try std.testing.expect(!isZero(non_zero));

    const almost_zero = try fromHex("0x0000000000000000000000000000000000000001");
    try std.testing.expect(!isZero(almost_zero));
}

test "Address - formatWithCase function" {
    const test_addr = try fromHex("0xabcdef0123456789abcdef0123456789abcdef01");

    const lower = formatWithCase(test_addr, false);
    try std.testing.expectEqualStrings("0xabcdef0123456789abcdef0123456789abcdef01", &lower);

    const upper = formatWithCase(test_addr, true);
    try std.testing.expectEqualStrings("0xABCDEF0123456789ABCDEF0123456789ABCDEF01", &upper);

    const zero_lower = formatWithCase(zero(), false);
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000", &zero_lower);

    const zero_upper = formatWithCase(zero(), true);
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000", &zero_upper);
}

test "Address - fromHex error cases" {
    const too_short = "0x1234";
    const result1 = fromHex(too_short);
    try std.testing.expectError(error.InvalidHexFormat, result1);

    const too_long = "0x" ++ "a" ** 50;
    const result2 = fromHex(too_long);
    try std.testing.expectError(error.InvalidHexFormat, result2);

    const no_prefix = "a0cf798816d4b9b9866b5330eea46a18382f251e";
    const result3 = fromHex(no_prefix);
    try std.testing.expectError(error.InvalidHexFormat, result3);

    const invalid_char = "0xa0cf798816d4b9b9866b5330eea46a18382f251g";
    const result4 = fromHex(invalid_char);
    try std.testing.expectError(error.InvalidHexString, result4);

    const odd_length = "0xa0cf798816d4b9b9866b5330eea46a18382f251";
    const result5 = fromHex(odd_length);
    try std.testing.expectError(error.InvalidHexFormat, result5);
}

test "PublicKey - fromHex error cases" {
    const too_short = "0x04";
    const result1 = PublicKey.fromHex(too_short);
    try std.testing.expectError(error.InvalidPublicKeyLength, result1);

    const no_prefix = "048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const result2 = PublicKey.fromHex(no_prefix);
    try std.testing.expectError(error.InvalidPublicKeyFormat, result2);

    const wrong_prefix = "0x028318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa5";
    const result3 = PublicKey.fromHex(wrong_prefix);
    try std.testing.expectError(error.InvalidPublicKeyPrefix, result3);

    const invalid_char = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aag";
    const result4 = PublicKey.fromHex(invalid_char);
    try std.testing.expectError(error.InvalidHexString, result4);

    const odd_length = "0x048318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed753547f11ca8696646f2f3acb08e31016afac23e630c5d11f59f61fef57b0d2aa";
    const result5 = PublicKey.fromHex(odd_length);
    try std.testing.expectError(error.InvalidPublicKeyLength, result5);
}

test "Address - equals and eql functions" {
    const addr1 = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const addr2 = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const addr3 = try fromHex("0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");

    try std.testing.expect(equals(addr1, addr2));
    try std.testing.expect(eql(addr1, addr2));
    try std.testing.expect(!equals(addr1, addr3));
    try std.testing.expect(!eql(addr1, addr3));

    try std.testing.expect(equals(zero(), zero()));
    try std.testing.expect(eql(ZERO_ADDRESS, ZERO));
}

test "Address - toHex function" {
    const test_addr = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const hex_result = toHex(test_addr);
    try std.testing.expectEqualStrings("0xa0cf798816d4b9b9866b5330eea46a18382f251e", &hex_result);

    const zero_hex = toHex(zero());
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000", &zero_hex);
}

test "Address - toChecksumHex function" {
    const test_addr = try fromHex("0xa0cf798816d4b9b9866b5330eea46a18382f251e");
    const checksum = toChecksumHex(test_addr);
    try std.testing.expectEqualStrings("0xA0Cf798816D4b9b9866b5330EEa46a18382f251e", &checksum);

    const zero_checksum = toChecksumHex(zero());
    try std.testing.expectEqualStrings("0x0000000000000000000000000000000000000000", &zero_checksum);
}
