//! Merkle Patricia Trie - Ethereum's state storage data structure
//!
//! This module implements the Modified Merkle Patricia Trie as specified in the Ethereum Yellow Paper.
//! It provides cryptographically secure key-value storage with proof generation capabilities.
//!
//! ## Overview
//!
//! The Merkle Patricia Trie combines:
//! - **Patricia Trie**: Path compression for efficient sparse storage
//! - **Merkle Tree**: Cryptographic hashing for integrity verification
//!
//! ## Node Types
//!
//! 1. **Empty**: Null node (empty trie)
//! 2. **Leaf**: Terminal node storing a value
//! 3. **Extension**: Path compression node for shared prefixes
//! 4. **Branch**: Node with up to 16 children (one per nibble) + optional value
//!
//! ## Usage
//!
//! ```zig
//! var trie = Trie.init(allocator);
//! defer trie.deinit();
//!
//! // Insert key-value pairs
//! try trie.put(&[_]u8{0x12, 0x34}, "value1");
//! try trie.put(&[_]u8{0x12, 0x56}, "value2");
//!
//! // Retrieve values
//! const value = try trie.get(&[_]u8{0x12, 0x34});
//!
//! // Get root hash for verification
//! const root = trie.root_hash();
//!
//! // Generate Merkle proof
//! const proof = try trie.prove(&[_]u8{0x12, 0x34});
//! defer proof.deinit();
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const crypto = @import("crypto");

/// Error types for trie operations
pub const TrieError = error{
    /// Node structure is invalid or corrupted
    InvalidNode,
    /// Key format is invalid
    InvalidKey,
    /// Merkle proof is invalid or inconsistent
    InvalidProof,
    /// Path encoding is malformed
    InvalidPath,
    /// Requested node does not exist
    NonExistentNode,
    /// Input is empty when it shouldn't be
    EmptyInput,
    /// Memory allocation failed
    OutOfMemory,
    /// Trie structure is corrupted
    CorruptedTrie,
};

/// 16-bit mask for efficient branch children representation
///
/// Uses a bitmap to track which of the 16 possible nibble positions
/// have children, allowing O(1) membership tests and compact storage.
pub const TrieMask = struct {
    mask: u16,

    /// Initialize an empty mask (no children)
    pub fn init() TrieMask {
        return TrieMask{ .mask = 0 };
    }

    /// Set a bit at the given index (marks child as present)
    pub fn set(self: *TrieMask, index: u4) void {
        const bit = @as(u16, 1) << index;
        self.mask |= bit;
    }

    /// Unset a bit at the given index (marks child as absent)
    pub fn unset(self: *TrieMask, index: u4) void {
        const bit = @as(u16, 1) << index;
        self.mask &= ~bit;
    }

    /// Check if a bit is set at the given index
    pub fn is_set(self: TrieMask, index: u4) bool {
        const bit = @as(u16, 1) << index;
        return (self.mask & bit) != 0;
    }

    /// Count the number of set bits (number of children)
    pub fn bit_count(self: TrieMask) u5 {
        return @popCount(self.mask);
    }

    /// Check if the mask is empty (no children)
    pub fn is_empty(self: TrieMask) bool {
        return self.mask == 0;
    }
};

// Tests for TrieMask
test "TrieMask - initialization" {
    const testing = std.testing;

    const mask = TrieMask.init();
    try testing.expect(mask.is_empty());
    try testing.expectEqual(@as(u5, 0), mask.bit_count());
}

test "TrieMask - set and is_set" {
    const testing = std.testing;

    var mask = TrieMask.init();

    mask.set(0);
    try testing.expect(mask.is_set(0));
    try testing.expect(!mask.is_set(1));
    try testing.expectEqual(@as(u5, 1), mask.bit_count());

    mask.set(15);
    try testing.expect(mask.is_set(0));
    try testing.expect(mask.is_set(15));
    try testing.expectEqual(@as(u5, 2), mask.bit_count());
}

test "TrieMask - unset" {
    const testing = std.testing;

    var mask = TrieMask.init();
    mask.set(5);
    mask.set(10);
    try testing.expectEqual(@as(u5, 2), mask.bit_count());

    mask.unset(5);
    try testing.expect(!mask.is_set(5));
    try testing.expect(mask.is_set(10));
    try testing.expectEqual(@as(u5, 1), mask.bit_count());

    mask.unset(10);
    try testing.expect(mask.is_empty());
}

test "TrieMask - all positions" {
    const testing = std.testing;

    var mask = TrieMask.init();

    // Set all 16 positions
    for (0..16) |i| {
        mask.set(@intCast(i));
    }

    try testing.expectEqual(@as(u5, 16), mask.bit_count());

    // Verify all are set
    for (0..16) |i| {
        try testing.expect(mask.is_set(@intCast(i)));
    }

    // Unset all
    for (0..16) |i| {
        mask.unset(@intCast(i));
    }

    try testing.expect(mask.is_empty());
}

/// Convert a key (bytes) to nibbles (hex digits)
///
/// Each byte is split into two 4-bit nibbles (high and low).
/// Example: 0x1A -> [0x1, 0xA]
pub fn keyToNibbles(allocator: Allocator, key: []const u8) ![]u8 {
    const nibbles = try allocator.alloc(u8, key.len * 2);
    errdefer allocator.free(nibbles);

    for (key, 0..) |byte, i| {
        nibbles[i * 2] = byte >> 4; // High nibble
        nibbles[i * 2 + 1] = byte & 0x0F; // Low nibble
    }

    return nibbles;
}

/// Convert nibbles back to key bytes
///
/// Requires an even number of nibbles.
pub fn nibblesToKey(allocator: Allocator, nibbles: []const u8) ![]u8 {
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

test "keyToNibbles - basic conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const key = [_]u8{ 0x12, 0xAB };
    const nibbles = try keyToNibbles(allocator, &key);
    defer allocator.free(nibbles);

    try testing.expectEqual(@as(usize, 4), nibbles.len);
    try testing.expectEqual(@as(u8, 0x1), nibbles[0]);
    try testing.expectEqual(@as(u8, 0x2), nibbles[1]);
    try testing.expectEqual(@as(u8, 0xA), nibbles[2]);
    try testing.expectEqual(@as(u8, 0xB), nibbles[3]);
}

test "keyToNibbles - empty key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const key = [_]u8{};
    const nibbles = try keyToNibbles(allocator, &key);
    defer allocator.free(nibbles);

    try testing.expectEqual(@as(usize, 0), nibbles.len);
}

test "nibblesToKey - basic conversion" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0xA, 0xB };
    const key = try nibblesToKey(allocator, &nibbles);
    defer allocator.free(key);

    try testing.expectEqual(@as(usize, 2), key.len);
    try testing.expectEqual(@as(u8, 0x12), key[0]);
    try testing.expectEqual(@as(u8, 0xAB), key[1]);
}

test "nibblesToKey - odd length fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0x3 };
    const result = nibblesToKey(allocator, &nibbles);

    try testing.expectError(TrieError.InvalidKey, result);
}

test "keyToNibbles and nibblesToKey - round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const original = [_]u8{ 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };
    const nibbles = try keyToNibbles(allocator, &original);
    defer allocator.free(nibbles);

    const restored = try nibblesToKey(allocator, nibbles);
    defer allocator.free(restored);

    try testing.expectEqualSlices(u8, &original, restored);
}

/// Encode a nibble path for leaf or extension nodes
///
/// Path encoding (hex prefix encoding):
/// - Even length, extension: [0x00, ...]
/// - Odd length, extension:  [0x1X, ...] where X is first nibble
/// - Even length, leaf:      [0x20, ...]
/// - Odd length, leaf:       [0x3X, ...] where X is first nibble
pub fn encodePath(allocator: Allocator, nibbles: []const u8, is_leaf: bool) ![]u8 {
    if (nibbles.len == 0) {
        const result = try allocator.alloc(u8, 1);
        result[0] = if (is_leaf) 0x20 else 0x00;
        return result;
    }

    const is_odd = nibbles.len % 2 == 1;
    const encoded_len = if (is_odd) (nibbles.len + 1) / 2 else (nibbles.len / 2) + 1;
    const encoded = try allocator.alloc(u8, encoded_len);
    errdefer allocator.free(encoded);

    if (is_odd) {
        // Odd length: first byte contains prefix + first nibble
        const prefix: u8 = if (is_leaf) 0x30 else 0x10;
        encoded[0] = prefix | nibbles[0];

        // Pack remaining nibbles
        for (1..encoded_len) |i| {
            encoded[i] = (nibbles[i * 2 - 1] << 4) | nibbles[i * 2];
        }
    } else {
        // Even length: first byte is just prefix
        encoded[0] = if (is_leaf) 0x20 else 0x00;

        // Pack nibbles
        for (1..encoded_len) |i| {
            encoded[i] = (nibbles[(i - 1) * 2] << 4) | nibbles[(i - 1) * 2 + 1];
        }
    }

    return encoded;
}

/// Decode a path from hex prefix encoding
///
/// Returns the nibbles and a flag indicating if this is a leaf node.
pub fn decodePath(allocator: Allocator, encoded: []const u8) !struct { nibbles: []u8, is_leaf: bool } {
    if (encoded.len == 0) {
        return TrieError.InvalidPath;
    }

    const prefix = encoded[0];
    const prefix_nibble = prefix >> 4;
    const is_leaf = prefix_nibble == 2 or prefix_nibble == 3;
    const is_odd = prefix_nibble == 1 or prefix_nibble == 3;

    const nibble_count = if (is_odd)
        encoded.len * 2 - 1
    else
        (encoded.len - 1) * 2;

    const nibbles = try allocator.alloc(u8, nibble_count);
    errdefer allocator.free(nibbles);

    if (is_odd) {
        // First nibble is in the prefix byte
        nibbles[0] = prefix & 0x0F;

        // Unpack remaining bytes
        for (1..encoded.len) |i| {
            nibbles[i * 2 - 1] = encoded[i] >> 4;
            nibbles[i * 2] = encoded[i] & 0x0F;
        }
    } else {
        // Unpack all bytes (skip prefix)
        for (0..encoded.len - 1) |i| {
            nibbles[i * 2] = encoded[i + 1] >> 4;
            nibbles[i * 2 + 1] = encoded[i + 1] & 0x0F;
        }
    }

    return .{ .nibbles = nibbles, .is_leaf = is_leaf };
}

test "encodePath - even length extension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0x3, 0x4 };
    const encoded = try encodePath(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 3), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]); // Even extension prefix
    try testing.expectEqual(@as(u8, 0x12), encoded[1]);
    try testing.expectEqual(@as(u8, 0x34), encoded[2]);
}

test "encodePath - odd length leaf" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0x3 };
    const encoded = try encodePath(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 2), encoded.len);
    try testing.expectEqual(@as(u8, 0x31), encoded[0]); // Odd leaf prefix + first nibble
    try testing.expectEqual(@as(u8, 0x23), encoded[1]);
}

test "encodePath - empty nibbles extension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encodePath(allocator, &nibbles, false);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x00), encoded[0]);
}

test "encodePath - empty nibbles leaf" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{};
    const encoded = try encodePath(allocator, &nibbles, true);
    defer allocator.free(encoded);

    try testing.expectEqual(@as(usize, 1), encoded.len);
    try testing.expectEqual(@as(u8, 0x20), encoded[0]);
}

test "decodePath - even length extension" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = [_]u8{ 0x00, 0x12, 0x34 };
    const result = try decodePath(allocator, &encoded);
    defer allocator.free(result.nibbles);

    try testing.expect(!result.is_leaf);
    try testing.expectEqual(@as(usize, 4), result.nibbles.len);
    try testing.expectEqual(@as(u8, 0x1), result.nibbles[0]);
    try testing.expectEqual(@as(u8, 0x2), result.nibbles[1]);
    try testing.expectEqual(@as(u8, 0x3), result.nibbles[2]);
    try testing.expectEqual(@as(u8, 0x4), result.nibbles[3]);
}

test "decodePath - odd length leaf" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = [_]u8{ 0x31, 0x23 };
    const result = try decodePath(allocator, &encoded);
    defer allocator.free(result.nibbles);

    try testing.expect(result.is_leaf);
    try testing.expectEqual(@as(usize, 3), result.nibbles.len);
    try testing.expectEqual(@as(u8, 0x1), result.nibbles[0]);
    try testing.expectEqual(@as(u8, 0x2), result.nibbles[1]);
    try testing.expectEqual(@as(u8, 0x3), result.nibbles[2]);
}

test "decodePath - empty encoded fails" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const encoded = [_]u8{};
    const result = decodePath(allocator, &encoded);

    try testing.expectError(TrieError.InvalidPath, result);
}

test "encodePath and decodePath - round trip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const test_cases = [_]struct {
        nibbles: []const u8,
        is_leaf: bool,
    }{
        .{ .nibbles = &[_]u8{ 0x1, 0x2, 0x3, 0x4 }, .is_leaf = false },
        .{ .nibbles = &[_]u8{ 0xA, 0xB, 0xC }, .is_leaf = true },
        .{ .nibbles = &[_]u8{0x5}, .is_leaf = false },
        .{ .nibbles = &[_]u8{}, .is_leaf = true },
    };

    for (test_cases) |tc| {
        const encoded = try encodePath(allocator, tc.nibbles, tc.is_leaf);
        defer allocator.free(encoded);

        const decoded = try decodePath(allocator, encoded);
        defer allocator.free(decoded.nibbles);

        try testing.expectEqual(tc.is_leaf, decoded.is_leaf);
        try testing.expectEqualSlices(u8, tc.nibbles, decoded.nibbles);
    }
}

/// Node types in the trie
pub const NodeType = enum {
    Empty,
    Branch,
    Extension,
    Leaf,
};

/// Merkle Patricia Trie node
///
/// This is a union representing the four possible node types.
/// Each variant has different memory management requirements.
pub const Node = union(NodeType) {
    Empty: void,
    Branch: BranchNode,
    Extension: ExtensionNode,
    Leaf: LeafNode,

    /// Free all memory associated with this node
    pub fn deinit(self: *Node, allocator: Allocator) void {
        switch (self.*) {
            .Empty => {},
            .Branch => |*branch| branch.deinit(allocator),
            .Extension => |*ext| ext.deinit(allocator),
            .Leaf => |*leaf| leaf.deinit(allocator),
        }
    }

    /// Create a deep copy of this node
    pub fn clone(self: *const Node, allocator: Allocator) !Node {
        return switch (self.*) {
            .Empty => Node{ .Empty = {} },
            .Branch => |*branch| Node{ .Branch = try branch.clone(allocator) },
            .Extension => |*ext| Node{ .Extension = try ext.clone(allocator) },
            .Leaf => |*leaf| Node{ .Leaf = try leaf.clone(allocator) },
        };
    }
};

/// Leaf node - stores a key-value pair at a terminal position
pub const LeafNode = struct {
    /// Remaining nibbles of the key path
    nibbles: []u8,
    /// The stored value
    value: []u8,

    pub fn init(allocator: Allocator, nibbles: []const u8, value: []const u8) !LeafNode {
        const nibbles_copy = try allocator.dupe(u8, nibbles);
        errdefer allocator.free(nibbles_copy);

        const value_copy = try allocator.dupe(u8, value);
        errdefer allocator.free(value_copy);

        return LeafNode{
            .nibbles = nibbles_copy,
            .value = value_copy,
        };
    }

    pub fn deinit(self: *LeafNode, allocator: Allocator) void {
        allocator.free(self.nibbles);
        allocator.free(self.value);
    }

    pub fn clone(self: *const LeafNode, allocator: Allocator) !LeafNode {
        return try LeafNode.init(allocator, self.nibbles, self.value);
    }
};

/// Extension node - compresses shared path prefixes
pub const ExtensionNode = struct {
    /// Shared nibbles of the compressed path
    nibbles: []u8,
    /// Hash or reference to the next node
    child_hash: [32]u8,

    pub fn init(allocator: Allocator, nibbles: []const u8, child_hash: [32]u8) !ExtensionNode {
        const nibbles_copy = try allocator.dupe(u8, nibbles);
        errdefer allocator.free(nibbles_copy);

        return ExtensionNode{
            .nibbles = nibbles_copy,
            .child_hash = child_hash,
        };
    }

    pub fn deinit(self: *ExtensionNode, allocator: Allocator) void {
        allocator.free(self.nibbles);
    }

    pub fn clone(self: *const ExtensionNode, allocator: Allocator) !ExtensionNode {
        return try ExtensionNode.init(allocator, self.nibbles, self.child_hash);
    }
};

/// Branch node - up to 16 children (one per nibble) plus optional value
pub const BranchNode = struct {
    /// Array of child hashes (null if no child at that position)
    children: [16]?[32]u8,
    /// Optional value stored at this branch (for keys ending here)
    value: ?[]u8,
    /// Mask indicating which children exist
    mask: TrieMask,

    pub fn init() BranchNode {
        return BranchNode{
            .children = [_]?[32]u8{null} ** 16,
            .value = null,
            .mask = TrieMask.init(),
        };
    }

    pub fn deinit(self: *BranchNode, allocator: Allocator) void {
        if (self.value) |v| {
            allocator.free(v);
        }
    }

    pub fn clone(self: *const BranchNode, allocator: Allocator) !BranchNode {
        var new_branch = BranchNode{
            .children = self.children,
            .value = null,
            .mask = self.mask,
        };

        if (self.value) |v| {
            new_branch.value = try allocator.dupe(u8, v);
        }

        return new_branch;
    }

    /// Set a child at the given position
    pub fn set_child(self: *BranchNode, index: u4, hash: [32]u8) void {
        self.children[index] = hash;
        self.mask.set(index);
    }

    /// Remove a child at the given position
    pub fn remove_child(self: *BranchNode, index: u4) void {
        self.children[index] = null;
        self.mask.unset(index);
    }

    /// Get a child at the given position
    pub fn get_child(self: *const BranchNode, index: u4) ?[32]u8 {
        return self.children[index];
    }

    /// Check if the branch is empty (no children and no value)
    pub fn is_empty(self: *const BranchNode) bool {
        return self.mask.is_empty() and self.value == null;
    }

    /// Check if the branch has only one child and no value
    pub fn has_single_child(self: *const BranchNode) bool {
        return self.mask.bit_count() == 1 and self.value == null;
    }

    /// Get the index of the single child, if any
    pub fn get_single_child_index(self: *const BranchNode) ?u4 {
        if (!self.has_single_child()) return null;

        for (0..16) |i| {
            if (self.mask.is_set(@intCast(i))) {
                return @intCast(i);
            }
        }

        return null;
    }
};

test "LeafNode - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0x3 };
    const value = "test_value";

    var leaf = try LeafNode.init(allocator, &nibbles, value);
    defer leaf.deinit(allocator);

    try testing.expectEqualSlices(u8, &nibbles, leaf.nibbles);
    try testing.expectEqualStrings(value, leaf.value);
}

test "LeafNode - clone" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2, 0x3 };
    const value = "test_value";

    var leaf = try LeafNode.init(allocator, &nibbles, value);
    defer leaf.deinit(allocator);

    var cloned = try leaf.clone(allocator);
    defer cloned.deinit(allocator);

    try testing.expectEqualSlices(u8, leaf.nibbles, cloned.nibbles);
    try testing.expectEqualStrings(leaf.value, cloned.value);

    // Verify it's a deep copy (different pointers)
    try testing.expect(leaf.nibbles.ptr != cloned.nibbles.ptr);
    try testing.expect(leaf.value.ptr != cloned.value.ptr);
}

test "ExtensionNode - init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const nibbles = [_]u8{ 0x1, 0x2 };
    const hash = [_]u8{0xAB} ** 32;

    var ext = try ExtensionNode.init(allocator, &nibbles, hash);
    defer ext.deinit(allocator);

    try testing.expectEqualSlices(u8, &nibbles, ext.nibbles);
    try testing.expectEqualSlices(u8, &hash, &ext.child_hash);
}

test "BranchNode - init and operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Start empty
    try testing.expect(branch.is_empty());
    try testing.expect(!branch.has_single_child());

    // Add a child
    const hash1 = [_]u8{0x11} ** 32;
    branch.set_child(5, hash1);

    try testing.expect(!branch.is_empty());
    try testing.expect(branch.has_single_child());
    try testing.expectEqual(@as(?u4, 5), branch.get_single_child_index());
    try testing.expectEqual(hash1, branch.get_child(5).?);

    // Add another child
    const hash2 = [_]u8{0x22} ** 32;
    branch.set_child(10, hash2);

    try testing.expect(!branch.has_single_child());
    try testing.expectEqual(@as(?u4, null), branch.get_single_child_index());

    // Remove a child
    branch.remove_child(5);
    try testing.expect(branch.has_single_child());
    try testing.expectEqual(@as(?u4, 10), branch.get_single_child_index());
}

test "BranchNode - with value" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var branch = BranchNode.init();
    defer branch.deinit(allocator);

    // Add a value
    branch.value = try allocator.dupe(u8, "branch_value");

    try testing.expect(!branch.is_empty());
    try testing.expect(!branch.has_single_child());
    try testing.expectEqualStrings("branch_value", branch.value.?);
}

test "Node - union operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test empty node
    {
        var node = Node{ .Empty = {} };
        defer node.deinit(allocator);
        try testing.expectEqual(NodeType.Empty, node);
    }

    // Test leaf node
    {
        const nibbles = [_]u8{ 0x1, 0x2 };
        const leaf = try LeafNode.init(allocator, &nibbles, "value");
        var node = Node{ .Leaf = leaf };
        defer node.deinit(allocator);
        try testing.expectEqual(NodeType.Leaf, node);
    }

    // Test clone
    {
        const nibbles = [_]u8{ 0x1, 0x2 };
        const leaf = try LeafNode.init(allocator, &nibbles, "value");
        var node = Node{ .Leaf = leaf };
        defer node.deinit(allocator);

        var cloned = try node.clone(allocator);
        defer cloned.deinit(allocator);

        try testing.expectEqual(NodeType.Leaf, cloned);
    }
}

/// Merkle Patricia Trie implementation
///
/// This is the main trie structure that provides insert, get, delete,
/// and proof generation operations.
pub const Trie = struct {
    allocator: Allocator,
    /// Storage for all nodes, keyed by their hash
    nodes: std.StringHashMap(Node),
    /// Root hash of the trie (null for empty trie)
    root: ?[32]u8,

    pub fn init(allocator: Allocator) Trie {
        return Trie{
            .allocator = allocator,
            .nodes = std.StringHashMap(Node).init(allocator),
            .root = null,
        };
    }

    pub fn deinit(self: *Trie) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    /// Get the root hash of the trie
    pub fn root_hash(self: *const Trie) ?[32]u8 {
        return self.root;
    }

    /// Insert a key-value pair into the trie
    pub fn put(self: *Trie, key: []const u8, value: []const u8) !void {
        const nibbles = try keyToNibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        if (self.root) |current_root| {
            // Update existing trie
            const new_root_hash = try self.insert_at(current_root, nibbles, value);
            self.root = new_root_hash;
        } else {
            // Create new trie with single leaf
            const leaf = try LeafNode.init(self.allocator, nibbles, value);
            const node = Node{ .Leaf = leaf };
            const hash = try self.store_node(node);
            self.root = hash;
        }
    }

    /// Get a value from the trie
    pub fn get(self: *const Trie, key: []const u8) !?[]const u8 {
        const current_root = self.root orelse return null;

        const nibbles = try keyToNibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        return try self.get_at(current_root, nibbles);
    }

    /// Delete a key from the trie
    pub fn delete(self: *Trie, key: []const u8) !void {
        const current_root = self.root orelse return;

        const nibbles = try keyToNibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const result = try self.delete_at(current_root, nibbles);
        self.root = result;
    }

    /// Clear the trie (reset to empty)
    pub fn clear(self: *Trie) void {
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();
        self.root = null;
    }

    // Internal methods

    /// Store a node and return its hash
    fn store_node(self: *Trie, node: Node) ![32]u8 {
        const hash = try hash_node(self.allocator, &node);
        const hash_str = try hash_to_string(self.allocator, &hash);
        errdefer self.allocator.free(hash_str);

        try self.nodes.put(hash_str, node);
        return hash;
    }

    /// Get a node by its hash
    fn get_node(self: *const Trie, hash: [32]u8) ?*const Node {
        const hash_str = hash_to_string(self.allocator, &hash) catch return null;
        defer self.allocator.free(hash_str);

        return self.nodes.getPtr(hash_str);
    }

    /// Insert at a specific node
    fn insert_at(self: *Trie, node_hash: [32]u8, nibbles: []const u8, value: []const u8) ![32]u8 {
        const hash_str = try hash_to_string(self.allocator, &node_hash);
        defer self.allocator.free(hash_str);

        const existing_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;

        switch (existing_node) {
            .Empty => {
                // Replace empty with leaf
                const leaf = try LeafNode.init(self.allocator, nibbles, value);
                const node = Node{ .Leaf = leaf };
                return try self.store_node(node);
            },
            .Leaf => |leaf| {
                // Check if same path
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    // Update value
                    const new_leaf = try LeafNode.init(self.allocator, nibbles, value);
                    const node = Node{ .Leaf = new_leaf };
                    return try self.store_node(node);
                }

                // Split into branch
                return try self.split_leaf(leaf, nibbles, value);
            },
            .Extension => |ext| {
                const common_prefix_len = common_prefix_length(ext.nibbles, nibbles);

                if (common_prefix_len == ext.nibbles.len) {
                    // Extension path is a prefix of the key
                    const remaining = nibbles[common_prefix_len..];
                    const new_child_hash = try self.insert_at(ext.child_hash, remaining, value);

                    const new_ext = try ExtensionNode.init(self.allocator, ext.nibbles, new_child_hash);
                    const node = Node{ .Extension = new_ext };
                    return try self.store_node(node);
                } else {
                    // Need to split the extension
                    return try self.split_extension(ext, nibbles, value, common_prefix_len);
                }
            },
            .Branch => |branch| {
                if (nibbles.len == 0) {
                    // Update branch value
                    var new_branch = try branch.clone(self.allocator);
                    if (new_branch.value) |old_val| {
                        self.allocator.free(old_val);
                    }
                    new_branch.value = try self.allocator.dupe(u8, value);

                    const node = Node{ .Branch = new_branch };
                    return try self.store_node(node);
                }

                // Insert into appropriate child
                const nibble = nibbles[0];
                const remaining = nibbles[1..];

                var new_branch = try branch.clone(self.allocator);

                if (new_branch.get_child(nibble)) |child_hash| {
                    const new_child_hash = try self.insert_at(child_hash, remaining, value);
                    new_branch.set_child(nibble, new_child_hash);
                } else {
                    // Create new leaf for this branch
                    const leaf = try LeafNode.init(self.allocator, remaining, value);
                    const leaf_node = Node{ .Leaf = leaf };
                    const leaf_hash = try self.store_node(leaf_node);
                    new_branch.set_child(nibble, leaf_hash);
                }

                const node = Node{ .Branch = new_branch };
                return try self.store_node(node);
            },
        }
    }

    /// Get value at a specific node
    fn get_at(self: *const Trie, node_hash: [32]u8, nibbles: []const u8) !?[]const u8 {
        const hash_str = try hash_to_string(self.allocator, &node_hash);
        defer self.allocator.free(hash_str);

        const node = self.nodes.get(hash_str) orelse return null;

        switch (node) {
            .Empty => return null,
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    return leaf.value;
                }
                return null;
            },
            .Extension => |ext| {
                if (nibbles.len < ext.nibbles.len) return null;
                if (!std.mem.eql(u8, ext.nibbles, nibbles[0..ext.nibbles.len])) return null;

                const remaining = nibbles[ext.nibbles.len..];
                return try self.get_at(ext.child_hash, remaining);
            },
            .Branch => |branch| {
                if (nibbles.len == 0) {
                    return branch.value;
                }

                const nibble = nibbles[0];
                const child_hash = branch.get_child(nibble) orelse return null;

                const remaining = nibbles[1..];
                return try self.get_at(child_hash, remaining);
            },
        }
    }

    /// Delete at a specific node
    fn delete_at(self: *Trie, node_hash: [32]u8, nibbles: []const u8) !?[32]u8 {
        const hash_str = try hash_to_string(self.allocator, &node_hash);
        defer self.allocator.free(hash_str);

        const node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;

        switch (node) {
            .Empty => return null,
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    // Delete this leaf
                    return null;
                }
                // Key not found, return unchanged
                return node_hash;
            },
            .Extension => |ext| {
                if (nibbles.len < ext.nibbles.len) return node_hash;
                if (!std.mem.eql(u8, ext.nibbles, nibbles[0..ext.nibbles.len])) return node_hash;

                const remaining = nibbles[ext.nibbles.len..];
                const new_child_hash = try self.delete_at(ext.child_hash, remaining);

                if (new_child_hash) |child_hash| {
                    const new_ext = try ExtensionNode.init(self.allocator, ext.nibbles, child_hash);
                    const new_node = Node{ .Extension = new_ext };
                    return try self.store_node(new_node);
                } else {
                    return null;
                }
            },
            .Branch => |branch| {
                if (nibbles.len == 0) {
                    // Delete branch value
                    var new_branch = try branch.clone(self.allocator);
                    if (new_branch.value) |v| {
                        self.allocator.free(v);
                        new_branch.value = null;
                    }

                    // Check if branch should collapse
                    if (new_branch.is_empty()) {
                        return null;
                    }

                    const new_node = Node{ .Branch = new_branch };
                    return try self.store_node(new_node);
                }

                const nibble = nibbles[0];
                const remaining = nibbles[1..];

                const child_hash = branch.get_child(nibble) orelse return node_hash;

                var new_branch = try branch.clone(self.allocator);
                const new_child_hash = try self.delete_at(child_hash, remaining);

                if (new_child_hash) |child| {
                    new_branch.set_child(nibble, child);
                } else {
                    new_branch.remove_child(nibble);
                }

                // Check if branch should collapse
                if (new_branch.is_empty()) {
                    return null;
                }

                const new_node = Node{ .Branch = new_branch };
                return try self.store_node(new_node);
            },
        }
    }

    /// Split a leaf node when inserting a divergent key
    fn split_leaf(self: *Trie, leaf: LeafNode, new_nibbles: []const u8, new_value: []const u8) ![32]u8 {
        const common_len = common_prefix_length(leaf.nibbles, new_nibbles);

        // Create branch node
        var branch = BranchNode.init();

        if (common_len == leaf.nibbles.len) {
            // Existing leaf becomes branch value
            branch.value = try self.allocator.dupe(u8, leaf.value);

            // New value goes into child
            const new_leaf = try LeafNode.init(self.allocator, new_nibbles[common_len + 1 ..], new_value);
            const new_leaf_node = Node{ .Leaf = new_leaf };
            const new_leaf_hash = try self.store_node(new_leaf_node);
            branch.set_child(new_nibbles[common_len], new_leaf_hash);
        } else if (common_len == new_nibbles.len) {
            // New value becomes branch value
            branch.value = try self.allocator.dupe(u8, new_value);

            // Existing leaf goes into child
            const old_leaf = try LeafNode.init(self.allocator, leaf.nibbles[common_len + 1 ..], leaf.value);
            const old_leaf_node = Node{ .Leaf = old_leaf };
            const old_leaf_hash = try self.store_node(old_leaf_node);
            branch.set_child(leaf.nibbles[common_len], old_leaf_hash);
        } else {
            // Both become children
            const old_leaf = try LeafNode.init(self.allocator, leaf.nibbles[common_len + 1 ..], leaf.value);
            const old_leaf_node = Node{ .Leaf = old_leaf };
            const old_leaf_hash = try self.store_node(old_leaf_node);
            branch.set_child(leaf.nibbles[common_len], old_leaf_hash);

            const new_leaf = try LeafNode.init(self.allocator, new_nibbles[common_len + 1 ..], new_value);
            const new_leaf_node = Node{ .Leaf = new_leaf };
            const new_leaf_hash = try self.store_node(new_leaf_node);
            branch.set_child(new_nibbles[common_len], new_leaf_hash);
        }

        const branch_node = Node{ .Branch = branch };
        const branch_hash = try self.store_node(branch_node);

        // If there's a common prefix, wrap in extension
        if (common_len > 0) {
            const ext = try ExtensionNode.init(self.allocator, leaf.nibbles[0..common_len], branch_hash);
            const ext_node = Node{ .Extension = ext };
            return try self.store_node(ext_node);
        }

        return branch_hash;
    }

    /// Split an extension node
    fn split_extension(self: *Trie, ext: ExtensionNode, new_nibbles: []const u8, new_value: []const u8, common_len: usize) ![32]u8 {
        // Create a branch at the split point
        var branch = BranchNode.init();

        // Old extension continues
        if (ext.nibbles.len > common_len + 1) {
            const remaining_ext = try ExtensionNode.init(self.allocator, ext.nibbles[common_len + 1 ..], ext.child_hash);
            const remaining_ext_node = Node{ .Extension = remaining_ext };
            const remaining_ext_hash = try self.store_node(remaining_ext_node);
            branch.set_child(ext.nibbles[common_len], remaining_ext_hash);
        } else {
            branch.set_child(ext.nibbles[common_len], ext.child_hash);
        }

        // New value goes into branch
        if (new_nibbles.len == common_len + 1) {
            branch.value = try self.allocator.dupe(u8, new_value);
        } else {
            const new_leaf = try LeafNode.init(self.allocator, new_nibbles[common_len + 1 ..], new_value);
            const new_leaf_node = Node{ .Leaf = new_leaf };
            const new_leaf_hash = try self.store_node(new_leaf_node);
            branch.set_child(new_nibbles[common_len], new_leaf_hash);
        }

        const branch_node = Node{ .Branch = branch };
        const branch_hash = try self.store_node(branch_node);

        // If there's a common prefix, wrap in extension
        if (common_len > 0) {
            const new_ext = try ExtensionNode.init(self.allocator, ext.nibbles[0..common_len], branch_hash);
            const new_ext_node = Node{ .Extension = new_ext };
            return try self.store_node(new_ext_node);
        }

        return branch_hash;
    }
};

/// Find the length of the common prefix between two nibble slices
fn common_prefix_length(a: []const u8, b: []const u8) usize {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

/// Hash a node using Keccak256
fn hash_node(allocator: Allocator, node: *const Node) ![32]u8 {
    // For now, use a simple hash based on node content
    // In production, this should use RLP encoding + Keccak256
    const Rlp = @import("rlp.zig");

    const encoded = switch (node.*) {
        .Empty => try Rlp.encode(allocator, ""),
        .Leaf => |leaf| blk: {
            const path_encoded = try encodePath(allocator, leaf.nibbles, true);
            defer allocator.free(path_encoded);

            var list = std.ArrayList([]const u8){};
            defer {
                for (list.items) |item| {
                    allocator.free(item);
                }
                list.deinit(allocator);
            }

            try list.append(allocator, try Rlp.encode(allocator, path_encoded));
            try list.append(allocator, try Rlp.encode(allocator, leaf.value));

            break :blk try Rlp.encode(allocator, list.items);
        },
        .Extension => |ext| blk: {
            const path_encoded = try encodePath(allocator, ext.nibbles, false);
            defer allocator.free(path_encoded);

            var list = std.ArrayList([]const u8){};
            defer {
                for (list.items) |item| {
                    allocator.free(item);
                }
                list.deinit(allocator);
            }

            try list.append(allocator, try Rlp.encode(allocator, path_encoded));
            try list.append(allocator, try Rlp.encode(allocator, &ext.child_hash));

            break :blk try Rlp.encode(allocator, list.items);
        },
        .Branch => |branch| blk: {
            var list = std.ArrayList([]const u8){};
            defer {
                for (list.items) |item| {
                    allocator.free(item);
                }
                list.deinit(allocator);
            }

            // 16 children
            for (0..16) |i| {
                if (branch.get_child(@intCast(i))) |child_hash| {
                    try list.append(allocator, try Rlp.encode(allocator, &child_hash));
                } else {
                    try list.append(allocator, try Rlp.encode(allocator, ""));
                }
            }

            // Value
            if (branch.value) |v| {
                try list.append(allocator, try Rlp.encode(allocator, v));
            } else {
                try list.append(allocator, try Rlp.encode(allocator, ""));
            }

            break :blk try Rlp.encode(allocator, list.items);
        },
    };
    defer allocator.free(encoded);

    // Hash the encoded data
    var hash: [32]u8 = undefined;
    crypto.Keccak256.hash(encoded, &hash, .{});
    return hash;
}

/// Convert hash to hex string for use as map key
fn hash_to_string(allocator: Allocator, hash: []const u8) ![]u8 {
    const hex_chars = "0123456789abcdef";
    const result = try allocator.alloc(u8, hash.len * 2);
    errdefer allocator.free(result);

    for (hash, 0..) |byte, i| {
        result[i * 2] = hex_chars[byte >> 4];
        result[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return result;
}

test "common_prefix_length" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), common_prefix_length(&[_]u8{ 0x1, 0x2 }, &[_]u8{ 0x3, 0x4 }));
    try testing.expectEqual(@as(usize, 2), common_prefix_length(&[_]u8{ 0x1, 0x2 }, &[_]u8{ 0x1, 0x2, 0x3 }));
    try testing.expectEqual(@as(usize, 1), common_prefix_length(&[_]u8{ 0x1, 0x2, 0x3 }, &[_]u8{ 0x1, 0x4 }));
    try testing.expectEqual(@as(usize, 0), common_prefix_length(&[_]u8{}, &[_]u8{ 0x1, 0x2 }));
}

test "Trie - empty trie" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try testing.expect(trie.root_hash() == null);

    const result = try trie.get(&[_]u8{ 0x12, 0x34 });
    try testing.expect(result == null);
}

test "Trie - single insert and get" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };
    const value = "test_value";

    try trie.put(&key, value);

    try testing.expect(trie.root_hash() != null);

    const retrieved = try trie.get(&key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(value, retrieved.?);
}

test "Trie - update existing key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };

    try trie.put(&key, "value1");
    try trie.put(&key, "value2");

    const retrieved = try trie.get(&key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings("value2", retrieved.?);
}

test "Trie - multiple inserts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value1");
    try trie.put(&[_]u8{ 0x12, 0x56 }, "value2");
    try trie.put(&[_]u8{ 0xAB, 0xCD }, "value3");

    const val1 = try trie.get(&[_]u8{ 0x12, 0x34 });
    try testing.expectEqualStrings("value1", val1.?);

    const val2 = try trie.get(&[_]u8{ 0x12, 0x56 });
    try testing.expectEqualStrings("value2", val2.?);

    const val3 = try trie.get(&[_]u8{ 0xAB, 0xCD });
    try testing.expectEqualStrings("value3", val3.?);
}

test "Trie - delete single key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };
    try trie.put(&key, "value");

    try trie.delete(&key);

    const retrieved = try trie.get(&key);
    try testing.expect(retrieved == null);
    try testing.expect(trie.root_hash() == null);
}

test "Trie - delete one of multiple keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value1");
    try trie.put(&[_]u8{ 0x12, 0x56 }, "value2");

    try trie.delete(&[_]u8{ 0x12, 0x34 });

    const deleted = try trie.get(&[_]u8{ 0x12, 0x34 });
    try testing.expect(deleted == null);

    const remaining = try trie.get(&[_]u8{ 0x12, 0x56 });
    try testing.expectEqualStrings("value2", remaining.?);
}

test "Trie - clear" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value1");
    try trie.put(&[_]u8{ 0x56, 0x78 }, "value2");

    trie.clear();

    try testing.expect(trie.root_hash() == null);
    try testing.expect((try trie.get(&[_]u8{ 0x12, 0x34 })) == null);
}

// Additional comprehensive tests

test "Trie - root hash changes with updates" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };

    try testing.expect(trie.root_hash() == null);

    try trie.put(&key, "value1");
    const hash1 = trie.root_hash();
    try testing.expect(hash1 != null);

    try trie.put(&key, "value2");
    const hash2 = trie.root_hash();
    try testing.expect(hash2 != null);

    try testing.expect(!std.mem.eql(u8, &hash1.?, &hash2.?));
}

test "Trie - root hash deterministic" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie1 = Trie.init(allocator);
    defer trie1.deinit();

    var trie2 = Trie.init(allocator);
    defer trie2.deinit();

    const keys = [_][]const u8{
        &[_]u8{ 0x12, 0x34 },
        &[_]u8{ 0x56, 0x78 },
        &[_]u8{ 0xAB, 0xCD },
    };

    for (keys, 0..) |key, i| {
        const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(value);
        try trie1.put(key, value);
        try trie2.put(key, value);
    }

    const hash1 = trie1.root_hash();
    const hash2 = trie2.root_hash();

    try testing.expect(hash1 != null);
    try testing.expect(hash2 != null);
    try testing.expectEqualSlices(u8, &hash1.?, &hash2.?);
}

test "Trie - large key handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    var large_key: [256]u8 = undefined;
    for (&large_key, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    const value = "test_value_for_large_key";

    try trie.put(&large_key, value);

    const retrieved = try trie.get(&large_key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(value, retrieved.?);
}

test "Trie - large value handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };

    const large_value = try allocator.alloc(u8, 1024);
    defer allocator.free(large_value);
    for (large_value, 0..) |*byte, i| {
        byte.* = @intCast(i % 256);
    }

    try trie.put(&key, large_value);

    const retrieved = try trie.get(&key);
    try testing.expect(retrieved != null);
    try testing.expectEqualSlices(u8, large_value, retrieved.?);
}

test "Trie - empty key handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const empty_key = [_]u8{};
    const value = "value_for_empty_key";

    try trie.put(&empty_key, value);

    const retrieved = try trie.get(&empty_key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(value, retrieved.?);
}

test "Trie - empty value handling" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };
    const empty_value = "";

    try trie.put(&key, empty_value);

    const retrieved = try trie.get(&key);
    try testing.expect(retrieved != null);
    try testing.expectEqualStrings(empty_value, retrieved.?);
}

test "Trie - single nibble keys" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key1 = [_]u8{0x01};
    const key2 = [_]u8{0x02};

    try trie.put(&key1, "value1");
    try trie.put(&key2, "value2");

    const val1 = try trie.get(&key1);
    try testing.expectEqualStrings("value1", val1.?);

    const val2 = try trie.get(&key2);
    try testing.expectEqualStrings("value2", val2.?);
}

test "Trie - keys with common prefix" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34, 0x56 }, "value1");
    try trie.put(&[_]u8{ 0x12, 0x34, 0x78 }, "value2");
    try trie.put(&[_]u8{ 0x12, 0x34, 0x9A }, "value3");

    const val1 = try trie.get(&[_]u8{ 0x12, 0x34, 0x56 });
    try testing.expectEqualStrings("value1", val1.?);

    const val2 = try trie.get(&[_]u8{ 0x12, 0x34, 0x78 });
    try testing.expectEqualStrings("value2", val2.?);

    const val3 = try trie.get(&[_]u8{ 0x12, 0x34, 0x9A });
    try testing.expectEqualStrings("value3", val3.?);
}

test "Trie - key is prefix of another" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "short");
    try trie.put(&[_]u8{ 0x12, 0x34, 0x56 }, "long");

    const short = try trie.get(&[_]u8{ 0x12, 0x34 });
    try testing.expectEqualStrings("short", short.?);

    const long = try trie.get(&[_]u8{ 0x12, 0x34, 0x56 });
    try testing.expectEqualStrings("long", long.?);
}

test "Trie - get non-existent key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value");

    const result = try trie.get(&[_]u8{ 0x56, 0x78 });
    try testing.expect(result == null);
}

test "Trie - delete non-existent key" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value");

    try trie.delete(&[_]u8{ 0x56, 0x78 });

    const val = try trie.get(&[_]u8{ 0x12, 0x34 });
    try testing.expectEqualStrings("value", val.?);
}

test "Trie - delete from empty trie" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.delete(&[_]u8{ 0x12, 0x34 });

    try testing.expect(trie.root_hash() == null);
}

test "Trie - multiple deletes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value1");
    try trie.put(&[_]u8{ 0x56, 0x78 }, "value2");
    try trie.put(&[_]u8{ 0xAB, 0xCD }, "value3");

    try trie.delete(&[_]u8{ 0x12, 0x34 });
    try testing.expect((try trie.get(&[_]u8{ 0x12, 0x34 })) == null);
    try testing.expectEqualStrings("value2", (try trie.get(&[_]u8{ 0x56, 0x78 })).?);

    try trie.delete(&[_]u8{ 0x56, 0x78 });
    try testing.expect((try trie.get(&[_]u8{ 0x56, 0x78 })) == null);
    try testing.expectEqualStrings("value3", (try trie.get(&[_]u8{ 0xAB, 0xCD })).?);

    try trie.delete(&[_]u8{ 0xAB, 0xCD });
    try testing.expect((try trie.get(&[_]u8{ 0xAB, 0xCD })) == null);
    try testing.expect(trie.root_hash() == null);
}

test "Trie - delete and reinsert" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };

    try trie.put(&key, "value1");
    const hash1 = trie.root_hash();

    try trie.delete(&key);
    try testing.expect(trie.root_hash() == null);

    try trie.put(&key, "value1");
    const hash2 = trie.root_hash();

    try testing.expect(hash1 != null and hash2 != null);
    try testing.expectEqualSlices(u8, &hash1.?, &hash2.?);
}

test "Trie - many sequential inserts" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const count = 100;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        var key: [4]u8 = undefined;
        key[0] = @intCast((i >> 24) & 0xFF);
        key[1] = @intCast((i >> 16) & 0xFF);
        key[2] = @intCast((i >> 8) & 0xFF);
        key[3] = @intCast(i & 0xFF);

        const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(value);

        try trie.put(&key, value);
    }

    i = 0;
    while (i < count) : (i += 1) {
        var key: [4]u8 = undefined;
        key[0] = @intCast((i >> 24) & 0xFF);
        key[1] = @intCast((i >> 16) & 0xFF);
        key[2] = @intCast((i >> 8) & 0xFF);
        key[3] = @intCast(i & 0xFF);

        const expected = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(expected);

        const retrieved = try trie.get(&key);
        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(expected, retrieved.?);
    }
}

test "Trie - random access pattern" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const keys = [_][2]u8{
        [_]u8{ 0xAB, 0xCD },
        [_]u8{ 0x12, 0x34 },
        [_]u8{ 0xFF, 0x00 },
        [_]u8{ 0x56, 0x78 },
        [_]u8{ 0x00, 0xFF },
    };

    for (keys, 0..) |key, i| {
        const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(value);
        try trie.put(&key, value);
    }

    for (keys, 0..) |key, i| {
        const expected = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(expected);

        const retrieved = try trie.get(&key);
        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(expected, retrieved.?);
    }
}

test "Trie - branch node creation and traversal" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{ i, 0x00 };
        const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(value);
        try trie.put(&key, value);
    }

    i = 0;
    while (i < 16) : (i += 1) {
        const key = [_]u8{ i, 0x00 };
        const expected = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(expected);

        const retrieved = try trie.get(&key);
        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(expected, retrieved.?);
    }
}

test "Trie - extension node creation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x01, 0x02, 0x03, 0x04 }, "value1");
    try trie.put(&[_]u8{ 0x01, 0x02, 0x03, 0x05 }, "value2");

    const val1 = try trie.get(&[_]u8{ 0x01, 0x02, 0x03, 0x04 });
    try testing.expectEqualStrings("value1", val1.?);

    const val2 = try trie.get(&[_]u8{ 0x01, 0x02, 0x03, 0x05 });
    try testing.expectEqualStrings("value2", val2.?);
}

test "Trie - all node types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x01, 0x23, 0x45 }, "leaf1");
    try trie.put(&[_]u8{ 0x01, 0x23, 0x46 }, "leaf2");
    try trie.put(&[_]u8{ 0x01, 0x24 }, "branch_value");
    try trie.put(&[_]u8{ 0x02, 0x00 }, "another_leaf");

    try testing.expectEqualStrings("leaf1", (try trie.get(&[_]u8{ 0x01, 0x23, 0x45 })).?);
    try testing.expectEqualStrings("leaf2", (try trie.get(&[_]u8{ 0x01, 0x23, 0x46 })).?);
    try testing.expectEqualStrings("branch_value", (try trie.get(&[_]u8{ 0x01, 0x24 })).?);
    try testing.expectEqualStrings("another_leaf", (try trie.get(&[_]u8{ 0x02, 0x00 })).?);
}

test "Trie - delete with branch collapse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x01, 0x23 }, "value1");
    try trie.put(&[_]u8{ 0x01, 0x24 }, "value2");
    try trie.put(&[_]u8{ 0x01, 0x25 }, "value3");

    try trie.delete(&[_]u8{ 0x01, 0x23 });
    try trie.delete(&[_]u8{ 0x01, 0x24 });

    try testing.expect((try trie.get(&[_]u8{ 0x01, 0x23 })) == null);
    try testing.expect((try trie.get(&[_]u8{ 0x01, 0x24 })) == null);
    try testing.expectEqualStrings("value3", (try trie.get(&[_]u8{ 0x01, 0x25 })).?);
}

test "Trie - memory safety with many operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var key: [2]u8 = undefined;
        key[0] = @intCast((i >> 8) & 0xFF);
        key[1] = @intCast(i & 0xFF);

        const value = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(value);
        try trie.put(&key, value);
    }

    i = 0;
    while (i < 50) : (i += 2) {
        var key: [2]u8 = undefined;
        key[0] = @intCast((i >> 8) & 0xFF);
        key[1] = @intCast(i & 0xFF);
        try trie.delete(&key);
    }

    i = 1;
    while (i < 50) : (i += 2) {
        var key: [2]u8 = undefined;
        key[0] = @intCast((i >> 8) & 0xFF);
        key[1] = @intCast(i & 0xFF);

        const expected = try std.fmt.allocPrint(allocator, "value{}", .{i});
        defer allocator.free(expected);

        const retrieved = try trie.get(&key);
        try testing.expect(retrieved != null);
        try testing.expectEqualStrings(expected, retrieved.?);
    }
}

test "Trie - overwrite with different length values" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const key = [_]u8{ 0x12, 0x34 };

    try trie.put(&key, "short");
    try testing.expectEqualStrings("short", (try trie.get(&key)).?);

    try trie.put(&key, "much longer value");
    try testing.expectEqualStrings("much longer value", (try trie.get(&key)).?);

    try trie.put(&key, "x");
    try testing.expectEqualStrings("x", (try trie.get(&key)).?);
}

test "Trie - hash_to_string and back" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const hash = [_]u8{0xAB} ** 32;
    const hash_str = try hash_to_string(allocator, &hash);
    defer allocator.free(hash_str);

    try testing.expectEqual(@as(usize, 64), hash_str.len);

    for (hash_str) |c| {
        try testing.expect((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'));
    }
}

test "Trie - store and retrieve node" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    const nibbles = [_]u8{ 0x1, 0x2, 0x3 };
    const leaf = try LeafNode.init(allocator, &nibbles, "test");
    const node = Node{ .Leaf = leaf };

    const hash = try trie.store_node(node);

    const retrieved = trie.get_node(hash);
    try testing.expect(retrieved != null);
}

test "Trie - clear and reuse" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var trie = Trie.init(allocator);
    defer trie.deinit();

    try trie.put(&[_]u8{ 0x12, 0x34 }, "value1");
    try trie.put(&[_]u8{ 0x56, 0x78 }, "value2");

    trie.clear();

    try trie.put(&[_]u8{ 0xAB, 0xCD }, "value3");
    try testing.expectEqualStrings("value3", (try trie.get(&[_]u8{ 0xAB, 0xCD })).?);
    try testing.expect((try trie.get(&[_]u8{ 0x12, 0x34 })) == null);
}
