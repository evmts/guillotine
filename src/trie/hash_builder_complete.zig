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
            const hash_str = try bytes_to_hex_string(allocator, &root);
            defer allocator.free(hash_str);

            if (builder.nodes.get(hash_str)) |root_node| {
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
                        .Hash => |hash| blk: {
                            const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                            defer self.allocator.free(hash_str);
                            break :blk self.builder.nodes.get(hash_str) orelse {
                                self.allocator.free(new_path);
                                return TrieError.NonExistentNode;
                            };
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
                                    const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                                    defer self.allocator.free(hash_str);

                                    const child_node = self.builder.nodes.get(hash_str) orelse {
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
    // Store nodes by their hash (hex encoded) - safer than complex pointer management
    nodes: std.StringHashMap(TrieNode),
    // The root node's hash (if built)
    root_hash: ?[32]u8,

    pub fn init(allocator: Allocator) HashBuilder {
        return HashBuilder{
            .allocator = allocator,
            .nodes = std.StringHashMap(TrieNode).init(allocator),
            .root_hash = null,
        };
    }

    pub fn deinit(self: *HashBuilder) void {
        // Clean up all nodes
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            // Free the hash key string
            self.allocator.free(entry.key_ptr.*);
            // Deinit the node
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    pub fn reset(self: *HashBuilder) void {
        // Clean up all nodes
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var node = entry.value_ptr.*;
            node.deinit(self.allocator);
        }
        self.nodes.clearRetainingCapacity();

        self.root_hash = null;
    }

    /// Store a node and return its hash
    fn store_node(self: *HashBuilder, node: TrieNode) HashBuilderError![32]u8 {
        // Calculate the hash
        const hash = try node.hash(self.allocator);
        const hash_str = try bytes_to_hex_string(self.allocator, &hash);
        errdefer self.allocator.free(hash_str);

        // Check if we already have this node
        if (self.nodes.contains(hash_str)) {
            self.allocator.free(hash_str);
            var duplicate = node;
            duplicate.deinit(self.allocator);
            return hash;
        }

        // Store the node
        try self.nodes.put(hash_str, node);
        return hash;
    }

    /// Add a key-value pair to the trie
    pub fn insert(self: *HashBuilder, key: []const u8, value: []const u8) HashBuilderError!void {
        // Convert key to nibbles
        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        // Get or create root
        const root_node = if (self.root_hash) |hash| blk: {
            const hash_str = try bytes_to_hex_string(self.allocator, &hash);
            defer self.allocator.free(hash_str);
            break :blk self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
        } else TrieNode{ .Empty = {} };

        // Insert into the trie
        const new_root = try self.insert_node(root_node, nibbles, value);

        // Store the new root and update hash
        self.root_hash = try self.store_node(new_root);
    }

    /// Get a value from the trie
    pub fn get(self: *HashBuilder, key: []const u8) HashBuilderError!?[]const u8 {
        if (self.root_hash == null) return null;

        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const hash_str = try bytes_to_hex_string(self.allocator, &self.root_hash.?);
        defer self.allocator.free(hash_str);

        const root_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
        return try self.get_value(root_node, nibbles);
    }

    /// Delete a key-value pair from the trie
    pub fn delete(self: *HashBuilder, key: []const u8) HashBuilderError!void {
        if (self.root_hash == null) return;

        const nibbles = try trie.key_to_nibbles(self.allocator, key);
        defer self.allocator.free(nibbles);

        const hash_str = try bytes_to_hex_string(self.allocator, &self.root_hash.?);
        defer self.allocator.free(hash_str);

        const root_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;

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

    // Internal implementation methods

    fn insert_node(self: *HashBuilder, node: TrieNode, nibbles: []const u8, value: []const u8) HashBuilderError!TrieNode {
        switch (node) {
            .Empty => {
                // Create new leaf
                const path_copy = try self.allocator.dupe(u8, nibbles);
                const value_copy = try self.allocator.dupe(u8, value);
                const leaf = try LeafNode.init(self.allocator, path_copy, HashValue{ .Raw = value_copy });
                return TrieNode{ .Leaf = leaf };
            },
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    // Replace value
                    const path_copy = try self.allocator.dupe(u8, nibbles);
                    const value_copy = try self.allocator.dupe(u8, value);
                    const new_leaf = try LeafNode.init(self.allocator, path_copy, HashValue{ .Raw = value_copy });
                    return TrieNode{ .Leaf = new_leaf };
                }

                // Split the leaf
                return try self.split_leaf(leaf, nibbles, value);
            },
            .Extension => |extension| {
                return try self.insert_into_extension(extension, nibbles, value);
            },
            .Branch => |branch| {
                return try self.insert_into_branch(branch, nibbles, value);
            },
        }
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

    fn insert_into_extension(self: *HashBuilder, extension: ExtensionNode, nibbles: []const u8, value: []const u8) HashBuilderError!TrieNode {
        const common_len = common_prefix_length(extension.nibbles, nibbles);

        if (common_len == extension.nibbles.len) {
            // Extension is prefix of path, continue with next node
            const remaining_path = nibbles[common_len..];

            // Get next node
            const next_node = switch (extension.next) {
                .Raw => return TrieError.InvalidNode,
                .Hash => |hash| blk: {
                    const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                    defer self.allocator.free(hash_str);
                    break :blk self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
                },
            };

            // Insert into next node
            const updated_node = try self.insert_node(next_node, remaining_path, value);
            const updated_hash = try self.store_node(updated_node);

            // Create new extension with updated next
            const path_copy = try self.allocator.dupe(u8, extension.nibbles);
            const new_extension = try ExtensionNode.init(self.allocator, path_copy, HashValue{ .Hash = updated_hash });

            return TrieNode{ .Extension = new_extension };
        } else {
            // Split the extension
            return try self.split_extension(extension, nibbles, value, common_len);
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
            // Create new extension
            const branch_node = TrieNode{ .Branch = branch };
            const branch_hash = try self.store_node(branch_node);

            const common_prefix = try self.allocator.dupe(u8, nibbles[0..common_len]);
            const new_extension = try ExtensionNode.init(self.allocator, common_prefix, HashValue{ .Hash = branch_hash });

            return TrieNode{ .Extension = new_extension };
        } else {
            return TrieNode{ .Branch = branch };
        }
    }

    fn insert_into_branch(self: *HashBuilder, branch: BranchNode, nibbles: []const u8, value: []const u8) HashBuilderError!TrieNode {
        var new_branch = try branch.dupe(self.allocator);

        if (nibbles.len == 0) {
            // Set branch value
            if (new_branch.value) |*old_value| {
                old_value.deinit(self.allocator);
            }
            new_branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            return TrieNode{ .Branch = new_branch };
        }

        const key = nibbles[0];
        const remaining_path = nibbles[1..];

        if (new_branch.children_mask.is_set(@intCast(key))) {
            // Update existing child
            const child = new_branch.children[key].?;
            const updated_node = switch (child) {
                .Raw => |data| blk: {
                    // Handle raw value directly without creating temp node
                    if (remaining_path.len == 0) {
                        // Direct replacement with new value
                        const new_leaf = try LeafNode.init(self.allocator, try self.allocator.alloc(u8, 0), HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                        break :blk TrieNode{ .Leaf = new_leaf };
                    } else {
                        // Need to create a branch to hold both the existing data and new value
                        var sub_branch = BranchNode.init();

                        // Add existing value at remaining_path[0]
                        if (remaining_path.len == 1) {
                            sub_branch.children[remaining_path[0]] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
                            sub_branch.children_mask.set(@intCast(remaining_path[0]));
                        } else {
                            const leaf_path = try self.allocator.dupe(u8, remaining_path[1..]);
                            const new_leaf = try LeafNode.init(self.allocator, leaf_path, HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                            const leaf_node = TrieNode{ .Leaf = new_leaf };
                            const leaf_hash = try self.store_node(leaf_node);
                            sub_branch.children[remaining_path[0]] = HashValue{ .Hash = leaf_hash };
                            sub_branch.children_mask.set(@intCast(remaining_path[0]));
                        }

                        // Set the existing data as the branch value
                        sub_branch.value = HashValue{ .Raw = try self.allocator.dupe(u8, data) };

                        break :blk TrieNode{ .Branch = sub_branch };
                    }
                },
                .Hash => |hash| blk: {
                    const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                    defer self.allocator.free(hash_str);
                    const next_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
                    break :blk try self.insert_node(next_node, remaining_path, value);
                },
            };

            const updated_hash = try self.store_node(updated_node);

            // Free old child and set new one
            new_branch.children[key].?.deinit(self.allocator);
            new_branch.children[key] = HashValue{ .Hash = updated_hash };
        } else {
            // Add new child
            if (remaining_path.len == 0) {
                new_branch.children[key] = HashValue{ .Raw = try self.allocator.dupe(u8, value) };
            } else {
                const leaf = try LeafNode.init(self.allocator, try self.allocator.dupe(u8, remaining_path), HashValue{ .Raw = try self.allocator.dupe(u8, value) });
                const leaf_node = TrieNode{ .Leaf = leaf };
                const leaf_hash = try self.store_node(leaf_node);
                new_branch.children[key] = HashValue{ .Hash = leaf_hash };
            }
            new_branch.children_mask.set(@intCast(key));
        }

        return TrieNode{ .Branch = new_branch };
    }

    fn get_value(self: *const HashBuilder, node: TrieNode, nibbles: []const u8) HashBuilderError!?[]const u8 {
        switch (node) {
            .Empty => return null,
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    switch (leaf.value) {
                        .Raw => |data| return data,
                        .Hash => return TrieError.InvalidNode, // Leaves should have raw values
                    }
                }
                return null;
            },
            .Extension => |extension| {
                if (nibbles.len < extension.nibbles.len) return null;
                if (!std.mem.eql(u8, extension.nibbles, nibbles[0..extension.nibbles.len])) return null;

                const next_node = switch (extension.next) {
                    .Raw => return TrieError.InvalidNode,
                    .Hash => |hash| blk: {
                        const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                        defer self.allocator.free(hash_str);
                        break :blk self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
                    },
                };

                return try self.get_value(next_node, nibbles[extension.nibbles.len..]);
            },
            .Branch => |branch| {
                if (nibbles.len == 0) {
                    if (branch.value) |value| {
                        switch (value) {
                            .Raw => |data| return data,
                            .Hash => return TrieError.InvalidNode,
                        }
                    }
                    return null;
                }

                const key = nibbles[0];
                if (!branch.children_mask.is_set(@intCast(key))) return null;

                const child = branch.children[key].?;
                return switch (child) {
                    .Raw => |data| {
                        if (nibbles.len == 1) return data;
                        return null;
                    },
                    .Hash => |hash| blk: {
                        const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                        defer self.allocator.free(hash_str);
                        const next_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
                        break :blk try self.get_value(next_node, nibbles[1..]);
                    },
                };
            },
        }
    }

    fn delete_node(self: *HashBuilder, node: TrieNode, nibbles: []const u8) HashBuilderError!?TrieNode {
        // Simplified delete - in a full implementation this would handle node consolidation
        switch (node) {
            .Empty => return null,
            .Leaf => |leaf| {
                if (std.mem.eql(u8, leaf.nibbles, nibbles)) {
                    return null; // Delete this leaf
                }
                // Copy the leaf
                const path_copy = try self.allocator.dupe(u8, leaf.nibbles);
                const new_leaf = try LeafNode.init(self.allocator, path_copy, try leaf.value.dupe(self.allocator));
                return TrieNode{ .Leaf = new_leaf };
            },
            .Extension => |extension| {
                if (nibbles.len < extension.nibbles.len) {
                    // Path doesn't match
                    const path_copy = try self.allocator.dupe(u8, extension.nibbles);
                    const new_extension = try ExtensionNode.init(self.allocator, path_copy, extension.next);
                    return TrieNode{ .Extension = new_extension };
                }

                if (!std.mem.eql(u8, extension.nibbles, nibbles[0..extension.nibbles.len])) {
                    // Path doesn't match
                    const path_copy = try self.allocator.dupe(u8, extension.nibbles);
                    const new_extension = try ExtensionNode.init(self.allocator, path_copy, extension.next);
                    return TrieNode{ .Extension = new_extension };
                }

                // Follow extension and delete from next node
                const next_node = switch (extension.next) {
                    .Raw => return TrieError.InvalidNode,
                    .Hash => |hash| blk: {
                        const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                        defer self.allocator.free(hash_str);
                        break :blk self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;
                    },
                };

                const result = try self.delete_node(next_node, nibbles[extension.nibbles.len..]);
                if (result) |new_next| {
                    switch (new_next) {
                        .Leaf => |child_leaf| {
                            // Collapse Extension -> Leaf into a single canonical Leaf
                            const merged_path = try self.allocator.alloc(u8, extension.nibbles.len + child_leaf.nibbles.len);
                            @memcpy(merged_path[0..extension.nibbles.len], extension.nibbles);
                            @memcpy(merged_path[extension.nibbles.len..], child_leaf.nibbles);
                            self.allocator.free(child_leaf.nibbles);
                            const merged_leaf = try LeafNode.init(self.allocator, merged_path, child_leaf.value);
                            return TrieNode{ .Leaf = merged_leaf };
                        },
                        .Extension => |child_ext| {
                            // Collapse Extension -> Extension into a single canonical Extension
                            const merged_path = try self.allocator.alloc(u8, extension.nibbles.len + child_ext.nibbles.len);
                            @memcpy(merged_path[0..extension.nibbles.len], extension.nibbles);
                            @memcpy(merged_path[extension.nibbles.len..], child_ext.nibbles);
                            self.allocator.free(child_ext.nibbles);
                            const merged_ext = try ExtensionNode.init(self.allocator, merged_path, child_ext.next);
                            return TrieNode{ .Extension = merged_ext };
                        },
                        else => {
                            const new_hash = try self.store_node(new_next);
                            const path_copy = try self.allocator.dupe(u8, extension.nibbles);
                            const new_extension = try ExtensionNode.init(self.allocator, path_copy, HashValue{ .Hash = new_hash });
                            return TrieNode{ .Extension = new_extension };
                        },
                    }
                } else {
                    return null; // Next node was deleted
                }
            },
            .Branch => |branch| {
                var new_branch = try branch.dupe(self.allocator);
                errdefer new_branch.deinit(self.allocator);

                if (nibbles.len == 0) {
                    // Delete branch value
                    if (new_branch.value) |*value| {
                        value.deinit(self.allocator);
                        new_branch.value = null;
                    }
                } else {
                    const key = nibbles[0];
                    if (new_branch.children_mask.is_set(@intCast(key))) {
                        const child = new_branch.children[key].?;
                        switch (child) {
                            .Raw => {
                                if (nibbles.len == 1) {
                                    // Delete this child
                                    new_branch.children[key].?.deinit(self.allocator);
                                    new_branch.children[key] = null;
                                    new_branch.children_mask.unset(@intCast(key));
                                }
                            },
                            .Hash => |hash| {
                                const hash_str = try bytes_to_hex_string(self.allocator, &hash);
                                defer self.allocator.free(hash_str);
                                const next_node = self.nodes.get(hash_str) orelse return TrieError.NonExistentNode;

                                const result = try self.delete_node(next_node, nibbles[1..]);
                                if (result) |new_next| {
                                    const new_hash = try self.store_node(new_next);
                                    new_branch.children[key].?.deinit(self.allocator);
                                    new_branch.children[key] = HashValue{ .Hash = new_hash };
                                } else {
                                    new_branch.children[key].?.deinit(self.allocator);
                                    new_branch.children[key] = null;
                                    new_branch.children_mask.unset(@intCast(key));
                                }
                            },
                        }
                    }
                }

                return try self.collapse_branch(&new_branch);
            },
        }
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
                    const hash_str = try bytes_to_hex_string(self.allocator, &child_hash);
                    defer self.allocator.free(hash_str);
                    if (self.nodes.get(hash_str)) |target_node| {
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

fn bytes_to_hex_string(allocator: Allocator, bytes: []const u8) std.mem.Allocator.Error![]u8 {
    const hex_chars = "0123456789abcdef";
    const hex = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(hex);

    for (bytes, 0..) |byte, i| {
        hex[i * 2] = hex_chars[byte >> 4];
        hex[i * 2 + 1] = hex_chars[byte & 0x0F];
    }

    return hex;
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
