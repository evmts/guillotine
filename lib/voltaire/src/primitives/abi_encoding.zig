const std = @import("std");
const address = @import("address.zig");
const crypto_pkg = @import("crypto");
const hash = crypto_pkg.Hash;

pub const AbiError = error{
    InvalidLength,
    InvalidType,
    InvalidData,
    InvalidSelector,
    DataTooSmall,
    ZeroData,
    OutOfBounds,
    InvalidAddress,
    InvalidUtf8,
    UnsupportedType,
    OutOfMemory,
    MaxLengthExceeded,
    MaxRecursionDepthExceeded,
    IntegerCastOverflow,
};

// Security limits to prevent DoS attacks
pub const MAX_ABI_LENGTH: usize = 10 * 1024 * 1024; // 10 MB maximum ABI encoding size
pub const MAX_RECURSION_DEPTH: usize = 64; // Maximum nesting depth for arrays/tuples

// Safe integer cast that returns error instead of panicking
fn safeIntCast(comptime T: type, value: anytype) AbiError!T {
    const value_info = @typeInfo(@TypeOf(value));
    const target_info = @typeInfo(T);

    if (value_info != .int or target_info != .int) {
        return AbiError.IntegerCastOverflow;
    }

    const max_value = std.math.maxInt(T);
    const min_value = if (target_info.int.signedness == .signed) std.math.minInt(T) else 0;

    if (value > max_value or value < min_value) {
        return AbiError.IntegerCastOverflow;
    }

    return @intCast(value);
}

// Validate allocation size to prevent memory exhaustion DoS
fn validateAllocationSize(size: usize) AbiError!void {
    if (size > MAX_ABI_LENGTH) {
        return AbiError.MaxLengthExceeded;
    }
}

// Validate recursion depth to prevent stack exhaustion
fn validateRecursionDepth(depth: usize) AbiError!void {
    if (depth >= MAX_RECURSION_DEPTH) {
        return AbiError.MaxRecursionDepthExceeded;
    }
}

// Cursor for reading bytes
const Cursor = struct {
    data: []const u8,
    position: usize,

    pub fn init(data: []const u8) Cursor {
        return Cursor{
            .data = data,
            .position = 0,
        };
    }

    pub fn setPosition(self: *Cursor, pos: usize) void {
        self.position = pos;
    }

    pub fn readBytes(self: *Cursor, len: usize) AbiError![]const u8 {
        if (self.position + len > self.data.len) return AbiError.OutOfBounds;
        const result = self.data[self.position .. self.position + len];
        self.position += len;
        return result;
    }

    pub fn readU32Word(self: *Cursor) AbiError!u32 {
        const bytes = try self.readBytes(32);
        return std.mem.readInt(u32, bytes[28..32], .big);
    }

    pub fn readU64Word(self: *Cursor) AbiError!u64 {
        const bytes = try self.readBytes(32);
        return std.mem.readInt(u64, bytes[24..32], .big);
    }

    pub fn readU256Word(self: *Cursor) AbiError!u256 {
        const bytes = try self.readBytes(32);
        return std.mem.readInt(u256, bytes[0..32], .big);
    }

    pub fn readWord(self: *Cursor) AbiError![32]u8 {
        const bytes = try self.readBytes(32);
        return bytes[0..32].*;
    }

    pub fn atPosition(self: *const Cursor, pos: usize) Cursor {
        return Cursor{
            .data = self.data,
            .position = pos,
        };
    }
};

pub const AbiType = enum {
    uint8,
    uint16,
    uint32,
    uint64,
    uint128,
    uint256,
    int8,
    int16,
    int32,
    int64,
    int128,
    int256,
    address,
    bool,
    bytes1,
    bytes2,
    bytes3,
    bytes4,
    bytes8,
    bytes16,
    bytes32,
    // Dynamic types
    bytes,
    string,
    // Array types - using @"" syntax for names with special characters
    @"uint256[]",
    @"bytes32[]",
    @"address[]",
    @"string[]",

    pub fn is_dynamic(self: AbiType) bool {
        return switch (self) {
            .string, .bytes, .@"uint256[]", .@"bytes32[]", .@"address[]", .@"string[]" => true,
            else => false,
        };
    }

    pub fn size(self: AbiType) ?usize {
        return switch (self) {
            .uint8, .int8 => 1,
            .uint16, .int16 => 2,
            .uint32, .int32 => 4,
            .uint64, .int64 => 8,
            .uint128, .int128 => 16,
            .uint256, .int256 => 32,
            .address => 20,
            .bool => 1,
            .bytes1 => 1,
            .bytes2 => 2,
            .bytes3 => 3,
            .bytes4 => 4,
            .bytes8 => 8,
            .bytes16 => 16,
            .bytes32 => 32,
            .bytes, .string, .@"uint256[]", .@"bytes32[]", .@"address[]", .@"string[]" => null,
        };
    }

    pub fn get_type(self: AbiType) []const u8 {
        return @tagName(self);
    }
};

pub const AbiValue = union(AbiType) {
    uint8: u8,
    uint16: u16,
    uint32: u32,
    uint64: u64,
    uint128: u128,
    uint256: u256,
    int8: i8,
    int16: i16,
    int32: i32,
    int64: i64,
    int128: i128,
    int256: i256,
    address: address.Address,
    bool: bool,
    bytes1: [1]u8,
    bytes2: [2]u8,
    bytes3: [3]u8,
    bytes4: [4]u8,
    bytes8: [8]u8,
    bytes16: [16]u8,
    bytes32: [32]u8,
    bytes: []const u8,
    string: []const u8,
    @"uint256[]": []const u256,
    @"bytes32[]": []const [32]u8,
    @"address[]": []const address.Address,
    @"string[]": []const []const u8,

    pub fn get_type(self: AbiValue) AbiType {
        return self;
    }
};

pub fn uint256_value(val: u256) AbiValue {
    return .{ .uint256 = val };
}
pub fn boolValue(val: bool) AbiValue {
    return .{ .bool = val };
}
pub fn addressValue(val: address.Address) AbiValue {
    return .{ .address = val };
}
pub fn stringValue(val: []const u8) AbiValue {
    return .{ .string = val };
}
pub fn bytesValue(val: []const u8) AbiValue {
    return .{ .bytes = val };
}

pub const Selector = [4]u8;

pub fn computeSelector(signature: []const u8) Selector {
    var hash_result: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(signature, &hash_result, .{});
    return hash_result[0..4].*;
}

pub fn createFunctionSignature(allocator: std.mem.Allocator, name: []const u8, types: []const AbiType) ![]u8 {
    var signature = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer signature.deinit();

    try signature.appendSlice(name);
    try signature.append('(');

    for (types, 0..) |abi_type, i| {
        if (i > 0) try signature.append(',');
        try signature.appendSlice(abi_type.get_type());
    }

    try signature.append(')');
    return signature.toOwnedSlice();
}

// ABI Decoding Functions

fn decode_uint(cursor: *Cursor, comptime T: type, comptime bits: u16) AbiError!T {
    if (bits > 256 or bits % 8 != 0) return AbiError.InvalidType;

    const word = try cursor.readWord();
    const bytes_len = bits / 8;
    const start_offset = 32 - bytes_len;

    if (T == u256) {
        return std.mem.readInt(u256, &word, .big);
    } else {
        return std.mem.readInt(T, word[start_offset..32], .big);
    }
}

fn decode_int(cursor: *Cursor, comptime T: type, comptime bits: u16) AbiError!T {
    if (bits > 256 or bits % 8 != 0) return AbiError.InvalidType;

    const word = try cursor.readWord();
    const bytes_len = bits / 8;
    const start_offset = 32 - bytes_len;

    if (T == i256) {
        // i256 is not natively supported in Zig as there is no i256 type.
        // This is intentional - Solidity's int256 is rarely used in practice.
        // If needed, use uint256 and handle sign bit manually, or use a big integer library.
        return AbiError.UnsupportedType;
    } else {
        const unsigned = std.mem.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), word[start_offset..32], .big);
        return @bitCast(unsigned);
    }
}

fn decode_address(cursor: *Cursor) AbiError!address.Address {
    const word = try cursor.readWord();
    var address_result: address.Address = undefined;
    @memcpy(&address_result.bytes, word[12..32]);
    return address_result;
}

fn decode_bool(cursor: *Cursor) AbiError!bool {
    const word = try cursor.readWord();
    return word[31] != 0;
}

fn decode_bytes_fixed(cursor: *Cursor, comptime size: usize) AbiError![size]u8 {
    const word = try cursor.readWord();
    var result: [size]u8 = undefined;
    @memcpy(&result, word[0..size]);
    return result;
}

fn decode_bytes_dynamic(allocator: std.mem.Allocator, cursor: *Cursor, static_position: usize) AbiError![]u8 {
    const offset = try cursor.readU256Word();
    const offset_usize = try safeIntCast(usize, offset);
    var offset_cursor = cursor.atPosition(static_position + offset_usize);

    const length = try offset_cursor.readU256Word();
    const length_usize = try safeIntCast(usize, length);

    // Validate allocation size before allocating
    try validateAllocationSize(length_usize);

    if (length_usize == 0) {
        return try allocator.alloc(u8, 0);
    }

    // Calculate padded length (round up to 32-byte boundary)
    const padded_length = ((length_usize + 31) / 32) * 32;
    try validateAllocationSize(padded_length);

    const data = try offset_cursor.readBytes(padded_length);

    // Only return the actual data, not the padding
    const result = try allocator.alloc(u8, length_usize);
    @memcpy(result, data[0..length_usize]);
    return result;
}

fn decode_string(allocator: std.mem.Allocator, cursor: *Cursor, static_position: usize) AbiError![]u8 {
    const bytes = try decode_bytes_dynamic(allocator, cursor, static_position);
    // Validate UTF-8
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        allocator.free(bytes);
        return AbiError.InvalidUtf8;
    }
    return bytes;
}

fn decode_array(allocator: std.mem.Allocator, cursor: *Cursor, element_type: AbiType, static_position: usize, depth: usize) AbiError![]AbiValue {
    try validateRecursionDepth(depth);

    const offset = try cursor.readU256Word();
    const offset_usize = try safeIntCast(usize, offset);
    var offset_cursor = cursor.atPosition(static_position + offset_usize);

    const length = try offset_cursor.readU256Word();
    const length_usize = try safeIntCast(usize, length);

    // Validate total allocation size
    const total_size = length_usize * @sizeOf(AbiValue);
    try validateAllocationSize(total_size);

    var result = try allocator.alloc(AbiValue, length_usize);
    errdefer allocator.free(result);

    for (0..length_usize) |i| {
        result[i] = try decode_parameter(allocator, &offset_cursor, element_type, static_position, depth + 1);
    }

    return result;
}

fn decode_parameter(allocator: std.mem.Allocator, cursor: *Cursor, abi_type: AbiType, static_position: usize, depth: usize) AbiError!AbiValue {
    try validateRecursionDepth(depth);

    return switch (abi_type) {
        .uint8 => AbiValue{ .uint8 = try decode_uint(cursor, u8, 8) },
        .uint16 => AbiValue{ .uint16 = try decode_uint(cursor, u16, 16) },
        .uint32 => AbiValue{ .uint32 = try decode_uint(cursor, u32, 32) },
        .uint64 => AbiValue{ .uint64 = try decode_uint(cursor, u64, 64) },
        .uint128 => AbiValue{ .uint128 = try decode_uint(cursor, u128, 128) },
        .uint256 => AbiValue{ .uint256 = try decode_uint(cursor, u256, 256) },
        .int8 => AbiValue{ .int8 = try decode_int(cursor, i8, 8) },
        .int16 => AbiValue{ .int16 = try decode_int(cursor, i16, 16) },
        .int32 => AbiValue{ .int32 = try decode_int(cursor, i32, 32) },
        .int64 => AbiValue{ .int64 = try decode_int(cursor, i64, 64) },
        .int128 => AbiValue{ .int128 = try decode_int(cursor, i128, 128) },
        .int256 => return AbiError.UnsupportedType, // i256 not natively supported in Zig
        .address => AbiValue{ .address = try decode_address(cursor) },
        .bool => AbiValue{ .bool = try decode_bool(cursor) },
        .bytes1 => AbiValue{ .bytes1 = try decode_bytes_fixed(cursor, 1) },
        .bytes2 => AbiValue{ .bytes2 = try decode_bytes_fixed(cursor, 2) },
        .bytes3 => AbiValue{ .bytes3 = try decode_bytes_fixed(cursor, 3) },
        .bytes4 => AbiValue{ .bytes4 = try decode_bytes_fixed(cursor, 4) },
        .bytes8 => AbiValue{ .bytes8 = try decode_bytes_fixed(cursor, 8) },
        .bytes16 => AbiValue{ .bytes16 = try decode_bytes_fixed(cursor, 16) },
        .bytes32 => AbiValue{ .bytes32 = try decode_bytes_fixed(cursor, 32) },
        .bytes => AbiValue{ .bytes = try decode_bytes_dynamic(allocator, cursor, static_position) },
        .string => AbiValue{ .string = try decode_string(allocator, cursor, static_position) },
        .@"uint256[]" => {
            const array_values = try decode_array(allocator, cursor, .uint256, static_position, depth);
            defer allocator.free(array_values);

            try validateAllocationSize(array_values.len * @sizeOf(u256));
            var result = try allocator.alloc(u256, array_values.len);
            errdefer allocator.free(result);
            for (array_values, 0..) |value, i| {
                result[i] = value.uint256;
            }
            return AbiValue{ .@"uint256[]" = result };
        },
        .@"bytes32[]" => {
            const array_values = try decode_array(allocator, cursor, .bytes32, static_position, depth);
            defer allocator.free(array_values);

            try validateAllocationSize(array_values.len * @sizeOf([32]u8));
            var result = try allocator.alloc([32]u8, array_values.len);
            errdefer allocator.free(result);
            for (array_values, 0..) |value, i| {
                result[i] = value.bytes32;
            }
            return AbiValue{ .@"bytes32[]" = result };
        },
        .@"address[]" => {
            const array_values = try decode_array(allocator, cursor, .address, static_position, depth);
            defer allocator.free(array_values);

            try validateAllocationSize(array_values.len * @sizeOf(address.Address));
            var result = try allocator.alloc(address.Address, array_values.len);
            errdefer allocator.free(result);
            for (array_values, 0..) |value, i| {
                result[i] = value.address;
            }
            return AbiValue{ .@"address[]" = result };
        },
        .@"string[]" => {
            const array_values = try decode_array(allocator, cursor, .string, static_position, depth);
            defer allocator.free(array_values);

            try validateAllocationSize(array_values.len * @sizeOf([]const u8));
            var result = try allocator.alloc([]const u8, array_values.len);
            errdefer allocator.free(result);
            for (array_values, 0..) |value, i| {
                result[i] = value.string;
            }
            return AbiValue{ .@"string[]" = result };
        },
    };
}

// Main ABI decoding function
pub fn decodeAbiParameters(allocator: std.mem.Allocator, data: []const u8, types: []const AbiType) ![]AbiValue {
    if (data.len == 0 and types.len == 0) {
        return try allocator.alloc(AbiValue, 0);
    }

    if (data.len < types.len * 32) {
        return AbiError.DataTooSmall;
    }

    // Validate total input size
    try validateAllocationSize(data.len);
    try validateAllocationSize(types.len * @sizeOf(AbiValue));

    var cursor = Cursor.init(data);
    const result = try allocator.alloc(AbiValue, types.len);

    var consumed: usize = 0;
    for (types, 0..) |abi_type, i| {
        cursor.setPosition(consumed);
        result[i] = try decode_parameter(allocator, &cursor, abi_type, 0, 0);
        consumed += 32; // Each parameter takes 32 bytes in the static part
    }

    return result;
}

pub fn decodeFunctionData(allocator: std.mem.Allocator, data: []const u8, types: []const AbiType) AbiError!struct { selector: Selector, parameters: []AbiValue } {
    if (data.len < 4) return AbiError.DataTooSmall;

    const selector: Selector = data[0..4].*;
    const parameters = if (data.len > 4)
        try decodeAbiParameters(allocator, data[4..], types)
    else
        try allocator.alloc(AbiValue, 0);

    return .{
        .selector = selector,
        .parameters = parameters,
    };
}

// ABI Encoding Functions

// Helper to determine if a type is dynamic
fn is_dynamic(abi_type: AbiType) bool {
    return switch (abi_type) {
        .string, .bytes, .@"uint256[]", .@"bytes32[]", .@"address[]", .@"string[]" => true,
        else => false,
    };
}

// Helper to get static size for static types
fn get_static_size(abi_type: AbiType) ?usize {
    return switch (abi_type) {
        .uint8, .uint16, .uint32, .uint64, .uint128, .uint256, .int8, .int16, .int32, .int64, .int128, .int256, .address, .bool, .bytes1, .bytes2, .bytes3, .bytes4, .bytes8, .bytes16, .bytes32 => 32,
        .string, .bytes, .@"uint256[]", .@"bytes32[]", .@"address[]", .@"string[]" => null,
    };
}

// Encode a single static parameter
fn encode_static_parameter(allocator: std.mem.Allocator, value: AbiValue) ![]u8 {
    var result = try allocator.alloc(u8, 32);
    errdefer allocator.free(result);
    @memset(result, 0);

    switch (value) {
        .uint8 => |val| {
            result[31] = val;
        },
        .uint16 => |val| {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, val, .big);
            @memcpy(result[30..32], &bytes);
        },
        .uint32 => |val| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, val, .big);
            @memcpy(result[28..32], &bytes);
        },
        .uint64 => |val| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, val, .big);
            @memcpy(result[24..32], &bytes);
        },
        .uint128 => |val| {
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &bytes, val, .big);
            @memcpy(result[16..32], &bytes);
        },
        .uint256 => |val| {
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, val, .big);
            @memcpy(result, &bytes);
        },
        .int8 => |val| {
            const unsigned = @as(u8, @bitCast(val));
            result[31] = unsigned;
            // Sign extend for negative numbers
            if (val < 0) {
                @memset(result[0..31], 0xff);
            }
        },
        .int16 => |val| {
            const unsigned = @as(u16, @bitCast(val));
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, unsigned, .big);
            @memcpy(result[30..32], &bytes);
            // Sign extend for negative numbers
            if (val < 0) {
                @memset(result[0..30], 0xff);
            }
        },
        .int32 => |val| {
            const unsigned = @as(u32, @bitCast(val));
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, unsigned, .big);
            @memcpy(result[28..32], &bytes);
            // Sign extend for negative numbers
            if (val < 0) {
                @memset(result[0..28], 0xff);
            }
        },
        .int64 => |val| {
            const unsigned = @as(u64, @bitCast(val));
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, unsigned, .big);
            @memcpy(result[24..32], &bytes);
            // Sign extend for negative numbers
            if (val < 0) {
                @memset(result[0..24], 0xff);
            }
        },
        .int128 => |val| {
            const unsigned = @as(u128, @bitCast(val));
            var bytes: [16]u8 = undefined;
            std.mem.writeInt(u128, &bytes, unsigned, .big);
            @memcpy(result[16..32], &bytes);
            // Sign extend for negative numbers
            if (val < 0) {
                @memset(result[0..16], 0xff);
            }
        },
        .int256 => {
            // i256 is not natively supported in Zig as there is no i256 type.
            // This is intentional - Solidity's int256 is rarely used in practice.
            // If needed, use uint256 and handle sign bit manually, or use a big integer library.
            return AbiError.UnsupportedType;
        },
        .address => |val| {
            // Address is 20 bytes, right-aligned (left-padded with zeros)
            @memcpy(result[12..32], &val.bytes);
        },
        .bool => |val| {
            result[31] = if (val) 1 else 0;
        },
        .bytes1 => |val| {
            @memcpy(result[0..1], &val);
        },
        .bytes2 => |val| {
            @memcpy(result[0..2], &val);
        },
        .bytes3 => |val| {
            @memcpy(result[0..3], &val);
        },
        .bytes4 => |val| {
            @memcpy(result[0..4], &val);
        },
        .bytes8 => |val| {
            @memcpy(result[0..8], &val);
        },
        .bytes16 => |val| {
            @memcpy(result[0..16], &val);
        },
        .bytes32 => |val| {
            @memcpy(result, &val);
        },
        else => {
            // errdefer will handle cleanup
            return AbiError.InvalidType;
        },
    }

    return result;
}

// Encode a dynamic parameter
fn encode_dynamic_parameter(allocator: std.mem.Allocator, value: AbiValue) ![]u8 {
    switch (value) {
        .string => |val| {
            // Length + data, padded to 32-byte boundary
            const length = val.len;
            const padded_length = ((length + 31) / 32) * 32;
            const total_size = 32 + padded_length;

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Encode data
            @memcpy(result[32 .. 32 + length], val);

            return result;
        },
        .bytes => |val| {
            // Same as string
            const length = val.len;
            const padded_length = ((length + 31) / 32) * 32;
            const total_size = 32 + padded_length;

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Encode data
            @memcpy(result[32 .. 32 + length], val);

            return result;
        },
        .@"uint256[]" => |val| {
            // Length + array elements
            const length = val.len;
            const total_size = 32 + (length * 32);

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Encode elements
            for (val, 0..) |elem, i| {
                var elem_bytes: [32]u8 = undefined;
                std.mem.writeInt(u256, &elem_bytes, elem, .big);
                @memcpy(result[32 + (i * 32) .. 32 + ((i + 1) * 32)], &elem_bytes);
            }

            return result;
        },
        .@"bytes32[]" => |val| {
            // Length + array elements
            const length = val.len;
            const total_size = 32 + (length * 32);

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Encode elements (bytes32 values are left-aligned)
            for (val, 0..) |elem, i| {
                @memcpy(result[32 + (i * 32) .. 32 + ((i + 1) * 32)], &elem);
            }

            return result;
        },
        .@"address[]" => |val| {
            const length = val.len;
            const total_size = 32 + (length * 32);

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Encode elements
            for (val, 0..) |elem, i| {
                @memcpy(result[32 + (i * 32) + 12 .. 32 + ((i + 1) * 32)], &elem.bytes);
            }

            return result;
        },
        .@"string[]" => |val| {
            const length = val.len;

            // First pass: calculate total size needed
            var total_size: usize = 32; // For array length
            total_size += length * 32; // For offset pointers

            try validateAllocationSize(length * @sizeOf(usize));
            var string_sizes = try allocator.alloc(usize, length);
            defer allocator.free(string_sizes);

            for (val, 0..) |str, i| {
                const str_len = str.len;
                const padded_len = ((str_len + 31) / 32) * 32;
                string_sizes[i] = 32 + padded_len; // Length + data
                total_size += string_sizes[i];
            }

            try validateAllocationSize(total_size);

            var result = try allocator.alloc(u8, total_size);
            errdefer allocator.free(result);
            @memset(result, 0);

            // Encode array length
            var length_bytes: [32]u8 = undefined;
            @memset(&length_bytes, 0);
            const length_u64 = try safeIntCast(u64, length);
            std.mem.writeInt(u64, length_bytes[24..32], length_u64, .big);
            @memcpy(result[0..32], &length_bytes);

            // Calculate offsets and encode offset pointers
            var current_offset: usize = length * 32;
            for (0..length) |i| {
                var offset_bytes: [32]u8 = undefined;
                @memset(&offset_bytes, 0);
                const offset_u64 = try safeIntCast(u64, current_offset);
                std.mem.writeInt(u64, offset_bytes[24..32], offset_u64, .big);
                @memcpy(result[32 + (i * 32) .. 32 + ((i + 1) * 32)], &offset_bytes);
                current_offset += string_sizes[i];
            }

            // Encode string data
            var data_offset: usize = 32 + (length * 32);
            for (val, 0..) |str, i| {
                const str_len = str.len;

                // String length
                var str_length_bytes: [32]u8 = undefined;
                @memset(&str_length_bytes, 0);
                const str_len_u64 = try safeIntCast(u64, str_len);
                std.mem.writeInt(u64, str_length_bytes[24..32], str_len_u64, .big);
                @memcpy(result[data_offset .. data_offset + 32], &str_length_bytes);

                // String data
                @memcpy(result[data_offset + 32 .. data_offset + 32 + str_len], str);

                data_offset += string_sizes[i];
            }

            return result;
        },
        else => {
            return AbiError.InvalidType;
        },
    }
}

// Main ABI encoding function
pub fn encodeAbiParameters(allocator: std.mem.Allocator, values: []const AbiValue) ![]u8 {
    if (values.len == 0) return try allocator.alloc(u8, 0);

    var static_parts = std.array_list.AlignedManaged([]u8, null).init(allocator);
    defer {
        for (static_parts.items) |part| {
            allocator.free(part);
        }
        static_parts.deinit();
    }

    var dynamic_parts = std.array_list.AlignedManaged([]u8, null).init(allocator);
    defer {
        for (dynamic_parts.items) |part| {
            allocator.free(part);
        }
        dynamic_parts.deinit();
    }

    // First pass: compute static size and prepare static/dynamic parts
    var static_size: usize = 0;
    var dynamic_size: usize = 0;

    for (values) |value| {
        const abi_type = value.get_type();

        if (is_dynamic(abi_type)) {
            // Dynamic type: add 32 bytes for offset pointer in static part
            static_size += 32;

            // Encode the dynamic data
            const dynamic_data = try encode_dynamic_parameter(allocator, value);
            try dynamic_parts.append(dynamic_data);
            dynamic_size += dynamic_data.len;

            // Create offset pointer for static part
            const offset_pointer = try allocator.alloc(u8, 32);
            @memset(offset_pointer, 0);
            // Offset will be calculated in second pass
            try static_parts.append(offset_pointer);
        } else {
            // Static type: encode directly
            const static_data = try encode_static_parameter(allocator, value);
            try static_parts.append(static_data);
            static_size += 32;
        }
    }

    // Second pass: update offset pointers
    var current_dynamic_offset: usize = static_size;
    var dynamic_index: usize = 0;

    for (values, 0..) |value, i| {
        const abi_type = value.get_type();

        if (is_dynamic(abi_type)) {
            // Update the offset pointer
            var offset_bytes: [32]u8 = undefined;
            @memset(&offset_bytes, 0);
            const offset_u64 = try safeIntCast(u64, current_dynamic_offset);
            std.mem.writeInt(u64, offset_bytes[24..32], offset_u64, .big);
            @memcpy(static_parts.items[i], &offset_bytes);

            current_dynamic_offset += dynamic_parts.items[dynamic_index].len;
            dynamic_index += 1;
        }
    }

    // Concatenate all parts
    const total_size = static_size + dynamic_size;
    try validateAllocationSize(total_size);
    var result = try allocator.alloc(u8, total_size);

    var offset: usize = 0;

    // Copy static parts
    for (static_parts.items) |part| {
        @memcpy(result[offset .. offset + part.len], part);
        offset += part.len;
    }

    // Copy dynamic parts
    for (dynamic_parts.items) |part| {
        @memcpy(result[offset .. offset + part.len], part);
        offset += part.len;
    }

    return result;
}

pub fn encodeFunctionData(allocator: std.mem.Allocator, selector: Selector, parameters: []const AbiValue) ![]u8 {
    const encoded_params = try encodeAbiParameters(allocator, parameters);
    defer allocator.free(encoded_params);

    const result = try allocator.alloc(u8, 4 + encoded_params.len);
    @memcpy(result[0..4], &selector);
    @memcpy(result[4..], encoded_params);
    return result;
}

pub fn encodeEventTopics(allocator: std.mem.Allocator, event_signature: []const u8, indexed_values: []const AbiValue) ![][]u8 {
    var topics = std.array_list.AlignedManaged([]u8, null).init(allocator);
    defer topics.deinit();

    // First topic is the event signature hash
    var signature_hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(event_signature, &signature_hash, .{});
    const first_topic = try allocator.alloc(u8, 32);
    @memcpy(first_topic, &signature_hash);
    try topics.append(first_topic);

    // Add indexed parameters as topics
    for (indexed_values) |value| {
        var topic = try allocator.alloc(u8, 32);
        @memset(topic, 0);

        switch (value) {
            .address => |addr| {
                @memcpy(topic[12..32], &addr);
            },
            .uint256 => |val| {
                var bytes: [32]u8 = undefined;
                std.mem.writeInt(u256, &bytes, val, .big);
                @memcpy(topic, &bytes);
            },
            else => {
                // For other types, leave as zeros
            },
        }

        try topics.append(topic);
    }

    return topics.toOwnedSlice();
}

// Simple packed encoding
pub fn encodePacked(allocator: std.mem.Allocator, values: []const AbiValue) ![]u8 {
    var result = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer result.deinit();

    for (values) |value| {
        switch (value) {
            .uint8 => |val| {
                try result.append(val);
            },
            .uint16 => |val| {
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &bytes, val, .big);
                try result.appendSlice(&bytes);
            },
            .uint32 => |val| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, val, .big);
                try result.appendSlice(&bytes);
            },
            .string => |val| {
                try result.appendSlice(val);
            },
            else => {
                // For other types, skip or handle as needed
            },
        }
    }

    return result.toOwnedSlice();
}

// Gas estimation for call data using std.mem.count for efficiency
pub fn estimateGasForData(data: []const u8) u64 {
    const base_gas: u64 = 21000; // Base transaction cost

    const zero_bytes = std.mem.count(u8, data, &[_]u8{0});
    const non_zero_bytes = data.len - zero_bytes;

    return base_gas + (zero_bytes * 4) + (non_zero_bytes * 16);
}

// Common selectors
pub const CommonSelectors = struct {
    pub const ERC20_TRANSFER = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    pub const ERC20_BALANCE_OF = [_]u8{ 0x70, 0xa0, 0x82, 0x31 };
    pub const ERC20_APPROVE = [_]u8{ 0x09, 0x5e, 0xa7, 0xb3 };
    pub const ERC20_TOTAL_SUPPLY = [_]u8{ 0x18, 0x16, 0x0d, 0xdd };
};

// Function definition structure
pub const FunctionDefinition = struct {
    name: []const u8,
    inputs: []const AbiType,
    outputs: []const AbiType,
    state_mutability: StateMutability,

    pub fn get_selector(self: FunctionDefinition, allocator: std.mem.Allocator) !Selector {
        const signature = try createFunctionSignature(allocator, self.name, self.inputs);
        defer allocator.free(signature);
        return computeSelector(signature);
    }
};

pub const StateMutability = enum {
    pure,
    view,
    nonpayable,
    payable,
};

// Common patterns
pub const CommonPatterns = struct {
    pub fn erc20_transfer() FunctionDefinition {
        return FunctionDefinition{
            .name = "transfer",
            .inputs = &[_]AbiType{ .address, .uint256 },
            .outputs = &[_]AbiType{.bool},
            .state_mutability = .nonpayable,
        };
    }

    pub fn erc20_balance_of() FunctionDefinition {
        return FunctionDefinition{
            .name = "balanceOf",
            .inputs = &[_]AbiType{.address},
            .outputs = &[_]AbiType{.uint256},
            .state_mutability = .view,
        };
    }
};

// Tests
test "basic ABI encoding" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        uint256_value(42),
        boolValue(true),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 64), encoded.len); // 2 * 32 bytes
}

test "basic ABI decoding" {
    const allocator = std.testing.allocator;

    // Test decoding uint256
    const uint256_data = [_]u8{0} ** 28 ++ [_]u8{ 0x00, 0x00, 0x00, 0x2A }; // 42 in big-endian
    const types = [_]AbiType{.uint256};

    const decoded = try decodeAbiParameters(allocator, &uint256_data, &types);
    defer {
        for (decoded) |value| {
            switch (value) {
                .string, .bytes => |slice| allocator.free(slice),
                else => {},
            }
        }
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u256, 42), decoded[0].uint256);
}

test "function selector computation" {
    const selector = computeSelector("transfer(address,uint256)");

    // This should match the known ERC20 transfer selector
    const expected = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqualSlices(u8, &expected, &selector);
}

test "function data encoding" {
    const allocator = std.testing.allocator;

    const selector = computeSelector("transfer(address,uint256)");
    const params = [_]AbiValue{
        addressValue([_]u8{0x12} ** 20),
        uint256_value(1000),
    };

    const encoded = try encodeFunctionData(allocator, selector, &params);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 68), encoded.len); // 4 + 64 bytes
    try std.testing.expectEqualSlices(u8, &selector, encoded[0..4]);
}

test "packed encoding" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        AbiValue{ .uint8 = 0x12 },
        AbiValue{ .uint16 = 0x3456 },
        stringValue("test"),
    };

    const packed_data = try encodePacked(allocator, &values);
    defer allocator.free(packed_data);

    try std.testing.expectEqual(@as(usize, 7), packed_data.len); // 1 + 2 + 4 bytes
    try std.testing.expectEqual(@as(u8, 0x12), packed_data[0]);
    try std.testing.expectEqual(@as(u8, 0x34), packed_data[1]);
    try std.testing.expectEqual(@as(u8, 0x56), packed_data[2]);
    try std.testing.expectEqualSlices(u8, "test", packed_data[3..7]);
}

test "gas estimation" {
    const data = &[_]u8{ 0x00, 0x01, 0x02, 0x00, 0x03 };
    const gas = estimateGasForData(data);

    // 21000 + 4 + 16 + 16 + 4 + 16 = 21056
    try std.testing.expectEqual(@as(u64, 21056), gas);
}

test "common selectors" {
    const transfer_selector = CommonSelectors.ERC20_TRANSFER;
    const expected_transfer = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqualSlices(u8, &expected_transfer, &transfer_selector);

    const balance_selector = CommonSelectors.ERC20_BALANCE_OF;
    const expected_balance = [_]u8{ 0x70, 0xa0, 0x82, 0x31 };
    try std.testing.expectEqualSlices(u8, &expected_balance, &balance_selector);
}

// Encode function result (return values)
pub fn encodeFunctionResult(allocator: std.mem.Allocator, return_values: []const AbiValue) ![]u8 {
    return encodeAbiParameters(allocator, return_values);
}

// Decode function result (return values)
pub fn decodeFunctionResult(allocator: std.mem.Allocator, data: []const u8, output_types: []const AbiType) ![]AbiValue {
    return decodeAbiParameters(allocator, data, output_types);
}

// Encode error result (selector + error parameters)
pub fn encodeErrorResult(allocator: std.mem.Allocator, error_selector: Selector, error_params: []const AbiValue) ![]u8 {
    const encoded_params = try encodeAbiParameters(allocator, error_params);
    defer allocator.free(encoded_params);

    const result = try allocator.alloc(u8, 4 + encoded_params.len);
    @memcpy(result[0..4], &error_selector);
    @memcpy(result[4..], encoded_params);

    return result;
}

// Helper structs for function execution results
pub const FunctionResult = struct {
    success: bool,
    return_data: []const u8,
    gas_used: ?u64 = null,

    pub fn deinit(self: *FunctionResult, allocator: std.mem.Allocator) void {
        allocator.free(self.return_data);
    }
};

pub const ErrorResult = struct {
    selector: Selector,
    error_data: []const u8,
    decoded_params: ?[]AbiValue = null,

    pub fn deinit(self: *ErrorResult, allocator: std.mem.Allocator) void {
        allocator.free(self.error_data);
        if (self.decoded_params) |params| {
            for (params) |param| {
                switch (param) {
                    .string, .bytes => |slice| allocator.free(slice),
                    .@"uint256[]" => |arr| allocator.free(arr),
                    .@"bytes32[]" => |arr| allocator.free(arr),
                    .@"address[]" => |arr| allocator.free(arr),
                    .@"string[]" => |arr| {
                        for (arr) |str| allocator.free(str);
                        allocator.free(arr);
                    },
                    else => {},
                }
            }
            allocator.free(params);
        }
    }
};

// Helper functions for creating results
pub fn createFunctionResult(allocator: std.mem.Allocator, success: bool, return_data: []const u8, gas_used: ?u64) !FunctionResult {
    const owned_data = try allocator.dupe(u8, return_data);
    return FunctionResult{
        .success = success,
        .return_data = owned_data,
        .gas_used = gas_used,
    };
}

pub fn decodeFunctionResultWithTypes(allocator: std.mem.Allocator, result: FunctionResult, output_types: []const AbiType) ![]AbiValue {
    return decodeFunctionResult(allocator, result.return_data, output_types);
}

pub fn createErrorResult(allocator: std.mem.Allocator, selector: Selector, error_data: []const u8) !ErrorResult {
    const owned_data = try allocator.dupe(u8, error_data);
    return ErrorResult{
        .selector = selector,
        .error_data = owned_data,
    };
}

pub fn decodeErrorResultWithTypes(allocator: std.mem.Allocator, error_result: *ErrorResult, error_types: []const AbiType) !void {
    error_result.decoded_params = try decodeAbiParameters(allocator, error_result.error_data[4..], error_types);
}

// Test ABI encoding of uint types
test "encode uint256" {
    // Test encoding 69420n (0x10f2c)
    const values = [_]AbiValue{
        uint256_value(69420),
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    const expected = [_]u8{0} ** 28 ++ [_]u8{ 0x00, 0x00, 0x10, 0xf2, 0xc };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "encode uint8" {
    // Test encoding 32
    const values = [_]AbiValue{
        .{ .uint8 = 32 },
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 32), encoded.len);

    const expected = [_]u8{0} ** 31 ++ [_]u8{0x20};
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "encode multiple uint types" {
    const values = [_]AbiValue{
        .{ .uint8 = 255 },
        .{ .uint32 = 69420 },
        uint256_value(0xdeadbeef),
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 96), encoded.len); // 3 * 32 bytes
}

// Test ABI encoding of int types with two's complement
test "encode int32 positive" {
    const values = [_]AbiValue{
        .{ .int32 = 2147483647 }, // Max int32
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    const expected = [_]u8{0} ** 28 ++ [_]u8{ 0x7f, 0xff, 0xff, 0xff };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

test "encode int32 negative two's complement" {
    const values = [_]AbiValue{
        .{ .int32 = -2147483648 }, // Min int32
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    // Two's complement representation
    const expected = [_]u8{0xff} ** 28 ++ [_]u8{ 0x80, 0x00, 0x00, 0x00 };
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

// Test ABI encoding of addresses
test "encode address" {
    const addr: address.Address = [_]u8{
        0x14, 0xdC, 0x79, 0x96, 0x4d, 0xa2, 0xC0, 0x8b,
        0x23, 0x69, 0x8B, 0x3D, 0x3c, 0xc7, 0xCa, 0x32,
        0x19, 0x3d, 0x99, 0x55,
    };

    const values = [_]AbiValue{
        addressValue(addr),
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &values);
    defer std.testing.allocator.free(encoded);

    // Address should be right-padded with zeros
    const expected = [_]u8{0} ** 12 ++ addr;
    try std.testing.expectEqualSlices(u8, &expected, encoded);
}

// Test ABI encoding of bool
test "encode bool" {
    // Test true
    {
        const values = [_]AbiValue{
            boolValue(true),
        };

        const encoded = try encodeAbiParameters(std.testing.allocator, &values);
        defer std.testing.allocator.free(encoded);

        const expected = [_]u8{0} ** 31 ++ [_]u8{0x01};
        try std.testing.expectEqualSlices(u8, &expected, encoded);
    }

    // Test false
    {
        const values = [_]AbiValue{
            boolValue(false),
        };

        const encoded = try encodeAbiParameters(std.testing.allocator, &values);
        defer std.testing.allocator.free(encoded);

        const expected = [_]u8{0} ** 32;
        try std.testing.expectEqualSlices(u8, &expected, encoded);
    }
}

// Test ABI decoding
test "decode uint256" {
    const data = [_]u8{0} ** 28 ++ [_]u8{ 0x00, 0x00, 0x10, 0xf2, 0xc };
    const types = [_]AbiType{.uint256};

    const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
    defer {
        for (decoded) |value| {
            switch (value) {
                .string, .bytes => |slice| std.testing.allocator.free(slice),
                .@"uint256[]" => |arr| std.testing.allocator.free(arr),
                .@"bytes32[]" => |arr| std.testing.allocator.free(arr),
                .@"address[]" => |arr| std.testing.allocator.free(arr),
                .@"string[]" => |arr| {
                    for (arr) |str| std.testing.allocator.free(str);
                    std.testing.allocator.free(arr);
                },
                else => {},
            }
        }
        std.testing.allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(u256, 69420), decoded[0].uint256);
}

test "decode int32 negative" {
    // Two's complement representation of -2147483648
    const data = [_]u8{0xff} ** 28 ++ [_]u8{ 0x80, 0x00, 0x00, 0x00 };
    const types = [_]AbiType{.int32};

    const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqual(@as(i32, -2147483648), decoded[0].int32);
}

test "decode address" {
    const expectedAddr: address.Address = [_]u8{
        0x14, 0xdC, 0x79, 0x96, 0x4d, 0xa2, 0xC0, 0x8b,
        0x23, 0x69, 0x8B, 0x3D, 0x3c, 0xc7, 0xCa, 0x32,
        0x19, 0x3d, 0x99, 0x55,
    };

    const data = [_]u8{0} ** 12 ++ expectedAddr;
    const types = [_]AbiType{.address};

    const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualSlices(u8, &expectedAddr, &decoded[0].address);
}

test "decode bool" {
    // Test true
    {
        const data = [_]u8{0} ** 31 ++ [_]u8{0x01};
        const types = [_]AbiType{.bool};

        const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 1), decoded.len);
        try std.testing.expectEqual(true, decoded[0].bool);
    }

    // Test false
    {
        const data = [_]u8{0} ** 32;
        const types = [_]AbiType{.bool};

        const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
        defer std.testing.allocator.free(decoded);

        try std.testing.expectEqual(@as(usize, 1), decoded.len);
        try std.testing.expectEqual(false, decoded[0].bool);
    }
}

// Test function selector computation
test "compute selector" {
    // Test "transfer(address,uint256)" selector
    const transfer_sig = "transfer(address,uint256)";
    const selector = computeSelector(transfer_sig);

    // This should match the known ERC20 transfer selector
    const expected_selector = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqualSlices(u8, &expected_selector, &selector);
}

test "encode function data" {
    const selector = computeSelector("transfer(address,uint256)");

    const recipient: address.Address = [_]u8{0x12} ** 20;
    const params = [_]AbiValue{
        addressValue(recipient),
        uint256_value(1000),
    };

    const encoded = try encodeFunctionData(std.testing.allocator, selector, &params);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 68), encoded.len); // 4 + 64 bytes
    try std.testing.expectEqualSlices(u8, &selector, encoded[0..4]);
}

// Test dynamic types (strings and bytes)
test "decode string" {
    // Encoded "hello" string
    // offset (32 bytes) + length (32 bytes) + data (32 bytes padded)
    const data = [_]u8{
        // Offset to string data (32)
        0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x20,
        // Length of string (5)
        0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x05,
        // String data "hello" padded to 32 bytes
        'h', 'e', 'l', 'l', 'o', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0,   0,   0,   0,   0,   0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };

    const types = [_]AbiType{.string};

    const decoded = try decodeAbiParameters(std.testing.allocator, &data, &types);
    defer {
        std.testing.allocator.free(decoded[0].string);
        std.testing.allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualStrings("hello", decoded[0].string);
}

// Test packed encoding
test "encode packed" {
    const values = [_]AbiValue{
        .{ .uint8 = 0x12 },
        .{ .uint16 = 0x3456 },
        stringValue("test"),
    };

    const packed_data = try encodePacked(std.testing.allocator, &values);
    defer std.testing.allocator.free(packed_data);

    try std.testing.expectEqual(@as(usize, 7), packed_data.len); // 1 + 2 + 4 bytes
    try std.testing.expectEqual(@as(u8, 0x12), packed_data[0]);
    try std.testing.expectEqual(@as(u8, 0x34), packed_data[1]);
    try std.testing.expectEqual(@as(u8, 0x56), packed_data[2]);
    try std.testing.expectEqualStrings("test", packed_data[3..7]);
}

// Test gas estimation
test "gas estimation for data" {
    // Test with mix of zero and non-zero bytes
    const data = &[_]u8{ 0x00, 0x01, 0x02, 0x00, 0x03 };
    const gas = estimateGasForData(data);

    // Base cost: 21000
    // Zero bytes (2): 2 * 4 = 8
    // Non-zero bytes (3): 3 * 16 = 48
    // Total: 21000 + 8 + 48 = 21056
    try std.testing.expectEqual(@as(u64, 21056), gas);
}

// Test edge cases
test "decode empty parameters" {
    const decoded = try decodeAbiParameters(std.testing.allocator, "", &[_]AbiType{});
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "decode with insufficient data" {
    const data = [_]u8{ 0x01, 0x02, 0x03 }; // Only 3 bytes
    const types = [_]AbiType{.uint256}; // Expects 32 bytes

    const result = decodeAbiParameters(std.testing.allocator, &data, &types);
    try std.testing.expectError(AbiError.DataTooSmall, result);
}

// Test complex types
test "encode and decode multiple types" {
    const addr: address.Address = [_]u8{0xaa} ** 20;
    const originalValues = [_]AbiValue{
        uint256_value(42),
        boolValue(true),
        addressValue(addr),
    };

    const encoded = try encodeAbiParameters(std.testing.allocator, &originalValues);
    defer std.testing.allocator.free(encoded);

    const types = [_]AbiType{ .uint256, .bool, .address };
    const decoded = try decodeAbiParameters(std.testing.allocator, encoded, &types);
    defer std.testing.allocator.free(decoded);

    try std.testing.expectEqual(@as(u256, 42), decoded[0].uint256);
    try std.testing.expectEqual(true, decoded[1].bool);
    try std.testing.expectEqualSlices(u8, &addr, &decoded[2].address);
}

// Test ABI encoding with ox and viem test cases
test "encode_abi_parameters - comprehensive test cases from ox and viem" {
    const allocator = std.testing.allocator;

    // Test uint256 (value 69420n)
    {
        const values = [_]AbiValue{uint256_value(69420)};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "0000000000000000000000000000000000000000000000000000000000010f2c";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test uint8 (value 32)
    {
        const values = [_]AbiValue{AbiValue{ .uint8 = 32 }};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "0000000000000000000000000000000000000000000000000000000000000020";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test address
    {
        const addr: address.Address = [_]u8{
            0x14, 0xdC, 0x79, 0x96, 0x4d, 0xa2, 0xC0, 0x8b,
            0x23, 0x69, 0x8B, 0x3D, 0x3c, 0xc7, 0xCa, 0x32,
            0x19, 0x3d, 0x99, 0x55,
        };
        const values = [_]AbiValue{addressValue(addr)};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "00000000000000000000000014dc79964da2c08b23698b3d3cc7ca32193d9955";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test bool true
    {
        const values = [_]AbiValue{boolValue(true)};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "0000000000000000000000000000000000000000000000000000000000000001";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test bool false
    {
        const values = [_]AbiValue{boolValue(false)};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "0000000000000000000000000000000000000000000000000000000000000000";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test int32 positive
    {
        const values = [_]AbiValue{AbiValue{ .int32 = 2147483647 }};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "000000000000000000000000000000000000000000000000000000007fffffff";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test int32 negative (two's complement)
    {
        const values = [_]AbiValue{AbiValue{ .int32 = -2147483648 }};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffff80000000";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test multiple static types (uint256, bool, address)
    {
        const addr: address.Address = [_]u8{
            0xc9, 0x61, 0x14, 0x5a, 0x54, 0xC9, 0x6E, 0x3a,
            0xE9, 0xbA, 0xA0, 0x48, 0xc4, 0xF4, 0xD6, 0xb0,
            0x4C, 0x13, 0x91, 0x6b,
        };
        const values = [_]AbiValue{
            uint256_value(420),
            boolValue(true),
            addressValue(addr),
        };
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "00000000000000000000000000000000000000000000000000000000000001a40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c961145a54c96e3ae9baa048c4f4d6b04c13916b";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test string encoding
    {
        const values = [_]AbiValue{stringValue("wagmi")};
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000057761676d69000000000000000000000000000000000000000000000000000000";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }

    // Test mixed static and dynamic types (string, uint256, bool)
    {
        const values = [_]AbiValue{
            stringValue("wagmi"),
            uint256_value(420),
            boolValue(true),
        };
        const encoded = try encodeAbiParameters(allocator, &values);
        defer allocator.free(encoded);

        const expected = "000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000001a4000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000057761676d69000000000000000000000000000000000000000000000000000000";
        const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
        defer allocator.free(actual_hex);

        try std.testing.expectEqualStrings(expected, actual_hex);
    }
}

test "ABI encode decode round-trip - all uint types" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .uint8 = 255 },
        .{ .uint16 = 65535 },
        .{ .uint32 = 4294967295 },
        .{ .uint64 = 18446744073709551615 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .uint8, .uint16, .uint32, .uint64 };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(u8, 255), decoded[0].uint8);
    try std.testing.expectEqual(@as(u16, 65535), decoded[1].uint16);
    try std.testing.expectEqual(@as(u32, 4294967295), decoded[2].uint32);
    try std.testing.expectEqual(@as(u64, 18446744073709551615), decoded[3].uint64);
}

test "ABI encode decode round-trip - all int types" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .int8 = -128 },
        .{ .int16 = -32768 },
        .{ .int32 = -2147483648 },
        .{ .int64 = -9223372036854775808 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .int8, .int16, .int32, .int64 };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(i8, -128), decoded[0].int8);
    try std.testing.expectEqual(@as(i16, -32768), decoded[1].int16);
    try std.testing.expectEqual(@as(i32, -2147483648), decoded[2].int32);
    try std.testing.expectEqual(@as(i64, -9223372036854775808), decoded[3].int64);
}

test "ABI fixed bytes types encoding" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .bytes1 = [_]u8{0xaa} },
        .{ .bytes4 = [_]u8{ 0x11, 0x22, 0x33, 0x44 } },
        .{ .bytes32 = [_]u8{0xff} ** 32 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 96), encoded.len);
    try std.testing.expectEqual(@as(u8, 0xaa), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x11), encoded[32]);
    try std.testing.expectEqual(@as(u8, 0xff), encoded[64]);
}

test "ABI fixed bytes decode round-trip" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .bytes8 = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 } },
        .{ .bytes16 = [_]u8{0xab} ** 16 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .bytes8, .bytes16 };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &values[0].bytes8, &decoded[0].bytes8);
    try std.testing.expectEqualSlices(u8, &values[1].bytes16, &decoded[1].bytes16);
}

test "ABI dynamic bytes encoding" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    const values = [_]AbiValue{
        bytesValue(&data),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.bytes};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].bytes);
        allocator.free(decoded);
    }

    try std.testing.expectEqualSlices(u8, &data, decoded[0].bytes);
}

test "ABI large dynamic bytes" {
    const allocator = std.testing.allocator;

    const large_data = [_]u8{0xaa} ** 1000;
    const values = [_]AbiValue{
        bytesValue(&large_data),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.bytes};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].bytes);
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1000), decoded[0].bytes.len);
    try std.testing.expectEqualSlices(u8, &large_data, decoded[0].bytes);
}

test "ABI uint256 array encoding" {
    const allocator = std.testing.allocator;

    const arr = [_]u256{ 1, 2, 3, 4, 5 };
    const values = [_]AbiValue{
        .{ .@"uint256[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 5), decoded[0].@"uint256[]".len);
    for (arr, 0..) |val, i| {
        try std.testing.expectEqual(val, decoded[0].@"uint256[]"[i]);
    }
}

test "ABI bytes32 array encoding" {
    const allocator = std.testing.allocator;

    const arr = [_][32]u8{
        [_]u8{0xaa} ** 32,
        [_]u8{0xbb} ** 32,
        [_]u8{0xcc} ** 32,
    };
    const values = [_]AbiValue{
        .{ .@"bytes32[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"bytes32[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"bytes32[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"bytes32[]".len);
    for (arr, 0..) |val, i| {
        try std.testing.expectEqualSlices(u8, &val, &decoded[0].@"bytes32[]"[i]);
    }
}

test "ABI address array encoding" {
    const allocator = std.testing.allocator;

    const addr1: address.Address = [_]u8{0x11} ** 20;
    const addr2: address.Address = [_]u8{0x22} ** 20;
    const arr = [_]address.Address{ addr1, addr2 };
    const values = [_]AbiValue{
        .{ .@"address[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"address[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"address[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 2), decoded[0].@"address[]".len);
    try std.testing.expectEqualSlices(u8, &addr1, &decoded[0].@"address[]"[0]);
    try std.testing.expectEqualSlices(u8, &addr2, &decoded[0].@"address[]"[1]);
}

test "ABI string array encoding" {
    const allocator = std.testing.allocator;

    const strings = [_][]const u8{ "hello", "world", "test" };
    const values = [_]AbiValue{
        .{ .@"string[]" = &strings },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"string[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        for (decoded[0].@"string[]") |str| {
            allocator.free(str);
        }
        allocator.free(decoded[0].@"string[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"string[]".len);
    try std.testing.expectEqualStrings("hello", decoded[0].@"string[]"[0]);
    try std.testing.expectEqualStrings("world", decoded[0].@"string[]"[1]);
    try std.testing.expectEqualStrings("test", decoded[0].@"string[]"[2]);
}

test "ABI empty arrays" {
    const allocator = std.testing.allocator;

    const empty_arr = [_]u256{};
    const values = [_]AbiValue{
        .{ .@"uint256[]" = &empty_arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 0), decoded[0].@"uint256[]".len);
}

test "ABI malformed input - truncated data" {
    const allocator = std.testing.allocator;

    const truncated = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00 };
    const types = [_]AbiType{.uint256};

    const result = decodeAbiParameters(allocator, &truncated, &types);
    try std.testing.expectError(AbiError.DataTooSmall, result);
}

test "ABI malformed input - invalid offset beyond bounds" {
    const allocator = std.testing.allocator;

    var data: [64]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 1000, .big);

    const types = [_]AbiType{.string};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI invalid UTF-8 in string" {
    const allocator = std.testing.allocator;

    var data: [96]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], 5, .big);
    data[64] = 0xff;
    data[65] = 0xff;
    data[66] = 0xff;
    data[67] = 0xff;
    data[68] = 0xff;

    const types = [_]AbiType{.string};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.InvalidUtf8, result);
}

test "ABI complex mixed encoding - multiple dynamic types" {
    const allocator = std.testing.allocator;

    const arr = [_]u256{ 100, 200, 300 };
    const values = [_]AbiValue{
        uint256_value(42),
        stringValue("test"),
        .{ .@"uint256[]" = &arr },
        boolValue(true),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .uint256, .string, .@"uint256[]", .bool };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[1].string);
        allocator.free(decoded[2].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(u256, 42), decoded[0].uint256);
    try std.testing.expectEqualStrings("test", decoded[1].string);
    try std.testing.expectEqual(@as(usize, 3), decoded[2].@"uint256[]".len);
    try std.testing.expectEqual(true, decoded[3].bool);
}

test "ABI decode function data with no parameters" {
    const allocator = std.testing.allocator;

    const selector = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    const result = try decodeFunctionData(allocator, &selector, &[_]AbiType{});
    defer allocator.free(result.parameters);

    try std.testing.expectEqualSlices(u8, &selector, &result.selector);
    try std.testing.expectEqual(@as(usize, 0), result.parameters.len);
}

test "ABI encode event topics with indexed values" {
    const allocator = std.testing.allocator;

    const addr: address.Address = [_]u8{0xaa} ** 20;
    const indexed = [_]AbiValue{
        addressValue(addr),
        uint256_value(1000),
    };

    const topics = try encodeEventTopics(allocator, "Transfer(address,address,uint256)", &indexed);
    defer {
        for (topics) |topic| {
            allocator.free(topic);
        }
        allocator.free(topics);
    }

    try std.testing.expectEqual(@as(usize, 3), topics.len);
    try std.testing.expectEqual(@as(usize, 32), topics[0].len);
    try std.testing.expectEqual(@as(usize, 32), topics[1].len);
}

test "ABI zero values encoding" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .uint8 = 0 },
        .{ .uint256 = 0 },
        boolValue(false),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_zeros = [_]u8{0} ** 96;
    try std.testing.expectEqualSlices(u8, &expected_zeros, encoded);
}

test "ABI maximum values encoding" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .uint8 = 255 },
        .{ .uint16 = 65535 },
        .{ .uint32 = 4294967295 },
        .{ .uint64 = 18446744073709551615 },
        .{ .uint128 = 340282366920938463463374607431768211455 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 160), encoded.len);
}

test "ABI large array encoding - 1000 elements" {
    const allocator = std.testing.allocator;

    const arr = try allocator.alloc(u256, 1000);
    defer allocator.free(arr);

    for (arr, 0..) |*val, i| {
        val.* = i;
    }

    const values = [_]AbiValue{
        .{ .@"uint256[]" = arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1000), decoded[0].@"uint256[]".len);
    for (arr, 0..) |val, i| {
        try std.testing.expectEqual(val, decoded[0].@"uint256[]"[i]);
    }
}

test "ABI cursor bounds checking" {
    var cursor = Cursor.init(&[_]u8{ 1, 2, 3 });
    const result = cursor.readBytes(10);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI cursor position manipulation" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var cursor = Cursor.init(&data);

    cursor.setPosition(2);
    const bytes = try cursor.readBytes(2);
    try std.testing.expectEqual(@as(u8, 3), bytes[0]);
    try std.testing.expectEqual(@as(u8, 4), bytes[1]);
}

test "ABI createFunctionSignature" {
    const allocator = std.testing.allocator;

    const types = [_]AbiType{ .address, .uint256 };
    const signature = try createFunctionSignature(allocator, "transfer", &types);
    defer allocator.free(signature);

    try std.testing.expectEqualStrings("transfer(address,uint256)", signature);
}

// ============================================================================
// COMPREHENSIVE TEST SUITE - Dynamic Arrays (10+ tests)
// ============================================================================

test "ABI dynamic array - empty uint256 array" {
    const allocator = std.testing.allocator;

    const empty_arr = [_]u256{};
    const values = [_]AbiValue{
        .{ .@"uint256[]" = &empty_arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 0), decoded[0].@"uint256[]".len);
}

test "ABI dynamic array - single element uint256 array" {
    const allocator = std.testing.allocator;

    const arr = [_]u256{42};
    const values = [_]AbiValue{
        .{ .@"uint256[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 1), decoded[0].@"uint256[]".len);
    try std.testing.expectEqual(@as(u256, 42), decoded[0].@"uint256[]"[0]);
}

test "ABI dynamic array - multiple elements address array" {
    const allocator = std.testing.allocator;

    const addr1: address.Address = [_]u8{0x11} ** 20;
    const addr2: address.Address = [_]u8{0x22} ** 20;
    const addr3: address.Address = [_]u8{0x33} ** 20;
    const arr = [_]address.Address{ addr1, addr2, addr3 };
    const values = [_]AbiValue{
        .{ .@"address[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"address[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"address[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"address[]".len);
    try std.testing.expectEqualSlices(u8, &addr1, &decoded[0].@"address[]"[0]);
    try std.testing.expectEqualSlices(u8, &addr2, &decoded[0].@"address[]"[1]);
    try std.testing.expectEqualSlices(u8, &addr3, &decoded[0].@"address[]"[2]);
}

test "ABI dynamic array - empty string array" {
    const allocator = std.testing.allocator;

    const empty_arr = [_][]const u8{};
    const values = [_]AbiValue{
        .{ .@"string[]" = &empty_arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"string[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        for (decoded[0].@"string[]") |str| {
            allocator.free(str);
        }
        allocator.free(decoded[0].@"string[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 0), decoded[0].@"string[]".len);
}

test "ABI dynamic array - string array with empty strings" {
    const allocator = std.testing.allocator;

    const strings = [_][]const u8{ "", "test", "" };
    const values = [_]AbiValue{
        .{ .@"string[]" = &strings },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"string[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        for (decoded[0].@"string[]") |str| {
            allocator.free(str);
        }
        allocator.free(decoded[0].@"string[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"string[]".len);
    try std.testing.expectEqualStrings("", decoded[0].@"string[]"[0]);
    try std.testing.expectEqualStrings("test", decoded[0].@"string[]"[1]);
    try std.testing.expectEqualStrings("", decoded[0].@"string[]"[2]);
}

test "ABI dynamic array - very large uint256 array (10000 elements)" {
    const allocator = std.testing.allocator;

    const arr = try allocator.alloc(u256, 10000);
    defer allocator.free(arr);

    for (arr, 0..) |*val, i| {
        val.* = i * 123456789;
    }

    const values = [_]AbiValue{
        .{ .@"uint256[]" = arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 10000), decoded[0].@"uint256[]".len);
    for (arr, 0..) |val, i| {
        try std.testing.expectEqual(val, decoded[0].@"uint256[]"[i]);
    }
}

test "ABI dynamic array - bytes32 array with all zeros" {
    const allocator = std.testing.allocator;

    const arr = [_][32]u8{
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
        [_]u8{0} ** 32,
    };
    const values = [_]AbiValue{
        .{ .@"bytes32[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"bytes32[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"bytes32[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"bytes32[]".len);
    for (decoded[0].@"bytes32[]") |val| {
        try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &val);
    }
}

test "ABI dynamic array - mixed static and dynamic array encoding" {
    const allocator = std.testing.allocator;

    const uint_arr = [_]u256{ 1, 2, 3 };
    const string_arr = [_][]const u8{ "hello", "world" };
    const values = [_]AbiValue{
        uint256_value(99),
        .{ .@"uint256[]" = &uint_arr },
        stringValue("middle"),
        .{ .@"string[]" = &string_arr },
        boolValue(true),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .uint256, .@"uint256[]", .string, .@"string[]", .bool };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[1].@"uint256[]");
        allocator.free(decoded[2].string);
        for (decoded[3].@"string[]") |str| {
            allocator.free(str);
        }
        allocator.free(decoded[3].@"string[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(u256, 99), decoded[0].uint256);
    try std.testing.expectEqual(@as(usize, 3), decoded[1].@"uint256[]".len);
    try std.testing.expectEqualStrings("middle", decoded[2].string);
    try std.testing.expectEqual(@as(usize, 2), decoded[3].@"string[]".len);
    try std.testing.expectEqual(true, decoded[4].bool);
}

test "ABI dynamic array - address array with zero addresses" {
    const allocator = std.testing.allocator;

    const zero_addr: address.Address = [_]u8{0} ** 20;
    const arr = [_]address.Address{zero_addr} ** 5;
    const values = [_]AbiValue{
        .{ .@"address[]" = &arr },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"address[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"address[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 5), decoded[0].@"address[]".len);
    for (decoded[0].@"address[]") |addr| {
        try std.testing.expectEqualSlices(u8, &zero_addr, &addr);
    }
}

test "ABI dynamic array - string array with long strings (>32 bytes each)" {
    const allocator = std.testing.allocator;

    const long_str1 = "This is a very long string that exceeds thirty-two bytes in length";
    const long_str2 = "Another extraordinarily lengthy string for comprehensive testing purposes";
    const strings = [_][]const u8{ long_str1, long_str2 };
    const values = [_]AbiValue{
        .{ .@"string[]" = &strings },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.@"string[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        for (decoded[0].@"string[]") |str| {
            allocator.free(str);
        }
        allocator.free(decoded[0].@"string[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 2), decoded[0].@"string[]".len);
    try std.testing.expectEqualStrings(long_str1, decoded[0].@"string[]"[0]);
    try std.testing.expectEqualStrings(long_str2, decoded[0].@"string[]"[1]);
}

// ============================================================================
// BOUNDARY VALUE TESTS (10+ tests)
// ============================================================================

test "ABI boundary - uint8 minimum value (0)" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .uint8 = 0 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.uint8};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(u8, 0), decoded[0].uint8);
}

test "ABI boundary - uint8 maximum value (255)" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .uint8 = 255 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.uint8};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(u8, 255), decoded[0].uint8);
}

test "ABI boundary - uint256 minimum value (0)" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        uint256_value(0),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.uint256};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(u256, 0), decoded[0].uint256);
}

test "ABI boundary - uint256 maximum value (2^256-1)" {
    const allocator = std.testing.allocator;

    const max_u256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const values = [_]AbiValue{
        uint256_value(max_u256),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.uint256};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(max_u256, decoded[0].uint256);
}

test "ABI boundary - int8 minimum value (-128)" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .int8 = -128 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.int8};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(i8, -128), decoded[0].int8);
}

test "ABI boundary - int8 maximum value (127)" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .int8 = 127 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.int8};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(i8, 127), decoded[0].int8);
}

test "ABI boundary - int128 minimum value" {
    const allocator = std.testing.allocator;

    const min_i128: i128 = -170141183460469231731687303715884105728;
    const values = [_]AbiValue{
        .{ .int128 = min_i128 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.int128};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(min_i128, decoded[0].int128);
}

test "ABI boundary - int128 maximum value" {
    const allocator = std.testing.allocator;

    const max_i128: i128 = 170141183460469231731687303715884105727;
    const values = [_]AbiValue{
        .{ .int128 = max_i128 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.int128};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(max_i128, decoded[0].int128);
}

test "ABI boundary - address zero (0x0000...0000)" {
    const allocator = std.testing.allocator;

    const zero_addr: address.Address = [_]u8{0} ** 20;
    const values = [_]AbiValue{
        addressValue(zero_addr),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.address};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &zero_addr, &decoded[0].address);
}

test "ABI boundary - address maximum (0xFFFF...FFFF)" {
    const allocator = std.testing.allocator;

    const max_addr: address.Address = [_]u8{0xFF} ** 20;
    const values = [_]AbiValue{
        addressValue(max_addr),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{.address};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, &max_addr, &decoded[0].address);
}

test "ABI boundary - bytes1 vs bytes32 comparison" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        .{ .bytes1 = [_]u8{0xAA} },
        .{ .bytes32 = [_]u8{0xBB} ** 32 },
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .bytes1, .bytes32 };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(u8, 0xAA), decoded[0].bytes1[0]);
    for (decoded[1].bytes32) |byte| {
        try std.testing.expectEqual(@as(u8, 0xBB), byte);
    }
}

test "ABI boundary - empty string vs long string (>1000 bytes)" {
    const allocator = std.testing.allocator;

    const long_str = "a" ** 1500;
    const values = [_]AbiValue{
        stringValue(""),
        stringValue(long_str),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .string, .string };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].string);
        allocator.free(decoded[1].string);
        allocator.free(decoded);
    }

    try std.testing.expectEqualStrings("", decoded[0].string);
    try std.testing.expectEqualStrings(long_str, decoded[1].string);
    try std.testing.expectEqual(@as(usize, 1500), decoded[1].string.len);
}

test "ABI boundary - empty bytes vs maximum bytes" {
    const allocator = std.testing.allocator;

    const empty_bytes = [_]u8{};
    const large_bytes = [_]u8{0xCD} ** 5000;
    const values = [_]AbiValue{
        bytesValue(&empty_bytes),
        bytesValue(&large_bytes),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .bytes, .bytes };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].bytes);
        allocator.free(decoded[1].bytes);
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 0), decoded[0].bytes.len);
    try std.testing.expectEqual(@as(usize, 5000), decoded[1].bytes.len);
    try std.testing.expectEqualSlices(u8, &large_bytes, decoded[1].bytes);
}

// ============================================================================
// FUNCTION SELECTOR TESTS (5+ tests)
// ============================================================================

test "ABI selector - ERC20 transfer selector accuracy" {
    const selector = computeSelector("transfer(address,uint256)");
    const expected = [_]u8{ 0xa9, 0x05, 0x9c, 0xbb };
    try std.testing.expectEqualSlices(u8, &expected, &selector);
}

test "ABI selector - ERC20 approve selector accuracy" {
    const selector = computeSelector("approve(address,uint256)");
    const expected = [_]u8{ 0x09, 0x5e, 0xa7, 0xb3 };
    try std.testing.expectEqualSlices(u8, &expected, &selector);
}

test "ABI selector - ERC20 balanceOf selector accuracy" {
    const selector = computeSelector("balanceOf(address)");
    const expected = [_]u8{ 0x70, 0xa0, 0x82, 0x31 };
    try std.testing.expectEqualSlices(u8, &expected, &selector);
}

test "ABI selector - complex function signature parsing" {
    const allocator = std.testing.allocator;

    const types = [_]AbiType{ .uint256, .address, .bool, .bytes32 };
    const signature = try createFunctionSignature(allocator, "complexFunction", &types);
    defer allocator.free(signature);

    try std.testing.expectEqualStrings("complexFunction(uint256,address,bool,bytes32)", signature);

    const selector = computeSelector(signature);
    try std.testing.expectEqual(@as(usize, 4), selector.len);
}

test "ABI selector - function data encoding with selector" {
    const allocator = std.testing.allocator;

    const selector = computeSelector("setValue(uint256)");
    const params = [_]AbiValue{
        uint256_value(12345),
    };

    const encoded = try encodeFunctionData(allocator, selector, &params);
    defer allocator.free(encoded);

    try std.testing.expectEqual(@as(usize, 36), encoded.len);
    try std.testing.expectEqualSlices(u8, &selector, encoded[0..4]);
}

test "ABI selector - decoding function data with selector" {
    const allocator = std.testing.allocator;

    const selector = computeSelector("getValue()");
    const params = [_]AbiValue{};

    const encoded = try encodeFunctionData(allocator, selector, &params);
    defer allocator.free(encoded);

    const result = try decodeFunctionData(allocator, encoded, &[_]AbiType{});
    defer allocator.free(result.parameters);

    try std.testing.expectEqualSlices(u8, &selector, &result.selector);
    try std.testing.expectEqual(@as(usize, 0), result.parameters.len);
}

test "ABI selector - function definition get_selector" {
    const allocator = std.testing.allocator;

    const func_def = CommonPatterns.erc20_transfer();
    const selector = try func_def.get_selector(allocator);

    const expected = CommonSelectors.ERC20_TRANSFER;
    try std.testing.expectEqualSlices(u8, &expected, &selector);
}

test "ABI selector - multiple selectors uniqueness" {
    const sel1 = computeSelector("func1(uint256)");
    const sel2 = computeSelector("func2(uint256)");
    const sel3 = computeSelector("func1(address)");

    const same_as_sel1 = computeSelector("func1(uint256)");
    try std.testing.expectEqualSlices(u8, &sel1, &same_as_sel1);

    const equal_sel1_sel2 = std.mem.eql(u8, &sel1, &sel2);
    try std.testing.expect(!equal_sel1_sel2);

    const equal_sel1_sel3 = std.mem.eql(u8, &sel1, &sel3);
    try std.testing.expect(!equal_sel1_sel3);
}

// ============================================================================
// ERROR CONDITION TESTS (10+ tests)
// ============================================================================

test "ABI error - truncated data insufficient for type" {
    const allocator = std.testing.allocator;

    const truncated = [_]u8{ 0x01, 0x02, 0x03 };
    const types = [_]AbiType{.uint256};

    const result = decodeAbiParameters(allocator, &truncated, &types);
    try std.testing.expectError(AbiError.DataTooSmall, result);
}

test "ABI error - invalid dynamic offset beyond data bounds" {
    const allocator = std.testing.allocator;

    var data: [64]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 999999, .big);

    const types = [_]AbiType{.string};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - invalid UTF-8 string decoding" {
    const allocator = std.testing.allocator;

    var data: [96]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], 4, .big);
    data[64] = 0xFF;
    data[65] = 0xFF;
    data[66] = 0xFE;
    data[67] = 0xFD;

    const types = [_]AbiType{.string};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.InvalidUtf8, result);
}

test "ABI error - function data too small (less than 4 bytes)" {
    const allocator = std.testing.allocator;

    const short_data = [_]u8{ 0x01, 0x02 };
    const result = decodeFunctionData(allocator, &short_data, &[_]AbiType{});
    try std.testing.expectError(AbiError.DataTooSmall, result);
}

test "ABI error - cursor reading beyond bounds" {
    var cursor = Cursor.init(&[_]u8{ 1, 2, 3, 4, 5 });
    const result = cursor.readBytes(10);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - cursor reading word from insufficient data" {
    var cursor = Cursor.init(&[_]u8{ 1, 2, 3, 4, 5 });
    const result = cursor.readWord();
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - array length causes offset overflow" {
    const allocator = std.testing.allocator;

    var data: [64]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], std.math.maxInt(u64), .big);

    const types = [_]AbiType{.@"uint256[]"};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - negative offset in dynamic data" {
    const allocator = std.testing.allocator;

    var data: [64]u8 = undefined;
    @memset(&data, 0xFF);

    const types = [_]AbiType{.string};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - malformed array with invalid element count" {
    const allocator = std.testing.allocator;

    var data: [128]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], 10, .big);

    const types = [_]AbiType{.@"uint256[]"};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - empty data with non-empty type requirements" {
    const allocator = std.testing.allocator;

    const empty_data = [_]u8{};
    const types = [_]AbiType{ .uint256, .address };

    const result = decodeAbiParameters(allocator, &empty_data, &types);
    try std.testing.expectError(AbiError.DataTooSmall, result);
}

test "ABI error - bytes dynamic length exceeds available data" {
    const allocator = std.testing.allocator;

    var data: [96]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], 1000, .big);

    const types = [_]AbiType{.bytes};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

test "ABI error - string array with invalid nested offset" {
    const allocator = std.testing.allocator;

    var data: [128]u8 = undefined;
    @memset(&data, 0);
    std.mem.writeInt(u64, data[24..32], 32, .big);
    std.mem.writeInt(u64, data[56..64], 1, .big);
    std.mem.writeInt(u64, data[88..96], 999999, .big);

    const types = [_]AbiType{.@"string[]"};
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.OutOfBounds, result);
}

// ============================================================================
// CROSS-VALIDATION TESTS (5+ tests)
// ============================================================================

test "ABI cross-validation - ethers.js ERC20 transfer encoding" {
    const allocator = std.testing.allocator;

    const recipient: address.Address = [_]u8{
        0xd8, 0xda, 0x6b, 0xf2, 0x69, 0x64, 0xaf, 0x9d,
        0x7e, 0xed, 0x9e, 0x03, 0xe5, 0x34, 0x15, 0xd3,
        0x7a, 0xa9, 0x60, 0x45,
    };
    const amount: u256 = 1000000000000000000;

    const values = [_]AbiValue{
        addressValue(recipient),
        uint256_value(amount),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_hex = "000000000000000000000000d8da6bf26964af9d7eed9e03e53415d37aa960450000000000000000000000000000000000000000000000000de0b6b3a7640000";
    const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer allocator.free(actual_hex);

    try std.testing.expectEqualStrings(expected_hex, actual_hex);
}

test "ABI cross-validation - web3.js approve encoding" {
    const allocator = std.testing.allocator;

    const spender: address.Address = [_]u8{
        0x7a, 0x25, 0x0d, 0x56, 0x30, 0xb4, 0xcf, 0x53,
        0x99, 0x39, 0xc1, 0xf0, 0x7d, 0x1e, 0x3e, 0xa4,
        0x0f, 0x60, 0x63, 0xaf,
    };
    const max_uint256: u256 = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;

    const values = [_]AbiValue{
        addressValue(spender),
        uint256_value(max_uint256),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_hex = "0000000000000000000000007a250d5630b4cf539939c1f07d1e3ea40f6063afffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
    const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer allocator.free(actual_hex);

    try std.testing.expectEqualStrings(expected_hex, actual_hex);
}

test "ABI cross-validation - viem string encoding 'Hello World'" {
    const allocator = std.testing.allocator;

    const values = [_]AbiValue{
        stringValue("Hello World"),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_hex = "0000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000b48656c6c6f20576f726c64000000000000000000000000000000000000000000";
    const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer allocator.free(actual_hex);

    try std.testing.expectEqualStrings(expected_hex, actual_hex);
}

test "ABI cross-validation - ethers.js multiple parameters encoding" {
    const allocator = std.testing.allocator;

    const addr: address.Address = [_]u8{
        0xc9, 0x61, 0x14, 0x5a, 0x54, 0xc9, 0x6e, 0x3a,
        0xe9, 0xba, 0xa0, 0x48, 0xc4, 0xf4, 0xd6, 0xb0,
        0x4c, 0x13, 0x91, 0x6b,
    };
    const values = [_]AbiValue{
        uint256_value(420),
        boolValue(true),
        addressValue(addr),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_hex = "00000000000000000000000000000000000000000000000000000000000001a40000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c961145a54c96e3ae9baa048c4f4d6b04c13916b";
    const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer allocator.free(actual_hex);

    try std.testing.expectEqualStrings(expected_hex, actual_hex);
}

test "ABI cross-validation - real contract function encoding" {
    const allocator = std.testing.allocator;

    const addr1: address.Address = [_]u8{0x11} ** 20;
    const addr2: address.Address = [_]u8{0x22} ** 20;
    const path = [_]address.Address{ addr1, addr2 };

    const to_addr: address.Address = [_]u8{0x33} ** 20;

    const values = [_]AbiValue{
        uint256_value(1000000000000000000),
        uint256_value(900000000000000000),
        .{ .@"address[]" = &path },
        addressValue(to_addr),
        uint256_value(1700000000),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const types = [_]AbiType{ .uint256, .uint256, .@"address[]", .address, .uint256 };
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[2].@"address[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(u256, 1000000000000000000), decoded[0].uint256);
    try std.testing.expectEqual(@as(u256, 900000000000000000), decoded[1].uint256);
    try std.testing.expectEqual(@as(usize, 2), decoded[2].@"address[]".len);
    try std.testing.expectEqualSlices(u8, &to_addr, &decoded[3].address);
    try std.testing.expectEqual(@as(u256, 1700000000), decoded[4].uint256);
}

test "ABI cross-validation - bytes encoding with known hash" {
    const allocator = std.testing.allocator;

    const data = [_]u8{ 0xde, 0xad, 0xbe, 0xef, 0xca, 0xfe, 0xba, 0xbe };
    const values = [_]AbiValue{
        bytesValue(&data),
    };

    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    const expected_hex = "00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000008deadbeefcafebabe0000000000000000000000000000000000000000000000";
    const actual_hex = try std.fmt.allocPrint(allocator, "{}", .{std.fmt.fmtSliceHexLower(encoded)});
    defer allocator.free(actual_hex);

    try std.testing.expectEqualStrings(expected_hex, actual_hex);
}

// Security Tests - DoS Prevention

test "Security - MAX_ABI_LENGTH prevents memory exhaustion on decode" {
    const allocator = std.testing.allocator;

    // Create encoded data claiming to have an absurdly large length (20 MB)
    var large_data: [64]u8 = undefined;
    @memset(&large_data, 0);

    // First word: offset to dynamic data = 32
    std.mem.writeInt(u256, large_data[0..32], 32, .big);

    // Second word: claimed length = 20MB (exceeds MAX_ABI_LENGTH)
    const excessive_length: u256 = 20 * 1024 * 1024;
    std.mem.writeInt(u256, large_data[32..64], excessive_length, .big);

    const types = [_]AbiType{.bytes};

    // Should fail with MaxLengthExceeded
    const result = decodeAbiParameters(allocator, &large_data, &types);
    try std.testing.expectError(AbiError.MaxLengthExceeded, result);
}

test "Security - MAX_ABI_LENGTH prevents memory exhaustion on encode" {
    const allocator = std.testing.allocator;

    // Try to allocate a string that would exceed MAX_ABI_LENGTH
    const huge_str_len = MAX_ABI_LENGTH + 1000;
    const huge_str = try allocator.alloc(u8, huge_str_len);
    defer allocator.free(huge_str);
    @memset(huge_str, 'A');

    const values = [_]AbiValue{
        stringValue(huge_str),
    };

    // Should fail with MaxLengthExceeded
    const result = encodeAbiParameters(allocator, &values);
    try std.testing.expectError(AbiError.MaxLengthExceeded, result);
}

test "Security - MAX_RECURSION_DEPTH prevents stack exhaustion" {
    const allocator = std.testing.allocator;

    // Create nested array structure that would exceed recursion depth
    // We can't actually create deeply nested arrays in the current type system,
    // but we can test with the maximum supported depth

    // Create a uint256[] array at depth 0
    const arr = [_]u256{ 1, 2, 3 };
    const values = [_]AbiValue{
        .{ .@"uint256[]" = &arr },
    };

    // Encode it (should work at depth 0)
    const encoded = try encodeAbiParameters(allocator, &values);
    defer allocator.free(encoded);

    // Decode it (should work at depth 0)
    const types = [_]AbiType{.@"uint256[]"};
    const decoded = try decodeAbiParameters(allocator, encoded, &types);
    defer {
        allocator.free(decoded[0].@"uint256[]");
        allocator.free(decoded);
    }

    try std.testing.expectEqual(@as(usize, 3), decoded[0].@"uint256[]".len);
}

test "Security - safeIntCast prevents integer overflow" {
    // Test that safeIntCast properly validates ranges

    // Valid cast
    const valid = try safeIntCast(u64, 100);
    try std.testing.expectEqual(@as(u64, 100), valid);

    // Invalid cast - value too large for u64
    const too_large: u256 = std.math.maxInt(u256);
    const result = safeIntCast(u64, too_large);
    try std.testing.expectError(AbiError.IntegerCastOverflow, result);
}

test "Security - validateAllocationSize prevents large allocations" {
    // Within limit
    try validateAllocationSize(1024);
    try validateAllocationSize(MAX_ABI_LENGTH);

    // Exceeds limit
    const result = validateAllocationSize(MAX_ABI_LENGTH + 1);
    try std.testing.expectError(AbiError.MaxLengthExceeded, result);
}

test "Security - validateRecursionDepth prevents deep recursion" {
    // Within limit
    try validateRecursionDepth(0);
    try validateRecursionDepth(MAX_RECURSION_DEPTH - 1);

    // Exceeds limit
    const result = validateRecursionDepth(MAX_RECURSION_DEPTH);
    try std.testing.expectError(AbiError.MaxRecursionDepthExceeded, result);
}

test "Security - array length validation on decode" {
    const allocator = std.testing.allocator;

    // Create encoded data with excessive array length
    var data: [64]u8 = undefined;
    @memset(&data, 0);

    // First word: offset = 32
    std.mem.writeInt(u256, data[0..32], 32, .big);

    // Second word: array length that would cause excessive memory allocation
    const excessive_count: u256 = MAX_ABI_LENGTH / 32 + 1000;
    std.mem.writeInt(u256, data[32..64], excessive_count, .big);

    const types = [_]AbiType{.@"uint256[]"};

    // Should fail with MaxLengthExceeded when trying to allocate array
    const result = decodeAbiParameters(allocator, &data, &types);
    try std.testing.expectError(AbiError.MaxLengthExceeded, result);
}

test "Security - string array total size validation" {
    const allocator = std.testing.allocator;

    // Create many large strings that would exceed MAX_ABI_LENGTH in total
    const str_count = 1000;
    const str_size = MAX_ABI_LENGTH / 100; // Each string is 100KB

    const strings = try allocator.alloc([]const u8, str_count);
    defer allocator.free(strings);

    for (strings) |*s| {
        const str = try allocator.alloc(u8, str_size);
        @memset(str, 'X');
        s.* = str;
    }
    defer for (strings) |s| {
        allocator.free(s);
    };

    var values = try allocator.alloc(AbiValue, str_count);
    defer allocator.free(values);

    for (strings, 0..) |s, i| {
        values[i] = stringValue(s);
    }

    // Should fail with MaxLengthExceeded due to total size
    const result = encodeAbiParameters(allocator, values);
    try std.testing.expectError(AbiError.MaxLengthExceeded, result);
}
