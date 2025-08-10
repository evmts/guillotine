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

/// Metadata about a created database for proper cleanup
const DatabaseMetadata = struct {
    database_type: DatabaseType,
    allocation_ptr: *anyopaque,

    /// Size of the allocated database struct for proper deallocation
    allocation_size: usize,
};

/// Storage for database metadata to enable proper cleanup
var database_metadata_map: ?std.AutoHashMap(*anyopaque, DatabaseMetadata) = null;

/// Initialize the metadata map (called automatically when needed)
fn ensure_metadata_map_initialized(allocator: std.mem.Allocator) !void {
    if (database_metadata_map == null) {
        database_metadata_map = std.AutoHashMap(*anyopaque, DatabaseMetadata).init(allocator);
    }
}

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
    try ensure_metadata_map_initialized(allocator);

    switch (config) {
        .Memory => {
            // Allocate memory database on heap
            const memory_db = try allocator.create(MemoryDatabase);
            memory_db.* = MemoryDatabase.init(allocator);

            // Store metadata for cleanup
            const metadata = DatabaseMetadata{
                .database_type = .Memory,
                .allocation_ptr = memory_db,
                .allocation_size = @sizeOf(MemoryDatabase),
            };
            if (database_metadata_map) |*map| {
                try map.put(memory_db, metadata);
            }

            return memory_db.to_database_interface();
        },
    }
}

/// Destroy a database created by create_database
///
/// ## Parameters
/// - `allocator`: The same allocator used to create the database
/// - `database`: Database interface to destroy
///
/// ## Important
/// This function must be called to properly clean up database resources.
/// The database interface becomes invalid after this call.
///
/// ## Example
/// ```zig
/// const db = try create_database(allocator, config);
/// defer destroy_database(allocator, db);
/// ```
pub fn destroy_database(allocator: std.mem.Allocator, database: DatabaseInterface) void {
    // Call the database's deinit method
    database.deinit();

    // Look up metadata for proper deallocation
    if (database_metadata_map) |*map| {
        if (map.get(database.ptr)) |metadata| {
            // Remove from metadata map
            _ = map.remove(database.ptr);

            // Deallocate based on original type
            switch (metadata.database_type) {
                .Memory => {
                    const memory_db: *MemoryDatabase = @ptrCast(@alignCast(metadata.allocation_ptr));
                    allocator.destroy(memory_db);
                },

                // Future database type cleanup:
                // .Fork => {
                //     const fork_db: *ForkDatabase = @ptrCast(@alignCast(metadata.allocation_ptr));
                //     allocator.destroy(fork_db);
                // },
                // .File => {
                //     const file_db: *FileDatabase = @ptrCast(@alignCast(metadata.allocation_ptr));
                //     allocator.destroy(file_db);
                // },
                // .Cached => {
                //     const cached_db: *CachedDatabase = @ptrCast(@alignCast(metadata.allocation_ptr));
                //     allocator.destroy(cached_db);
                // },
            }
        }
    }
}

/// Get the type of a database interface
///
/// ## Parameters
/// - `database`: Database interface to inspect
///
/// ## Returns
/// DatabaseType if the database was created through this factory, null otherwise
pub fn get_database_type(database: DatabaseInterface) ?DatabaseType {
    if (database_metadata_map) |*map| {
        if (map.get(database.ptr)) |metadata| {
            return metadata.database_type;
        }
    }
    return null;
}

/// Clean up factory resources
///
/// Call this when shutting down to clean up internal factory state.
/// Only needed if you've created databases through this factory.
pub fn deinit_factory() void {
    if (database_metadata_map) |*map| {
        map.deinit();
        database_metadata_map = null;
    }
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
