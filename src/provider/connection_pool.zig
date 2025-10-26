//! Connection pooling for HTTP RPC providers
//!
//! Provides reusable HTTP client connections with configurable limits,
//! idle timeout, and thread safety. Prevents connection leaks and
//! improves performance by reusing established connections.
//!
//! IMPORTANT: Connection pointers returned by acquire() may become invalid
//! after calling cleanup_idle() if the cleanup removes connections from
//! the pool. Always release connections before calling cleanup, or avoid
//! holding connection pointers across cleanup calls.

const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.connection_pool);

/// Connection pool configuration
pub const PoolConfig = struct {
    max_connections: usize = 10,
    idle_timeout_ms: u64 = 30000, // 30 seconds
    acquire_timeout_ms: u64 = 5000, // 5 seconds
};

/// Pooled HTTP connection wrapper
pub const PooledConnection = struct {
    client: std.http.Client,
    last_used: i64,
    in_use: bool,

    pub fn init(allocator: Allocator) PooledConnection {
        return .{
            .client = std.http.Client{ .allocator = allocator },
            .last_used = std.time.milliTimestamp(),
            .in_use = false,
        };
    }

    pub fn deinit(self: *PooledConnection) void {
        self.client.deinit();
    }

    pub fn is_idle_expired(self: *const PooledConnection, timeout_ms: u64) bool {
        const now = std.time.milliTimestamp();
        const elapsed = @as(u64, @intCast(now - self.last_used));
        return !self.in_use and elapsed > timeout_ms;
    }

    pub fn mark_used(self: *PooledConnection) void {
        self.in_use = true;
        self.last_used = std.time.milliTimestamp();
    }

    pub fn mark_available(self: *PooledConnection) void {
        self.in_use = false;
        self.last_used = std.time.milliTimestamp();
    }
};

/// Thread-safe HTTP connection pool
pub const ConnectionPool = struct {
    allocator: Allocator,
    connections: std.ArrayList(PooledConnection),
    config: PoolConfig,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, config: PoolConfig) Self {
        var connections = std.ArrayList(PooledConnection){};
        // Pre-allocate to prevent reallocation and pointer invalidation
        connections.ensureTotalCapacity(allocator, config.max_connections) catch |err| {
            log.warn("Failed to pre-allocate connection pool capacity ({d}): {s}. Pool will reallocate as needed.", .{ config.max_connections, @errorName(err) });
        };
        return .{
            .allocator = allocator,
            .connections = connections,
            .config = config,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*conn| {
            conn.deinit();
        }
        self.connections.deinit(self.allocator);
    }

    /// Acquire a connection from the pool
    /// Returns error if pool is exhausted and timeout is reached
    pub fn acquire(self: *Self) !*std.http.Client {
        const start_time = std.time.milliTimestamp();

        while (true) {
            self.mutex.lock();

            // Try to find an available connection
            for (self.connections.items) |*conn| {
                if (!conn.in_use) {
                    conn.mark_used();
                    self.mutex.unlock();
                    return &conn.client;
                }
            }

            // Create new connection if under limit
            if (self.connections.items.len < self.config.max_connections) {
                var new_conn = PooledConnection.init(self.allocator);
                new_conn.mark_used();
                try self.connections.append(self.allocator, new_conn);
                const client = &self.connections.items[self.connections.items.len - 1].client;
                self.mutex.unlock();
                return client;
            }

            // Check timeout
            const now = std.time.milliTimestamp();
            const elapsed = @as(u64, @intCast(now - start_time));
            if (elapsed > self.config.acquire_timeout_ms) {
                self.mutex.unlock();
                return error.PoolExhausted;
            }

            // Release mutex and sleep briefly before retry
            self.mutex.unlock();
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }

    /// Release a connection back to the pool
    pub fn release(self: *Self, client: *std.http.Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.connections.items) |*conn| {
            if (&conn.client == client) {
                conn.mark_available();
                return;
            }
        }
    }

    /// Clean up idle connections that have exceeded timeout
    pub fn cleanup_idle(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.connections.items.len) {
            if (self.connections.items[i].is_idle_expired(self.config.idle_timeout_ms)) {
                var conn = self.connections.swapRemove(i);
                conn.deinit();
                // Don't increment i, as we removed an item (and swapped last into this position)
            } else {
                i += 1;
            }
        }
    }

    /// Get current pool statistics
    pub fn get_stats(self: *Self) PoolStats {
        self.mutex.lock();
        defer self.mutex.unlock();

        var active: usize = 0;
        var idle: usize = 0;

        for (self.connections.items) |*conn| {
            if (conn.in_use) {
                active += 1;
            } else {
                idle += 1;
            }
        }

        return PoolStats{
            .total = self.connections.items.len,
            .active = active,
            .idle = idle,
            .max = self.config.max_connections,
        };
    }
};

pub const PoolStats = struct {
    total: usize,
    active: usize,
    idle: usize,
    max: usize,
};

// Tests
test "connection pool init and deinit" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 5), stats.max);
}

test "connection pool acquire creates new connection" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    _ = try pool.acquire();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.active);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);
}

test "connection pool release marks connection available" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client = try pool.acquire();

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.active);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);

    pool.release(client);

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
}

test "connection pool reuses released connections" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    pool.release(client1);

    const client2 = try pool.acquire();
    try std.testing.expect(client1 == client2);

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
}

test "connection pool respects max connections" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 2,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    const client2 = try pool.acquire();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 2), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.active);

    // Third acquire should timeout
    const result = pool.acquire();
    try std.testing.expectError(error.PoolExhausted, result);

    // Release one and acquire should work
    pool.release(client1);
    const client3 = try pool.acquire();

    pool.release(client2);
    pool.release(client3);
}

test "connection pool cleanup removes idle connections" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 50, // Very short timeout
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    const client2 = try pool.acquire();

    pool.release(client1);
    pool.release(client2);

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 2), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.idle);

    // Wait for connections to become idle
    std.Thread.sleep(60 * std.time.ns_per_ms);

    try pool.cleanup_idle();

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
}

test "connection pool idle expiration check" {
    const allocator = std.testing.allocator;

    var conn = PooledConnection.init(allocator);
    defer conn.deinit();

    // Fresh connection should not be expired
    try std.testing.expect(!conn.is_idle_expired(1000));

    // Mark as used and wait
    conn.mark_used();
    conn.mark_available();

    // Should still not be expired immediately
    try std.testing.expect(!conn.is_idle_expired(1000));

    // Wait and check again
    std.Thread.sleep(60 * std.time.ns_per_ms);
    try std.testing.expect(conn.is_idle_expired(50));
}

test "connection pool multiple acquire and release" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 3,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    var clients = [_]*std.http.Client{undefined} ** 3;

    // Acquire all
    for (&clients) |*client| {
        client.* = try pool.acquire();
    }

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.active);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);

    // Release all
    for (clients) |client| {
        pool.release(client);
    }

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 3), stats.idle);
}

test "connection pool stats accuracy" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    const client2 = try pool.acquire();
    const client3 = try pool.acquire();

    pool.release(client1);

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.active);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
    try std.testing.expectEqual(@as(usize, 10), stats.max);

    pool.release(client2);
    pool.release(client3);
}

test "connection pool default config" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{};

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 10), pool.config.max_connections);
    try std.testing.expectEqual(@as(u64, 30000), pool.config.idle_timeout_ms);
    try std.testing.expectEqual(@as(u64, 5000), pool.config.acquire_timeout_ms);
}

test "connection pool custom config" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 20,
        .idle_timeout_ms = 60000,
        .acquire_timeout_ms = 10000,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    try std.testing.expectEqual(@as(usize, 20), pool.config.max_connections);
    try std.testing.expectEqual(@as(u64, 60000), pool.config.idle_timeout_ms);
    try std.testing.expectEqual(@as(u64, 10000), pool.config.acquire_timeout_ms);
}

test "connection pool acquire after cleanup" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 50,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    pool.release(client1);

    std.Thread.sleep(60 * std.time.ns_per_ms);
    try pool.cleanup_idle();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);

    // Should be able to acquire again
    const client2 = try pool.acquire();

    pool.release(client2);
}

test "connection pool zero idle after all active" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    const client2 = try pool.acquire();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 2), stats.active);
    try std.testing.expectEqual(@as(usize, 0), stats.idle);

    pool.release(client1);
    pool.release(client2);
}

test "connection pool partial cleanup" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 50,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client1 = try pool.acquire();
    pool.release(client1);

    std.Thread.sleep(60 * std.time.ns_per_ms);

    const client2 = try pool.acquire();
    pool.release(client2);

    // client1 should be expired, client2 should not be
    try pool.cleanup_idle();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
}

test "connection pool in_use flag prevents cleanup" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 50,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const client = try pool.acquire();

    std.Thread.sleep(60 * std.time.ns_per_ms);

    // Connection is in use, should not be cleaned up
    try pool.cleanup_idle();

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.active);

    pool.release(client);
}
