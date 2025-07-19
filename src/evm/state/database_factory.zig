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
//! defer destroy_database(allocator, db_interface);
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


/// Create a database implementation based on configuration
///
/// ## Parameters
/// - `allocator`: Memory allocator for database allocation
/// - `config`: Configuration specifying database type and parameters
///
/// ## Returns
/// DatabaseInterface wrapping the created database implementation
///
/// ## Memory Management
/// The returned database interface owns the underlying implementation.
/// Call `destroy_database` to properly clean up resources.
///
/// ## Example
/// ```zig
/// const config = DatabaseConfig{ .Memory = {} };
/// const db = try create_database(allocator, config);
/// defer destroy_database(allocator, db);
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

            // Return interface with embedded cleanup
            return memory_db.to_database_interface_with_cleanup(allocator);
        },

        // Future database types can be implemented here:
        //
        // .Fork => |fork_config| {
        //     const fork_db = try allocator.create(ForkDatabase);
        //     fork_db.* = try ForkDatabase.init(allocator, fork_config.remote_url, fork_config.block_number);
        //
        //     const metadata = DatabaseMetadata{
        //         .database_type = .Fork,
        //         .allocation_ptr = fork_db,
        //         .allocation_size = @sizeOf(ForkDatabase),
        //     };
        //     try database_metadata_map.put(fork_db, metadata);
        //
        //     return fork_db.to_database_interface();
        // },
        //
        // .File => |file_config| {
        //     const file_db = try allocator.create(FileDatabase);
        //     file_db.* = try FileDatabase.init(allocator, file_config.file_path, file_config.create_if_missing);
        //
        //     const metadata = DatabaseMetadata{
        //         .database_type = .File,
        //         .allocation_ptr = file_db,
        //         .allocation_size = @sizeOf(FileDatabase),
        //     };
        //     try database_metadata_map.put(file_db, metadata);
        //
        //     return file_db.to_database_interface();
        // },
        //
        // .Cached => |cached_config| {
        //     const backend_db = try create_database(allocator, cached_config.backend_config.*);
        //
        //     const cached_db = try allocator.create(CachedDatabase);
        //     cached_db.* = try CachedDatabase.init(allocator, backend_db, cached_config.cache_size);
        //
        //     const metadata = DatabaseMetadata{
        //         .database_type = .Cached,
        //         .allocation_ptr = cached_db,
        //         .allocation_size = @sizeOf(CachedDatabase),
        //     };
        //     try database_metadata_map.put(cached_db, metadata);
        //
        //     return cached_db.to_database_interface();
        // },
    }
}

/// Destroy a database created by create_database
///
/// ## Parameters
/// - `database`: Database interface to destroy
///
/// ## Important
/// This function must be called to properly clean up database resources.
/// The database interface becomes invalid after this call.
/// Uses the embedded cleanup pattern, so no allocator parameter is needed.
///
/// ## Example
/// ```zig
/// const db = try create_database(allocator, config);
/// defer destroy_database(db);
/// ```
pub fn destroy_database(database: DatabaseInterface) void {
    // Use the embedded cleanup function which handles both deinit and deallocation
    database.destroy();
}


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
    defer destroy_database(testing.allocator, db);

    // Test that we can use the database
    const address = [_]u8{1} ** 20;
    const account = @import("database_interface.zig").Account.zero();

    try db.set_account(address, account);
    const retrieved_account = try db.get_account(address);
    try testing.expect(retrieved_account != null);
}

test "factory convenience function" {
    const db = try create_memory_database(testing.allocator);
    defer destroy_database(testing.allocator, db);

    // Test database type detection
    const db_type = get_database_type(db);
    try testing.expect(db_type == .Memory);
}

test "factory cleanup" {
    defer deinit_factory();

    // Create and destroy a database
    const db = try create_memory_database(testing.allocator);
    destroy_database(testing.allocator, db);

    // Factory should clean up properly
}
