const std = @import("std");
const testing = std.testing;
const address = @import("address.zig");
const crypto_pkg = @import("crypto");
const hash = crypto_pkg.Hash;
const crypto = crypto_pkg.Crypto;
const hex = @import("hex.zig");
const Address = address.Address;
const Hash = hash.Hash;
const Allocator = std.mem.Allocator;

// SIWE error types
pub const SiweError = error{
    EmptyDomain,
    EmptyUri,
    InvalidVersion,
    EmptyNonce,
    InvalidIssuedAt,
    InvalidExpirationTime,
    InvalidNotBefore,
    InvalidFormat,
    OutOfMemory,
};

// Sign-In with Ethereum (EIP-4361) Message
pub const SiweMessage = struct {
    domain: []const u8,
    address: Address,
    statement: ?[]const u8,
    uri: []const u8,
    version: []const u8,
    chain_id: u16,
    nonce: []const u8,
    issued_at: []const u8,
    expiration_time: ?[]const u8,
    not_before: ?[]const u8,
    request_id: ?[]const u8,
    resources: ?[]const []const u8,

    pub fn format(self: *const SiweMessage, allocator: Allocator) ![]u8 {
        var result = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer result.deinit();

        // Header
        try result.appendSlice(self.domain);
        try result.appendSlice(" wants you to sign in with your Ethereum account:\n");

        // Address
        const addr_hex = try hex.to_hex(allocator, &self.address);
        defer allocator.free(addr_hex);
        try result.appendSlice(addr_hex);
        try result.appendSlice("\n\n");

        // Statement (optional)
        if (self.statement) |stmt| {
            try result.appendSlice(stmt);
            try result.appendSlice("\n\n");
        }

        // URI
        try result.appendSlice("URI: ");
        try result.appendSlice(self.uri);
        try result.appendSlice("\n");

        // Version
        try result.appendSlice("Version: ");
        try result.appendSlice(self.version);
        try result.appendSlice("\n");

        // Chain ID
        try result.appendSlice("Chain ID: ");
        try result.writer().print("{d}", .{self.chain_id});
        try result.appendSlice("\n");

        // Nonce
        try result.appendSlice("Nonce: ");
        try result.appendSlice(self.nonce);
        try result.appendSlice("\n");

        // Issued At
        try result.appendSlice("Issued At: ");
        try result.appendSlice(self.issued_at);

        // Optional fields
        if (self.expiration_time) |exp| {
            try result.appendSlice("\nExpiration Time: ");
            try result.appendSlice(exp);
        }

        if (self.not_before) |nb| {
            try result.appendSlice("\nNot Before: ");
            try result.appendSlice(nb);
        }

        if (self.request_id) |rid| {
            try result.appendSlice("\nRequest ID: ");
            try result.appendSlice(rid);
        }

        if (self.resources) |res| {
            try result.appendSlice("\nResources:");
            for (res) |resource| {
                try result.appendSlice("\n- ");
                try result.appendSlice(resource);
            }
        }

        return result.to_owned_slice();
    }

    pub fn validate(self: *const SiweMessage) !void {
        // Domain must not be empty
        if (self.domain.len == 0) {
            return SiweError.EmptyDomain;
        }

        // URI must be valid
        if (self.uri.len == 0) {
            return SiweError.EmptyUri;
        }

        // Version must be "1"
        if (!std.mem.eql(u8, self.version, "1")) {
            return SiweError.InvalidVersion;
        }

        // Nonce must not be empty
        if (self.nonce.len == 0) {
            return SiweError.EmptyNonce;
        }

        // Validate timestamp formats (simplified)
        if (!is_valid_timestamp(self.issued_at)) {
            return SiweError.InvalidIssuedAt;
        }

        if (self.expiration_time) |exp| {
            if (!is_valid_timestamp(exp)) {
                return SiweError.InvalidExpirationTime;
            }
        }

        if (self.not_before) |nb| {
            if (!is_valid_timestamp(nb)) {
                return SiweError.InvalidNotBefore;
            }
        }
    }
};

fn is_valid_timestamp(timestamp: []const u8) bool {
    // Simplified ISO 8601 validation
    // Format: YYYY-MM-DDTHH:MM:SSZ
    if (timestamp.len < 20) return false;
    if (timestamp[4] != '-' or timestamp[7] != '-') return false;
    if (timestamp[10] != 'T') return false;
    if (timestamp[13] != ':' or timestamp[16] != ':') return false;
    if (timestamp[timestamp.len - 1] != 'Z') return false;
    return true;
}

// SIWE message verification
pub fn verify_siwe_message(
    allocator: Allocator,
    message: *const SiweMessage,
    signature: crypto.Signature,
) !bool {
    // Validate message structure
    try message.validate();

    // Format message
    const formatted = try message.format(allocator);
    defer allocator.free(formatted);

    // Hash with EIP-191
    const message_hash = try hash.eip_191_hash_message(formatted, allocator);

    // Recover signer
    const public_key = try crypto.recover_public_key(allocator, message_hash, signature);
    const recovered_address = address.from_public_key(public_key.bytes);

    // Check if recovered address matches
    return recovered_address.eql(message.address);
}

// Parse SIWE message from string
pub fn parse_siwe_message(allocator: Allocator, text: []const u8) !SiweMessage {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');

    // Parse header
    const header = lines.next() orelse return SiweError.InvalidFormat;
    const domain_end = std.mem.indexOf(u8, header, " wants you") orelse return SiweError.InvalidFormat;
    const domain = header[0..domain_end];

    // Parse address
    const addr_line = lines.next() orelse return SiweError.InvalidFormat;
    const addr = try address.from_hex(addr_line);

    // Skip empty line
    _ = lines.next();

    // Parse statement (optional)
    var statement: ?[]const u8 = null;
    var next_line = lines.next() orelse return SiweError.InvalidFormat;

    if (!std.mem.startsWith(u8, next_line, "URI: ")) {
        statement = next_line;
        _ = lines.next(); // Skip empty line
        next_line = lines.next() orelse return SiweError.InvalidFormat;
    }

    // Parse required fields
    if (!std.mem.startsWith(u8, next_line, "URI: ")) return SiweError.InvalidFormat;
    const uri = next_line[5..];

    const version_line = lines.next() orelse return SiweError.InvalidFormat;
    if (!std.mem.startsWith(u8, version_line, "Version: ")) return SiweError.InvalidFormat;
    const version = version_line[9..];

    const chain_line = lines.next() orelse return SiweError.InvalidFormat;
    if (!std.mem.startsWith(u8, chain_line, "Chain ID: ")) return SiweError.InvalidFormat;
    const chain_id = try std.fmt.parseInt(u64, chain_line[10..], 10);

    const nonce_line = lines.next() orelse return SiweError.InvalidFormat;
    if (!std.mem.startsWith(u8, nonce_line, "Nonce: ")) return SiweError.InvalidFormat;
    const nonce = nonce_line[7..];

    const issued_line = lines.next() orelse return SiweError.InvalidFormat;
    if (!std.mem.startsWith(u8, issued_line, "Issued At: ")) return SiweError.InvalidFormat;
    const issued_at = issued_line[11..];

    // Allocate copies
    return SiweMessage{
        .domain = try allocator.dupe(u8, domain),
        .address = addr,
        .statement = if (statement) |s| try allocator.dupe(u8, s) else null,
        .uri = try allocator.dupe(u8, uri),
        .version = try allocator.dupe(u8, version),
        .chain_id = chain_id,
        .nonce = try allocator.dupe(u8, nonce),
        .issued_at = try allocator.dupe(u8, issued_at),
        .expiration_time = null,
        .not_before = null,
        .request_id = null,
        .resources = null,
    };
}

// Tests

test "SIWE message formatting" {
    const allocator = testing.allocator;

    const message = SiweMessage{
        .domain = "example.com",
        .address = try address.fromHex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        .statement = "Sign in to Example",
        .uri = "https://example.com",
        .version = "1",
        .chain_id = 1,
        .nonce = "32891756",
        .issued_at = "2021-09-30T16:25:24Z",
        .expiration_time = null,
        .not_before = null,
        .request_id = null,
        .resources = null,
    };

    const formatted = try message.format(allocator);
    defer allocator.free(formatted);

    // Check key components
    try testing.expect(std.mem.indexOf(u8, formatted, "example.com wants you") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Sign in to Example") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Chain ID: 1") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Nonce: 32891756") != null);
}

test "SIWE message with all fields" {
    const allocator = testing.allocator;

    const resources = [_][]const u8{
        "https://example.com/my-account",
        "https://example.com/settings",
    };

    const message = SiweMessage{
        .domain = "example.com",
        .address = try address.fromHex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        .statement = "Sign in to Example",
        .uri = "https://example.com",
        .version = "1",
        .chain_id = 1,
        .nonce = "32891756",
        .issued_at = "2021-09-30T16:25:24Z",
        .expiration_time = "2021-10-01T16:25:24Z",
        .not_before = "2021-09-30T16:00:00Z",
        .request_id = "some-request-id",
        .resources = &resources,
    };

    const formatted = try message.format(allocator);
    defer allocator.free(formatted);

    // Check optional fields
    try testing.expect(std.mem.indexOf(u8, formatted, "Expiration Time: 2021-10-01T16:25:24Z") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Not Before: 2021-09-30T16:00:00Z") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Request ID: some-request-id") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "Resources:") != null);
    try testing.expect(std.mem.indexOf(u8, formatted, "- https://example.com/my-account") != null);
}

test "SIWE message validation" {
    var message = SiweMessage{
        .domain = "example.com",
        .address = try address.fromHex("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        .statement = null,
        .uri = "https://example.com",
        .version = "1",
        .chain_id = 1,
        .nonce = "32891756",
        .issued_at = "2021-09-30T16:25:24Z",
        .expiration_time = null,
        .not_before = null,
        .request_id = null,
        .resources = null,
    };

    // Valid message
    try message.validate();

    // Empty domain
    message.domain = "";
    try testing.expectError(SiweError.EmptyDomain, message.validate());
    message.domain = "example.com";

    // Empty URI
    message.uri = "";
    try testing.expectError(SiweError.EmptyUri, message.validate());
    message.uri = "https://example.com";

    // Invalid version
    message.version = "2";
    try testing.expectError(SiweError.InvalidVersion, message.validate());
    message.version = "1";

    // Empty nonce
    message.nonce = "";
    try testing.expectError(SiweError.EmptyNonce, message.validate());
    message.nonce = "32891756";

    // Invalid timestamp
    message.issued_at = "not-a-timestamp";
    try testing.expectError(SiweError.InvalidIssuedAt, message.validate());
}

test "SIWE message signature verification" {
    const allocator = testing.allocator;

    const private_key = crypto.PrivateKey{
        .bytes = [_]u8{0x42} ** 32,
    };

    const signer_address = try crypto.get_address(allocator, private_key);

    const message = SiweMessage{
        .domain = "example.com",
        .address = signer_address,
        .statement = "Sign in to Example",
        .uri = "https://example.com",
        .version = "1",
        .chain_id = 1,
        .nonce = "32891756",
        .issued_at = "2021-09-30T16:25:24Z",
        .expiration_time = null,
        .not_before = null,
        .request_id = null,
        .resources = null,
    };

    // Format and sign
    const formatted = try message.format(allocator);
    defer allocator.free(formatted);

    const signature = try crypto.personal_sign(allocator, private_key, formatted);

    // Verify
    const verified = try verify_siwe_message(allocator, &message, signature);
    try testing.expect(verified);

    // Verify with wrong address should fail
    var wrong_message = message;
    wrong_message.address = Address.ZERO;
    const not_verified = try verify_siwe_message(allocator, &wrong_message, signature);
    try testing.expect(!not_verified);
}

test "SIWE message parsing" {
    const allocator = testing.allocator;

    const text =
        \\example.com wants you to sign in with your Ethereum account:
        \\0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        \\
        \\Sign in to Example
        \\
        \\URI: https://example.com
        \\Version: 1
        \\Chain ID: 1
        \\Nonce: 32891756
        \\Issued At: 2021-09-30T16:25:24Z
    ;

    const parsed = try parse_siwe_message(allocator, text);
    defer {
        allocator.free(parsed.domain);
        if (parsed.statement) |s| allocator.free(s);
        allocator.free(parsed.uri);
        allocator.free(parsed.version);
        allocator.free(parsed.nonce);
        allocator.free(parsed.issued_at);
    }

    try testing.expectEqualStrings("example.com", parsed.domain);
    try testing.expectEqualStrings("Sign in to Example", parsed.statement.?);
    try testing.expectEqualStrings("https://example.com", parsed.uri);
    try testing.expectEqual(@as(u64, 1), parsed.chain_id);
}
