//! Database Factory for Creating Different Database Implementations
//!
//! This module provides a factory pattern for creating different types of database
//! implementations. It allows for easy configuration and instantiation of database
//! backends without coupling the EVM core to specific implementations.
//!
//! ## Supported Database Types
//!
//! - **Memory**: Fast in-memory storage for testing and development
//! - **Future**: File, Network, Cached, Fork implementations can be added here
//!
//! ## Usage
//!
//! ```zig
//! const config = DatabaseConfig{ .Memory = {} };
//! const db_interface = try create_database(allocator, config);
//! defer db_interface.destroy(); // Uses embedded cleanup, no need to pass allocator
//! ```
//!
//! ## Extensibility
//!
//! New database types can be added by:
//! 1. Adding to DatabaseType enum
//! 2. Adding configuration to DatabaseConfig union
//! 3. Adding case to create_database function
//! 4. Implementing the required database interface

const std = @import("std");
const DatabaseInterface = @import("database_interface.zig").DatabaseInterface;
const MemoryDatabase = @import("memory_database.zig").MemoryDatabase;

/// Types of database implementations available
pub const DatabaseType = enum {
    /// In-memory hash map based storage
    Memory,

    // Future database types can be added here:
    // Fork,      // Fork from remote Ethereum node
    // File,      // File-based persistent storage
    // Cached,    // Cached layer over another database
    // Network,   // Network-based remote database
};

/// Configuration for database creation
pub const DatabaseConfig = union(DatabaseType) {
    /// Memory database requires no configuration
    Memory: void,

    // Future configurations:
    // Fork: struct {
    //     remote_url: []const u8,
    //     block_number: ?u64 = null,  // Fork at specific block
    // },
    // File: struct {
    //     file_path: []const u8,
    //     create_if_missing: bool = true,
    // },
    // Cached: struct {
    //     backend_config: *const DatabaseConfig,
    //     cache_size: usize,
    //     eviction_policy: CacheEvictionPolicy = .LRU,
    // },
    // Network: struct {
    //     endpoint_url: []const u8,
    //     timeout_ms: u32 = 5000,
    //     retry_count: u8 = 3,
    // },
};

/// Cleanup function for memory database
fn cleanup_memory_database(allocator: std.mem.Allocator, ptr: *anyopaque) void {
    const memory_db: *MemoryDatabase = @ptrCast(@alignCast(ptr));
    allocator.destroy(memory_db);
}

/// Create a database implementation based on configuration
///
/// ## Parameters
/// - `allocator`: Memory allocator for database allocation
/// - `config`: Configuration specifying database type and parameters
///
/// ## Returns
/// DatabaseInterface wrapping the created database implementation with embedded cleanup
///
/// ## Memory Management
/// The returned database interface owns the underlying implementation.
/// Call `.destroy()` to properly clean up resources using embedded cleanup information.
///
/// ## Example
/// ```zig
/// const config = DatabaseConfig{ .Memory = {} };
/// const db = try create_database(allocator, config);
/// defer db.destroy(); // No need to pass allocator, it's embedded
///
/// // Use database through interface
/// try db.set_account(address, account);
/// ```
pub fn create_database(allocator: std.mem.Allocator, config: DatabaseConfig) !DatabaseInterface {
    switch (config) {
        .Memory => {
            // Allocate memory database on heap
            const memory_db = try allocator.create(MemoryDatabase);
            memory_db.* = MemoryDatabase.init(allocator);

            // Return interface with embedded cleanup function and allocator
            return DatabaseInterface.init_with_cleanup(memory_db, allocator, cleanup_memory_database);
        },

        // Future database types can be implemented here:
        //
        // .Fork => |fork_config| {
        //     const fork_db = try allocator.create(ForkDatabase);
        //     fork_db.* = try ForkDatabase.init(allocator, fork_config.remote_url, fork_config.block_number);
        //     return DatabaseInterface.init_with_cleanup(fork_db, allocator, cleanup_fork_database);
        // },
        //
        // .File => |file_config| {
        //     const file_db = try allocator.create(FileDatabase);
        //     file_db.* = try FileDatabase.init(allocator, file_config.file_path, file_config.create_if_missing);
        //     return DatabaseInterface.init_with_cleanup(file_db, allocator, cleanup_file_database);
        // },
        //
        // .Cached => |cached_config| {
        //     const backend_db = try create_database(allocator, cached_config.backend_config.*);
        //     const cached_db = try allocator.create(CachedDatabase);
        //     cached_db.* = try CachedDatabase.init(allocator, backend_db, cached_config.cache_size);
        //     return DatabaseInterface.init_with_cleanup(cached_db, allocator, cleanup_cached_database);
        // },
    }
}

// destroy_database function is no longer needed
// Use database.destroy() method instead, which uses embedded cleanup information

// get_database_type function is no longer available
// Database type information is not tracked with the new embedded cleanup approach

// deinit_factory function is no longer needed
// No global factory state to clean up with the embedded cleanup approach

/// Convenience function to create a memory database
///
/// ## Parameters
/// - `allocator`: Memory allocator
///
/// ## Returns
/// DatabaseInterface for a new memory database
pub fn create_memory_database(allocator: std.mem.Allocator) !DatabaseInterface {
    return create_database(allocator, DatabaseConfig{ .Memory = {} });
}

// Future convenience functions:
//
// /// Convenience function to create a fork database
// pub fn create_fork_database(allocator: std.mem.Allocator, remote_url: []const u8, block_number: ?u64) !DatabaseInterface {
//     return create_database(allocator, DatabaseConfig{ .Fork = .{ .remote_url = remote_url, .block_number = block_number } });
// }
//
// /// Convenience function to create a file database
// pub fn create_file_database(allocator: std.mem.Allocator, file_path: []const u8) !DatabaseInterface {
//     return create_database(allocator, DatabaseConfig{ .File = .{ .file_path = file_path } });
// }
//
// /// Convenience function to create a cached database
// pub fn create_cached_database(allocator: std.mem.Allocator, backend_config: DatabaseConfig, cache_size: usize) !DatabaseInterface {
//     return create_database(allocator, DatabaseConfig{ .Cached = .{ .backend_config = &backend_config, .cache_size = cache_size } });
// }

// Tests
const testing = std.testing;

test "factory memory database creation" {
    const config = DatabaseConfig{ .Memory = {} };
    const db = try create_database(testing.allocator, config);
    defer db.destroy(); // Use embedded cleanup

    // Test that we can use the database
    const address = [_]u8{1} ** 20;
    const account = @import("database_interface.zig").Account.zero();

    try db.set_account(address, account);
    const retrieved_account = try db.get_account(address);
    try testing.expect(retrieved_account != null);
}

test "factory convenience function" {
    const db = try create_memory_database(testing.allocator);
    defer db.destroy(); // Use embedded cleanup

    // Test that database works (database type detection is no longer available)
    const address = [_]u8{1} ** 20;
    const account = @import("database_interface.zig").Account.zero();
    try db.set_account(address, account);
    const retrieved_account = try db.get_account(address);
    try testing.expect(retrieved_account != null);
}

test "factory cleanup" {
    // No factory state to clean up with embedded cleanup approach
    
    // Create and destroy a database
    const db = try create_memory_database(testing.allocator);
    db.destroy(); // Use embedded cleanup

    // No global factory state to verify
}
