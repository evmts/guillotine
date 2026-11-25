# Trie

Merkle Patricia Trie and helpers for Ethereum state storage and proofs.

## Overview

Implements Patricia trie nodes, RLP encoding, hashing (Keccak256), and proof tooling. Emphasis is on cache‑friendly layouts and minimal allocations.

## Components and Architecture

### Core Implementation
- **`trie.zig`** - Main trie data structure and core operations
- **`merkle_trie.zig`** - Merkle tree functionality and root calculation
- **`module.zig`** - Module exports and type definitions
- **`root.zig`** - Module entry point and re-exports

### Hash Builders
- **`hash_builder_complete.zig`** - Full-featured hash builder with advanced optimizations

### Optimization Components
- **`optimized_branch.zig`** - Compact branch node representation
- **`proof.zig`** - Merkle proof generation and verification
- **`known_roots_test.zig`** - Test data for known root validation

### Testing
- **`test_simple_update.zig`** - Simple update operation tests

## Key Features

### Ethereum Compatibility
- **Patricia Trie Structure**: Full implementation of Ethereum's Patricia trie specification
- **RLP Encoding**: Proper RLP encoding/decoding for all trie nodes
- **Keccak256 Hashing**: Cryptographically secure hashing using Keccak256
- **Node Types**: Support for all Ethereum trie node types (leaf, extension, branch)

### Performance Optimization
- **Cache-Conscious Design**: Data structures optimized for CPU cache performance
- **Minimal Allocations**: Careful memory management with reuse patterns
- **Lazy Evaluation**: Deferred computation for improved performance
- **Batch Operations**: Efficient batch updates and bulk operations

### Memory Efficiency
- **Compact Representations**: Optimized node storage with minimal overhead
- **Reference Counting**: Efficient memory sharing for common subtrees
- **Garbage Collection**: Automatic cleanup of unused nodes and references
- **Memory Pools**: Custom allocators for improved memory management

### Cryptographic Security
- **Merkle Proofs**: Generation and verification of cryptographic proofs
- **Root Verification**: Efficient root hash calculation and validation
- **Tamper Detection**: Cryptographic integrity checking throughout operations
- **Secure Deletion**: Proper cleanup of sensitive data structures

## Integration Points

### State Management
- **Account Storage**: Efficient storage of Ethereum account data
- **Contract Storage**: High-performance contract state storage
- **Transaction Receipts**: Receipt trie construction and verification
- **State Root Calculation**: Fast state root computation for block headers

### Database Layer
- **Key-Value Backend**: Abstract interface for various storage backends
- **Caching Integration**: Multi-level caching for improved performance
- **Persistence**: Efficient serialization and deserialization
- **Migration Support**: Version-aware data format evolution

### EVM Integration
- **Storage Operations**: Direct integration with EVM SLOAD/SSTORE operations
- **State Queries**: Fast account and storage slot lookups
- **State Transitions**: Efficient state updates during transaction execution
- **Snapshot Support**: State snapshots for transaction rollback

## Usage Examples

### Basic Trie Operations
```zig
const trie = @import("trie");
const std = @import("std");

// Initialize trie
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

var my_trie = try trie.MerkleTrie.init(allocator);
defer my_trie.deinit();

// Insert key-value pairs
const key1 = "account1";
const value1 = "balance:1000000000000000000";
try my_trie.insert(key1, value1);

const key2 = "account2"; 
const value2 = "balance:2000000000000000000";
try my_trie.insert(key2, value2);

// Retrieve values
const retrieved = try my_trie.get(key1);
if (retrieved) |value| {
    std.debug.print("Retrieved: {s}\n", .{value});
}

// Calculate Merkle root
const root = try my_trie.calculate_root();
std.debug.print("Merkle root: {}\n", .{root});
```

### Advanced Hash Builder Usage
```zig
// Create hash builder with custom configuration
var hash_builder = try trie.HashBuilder.init(allocator, .{
    .optimization_level = .high,
    .cache_size = 1024 * 1024, // 1MB cache
    .enable_compression = true,
    .parallel_processing = true,
});
defer hash_builder.deinit();

// Build hash tree from key-value pairs
const pairs = &[_]trie.KeyValuePair{
    .{ .key = "key1", .value = "value1" },
    .{ .key = "key2", .value = "value2" },
    .{ .key = "key3", .value = "value3" },
};

const root_hash = try hash_builder.build_from_pairs(pairs);
std.debug.print("Computed root: {}\n", .{root_hash});

// Generate Merkle proof
const proof = try hash_builder.generate_proof("key2");
defer proof.deinit(allocator);
```

### Merkle Proof Operations
```zig
// Generate proof for a key
const proof_key = "account1";
const proof = try my_trie.generate_proof(proof_key);
defer proof.deinit(allocator);

// Verify proof against known root
const root_hash = try my_trie.get_root();
const is_valid = try trie.ProofRetainer.verify_proof(
    proof_key,
    value1,
    root_hash,
    proof.nodes
);

if (is_valid) {
    std.debug.print("Proof verification successful!\n");
} else {
    std.debug.print("Proof verification failed!\n");
}

// Verify proof without full trie
const standalone_verification = try trie.proof.verify_standalone(
    proof_key,
    expected_value,
    root_hash,
    proof.nodes
);
```

### Batch Operations
```zig
// Prepare batch update
var batch = try my_trie.create_batch();
defer batch.deinit();

// Add multiple operations to batch
try batch.insert("batch_key1", "batch_value1");
try batch.insert("batch_key2", "batch_value2");
try batch.delete("old_key");
try batch.update("existing_key", "new_value");

// Execute batch atomically
try my_trie.execute_batch(batch);

// Calculate new root after batch
const new_root = try my_trie.calculate_root();
```

### Custom Node Processing
```zig
// Implement custom node visitor
const NodeVisitor = struct {
    count: u32 = 0,
    
    pub fn visit_leaf(self: *@This(), key: []const u8, value: []const u8) !void {
        self.count += 1;
        std.debug.print("Leaf: {s} -> {s}\n", .{ key, value });
    }
    
    pub fn visit_branch(self: *@This(), children: []const ?*trie.TrieNode) !void {
        self.count += 1;
        std.debug.print("Branch with {} children\n", .{children.len});
    }
    
    pub fn visit_extension(self: *@This(), key: []const u8, child: *trie.TrieNode) !void {
        self.count += 1;
        std.debug.print("Extension: {s}\n", .{key});
    }
};

// Traverse trie with custom visitor
var visitor = NodeVisitor{};
try my_trie.traverse(&visitor);
std.debug.print("Visited {} nodes\n", .{visitor.count});
```

### Storage Backend Integration
```zig
// Implement custom storage backend
const CustomStorage = struct {
    data: std.HashMap([]const u8, []const u8),
    
    pub fn get(self: *@This(), key: []const u8) ?[]const u8 {
        return self.data.get(key);
    }
    
    pub fn put(self: *@This(), key: []const u8, value: []const u8) !void {
        try self.data.put(key, value);
    }
    
    pub fn delete(self: *@This(), key: []const u8) void {
        _ = self.data.remove(key);
    }
};

// Create trie with custom storage
var custom_storage = CustomStorage{
    .data = std.HashMap([]const u8, []const u8).init(allocator),
};
defer custom_storage.data.deinit();

var storage_trie = try trie.MerkleTrie.init_with_storage(allocator, &custom_storage);
defer storage_trie.deinit();
```

## Performance Characteristics

### Time Complexity
- **Insert/Update**: O(log n) average case, O(n) worst case
- **Lookup**: O(log n) average case, O(n) worst case  
- **Delete**: O(log n) average case, O(n) worst case
- **Root Calculation**: O(n) for full recalculation, O(log n) for incremental updates
- **Proof Generation**: O(log n) average case

### Space Complexity
- **Memory Usage**: O(n) for n key-value pairs
- **Node Overhead**: Minimal overhead per node with compact representation
- **Proof Size**: O(log n) for Merkle proofs
- **Cache Usage**: Configurable cache size for performance tuning

### Optimization Features
- **Lazy Hash Computation**: Hash calculation deferred until needed
- **Path Compression**: Efficient storage of common path prefixes
- **Node Sharing**: Reference counting for shared subtree structures
- **Cache Locality**: Data layout optimized for CPU cache performance

## Error Handling

### Error Types
```zig
pub const TrieError = error{
    InvalidNode,      // Malformed node structure
    InvalidKey,       // Invalid key format or encoding
    InvalidProof,     // Proof verification failure
    InvalidPath,      // Path traversal error
    NonExistentNode,  // Attempted access to missing node
    EmptyInput,       // Empty input where data required
    OutOfMemory,      // Memory allocation failure
    CorruptedTrie,    // Trie structure corruption detected
};
```

### Error Recovery
```zig
// Robust error handling with recovery
const result = my_trie.get(key) catch |err| switch (err) {
    error.InvalidKey => {
        std.debug.print("Invalid key format, sanitizing...\n");
        const sanitized_key = try sanitize_key(key);
        return try my_trie.get(sanitized_key);
    },
    error.CorruptedTrie => {
        std.debug.print("Trie corruption detected, rebuilding...\n");
        try my_trie.rebuild_from_storage();
        return try my_trie.get(key);
    },
    else => return err,
};
```

## Testing and Validation

### Unit Testing
```zig
test "basic trie operations" {
    var trie_instance = try trie.MerkleTrie.init(std.testing.allocator);
    defer trie_instance.deinit();
    
    // Test insertion
    try trie_instance.insert("test_key", "test_value");
    
    // Test retrieval
    const result = try trie_instance.get("test_key");
    try std.testing.expect(std.mem.eql(u8, result.?, "test_value"));
    
    // Test deletion
    try trie_instance.delete("test_key");
    const deleted_result = try trie_instance.get("test_key");
    try std.testing.expect(deleted_result == null);
}
```

### Property-Based Testing
```zig
test "trie invariants" {
    var trie_instance = try trie.MerkleTrie.init(std.testing.allocator);
    defer trie_instance.deinit();
    
    // Test with random data
    var prng = std.rand.DefaultPrng.init(12345);
    const random = prng.random();
    
    for (0..1000) |i| {
        const key = try generate_random_key(random);
        const value = try generate_random_value(random);
        
        try trie_instance.insert(key, value);
        
        // Verify retrieval
        const retrieved = try trie_instance.get(key);
        try std.testing.expect(std.mem.eql(u8, retrieved.?, value));
        
        // Verify root consistency
        const root1 = try trie_instance.get_root();
        const root2 = try trie_instance.calculate_root();
        try std.testing.expect(std.mem.eql(u8, &root1, &root2));
    }
}
```

### Integration Testing
```zig
test "Ethereum compatibility" {
    // Test against known Ethereum state roots
    const known_test_cases = trie.known_roots_test.get_test_cases();
    
    for (known_test_cases) |test_case| {
        var test_trie = try trie.MerkleTrie.init(std.testing.allocator);
        defer test_trie.deinit();
        
        // Insert test data
        for (test_case.data) |kv_pair| {
            try test_trie.insert(kv_pair.key, kv_pair.value);
        }
        
        // Verify computed root matches expected
        const computed_root = try test_trie.get_root();
        try std.testing.expect(std.mem.eql(u8, &computed_root, &test_case.expected_root));
    }
}
```

## Configuration and Tuning

### Performance Tuning
```zig
// Configure trie for high-performance scenarios
const PerformanceConfig = trie.Config{
    .cache_size = 10 * 1024 * 1024,    // 10MB cache
    .enable_lazy_hashing = true,        // Defer hash computation
    .max_batch_size = 10000,           // Large batch operations
    .compression_level = .fast,         // Fast compression
    .parallel_threads = 4,              // Parallel processing
};

var perf_trie = try trie.MerkleTrie.init_with_config(allocator, PerformanceConfig);
```

### Memory Optimization
```zig
// Configure trie for memory-constrained environments
const MemoryConfig = trie.Config{
    .cache_size = 256 * 1024,          // 256KB cache
    .enable_compression = true,         // Aggressive compression
    .garbage_collection_frequency = 100, // Frequent GC
    .max_node_pool_size = 1000,        // Limited node pool
    .enable_node_sharing = true,        // Maximize sharing
};

var memory_trie = try trie.MerkleTrie.init_with_config(allocator, MemoryConfig);
```

The trie module provides a production-ready, high-performance implementation of Ethereum's Merkle Patricia Trie with comprehensive features for state management, proof generation, and cryptographic verification while maintaining optimal performance characteristics for real-world blockchain applications.
