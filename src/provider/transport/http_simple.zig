const std = @import("std");
const http = std.http;
const Allocator = std.mem.Allocator;
const RateLimiter = @import("../rate_limiter.zig").RateLimiter;
// Define transport errors locally since we removed the errors.zig file
const TransportError = error{
    NetworkError,
    Timeout,
    InvalidResponse,
    InvalidRequest,
    OutOfMemory,
    ConnectionFailed,
    TlsError,
    AuthenticationFailed,
    RateLimitExceeded,
};
const json_rpc = @import("json_rpc.zig");

pub const HttpTransport = struct {
    allocator: Allocator,
    client: http.Client,
    url: []const u8,
    user_agent: []const u8,
    request_timeout_ms: u32,
    connection_timeout_ms: u32,
    max_retries: u8,
    retry_delay_ms: u32,
    request_id: std.atomic.Value(u64),
    rate_limiter: ?RateLimiter,

    pub fn init(allocator: Allocator, url: []const u8) !HttpTransport {
        var client = http.Client{ .allocator = allocator };
        client.connection_pool.timeout_ns = 30 * std.time.ns_per_s;

        return HttpTransport{
            .allocator = allocator,
            .client = client,
            .url = try allocator.dupe(u8, url),
            .user_agent = "Guillotine-Provider/1.0",
            .request_timeout_ms = 30000,
            .connection_timeout_ms = 10000,
            .max_retries = 3,
            .retry_delay_ms = 1000,
            .request_id = std.atomic.Value(u64).init(1),
            .rate_limiter = null,
        };
    }

    pub fn init_with_config(allocator: Allocator, url: []const u8, timeout_ms: u32, connection_timeout_ms: u32, max_retries: u8, retry_delay_ms: u32) !HttpTransport {
        var client = http.Client{ .allocator = allocator };
        client.connection_pool.timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;

        return HttpTransport{
            .allocator = allocator,
            .client = client,
            .url = try allocator.dupe(u8, url),
            .user_agent = "Guillotine-Provider/1.0",
            .request_timeout_ms = timeout_ms,
            .connection_timeout_ms = connection_timeout_ms,
            .max_retries = max_retries,
            .retry_delay_ms = retry_delay_ms,
            .request_id = std.atomic.Value(u64).init(1),
            .rate_limiter = null,
        };
    }

    pub fn init_with_rate_limiter(
        allocator: Allocator,
        url: []const u8,
        timeout_ms: u32,
        connection_timeout_ms: u32,
        max_retries: u8,
        retry_delay_ms: u32,
        rate_limit_per_second: u32,
        burst_size: u32,
    ) !HttpTransport {
        var client = http.Client{ .allocator = allocator };
        client.connection_pool.timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;

        const limiter = try RateLimiter.init(.{
            .tokens_per_second = @as(u64, rate_limit_per_second),
            .max_tokens = @as(u64, burst_size),
        });

        return HttpTransport{
            .allocator = allocator,
            .client = client,
            .url = try allocator.dupe(u8, url),
            .user_agent = "Guillotine-Provider/1.0",
            .request_timeout_ms = timeout_ms,
            .connection_timeout_ms = connection_timeout_ms,
            .max_retries = max_retries,
            .retry_delay_ms = retry_delay_ms,
            .request_id = std.atomic.Value(u64).init(1),
            .rate_limiter = limiter,
        };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
        self.allocator.free(self.url);
    }

    pub fn request(self: *HttpTransport, method: []const u8, params: []const u8) TransportError!json_rpc.JsonRpcResponse {
        var retries_remaining = self.max_retries;
        var current_retry: u8 = 0;

        while (true) {
            if (self.rate_limiter) |*limiter| {
                limiter.waitAndAcquire();
            }

            const result = self.request_once(method, params);

            if (result) |response| {
                return response;
            } else |err| switch (err) {
                TransportError.RateLimitExceeded => {
                    if (retries_remaining == 0) {
                        return err;
                    }
                    retries_remaining -= 1;
                    current_retry += 1;
                    const delay_ms = self.retry_delay_ms * (@as(u32, 1) << @as(u5, @intCast(current_retry - 1)));
                    std.posix.nanosleep(0, delay_ms * std.time.ns_per_ms);
                },
                else => {
                    const is_transient = self.is_transient_error(err);
                    if (!is_transient or retries_remaining == 0) {
                        return err;
                    }
                    retries_remaining -= 1;
                    current_retry += 1;
                    const delay_ms = self.retry_delay_ms * (@as(u32, 1) << @as(u5, @intCast(current_retry - 1)));
                    std.posix.nanosleep(0, delay_ms * std.time.ns_per_ms);
                },
            }
        }
    }

    fn request_once(self: *HttpTransport, method: []const u8, params: []const u8) TransportError!json_rpc.JsonRpcResponse {
        const req = json_rpc.JsonRpcRequest{
            .method = method,
            .params = params,
            .id = self.generate_request_id(),
        };

        const json_payload = req.to_json(self.allocator) catch |err| switch (err) {
            error.OutOfMemory => return TransportError.OutOfMemory,
        };
        defer self.allocator.free(json_payload);

        var response_buffer = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer response_buffer.deinit();

        const response = self.client.fetch(.{
            .method = .POST,
            .location = .{ .url = self.url },
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = self.user_agent },
            },
            .payload = json_payload,
            .response_storage = .{ .dynamic = &response_buffer },
            .max_append_size = 10 * 1024 * 1024,
        }) catch |err| {
            return switch (err) {
                error.ConnectionRefused => TransportError.ConnectionFailed,
                error.ConnectionTimedOut => TransportError.Timeout,
                error.TlsInitializationFailed => TransportError.TlsError,
                error.TlsFailure => TransportError.TlsError,
                error.OutOfMemory => TransportError.OutOfMemory,
                else => TransportError.NetworkError,
            };
        };

        if (response.status == .too_many_requests) {
            return TransportError.RateLimitExceeded;
        }

        if (response.status.class() != .success) {
            return TransportError.NetworkError;
        }

        return json_rpc.JsonRpcResponse.from_json(self.allocator, response_buffer.items) catch |err| switch (err) {
            error.OutOfMemory => TransportError.OutOfMemory,
            else => TransportError.InvalidResponse,
        };
    }

    fn is_transient_error(self: *HttpTransport, err: TransportError) bool {
        _ = self;
        return switch (err) {
            TransportError.NetworkError => true,
            TransportError.Timeout => true,
            TransportError.ConnectionFailed => true,
            TransportError.RateLimitExceeded => true,
            TransportError.InvalidResponse => false,
            TransportError.InvalidRequest => false,
            TransportError.OutOfMemory => false,
            TransportError.TlsError => true,
            TransportError.AuthenticationFailed => false,
        };
    }

    fn generate_request_id(self: *HttpTransport) u64 {
        return self.request_id.fetchAdd(1, .monotonic);
    }

    pub fn is_connected(self: HttpTransport) bool {
        _ = self;
        return true; // HTTP is stateless
    }

    pub fn get_type(self: HttpTransport) []const u8 {
        _ = self;
        return "http";
    }
};

test "HttpTransport init with defaults" {
    const allocator = std.testing.allocator;
    const url = "https://mainnet.infura.io/v3/test";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    try std.testing.expectEqualStrings(url, transport.url);
    try std.testing.expectEqual(@as(u32, 30000), transport.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 10000), transport.connection_timeout_ms);
    try std.testing.expectEqual(@as(u8, 3), transport.max_retries);
    try std.testing.expectEqual(@as(u32, 1000), transport.retry_delay_ms);
}

test "HttpTransport init_with_config custom values" {
    const allocator = std.testing.allocator;
    const url = "https://mainnet.infura.io/v3/test";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        60000,
        15000,
        5,
        2000,
    );
    defer transport.deinit();

    try std.testing.expectEqualStrings(url, transport.url);
    try std.testing.expectEqual(@as(u32, 60000), transport.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 15000), transport.connection_timeout_ms);
    try std.testing.expectEqual(@as(u8, 5), transport.max_retries);
    try std.testing.expectEqual(@as(u32, 2000), transport.retry_delay_ms);
}

test "HttpTransport is_transient_error detects transient errors" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    try std.testing.expect(transport.is_transient_error(TransportError.NetworkError));
    try std.testing.expect(transport.is_transient_error(TransportError.Timeout));
    try std.testing.expect(transport.is_transient_error(TransportError.ConnectionFailed));
    try std.testing.expect(transport.is_transient_error(TransportError.TlsError));
}

test "HttpTransport is_transient_error detects non-transient errors" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    try std.testing.expect(!transport.is_transient_error(TransportError.InvalidResponse));
    try std.testing.expect(!transport.is_transient_error(TransportError.InvalidRequest));
    try std.testing.expect(!transport.is_transient_error(TransportError.OutOfMemory));
    try std.testing.expect(!transport.is_transient_error(TransportError.AuthenticationFailed));
}

test "HttpTransport generate_request_id increments atomically" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    const id1 = transport.generate_request_id();
    const id2 = transport.generate_request_id();
    const id3 = transport.generate_request_id();

    try std.testing.expectEqual(@as(u64, 1), id1);
    try std.testing.expectEqual(@as(u64, 2), id2);
    try std.testing.expectEqual(@as(u64, 3), id3);
}

test "HttpTransport exponential backoff calculation" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        10000,
        5,
        1000,
    );
    defer transport.deinit();

    const base_delay = transport.retry_delay_ms;

    const delay1 = base_delay * (@as(u32, 1) << @as(u5, 0));
    const delay2 = base_delay * (@as(u32, 1) << @as(u5, 1));
    const delay3 = base_delay * (@as(u32, 1) << @as(u5, 2));
    const delay4 = base_delay * (@as(u32, 1) << @as(u5, 3));

    try std.testing.expectEqual(@as(u32, 1000), delay1);
    try std.testing.expectEqual(@as(u32, 2000), delay2);
    try std.testing.expectEqual(@as(u32, 4000), delay3);
    try std.testing.expectEqual(@as(u32, 8000), delay4);
}

test "HttpTransport max_retries zero means no retries" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        10000,
        0,
        1000,
    );
    defer transport.deinit();

    try std.testing.expectEqual(@as(u8, 0), transport.max_retries);
}

test "HttpTransport connection_timeout_ms configurable" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport1 = try HttpTransport.init(allocator, url);
    defer transport1.deinit();
    try std.testing.expectEqual(@as(u32, 10000), transport1.connection_timeout_ms);

    var transport2 = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        5000,
        3,
        1000,
    );
    defer transport2.deinit();
    try std.testing.expectEqual(@as(u32, 5000), transport2.connection_timeout_ms);
}

test "HttpTransport request_timeout_ms configurable" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport1 = try HttpTransport.init(allocator, url);
    defer transport1.deinit();
    try std.testing.expectEqual(@as(u32, 30000), transport1.request_timeout_ms);

    var transport2 = try HttpTransport.init_with_config(
        allocator,
        url,
        60000,
        10000,
        3,
        1000,
    );
    defer transport2.deinit();
    try std.testing.expectEqual(@as(u32, 60000), transport2.request_timeout_ms);
}

test "HttpTransport retry_delay_ms configurable" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport1 = try HttpTransport.init(allocator, url);
    defer transport1.deinit();
    try std.testing.expectEqual(@as(u32, 1000), transport1.retry_delay_ms);

    var transport2 = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        10000,
        3,
        500,
    );
    defer transport2.deinit();
    try std.testing.expectEqual(@as(u32, 500), transport2.retry_delay_ms);
}

test "HttpTransport is_connected always returns true" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    try std.testing.expect(transport.is_connected());
}

test "HttpTransport get_type returns http" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init(allocator, url);
    defer transport.deinit();

    try std.testing.expectEqualStrings("http", transport.get_type());
}

test "HttpTransport exponential backoff with custom retry delay" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        10000,
        5,
        2000,
    );
    defer transport.deinit();

    const base_delay = transport.retry_delay_ms;

    const delay1 = base_delay * (@as(u32, 1) << @as(u5, 0));
    const delay2 = base_delay * (@as(u32, 1) << @as(u5, 1));
    const delay3 = base_delay * (@as(u32, 1) << @as(u5, 2));

    try std.testing.expectEqual(@as(u32, 2000), delay1);
    try std.testing.expectEqual(@as(u32, 4000), delay2);
    try std.testing.expectEqual(@as(u32, 8000), delay3);
}

test "HttpTransport high max_retries value" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        30000,
        10000,
        10,
        1000,
    );
    defer transport.deinit();

    try std.testing.expectEqual(@as(u8, 10), transport.max_retries);
}

test "HttpTransport all timeout values respect nanosecond conversion" {
    const allocator = std.testing.allocator;
    const url = "https://test.com";

    var transport = try HttpTransport.init_with_config(
        allocator,
        url,
        1000,
        500,
        3,
        100,
    );
    defer transport.deinit();

    try std.testing.expectEqual(@as(u32, 1000), transport.request_timeout_ms);
    try std.testing.expectEqual(@as(u32, 500), transport.connection_timeout_ms);
    try std.testing.expectEqual(@as(u32, 100), transport.retry_delay_ms);

    const timeout_ns = @as(u64, transport.request_timeout_ms) * std.time.ns_per_ms;
    const conn_timeout_ns = @as(u64, transport.connection_timeout_ms) * std.time.ns_per_ms;
    const delay_ns = @as(u64, transport.retry_delay_ms) * std.time.ns_per_ms;

    try std.testing.expectEqual(@as(u64, 1000000000), timeout_ns);
    try std.testing.expectEqual(@as(u64, 500000000), conn_timeout_ns);
    try std.testing.expectEqual(@as(u64, 100000000), delay_ns);
}

test "HttpTransport url properly copied" {
    const allocator = std.testing.allocator;
    const original_url = "https://original.com";

    var transport = try HttpTransport.init(allocator, original_url);
    defer transport.deinit();

    try std.testing.expectEqualStrings(original_url, transport.url);

    try std.testing.expect(transport.url.ptr != original_url.ptr);
}

test "HttpTransport init with rate limiter" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        10,
        20,
    );
    defer transport.deinit();

    try std.testing.expect(transport.rate_limiter != null);
    if (transport.rate_limiter) |limiter| {
        try std.testing.expectEqual(@as(u64, 10), limiter.tokens_per_second);
        try std.testing.expectEqual(@as(u64, 20), limiter.max_tokens);
    }
}

test "HttpTransport rate limiter blocks excessive requests" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        0,
        1000,
        5,
        5,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            try std.testing.expect(limiter.tryAcquire());
        }
        try std.testing.expect(!limiter.tryAcquire());
    }
}

test "HttpTransport 429 status code detection" {
    const status: http.Status = .too_many_requests;
    try std.testing.expectEqual(@as(u16, 429), @intFromEnum(status));
}

test "HttpTransport transient error classification includes rate limit" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init(allocator, "https://test.com");
    defer transport.deinit();

    try std.testing.expect(transport.is_transient_error(TransportError.RateLimitExceeded));
    try std.testing.expect(transport.is_transient_error(TransportError.NetworkError));
    try std.testing.expect(transport.is_transient_error(TransportError.Timeout));
    try std.testing.expect(!transport.is_transient_error(TransportError.InvalidRequest));
}

test "HttpTransport burst capacity allows initial spike" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        5,
        15,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        var i: u32 = 0;
        while (i < 15) : (i += 1) {
            try std.testing.expect(limiter.tryAcquire());
        }
        try std.testing.expect(!limiter.tryAcquire());
    }
}

test "HttpTransport rate limiter respects max tokens" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        100,
        10,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        std.posix.nanosleep(1, 0);
        try std.testing.expectEqual(@as(u64, 10), limiter.getAvailableTokens());
    }
}

test "HttpTransport with zero rate limit rejected" {
    const allocator = std.testing.allocator;

    const result = HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        0,
        10,
    );

    try std.testing.expectError(error.InvalidConfiguration, result);
}

test "HttpTransport with zero burst size rejected" {
    const allocator = std.testing.allocator;

    const result = HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        10,
        0,
    );

    try std.testing.expectError(error.InvalidConfiguration, result);
}

test "HttpTransport rate limiter per-host isolation" {
    const allocator = std.testing.allocator;

    var transport1 = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://host1.com",
        30000,
        10000,
        3,
        1000,
        10,
        5,
    );
    defer transport1.deinit();

    var transport2 = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://host2.com",
        30000,
        10000,
        3,
        1000,
        10,
        5,
    );
    defer transport2.deinit();

    if (transport1.rate_limiter) |*limiter1| {
        if (transport2.rate_limiter) |*limiter2| {
            var i: u32 = 0;
            while (i < 5) : (i += 1) {
                try std.testing.expect(limiter1.tryAcquire());
            }

            try std.testing.expect(limiter2.tryAcquire());
            try std.testing.expect(limiter2.tryAcquire());
        }
    }
}

test "HttpTransport high burst rate" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        100,
        100,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            try std.testing.expect(limiter.tryAcquire());
        }
        try std.testing.expect(!limiter.tryAcquire());
    }
}

test "HttpTransport rate limiter refills over time" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        10,
        5,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        var i: u32 = 0;
        while (i < 5) : (i += 1) {
            try std.testing.expect(limiter.tryAcquire());
        }
        try std.testing.expect(!limiter.tryAcquire());

        std.posix.nanosleep(0, std.time.ns_per_s / 2);

        var refilled: u32 = 0;
        while (limiter.tryAcquire()) {
            refilled += 1;
        }
        try std.testing.expect(refilled > 0);
    }
}

test "HttpTransport fractional token accumulation" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        2,
        10,
    );
    defer transport.deinit();

    if (transport.rate_limiter) |*limiter| {
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            try limiter.acquire();
        }

        std.posix.nanosleep(0, std.time.ns_per_s / 2);

        try std.testing.expect(limiter.tryAcquire());
        try std.testing.expect(!limiter.tryAcquire());
    }
}

test "HttpTransport concurrent rate limiting" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_rate_limiter(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
        50,
        100,
    );
    defer transport.deinit();

    const ThreadContext = struct {
        limiter: *RateLimiter,
        success_count: *std.atomic.Value(u32),

        fn worker(ctx: *@This()) void {
            var i: u32 = 0;
            while (i < 10) : (i += 1) {
                if (ctx.limiter.tryAcquire()) {
                    _ = ctx.success_count.fetchAdd(1, .monotonic);
                }
                std.posix.nanosleep(0, 5 * std.time.ns_per_ms);
            }
        }
    };

    if (transport.rate_limiter) |*limiter| {
        var success_count = std.atomic.Value(u32).init(0);
        var context = ThreadContext{
            .limiter = limiter,
            .success_count = &success_count,
        };

        const thread1 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});
        const thread2 = try std.Thread.spawn(.{}, ThreadContext.worker, .{&context});

        thread1.join();
        thread2.join();

        const final_count = success_count.load(.monotonic);
        try std.testing.expect(final_count > 0);
        try std.testing.expect(final_count <= 100);
    }
}

test "HttpTransport default init has no rate limiter" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init(allocator, "https://test.com");
    defer transport.deinit();

    try std.testing.expect(transport.rate_limiter == null);
}

test "HttpTransport init_with_config has no rate limiter" {
    const allocator = std.testing.allocator;
    var transport = try HttpTransport.init_with_config(
        allocator,
        "https://test.com",
        30000,
        10000,
        3,
        1000,
    );
    defer transport.deinit();

    try std.testing.expect(transport.rate_limiter == null);
}
