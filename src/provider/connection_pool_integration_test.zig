const std = @import("std");
const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
const PoolConfig = @import("connection_pool.zig").PoolConfig;

test "connection pool prevents connection leaks" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Acquire and release connections multiple times
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        const client = try pool.acquire();
        pool.release(client);
    }

    // Should only have created 1 connection that was reused
    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
}

test "connection pool cleanup task simulation" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 100,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Create burst of connections
    var clients: [5]*std.http.Client = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        clients[i] = try pool.acquire();
    }

    // Release all
    i = 0;
    while (i < 5) : (i += 1) {
        pool.release(clients[i]);
    }

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 5), stats.total);
    try std.testing.expectEqual(@as(usize, 5), stats.idle);

    // Wait for idle timeout
    std.Thread.sleep(150 * std.time.ns_per_ms);

    // Cleanup should remove all idle connections
    try pool.cleanup_idle();

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
}

test "connection pool handles concurrent burst traffic" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Simulate burst: acquire 8, use, release
    var clients: [8]*std.http.Client = undefined;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        clients[i] = try pool.acquire();
    }

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 8), stats.active);

    // Release all
    i = 0;
    while (i < 8) : (i += 1) {
        pool.release(clients[i]);
    }

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 8), stats.idle);
}

test "connection pool reuses connections efficiently" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 3,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // First batch: create 3 connections
    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    const c3 = try pool.acquire();

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);

    // Release all
    pool.release(c1);
    pool.release(c2);
    pool.release(c3);

    // Second batch: should reuse same 3 connections
    const c4 = try pool.acquire();
    const c5 = try pool.acquire();
    const c6 = try pool.acquire();

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);

    // Verify we got the same connections (pointer equality)
    try std.testing.expect(c1 == c4 or c1 == c5 or c1 == c6);

    pool.release(c4);
    pool.release(c5);
    pool.release(c6);
}

test "connection pool enforces max connections with waiting" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 2,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 50,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    const c1 = try pool.acquire();
    const c2 = try pool.acquire();

    // Third acquire should fail due to timeout
    const result = pool.acquire();
    try std.testing.expectError(error.PoolExhausted, result);

    // Release one connection
    pool.release(c1);

    // Now acquire should succeed
    const c3 = try pool.acquire();
    try std.testing.expect(c3 == c1);

    pool.release(c2);
    pool.release(c3);
}
