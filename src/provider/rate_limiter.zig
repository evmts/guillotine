const std = @import("std");

/// Token bucket rate limiter for controlling request rates
///
/// Implements the token bucket algorithm with configurable rate and burst capacity:
/// - Tokens are added at a constant rate (tokens_per_second)
/// - Up to max_tokens can be accumulated (burst capacity)
/// - Each request consumes one token
/// - Requests block when no tokens are available
///
/// Thread-safe for concurrent access via mutex.
pub const RateLimiter = struct {
    /// Maximum number of tokens (burst capacity)
    max_tokens: u64,

    /// Rate at which tokens are added (per second)
    tokens_per_second: u64,

    /// Current token count (fractional tokens stored as nanosecond precision)
    current_tokens: u64,

    /// Last time tokens were added
    last_refill: i128,

    /// Mutex for thread-safe access
    mutex: std.Thread.Mutex,

    /// Configuration for rate limiter
    pub const Config = struct {
        /// Maximum burst size (default: 20 requests)
        max_tokens: u64 = 20,

        /// Requests per second (default: 10 requests/sec)
        tokens_per_second: u64 = 10,
    };

    pub const Error = error{
        RateLimitExceeded,
        InvalidConfiguration,
    };

    /// Initialize a new rate limiter with the given configuration
    pub fn init(config: Config) Error!RateLimiter {
        if (config.max_tokens == 0) {
            return Error.InvalidConfiguration;
        }
        if (config.tokens_per_second == 0) {
            return Error.InvalidConfiguration;
        }

        return RateLimiter{
            .max_tokens = config.max_tokens,
            .tokens_per_second = config.tokens_per_second,
            .current_tokens = config.max_tokens,
            .last_refill = std.time.nanoTimestamp(),
            .mutex = std.Thread.Mutex{},
        };
    }

    /// Try to acquire a token without blocking
    /// Returns true if token was acquired, false if rate limit would be exceeded
    pub fn tryAcquire(self: *RateLimiter) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refillTokens();

        if (self.current_tokens >= 1) {
            self.current_tokens -= 1;
            return true;
        }

        return false;
    }

    /// Acquire a token, blocking if necessary
    /// Returns error.RateLimitExceeded if token cannot be acquired
    pub fn acquire(self: *RateLimiter) Error!void {
        if (!self.tryAcquire()) {
            return Error.RateLimitExceeded;
        }
    }

    /// Wait and acquire a token, sleeping until one is available
    /// This method will spin-wait with small sleeps until a token is available
    pub fn waitAndAcquire(self: *RateLimiter) void {
        while (!self.tryAcquire()) {
            // Calculate sleep time based on token refill rate
            const nanos_per_token = std.time.ns_per_s / self.tokens_per_second;
            // Sleep for slightly longer than one token's worth of time
            const sleep_nanos = nanos_per_token + (nanos_per_token / 10);
            std.posix.nanosleep(0, sleep_nanos);
        }
    }

    /// Refill tokens based on elapsed time since last refill
    /// Must be called with mutex held
    fn refillTokens(self: *RateLimiter) void {
        const now = std.time.nanoTimestamp();
        const elapsed = now - self.last_refill;

        if (elapsed <= 0) {
            return;
        }

        // Calculate tokens to add based on elapsed time
        // tokens = (elapsed_nanos / nanos_per_second) * tokens_per_second
        const nanos_per_second: i128 = std.time.ns_per_s;
        const tokens_to_add_i128 = @divFloor(elapsed * @as(i128, @intCast(self.tokens_per_second)), nanos_per_second);

        if (tokens_to_add_i128 > 0) {
            const tokens_to_add: u64 = @intCast(tokens_to_add_i128);
            self.current_tokens = @min(self.max_tokens, self.current_tokens + tokens_to_add);
            self.last_refill = now;
        }
    }

    /// Reset the rate limiter to full capacity
    pub fn reset(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.current_tokens = self.max_tokens;
        self.last_refill = std.time.nanoTimestamp();
    }

    /// Get current available tokens (for testing/monitoring)
    pub fn getAvailableTokens(self: *RateLimiter) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.refillTokens();
        return self.current_tokens;
    }
};

// Tests
test "RateLimiter initialization" {
    const limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 5,
    });
    try std.testing.expectEqual(@as(u64, 10), limiter.max_tokens);
    try std.testing.expectEqual(@as(u64, 5), limiter.tokens_per_second);
    try std.testing.expectEqual(@as(u64, 10), limiter.current_tokens);
}

test "RateLimiter default configuration" {
    const limiter = try RateLimiter.init(.{});
    try std.testing.expectEqual(@as(u64, 20), limiter.max_tokens);
    try std.testing.expectEqual(@as(u64, 10), limiter.tokens_per_second);
}

test "RateLimiter invalid configuration - zero max tokens" {
    const result = RateLimiter.init(.{
        .max_tokens = 0,
        .tokens_per_second = 10,
    });
    try std.testing.expectError(error.InvalidConfiguration, result);
}

test "RateLimiter invalid configuration - zero tokens per second" {
    const result = RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 0,
    });
    try std.testing.expectError(error.InvalidConfiguration, result);
}

test "RateLimiter tryAcquire success" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 5,
        .tokens_per_second = 10,
    });

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expectEqual(@as(u64, 4), limiter.current_tokens);
}

test "RateLimiter tryAcquire exhaustion" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 3,
        .tokens_per_second = 10,
    });

    // Acquire all tokens
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(limiter.tryAcquire());

    // Should fail now
    try std.testing.expect(!limiter.tryAcquire());
}

test "RateLimiter acquire success" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 5,
        .tokens_per_second = 10,
    });

    try limiter.acquire();
    try std.testing.expectEqual(@as(u64, 4), limiter.current_tokens);
}

test "RateLimiter acquire fails when exhausted" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 2,
        .tokens_per_second = 10,
    });

    try limiter.acquire();
    try limiter.acquire();

    const result = limiter.acquire();
    try std.testing.expectError(error.RateLimitExceeded, result);
}

test "RateLimiter burst capacity" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 5,
    });

    // Should be able to burst up to max_tokens
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Next one should fail
    try std.testing.expect(!limiter.tryAcquire());
}

test "RateLimiter token refill" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 5, // 5 tokens per second
    });

    // Consume all tokens
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Sleep for 1 second to allow refill (5 tokens should be added)
    std.posix.nanosleep(1, 0);

    // Should be able to acquire 5 more tokens
    i = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }

    // Next one should fail
    try std.testing.expect(!limiter.tryAcquire());
}

test "RateLimiter refill respects max tokens" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 5,
        .tokens_per_second = 10,
    });

    // Don't consume any tokens, just wait
    std.posix.nanosleep(1, 0);

    // Should still be at max, not exceeded
    try std.testing.expectEqual(@as(u64, 5), limiter.getAvailableTokens());
}

test "RateLimiter reset" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 5,
        .tokens_per_second = 10,
    });

    // Consume all tokens
    var i: u64 = 0;
    while (i < 5) : (i += 1) {
        try limiter.acquire();
    }

    try std.testing.expectEqual(@as(u64, 0), limiter.current_tokens);

    // Reset should restore all tokens
    limiter.reset();
    try std.testing.expectEqual(@as(u64, 5), limiter.current_tokens);
}

test "RateLimiter getAvailableTokens" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 5,
    });

    try std.testing.expectEqual(@as(u64, 10), limiter.getAvailableTokens());

    try limiter.acquire();
    try std.testing.expectEqual(@as(u64, 9), limiter.getAvailableTokens());
}

test "RateLimiter concurrent access" {
    const ThreadContext = struct {
        limiter: *RateLimiter,
        success_count: *std.atomic.Value(u32),

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                if (ctx.limiter.tryAcquire()) {
                    _ = ctx.success_count.fetchAdd(1, .monotonic);
                }
                std.posix.nanosleep(0, 10 * std.time.ns_per_ms);
            }
        }
    };

    var limiter = try RateLimiter.init(.{
        .max_tokens = 20,
        .tokens_per_second = 100,
    });

    var success_count = std.atomic.Value(u32).init(0);
    var context = ThreadContext{
        .limiter = &limiter,
        .success_count = &success_count,
    };

    // Spawn multiple threads
    const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
    const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});

    thread1.join();
    thread2.join();

    // Should have acquired some tokens from concurrent access
    const final_count = success_count.load(.monotonic);
    try std.testing.expect(final_count > 0);
    try std.testing.expect(final_count <= 20);
}

test "RateLimiter waitAndAcquire" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 2,
        .tokens_per_second = 10, // 10 tokens/sec = 100ms per token
    });

    // Consume all tokens
    try limiter.acquire();
    try limiter.acquire();

    const start = std.time.nanoTimestamp();

    // This should wait for a token to become available
    limiter.waitAndAcquire();

    const elapsed = std.time.nanoTimestamp() - start;

    // Should have waited at least 90ms (with 10ms tolerance)
    try std.testing.expect(elapsed >= 90 * std.time.ns_per_ms);
}

test "RateLimiter high throughput rate" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 100,
        .tokens_per_second = 100,
    });

    // Should be able to burst 100 requests immediately
    var i: u64 = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(limiter.tryAcquire());
    }
}

test "RateLimiter low rate limit" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 1,
        .tokens_per_second = 1,
    });

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire());

    // Wait for 1 second
    std.posix.nanosleep(1, 0);

    // Should be able to acquire one more
    try std.testing.expect(limiter.tryAcquire());
}

test "RateLimiter fractional token accumulation" {
    var limiter = try RateLimiter.init(.{
        .max_tokens = 10,
        .tokens_per_second = 2, // 2 tokens per second = 0.5 seconds per token
    });

    // Consume all tokens
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try limiter.acquire();
    }

    // Wait for 0.5 seconds (should refill 1 token)
    std.posix.nanosleep(0, std.time.ns_per_s / 2);

    try std.testing.expect(limiter.tryAcquire());
    try std.testing.expect(!limiter.tryAcquire());
}
