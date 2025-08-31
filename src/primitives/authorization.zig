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
        const h = try self.signing_hash();
        const r_value = std.mem.readInt(u256, &self.r, .big);
        const s_value = std.mem.readInt(u256, &self.s, .big);
        const signature = crypto.Signature{
            .v = @intCast(self.v),
            .r = r_value,
            .s = s_value,
        };

        const allocator = std.heap.page_allocator;
        const public_key = try crypto.recover_public_key(allocator, h, signature);
        return address.from_public_key(public_key.bytes);
    }

    pub fn signing_hash(self: *const Authorization) !Hash {
        const allocator = std.heap.page_allocator;

        // RLP encode [chain_id, address, nonce]
        var list = std.ArrayList(u8).init(allocator);
        defer list.deinit();

        // Encode chain_id
        try rlp.encode_uint(allocator, self.chain_id, &list);

        // Encode address
        try rlp.encode_bytes(allocator, &self.address.bytes, &list);

        // Encode nonce
        try rlp.encode_uint(allocator, self.nonce, &list);

        // Wrap in RLP list
        var rlp_list = std.ArrayList(u8).init(allocator);
        defer rlp_list.deinit();

        if (list.items.len <= 55) {
            try rlp_list.append(@as(u8, @intCast(0xc0 + list.items.len)));
        } else {
            const len_bytes = rlp.encode_length(list.items.len);
            try rlp_list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try rlp_list.appendSlice(len_bytes);
        }
        try rlp_list.appendSlice(list.items);

        // EIP-7702 uses keccak256(MAGIC || rlp([chain_id, address, nonce]))
        var data: [rlp_list.items.len + 1]u8 = undefined;
        data[0] = 0x05; // MAGIC byte for EIP-7702
        @memcpy(data[1..], rlp_list.items);

        return hash.keccak256(&data);
    }

    pub fn validate(self: *const Authorization) !void {
        // Chain ID must be non-zero
        if (self.chain_id == 0) {
            return AuthorizationError.InvalidChainId;
        }

        // Address must not be zero
        if (self.address.is_zero()) {
            return AuthorizationError.ZeroAddress;
        }

        // Signature must be valid
        const r_value = std.mem.readInt(u256, &self.r, .big);
        const s_value = std.mem.readInt(u256, &self.s, .big);
        if (!crypto.is_valid_signature(.{ .v = @intCast(self.v), .r = r_value, .s = s_value })) {
            return AuthorizationError.InvalidSignature;
        }
    }
};

// Create a signed authorization
pub fn create_authorization(
    allocator: Allocator,
    chain_id: u64,
    addr: Address,
    nonce: u64,
    private_key: crypto.PrivateKey,
) !Authorization {
    var auth = Authorization{
        .chain_id = chain_id,
        .address = addr,
        .nonce = nonce,
        .v = 0,
        .r = [_]u8{0} ** 32,
        .s = [_]u8{0} ** 32,
    };

    const h = try auth.signing_hash();
    const signature = try crypto.sign(allocator, private_key, h);

    auth.v = signature.v;
    std.mem.writeInt(u256, &auth.r, signature.r, .big);
    std.mem.writeInt(u256, &auth.s, signature.s, .big);

    return auth;
}

// Authorization list for transaction
pub const AuthorizationList = []const Authorization;

// RLP encode authorization list
pub fn encode_authorization_list(allocator: Allocator, auth_list: AuthorizationList) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    for (auth_list) |auth| {
        var auth_fields = std.ArrayList(u8).init(allocator);
        defer auth_fields.deinit();

        // Encode fields: [chain_id, address, nonce, v, r, s]
        try rlp.encode_uint(allocator, auth.chain_id, &auth_fields);
        try rlp.encode_bytes(allocator, &auth.address.bytes, &auth_fields);
        try rlp.encode_uint(allocator, auth.nonce, &auth_fields);
        try rlp.encode_uint(allocator, auth.v, &auth_fields);
        try rlp.encode_bytes(allocator, &auth.r, &auth_fields);
        try rlp.encode_bytes(allocator, &auth.s, &auth_fields);

        // Wrap authorization in RLP list
        if (auth_fields.items.len <= 55) {
            try list.append(@as(u8, @intCast(0xc0 + auth_fields.items.len)));
        } else {
            const len_bytes = rlp.encode_length(auth_fields.items.len);
            try list.append(@as(u8, @intCast(0xf7 + len_bytes.len)));
            try list.appendSlice(len_bytes);
        }
        try list.appendSlice(auth_fields.items);
    }

    // Wrap entire list
    var result = std.ArrayList(u8).init(allocator);
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

    pub fn is_active(self: *const DelegationDesignation) bool {
        // Delegation is active if delegated address is not zero
        return !self.delegated_address.is_zero();
    }

    pub fn revoke(self: *DelegationDesignation) void {
        self.delegated_address = Address.ZERO;
    }
};

// Batch authorization processing
pub fn process_authorizations(
    allocator: Allocator,
    auth_list: AuthorizationList,
) ![]DelegationDesignation {
    var delegations = std.ArrayList(DelegationDesignation).init(allocator);
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

pub fn calculate_authorization_gas_cost(auth_list: AuthorizationList, empty_accounts: usize) u64 {
    const auth_cost = auth_list.len * PER_AUTH_BASE_COST;
    const empty_cost = empty_accounts * PER_EMPTY_ACCOUNT_COST;
    return auth_cost + empty_cost;
}

// Tests

test "authorization creation and recovery" {
    const allocator = testing.allocator;

    const private_key: crypto.PrivateKey = [_]u8{0x42} ** 32;

    const signer_address = try crypto.getAddress(allocator, private_key);
    const target_address = try Address.from_hex("0x1111111111111111111111111111111111111111");

    const auth = try create_authorization(
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
        .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
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

    const auth1 = try create_authorization(
        allocator,
        1,
        try Address.from_hex("0x1111111111111111111111111111111111111111"),
        0,
        private_key,
    );

    const auth2 = try create_authorization(
        allocator,
        1,
        try Address.from_hex("0x2222222222222222222222222222222222222222"),
        1,
        private_key,
    );

    const auth_list = [_]Authorization{ auth1, auth2 };

    const encoded = try encode_authorization_list(allocator, &auth_list);
    defer allocator.free(encoded);

    // Should produce valid RLP
    try testing.expect(encoded.len > 0);
    try testing.expect(encoded[0] >= 0xc0); // RLP list prefix
}

test "delegation designation" {
    var delegation = DelegationDesignation{
        .authority = try Address.from_hex("0x1111111111111111111111111111111111111111"),
        .delegated_address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
    };

    // Should be active
    try testing.expect(delegation.is_active());

    // Revoke delegation
    delegation.revoke();
    try testing.expect(!delegation.is_active());
    try testing.expectEqual(Address.ZERO, delegation.delegated_address);
}

test "batch authorization processing" {
    const allocator = testing.allocator;

    const private_key1: crypto.PrivateKey = [_]u8{0x01} ** 32;
    const private_key2: crypto.PrivateKey = [_]u8{0x02} ** 32;

    const auth1 = try create_authorization(
        allocator,
        1,
        try Address.from_hex("0x1111111111111111111111111111111111111111"),
        0,
        private_key1,
    );

    const auth2 = try create_authorization(
        allocator,
        1,
        try Address.from_hex("0x2222222222222222222222222222222222222222"),
        0,
        private_key2,
    );

    const auth_list = [_]Authorization{ auth1, auth2 };

    const delegations = try process_authorizations(allocator, &auth_list);
    defer allocator.free(delegations);

    try testing.expectEqual(@as(usize, 2), delegations.len);
    try testing.expect(delegations[0].is_active());
    try testing.expect(delegations[1].is_active());
}

test "authorization gas cost calculation" {
    const auth_list = [_]Authorization{
        .{
            .chain_id = 1,
            .address = try Address.from_hex("0x1111111111111111111111111111111111111111"),
            .nonce = 0,
            .v = 27,
            .r = [_]u8{0x12} ** 32,
            .s = [_]u8{0x34} ** 32,
        },
        .{
            .chain_id = 1,
            .address = try Address.from_hex("0x2222222222222222222222222222222222222222"),
            .nonce = 0,
            .v = 27,
            .r = [_]u8{0x56} ** 32,
            .s = [_]u8{0x78} ** 32,
        },
    };

    // 2 authorizations, 1 empty account
    const gas_cost = calculate_authorization_gas_cost(&auth_list, 1);

    // Expected: 2 * 12500 + 1 * 25000 = 50000
    try testing.expectEqual(@as(u64, 50000), gas_cost);
}
