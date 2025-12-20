const std = @import("std");
const testing = std.testing;
const address = @import("address.zig");
const crypto_pkg = @import("crypto");
const hash = crypto_pkg.Hash;
const crypto = crypto_pkg.Crypto;
const rlp = @import("rlp.zig");
const Address = address.Address;
const Hash = hash.Hash;
const Allocator = std.mem.Allocator;

// EIP-7702 Authorization List

// Authorization error types
pub const AuthorizationError = error{
    InvalidChainId,
    ZeroAddress,
    InvalidSignature,
    OutOfMemory,
};

// Authorization structure
pub const Authorization = struct {
    chain_id: u64,
    address: Address,
    nonce: u64,
    v: u64,
    r: [32]u8,
    s: [32]u8,

    pub fn authority(self: *const Authorization) !Address {
        // Recover the authority (signer) from the authorization
        const h = try self.signingHash();
        const r_value = std.mem.readInt(u256, &self.r, .big);
        const s_value = std.mem.readInt(u256, &self.s, .big);
        const signature = crypto.Signature{
            .v = @intCast(self.v),
            .r = r_value,
            .s = s_value,
        };

        return try crypto.unaudited_recoverAddress(h, signature);
    }

    pub fn signingHash(self: *const Authorization) !Hash {
        const allocator = std.heap.page_allocator;

        // RLP encode [chain_id, address, nonce]
        var list = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer list.deinit();

        // Encode chain_id
        const chain_id_encoded = try rlp.encode(allocator, self.chain_id);
        defer allocator.free(chain_id_encoded);
        try list.appendSlice(chain_id_encoded);

        // Encode address
        const address_encoded = try rlp.encode_bytes(allocator, &self.address.bytes);
        defer allocator.free(address_encoded);
        try list.appendSlice(address_encoded);

        // Encode nonce
        const nonce_encoded = try rlp.encode(allocator, self.nonce);
        defer allocator.free(nonce_encoded);
        try list.appendSlice(nonce_encoded);

        // Wrap in RLP list
        var rlp_list = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer rlp_list.deinit();

        if (list.items.len <= 55) {
            try rlp_list.append(@as(u8, @intCast(0xc0 + list.items.len)));
        } else {
            const len_bytes = try rlp.encode_length(allocator, list.items.len);
            defer allocator.free(len_bytes);
            try rlp_list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try rlp_list.appendSlice(len_bytes);
        }
        try rlp_list.appendSlice(list.items);

        // EIP-7702 uses keccak256(MAGIC || rlp([chain_id, address, nonce]))
        var data = try allocator.alloc(u8, rlp_list.items.len + 1);
        defer allocator.free(data);
        data[0] = 0x05; // MAGIC byte for EIP-7702
        @memcpy(data[1..], rlp_list.items);

        return hash.keccak256(data);
    }

    pub fn validate(self: *const Authorization) !void {
        // Chain ID must be non-zero
        if (self.chain_id == 0) {
            return AuthorizationError.InvalidChainId;
        }

        // Address must not be zero
        if (self.address.isZero()) {
            return AuthorizationError.ZeroAddress;
        }

        // Signature must be valid
        const r_value = std.mem.readInt(u256, &self.r, .big);
        const s_value = std.mem.readInt(u256, &self.s, .big);
        if (!crypto.isValidSignature(.{ .v = @intCast(self.v), .r = r_value, .s = s_value })) {
            return AuthorizationError.InvalidSignature;
        }
    }
};

// Create a signed authorization
pub fn createAuthorization(
    allocator: Allocator,
    chain_id: u64,
    addr: Address,
    nonce: u64,
    private_key: crypto.PrivateKey,
) !Authorization {
    _ = allocator;
    var auth = Authorization{
        .chain_id = chain_id,
        .address = addr,
        .nonce = nonce,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const h = try auth.signingHash();
    const signature = try crypto.unaudited_signHash(h, private_key);

    auth.v = signature.v;
    std.mem.writeInt(u256, &auth.r, signature.r, .big);
    std.mem.writeInt(u256, &auth.s, signature.s, .big);

    return auth;
}

// Authorization list for transaction
pub const AuthorizationList = []const Authorization;

// RLP encode authorization list
pub fn encodeAuthorizationList(allocator: Allocator, auth_list: AuthorizationList) ![]u8 {
    var list = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer list.deinit();

    for (auth_list) |auth| {
        var auth_fields = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer auth_fields.deinit();

        // Encode fields: [chain_id, address, nonce, v, r, s]
        const chain_id_enc = try rlp.encode(allocator, auth.chain_id);
        defer allocator.free(chain_id_enc);
        try auth_fields.appendSlice(chain_id_enc);
        const addr_enc = try rlp.encode_bytes(allocator, &auth.address.bytes);
        defer allocator.free(addr_enc);
        try auth_fields.appendSlice(addr_enc);
        const nonce_enc = try rlp.encode(allocator, auth.nonce);
        defer allocator.free(nonce_enc);
        try auth_fields.appendSlice(nonce_enc);
        const v_enc = try rlp.encode(allocator, auth.v);
        defer allocator.free(v_enc);
        try auth_fields.appendSlice(v_enc);
        const r_enc = try rlp.encode_bytes(allocator, &auth.r);
        defer allocator.free(r_enc);
        try auth_fields.appendSlice(r_enc);
        const s_enc = try rlp.encode_bytes(allocator, &auth.s);
        defer allocator.free(s_enc);
        try auth_fields.appendSlice(s_enc);

        // Wrap authorization in RLP list
        if (auth_fields.items.len <= 55) {
            try list.append(@as(u8, @intCast(0xc0 + auth_fields.items.len)));
        } else {
            const len_bytes = try rlp.encode_length(allocator, auth_fields.items.len);
            defer allocator.free(len_bytes);
            try list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try list.appendSlice(len_bytes);
        }
        try list.appendSlice(auth_fields.items);
    }

    // Wrap entire list
    var result = std.array_list.AlignedManaged(u8, null).init(allocator);
    if (list.items.len <= 55) {
        try result.append(@as(u8, @intCast(0xc0 + list.items.len)));
    } else {
        const len_bytes = rlp.encode_length(list.items.len);
        try result.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
        try result.appendSlice(len_bytes);
    }
    try result.appendSlice(list.items);

    return result.toOwnedSlice();
}

// Delegation designation
pub const DelegationDesignation = struct {
    authority: Address,
    delegated_address: Address,

    pub fn isActive(self: *const DelegationDesignation) bool {
        // Delegation is active if delegated address is not zero
        return !self.delegated_address.is_zero();
    }

    pub fn revoke(self: *DelegationDesignation) void {
        self.delegated_address = Address.ZERO;
    }
};

// Batch authorization processing
pub fn processAuthorizations(
    allocator: Allocator,
    auth_list: AuthorizationList,
) ![]DelegationDesignation {
    var delegations = std.array_list.AlignedManaged(DelegationDesignation, null).init(allocator);
    defer delegations.deinit();

    for (auth_list) |auth| {
        // Validate authorization
        try auth.validate();

        // Recover authority
        const auth_addr = try auth.authority();

        // Create delegation
        try delegations.append(.{
            .authority = auth_addr,
            .delegated_address = auth.address,
        });
    }

    return delegations.toOwnedSlice();
}

// Gas costs for EIP-7702
pub const PER_EMPTY_ACCOUNT_COST = 25000;
pub const PER_AUTH_BASE_COST = 12500;

pub fn calculateAuthorizationGasCost(auth_list: AuthorizationList, empty_accounts: usize) u64 {
    const auth_cost = auth_list.len * PER_AUTH_BASE_COST;
    const empty_cost = empty_accounts * PER_EMPTY_ACCOUNT_COST;
    return auth_cost + empty_cost;
}

// Tests

test "authorization creation and recovery" {
    const allocator = testing.allocator;

    const private_key: crypto.PrivateKey = [_]u8{0x42} ** 32;

    const signer_address = try crypto.getAddress(allocator, private_key);
    const target_address = try Address.fromHex("0x1111111111111111111111111111111111111111");

    const auth = try createAuthorization(
        allocator,
        1, // chain_id
        target_address,
        0, // nonce
        private_key,
    );

    // Validate
    try auth.validate();

    // Recover authority
    const auth_addr = try auth.authority();
    try testing.expectEqual(signer_address, auth_addr);
}

test "authorization validation" {
    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    // Valid
    try auth.validate();

    // Invalid chain ID
    auth.chain_id = 0;
    try testing.expectError(AuthorizationError.InvalidChainId, auth.validate());
    auth.chain_id = 1;

    // Zero address
    auth.address = Address.ZERO;
    try testing.expectError(AuthorizationError.ZeroAddress, auth.validate());
}

test "authorization list encoding" {
    const allocator = testing.allocator;

    const private_key: crypto.PrivateKey = [_]u8{0x42} ** 32;

    const auth1 = try createAuthorization(
        allocator,
        1,
        try Address.fromHex("0x1111111111111111111111111111111111111111"),
        0,
        private_key,
    );

    const auth2 = try createAuthorization(
        allocator,
        1,
        try Address.fromHex("0x2222222222222222222222222222222222222222"),
        1,
        private_key,
    );

    const auth_list = [_]Authorization{ auth1, auth2 };

    const encoded = try encodeAuthorizationList(allocator, &auth_list);
    defer allocator.free(encoded);

    // Should produce valid RLP
    try testing.expect(encoded.len > 0);
    try testing.expect(encoded[0] >= 0xc0); // RLP list prefix
}

test "delegation designation" {
    var delegation = DelegationDesignation{
        .authority = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .delegated_address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
    };

    // Should be active
    try testing.expect(delegation.isActive());

    // Revoke delegation
    delegation.revoke();
    try testing.expect(!delegation.isActive());
    try testing.expectEqual(Address.ZERO, delegation.delegated_address);
}

test "batch authorization processing" {
    const allocator = testing.allocator;

    const private_key1: crypto.PrivateKey = [_]u8{0x01} ** 32;
    const private_key2: crypto.PrivateKey = [_]u8{0x02} ** 32;

    const auth1 = try createAuthorization(
        allocator,
        1,
        try Address.fromHex("0x1111111111111111111111111111111111111111"),
        0,
        private_key1,
    );

    const auth2 = try createAuthorization(
        allocator,
        1,
        try Address.fromHex("0x2222222222222222222222222222222222222222"),
        0,
        private_key2,
    );

    const auth_list = [_]Authorization{ auth1, auth2 };

    const delegations = try processAuthorizations(allocator, &auth_list);
    defer allocator.free(delegations);

    try testing.expectEqual(@as(usize, 2), delegations.len);
    try testing.expect(delegations[0].isActive());
    try testing.expect(delegations[1].isActive());
}

test "authorization gas cost calculation" {
    const auth_list = [_]Authorization{
        .{
            .chain_id = 1,
            .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
            .nonce = 0,
            .v = 27,
            .r = [_]u8{0x12} ** 32,
            .s = [_]u8{0x34} ** 32,
        },
        .{
            .chain_id = 1,
            .address = try Address.fromHex("0x2222222222222222222222222222222222222222"),
            .nonce = 0,
            .v = 27,
            .r = [_]u8{0x56} ** 32,
            .s = [_]u8{0x78} ** 32,
        },
    };

    // 2 authorizations, 1 empty account
    const gas_cost = calculateAuthorizationGasCost(&auth_list, 1);

    // Expected: 2 * 12500 + 1 * 25000 = 50000
    try testing.expectEqual(@as(u64, 50000), gas_cost);
}

test "authority() recovers correct signer address" {
    const allocator = testing.allocator;

    const private_key: crypto.PrivateKey = [_]u8{0x42} ** 32;
    const expected_signer = try crypto.getAddress(allocator, private_key);
    const target = try Address.fromHex("0x1111111111111111111111111111111111111111");

    const auth = try createAuthorization(
        allocator,
        1,
        target,
        0,
        private_key,
    );

    const recovered = try auth.authority();
    try testing.expectEqual(expected_signer, recovered);
}

test "authority() recovers correct signer with different nonces" {
    const allocator = testing.allocator;

    const private_key: crypto.PrivateKey = [_]u8{0x99} ** 32;
    const expected_signer = try crypto.getAddress(allocator, private_key);
    const target = try Address.fromHex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");

    const nonces = [_]u64{ 0, 1, 100, 999999, std.math.maxInt(u64) };

    for (nonces) |nonce| {
        const auth = try createAuthorization(
            allocator,
            1,
            target,
            nonce,
            private_key,
        );

        const recovered = try auth.authority();
        try testing.expectEqual(expected_signer, recovered);
    }
}

test "signingHash() produces consistent hashes" {
    const allocator = testing.allocator;
    _ = allocator;

    const addr = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const auth1 = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = 42,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const auth2 = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = 42,
        .v = 28,
        .r = [_]u8{0xff} ** 32,
        .s = [_]u8{0xaa} ** 32,
    };

    const hash1 = try auth1.signingHash();
    const hash2 = try auth2.signingHash();

    try testing.expectEqual(hash1, hash2);
}

test "signingHash() produces different hashes for different inputs" {
    const allocator = testing.allocator;
    _ = allocator;

    const addr = try Address.fromHex("0x1111111111111111111111111111111111111111");
    const auth1 = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const auth2 = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = 1,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const auth3 = Authorization{
        .chain_id = 2,
        .address = addr,
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const hash1 = try auth1.signingHash();
    const hash2 = try auth2.signingHash();
    const hash3 = try auth3.signingHash();

    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
    try testing.expect(!std.mem.eql(u8, &hash1, &hash3));
    try testing.expect(!std.mem.eql(u8, &hash2, &hash3));
}

test "signingHash() handles edge case nonce values" {
    const allocator = testing.allocator;
    _ = allocator;

    const addr = try Address.fromHex("0x1111111111111111111111111111111111111111");

    const auth_zero = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const auth_max = Authorization{
        .chain_id = 1,
        .address = addr,
        .nonce = std.math.maxInt(u64),
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    const hash_zero = try auth_zero.signingHash();
    const hash_max = try auth_max.signingHash();

    try testing.expect(hash_zero.len == 32);
    try testing.expect(hash_max.len == 32);
    try testing.expect(!std.mem.eql(u8, &hash_zero, &hash_max));
}

test "validate() rejects zero chain ID" {
    const allocator = testing.allocator;
    _ = allocator;

    var auth = Authorization{
        .chain_id = 0,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(AuthorizationError.InvalidChainId, auth.validate());
}

test "validate() rejects zero address" {
    const allocator = testing.allocator;
    _ = allocator;

    var auth = Authorization{
        .chain_id = 1,
        .address = Address.ZERO,
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(AuthorizationError.ZeroAddress, auth.validate());
}

test "validate() rejects signature with r=0" {
    const allocator = testing.allocator;
    _ = allocator;

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(AuthorizationError.InvalidSignature, auth.validate());
}

test "validate() rejects signature with s=0" {
    const allocator = testing.allocator;
    _ = allocator;

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = [_]u8{0} ** 32,
    };

    try testing.expectError(AuthorizationError.InvalidSignature, auth.validate());
}

test "validate() rejects signature with r >= N" {
    const allocator = testing.allocator;
    _ = allocator;

    const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    var r_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, secp256k1_n, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = r_bytes,
        .s = [_]u8{0x34} ** 32,
    };

    try testing.expectError(AuthorizationError.InvalidSignature, auth.validate());
}

test "validate() rejects signature with s >= N" {
    const allocator = testing.allocator;
    _ = allocator;

    const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &s_bytes, secp256k1_n, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = s_bytes,
    };

    try testing.expectError(AuthorizationError.InvalidSignature, auth.validate());
}

test "validate() rejects malleable signature (high S-value)" {
    const allocator = testing.allocator;
    _ = allocator;

    const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    const half_n = secp256k1_n >> 1;
    const high_s = half_n + 1;

    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &s_bytes, high_s, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = [_]u8{0x12} ** 32,
        .s = s_bytes,
    };

    try testing.expectError(AuthorizationError.InvalidSignature, auth.validate());
}

test "validate() accepts signature with s = N/2 (boundary)" {
    const allocator = testing.allocator;
    _ = allocator;

    const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    const half_n = secp256k1_n >> 1;

    var r_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, 0x12345678, .big);

    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &s_bytes, half_n, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = r_bytes,
        .s = s_bytes,
    };

    try auth.validate();
}

test "validate() accepts signature with s = 1 (minimum)" {
    const allocator = testing.allocator;
    _ = allocator;

    var r_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, 0x12345678, .big);

    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &s_bytes, 1, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = r_bytes,
        .s = s_bytes,
    };

    try auth.validate();
}

test "validate() accepts signature with r = N-1 (maximum valid)" {
    const allocator = testing.allocator;
    _ = allocator;

    const secp256k1_n: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    const max_r = secp256k1_n - 1;

    var r_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_bytes, max_r, .big);

    var s_bytes: [32]u8 = undefined;
    std.mem.writeInt(u256, &s_bytes, 0x12345678, .big);

    var auth = Authorization{
        .chain_id = 1,
        .address = try Address.fromHex("0x1111111111111111111111111111111111111111"),
        .nonce = 0,
        .v = 27,
        .r = r_bytes,
        .s = s_bytes,
    };

    try auth.validate();
}
