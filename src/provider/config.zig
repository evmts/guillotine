const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ConfigError = error{
    InvalidUrl,
    InvalidTimeout,
    InvalidConnectTimeout,
    InvalidMaxRetries,
    InvalidPoolSize,
    InvalidRateLimit,
    InvalidBurstSize,
    InvalidRetryDelay,
    InvalidIdleTimeout,
    UrlTooLong,
    OutOfMemory,
};

pub const CustomHeader = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: *const CustomHeader, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const ProviderConfig = struct {
    url: []const u8,
    timeout_ms: u32,
    connect_timeout_ms: u32,
    max_retries: u8,
    retry_delay_ms: u32,
    connection_pool_size: u8,
    connection_idle_timeout_ms: u64,
    connection_acquire_timeout_ms: u64,
    rate_limit_per_second: u32,
    burst_size: u32,
    user_agent: []const u8,
    custom_headers: []CustomHeader,

    pub const DEFAULT_TIMEOUT_MS: u32 = 30000;
    pub const DEFAULT_CONNECT_TIMEOUT_MS: u32 = 10000;
    pub const DEFAULT_MAX_RETRIES: u8 = 3;
    pub const DEFAULT_RETRY_DELAY_MS: u32 = 1000;
    pub const DEFAULT_POOL_SIZE: u8 = 10;
    pub const DEFAULT_IDLE_TIMEOUT_MS: u64 = 30000;
    pub const DEFAULT_ACQUIRE_TIMEOUT_MS: u64 = 5000;
    pub const DEFAULT_RATE_LIMIT: u32 = 10;
    pub const DEFAULT_BURST_SIZE: u32 = 20;
    pub const DEFAULT_USER_AGENT: []const u8 = "Guillotine-Provider/1.0";
    pub const MAX_URL_LENGTH: usize = 2048;
    pub const MIN_POOL_SIZE: u8 = 1;
    pub const MAX_POOL_SIZE: u8 = 100;
    pub const MAX_TIMEOUT_MS: u32 = 300000;
    pub const MIN_TIMEOUT_MS: u32 = 100;
    pub const MAX_RETRIES: u8 = 20;
    pub const MAX_RETRY_DELAY_MS: u32 = 60000;
    pub const MAX_RATE_LIMIT: u32 = 10000;
    pub const MAX_IDLE_TIMEOUT_MS: u64 = 3600000;

    pub fn init(allocator: Allocator, url: []const u8) ConfigError!ProviderConfig {
        try validateUrl(url);

        const url_copy = allocator.dupe(u8, url) catch return ConfigError.OutOfMemory;
        errdefer allocator.free(url_copy);

        const user_agent_copy = allocator.dupe(u8, DEFAULT_USER_AGENT) catch return ConfigError.OutOfMemory;

        const empty_headers = allocator.alloc(CustomHeader, 0) catch return ConfigError.OutOfMemory;

        return ProviderConfig{
            .url = url_copy,
            .timeout_ms = DEFAULT_TIMEOUT_MS,
            .connect_timeout_ms = DEFAULT_CONNECT_TIMEOUT_MS,
            .max_retries = DEFAULT_MAX_RETRIES,
            .retry_delay_ms = DEFAULT_RETRY_DELAY_MS,
            .connection_pool_size = DEFAULT_POOL_SIZE,
            .connection_idle_timeout_ms = DEFAULT_IDLE_TIMEOUT_MS,
            .connection_acquire_timeout_ms = DEFAULT_ACQUIRE_TIMEOUT_MS,
            .rate_limit_per_second = DEFAULT_RATE_LIMIT,
            .burst_size = DEFAULT_BURST_SIZE,
            .user_agent = user_agent_copy,
            .custom_headers = empty_headers,
        };
    }

    pub fn initWithOptions(
        allocator: Allocator,
        url: []const u8,
        timeout_ms: ?u32,
        connect_timeout_ms: ?u32,
        max_retries: ?u8,
        retry_delay_ms: ?u32,
        pool_size: ?u8,
        idle_timeout_ms: ?u64,
        acquire_timeout_ms: ?u64,
        rate_limit: ?u32,
        burst_size: ?u32,
        user_agent: ?[]const u8,
        custom_headers: ?[]const CustomHeader,
    ) ConfigError!ProviderConfig {
        try validateUrl(url);

        if (timeout_ms) |t| {
            try validateTimeout(t);
        }

        if (connect_timeout_ms) |t| {
            try validateConnectTimeout(t);
        }

        if (max_retries) |r| {
            try validateMaxRetries(r);
        }

        if (retry_delay_ms) |d| {
            try validateRetryDelay(d);
        }

        if (pool_size) |p| {
            try validatePoolSize(p);
        }

        if (idle_timeout_ms) |t| {
            try validateIdleTimeout(t);
        }

        if (acquire_timeout_ms) |t| {
            try validateAcquireTimeout(t);
        }

        if (rate_limit) |r| {
            try validateRateLimit(r);
        }

        if (burst_size) |b| {
            try validateBurstSize(b);
        }

        const url_copy = allocator.dupe(u8, url) catch return ConfigError.OutOfMemory;
        errdefer allocator.free(url_copy);

        const agent = user_agent orelse DEFAULT_USER_AGENT;
        const user_agent_copy = allocator.dupe(u8, agent) catch return ConfigError.OutOfMemory;
        errdefer allocator.free(user_agent_copy);

        const headers = if (custom_headers) |h| blk: {
            const headers_copy = allocator.alloc(CustomHeader, h.len) catch return ConfigError.OutOfMemory;
            for (h, 0..) |header, i| {
                const name_copy = allocator.dupe(u8, header.name) catch return ConfigError.OutOfMemory;
                const value_copy = allocator.dupe(u8, header.value) catch return ConfigError.OutOfMemory;
                headers_copy[i] = CustomHeader{
                    .name = name_copy,
                    .value = value_copy,
                };
            }
            break :blk headers_copy;
        } else allocator.alloc(CustomHeader, 0) catch return ConfigError.OutOfMemory;

        return ProviderConfig{
            .url = url_copy,
            .timeout_ms = timeout_ms orelse DEFAULT_TIMEOUT_MS,
            .connect_timeout_ms = connect_timeout_ms orelse DEFAULT_CONNECT_TIMEOUT_MS,
            .max_retries = max_retries orelse DEFAULT_MAX_RETRIES,
            .retry_delay_ms = retry_delay_ms orelse DEFAULT_RETRY_DELAY_MS,
            .connection_pool_size = pool_size orelse DEFAULT_POOL_SIZE,
            .connection_idle_timeout_ms = idle_timeout_ms orelse DEFAULT_IDLE_TIMEOUT_MS,
            .connection_acquire_timeout_ms = acquire_timeout_ms orelse DEFAULT_ACQUIRE_TIMEOUT_MS,
            .rate_limit_per_second = rate_limit orelse DEFAULT_RATE_LIMIT,
            .burst_size = burst_size orelse DEFAULT_BURST_SIZE,
            .user_agent = user_agent_copy,
            .custom_headers = headers,
        };
    }

    pub fn deinit(self: *const ProviderConfig, allocator: Allocator) void {
        allocator.free(self.url);
        allocator.free(self.user_agent);
        for (self.custom_headers) |*header| {
            header.deinit(allocator);
        }
        allocator.free(self.custom_headers);
    }

    pub fn validate(self: *const ProviderConfig) ConfigError!void {
        try validateUrl(self.url);
        try validateTimeout(self.timeout_ms);
        try validateConnectTimeout(self.connect_timeout_ms);
        try validateMaxRetries(self.max_retries);
        try validateRetryDelay(self.retry_delay_ms);
        try validatePoolSize(self.connection_pool_size);
        try validateIdleTimeout(self.connection_idle_timeout_ms);
        try validateAcquireTimeout(self.connection_acquire_timeout_ms);
        try validateRateLimit(self.rate_limit_per_second);
        try validateBurstSize(self.burst_size);
    }

    fn validateUrl(url: []const u8) ConfigError!void {
        if (url.len == 0) {
            return ConfigError.InvalidUrl;
        }

        if (url.len > MAX_URL_LENGTH) {
            return ConfigError.UrlTooLong;
        }

        const has_http = std.mem.startsWith(u8, url, "http://");
        const has_https = std.mem.startsWith(u8, url, "https://");

        if (!has_http and !has_https) {
            return ConfigError.InvalidUrl;
        }

        if (has_http and url.len == 7) {
            return ConfigError.InvalidUrl;
        }

        if (has_https and url.len == 8) {
            return ConfigError.InvalidUrl;
        }
    }

    fn validateTimeout(timeout_ms: u32) ConfigError!void {
        if (timeout_ms < MIN_TIMEOUT_MS or timeout_ms > MAX_TIMEOUT_MS) {
            return ConfigError.InvalidTimeout;
        }
    }

    fn validateConnectTimeout(connect_timeout_ms: u32) ConfigError!void {
        if (connect_timeout_ms < MIN_TIMEOUT_MS or connect_timeout_ms > MAX_TIMEOUT_MS) {
            return ConfigError.InvalidConnectTimeout;
        }
    }

    fn validateMaxRetries(max_retries: u8) ConfigError!void {
        if (max_retries > MAX_RETRIES) {
            return ConfigError.InvalidMaxRetries;
        }
    }

    fn validateRetryDelay(retry_delay_ms: u32) ConfigError!void {
        if (retry_delay_ms == 0 or retry_delay_ms > MAX_RETRY_DELAY_MS) {
            return ConfigError.InvalidRetryDelay;
        }
    }

    fn validatePoolSize(pool_size: u8) ConfigError!void {
        if (pool_size < MIN_POOL_SIZE or pool_size > MAX_POOL_SIZE) {
            return ConfigError.InvalidPoolSize;
        }
    }

    fn validateIdleTimeout(idle_timeout_ms: u64) ConfigError!void {
        if (idle_timeout_ms == 0 or idle_timeout_ms > MAX_IDLE_TIMEOUT_MS) {
            return ConfigError.InvalidIdleTimeout;
        }
    }

    fn validateAcquireTimeout(acquire_timeout_ms: u64) ConfigError!void {
        if (acquire_timeout_ms == 0 or acquire_timeout_ms > MAX_IDLE_TIMEOUT_MS) {
            return ConfigError.InvalidIdleTimeout;
        }
    }

    fn validateRateLimit(rate_limit: u32) ConfigError!void {
        if (rate_limit == 0 or rate_limit > MAX_RATE_LIMIT) {
            return ConfigError.InvalidRateLimit;
        }
    }

    fn validateBurstSize(burst_size: u32) ConfigError!void {
        if (burst_size == 0 or burst_size > MAX_RATE_LIMIT) {
            return ConfigError.InvalidBurstSize;
        }
    }
};

test "ProviderConfig init with defaults" {
    const allocator = std.testing.allocator;
    const url = "https://mainnet.infura.io/v3/test";

    var config = try ProviderConfig.init(allocator, url);
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings(url, config.url);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_TIMEOUT_MS, config.timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_CONNECT_TIMEOUT_MS, config.connect_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_MAX_RETRIES, config.max_retries);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_RETRY_DELAY_MS, config.retry_delay_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_POOL_SIZE, config.connection_pool_size);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_IDLE_TIMEOUT_MS, config.connection_idle_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_ACQUIRE_TIMEOUT_MS, config.connection_acquire_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_RATE_LIMIT, config.rate_limit_per_second);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_BURST_SIZE, config.burst_size);
    try std.testing.expectEqualStrings(ProviderConfig.DEFAULT_USER_AGENT, config.user_agent);
    try std.testing.expectEqual(@as(usize, 0), config.custom_headers.len);
}

test "ProviderConfig init with custom options" {
    const allocator = std.testing.allocator;
    const url = "https://mainnet.infura.io/v3/test";

    var config = try ProviderConfig.initWithOptions(
        allocator,
        url,
        60000,
        15000,
        5,
        2000,
        20,
        60000,
        10000,
        100,
        50,
        "CustomAgent/2.0",
        null,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings(url, config.url);
    try std.testing.expectEqual(@as(u32, 60000), config.timeout_ms);
    try std.testing.expectEqual(@as(u32, 15000), config.connect_timeout_ms);
    try std.testing.expectEqual(@as(u8, 5), config.max_retries);
    try std.testing.expectEqual(@as(u32, 2000), config.retry_delay_ms);
    try std.testing.expectEqual(@as(u8, 20), config.connection_pool_size);
    try std.testing.expectEqual(@as(u64, 60000), config.connection_idle_timeout_ms);
    try std.testing.expectEqual(@as(u64, 10000), config.connection_acquire_timeout_ms);
    try std.testing.expectEqual(@as(u32, 100), config.rate_limit_per_second);
    try std.testing.expectEqual(@as(u32, 50), config.burst_size);
    try std.testing.expectEqualStrings("CustomAgent/2.0", config.user_agent);
}

test "ProviderConfig validate valid config" {
    const allocator = std.testing.allocator;
    const url = "https://mainnet.infura.io/v3/test";

    var config = try ProviderConfig.init(allocator, url);
    defer config.deinit(allocator);

    try config.validate();
}

test "ProviderConfig rejects empty url" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.init(allocator, "");
    try std.testing.expectError(ConfigError.InvalidUrl, result);
}

test "ProviderConfig rejects url without protocol" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.init(allocator, "mainnet.infura.io");
    try std.testing.expectError(ConfigError.InvalidUrl, result);
}

test "ProviderConfig rejects url with only protocol" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.init(allocator, "http://");
    try std.testing.expectError(ConfigError.InvalidUrl, result);

    const result2 = ProviderConfig.init(allocator, "https://");
    try std.testing.expectError(ConfigError.InvalidUrl, result2);
}

test "ProviderConfig rejects too long url" {
    const allocator = std.testing.allocator;

    var long_url = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer long_url.deinit();

    try long_url.appendSlice("https://");
    var i: usize = 0;
    while (i < ProviderConfig.MAX_URL_LENGTH) : (i += 1) {
        try long_url.append('a');
    }

    const result = ProviderConfig.init(allocator, long_url.items);
    try std.testing.expectError(ConfigError.UrlTooLong, result);
}

test "ProviderConfig accepts valid http url" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.init(allocator, "http://localhost:8545");
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("http://localhost:8545", config.url);
}

test "ProviderConfig accepts valid https url" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.init(allocator, "https://mainnet.infura.io/v3/key");
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("https://mainnet.infura.io/v3/key", config.url);
}

test "ProviderConfig rejects zero timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidTimeout, result);
}

test "ProviderConfig accepts any max_retries value within limit" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), config.max_retries);

    var config2 = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        ProviderConfig.MAX_RETRIES,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config2.deinit(allocator);

    try std.testing.expectEqual(ProviderConfig.MAX_RETRIES, config2.max_retries);
}

test "ProviderConfig rejects zero retry_delay" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidRetryDelay, result);
}

test "ProviderConfig rejects pool size below minimum" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidPoolSize, result);
}

test "ProviderConfig rejects pool size above maximum" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        101,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidPoolSize, result);
}

test "ProviderConfig accepts pool size at boundaries" {
    const allocator = std.testing.allocator;

    var config1 = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        1,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config1.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), config1.connection_pool_size);

    var config2 = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        100,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config2.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 100), config2.connection_pool_size);
}

test "ProviderConfig rejects zero rate limit" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidRateLimit, result);
}

test "ProviderConfig rejects zero burst size" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidBurstSize, result);
}

test "ProviderConfig accepts custom user agent" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        "MyAgent/1.0",
        null,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings("MyAgent/1.0", config.user_agent);
}

test "ProviderConfig uses default user agent when null" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqualStrings(ProviderConfig.DEFAULT_USER_AGENT, config.user_agent);
}

test "ProviderConfig all options null uses defaults" {
    const allocator = std.testing.allocator;

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(ProviderConfig.DEFAULT_TIMEOUT_MS, config.timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_CONNECT_TIMEOUT_MS, config.connect_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_MAX_RETRIES, config.max_retries);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_RETRY_DELAY_MS, config.retry_delay_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_POOL_SIZE, config.connection_pool_size);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_IDLE_TIMEOUT_MS, config.connection_idle_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_ACQUIRE_TIMEOUT_MS, config.connection_acquire_timeout_ms);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_RATE_LIMIT, config.rate_limit_per_second);
    try std.testing.expectEqual(ProviderConfig.DEFAULT_BURST_SIZE, config.burst_size);
}

test "ProviderConfig rejects below minimum timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        50,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidTimeout, result);
}

test "ProviderConfig rejects above maximum timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        400000,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidTimeout, result);
}

test "ProviderConfig rejects zero connect timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        0,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidConnectTimeout, result);
}

test "ProviderConfig rejects excessive max retries" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        ProviderConfig.MAX_RETRIES + 1,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidMaxRetries, result);
}

test "ProviderConfig rejects excessive retry delay" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        ProviderConfig.MAX_RETRY_DELAY_MS + 1,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidRetryDelay, result);
}

test "ProviderConfig rejects zero idle timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidIdleTimeout, result);
}

test "ProviderConfig rejects zero acquire timeout" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidIdleTimeout, result);
}

test "ProviderConfig rejects excessive rate limit" {
    const allocator = std.testing.allocator;

    const result = ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        ProviderConfig.MAX_RATE_LIMIT + 1,
        null,
        null,
        null,
    );
    try std.testing.expectError(ConfigError.InvalidRateLimit, result);
}

test "ProviderConfig accepts custom headers" {
    const allocator = std.testing.allocator;

    const headers = [_]CustomHeader{
        CustomHeader{ .name = "Authorization", .value = "Bearer token123" },
        CustomHeader{ .name = "X-Custom-Header", .value = "custom-value" },
    };

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        &headers,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), config.custom_headers.len);
    try std.testing.expectEqualStrings("Authorization", config.custom_headers[0].name);
    try std.testing.expectEqualStrings("Bearer token123", config.custom_headers[0].value);
    try std.testing.expectEqualStrings("X-Custom-Header", config.custom_headers[1].name);
    try std.testing.expectEqualStrings("custom-value", config.custom_headers[1].value);
}

test "ProviderConfig empty custom headers" {
    const allocator = std.testing.allocator;

    const headers = [_]CustomHeader{};

    var config = try ProviderConfig.initWithOptions(
        allocator,
        "https://test.com",
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        &headers,
    );
    defer config.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), config.custom_headers.len);
}
