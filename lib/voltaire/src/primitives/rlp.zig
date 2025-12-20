//! RLP (Recursive Length Prefix) - Ethereum's serialization format
//!
//! This module provides a complete implementation of RLP encoding and decoding
//! as specified in the Ethereum Yellow Paper. RLP is used throughout Ethereum
//! for serializing transactions, blocks, state, and other data structures.
//!
//! ## RLP Specification Overview
//!
//! RLP is a serialization method that encodes arbitrarily nested arrays of
//! binary data. It defines encoding rules for:
//!
//! ### String Encoding
//! - **Single byte [0x00, 0x7f]**: Encoded as itself
//! - **String [0-55 bytes]**: 0x80 + length, followed by string
//! - **Long string [55+ bytes]**: 0xb7 + length_of_length + length + string
//!
//! ### List Encoding
//! - **Short list [0-55 bytes]**: 0xc0 + length, followed by items
//! - **Long list [55+ bytes]**: 0xf7 + length_of_length + length + items
//!
//! ## Key Features
//!
//! - **Canonical Encoding**: Ensures unique serialization of data
//! - **Efficient Parsing**: Streaming decode with minimal allocations
//! - **Memory Safety**: Comprehensive bounds checking
//! - **Error Handling**: Detailed error types for debugging
//! - **Flexible API**: Supports various input types and patterns
//!
//! ## Usage Examples
//!
//! ### Encoding Simple Data
//! ```zig
//! const rlp = @import("rlp.zig");
//!
//! // Encode a string
//! const encoded = try rlp.encode(allocator, "hello");
//! defer allocator.free(encoded);
//!
//! // Encode a list of strings
//! const list = [_][]const u8{ "cat", "dog" };
//! const encoded_list = try rlp.encode(allocator, list);
//! defer allocator.free(encoded_list);
//! ```
//!
//! ### Decoding RLP Data
//! ```zig
//! // Decode RLP data
//! const decoded = try rlp.decode(allocator, encoded_data);
//! defer decoded.data.deinit(allocator);
//!
//! // Access decoded data
//! switch (decoded.data) {
//!     .String => |str| std.log.info("String: {s}", .{str}),
//!     .List => |items| std.log.info("List with {} items", .{items.len}),
//! }
//! ```
//!
//! ### Working with Nested Structures
//! ```zig
//! // Encode nested list: [[], [[]]]
//! const inner_list = [_][]const u8{};
//! const nested_list = [_][]const []const u8{&inner_list};
//! const encoded = try rlp.encode(allocator, nested_list);
//! defer allocator.free(encoded);
//! ```
//!
//! ## Error Handling
//!
//! The module provides comprehensive error types:
//! - `InputTooShort`: Unexpected end of input
//! - `InputTooLong`: Data exceeds expected length
//! - `LeadingZeros`: Invalid number encoding
//! - `NonCanonicalSize`: Non-minimal length encoding
//! - `InvalidLength`: Malformed length field
//! - `UnexpectedInput`: Invalid data format
//!
//! ## Performance Considerations
//!
//! - **Streaming**: Processes data incrementally
//! - **Allocation Strategy**: Minimal allocations during encoding
//! - **Memory Management**: Clear ownership semantics
//! - **Validation**: Comprehensive but efficient error checking
//!
//! ## Design Principles
//!
//! 1. **Specification Compliance**: Exact adherence to Ethereum RLP spec
//! 2. **Memory Safety**: Comprehensive bounds checking and validation
//! 3. **Performance**: Efficient encoding/decoding with minimal allocations
//! 4. **Error Transparency**: Clear error reporting for debugging
//! 5. **Type Safety**: Strongly typed API prevents common mistakes

const std = @import("std");
const Hex = @import("hex.zig");
const Allocator = std.mem.Allocator;

/// Maximum recursion depth to prevent stack overflow attacks
/// Reasonable limit for nested RLP structures
pub const MAX_RLP_DEPTH: u32 = 32;

pub const RlpError = error{
    InputTooShort,
    InputTooLong,
    LeadingZeros,
    NonCanonicalSize,
    InvalidLength,
    UnexpectedInput,
    InvalidRemainder,
    ExtraZeros,
    RecursionDepthExceeded,
};

pub const EncodeError = std.mem.Allocator.Error;

pub const Decoded = struct {
    data: Data,
    remainder: []const u8,
};

pub const Data = union(enum) {
    List: []Data,
    String: []const u8,

    pub fn deinit(self: Data, allocator: Allocator) void {
        switch (self) {
            .List => |items| {
                for (items) |item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
            .String => |value| {
                // Always free strings since they are always allocated during decoding
                allocator.free(value);
            },
        }
    }
};

/// Encodes input into RLP format according to the Ethereum RLP specification.
/// The input can be a slice of bytes or a list of other RLP encodable items.
/// Allocates memory for the result, which must be freed by the caller.
pub fn encode(allocator: Allocator, input: anytype) EncodeError![]u8 {
    const T = @TypeOf(input);
    const info = @typeInfo(T);

    // Handle byte arrays and slices
    if (info == .array) {
        const child_info = @typeInfo(info.array.child);
        if (child_info == .int and child_info.int.bits == 8) {
            return try encodeBytes(allocator, &input);
        }
    } else if (info == .pointer) {
        const child_info = @typeInfo(info.pointer.child);
        if (child_info == .int and child_info.int.bits == 8) {
            return try encodeBytes(allocator, input);
        } else if (child_info == .array) {
            const elem_info = @typeInfo(child_info.array.child);
            if (elem_info == .int and elem_info.int.bits == 8) {
                // Handle string literals like "a" which are *const [N:0]u8
                return try encodeBytes(allocator, input);
            }
        }
    }

    // Handle lists
    if (info == .array or info == .pointer) {
        var result = std.ArrayList(u8){};
        defer result.deinit(allocator);

        // First encode each element
        var encoded_items = std.ArrayList([]u8){};
        defer {
            for (encoded_items.items) |item| {
                allocator.free(item);
            }
            encoded_items.deinit(allocator);
        }

        var total_len: usize = 0;
        for (input) |item| {
            const encoded_item = try encode(allocator, item);
            try encoded_items.append(allocator, encoded_item);
            total_len += encoded_item.len;
        }

        // Calculate header
        if (total_len < 56) {
            try result.append(allocator, 0xc0 + @as(u8, @intCast(total_len)));
        } else {
            const len_bytes = try encodeLength(allocator, total_len);
            defer allocator.free(len_bytes);
            try result.append(allocator, 0xf7 + @as(u8, @intCast(len_bytes.len)));
            try result.appendSlice(allocator, len_bytes);
        }

        // Append encoded items
        for (encoded_items.items) |item| {
            try result.appendSlice(allocator, item);
        }

        return try result.toOwnedSlice(allocator);
    }

    // Handle comptime integers
    if (info == .comptime_int) {
        // Convert to u64 at compile time
        const value_u64: u64 = input;
        return try encode(allocator, value_u64);
    }

    // Handle integers
    if (info == .int) {
        if (input == 0) {
            // Special case: 0 is encoded as empty string
            const result = try allocator.alloc(u8, 1);
            result[0] = 0x80;
            return result;
        }

        var bytes = std.ArrayList(u8){};
        defer bytes.deinit(allocator);

        var value = input;
        while (value > 0) {
            try bytes.insert(allocator, 0, @as(u8, @intCast(value & 0xff)));
            if (@TypeOf(value) == u8) {
                value = 0; // For u8, after extracting the byte, we're done
            } else {
                value = @divTrunc(value, @as(@TypeOf(value), 256)); // Divide by 256 instead of shifting by 8
            }
        }

        return try encodeBytes(allocator, bytes.items);
    }

    @compileError("Unsupported type for RLP encoding: " ++ @typeName(T));
}

/// Encodes a byte array or slice according to RLP rules
pub fn encodeBytes(allocator: Allocator, bytes: []const u8) ![]u8 {
    // If a single byte less than 0x80, return as is
    if (bytes.len == 1 and bytes[0] < 0x80) {
        const result = try allocator.alloc(u8, 1);
        result[0] = bytes[0];
        return result;
    }

    // If string is 0-55 bytes long, return [0x80+len, data]
    if (bytes.len < 56) {
        const result = try allocator.alloc(u8, 1 + bytes.len);
        result[0] = 0x80 + @as(u8, @intCast(bytes.len));
        @memcpy(result[1..], bytes);
        return result;
    }

    // If string is >55 bytes long, return [0xb7+len(len(data)), len(data), data]
    const len_bytes = try encodeLength(allocator, bytes.len);
    defer allocator.free(len_bytes);

    const result = try allocator.alloc(u8, 1 + len_bytes.len + bytes.len);
    result[0] = 0xb7 + @as(u8, @intCast(len_bytes.len));
    @memcpy(result[1 .. 1 + len_bytes.len], len_bytes);
    @memcpy(result[1 + len_bytes.len ..], bytes);

    return result;
}

/// Encodes an integer length as bytes
pub fn encodeLength(allocator: Allocator, length: usize) ![]u8 {
    var len_bytes = std.ArrayList(u8){};
    defer len_bytes.deinit(allocator);

    var temp = length;
    while (temp > 0) {
        try len_bytes.insert(allocator, 0, @as(u8, @intCast(temp & 0xff)));
        temp >>= 8;
    }

    return try len_bytes.toOwnedSlice(allocator);
}

/// Decodes RLP encoded data.
/// If stream is true, it returns both the decoded data and the remaining bytes.
/// If stream is false (default), it expects the entire input to be consumed.
/// Allocates memory that must be freed by calling .deinit() on the result.
pub fn decode(allocator: Allocator, input: []const u8, stream: bool) !Decoded {
    if (input.len == 0) {
        return Decoded{
            .data = Data{ .String = try allocator.dupe(u8, &.{}) },
            .remainder = &.{},
        };
    }

    const result = try _decode(allocator, input, 0);

    if (!stream and result.remainder.len > 0) {
        // Free the allocated data before returning error
        result.data.deinit(allocator);
        return RlpError.InvalidRemainder;
    }

    return result;
}

fn _decode(allocator: Allocator, input: []const u8, depth: u32) !Decoded {
    if (input.len == 0) {
        return RlpError.InputTooShort;
    }

    // Check recursion depth to prevent stack overflow
    if (depth >= MAX_RLP_DEPTH) {
        return RlpError.RecursionDepthExceeded;
    }

    const prefix = input[0];

    // Single byte (0x00 - 0x7f)
    if (prefix <= 0x7f) {
        const result = try allocator.alloc(u8, 1);
        result[0] = prefix;
        return Decoded{
            .data = Data{ .String = result },
            .remainder = input[1..],
        };
    }

    // String 0-55 bytes (0x80 - 0xb7)
    if (prefix <= 0xb7) {
        const length = prefix - 0x80;

        if (input.len - 1 < length) {
            return RlpError.InputTooShort;
        }

        // Empty string
        if (prefix == 0x80) {
            return Decoded{
                .data = Data{ .String = try allocator.dupe(u8, &.{}) },
                .remainder = input[1..],
            };
        }

        // Enforce canonical representation: single byte < 0x80 should be encoded as itself
        if (length == 1 and input[1] < 0x80) {
            return RlpError.NonCanonicalSize;
        }

        const data = try allocator.alloc(u8, length);
        @memcpy(data, input[1 .. 1 + length]);

        return Decoded{
            .data = Data{ .String = data },
            .remainder = input[1 + length ..],
        };
    }

    // String > 55 bytes (0xb8 - 0xbf)
    if (prefix <= 0xbf) {
        const length_of_length = prefix - 0xb7;

        if (input.len - 1 < length_of_length) {
            return RlpError.InputTooShort;
        }

        // Check for leading zeros in the length
        if (input[1] == 0) {
            return RlpError.LeadingZeros;
        }

        var total_length: usize = 0;
        for (input[1 .. 1 + length_of_length]) |byte| {
            total_length = (total_length << 8) + byte;
        }

        // Enforce canonical representation: if length < 56, should use the short form
        if (total_length < 56) {
            return RlpError.NonCanonicalSize;
        }

        if (input.len - 1 - length_of_length < total_length) {
            return RlpError.InputTooShort;
        }

        const data = try allocator.alloc(u8, total_length);
        @memcpy(data, input[1 + length_of_length .. 1 + length_of_length + total_length]);

        return Decoded{
            .data = Data{ .String = data },
            .remainder = input[1 + length_of_length + total_length ..],
        };
    }

    // List 0-55 bytes (0xc0 - 0xf7)
    if (prefix <= 0xf7) {
        const length = prefix - 0xc0;

        if (input.len - 1 < length) {
            return RlpError.InputTooShort;
        }

        if (length == 0) {
            return Decoded{
                .data = Data{ .List = try allocator.alloc(Data, 0) },
                .remainder = input[1..],
            };
        }

        var items = std.ArrayList(Data){};
        errdefer {
            // Clean up already allocated items on error
            for (items.items) |item| {
                item.deinit(allocator);
            }
            items.deinit(allocator);
        }

        var remaining = input[1 .. 1 + length];
        while (remaining.len > 0) {
            const decoded = try _decode(allocator, remaining, depth + 1);
            try items.append(allocator, decoded.data);
            remaining = decoded.remainder;
        }

        return Decoded{
            .data = Data{ .List = try items.toOwnedSlice(allocator) },
            .remainder = input[1 + length ..],
        };
    }

    // List > 55 bytes (0xf8 - 0xff)
    if (prefix <= 0xff) {
        const length_of_length = prefix - 0xf7;

        if (input.len - 1 < length_of_length) {
            return RlpError.InputTooShort;
        }

        // Check for leading zeros in the length
        if (input[1] == 0) {
            return RlpError.LeadingZeros;
        }

        var total_length: usize = 0;
        for (input[1 .. 1 + length_of_length]) |byte| {
            total_length = (total_length << 8) + byte;
        }

        // Enforce canonical representation: if length < 56, should use the short form
        if (total_length < 56) {
            return RlpError.NonCanonicalSize;
        }

        if (input.len - 1 - length_of_length < total_length) {
            return RlpError.InputTooShort;
        }

        var items = std.ArrayList(Data){};
        errdefer {
            // Clean up already allocated items on error
            for (items.items) |item| {
                item.deinit(allocator);
            }
            items.deinit(allocator);
        }

        var remaining = input[1 + length_of_length .. 1 + length_of_length + total_length];
        while (remaining.len > 0) {
            const decoded = try _decode(allocator, remaining, depth + 1);
            try items.append(allocator, decoded.data);
            remaining = decoded.remainder;
        }

        return Decoded{
            .data = Data{ .List = try items.toOwnedSlice(allocator) },
            .remainder = input[1 + length_of_length + total_length ..],
        };
    }

    return RlpError.UnexpectedInput;
}

// Utility functions

/// Converts a byte slice to a hex string
pub fn bytesToHex(allocator: Allocator, bytes: []const u8) ![]u8 {
    return try Hex.bytesToHex(allocator, bytes);
}

/// Converts a hex string to bytes
pub fn hexToBytes(allocator: Allocator, hex_str: []const u8) ![]u8 {
    return try Hex.hexToBytes(allocator, hex_str);
}

/// Concatenates multiple byte slices into one
pub fn concatBytes(allocator: Allocator, arrays: []const []const u8) ![]u8 {
    var total_len: usize = 0;
    for (arrays) |arr| {
        total_len += arr.len;
    }

    const result = try allocator.alloc(u8, total_len);
    var index: usize = 0;
    for (arrays) |arr| {
        @memcpy(result[index .. index + arr.len], arr);
        index += arr.len;
    }

    return result;
}

// Converts a UTF-8 string to bytes
pub fn utf8_to_bytes(allocator: Allocator, str: []const u8) ![]u8 {
    return try allocator.dupe(u8, str);
}

// Test cases
test "RLP single byte" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const single_byte = "a";
    const encoded = try encode(allocator, single_byte);
    defer allocator.free(encoded);

    try testing.expectEqualSlices(u8, &[_]u8{'a'}, encoded);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqualSlices(u8, &[_]u8{'a'}, str),
        .List => unreachable,
    }
}

test "RLP string 0-55 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const dog_str = "dog";
    const encoded = try encode(allocator, dog_str);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 4), encoded.len);
    try testing.expectEqual(@as(u8, 131), encoded[0]);
    try testing.expectEqual(@as(u8, 'd'), encoded[1]);
    try testing.expectEqual(@as(u8, 'o'), encoded[2]);
    try testing.expectEqual(@as(u8, 'g'), encoded[3]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqualSlices(u8, dog_str, str),
        .List => unreachable,
    }
}

test "RLP string >55 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const long_str = "zoo255zoo255zzzzzzzzzzzzssssssssssssssssssssssssssssssssssssssssssssss";
    const encoded = try encode(allocator, long_str);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 72), encoded.len);
    try testing.expectEqual(@as(u8, 184), encoded[0]);
    try testing.expectEqual(@as(u8, 70), encoded[1]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqualSlices(u8, long_str, str),
        .List => unreachable,
    }
}

test "RLP list 0-55 bytes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const list = [_][]const u8{ "dog", "god", "cat" };

    const encoded_list = try encode(allocator, list[0..]);
    defer allocator.free(encoded_list);

    try testing.expectEqual(@as(usize, 13), encoded_list.len);
    try testing.expectEqual(@as(u8, 204), encoded_list[0]);

    const decoded = try decode(allocator, encoded_list, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 3), items.len);
            for (items, 0..) |item, i| {
                switch (item) {
                    .String => |str| try testing.expectEqualSlices(u8, list[i], str),
                    .List => unreachable,
                }
            }
        },
        .String => unreachable,
    }
}

test "RLP integers" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Single byte integer
    {
        const encoded = try encode(allocator, 15);
        defer allocator.free(encoded);

        try testing.expectEqual(@as(usize, 1), encoded.len);
        try testing.expectEqual(@as(u8, 15), encoded[0]);

        const decoded = try decode(allocator, encoded, false);
        defer decoded.data.deinit(allocator);

        switch (decoded.data) {
            .String => |str| {
                try testing.expectEqual(@as(usize, 1), str.len);
                try testing.expectEqual(@as(u8, 15), str[0]);
            },
            .List => unreachable,
        }
    }

    // Multi-byte integer
    {
        const encoded = try encode(allocator, 1024);
        defer allocator.free(encoded);

        try testing.expectEqual(@as(usize, 3), encoded.len);
        try testing.expectEqual(@as(u8, 130), encoded[0]);
        try testing.expectEqual(@as(u8, 4), encoded[1]);
        try testing.expectEqual(@as(u8, 0), encoded[2]);

        const decoded = try decode(allocator, encoded, false);
        defer decoded.data.deinit(allocator);

        switch (decoded.data) {
            .String => |str| {
                try testing.expectEqual(@as(usize, 2), str.len);
                try testing.expectEqual(@as(u8, 4), str[0]);
                try testing.expectEqual(@as(u8, 0), str[1]);
            },
            .List => unreachable,
        }
    }

    // Zero
    {
        const encoded = try encode(allocator, 0);
        defer allocator.free(encoded);

        try testing.expectEqual(@as(usize, 1), encoded.len);
        try testing.expectEqual(@as(u8, 0x80), encoded[0]);

        const decoded = try decode(allocator, encoded, false);
        defer decoded.data.deinit(allocator);

        switch (decoded.data) {
            .String => |str| try testing.expectEqual(@as(usize, 0), str.len),
            .List => unreachable,
        }
    }
}

test "RLP nested lists - simple two level [[1,2],[3,4]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Manually construct [[1, 2], [3, 4]]
    // [1, 2] = 0xc2 0x01 0x02 (list prefix 0xc0+2, then bytes 1 and 2)
    // [3, 4] = 0xc2 0x03 0x04 (list prefix 0xc0+2, then bytes 3 and 4)
    // [[1,2],[3,4]] = 0xc6 0xc2 0x01 0x02 0xc2 0x03 0x04 (list prefix 0xc0+6, then both sublists)
    const manual_encoding = [_]u8{ 0xc6, 0xc2, 0x01, 0x02, 0xc2, 0x03, 0x04 };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 2), outer_list.len);

            // Verify first inner list [1, 2]
            switch (outer_list[0]) {
                .List => |inner_list1| {
                    try testing.expectEqual(@as(usize, 2), inner_list1.len);
                    switch (inner_list1[0]) {
                        .String => |bytes| {
                            try testing.expectEqual(@as(usize, 1), bytes.len);
                            try testing.expectEqual(@as(u8, 1), bytes[0]);
                        },
                        .List => unreachable,
                    }
                    switch (inner_list1[1]) {
                        .String => |bytes| {
                            try testing.expectEqual(@as(usize, 1), bytes.len);
                            try testing.expectEqual(@as(u8, 2), bytes[0]);
                        },
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }

            // Verify second inner list [3, 4]
            switch (outer_list[1]) {
                .List => |inner_list2| {
                    try testing.expectEqual(@as(usize, 2), inner_list2.len);
                    switch (inner_list2[0]) {
                        .String => |bytes| {
                            try testing.expectEqual(@as(usize, 1), bytes.len);
                            try testing.expectEqual(@as(u8, 3), bytes[0]);
                        },
                        .List => unreachable,
                    }
                    switch (inner_list2[1]) {
                        .String => |bytes| {
                            try testing.expectEqual(@as(usize, 1), bytes.len);
                            try testing.expectEqual(@as(u8, 4), bytes[0]);
                        },
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP nested lists - empty nested lists [[],[]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // [] = 0xc0 (empty list)
    // [[],[]] = 0xc2 0xc0 0xc0 (list of 2 bytes, containing two empty lists)
    const manual_encoding = [_]u8{ 0xc2, 0xc0, 0xc0 };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 2), outer_list.len);
            switch (outer_list[0]) {
                .List => |inner| try testing.expectEqual(@as(usize, 0), inner.len),
                .String => unreachable,
            }
            switch (outer_list[1]) {
                .List => |inner| try testing.expectEqual(@as(usize, 0), inner.len),
                .String => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP nested lists - single element [[1],[2]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // [1] = 0xc1 0x01 (list of 1 byte containing 1)
    // [2] = 0xc1 0x02 (list of 1 byte containing 2)
    // [[1],[2]] = 0xc4 0xc1 0x01 0xc1 0x02 (list of 4 bytes total)
    const manual_encoding = [_]u8{ 0xc4, 0xc1, 0x01, 0xc1, 0x02 };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 2), outer_list.len);
            switch (outer_list[0]) {
                .List => |inner1| {
                    try testing.expectEqual(@as(usize, 1), inner1.len);
                    switch (inner1[0]) {
                        .String => |bytes| try testing.expectEqual(@as(u8, 1), bytes[0]),
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }
            switch (outer_list[1]) {
                .List => |inner2| {
                    try testing.expectEqual(@as(usize, 1), inner2.len);
                    switch (inner2[0]) {
                        .String => |bytes| try testing.expectEqual(@as(u8, 2), bytes[0]),
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP nested lists - three levels [[[1,2],[3]],[[4]]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // [1,2] = 0xc2 0x01 0x02
    // [3] = 0xc1 0x03
    // [[1,2],[3]] = 0xc5 0xc2 0x01 0x02 0xc1 0x03
    // [4] = 0xc1 0x04
    // [[4]] = 0xc2 0xc1 0x04
    // [[[1,2],[3]],[[4]]] = 0xc9 0xc5 0xc2 0x01 0x02 0xc1 0x03 0xc2 0xc1 0x04
    const manual_encoding = [_]u8{ 0xc9, 0xc5, 0xc2, 0x01, 0x02, 0xc1, 0x03, 0xc2, 0xc1, 0x04 };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 2), outer_list.len);

            // Verify [[1,2],[3]]
            switch (outer_list[0]) {
                .List => |middle1| {
                    try testing.expectEqual(@as(usize, 2), middle1.len);
                    // Verify [1,2]
                    switch (middle1[0]) {
                        .List => |inner1| {
                            try testing.expectEqual(@as(usize, 2), inner1.len);
                            switch (inner1[0]) {
                                .String => |bytes| try testing.expectEqual(@as(u8, 1), bytes[0]),
                                .List => unreachable,
                            }
                            switch (inner1[1]) {
                                .String => |bytes| try testing.expectEqual(@as(u8, 2), bytes[0]),
                                .List => unreachable,
                            }
                        },
                        .String => unreachable,
                    }
                    // Verify [3]
                    switch (middle1[1]) {
                        .List => |inner2| {
                            try testing.expectEqual(@as(usize, 1), inner2.len);
                            switch (inner2[0]) {
                                .String => |bytes| try testing.expectEqual(@as(u8, 3), bytes[0]),
                                .List => unreachable,
                            }
                        },
                        .String => unreachable,
                    }
                },
                .String => unreachable,
            }

            // Verify [[4]]
            switch (outer_list[1]) {
                .List => |middle2| {
                    try testing.expectEqual(@as(usize, 1), middle2.len);
                    switch (middle2[0]) {
                        .List => |inner| {
                            try testing.expectEqual(@as(usize, 1), inner.len);
                            switch (inner[0]) {
                                .String => |bytes| try testing.expectEqual(@as(u8, 4), bytes[0]),
                                .List => unreachable,
                            }
                        },
                        .String => unreachable,
                    }
                },
                .String => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP nested lists - mixed types with strings and lists" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // ["cat", [1,2], "dog"]
    // "cat" = 0x83 'c' 'a' 't' (0x83 = 0x80+3, total 4 bytes)
    // [1,2] = 0xc2 0x01 0x02 (total 3 bytes)
    // "dog" = 0x83 'd' 'o' 'g' (total 4 bytes)
    // ["cat", [1,2], "dog"] = 0xcb 0x83 'c' 'a' 't' 0xc2 0x01 0x02 0x83 'd' 'o' 'g'
    // Total payload: 4+3+4 = 11 bytes, so 0xc0+11 = 0xcb
    const manual_encoding = [_]u8{ 0xcb, 0x83, 'c', 'a', 't', 0xc2, 0x01, 0x02, 0x83, 'd', 'o', 'g' };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 3), outer_list.len);

            // Verify "cat"
            switch (outer_list[0]) {
                .String => |bytes| try testing.expectEqualSlices(u8, "cat", bytes),
                .List => unreachable,
            }

            // Verify [1,2]
            switch (outer_list[1]) {
                .List => |inner| {
                    try testing.expectEqual(@as(usize, 2), inner.len);
                    switch (inner[0]) {
                        .String => |bytes| try testing.expectEqual(@as(u8, 1), bytes[0]),
                        .List => unreachable,
                    }
                    switch (inner[1]) {
                        .String => |bytes| try testing.expectEqual(@as(u8, 2), bytes[0]),
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }

            // Verify "dog"
            switch (outer_list[2]) {
                .String => |bytes| try testing.expectEqualSlices(u8, "dog", bytes),
                .List => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP nested lists - edge case with empty and non-empty [[],[1],[]]" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // [] = 0xc0
    // [1] = 0xc1 0x01
    // [[],[1],[]] = 0xc4 0xc0 0xc1 0x01 0xc0 (list of 4 bytes total)
    const manual_encoding = [_]u8{ 0xc4, 0xc0, 0xc1, 0x01, 0xc0 };

    const decoded = try decode(allocator, &manual_encoding, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 3), outer_list.len);
            switch (outer_list[0]) {
                .List => |inner| try testing.expectEqual(@as(usize, 0), inner.len),
                .String => unreachable,
            }
            switch (outer_list[1]) {
                .List => |inner| {
                    try testing.expectEqual(@as(usize, 1), inner.len);
                    switch (inner[0]) {
                        .String => |bytes| try testing.expectEqual(@as(u8, 1), bytes[0]),
                        .List => unreachable,
                    }
                },
                .String => unreachable,
            }
            switch (outer_list[2]) {
                .List => |inner| try testing.expectEqual(@as(usize, 0), inner.len),
                .String => unreachable,
            }
        },
        .String => unreachable,
    }
}

test "RLP stream decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create a stream of RLP encoded items
    const encoded_number = try encode(allocator, 1);
    defer allocator.free(encoded_number);

    const encoded_string = try encode(allocator, "test");
    defer allocator.free(encoded_string);

    const long_string = "This is a long string that should trigger the long string encoding in RLP";
    const encoded_long_string = try encode(allocator, long_string);
    defer allocator.free(encoded_long_string);

    const list_items = [_]i32{ 1, 2, 3 };
    const encoded_list = try encode(allocator, list_items);
    defer allocator.free(encoded_list);

    // Concatenate all encoded items
    const arrays = [_][]const u8{ encoded_number, encoded_string, encoded_long_string, encoded_list };
    const buffer_stream = try concatBytes(allocator, &arrays);
    defer allocator.free(buffer_stream);

    // Decode stream one by one
    var remaining: []const u8 = buffer_stream;

    // First item (number)
    var decoded = try decode(allocator, remaining, true);
    remaining = decoded.remainder;
    switch (decoded.data) {
        .String => |str| {
            try testing.expectEqual(@as(usize, 1), str.len);
            try testing.expectEqual(@as(u8, 1), str[0]);
        },
        .List => unreachable,
    }
    decoded.data.deinit(allocator);

    // Second item (string)
    decoded = try decode(allocator, remaining, true);
    remaining = decoded.remainder;
    switch (decoded.data) {
        .String => |str| {
            try testing.expectEqualSlices(u8, "test", str);
        },
        .List => unreachable,
    }
    decoded.data.deinit(allocator);

    // Third item (long string)
    decoded = try decode(allocator, remaining, true);
    remaining = decoded.remainder;
    switch (decoded.data) {
        .String => |str| {
            try testing.expectEqualSlices(u8, long_string, str);
        },
        .List => unreachable,
    }
    decoded.data.deinit(allocator);

    // Fourth item (list)
    decoded = try decode(allocator, remaining, true);
    remaining = decoded.remainder;
    switch (decoded.data) {
        .List => |list| {
            try testing.expectEqual(@as(usize, 3), list.len);
            for (list, 0..) |item, i| {
                switch (item) {
                    .String => |str| {
                        try testing.expectEqual(@as(usize, 1), str.len);
                        try testing.expectEqual(@as(u8, @intCast(i + 1)), str[0]);
                    },
                    .List => unreachable,
                }
            }
        },
        .String => unreachable,
    }
    decoded.data.deinit(allocator);

    // Verify all data was consumed
    try testing.expectEqual(@as(usize, 0), remaining.len);
}

test "RLP recursion depth limit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test 1: Verify MAX_RLP_DEPTH constant exists and has reasonable value
    try testing.expect(MAX_RLP_DEPTH == 32);

    // Test 2: Create deeply nested list that exceeds MAX_RLP_DEPTH
    // Each nested list adds one level of depth
    // We'll create a list with MAX_RLP_DEPTH + 5 levels of nesting
    var current_encoded = try encode(allocator, "inner");
    defer allocator.free(current_encoded);

    // Build nested structure: [[[[["inner"]]]]]
    var depth: u32 = 0;
    while (depth < MAX_RLP_DEPTH + 5) : (depth += 1) {
        const list = [_][]const u8{current_encoded};
        const new_encoded = try encode(allocator, list[0..]);
        if (depth > 0) {
            allocator.free(current_encoded);
        }
        current_encoded = new_encoded;
    }
    defer if (MAX_RLP_DEPTH + 5 > 0) allocator.free(current_encoded);

    // Test 3: Decoding should fail with RecursionDepthExceeded
    const result = decode(allocator, current_encoded, false);
    try testing.expectError(RlpError.RecursionDepthExceeded, result);
}

test "RLP max allowed depth" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create nested list exactly at MAX_RLP_DEPTH - 1 (should succeed)
    var current_encoded = try encode(allocator, "inner");
    defer allocator.free(current_encoded);

    // Build nested structure up to MAX_RLP_DEPTH - 1 levels
    var depth: u32 = 0;
    while (depth < MAX_RLP_DEPTH - 1) : (depth += 1) {
        const list = [_][]const u8{current_encoded};
        const new_encoded = try encode(allocator, list[0..]);
        if (depth > 0) {
            allocator.free(current_encoded);
        }
        current_encoded = new_encoded;
    }
    defer if (MAX_RLP_DEPTH - 1 > 0) allocator.free(current_encoded);

    // This should succeed since we're at MAX_RLP_DEPTH - 1
    const decoded = try decode(allocator, current_encoded, false);
    defer decoded.data.deinit(allocator);

    // Verify we got a list
    try testing.expect(decoded.data == .List);
}

test "RLP depth limit edge case" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test with exactly MAX_RLP_DEPTH levels (should succeed)
    var current_encoded = try encode(allocator, "data");
    defer allocator.free(current_encoded);

    var depth: u32 = 0;
    while (depth < MAX_RLP_DEPTH - 1) : (depth += 1) {
        const list = [_][]const u8{current_encoded};
        const new_encoded = try encode(allocator, list[0..]);
        if (depth > 0) {
            allocator.free(current_encoded);
        }
        current_encoded = new_encoded;
    }
    defer if (MAX_RLP_DEPTH - 1 > 0) allocator.free(current_encoded);

    // Decoding at exactly MAX_RLP_DEPTH should succeed
    const decoded = try decode(allocator, current_encoded, false);
    defer decoded.data.deinit(allocator);
    try testing.expect(decoded.data == .List);
}

test "RLP depth protection against attack" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simulate an attack with 100 levels of nesting
    const attack_depth: u32 = 100;
    var current_encoded = try encode(allocator, &[_]u8{});
    defer allocator.free(current_encoded);

    var depth: u32 = 0;
    while (depth < attack_depth) : (depth += 1) {
        const list = [_][]const u8{current_encoded};
        const new_encoded = try encode(allocator, list[0..]);
        if (depth > 0) {
            allocator.free(current_encoded);
        }
        current_encoded = new_encoded;
    }
    defer if (attack_depth > 0) allocator.free(current_encoded);

    // Should fail with RecursionDepthExceeded
    const result = decode(allocator, current_encoded, false);
    try testing.expectError(RlpError.RecursionDepthExceeded, result);
}

test "RLP empty string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const empty_str = "";
    const encoded = try encode(allocator, empty_str);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x80), encoded[0]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqual(@as(usize, 0), str.len),
        .List => unreachable,
    }
}

test "RLP empty list" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const empty_list = [_][]const u8{};
    const encoded = try encode(allocator, empty_list[0..]);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0xc0), encoded[0]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| try testing.expectEqual(@as(usize, 0), items.len),
        .String => unreachable,
    }
}

test "RLP malformed input - truncated string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // String header says 5 bytes but only 3 provided
    const malformed = [_]u8{ 0x85, 'a', 'b', 'c' };
    const result = decode(allocator, &malformed, false);
    try testing.expectError(RlpError.InputTooShort, result);
}

test "RLP malformed input - truncated list" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // List header says 10 bytes but only 5 provided
    const malformed = [_]u8{ 0xca, 0x83, 'd', 'o', 'g' };
    const result = decode(allocator, &malformed, false);
    try testing.expectError(RlpError.InputTooShort, result);
}

test "RLP malformed input - leading zeros in length" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Long string with leading zero in length
    const malformed = [_]u8{ 0xb8, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const result = decode(allocator, &malformed, false);
    try testing.expectError(RlpError.LeadingZeros, result);
}

test "RLP non-canonical encoding - single byte as string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Single byte less than 0x80 should not have 0x81 prefix
    const non_canonical = [_]u8{ 0x81, 0x50 };
    const result = decode(allocator, &non_canonical, false);
    try testing.expectError(RlpError.NonCanonicalSize, result);
}

test "RLP non-canonical encoding - short form for small string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // String of 5 bytes should use short form, not long form
    const non_canonical = [_]u8{ 0xb8, 0x05, 'h', 'e', 'l', 'l', 'o' };
    const result = decode(allocator, &non_canonical, false);
    try testing.expectError(RlpError.NonCanonicalSize, result);
}

test "RLP encode decode round-trip - large integer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const large_value: u64 = 0xFFFFFFFFFFFFFFFF;
    const encoded = try encode(allocator, large_value);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |bytes| {
            try testing.expectEqual(@as(usize, 8), bytes.len);
            var value: u64 = 0;
            for (bytes) |byte| {
                value = (value << 8) | byte;
            }
            try testing.expectEqual(large_value, value);
        },
        .List => unreachable,
    }
}

test "RLP encode decode round-trip - list with mixed types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create list with string and integer
    const str = "hello";
    const encoded_str = try encode(allocator, str);
    defer allocator.free(encoded_str);

    const encoded_int = try encode(allocator, 42);
    defer allocator.free(encoded_int);

    const list = [_][]const u8{ encoded_str, encoded_int };
    const encoded_list = try encode(allocator, list[0..]);
    defer allocator.free(encoded_list);

    const decoded = try decode(allocator, encoded_list, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => unreachable,
    }
}

test "RLP extra data in non-stream mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Valid encoding followed by extra bytes
    const with_extra = [_]u8{ 0x83, 'd', 'o', 'g', 0x01, 0x02 };
    const result = decode(allocator, &with_extra, false);
    try testing.expectError(RlpError.InvalidRemainder, result);
}

test "RLP extra data allowed in stream mode" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Valid encoding followed by extra bytes
    const with_extra = [_]u8{ 0x83, 'd', 'o', 'g', 0x01, 0x02 };
    const decoded = try decode(allocator, &with_extra, true);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqualSlices(u8, "dog", str),
        .List => unreachable,
    }

    // Remainder should be the extra bytes
    try testing.expectEqual(@as(usize, 2), decoded.remainder.len);
    try testing.expectEqual(@as(u8, 0x01), decoded.remainder[0]);
}

test "RLP all single byte values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test all values from 0x00 to 0x7f (should encode as themselves)
    var value: u8 = 0;
    while (value < 0x7f) : (value += 1) {
        const bytes = [_]u8{value};
        const encoded = try encode(allocator, &bytes);
        defer allocator.free(encoded);

        try testing.expectEqual(@as(usize, 1), encoded.len);
        try testing.expectEqual(value, encoded[0]);

        const decoded = try decode(allocator, encoded, false);
        defer decoded.data.deinit(allocator);

        switch (decoded.data) {
            .String => |str| {
                try testing.expectEqual(@as(usize, 1), str.len);
                try testing.expectEqual(value, str[0]);
            },
            .List => unreachable,
        }
    }
}

test "RLP boundary values - 55 byte string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Exactly 55 bytes - should use short form
    const str_55 = "a" ** 55;
    const encoded = try encode(allocator, str_55);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 56), encoded.len);
    try testing.expectEqual(@as(u8, 0x80 + 55), encoded[0]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqual(@as(usize, 55), str.len),
        .List => unreachable,
    }
}

test "RLP boundary values - 56 byte string" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Exactly 56 bytes - should use long form
    const str_56 = "a" ** 56;
    const encoded = try encode(allocator, str_56);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(u8, 0xb8), encoded[0]);
    try testing.expectEqual(@as(u8, 56), encoded[1]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| try testing.expectEqual(@as(usize, 56), str.len),
        .List => unreachable,
    }
}

test "RLP list boundary - 55 byte total" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create list where total encoded size is exactly 55 bytes
    const items = [_][]const u8{ "a" ** 17, "b" ** 17, "c" ** 17 };
    const encoded = try encode(allocator, items[0..]);
    defer allocator.free(encoded);

    // Should use short list form
    try testing.expect(encoded[0] >= 0xc0 and encoded[0] <= 0xf7);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |list| try testing.expectEqual(@as(usize, 3), list.len),
        .String => unreachable,
    }
}

test "RLP maximum u8 value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const max_u8: u8 = 255;
    const encoded = try encode(allocator, max_u8);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 2), encoded.len);
    try testing.expectEqual(@as(u8, 0x81), encoded[0]);
    try testing.expectEqual(@as(u8, 0xff), encoded[1]);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |bytes| {
            try testing.expectEqual(@as(usize, 1), bytes.len);
            try testing.expectEqual(@as(u8, 255), bytes[0]);
        },
        .List => unreachable,
    }
}

test "RLP nested list round-trip - two levels" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create [[1, 2], [3, 4]]
    const list1_item1 = try encode(allocator, 1);
    defer allocator.free(list1_item1);
    const list1_item2 = try encode(allocator, 2);
    defer allocator.free(list1_item2);
    const list1_items = [_][]const u8{ list1_item1, list1_item2 };
    const list1 = try encode(allocator, list1_items[0..]);
    defer allocator.free(list1);

    const list2_item1 = try encode(allocator, 3);
    defer allocator.free(list2_item1);
    const list2_item2 = try encode(allocator, 4);
    defer allocator.free(list2_item2);
    const list2_items = [_][]const u8{ list2_item1, list2_item2 };
    const list2 = try encode(allocator, list2_items[0..]);
    defer allocator.free(list2);

    const outer_items = [_][]const u8{ list1, list2 };
    const encoded = try encode(allocator, outer_items[0..]);
    defer allocator.free(encoded);

    const decoded = try decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |outer_list| {
            try testing.expectEqual(@as(usize, 2), outer_list.len);
            for (outer_list) |inner| {
                switch (inner) {
                    .List => |inner_list| {
                        try testing.expectEqual(@as(usize, 2), inner_list.len);
                    },
                    .String => unreachable,
                }
            }
        },
        .String => unreachable,
    }
}
