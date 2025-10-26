const std = @import("std");
const ConnectionPool = @import("connection_pool.zig").ConnectionPool;
const PoolConfig = @import("connection_pool.zig").PoolConfig;

test "connection pool has no memory leaks with repeated acquire/release cycles" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Run many cycles of acquire/release
    var cycle: usize = 0;
    while (cycle < 100) : (cycle += 1) {
        const client = try pool.acquire();
        pool.release(client);
    }

    // All connections should be released and only 1 created
    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 1), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 1), stats.idle);
}

test "connection pool properly cleans up all connections on deinit" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);

    // Create multiple connections
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

    // deinit should clean up all connections without leaking
    pool.deinit();
}

test "connection pool cleanup removes all idle connections without leaking" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 10,
        .idle_timeout_ms = 50,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Create and release multiple connections
    var clients: [7]*std.http.Client = undefined;
    var i: usize = 0;
    while (i < 7) : (i += 1) {
        clients[i] = try pool.acquire();
    }

    i = 0;
    while (i < 7) : (i += 1) {
        pool.release(clients[i]);
    }

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 7), stats.total);

    // Wait for idle timeout
    std.Thread.sleep(60 * std.time.ns_per_ms);

    // Cleanup should free all connections properly
    try pool.cleanup_idle();

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 0), stats.total);
}

test "connection pool handles acquire/release without cleanup" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 5,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Acquire 3, release 2, keep 1 active
    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    const c3 = try pool.acquire();

    pool.release(c1);
    pool.release(c2);

    var stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 1), stats.active);
    try std.testing.expectEqual(@as(usize, 2), stats.idle);

    // Release remaining connection
    pool.release(c3);

    stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 3), stats.idle);
}

test "connection pool no leaks with max connections reached" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 3,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 50,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Fill the pool
    const c1 = try pool.acquire();
    const c2 = try pool.acquire();
    const c3 = try pool.acquire();

    // Try to over-acquire (should fail gracefully)
    const result = pool.acquire();
    try std.testing.expectError(error.PoolExhausted, result);

    // Release and verify no leaks
    pool.release(c1);
    pool.release(c2);
    pool.release(c3);

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
}

test "connection pool no leaks with rapid acquire/release" {
    const allocator = std.testing.allocator;

    const config = PoolConfig{
        .max_connections = 2,
        .idle_timeout_ms = 1000,
        .acquire_timeout_ms = 100,
    };

    var pool = ConnectionPool.init(allocator, config);
    defer pool.deinit();

    // Rapid fire acquire/release
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const c1 = try pool.acquire();
        const c2 = try pool.acquire();
        pool.release(c1);
        pool.release(c2);
    }

    const stats = pool.get_stats();
    try std.testing.expectEqual(@as(usize, 2), stats.total);
    try std.testing.expectEqual(@as(usize, 0), stats.active);
    try std.testing.expectEqual(@as(usize, 2), stats.idle);
}
