const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const primitives = @import("primitives");
const utils = @import("utils");

/// Error type for trie operations
pub const TrieError = error{
    InvalidNode,
    InvalidKey,
    InvalidProof,
    InvalidPath,
    NonExistentNode,
    EmptyInput,
    OutOfMemory,
    CorruptedTrie,
};

/// 16-bit mask for efficient representation of children
pub const TrieMask = struct {
    mask: u16,

    pub fn init() TrieMask {
        return TrieMask{ .mask = 0 };
    }

    pub fn set(self: *TrieMask, index: u4) void {
        const bit = @as(u16, 1) << index;
        self.mask |= bit;
    }

    pub fn unset(self: *TrieMask, index: u4) void {
        const bit = @as(u16, 1) << index;
        self.mask &= ~bit;
    }

    pub fn is_set(self: TrieMask, index: u4) bool {
        const bit = @as(u16, 1) << index;
        return (self.mask & bit) != 0;
    }

    pub fn bit_count(self: TrieMask) u5 {
        var count: u5 = 0;
        var mask = self.mask;
        while (mask != 0) : (mask &= mask - 1) {
            count += 1;
        }
        return count;
    }

    pub fn is_empty(self: TrieMask) bool {
        return self.mask == 0;
    }
};

/// Represents different node types in the trie
pub const NodeType = enum {
    Empty,
    Branch,
    Extension,
    Leaf,
};

/// Value stored in trie - either raw bytes or a hash
pub const HashValue = union(enum) {
    Raw: []const u8,
    Hash: [32]u8,

    pub fn deinit(self: HashValue, allocator: Allocator) void {
        switch (self) {
            .Raw => |data| allocator.free(data),
            .Hash => {}, // Hashes are static/fixed size
        }
    }

    pub fn hash(self: HashValue, allocator: Allocator) ![32]u8 {
        switch (self) {
            .Hash => |h| return h,
            .Raw => |data| {
                // RLP encode the data first
                const encoded = try primitives.Rlp.encode(allocator, data);
                defer allocator.free(encoded);

                // Then calculate the hash
                var hash_output: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_output, .{});
                return hash_output;
            },
        }
    }

    pub fn dupe(self: HashValue, allocator: Allocator) !HashValue {
        switch (self) {
            .Hash => |h| return HashValue{ .Hash = h },
            .Raw => |data| {
                const data_copy = try allocator.dupe(u8, data);
                return HashValue{ .Raw = data_copy };
            },
        }
    }
};

/// Branch node in the trie with up to 16 children (one per nibble)
pub const BranchNode = struct {
    children: [16]?HashValue = [_]?HashValue{null} ** 16,
    value: ?HashValue = null,
    children_mask: TrieMask = TrieMask.init(),

    pub fn init() BranchNode {
        return BranchNode{};
    }

    pub fn deinit(self: *BranchNode, allocator: Allocator) void {
        for (self.children, 0..) |child, i| {
            if (child != null and self.children_mask.is_set(@intCast(i))) {
                child.?.deinit(allocator);
            }
        }
        if (self.value) |value| {
            value.deinit(allocator);
        }
    }

    pub fn is_empty(self: BranchNode) bool {
        return self.children_mask.is_empty() and self.value == null;
    }

    pub fn dupe(self: BranchNode, allocator: Allocator) !BranchNode {
        var new_branch = BranchNode.init();
        new_branch.children_mask = self.children_mask;

        // Track how many children we've copied for cleanup on error
        var copied_count: usize = 0;
        errdefer {
            // Clean up any children we've already copied
            for (0..copied_count) |i| {
                if (new_branch.children[i]) |*child| {
                    child.deinit(allocator);
                }
            }
            // Clean up value if we copied it
            if (new_branch.value) |*v| {
                v.deinit(allocator);
            }
        }

        // Deep copy all children
        for (self.children, 0..) |child, i| {
            if (child) |c| {
                new_branch.children[i] = try c.dupe(allocator);
                copied_count = i + 1;
            }
        }

        // Deep copy value if present
        if (self.value) |v| {
            new_branch.value = try v.dupe(allocator);
        }

        return new_branch;
    }

    pub fn encode(self: BranchNode, allocator: Allocator) ![]u8 {
        var encoded_children = std.array_list.AlignedManaged([]u8, null).init(allocator);
        defer {
            for (encoded_children.items) |item| {
                allocator.free(item);
            }
            encoded_children.deinit();
        }

        // Encode each child or an empty string
        for (self.children) |child| {
            if (child) |value| {
                switch (value) {
                    .Raw => |data| {
                        const encoded = try primitives.Rlp.encode(allocator, data);
                        try encoded_children.append(encoded);
                    },
                    .Hash => |hash| {
                        const encoded = try primitives.Rlp.encode(allocator, &hash);
                        try encoded_children.append(encoded);
                    },
                }
            } else {
                const empty = try primitives.Rlp.encode(allocator, "");
                try encoded_children.append(empty);
            }
        }

        // Encode value or empty string
        if (self.value) |value| {
            switch (value) {
                .Raw => |data| {
                    const encoded = try primitives.Rlp.encode(allocator, data);
                    try encoded_children.append(encoded);
                },
                .Hash => |hash| {
                    const encoded = try primitives.Rlp.encode(allocator, &hash);
                    try encoded_children.append(encoded);
                },
            }
        } else {
            const empty = try primitives.Rlp.encode(allocator, "");
            try encoded_children.append(empty);
        }

        // Encode the entire node as a list
        return try primitives.Rlp.encode(allocator, encoded_children.items);
    }
};

/// Extension node - compresses shared path prefixes
pub const ExtensionNode = struct {
    nibbles: []u8,
    next: HashValue,

    pub fn init(allocator: Allocator, path: []u8, next: HashValue) !ExtensionNode {
        _ = allocator;
        return ExtensionNode{
            .nibbles = path,
            .next = next,
        };
    }

    pub fn deinit(self: *ExtensionNode, allocator: Allocator) void {
        allocator.free(self.nibbles);
        self.next.deinit(allocator);
    }

    pub fn encode(self: ExtensionNode, allocator: Allocator) ![]u8 {
        var items = std.array_list.AlignedManaged([]u8, null).init(allocator);
        defer {
            for (items.items) |item| {
                allocator.free(item);
            }
            items.deinit();
        }

        // Encode the path
        const encoded_path = try encode_path(allocator, self.nibbles, false);
        try items.append(encoded_path);

        // Encode the next node
        const encoded_next = switch (self.next) {
            .Raw => |data| try primitives.Rlp.encode(allocator, data),
            .Hash => |hash| try primitives.Rlp.encode(allocator, &hash),
        };
        try items.append(encoded_next);

        // Encode as a list
        return try primitives.Rlp.encode(allocator, items.items);
    }
};

/// Leaf node - stores actual key-value pairs
pub const LeafNode = struct {
    nibbles: []u8,
    value: HashValue,

    pub fn init(allocator: Allocator, path: []u8, value: HashValue) !LeafNode {
        _ = allocator;
        return LeafNode{
            .nibbles = path,
            .value = value,
        };
    }

    pub fn deinit(self: *LeafNode, allocator: Allocator) void {
        allocator.free(self.nibbles);
        self.value.deinit(allocator);
    }

    pub fn encode(self: LeafNode, allocator: Allocator) ![]u8 {
        var items = std.array_list.AlignedManaged([]u8, null).init(allocator);
        defer {
            for (items.items) |item| {
                allocator.free(item);
            }
            items.deinit();
        }

        // Encode the path
        const encoded_path = try encode_path(allocator, self.nibbles, true);
        try items.append(encoded_path);

        // Encode the value
        const encoded_value = switch (self.value) {
            .Raw => |data| try primitives.Rlp.encode(allocator, data),
            .Hash => |hash| try primitives.Rlp.encode(allocator, &hash),
        };
        try items.append(encoded_value);

        // Encode as a list
        return try primitives.Rlp.encode(allocator, items.items);
    }
};

/// The main trie node type
pub const TrieNode = union(NodeType) {
    Empty: void,
    Branch: BranchNode,
    Extension: ExtensionNode,
    Leaf: LeafNode,

    pub fn deinit(self: *TrieNode, allocator: Allocator) void {
        switch (self.*) {
            .Empty => {},
            .Branch => |*branch| branch.deinit(allocator),
            .Extension => |*extension| extension.deinit(allocator),
            .Leaf => |*leaf| leaf.deinit(allocator),
        }
    }

    pub fn encode(self: TrieNode, allocator: Allocator) ![]u8 {
        return switch (self) {
            .Empty => try primitives.Rlp.encode(allocator, ""),
            .Branch => |branch| try branch.encode(allocator),
            .Extension => |extension| try extension.encode(allocator),
            .Leaf => |leaf| try leaf.encode(allocator),
        };
    }

    pub fn hash(self: TrieNode, allocator: Allocator) ![32]u8 {
        const encoded = try self.encode(allocator);
        defer allocator.free(encoded);

        var hash_output: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(encoded, &hash_output, .{});
        return hash_output;
    }
};

/// Converts hex key to nibbles
pub fn key_to_nibbles(allocator: Allocator, key: []const u8) ![]u8 {
    const nibbles = try allocator.alloc(u8, key.len * 2);
    errdefer allocator.free(nibbles);

    for (key, 0..) |byte, i| {
        nibbles[i * 2] = byte >> 4;
        nibbles[i * 2 + 1] = byte & 0x0F;
    }

    return nibbles;
}

/// Converts nibbles back to hex key
pub fn nibbles_to_key(allocator: Allocator, nibbles: []const u8) ![]u8 {
    // Must have even number of nibbles
    if (nibbles.len % 2 != 0) {
        return TrieError.InvalidKey;
    }

    const key = try allocator.alloc(u8, nibbles.len / 2);
    errdefer allocator.free(key);

    var i: usize = 0;
    while (i < nibbles.len) : (i += 2) {
        key[i / 2] = (nibbles[i] << 4) | nibbles[i + 1];
    }

    return key;
}

/// Encodes a path for either leaf or extension nodes
fn encode_path(allocator: Allocator, nibbles: []const u8, is_leaf: bool) ![]u8 {
    // Handle empty nibbles case
    if (nibbles.len == 0) {
        const hex_arr = try allocator.alloc(u8, 1);
        hex_arr[0] = if (is_leaf) 0x20 else 0x00;
        return hex_arr;
    }

    // Create a new array for the encoded path
    const len = if (nibbles.len % 2 == 0) (nibbles.len / 2) + 1 else (nibbles.len + 1) / 2;
    const hex_arr = try allocator.alloc(u8, len);
    errdefer allocator.free(hex_arr);

    if (nibbles.len % 2 == 0) {
        // Even number of nibbles
        hex_arr[0] = if (is_leaf) 0x20 else 0x00;
        for (1..hex_arr.len) |i| {
            hex_arr[i] = (nibbles[(i - 1) * 2] << 4) | nibbles[(i - 1) * 2 + 1];
        }
    } else {
        // Odd number of nibbles
        hex_arr[0] = (if (is_leaf) @as(u8, 0x30) else @as(u8, 0x10)) | nibbles[0];
        for (1..hex_arr.len) |i| {
            hex_arr[i] = (nibbles[i * 2 - 1] << 4) | nibbles[i * 2];
        }
    }

    return hex_arr;
}

/// Decodes a path into nibbles
pub fn decode_path(allocator: Allocator, encoded_path: []const u8) !struct { nibbles: []u8, is_leaf: bool } {
    if (encoded_path.len == 0) {
        return TrieError.InvalidPath;
    }

    const prefix = encoded_path[0];
    const prefix_nibble = prefix >> 4;
    const is_leaf = prefix_nibble == 2 or prefix_nibble == 3;
    const has_odd_nibble = prefix_nibble == 1 or prefix_nibble == 3;

    const nibble_count = if (has_odd_nibble)
        encoded_path.len * 2 - 1
    else
        (encoded_path.len - 1) * 2;

    const nibbles = try allocator.alloc(u8, nibble_count);
    errdefer allocator.free(nibbles);

    if (has_odd_nibble) {
        nibbles[0] = prefix & 0x0F;
        for (1..encoded_path.len) |i| {
            nibbles[i * 2 - 1] = encoded_path[i] >> 4;
            nibbles[i * 2] = encoded_path[i] & 0x0F;
        }
    } else {
        for (0..encoded_path.len - 1) |i| {
            nibbles[i * 2] = encoded_path[i + 1] >> 4;
            nibbles[i * 2 + 1] = encoded_path[i + 1] & 0x0F;
        }
    }

    return .{ .nibbles = nibbles, .is_leaf = is_leaf };
}

/// The main HashBuilder for constructing Merkle Patricia Tries
pub const HashBuilder = struct {
    allocator: Allocator,
    hashed_nodes: std.StringHashMap(TrieNode),

    pub fn init(allocator: Allocator) HashBuilder {
        return HashBuilder{
            .allocator = allocator,
            .hashed_nodes = std.StringHashMap(TrieNode).init(allocator),
        };
    }

    pub fn deinit(self: *HashBuilder) void {
        var it = self.hashed_nodes.iterator();
        while (it.next()) |entry| {
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.hashed_nodes.deinit();
    }

    // Main interface functions and implementations will be added here
};

// Tests

test "TrieMask operations" {
    var mask = TrieMask.init();
    try testing.expect(mask.is_empty());
    try testing.expectEqual(@as(u5, 0), mask.bit_count());

    mask.set(1);
    try testing.expect(!mask.is_empty());
    try testing.expectEqual(@as(u5, 1), mask.bit_count());
    try testing.expect(mask.is_set(1));
    try testing.expect(!mask.is_set(2));

    mask.set(3);
    try testing.expectEqual(@as(u5, 2), mask.bit_count());

    mask.unset(1);
    try testing.expectEqual(@as(u5, 1), mask.bit_count());
    try testing.expect(!mask.is_set(1));
    try testing.expect(mask.is_set(3));

    mask.unset(3);
    try testing.expect(mask.is_empty());
}

test "key_to_nibbles and nibbles_to_key" {
    const allocator = testing.allocator;

    const key = [_]u8{ 0x12, 0x34, 0xAB, 0xCD };
    const nibbles = try key_to_nibbles(allocator, &key);
    defer allocator.free(nibbles);

    try testing.expectEqual(@as(usize, 8), nibbles.len);
    try testing.expectEqual(@as(u8, 1), nibbles[0]);
    try testing.expectEqual(@as(u8, 2), nibbles[1]);
    try testing.expectEqual(@as(u8, 3), nibbles[2]);
    try testing.expectEqual(@as(u8, 4), nibbles[3]);
    try testing.expectEqual(@as(u8, 10), nibbles[4]);
    try testing.expectEqual(@as(u8, 11), nibbles[5]);
    try testing.expectEqual(@as(u8, 12), nibbles[6]);
    try testing.expectEqual(@as(u8, 13), nibbles[7]);

    const round_trip = try nibbles_to_key(allocator, nibbles);
    defer allocator.free(round_trip);

    try testing.expectEqualSlices(u8, &key, round_trip);
}

test "encode_path and decode_path - basic even extension" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3, 4 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);
    try testing.expectEqual(@as(u8, 0x12), encoded[1]);
    try testing.expectEqual(@as(u8, 0x34), encoded[2]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path and decode_path - basic odd leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3, 4, 5 };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x31), encoded[0]);
    try testing.expectEqual(@as(u8, 0x23), encoded[1]);
    try testing.expectEqual(@as(u8, 0x45), encoded[2]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - empty path extension" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqual(@as(usize, 0), decoded.nibbles.len);
}

test "encode_path - empty path leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqual(@as(usize, 0), decoded.nibbles.len);
}

test "encode_path - single nibble extension" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{7};
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x17), encoded[0]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - single nibble leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{9};
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x39), encoded[0]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - even length leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0, 1, 2, 3, 4, 5 };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 4), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]);
    try testing.expectEqual(@as(u8, 0x01), encoded[1]);
    try testing.expectEqual(@as(u8, 0x23), encoded[2]);
    try testing.expectEqual(@as(u8, 0x45), encoded[3]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - odd length extension" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 1, 2, 3 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 2), encoded.len);
    try testing.expectEqual(@as(u8, 0x11), encoded[0]);
    try testing.expectEqual(@as(u8, 0x23), encoded[1]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - all zeros even extension" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0, 0, 0, 0 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);
    try testing.expectEqual(@as(u8, 0x00), encoded[1]);
    try testing.expectEqual(@as(u8, 0x00), encoded[2]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - all 0xF even leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0xF, 0xF, 0xF, 0xF };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]);
    try testing.expectEqual(@as(u8, 0xFF), encoded[1]);
    try testing.expectEqual(@as(u8, 0xFF), encoded[2]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - all 0xF odd leaf" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0xF, 0xF, 0xF };
    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 2), encoded.len);
    try testing.expectEqual(@as(u8, 0x3F), encoded[0]);
    try testing.expectEqual(@as(u8, 0xFF), encoded[1]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - prefix flags verification" {

    const allocator = testing.allocator;

    // Test all four prefix types
    // 0x0_ = even extension (no terminator, even flag)
    {
        const nibbles = [_]u8{ 1, 2 };
        const encoded = try encode_path(allocator, &nibbles, false);
        defer allocator.free(encoded);
        try testing.expectEqual(@as(u8, 0x00), encoded[0] & 0xF0);
    }

    // 0x1_ = odd extension (no terminator, odd flag)
    {
        const nibbles = [_]u8{1};
        const encoded = try encode_path(allocator, &nibbles, false);
        defer allocator.free(encoded);
        try testing.expectEqual(@as(u8, 0x10), encoded[0] & 0xF0);
    }

    // 0x2_ = even leaf (terminator, even flag)
    {
        const nibbles = [_]u8{ 1, 2 };
        const encoded = try encode_path(allocator, &nibbles, true);
        defer allocator.free(encoded);
        try testing.expectEqual(@as(u8, 0x20), encoded[0] & 0xF0);
    }

    // 0x3_ = odd leaf (terminator, odd flag)
    {
        const nibbles = [_]u8{1};
        const encoded = try encode_path(allocator, &nibbles, true);
        defer allocator.free(encoded);
        try testing.expectEqual(@as(u8, 0x30), encoded[0] & 0xF0);
    }
}

test "encode_path - round trip even extension with various lengths" {

    const allocator = testing.allocator;

    const test_cases = [_][]const u8{
        &[_]u8{ 0, 0 },
        &[_]u8{ 1, 2 },
        &[_]u8{ 0xA, 0xB },
        &[_]u8{ 0xF, 0xF },
        &[_]u8{ 1, 2, 3, 4 },
        &[_]u8{ 1, 2, 3, 4, 5, 6 },
        &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE, 0xF },
    };

    for (test_cases) |nibbles| {
        const encoded = try encode_path(allocator, nibbles, false);
        defer allocator.free(encoded);

        const decoded = try decode_path(allocator, encoded);
        defer allocator.free(decoded.nibbles);

        try testing.expectEqual(false, decoded.is_leaf);
        try testing.expectEqualSlices(u8, nibbles, decoded.nibbles);
    }
}

test "encode_path - round trip odd leaf with various lengths" {

    const allocator = testing.allocator;

    const test_cases = [_][]const u8{
        &[_]u8{0},
        &[_]u8{1},
        &[_]u8{0xF},
        &[_]u8{ 1, 2, 3 },
        &[_]u8{ 1, 2, 3, 4, 5 },
        &[_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0xA, 0xB, 0xC, 0xD, 0xE },
    };

    for (test_cases) |nibbles| {
        const encoded = try encode_path(allocator, nibbles, true);
        defer allocator.free(encoded);

        const decoded = try decode_path(allocator, encoded);
        defer allocator.free(decoded.nibbles);

        try testing.expectEqual(true, decoded.is_leaf);
        try testing.expectEqualSlices(u8, nibbles, decoded.nibbles);
    }
}

test "encode_path - nibble with first nibble 0 in odd path" {

    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0, 1, 2 };
    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 2), encoded.len);
    try testing.expectEqual(@as(u8, 0x10), encoded[0]);
    try testing.expectEqual(@as(u8, 0x12), encoded[1]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - long path even extension" {

    const allocator = testing.allocator;

    var nibbles: [64]u8 = undefined;
    for (0..64) |i| {
        nibbles[i] = @intCast(i % 16);
    }

    const encoded = try encode_path(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 33), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(false, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "encode_path - long path odd leaf" {

    const allocator = testing.allocator;

    var nibbles: [63]u8 = undefined;
    for (0..63) |i| {
        nibbles[i] = @intCast(i % 16);
    }

    const encoded = try encode_path(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 32), encoded.len);
    try testing.expectEqual(@as(u8, 0x30), encoded[0] & 0xF0);

    const decoded = try decode_path(allocator, encoded);
    defer allocator.free(decoded.nibbles);

    try testing.expectEqual(true, decoded.is_leaf);
    try testing.expectEqualSlices(u8, &nibbles, decoded.nibbles);
}

test "decode_path - error on empty input" {

    const allocator = testing.allocator;

    const empty = [_]u8{};
    const result = decode_path(allocator, &empty);
    try testing.expectError(TrieError.InvalidPath, result);
}

test "BranchNode encoding" {

    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    const data1 = "value1";
    const data1_copy = try allocator.dupe(u8, data1);
    branch.children[1] = HashValue{ .Raw = data1_copy };
    branch.children_mask.set(1);

    const data2 = "value2";
    const data2_copy = try allocator.dupe(u8, data2);
    branch.children[9] = HashValue{ .Raw = data2_copy };
    branch.children_mask.set(9);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // With RLP, we can only verify encoding-decoding roundtrip because
    // the exact encoding layout is complex to predict
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);
        },
        .String => unreachable,
    }
}

test "LeafNode encoding" {

    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "test_value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Verify it's a list with 2 items (path and value)
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => unreachable,
    }
}

test "ExtensionNode encoding" {

    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "next_node";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    var extension = try ExtensionNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer extension.deinit(allocator);

    const encoded = try extension.encode(allocator);
    defer allocator.free(encoded);

    // Verify it's a list with 2 items (path and next node)
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => unreachable,
    }
}

test "TrieNode hash" {

    const allocator = testing.allocator;

    // Create a leaf node
    const path = [_]u8{ 1, 2, 3, 4 };
    const value = "test_value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.dupe(u8, &path);

    const leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    var node = TrieNode{ .Leaf = leaf };
    defer node.deinit(allocator);

    const hash = try node.hash(allocator);

    // We can't predict the exact hash, but we can ensure it's non-zero
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);
}

test "BranchNode - empty branch full RLP structure" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify all 17 elements
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // All children should be empty
            for (items[0..16]) |item| {
                switch (item) {
                    .String => |str| {
                        try testing.expectEqual(@as(usize, 0), str.len);
                    },
                    .List => return error.TestExpectedString,
                }
            }

            // Value slot should be empty
            switch (items[16]) {
                .String => |str| {
                    try testing.expectEqual(@as(usize, 0), str.len);
                },
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - multiple children full RLP structure" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add values at multiple indices
    const data1 = "value1";
    const data1_copy = try allocator.dupe(u8, data1);
    branch.children[1] = HashValue{ .Raw = data1_copy };
    branch.children_mask.set(1);

    const data2 = "value2";
    const data2_copy = try allocator.dupe(u8, data2);
    branch.children[9] = HashValue{ .Raw = data2_copy };
    branch.children_mask.set(9);

    const data3 = "value3";
    const data3_copy = try allocator.dupe(u8, data3);
    branch.children[15] = HashValue{ .Raw = data3_copy };
    branch.children_mask.set(15);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // Check specific children are present
            switch (items[1]) {
                .String => |str| try testing.expect(str.len > 0),
                .List => return error.TestExpectedString,
            }
            switch (items[9]) {
                .String => |str| try testing.expect(str.len > 0),
                .List => return error.TestExpectedString,
            }
            switch (items[15]) {
                .String => |str| try testing.expect(str.len > 0),
                .List => return error.TestExpectedString,
            }

            // Other children should be empty
            switch (items[0]) {
                .String => |str| try testing.expectEqual(@as(usize, 0), str.len),
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - with terminal value RLP structure" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Set terminal value
    const terminal_data = "terminal";
    const terminal_copy = try allocator.dupe(u8, terminal_data);
    branch.value = HashValue{ .Raw = terminal_copy };

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify terminal value
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // Last item should be terminal value
            switch (items[16]) {
                .String => |str| try testing.expect(str.len > 0),
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "BranchNode - hash children RLP encoding" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add hash value
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    branch.children[3] = HashValue{ .Hash = hash };
    branch.children_mask.set(3);

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify hash is present
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);
            switch (items[3]) {
                .String => |str| try testing.expect(str.len > 0),
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "LeafNode - empty path encoding" {
    const allocator = testing.allocator;

    const value = "value";
    const value_copy = try allocator.dupe(u8, value);
    const path_copy = try allocator.alloc(u8, 0);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify 2-element structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => return error.TestExpectedList,
    }
}

test "LeafNode - long value encoding (>55 bytes)" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2 };
    // Value longer than 55 bytes to test long string encoding
    const long_value = try allocator.alloc(u8, 100);
    defer allocator.free(long_value);
    for (long_value, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const value_copy = try allocator.dupe(u8, long_value);
    const path_copy = try allocator.dupe(u8, &path);

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify long value is present
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
            switch (items[1]) {
                .String => |str| try testing.expect(str.len > 55),
                .List => return error.TestExpectedString,
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "ExtensionNode - hash pointer encoding" {
    const allocator = testing.allocator;

    const path = [_]u8{ 5, 6 };
    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        byte.* = @intCast(i * 7 % 256);
    }

    const path_copy = try allocator.dupe(u8, &path);

    var extension = try ExtensionNode.init(allocator, path_copy, HashValue{ .Hash = hash });
    defer extension.deinit(allocator);

    const encoded = try extension.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify 2-element structure
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 2), items.len);
        },
        .String => return error.TestExpectedList,
    }
}

test "TrieNode - Empty encoding" {
    const allocator = testing.allocator;

    const node = TrieNode{ .Empty = {} };
    const encoded = try node.encode(allocator);
    defer allocator.free(encoded);

    // Empty node should encode as empty string
    try testing.expect(encoded.len > 0);

    // Decode to verify
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .String => |str| {
            try testing.expectEqual(@as(usize, 0), str.len);
        },
        .List => return error.TestExpectedString,
    }
}

test "TrieNode - hash determinism for branch" {
    const allocator = testing.allocator;

    // Create two identical branches
    var branch1 = BranchNode.init();
    defer branch1.deinit(allocator);
    const data1 = "test";
    const data1_copy = try allocator.dupe(u8, data1);
    branch1.children[0] = HashValue{ .Raw = data1_copy };
    branch1.children_mask.set(0);

    var node1 = TrieNode{ .Branch = branch1 };
    const hash1 = try node1.hash(allocator);

    var branch2 = BranchNode.init();
    const data2_copy = try allocator.dupe(u8, data1);
    branch2.children[0] = HashValue{ .Raw = data2_copy };
    branch2.children_mask.set(0);

    var node2 = TrieNode{ .Branch = branch2 };
    defer node2.deinit(allocator);
    const hash2 = try node2.hash(allocator);

    // Hashes should be identical (deterministic)
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "TrieNode - hash determinism for leaf" {
    const allocator = testing.allocator;

    const path = [_]u8{ 1, 2, 3 };
    const value = "value";

    const value_copy1 = try allocator.dupe(u8, value);
    const path_copy1 = try allocator.dupe(u8, &path);
    const leaf1 = try LeafNode.init(allocator, path_copy1, HashValue{ .Raw = value_copy1 });
    var node1 = TrieNode{ .Leaf = leaf1 };
    defer node1.deinit(allocator);
    const hash1 = try node1.hash(allocator);

    const value_copy2 = try allocator.dupe(u8, value);
    const path_copy2 = try allocator.dupe(u8, &path);
    const leaf2 = try LeafNode.init(allocator, path_copy2, HashValue{ .Raw = value_copy2 });
    var node2 = TrieNode{ .Leaf = leaf2 };
    defer node2.deinit(allocator);
    const hash2 = try node2.hash(allocator);

    // Hashes should be identical
    try testing.expectEqualSlices(u8, &hash1, &hash2);
}

test "HashValue - hash calculation for raw data" {
    const allocator = testing.allocator;

    const data = "test_data";
    const data_copy = try allocator.dupe(u8, data);
    const value = HashValue{ .Raw = data_copy };
    defer value.deinit(allocator);

    const hash = try value.hash(allocator);

    // Hash should be non-zero
    var is_zero = true;
    for (hash) |byte| {
        if (byte != 0) {
            is_zero = false;
            break;
        }
    }
    try testing.expect(!is_zero);
}

test "HashValue - hash passthrough for hash value" {
    const allocator = testing.allocator;

    var hash_input: [32]u8 = undefined;
    for (&hash_input, 0..) |*byte, i| {
        byte.* = @intCast(i);
    }

    const value = HashValue{ .Hash = hash_input };
    const hash = try value.hash(allocator);

    // Should return the same hash (passthrough)
    try testing.expectEqualSlices(u8, &hash_input, &hash);
}

test "Node serialization - inline small values" {
    const allocator = testing.allocator;

    // Small value stored as Raw
    const small_data = "small";
    const small_copy = try allocator.dupe(u8, small_data);
    const path_copy = try allocator.dupe(u8, &[_]u8{ 1, 2 });

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = small_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Small values should encode compactly
    try testing.expect(encoded.len < 100);
}

test "Node serialization - large value encoding" {
    const allocator = testing.allocator;

    const large_data = try allocator.alloc(u8, 50);
    defer allocator.free(large_data);
    for (large_data, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const large_copy = try allocator.dupe(u8, large_data);
    const path_copy = try allocator.dupe(u8, &[_]u8{ 3, 4 });

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = large_copy });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Large values should be fully encoded
    try testing.expect(encoded.len > 50);
}

test "Node serialization - hash value encoding" {
    const allocator = testing.allocator;

    var hash: [32]u8 = undefined;
    for (&hash, 0..) |*byte, i| {
        byte.* = @intCast((i * 13) % 256);
    }

    const path_copy = try allocator.dupe(u8, &[_]u8{ 5, 6 });

    var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Hash = hash });
    defer leaf.deinit(allocator);

    const encoded = try leaf.encode(allocator);
    defer allocator.free(encoded);

    // Hash values should result in compact encoding
    try testing.expect(encoded.len > 0);
    try testing.expect(encoded.len < 100);
}

test "BranchNode - all children populated" {
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Populate all 16 children
    var i: u4 = 0;
    while (i < 16) : (i += 1) {
        var buf: [10]u8 = undefined;
        const data = std.fmt.bufPrint(&buf, "child{d}", .{i}) catch unreachable;
        const data_copy = try allocator.dupe(u8, data);
        branch.children[i] = HashValue{ .Raw = data_copy };
        branch.children_mask.set(i);
    }

    const encoded = try branch.encode(allocator);
    defer allocator.free(encoded);

    // Decode to verify all children
    const decoded = try primitives.Rlp.decode(allocator, encoded, false);
    defer decoded.data.deinit(allocator);

    switch (decoded.data) {
        .List => |items| {
            try testing.expectEqual(@as(usize, 17), items.len);

            // All 16 children should be non-empty
            for (items[0..16]) |item| {
                switch (item) {
                    .String => |str| try testing.expect(str.len > 0),
                    .List => return error.TestExpectedString,
                }
            }
        },
        .String => return error.TestExpectedList,
    }
}

test "Node encoding - round trip consistency" {
    const allocator = testing.allocator;

    // Test leaf round trip
    {
        const path = [_]u8{ 1, 2, 3 };
        const value = "test_value";
        const value_copy = try allocator.dupe(u8, value);
        const path_copy = try allocator.dupe(u8, &path);

        var leaf = try LeafNode.init(allocator, path_copy, HashValue{ .Raw = value_copy });
        defer leaf.deinit(allocator);

        const encoded1 = try leaf.encode(allocator);
        defer allocator.free(encoded1);

        // Re-encode and compare
        const encoded2 = try leaf.encode(allocator);
        defer allocator.free(encoded2);

        try testing.expectEqualSlices(u8, encoded1, encoded2);
    }
}
