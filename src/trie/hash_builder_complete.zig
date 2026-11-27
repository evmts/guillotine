const std = @import("std");
const Allocator = std.mem.Allocator;
const trie = @import("trie.zig");
const primitives = @import("voltaire");

const TrieNode = trie.TrieNode;
const HashValue = trie.HashValue;
const BranchNode = trie.BranchNode;
const ExtensionNode = trie.ExtensionNode;
const LeafNode = trie.LeafNode;
const TrieError = trie.TrieError;

/// Error types for HashBuilder operations
const HashBuilderError = std.mem.Allocator.Error || TrieError;

/// Iterator for traversing all key-value pairs in the trie
pub const TrieIterator = struct {
    const StackItem = struct {
        node: TrieNode,
        path: []u8, // Nibbles traversed so far
        branch_index: u8, // For branch nodes, which child we're on
    };

    allocator: Allocator,
    builder: *const HashBuilder,
    stack: std.ArrayList(StackItem),
    finished: bool,

    pub fn init(allocator: Allocator, builder: *const HashBuilder) !TrieIterator {
        var stack = std.ArrayList(StackItem).empty;

        // Initialize with root if it exists
        if (builder.root_hash) |root| {
            if (builder.nodes.get(root)) |root_node| {
                const path = try allocator.alloc(u8, 0);
                try stack.append(allocator, StackItem{
                    .node = root_node,
                    .path = path,
                    .branch_index = 0,
                });
            }
        }

        return TrieIterator{
            .allocator = allocator,
            .builder = builder,
            .stack = stack,
            .finished = builder.root_hash == null,
        };
    }

    pub fn deinit(self: *TrieIterator) void {
        // Free all path allocations
        for (self.stack.items) |item| {
            self.allocator.free(item.path);
        }
        self.stack.deinit(self.allocator);
    }

    /// Get the next key-value pair
    /// Returns null when iteration is complete
    /// Caller must free the returned key and value
    pub fn next(self: *TrieIterator) !?struct { key: []u8, value: []u8 } {
        if (self.finished or self.stack.items.len == 0) {
            return null;
        }

        while (self.stack.items.len > 0) {
            var current = &self.stack.items[self.stack.items.len - 1];

            switch (current.node) {
                .Empty => {
                    // Pop empty nodes and continue
                    self.allocator.free(current.path);
                    _ = self.stack.pop();
                },
                .Leaf => |leaf| {
                    // Construct full path
                    const full_path = try self.allocator.alloc(u8, current.path.len + leaf.nibbles.len);
                    @memcpy(full_path[0..current.path.len], current.path);
                    @memcpy(full_path[current.path.len..], leaf.nibbles);

                    // Convert nibbles to key
                    const key = try trie.nibbles_to_key(self.allocator, full_path);
                    self.allocator.free(full_path);

                    // Extract value
                    const value = switch (leaf.value) {
                        .Raw => |data| try self.allocator.dupe(u8, data),
                        .Hash => return TrieError.InvalidNode,
                    };

                    // Pop this leaf
                    self.allocator.free(current.path);
                    _ = self.stack.pop();

                    return .{ .key = key, .value = value };
                },
                .Extension => |extension| {
                    // Construct new path
                    const new_path = try self.allocator.alloc(u8, current.path.len + extension.nibbles.len);
                    @memcpy(new_path[0..current.path.len], current.path);
                    @memcpy(new_path[current.path.len..], extension.nibbles);

                    // Pop current extension
                    self.allocator.free(current.path);
                    _ = self.stack.pop();

                    // Get next node
                    const next_node = switch (extension.next) {
                        .Raw => return TrieError.InvalidNode,
                        .Hash => |hash| self.builder.nodes.get(hash) orelse {
                            self.allocator.free(new_path);
                            return TrieError.NonExistentNode;
                        },
                    };

                    // Push next node with accumulated path
                    try self.stack.append(self.allocator, StackItem{
                        .node = next_node,
                        .path = new_path,
                        .branch_index = 0,
                    });
                },
                .Branch => |branch| {
                    // Check if we should return the branch's own value first
                    if (current.branch_index == 0 and branch.value != null) {
                        // Return branch value
                        const key = try trie.nibbles_to_key(self.allocator, current.path);
                        const value = switch (branch.value.?) {
                            .Raw => |data| try self.allocator.dupe(u8, data),
                            .Hash => return TrieError.InvalidNode,
                        };

                        // Move to first child
                        current.branch_index = 1;
                        return .{ .key = key, .value = value };
                    }

                    // Find next child to explore
                    var found_child = false;
                    while (current.branch_index < 16) : (current.branch_index += 1) {
                        const idx: u4 = @intCast(current.branch_index);
                        if (branch.children_mask.is_set(idx)) {
                            const child = branch.children[current.branch_index].?;

                            // Create new path with this branch index
                            const new_path = try self.allocator.alloc(u8, current.path.len + 1);
                            @memcpy(new_path[0..current.path.len], current.path);
                            new_path[current.path.len] = current.branch_index;

                            // Move to next child for future iterations
                            current.branch_index += 1;

                            // Handle child based on type
                            switch (child) {
                                .Raw => |data| {
                                    // Direct value at this branch
                                    const key = try trie.nibbles_to_key(self.allocator, new_path);
                                    self.allocator.free(new_path);
                                    const value = try self.allocator.dupe(u8, data);
                                    return .{ .key = key, .value = value };
                                },
                                .Hash => |hash| {
                                    // Get the child node
                                    const child_node = self.builder.nodes.get(hash) orelse {
                                        self.allocator.free(new_path);
                                        return TrieError.NonExistentNode;
                                    };

                                    // Push child onto stack
                                    try self.stack.append(self.allocator, StackItem{
                                        .node = child_node,
                                        .path = new_path,
                                        .branch_index = 0,
                                    });

                                    found_child = true;
                                    break;
                                },
                            }
                        }
                    }

                    // If no more children, pop this branch
                    if (!found_child) {
                        self.allocator.free(current.path);
                        _ = self.stack.pop();
                    }
                },
            }
        }

        // Stack is empty, iteration complete
        self.finished = true;
        return null;
    }
};

/// Complete Patricia Merkle Trie implementation with safe memory management
pub const HashBuilder = struct {
    allocator: Allocator,
    // Store nodes by their 32-byte Keccak hash directly (zero hex-string heap allocations).
    nodes: std.AutoHashMap([32]u8, TrieNode),
    // The root node's hash (if built)
    root_hash: ?[32]u8,

    pub fn init(allocator: Allocator) HashBuilder {
        return HashBuilder{
            .allocator = allocator,
            .nodes = std.AutoHashMap([32]u8, TrieNode).init(allocator),
            .root_hash = null,
        };
    }

    pub fn deinit(self: *HashBuilder) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node_ptr| {
            var node = node_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    pub fn reset(self: *HashBuilder) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node_ptr| {
            var node = node_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();

        self.root_hash = null;
    }

    /// Store a node and return its hash
    fn store_node(self: *HashBuilder, node: TrieNode) HashBuilderError![32]u8 {
        const hash = try node.hash(self.allocator);

        if (self.nodes.contains(hash)) {
            var duplicate = node;
            duplicate.deinit(self.allocator);
            return hash;
        }

        try self.nodes.put(hash, node);
        return hash;
    }

    /// Add a key-value pair to the trie
    pub fn insert(self: *HashBuilder, key: []const u8, value: []const u8) HashBuilderError!void {
        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const root_node = if (self.root_hash) |hash|
            self.nodes.get(hash) orelse return TrieError.NonExistentNode
        else
            TrieNode{ .Empty = {} };

        const new_root = try self.insert_node(root_node, nibbles, value);
        self.root_hash = try self.store_node(new_root);
    }

    /// Get a value from the trie
    pub fn get(self: *HashBuilder, key: []const u8) HashBuilderError!?[]const u8 {
        const root = self.root_hash orelse return null;

        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const root_node = self.nodes.get(root) orelse return TrieError.NonExistentNode;
        return try self.get_value(root_node, nibbles);
    }

    /// Delete a key-value pair from the trie
    pub fn delete(self: *HashBuilder, key: []const u8) HashBuilderError!void {
        const root = self.root_hash orelse return;

        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const root_node = self.nodes.get(root) orelse return TrieError.NonExistentNode;

        const result = try self.delete_node(root_node, nibbles);
        if (result) |new_root| {
            self.root_hash = try self.store_node(new_root);
        } else {
            self.root_hash = null;
        }
    }

    /// Get the root hash
    pub fn get_root_hash(self: *const HashBuilder) ?[32]u8 {
        return self.root_hash;
    }

    /// Create an iterator for traversing all key-value pairs
    /// Returns keys in lexicographic order (depth-first traversal)
    pub fn iterator(self: *const HashBuilder, allocator: Allocator) !TrieIterator {
        return try TrieIterator.init(allocator, self);
    }

    const TraversalFrame = union(enum) {
        extension: []const u8,
        branch: struct {
            node: BranchNode,
            key: u8,
        },

        fn deinit(self: *TraversalFrame, allocator: Allocator) void {
            switch (self.*) {
                .extension => {},
                .branch => |*b| b.node.deinit(allocator),
            }
        }
    };

    fn deinitFrames(self: *HashBuilder, frames: *std.ArrayList(TraversalFrame)) void {
        for (frames.items) |*frame| frame.deinit(self.allocator);
        frames.deinit(self.allocator);
    }

    /// Iteratively insert a key-value pair (descent + bottom-up rebuild, zero recursion).
    fn insert_node(self: *HashBuilder, start_node: TrieNode, start_nibbles: []const u8, value: []const u8) HashBuilderError!TrieNode {
        var frames = std.ArrayList(TraversalFrame).empty;
        errdefer self.deinitFrames(&frames);

        var cur_node = start_node;
        var remaining = start_nibbles;
        const max_steps: usize = start_nibbles.len + 2;
        var steps: usize = 0;

        var rebuilt: TrieNode = undefined;
        var have_rebuilt = false;

        while (steps < max_steps) : (steps += 1) {
            switch (cur_node) {
                .Empty => {
                    const path_copy = try self.allocator.dupe(u8, remaining);
                    const value_copy = try self.allocator.dupe(u8, value);
                    const leaf = try LeafNode.init(self.allocator, path_copy, HashValue{ .Raw = value_copy });
                    rebuilt = TrieNode{ .Leaf = leaf };
                    have_rebuilt = true;
                    break;
                },
                .Leaf => |leaf| {
                    if (std.mem.eql(u8, leaf.nibbles, remaining)) {
                        const path_copy = try self.allocator.dupe(u8, remaining);
                        const value_copy = try self.allocator.dupe(u8, value);
                        const new_leaf = try LeafNode.init(self.allocator, path_copy, HashValue{ .Raw = value_copy });
                        rebuilt = TrieNode{ .Leaf = new_leaf };
                    } else {
                        rebuilt = try self.split_leaf(leaf, remaining, value);
                    }
                    have_rebuilt = true;
                    break;
                },
                .Extension => |extension| {
                    const common_len = common_prefix_length(extension.nibbles, remaining);
                    if (common_len == extension.nibbles.len) {
                        const next_node = switch (extension.next) {
                            .Raw => return TrieError.InvalidNode,
                            .Hash => |hash| self.nodes.get(hash) orelse return TrieError.NonExistentNode,
                        };
                        try frames.append(self.allocator, .{ .extension = extension.nibbles });
                        cur_node = next_node;
                        remaining = remaining[common_len..];
                    } else {
                        rebuilt = try self.split_extension(extension, remaining, value, common_len);
                        have_rebuilt = true;
                        break;
                    }
                },
                .Branch => |branch| {
                    var new_branch = try branch.dupe(self.allocator);
                    errdefer new_branch.deinit(self.allocator);

                    if (remaining.len == 0) {
                        if (new_branch.value) |*old_value| old_value.deinit(self.allocator);
                        new_branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                        rebuilt = TrieNode{ .Branch = new_branch };
                        have_rebuilt = true;
                        break;
                    }

                    const key = remaining[0];
                    const tail = remaining[1..];
                    if (new_branch.children_mask.is_set(@intCast(key))) {
                        const child = new_branch.children[key].?;
                        if (child == .Hash) {
                            const next_node = self.nodes.get(child.Hash) orelse return TrieError.NonExistentNode;
                            try frames.append(self.allocator, .{ .branch = .{ .node = new_branch, .key = key } });
                            cur_node = next_node;
                            remaining = tail;
                            continue;
                        }
                        rebuilt = try self.insert_branch_raw_child(&new_branch, key, child.Raw, tail, value);
                        have_rebuilt = true;
                        break;
                    }

                    if (tail.len == 0) {
                        new_branch.children[key] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                    } else {
                        const leaf = try LeafNode.init(
                            self.allocator,
                            try self.allocator.dupe(u8, tail),
                            HashValue{ .Raw = try self.allocator.dupe(u8, value) },
                        );
                        const leaf_hash = try self.store_node(TrieNode{ .Leaf = leaf });
                        new_branch.children[key] = HashValue{ .Hash = leaf_hash };
                    }
                    new_branch.children_mask.set(@intCast(key));
                    rebuilt = TrieNode{ .Branch = new_branch };
                    have_rebuilt = true;
                    break;
                },
            }
        }
        if (!have_rebuilt) return TrieError.InvalidNode;

        while (frames.pop()) |frame| {
            errdefer rebuilt.deinit(self.allocator);
            switch (frame) {
                .extension => |ext_nibbles| {
                    const updated_hash = try self.store_node(rebuilt);
                    const path_copy = try self.allocator.dupe(u8, ext_nibbles);
                    const new_ext = try ExtensionNode.init(self.allocator, path_copy, HashValue{ .Hash = updated_hash });
                    rebuilt = TrieNode{ .Extension = new_ext };
                },
                .branch => |b| {
                    var branch_node = b.node;
                    errdefer branch_node.deinit(self.allocator);
                    const updated_hash = try self.store_node(rebuilt);
                    branch_node.children[b.key].?.deinit(self.allocator);
                    branch_node.children[b.key] = HashValue{ .Hash = updated_hash };
                    rebuilt = TrieNode{ .Branch = branch_node };
                },
            }
        }
        frames.deinit(self.allocator);
        return rebuilt;
    }

    fn insert_branch_raw_child(
        self: *HashBuilder,
        new_branch: *BranchNode,
        key: u8,
        existing_data: []const u8,
        remaining_path: []const u8,
        value: []const u8,
    ) HashBuilderError!TrieNode {
        if (remaining_path.len == 0) {
            const replacement = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            new_branch.children[key].?.deinit(self.allocator);
            new_branch.children[key] = replacement;
            return TrieNode{ .Branch = new_branch.* };
        }

        var sub_branch = BranchNode.init();
        errdefer sub_branch.deinit(self.allocator);
        if (remaining_path.len == 1) {
            sub_branch.children[remaining_path[0]] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            sub_branch.children_mask.set(@intCast(remaining_path[0]));
        } else {
            const leaf_path = try self.allocator.dupe(u8, remaining_path[1..]);
            const new_leaf = try LeafNode.init(self.allocator, leaf_path, HashValue{ .Raw = try self.allocator.dupe(u8, value) });
            const leaf_hash = try self.store_node(TrieNode{ .Leaf = new_leaf });
            sub_branch.children[remaining_path[0]] = HashValue{ .Hash = leaf_hash };
            sub_branch.children_mask.set(@intCast(remaining_path[0]));
        }
        sub_branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, existing_data) };
        const updated_hash = try self.store_node(TrieNode{ .Branch = sub_branch });
        new_branch.children[key].?.deinit(self.allocator);
        new_branch.children[key] = HashValue{ .Hash = updated_hash };
        return TrieNode{ .Branch = new_branch.* };
    }

    fn split_leaf(self: *HashBuilder, leaf: LeafNode, nibbles: []const u8, value: []const u8) HashBuilderError!TrieNode {
        const common_len = common_prefix_length(leaf.nibbles, nibbles);

        if (common_len == 0) {
            // No common prefix, create branch
            var branch = BranchNode.init();

            // Add existing leaf
            if (leaf.nibbles.len > 0) {
                const existing_key = leaf.nibbles[0];
                if (leaf.nibbles.len == 1) {
                    branch.children[existing_key] = try leaf.value.dupe(self.allocator);
                    branch.children_mask.set(@intCast(existing_key));
                } else {
                    const remaining_path = try self.allocator.dupe(u8, leaf.nibbles[1..]);
                    const new_leaf = try LeafNode.init(self.allocator, remaining_path, try leaf.value.dupe(self.allocator));
                    const new_node = TrieNode{ .Leaf = new_leaf };
                    const hash = try self.store_node(new_node);
                    branch.children[existing_key] = HashValue{ .Hash = hash };
                    branch.children_mask.set(@intCast(existing_key));
                }
            }

            // Add new value
            if (nibbles.len > 0) {
                const new_key = nibbles[0];
                if (nibbles.len == 1) {
                    branch.children[new_key] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                    branch.children_mask.set(@intCast(new_key));
                } else {
                    const remaining_path = try self.allocator.dupe(u8, nibbles[1..]);
                    const new_leaf = try LeafNode.init(self.allocator, remaining_path, HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                    const new_node = TrieNode{ .Leaf = new_leaf };
                    const hash = try self.store_node(new_node);
                    branch.children[new_key] = HashValue{ .Hash = hash };
                    branch.children_mask.set(@intCast(new_key));
                }
            } else {
                branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            }

            return TrieNode{ .Branch = branch };
        } else {
            // Create extension + branch
            var branch = BranchNode.init();

            // Add existing leaf remainder
            if (leaf.nibbles.len > common_len) {
                const existing_key = leaf.nibbles[common_len];
                if (leaf.nibbles.len == common_len + 1) {
                    branch.children[existing_key] = try leaf.value.dupe(self.allocator);
                    branch.children_mask.set(@intCast(existing_key));
                } else {
                    const remaining_path = try self.allocator.dupe(u8, leaf.nibbles[common_len + 1 ..]);
                    const new_leaf = try LeafNode.init(self.allocator, remaining_path, try leaf.value.dupe(self.allocator));
                    const new_node = TrieNode{ .Leaf = new_leaf };
                    const hash = try self.store_node(new_node);
                    branch.children[existing_key] = HashValue{ .Hash = hash };
                    branch.children_mask.set(@intCast(existing_key));
                }
            } else {
                branch.value = try leaf.value.dupe(self.allocator);
            }

            // Add new value remainder
            if (nibbles.len > common_len) {
                const new_key = nibbles[common_len];
                if (nibbles.len == common_len + 1) {
                    branch.children[new_key] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                    branch.children_mask.set(@intCast(new_key));
                } else {
                    const remaining_path = try self.allocator.dupe(u8, nibbles[common_len + 1 ..]);
                    const new_leaf = try LeafNode.init(self.allocator, remaining_path, HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                    const new_node = TrieNode{ .Leaf = new_leaf };
                    const hash = try self.store_node(new_node);
                    branch.children[new_key] = HashValue{ .Hash = hash };
                    branch.children_mask.set(@intCast(new_key));
                }
            } else {
                branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            }

            // Store branch and create extension
            const branch_node = TrieNode{ .Branch = branch };
            const branch_hash = try self.store_node(branch_node);

            const common_prefix = try self.allocator.dupe(u8, nibbles[0..common_len]);
            const extension = try ExtensionNode.init(self.allocator, common_prefix, HashValue{ .Hash = branch_hash });

            return TrieNode{ .Extension = extension };
        }
    }

    fn split_extension(self: *HashBuilder, extension: ExtensionNode, nibbles: []const u8, value: []const u8, common_len: usize) HashBuilderError!TrieNode {
        // Create branch at split point
        var branch = BranchNode.init();

        // Add extension continuation
        const ext_key = extension.nibbles[common_len];
        if (extension.nibbles.len == common_len + 1) {
            branch.children[ext_key] = extension.next;
            branch.children_mask.set(@intCast(ext_key));
        } else {
            const remaining_ext_path = try self.allocator.dupe(u8, extension.nibbles[common_len + 1 ..]);
            const new_extension = try ExtensionNode.init(self.allocator, remaining_ext_path, extension.next);
            const ext_node = TrieNode{ .Extension = new_extension };
            const ext_hash = try self.store_node(ext_node);
            branch.children[ext_key] = HashValue{ .Hash = ext_hash };
            branch.children_mask.set(@intCast(ext_key));
        }

        // Add new value
        if (nibbles.len > common_len) {
            const new_key = nibbles[common_len];
            if (nibbles.len == common_len + 1) {
                branch.children[new_key] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                branch.children_mask.set(@intCast(new_key));
            } else {
                const remaining_path = try self.allocator.dupe(u8, nibbles[common_len + 1 ..]);
                const new_leaf = try LeafNode.init(self.allocator, remaining_path, HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                const leaf_node = TrieNode{ .Leaf = new_leaf };
                const leaf_hash = try self.store_node(leaf_node);
                branch.children[new_key] = HashValue{ .Hash = leaf_hash };
                branch.children_mask.set(@intCast(new_key));
            }
        } else {
            branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
        }

        if (common_len > 0) {
            const branch_node = TrieNode{ .Branch = branch };
            const branch_hash = try self.store_node(branch_node);

            const common_prefix = try self.allocator.dupe(u8, nibbles[0..common_len]);
            const new_extension = try ExtensionNode.init(self.allocator, common_prefix, HashValue{ .Hash = branch_hash });

            return TrieNode{ .Extension = new_extension };
        } else {
            return TrieNode{ .Branch = branch };
        }
    }

    /// Iteratively look up a key in the trie (zero recursion, zero heap allocations).
    fn get_value(self: *const HashBuilder, start_node: TrieNode, start_nibbles: []const u8) HashBuilderError!?[]const u8 {
        var cur_node = start_node;
        var remaining = start_nibbles;
        const max_steps: usize = start_nibbles.len + 2;
        var steps: usize = 0;

        while (steps < max_steps) : (steps += 1) {
            switch (cur_node) {
                .Empty => return null,
                .Leaf => |leaf| {
                    if (!std.mem.eql(u8, leaf.nibbles, remaining)) return null;
                    return switch (leaf.value) {
                        .Raw => |data| data,
                        .Hash => TrieError.InvalidNode,
                    };
                },
                .Extension => |extension| {
                    if (remaining.len < extension.nibbles.len) return null;
                    if (!std.mem.eql(u8, extension.nibbles, remaining[0..extension.nibbles.len])) return null;
                    cur_node = switch (extension.next) {
                        .Raw => return TrieError.InvalidNode,
                        .Hash => |hash| self.nodes.get(hash) orelse return TrieError.NonExistentNode,
                    };
                    remaining = remaining[extension.nibbles.len..];
                },
                .Branch => |branch| {
                    if (remaining.len == 0) {
                        const value = branch.value orelse return null;
                        return switch (value) {
                            .Raw => |data| data,
                            .Hash => TrieError.InvalidNode,
                        };
                    }
                    const key = remaining[0];
                    if (!branch.children_mask.is_set(@intCast(key))) return null;
                    const child = branch.children[key].?;
                    switch (child) {
                        .Raw => |data| return if (remaining.len == 1) data else null,
                        .Hash => |hash| {
                            cur_node = self.nodes.get(hash) orelse return TrieError.NonExistentNode;
                            remaining = remaining[1..];
                        },
                    }
                },
            }
        }
        return TrieError.InvalidNode;
    }

    /// Iteratively delete a key from the trie (descent + bottom-up canonical collapse, zero recursion).
    fn delete_node(self: *HashBuilder, start_node: TrieNode, start_nibbles: []const u8) HashBuilderError!?TrieNode {
        var frames = std.ArrayList(TraversalFrame).empty;
        errdefer self.deinitFrames(&frames);

        var cur_node = start_node;
        var remaining = start_nibbles;
        const max_steps: usize = start_nibbles.len + 2;
        var steps: usize = 0;

        var current: ?TrieNode = null;
        var settled = false;

        while (steps < max_steps) : (steps += 1) {
            switch (cur_node) {
                .Empty => {
                    current = null;
                    settled = true;
                    break;
                },
                .Leaf => |leaf| {
                    if (std.mem.eql(u8, leaf.nibbles, remaining)) {
                        current = null;
                    } else {
                        const path_copy = try self.allocator.dupe(u8, leaf.nibbles);
                        const new_leaf = try LeafNode.init(self.allocator, path_copy, try leaf.value.dupe(self.allocator));
                        current = TrieNode{ .Leaf = new_leaf };
                    }
                    settled = true;
                    break;
                },
                .Extension => |extension| {
                    if (remaining.len < extension.nibbles.len or
                        !std.mem.eql(u8, extension.nibbles, remaining[0..extension.nibbles.len]))
                    {
                        const path_copy = try self.allocator.dupe(u8, extension.nibbles);
                        const new_ext = try ExtensionNode.init(self.allocator, path_copy, extension.next);
                        current = TrieNode{ .Extension = new_ext };
                        settled = true;
                        break;
                    }
                    const next_node = switch (extension.next) {
                        .Raw => return TrieError.InvalidNode,
                        .Hash => |hash| self.nodes.get(hash) orelse return TrieError.NonExistentNode,
                    };
                    try frames.append(self.allocator, .{ .extension = extension.nibbles });
                    cur_node = next_node;
                    remaining = remaining[extension.nibbles.len..];
                },
                .Branch => |branch| {
                    var new_branch = try branch.dupe(self.allocator);
                    errdefer new_branch.deinit(self.allocator);

                    if (remaining.len == 0) {
                        if (new_branch.value) |*value| {
                            value.deinit(self.allocator);
                            new_branch.value = null;
                        }
                        current = try self.collapse_branch(&new_branch);
                        settled = true;
                        break;
                    }

                    const key = remaining[0];
                    if (new_branch.children_mask.is_set(@intCast(key))) {
                        const child = new_branch.children[key].?;
                        switch (child) {
                            .Raw => {
                                if (remaining.len == 1) {
                                    new_branch.children[key].?.deinit(self.allocator);
                                    new_branch.children[key] = null;
                                    new_branch.children_mask.unset(@intCast(key));
                                }
                            },
                            .Hash => |hash| {
                                const next_node = self.nodes.get(hash) orelse return TrieError.NonExistentNode;
                                try frames.append(self.allocator, .{ .branch = .{ .node = new_branch, .key = key } });
                                cur_node = next_node;
                                remaining = remaining[1..];
                                continue;
                            },
                        }
                    }

                    current = try self.collapse_branch(&new_branch);
                    settled = true;
                    break;
                },
            }
        }
        if (!settled) return TrieError.InvalidNode;

        while (frames.pop()) |frame| {
            errdefer if (current) |*owned| owned.deinit(self.allocator);
            switch (frame) {
                .extension => |ext_nibbles| {
                    current = try self.unwind_delete_extension(ext_nibbles, current);
                },
                .branch => |b| {
                    var branch_node = b.node;
                    errdefer branch_node.deinit(self.allocator);
                    current = try self.unwind_delete_branch(&branch_node, b.key, current);
                },
            }
        }
        frames.deinit(self.allocator);
        return current;
    }

    fn unwind_delete_extension(self: *HashBuilder, ext_nibbles: []const u8, child: ?TrieNode) HashBuilderError!?TrieNode {
        const new_next = child orelse return null;
        return switch (new_next) {
            .Leaf => |child_leaf| {
                const merged_path = try self.allocator.alloc(u8, ext_nibbles.len + child_leaf.nibbles.len);
                @memcpy(merged_path[0..ext_nibbles.len], ext_nibbles);
                @memcpy(merged_path[ext_nibbles.len..], child_leaf.nibbles);
                self.allocator.free(child_leaf.nibbles);
                return TrieNode{ .Leaf = try LeafNode.init(self.allocator, merged_path, child_leaf.value) };
            },
            .Extension => |child_ext| {
                const merged_path = try self.allocator.alloc(u8, ext_nibbles.len + child_ext.nibbles.len);
                @memcpy(merged_path[0..ext_nibbles.len], ext_nibbles);
                @memcpy(merged_path[ext_nibbles.len..], child_ext.nibbles);
                self.allocator.free(child_ext.nibbles);
                return TrieNode{ .Extension = try ExtensionNode.init(self.allocator, merged_path, child_ext.next) };
            },
            else => {
                const new_hash = try self.store_node(new_next);
                const path_copy = try self.allocator.dupe(u8, ext_nibbles);
                return TrieNode{ .Extension = try ExtensionNode.init(self.allocator, path_copy, HashValue{ .Hash = new_hash }) };
            },
        };
    }

    fn unwind_delete_branch(self: *HashBuilder, branch: *BranchNode, key: u8, child: ?TrieNode) HashBuilderError!?TrieNode {
        if (child) |new_next| {
            if (new_next == .Leaf and new_next.Leaf.nibbles.len == 0 and new_next.Leaf.value == .Raw) {
                const inline_value = HashValue{ .Raw = try self.allocator.dupe(u8, new_next.Leaf.value.Raw) };
                var discarded = new_next;
                discarded.deinit(self.allocator);
                branch.children[key].?.deinit(self.allocator);
                branch.children[key] = inline_value;
            } else {
                const new_hash = try self.store_node(new_next);
                branch.children[key].?.deinit(self.allocator);
                branch.children[key] = HashValue{ .Hash = new_hash };
            }
        } else {
            branch.children[key].?.deinit(self.allocator);
            branch.children[key] = null;
            branch.children_mask.unset(@intCast(key));
        }
        return try self.collapse_branch(branch);
    }

    /// Canonical MPT branch compression (Yellow Paper Appendix D):
    /// - 0 children & no value -> null (empty)
    /// - 0 children & value -> Leaf([], value)
    /// - 1 child & no value -> collapse with remaining child into Leaf/Extension
    fn collapse_branch(self: *HashBuilder, branch: *BranchNode) TrieError!?TrieNode {
        const child_count = branch.children_mask.bit_count();
        if (child_count == 0) {
            if (branch.value) |val| {
                const val_copy = try val.dupe(self.allocator);
                errdefer val_copy.deinit(self.allocator);
                const empty_path = try self.allocator.alloc(u8, 0);
                errdefer self.allocator.free(empty_path);
                const leaf = try LeafNode.init(self.allocator, empty_path, val_copy);
                branch.deinit(self.allocator);
                return TrieNode{ .Leaf = leaf };
            }
            branch.deinit(self.allocator);
            return null;
        }
        if (child_count == 1 and branch.value == null) {
            var only_nibble: u8 = 0;
            for (0..16) |idx| {
                if (branch.children_mask.is_set(@intCast(idx))) {
                    only_nibble = @intCast(idx);
                    break;
                }
            }
            const remaining_child = branch.children[only_nibble].?;
            switch (remaining_child) {
                .Raw => |raw_val| {
                    const val_copy = try self.allocator.dupe(u8, raw_val);
                    errdefer self.allocator.free(val_copy);
                    const path = try self.allocator.alloc(u8, 1);
                    errdefer self.allocator.free(path);
                    path[0] = only_nibble;
                    const leaf = try LeafNode.init(self.allocator, path, HashValue{ .Raw = val_copy });
                    branch.deinit(self.allocator);
                    return TrieNode{ .Leaf = leaf };
                },
                .Hash => |child_hash| {
                    if (self.nodes.get(child_hash)) |target_node| {
                        switch (target_node) {
                            .Leaf => |child_leaf| {
                                const merged = try self.allocator.alloc(u8, 1 + child_leaf.nibbles.len);
                                errdefer self.allocator.free(merged);
                                merged[0] = only_nibble;
                                @memcpy(merged[1..], child_leaf.nibbles);
                                const val_copy = try child_leaf.value.dupe(self.allocator);
                                errdefer val_copy.deinit(self.allocator);
                                const leaf = try LeafNode.init(self.allocator, merged, val_copy);
                                branch.deinit(self.allocator);
                                return TrieNode{ .Leaf = leaf };
                            },
                            .Extension => |child_ext| {
                                const merged = try self.allocator.alloc(u8, 1 + child_ext.nibbles.len);
                                errdefer self.allocator.free(merged);
                                merged[0] = only_nibble;
                                @memcpy(merged[1..], child_ext.nibbles);
                                const next_copy = try child_ext.next.dupe(self.allocator);
                                errdefer next_copy.deinit(self.allocator);
                                const ext = try ExtensionNode.init(self.allocator, merged, next_copy);
                                branch.deinit(self.allocator);
                                return TrieNode{ .Extension = ext };
                            },
                            else => {
                                const path = try self.allocator.alloc(u8, 1);
                                errdefer self.allocator.free(path);
                                path[0] = only_nibble;
                                const ext = try ExtensionNode.init(self.allocator, path, HashValue{ .Hash = child_hash });
                                branch.deinit(self.allocator);
                                return TrieNode{ .Extension = ext };
                            },
                        }
                    }
                },
            }
        }
        return TrieNode{ .Branch = branch.* };
    }
};

// Helper functions
fn common_prefix_length(a: []const u8, b: []const u8) usize {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len and a[i] == b[i]) : (i += 1) {}
    return i;
}

// Tests
test "HashBuilder - complete trie operations" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var builder = HashBuilder.init(allocator);
    defer builder.deinit();

    // Test basic operations
    try builder.insert(&[_]u8{ 1, 2, 3 }, "value1");
    try testing.expect(builder.get_root_hash() != null);

    const value = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);

    // Test multiple keys with common prefixes
    try builder.insert(&[_]u8{ 1, 2, 4 }, "value2");
    try builder.insert(&[_]u8{ 1, 3, 5 }, "value3");

    const value1 = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expectEqualStrings("value1", value1.?);

    const value2 = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expectEqualStrings("value2", value2.?);

    const value3 = try builder.get(&[_]u8{ 1, 3, 5 });
    try testing.expectEqualStrings("value3", value3.?);

    // Test deletion
    try builder.delete(&[_]u8{ 1, 2, 3 });
    const deleted = try builder.get(&[_]u8{ 1, 2, 3 });
    try testing.expect(deleted == null);

    // Other values should still exist
    const remaining = try builder.get(&[_]u8{ 1, 2, 4 });
    try testing.expectEqualStrings("value2", remaining.?);
}
