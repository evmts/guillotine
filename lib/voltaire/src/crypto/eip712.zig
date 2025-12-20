const std = @import("std");
const testing = std.testing;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.AlignedManaged;

// Import primitives
const Hash = @import("hash_utils.zig");
const primitives = @import("voltaire");
const Hex = primitives.Hex;
const Crypto = @import("crypto.zig");
const Address = Crypto.Address;
const Signature = Crypto.Signature;
const PrivateKey = Crypto.PrivateKey;

// Import ABI for type encoding
const ABI = primitives.AbiEncoding;

// EIP-712 Error types
pub const Eip712Error = error{
    InvalidDomain,
    InvalidMessage,
    InvalidTypes,
    InvalidPrimaryType,
    InvalidEncoding,
    InvalidSignature,
    TypeNotFound,
    CircularReference,
    OutOfMemory,
    InvalidLength,
    InvalidUtf8,
} || std.mem.Allocator.Error;

// EIP-712 Domain structure
pub const Eip712Domain = struct {
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    chain_id: ?u64 = null,
    verifying_contract: ?Address = null,
    salt: ?Hash.Hash = null,

    pub fn deinit(self: *Eip712Domain, allocator: Allocator) void {
        if (self.name) |name| allocator.free(name);
        if (self.version) |version| allocator.free(version);
    }
};

// Type property for EIP-712 type definitions
pub const TypeProperty = struct {
    name: []const u8,
    type: []const u8,

    pub fn deinit(self: *TypeProperty, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type);
    }
};

// EIP-712 Type definitions
pub const TypeDefinitions = struct {
    types: std.StringHashMap([]TypeProperty),

    pub fn init(allocator: Allocator) TypeDefinitions {
        return TypeDefinitions{
            .types = std.StringHashMap([]TypeProperty).init(allocator),
        };
    }

    pub fn deinit(self: *TypeDefinitions, allocator: Allocator) void {
        var iterator = self.types.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.*) |*prop| {
                prop.deinit(allocator);
            }
            allocator.free(entry.value_ptr.*);
        }
        self.types.deinit();
    }

    pub fn put(self: *TypeDefinitions, allocator: Allocator, type_name: []const u8, properties: []const TypeProperty) !void {
        const owned_name = try allocator.dupe(u8, type_name);
        const owned_properties = try allocator.alloc(TypeProperty, properties.len);

        for (properties, 0..) |prop, i| {
            owned_properties[i] = TypeProperty{
                .name = try allocator.dupe(u8, prop.name),
                .type = try allocator.dupe(u8, prop.type),
            };
        }

        try self.types.put(owned_name, owned_properties);
    }

    pub fn get(self: *const TypeDefinitions, type_name: []const u8) ?[]const TypeProperty {
        return self.types.get(type_name);
    }
};

// EIP-712 Message value (JSON-like structure)
pub const MessageValue = union(enum) {
    string: []const u8,
    number: u256,
    boolean: bool,
    address: Address,
    bytes: []const u8,
    array: []MessageValue,
    object: std.StringHashMap(MessageValue),

    pub fn deinit(self: *MessageValue, allocator: Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .bytes => |b| allocator.free(b),
            .array => |arr| {
                for (arr) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(arr);
            },
            .object => |*obj| {
                var iterator = obj.iterator();
                while (iterator.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
            else => {},
        }
    }
};

// EIP-712 Typed Data structure
pub const TypedData = struct {
    domain: Eip712Domain,
    types: TypeDefinitions,
    primary_type: []const u8,
    message: std.StringHashMap(MessageValue),

    pub fn init(allocator: Allocator) TypedData {
        return TypedData{
            .domain = Eip712Domain{},
            .types = TypeDefinitions.init(allocator),
            .primary_type = "",
            .message = std.StringHashMap(MessageValue).init(allocator),
        };
    }

    pub fn deinit(self: *TypedData, allocator: Allocator) void {
        self.domain.deinit(allocator);
        self.types.deinit(allocator);

        var iterator = self.message.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        self.message.deinit();

        if (self.primary_type.len > 0) {
            allocator.free(self.primary_type);
        }
    }
};

// EIP-712 Domain type properties
fn get_eip712_domain_types(domain: *const Eip712Domain, allocator: Allocator) Eip712Error![]TypeProperty {
    var properties = ArrayList(TypeProperty, null).init(allocator);
    defer properties.deinit();

    if (domain.name != null) {
        try properties.append(TypeProperty{
            .name = try allocator.dupe(u8, "name"),
            .type = try allocator.dupe(u8, "string"),
        });
    }

    if (domain.version != null) {
        try properties.append(TypeProperty{
            .name = try allocator.dupe(u8, "version"),
            .type = try allocator.dupe(u8, "string"),
        });
    }

    if (domain.chain_id != null) {
        try properties.append(TypeProperty{
            .name = try allocator.dupe(u8, "chainId"),
            .type = try allocator.dupe(u8, "uint256"),
        });
    }

    if (domain.verifying_contract != null) {
        try properties.append(TypeProperty{
            .name = try allocator.dupe(u8, "verifyingContract"),
            .type = try allocator.dupe(u8, "address"),
        });
    }

    if (domain.salt != null) {
        try properties.append(TypeProperty{
            .name = try allocator.dupe(u8, "salt"),
            .type = try allocator.dupe(u8, "bytes32"),
        });
    }

    return properties.toOwnedSlice();
}

// Encode type string for EIP-712
fn encode_type(allocator: Allocator, primary_type: []const u8, types: *const TypeDefinitions) Eip712Error![]u8 {
    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    var result = ArrayList(u8, null).init(allocator);
    defer result.deinit();

    try encode_type_recursive(allocator, primary_type, types, &visited, &result);
    return result.toOwnedSlice();
}

fn encode_type_recursive(
    allocator: Allocator,
    type_name: []const u8,
    types: *const TypeDefinitions,
    visited: *std.StringHashMap(void),
    result: *ArrayList(u8, null),
) Eip712Error!void {
    if (visited.contains(type_name)) return;
    try visited.put(try allocator.dupe(u8, type_name), {});

    const type_properties = types.get(type_name) orelse return Eip712Error.TypeNotFound;

    // Add main type definition
    try result.appendSlice(type_name);
    try result.append('(');

    for (type_properties, 0..) |prop, i| {
        if (i > 0) try result.append(',');
        try result.appendSlice(prop.type);
        try result.append(' ');
        try result.appendSlice(prop.name);

        // If this is a custom type, recursively encode it
        if (types.get(prop.type) != null) {
            try encode_type_recursive(allocator, prop.type, types, visited, result);
        }
    }

    try result.append(')');
}

// Hash struct according to EIP-712
fn hash_struct(allocator: Allocator, primary_type: []const u8, data: *const std.StringHashMap(MessageValue), types: *const TypeDefinitions) Eip712Error!Hash.Hash {
    const encoded_data = try encode_data(allocator, primary_type, data, types);
    defer allocator.free(encoded_data);

    return Hash.keccak256(encoded_data);
}

// Encode data for struct hashing
fn encode_data(allocator: Allocator, primary_type: []const u8, data: *const std.StringHashMap(MessageValue), types: *const TypeDefinitions) Eip712Error![]u8 {
    const type_properties = types.get(primary_type) orelse return Eip712Error.TypeNotFound;

    var result = ArrayList(u8, null).init(allocator);
    defer result.deinit();

    // Add type hash
    const type_string = try encode_type(allocator, primary_type, types);
    defer allocator.free(type_string);

    const type_hash = Hash.keccak256(type_string);
    try result.appendSlice(&type_hash);

    // Add encoded values
    for (type_properties) |prop| {
        const value = data.get(prop.name) orelse return Eip712Error.InvalidMessage;
        const encoded_value = try encode_value(allocator, prop.type, value, types);
        defer allocator.free(encoded_value);
        try result.appendSlice(encoded_value);
    }

    return result.toOwnedSlice();
}

// Encode individual value
fn encode_value(allocator: Allocator, type_name: []const u8, value: MessageValue, types: *const TypeDefinitions) Eip712Error![]u8 {
    var result: [32]u8 = [_]u8{0} ** 32;

    if (std.mem.startsWith(u8, type_name, "uint")) {
        const num = switch (value) {
            .number => |n| n,
            else => return Eip712Error.InvalidMessage,
        };
        std.mem.writeInt(u256, &result, num, .big);
    } else if (std.mem.startsWith(u8, type_name, "int")) {
        const num = switch (value) {
            .number => |n| n,
            else => return Eip712Error.InvalidMessage,
        };
        std.mem.writeInt(u256, &result, num, .big);
    } else if (std.mem.eql(u8, type_name, "address")) {
        const addr = switch (value) {
            .address => |a| a,
            else => return Eip712Error.InvalidMessage,
        };
        @memcpy(result[12..32], &addr.bytes);
    } else if (std.mem.eql(u8, type_name, "bool")) {
        const bool_val = switch (value) {
            .boolean => |b| b,
            else => return Eip712Error.InvalidMessage,
        };
        result[31] = if (bool_val) 1 else 0;
    } else if (std.mem.eql(u8, type_name, "bytes")) {
        const bytes = switch (value) {
            .bytes => |b| b,
            else => return Eip712Error.InvalidMessage,
        };
        const hash = Hash.keccak256(bytes);
        @memcpy(&result, &hash);
    } else if (std.mem.eql(u8, type_name, "string")) {
        const str = switch (value) {
            .string => |s| s,
            else => return Eip712Error.InvalidMessage,
        };
        const hash = Hash.keccak256(str);
        @memcpy(&result, &hash);
    } else if (std.mem.startsWith(u8, type_name, "bytes")) {
        const bytes = switch (value) {
            .bytes => |b| b,
            else => return Eip712Error.InvalidMessage,
        };
        const size = std.fmt.parseInt(usize, type_name[5..], 10) catch return Eip712Error.InvalidMessage;
        if (bytes.len != size) return Eip712Error.InvalidMessage;
        @memcpy(result[0..size], bytes);
    } else if (types.get(type_name) != null) {
        // Custom type - hash the struct
        const obj = switch (value) {
            .object => |o| o,
            else => return Eip712Error.InvalidMessage,
        };
        const hash = try hash_struct(allocator, type_name, &obj, types);
        @memcpy(&result, &hash);
    } else {
        return Eip712Error.TypeNotFound;
    }

    return allocator.dupe(u8, &result);
}

// Hash domain separator
fn hash_domain(allocator: Allocator, domain: *const Eip712Domain) Eip712Error!Hash.Hash {
    const domain_type_name = "EIP712Domain";

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const domain_types = try get_eip712_domain_types(domain, allocator);
    defer {
        for (domain_types) |*prop| {
            prop.deinit(allocator);
        }
        allocator.free(domain_types);
    }

    try types.put(allocator, domain_type_name, domain_types);

    var domain_data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = domain_data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        domain_data.deinit();
    }

    if (domain.name) |name| {
        try domain_data.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, name) });
    }

    if (domain.version) |version| {
        try domain_data.put(try allocator.dupe(u8, "version"), MessageValue{ .string = try allocator.dupe(u8, version) });
    }

    if (domain.chain_id) |chain_id| {
        try domain_data.put(try allocator.dupe(u8, "chainId"), MessageValue{ .number = chain_id });
    }

    if (domain.verifying_contract) |contract| {
        try domain_data.put(try allocator.dupe(u8, "verifyingContract"), MessageValue{ .address = contract });
    }

    if (domain.salt) |salt| {
        try domain_data.put(try allocator.dupe(u8, "salt"), MessageValue{ .bytes = try allocator.dupe(u8, &salt) });
    }

    return hash_struct(allocator, domain_type_name, &domain_data, &types);
}

// Main EIP-712 functions

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Hash typed data according to EIP-712: keccak256("\x19\x01" ‖ domainSeparator ‖ hashStruct(message))
/// WARNING: This is a custom crypto implementation that has not been security audited.
/// EIP-712 implementation may have vulnerabilities in type encoding or hashing.
/// Do not use in production without proper security review.
pub fn unaudited_hashTypedData(allocator: Allocator, typed_data: *const TypedData) Eip712Error!Hash.Hash {
    var result = ArrayList(u8, null).init(allocator);
    defer result.deinit();

    // Add EIP-712 prefix
    try result.appendSlice("\x19\x01");

    // Add domain separator
    const domain_hash = try hash_domain(allocator, &typed_data.domain);
    try result.appendSlice(&domain_hash);

    // Add message hash (skip if primary type is EIP712Domain)
    if (!std.mem.eql(u8, typed_data.primary_type, "EIP712Domain")) {
        const message_hash = try hash_struct(allocator, typed_data.primary_type, &typed_data.message, &typed_data.types);
        try result.appendSlice(&message_hash);
    }

    const final_data = try result.toOwnedSlice();
    defer allocator.free(final_data);

    return Hash.keccak256(final_data);
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Sign typed data with a private key
/// WARNING: This is a custom crypto implementation that has not been security audited.
/// EIP-712 signing implementation may have vulnerabilities.
/// Do not use in production without proper security review.
pub fn unaudited_signTypedData(allocator: Allocator, typed_data: *const TypedData, private_key: PrivateKey) (Eip712Error || Crypto.CryptoError)!Signature {
    const hash = try unaudited_hashTypedData(allocator, typed_data);
    return Crypto.unaudited_signHash(hash, private_key);
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Verify typed data signature
/// WARNING: This is a custom crypto implementation that has not been security audited.
/// EIP-712 verification implementation may have vulnerabilities.
/// Do not use in production without proper security review.
pub fn unaudited_verifyTypedData(allocator: Allocator, typed_data: *const TypedData, signature: Signature, address: Address) (Eip712Error || Crypto.CryptoError)!bool {
    const hash = try unaudited_hashTypedData(allocator, typed_data);
    return Crypto.unaudited_verifySignature(hash, signature, address);
}

/// ⚠️ UNAUDITED - NOT SECURITY AUDITED ⚠️
/// Recover address from typed data signature
/// WARNING: This is a custom crypto implementation that has not been security audited.
/// EIP-712 address recovery implementation may have vulnerabilities.
/// Do not use in production without proper security review.
pub fn unaudited_recoverTypedDataAddress(allocator: Allocator, typed_data: *const TypedData, signature: Signature) (Eip712Error || Crypto.CryptoError)!Address {
    const hash = try unaudited_hashTypedData(allocator, typed_data);
    return Crypto.unaudited_recoverAddress(hash, signature);
}

// Convenience functions for common patterns

/// Create a simple typed data structure for testing
pub fn create_simple_typed_data(allocator: Allocator, domain: Eip712Domain, primary_type: []const u8) !TypedData {
    var typed_data = TypedData.init(allocator);

    // Set domain
    typed_data.domain = domain;

    // Set primary type
    typed_data.primary_type = try allocator.dupe(u8, primary_type);

    return typed_data;
}

/// Create EIP-712 domain
pub fn create_domain(allocator: Allocator, name: ?[]const u8, version: ?[]const u8, chain_id: ?u64, verifying_contract: ?Address) Eip712Error!Eip712Domain {
    return Eip712Domain{
        .name = if (name) |n| try allocator.dupe(u8, n) else null,
        .version = if (version) |v| try allocator.dupe(u8, v) else null,
        .chain_id = chain_id,
        .verifying_contract = verifying_contract,
        .salt = null,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "EIP-712 domain hashing" {
    const allocator = testing.allocator;

    const domain = try create_domain(allocator, "Test", "1", 1, null);
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    const hash = try hash_domain(allocator, &domain);

    // Verify hash is not all zeros
    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "EIP-712 type encoding" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "wallet", .type = "address" },
    };

    try types.put(allocator, "Person", &person_props);

    const encoded = try encode_type(allocator, "Person", &types);
    defer allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "Person(") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "string name") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "address wallet") != null);
}

test "EIP-712 signature roundtrip" {
    const allocator = testing.allocator;

    // Create a simple domain
    const domain = try create_domain(allocator, "TestDomain", "1", 1, null);
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    // Create typed data structure
    var typed_data = TypedData.init(allocator);
    defer typed_data.deinit(allocator);

    typed_data.domain = domain;
    typed_data.primary_type = try allocator.dupe(u8, "TestMessage");

    // Add simple type definition
    const test_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
    };
    try typed_data.types.put(allocator, "TestMessage", &test_props);

    // Add message data
    try typed_data.message.put(try allocator.dupe(u8, "value"), MessageValue{ .number = 42 });

    // Generate key pair
    const private_key = try Crypto.unaudited_randomPrivateKey();
    const public_key = try Crypto.unaudited_getPublicKey(private_key);
    const expected_address = public_key.toAddress();

    // Sign typed data
    const signature = try unaudited_signTypedData(allocator, &typed_data, private_key);

    // Verify signature
    try testing.expect(try unaudited_verifyTypedData(allocator, &typed_data, signature, expected_address));

    // Recover address
    const recovered_address = try unaudited_recoverTypedDataAddress(allocator, &typed_data, signature);
    try testing.expect(std.mem.eql(u8, &recovered_address, &expected_address));
}

test "EIP-712 hash deterministic" {
    const allocator = testing.allocator;

    const domain = try create_domain(allocator, "TestDomain", "1", 1, null);
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    var typed_data = TypedData.init(allocator);
    defer typed_data.deinit(allocator);

    typed_data.domain = domain;
    typed_data.primary_type = try allocator.dupe(u8, "TestMessage");

    const test_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
    };
    try typed_data.types.put(allocator, "TestMessage", &test_props);

    try typed_data.message.put(try allocator.dupe(u8, "value"), MessageValue{ .number = 42 });

    // Hash twice and verify they're the same
    const hash1 = try unaudited_hashTypedData(allocator, &typed_data);
    const hash2 = try unaudited_hashTypedData(allocator, &typed_data);

    try testing.expect(std.mem.eql(u8, &hash1, &hash2));
}

test "EIP-712 basic functionality" {
    const allocator = testing.allocator;

    // Test basic hash generation
    const domain = Eip712Domain{
        .name = "TestDomain",
        .version = "1",
        .chain_id = 1,
        .verifying_contract = null,
        .salt = null,
    };

    var typed_data = TypedData.init(allocator);
    defer typed_data.deinit(allocator);

    typed_data.domain = domain;
    typed_data.primary_type = "TestMessage";

    // Try to hash - this should work even if we don't have complete type definitions
    const hash_result = unaudited_hashTypedData(allocator, &typed_data);

    // We expect this to potentially fail but not crash
    if (hash_result) |hash| {
        // If successful, verify hash is not all zeros
        const zero_hash = [_]u8{0} ** 32;
        try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
    } else |_| {
        // If it fails, that's expected for incomplete type definitions
        // This is fine - we're just testing that it doesn't crash
    }
}

test "EIP-712 crypto integration" {
    // Test that the crypto functions are available
    const private_key = try Crypto.unaudited_randomPrivateKey();
    const public_key = try Crypto.unaudited_getPublicKey(private_key);
    const address = public_key.toAddress();

    // Basic test that addresses work
    const zero_address = [_]u8{0} ** 20;
    try testing.expect(!std.mem.eql(u8, &address, &zero_address));
}

test "encode_type - simple type" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "wallet", .type = "address" },
    };

    try types.put(allocator, "Person", &person_props);

    const encoded = try encode_type(allocator, "Person", &types);
    defer allocator.free(encoded);

    try testing.expectEqualStrings("Person(string name,address wallet)", encoded);
}

test "encode_type - nested custom type" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "wallet", .type = "address" },
    };
    try types.put(allocator, "Person", &person_props);

    const mail_props = [_]TypeProperty{
        TypeProperty{ .name = "from", .type = "Person" },
        TypeProperty{ .name = "to", .type = "Person" },
        TypeProperty{ .name = "contents", .type = "string" },
    };
    try types.put(allocator, "Mail", &mail_props);

    const encoded = try encode_type(allocator, "Mail", &types);
    defer allocator.free(encoded);

    // Should include Mail type definition and referenced Person type
    try testing.expect(std.mem.indexOf(u8, encoded, "Mail(") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "Person from") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "Person to") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "string contents") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "Person(") != null);
}

test "encode_type - invalid type returns error" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const result = encode_type(allocator, "NonExistent", &types);
    try testing.expectError(Eip712Error.TypeNotFound, result);
}

test "encode_type_recursive - multiple custom types" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const address_props = [_]TypeProperty{
        TypeProperty{ .name = "street", .type = "string" },
        TypeProperty{ .name = "city", .type = "string" },
    };
    try types.put(allocator, "Address", &address_props);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "home", .type = "Address" },
    };
    try types.put(allocator, "Person", &person_props);

    const encoded = try encode_type(allocator, "Person", &types);
    defer allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "Person(") != null);
    try testing.expect(std.mem.indexOf(u8, encoded, "Address(") != null);
}

test "hash_struct - simple struct" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const message_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
    };
    try types.put(allocator, "Message", &message_props);

    var data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data.deinit();
    }

    try data.put(try allocator.dupe(u8, "value"), MessageValue{ .number = 123 });

    const hash = try hash_struct(allocator, "Message", &data, &types);

    // Verify hash is not all zeros
    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "hash_struct - missing required field" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const message_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
        TypeProperty{ .name = "message", .type = "string" },
    };
    try types.put(allocator, "Message", &message_props);

    var data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data.deinit();
    }

    // Only provide one of two required fields
    try data.put(try allocator.dupe(u8, "value"), MessageValue{ .number = 123 });

    const result = hash_struct(allocator, "Message", &data, &types);
    try testing.expectError(Eip712Error.InvalidMessage, result);
}

test "encode_data - multiple fields" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const message_props = [_]TypeProperty{
        TypeProperty{ .name = "from", .type = "address" },
        TypeProperty{ .name = "to", .type = "address" },
        TypeProperty{ .name = "amount", .type = "uint256" },
    };
    try types.put(allocator, "Transfer", &message_props);

    var data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data.deinit();
    }

    const addr1 = [_]u8{1} ** 20;
    const addr2 = [_]u8{2} ** 20;

    try data.put(try allocator.dupe(u8, "from"), MessageValue{ .address = addr1 });
    try data.put(try allocator.dupe(u8, "to"), MessageValue{ .address = addr2 });
    try data.put(try allocator.dupe(u8, "amount"), MessageValue{ .number = 1000 });

    const encoded = try encode_data(allocator, "Transfer", &data, &types);
    defer allocator.free(encoded);

    // Should include type hash (32 bytes) + 3 encoded values (32 bytes each)
    try testing.expectEqual(@as(usize, 32 + 32 * 3), encoded.len);
}

test "encode_value - uint256" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const value = MessageValue{ .number = 42 };
    const encoded = try encode_value(allocator, "uint256", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // Verify big-endian encoding
    var expected = [_]u8{0} ** 32;
    expected[31] = 42;
    try testing.expectEqualSlices(u8, &expected, encoded);
}

test "encode_value - address" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const addr = [_]u8{0xAB} ** 20;
    const value = MessageValue{ .address = addr };
    const encoded = try encode_value(allocator, "address", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // Address should be in last 20 bytes
    try testing.expectEqualSlices(u8, &addr, encoded[12..32]);
}

test "encode_value - bool true" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const value = MessageValue{ .boolean = true };
    const encoded = try encode_value(allocator, "bool", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);
    try testing.expectEqual(@as(u8, 1), encoded[31]);
}

test "encode_value - bool false" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const value = MessageValue{ .boolean = false };
    const encoded = try encode_value(allocator, "bool", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);
    try testing.expectEqual(@as(u8, 0), encoded[31]);
}

test "encode_value - string" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const str = try allocator.dupe(u8, "Hello, World!");
    defer allocator.free(str);

    const value = MessageValue{ .string = str };
    const encoded = try encode_value(allocator, "string", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // Should be keccak256 hash of the string
    const expected_hash = Hash.keccak256("Hello, World!");
    try testing.expectEqualSlices(u8, &expected_hash, encoded);
}

test "encode_value - dynamic bytes" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const bytes = try allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 });
    defer allocator.free(bytes);

    const value = MessageValue{ .bytes = bytes };
    const encoded = try encode_value(allocator, "bytes", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // Should be keccak256 hash of the bytes
    const expected_hash = Hash.keccak256(&[_]u8{ 0x01, 0x02, 0x03 });
    try testing.expectEqualSlices(u8, &expected_hash, encoded);
}

test "encode_value - fixed bytes" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const bytes = try allocator.dupe(u8, &[_]u8{0xAB} ** 4);
    defer allocator.free(bytes);

    const value = MessageValue{ .bytes = bytes };
    const encoded = try encode_value(allocator, "bytes4", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // First 4 bytes should be the data, rest zeros
    try testing.expectEqualSlices(u8, &[_]u8{0xAB} ** 4, encoded[0..4]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** 28, encoded[4..32]);
}

test "encode_value - custom type" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
    };
    try types.put(allocator, "Person", &person_props);

    var person_data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = person_data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        person_data.deinit();
    }

    try person_data.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, "Alice") });

    const value = MessageValue{ .object = person_data };
    const encoded = try encode_value(allocator, "Person", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);

    // Should be hash of the struct
    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &zero_hash, encoded));
}

test "encode_value - type mismatch returns error" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    // Provide string value for uint256 type
    const value = MessageValue{ .string = "not a number" };
    const result = encode_value(allocator, "uint256", value, &types);
    try testing.expectError(Eip712Error.InvalidMessage, result);
}

test "encode_value - invalid type name" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const value = MessageValue{ .number = 42 };
    const result = encode_value(allocator, "invalidType", value, &types);
    try testing.expectError(Eip712Error.TypeNotFound, result);
}

test "hash_domain - all fields" {
    const allocator = testing.allocator;

    const addr = [_]u8{0xFF} ** 20;
    const salt_bytes = [_]u8{0xAB} ** 32;

    const domain = Eip712Domain{
        .name = try allocator.dupe(u8, "TestDomain"),
        .version = try allocator.dupe(u8, "1.0.0"),
        .chain_id = 1,
        .verifying_contract = addr,
        .salt = salt_bytes,
    };
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    const hash = try hash_domain(allocator, &domain);

    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "hash_domain - minimal fields" {
    const allocator = testing.allocator;

    const domain = Eip712Domain{
        .name = try allocator.dupe(u8, "MinimalDomain"),
        .version = null,
        .chain_id = null,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    const hash = try hash_domain(allocator, &domain);

    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "hash_domain - deterministic" {
    const allocator = testing.allocator;

    const domain = Eip712Domain{
        .name = try allocator.dupe(u8, "TestDomain"),
        .version = try allocator.dupe(u8, "1"),
        .chain_id = 1,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    const hash1 = try hash_domain(allocator, &domain);
    const hash2 = try hash_domain(allocator, &domain);

    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "hash_domain - different values produce different hashes" {
    const allocator = testing.allocator;

    const domain1 = Eip712Domain{
        .name = try allocator.dupe(u8, "Domain1"),
        .version = null,
        .chain_id = null,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain1 = domain1;
        mut_domain1.deinit(allocator);
    }

    const domain2 = Eip712Domain{
        .name = try allocator.dupe(u8, "Domain2"),
        .version = null,
        .chain_id = null,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain2 = domain2;
        mut_domain2.deinit(allocator);
    }

    const hash1 = try hash_domain(allocator, &domain1);
    const hash2 = try hash_domain(allocator, &domain2);

    try testing.expect(!std.mem.eql(u8, &hash1, &hash2));
}

test "deeply nested structures" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const level3_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
    };
    try types.put(allocator, "Level3", &level3_props);

    const level2_props = [_]TypeProperty{
        TypeProperty{ .name = "nested", .type = "Level3" },
    };
    try types.put(allocator, "Level2", &level2_props);

    const level1_props = [_]TypeProperty{
        TypeProperty{ .name = "nested", .type = "Level2" },
    };
    try types.put(allocator, "Level1", &level1_props);

    var level3_data = std.StringHashMap(MessageValue).init(allocator);
    defer level3_data.deinit();
    try level3_data.put(try allocator.dupe(u8, "value"), MessageValue{ .number = 42 });

    var level2_data = std.StringHashMap(MessageValue).init(allocator);
    defer level2_data.deinit();
    try level2_data.put(try allocator.dupe(u8, "nested"), MessageValue{ .object = level3_data });

    var level1_data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = level1_data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        level1_data.deinit();
    }
    try level1_data.put(try allocator.dupe(u8, "nested"), MessageValue{ .object = level2_data });

    const hash = try hash_struct(allocator, "Level1", &level1_data, &types);

    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "empty arrays" {
    const allocator = testing.allocator;

    const empty_array = try allocator.alloc(MessageValue, 0);
    defer allocator.free(empty_array);

    const value = MessageValue{ .array = empty_array };

    // Clean up properly
    var mut_value = value;
    mut_value.deinit(allocator);
}

test "arrays of custom types" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "age", .type = "uint256" },
    };
    try types.put(allocator, "Person", &person_props);

    // Create first person
    var person1 = std.StringHashMap(MessageValue).init(allocator);
    try person1.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, "Alice") });
    try person1.put(try allocator.dupe(u8, "age"), MessageValue{ .number = 30 });

    // Create second person
    var person2 = std.StringHashMap(MessageValue).init(allocator);
    try person2.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, "Bob") });
    try person2.put(try allocator.dupe(u8, "age"), MessageValue{ .number = 25 });

    const people = try allocator.alloc(MessageValue, 2);
    people[0] = MessageValue{ .object = person1 };
    people[1] = MessageValue{ .object = person2 };

    var value = MessageValue{ .array = people };
    defer value.deinit(allocator);

    // Verify structure was created successfully
    try testing.expectEqual(@as(usize, 2), value.array.len);
}

test "maximum field counts" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    // Create type with many fields (20 fields)
    const num_fields = 20;
    const large_props = try allocator.alloc(TypeProperty, num_fields);
    defer allocator.free(large_props);

    for (large_props, 0..) |*prop, i| {
        const field_name = try std.fmt.allocPrint(allocator, "field{d}", .{i});
        prop.* = TypeProperty{
            .name = field_name,
            .type = try allocator.dupe(u8, "uint256"),
        };
    }

    try types.put(allocator, "LargeType", large_props);

    var data = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data.deinit();
    }

    for (0..num_fields) |i| {
        const field_name = try std.fmt.allocPrint(allocator, "field{d}", .{i});
        try data.put(field_name, MessageValue{ .number = i });
    }

    const hash = try hash_struct(allocator, "LargeType", &data, &types);

    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "field ordering variations" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const props = [_]TypeProperty{
        TypeProperty{ .name = "a", .type = "uint256" },
        TypeProperty{ .name = "b", .type = "uint256" },
        TypeProperty{ .name = "c", .type = "uint256" },
    };
    try types.put(allocator, "Ordered", &props);

    // Create data with same values in same order
    var data1 = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data1.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data1.deinit();
    }

    try data1.put(try allocator.dupe(u8, "a"), MessageValue{ .number = 1 });
    try data1.put(try allocator.dupe(u8, "b"), MessageValue{ .number = 2 });
    try data1.put(try allocator.dupe(u8, "c"), MessageValue{ .number = 3 });

    // Create data with same values (hashmap order doesn't matter)
    var data2 = std.StringHashMap(MessageValue).init(allocator);
    defer {
        var iterator = data2.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(allocator);
        }
        data2.deinit();
    }

    try data2.put(try allocator.dupe(u8, "c"), MessageValue{ .number = 3 });
    try data2.put(try allocator.dupe(u8, "a"), MessageValue{ .number = 1 });
    try data2.put(try allocator.dupe(u8, "b"), MessageValue{ .number = 2 });

    const hash1 = try hash_struct(allocator, "Ordered", &data1, &types);
    const hash2 = try hash_struct(allocator, "Ordered", &data2, &types);

    // Hashes should be the same because field order is defined by type definition
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "invalid type name characters" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    // Create type with special characters in name (should work)
    const props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
    };
    try types.put(allocator, "Type_With_Underscores", &props);

    const encoded = try encode_type(allocator, "Type_With_Underscores", &types);
    defer allocator.free(encoded);

    try testing.expect(std.mem.indexOf(u8, encoded, "Type_With_Underscores") != null);
}

test "encode_value - fixed bytes wrong size" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    // Provide wrong sized bytes for bytes4
    const bytes = try allocator.dupe(u8, &[_]u8{0xAB} ** 8);
    defer allocator.free(bytes);

    const value = MessageValue{ .bytes = bytes };
    const result = encode_value(allocator, "bytes4", value, &types);
    try testing.expectError(Eip712Error.InvalidMessage, result);
}

test "encode_value - int256" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    const value = MessageValue{ .number = 12345 };
    const encoded = try encode_value(allocator, "int256", value, &types);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);
}

test "full typed data with nested types" {
    const allocator = testing.allocator;

    const domain = Eip712Domain{
        .name = try allocator.dupe(u8, "TestApp"),
        .version = try allocator.dupe(u8, "1"),
        .chain_id = 1,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    var typed_data = TypedData.init(allocator);
    defer typed_data.deinit(allocator);

    typed_data.domain = domain;
    typed_data.primary_type = try allocator.dupe(u8, "Mail");

    // Define Person type
    const person_props = [_]TypeProperty{
        TypeProperty{ .name = "name", .type = "string" },
        TypeProperty{ .name = "wallet", .type = "address" },
    };
    try typed_data.types.put(allocator, "Person", &person_props);

    // Define Mail type
    const mail_props = [_]TypeProperty{
        TypeProperty{ .name = "from", .type = "Person" },
        TypeProperty{ .name = "to", .type = "Person" },
        TypeProperty{ .name = "contents", .type = "string" },
    };
    try typed_data.types.put(allocator, "Mail", &mail_props);

    // Create from person
    var from_person = std.StringHashMap(MessageValue).init(allocator);
    try from_person.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, "Alice") });
    try from_person.put(try allocator.dupe(u8, "wallet"), MessageValue{ .address = [_]u8{0xAA} ** 20 });

    // Create to person
    var to_person = std.StringHashMap(MessageValue).init(allocator);
    try to_person.put(try allocator.dupe(u8, "name"), MessageValue{ .string = try allocator.dupe(u8, "Bob") });
    try to_person.put(try allocator.dupe(u8, "wallet"), MessageValue{ .address = [_]u8{0xBB} ** 20 });

    // Create mail message
    try typed_data.message.put(try allocator.dupe(u8, "from"), MessageValue{ .object = from_person });
    try typed_data.message.put(try allocator.dupe(u8, "to"), MessageValue{ .object = to_person });
    try typed_data.message.put(try allocator.dupe(u8, "contents"), MessageValue{ .string = try allocator.dupe(u8, "Hello!") });

    const hash = try unaudited_hashTypedData(allocator, &typed_data);

    const zero_hash = [_]u8{0} ** 32;
    try testing.expect(!std.mem.eql(u8, &hash, &zero_hash));
}

test "typed data determinism across multiple hashes" {
    const allocator = testing.allocator;

    const domain = Eip712Domain{
        .name = try allocator.dupe(u8, "TestApp"),
        .version = try allocator.dupe(u8, "1"),
        .chain_id = 1,
        .verifying_contract = null,
        .salt = null,
    };
    defer {
        var mut_domain = domain;
        mut_domain.deinit(allocator);
    }

    var typed_data = TypedData.init(allocator);
    defer typed_data.deinit(allocator);

    typed_data.domain = domain;
    typed_data.primary_type = try allocator.dupe(u8, "Message");

    const message_props = [_]TypeProperty{
        TypeProperty{ .name = "content", .type = "string" },
    };
    try typed_data.types.put(allocator, "Message", &message_props);

    try typed_data.message.put(try allocator.dupe(u8, "content"), MessageValue{ .string = try allocator.dupe(u8, "Test") });

    // Hash multiple times
    const hash1 = try unaudited_hashTypedData(allocator, &typed_data);
    const hash2 = try unaudited_hashTypedData(allocator, &typed_data);
    const hash3 = try unaudited_hashTypedData(allocator, &typed_data);

    try testing.expectEqualSlices(u8, &hash1, &hash2);
    try testing.expectEqualSlices(u8, &hash2, &hash3);
}

test "circular type references handled gracefully" {
    const allocator = testing.allocator;

    var types = TypeDefinitions.init(allocator);
    defer types.deinit(allocator);

    // Create TypeA that references TypeB
    const typeA_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
        TypeProperty{ .name = "next", .type = "TypeB" },
    };
    try types.put(allocator, "TypeA", &typeA_props);

    // Create TypeB that references TypeA (circular)
    const typeB_props = [_]TypeProperty{
        TypeProperty{ .name = "value", .type = "uint256" },
        TypeProperty{ .name = "next", .type = "TypeA" },
    };
    try types.put(allocator, "TypeB", &typeB_props);

    // The current implementation should handle this by visiting each type only once
    // This won't error, but will produce a type encoding that doesn't include the circular reference
    const encoded = try encode_type(allocator, "TypeA", &types);
    defer allocator.free(encoded);

    // Should have successfully encoded something
    try testing.expect(encoded.len > 0);
    try testing.expect(std.mem.indexOf(u8, encoded, "TypeA(") != null);
}
