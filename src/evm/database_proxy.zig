//! Generic database proxy supporting multiple operation modes.
//!
//! Provides flexible database access patterns through compile-time mode selection:
//! - pass_through: Direct forwarding to underlying database (default)
//! - static: Read-only access enforcing EIP-214 constraints  
//! - lru: Local caching with batch write capabilities
//!
//! This refactor generalizes the existing StaticDatabase pattern to support
//! multiple database interaction modes with zero runtime overhead.

const std = @import("std");
const Database = @import("database.zig").Database;
const Account = @import("database.zig").Account;

/// Database proxy operation modes
pub const ProxyMode = enum {
    pass_through, // Default - direct passthrough to inner database
    static,       // Read-only, writes return PermissionDenied (EIP-214)
    lru,         // Cache writes locally, flush on demand
};

/// Storage key for LRU cache mapping
const StorageKey = struct {
    address: [20]u8,
    slot: u256,
};

/// Generic database proxy with compile-time mode selection
pub fn DatabaseProxy(comptime mode: ProxyMode, comptime DatabaseType: type) type {
    return struct {
        const Self = @This();
        
        /// Underlying database for operations
        inner: DatabaseType,
        
        /// Cache data (only allocated for LRU mode)
        cache: if (mode == .lru) struct {
            // TODO: Add LRU cache implementation
            storage_writes: std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage),
            // TODO: Add account_updates, code_updates maps
            allocator: std.mem.Allocator,
        } else void,

        /// Initialize database proxy
        pub fn init(inner: DatabaseType, allocator: ?std.mem.Allocator) !Self {
            return switch (mode) {
                .pass_through, .static => Self{ 
                    .inner = inner, 
                    .cache = {} 
                },
                .lru => Self{
                    .inner = inner,
                    .cache = .{
                        .storage_writes = std.HashMap(StorageKey, u256, StorageKeyContext, std.hash_map.default_max_load_percentage).init(allocator.?),
                        .allocator = allocator.?,
                    },
                },
            };
        }

        /// Clean up proxy resources
        pub fn deinit(self: *Self) void {
            switch (mode) {
                .pass_through, .static => {}, // Nothing to clean up
                .lru => {
                    self.cache.storage_writes.deinit();
                },
            }
        }

        /// Get account information
        pub fn get_account(self: *Self, address: [20]u8) Database.Error!?Account {
            switch (mode) {
                .pass_through, .static => return self.inner.get_account(address),
                .lru => {
                    // TODO: Check cache first, then fall back to inner
                    return self.inner.get_account(address);
                },
            }
        }

        /// Get storage value
        pub fn get_storage(self: *Self, address: [20]u8, key: u256) Database.Error!u256 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_storage(address, key),
                .lru => {
                    // Check cache first
                    const cache_key = StorageKey{ .address = address, .slot = key };
                    if (self.cache.storage_writes.get(cache_key)) |value| {
                        return value;
                    }
                    // Fall back to inner database
                    return self.inner.get_storage(address, key);
                },
            }
        }

        /// Set storage value - behavior depends on mode
        pub fn set_storage(self: *Self, address: [20]u8, key: u256, value: u256) Database.Error!void {
            switch (mode) {
                .pass_through => return self.inner.set_storage(address, key, value),
                .static => return Database.Error.PermissionDenied, // EIP-214 constraint
                .lru => {
                    // Store in cache, don't write through yet
                    const cache_key = StorageKey{ .address = address, .slot = key };
                    try self.cache.storage_writes.put(cache_key, value);
                },
            }
        }

        /// Get account balance
        pub fn get_balance(self: *Self, address: [20]u8) Database.Error!u256 {
            switch (mode) {
                .pass_through, .static => return self.inner.get_balance(address),
                .lru => {
                    // TODO: Check cached account updates first
                    return self.inner.get_balance(address);
                },
            }
        }

        // TODO: Implement remaining Database interface methods for all modes
        // - set_account, get_code, set_code, etc.
        // - Snapshot operations (create_snapshot, revert_to_snapshot, etc.)
        // - Transaction operations (begin_transaction, commit_transaction, etc.)
        // - Batch operations (begin_batch, commit_batch, rollback_batch)

        /// Flush cached changes to underlying database (LRU mode only)
        pub fn flush(self: *Self) !void {
            if (mode != .lru) @compileError("flush only available in LRU mode");
            
            // TODO: Apply all cached changes to inner database
            // TODO: Clear cache after successful flush
            // TODO: Return cache contents for inspection
            _ = self;
        }
    };
}

/// Hash context for storage keys in LRU cache
const StorageKeyContext = struct {
    pub fn hash(self: @This(), key: StorageKey) u64 {
        _ = self;
        // TODO: Implement proper hash combining address + slot
        return std.hash_map.hashString(std.mem.asBytes(&key.address)) ^ @as(u64, @truncate(key.slot));
    }
    
    pub fn eql(self: @This(), a: StorageKey, b: StorageKey) bool {
        _ = self;
        return std.mem.eql(u8, &a.address, &b.address) and a.slot == b.slot;
    }
};

// Simple compilation test to verify basic structure
test "DatabaseProxy compiles with all modes" {
    const PassThroughProxy = DatabaseProxy(.pass_through, Database);
    const StaticProxy = DatabaseProxy(.static, Database);
    const LruProxy = DatabaseProxy(.lru, Database);
    
    // Should compile without errors
    _ = PassThroughProxy;
    _ = StaticProxy;
    _ = LruProxy;
}