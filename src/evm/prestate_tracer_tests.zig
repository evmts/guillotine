const std = @import("std");
const testing = std.testing;
const PrestateTracer = @import("prestate_tracer.zig").PrestateTracer;
const writePrestateJson = @import("prestate_tracer.zig").writePrestateJson;
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Helper to create test addresses
fn addr(n: u8) Address {
    return Address{ .bytes = [_]u8{n} ** 20 };
}

// Mock Host implementation for testing
const MockHost = struct {
    const Self = @This();
    
    // Stored state for mock responses
    balance: u256 = 1000,
    nonce: u64 = 5,
    storage_values: std.HashMap(u256, u256, std.hash_map.AutoContext(u256), std.hash_map.default_max_load_percentage),
    code: []const u8 = &[_]u8{0x60, 0x80, 0x60, 0x40},
    
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .storage_values = std.HashMap(u256, u256, std.hash_map.AutoContext(u256), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.storage_values.deinit();
    }
    
    // Host interface methods
    pub fn get_balance(self: *const Self, address: Address) u256 {
        _ = address;
        return self.balance;
    }
    
    pub fn get_nonce(self: *const Self, address: Address) u64 {
        _ = address;
        return self.nonce;
    }
    
    pub fn get_storage(self: *const Self, address: Address, key: u256) u256 {
        _ = address;
        return self.storage_values.get(key) orelse 0;
    }
    
    pub fn get_code(self: *const Self, address: Address) []const u8 {
        _ = address;
        return self.code;
    }
    
    pub fn set_storage(self: *Self, address: Address, key: u256, value: u256) void {
        _ = address;
        self.storage_values.put(key, value) catch {};
    }
    
    pub fn set_balance(self: *Self, new_balance: u256) void {
        self.balance = new_balance;
    }
    
    pub fn set_nonce(self: *Self, new_nonce: u64) void {
        self.nonce = new_nonce;
    }
};

// Helper to capture JSON output
fn captureJson(tracer: *const PrestateTracer, allocator: std.mem.Allocator) ![]u8 {
    var list = std.ArrayList(u8){};
    defer list.deinit(allocator);
    try writePrestateJson(list.writer(allocator), tracer);
    return try list.toOwnedSlice(allocator);
}

// Helper to verify JSON contains or doesn't contain patterns
fn expectContains(json: []const u8, pattern: []const u8) !void {
    if (std.mem.indexOf(u8, json, pattern) == null) {
        std.debug.print("JSON: {s}\n", .{json});
        std.debug.print("Missing pattern: {s}\n", .{pattern});
        return error.PatternNotFound;
    }
}

fn expectNotContains(json: []const u8, pattern: []const u8) !void {
    if (std.mem.indexOf(u8, json, pattern) != null) {
        std.debug.print("JSON: {s}\n", .{json});
        std.debug.print("Unexpected pattern: {s}\n", .{pattern});
        return error.PatternFound;
    }
}

// ===== Account Lifecycle Tests =====

test "diffMode: account read but not modified excluded" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true }); // diffMode = true
    tracer.onTransactionStart();

    // Only read account
    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onNonceRead(addr(1), &mock_host, 5);

    tracer.onTransactionEnd();

    // Account should be excluded from both pre and post
    try testing.expect(!tracer.prestate.contains(addr(1)));
    try testing.expect(!tracer.poststate.contains(addr(1)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);
    try testing.expectEqualStrings("{\"pre\":{},\"post\":{}}", json);
}

test "diffMode: account modified appears in both" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onBalanceChange(addr(1), &mock_host, 1000, 900);

    tracer.onTransactionEnd();

    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.poststate.contains(addr(1)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Verify address format and values
    try expectContains(json, "\"0x0101010101010101010101010101010101010101\"");
    try expectContains(json, "\"pre\":{");
    try expectContains(json, "\"post\":{");
    try expectContains(json, "\"balance\":\"0x3e8\""); // 1000 in hex
    try expectContains(json, "\"balance\":\"0x384\""); // 900 in hex
}

test "diffMode: account created only in post" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onAccountCreated(addr(2), &mock_host, 500, 1, &[_]u8{});

    tracer.onTransactionEnd();

    try testing.expect(!tracer.prestate.contains(addr(2)));
    try testing.expect(tracer.poststate.contains(addr(2)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectContains(json, "\"pre\":{}");
    try expectContains(json, "\"post\":{\"0x0202020202020202020202020202020202020202\"");
}

test "diffMode: account deleted only in pre" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(3), &mock_host, 1000);
    tracer.onAccountDestroyed(addr(3), &mock_host, addr(4), 1000, false, false);

    tracer.onTransactionEnd();

    try testing.expect(tracer.prestate.contains(addr(3)));
    try testing.expect(!tracer.poststate.contains(addr(3)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectContains(json, "\"pre\":{\"0x0303030303030303030303030303030303030303\"");
    try expectContains(json, "\"post\":{}");
}

test "nonDiffMode: all accessed accounts in prestate only" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{}); // diffMode = false
    tracer.onTransactionStart();

    // Read-only access
    tracer.onBalanceRead(addr(1), &mock_host, 100);
    // Modified account
    tracer.onBalanceChange(addr(2), &mock_host, 200, 300);

    tracer.onTransactionEnd();

    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.prestate.contains(addr(2)));
    try testing.expectEqual(@as(usize, 0), tracer.poststate.count());

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // No pre/post structure in non-diff mode
    try expectNotContains(json, "\"pre\"");
    try expectNotContains(json, "\"post\"");
    try expectContains(json, "\"0x0101010101010101010101010101010101010101\"");
    try expectContains(json, "\"0x0202020202020202020202020202020202020202\"");
    try expectContains(json, "\"balance\":\"0x64\""); // Original values only
    try expectContains(json, "\"balance\":\"0xc8\"");
}

// ===== Storage Operations Tests =====

test "storage: read-only excluded in diffMode" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onStorageRead(addr(1), &mock_host, 0x42, 100, false);

    tracer.onTransactionEnd();

    try testing.expect(!tracer.prestate.contains(addr(1)));
    try testing.expect(!tracer.poststate.contains(addr(1)));
}

test "storage: modified appears in both with correct values" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000); // Need to access account
    tracer.onStorageWrite(addr(1), &mock_host, 0x42, 100, 200, true);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Pre should have original storage value
    try expectContains(json, "\"pre\":{\"0x0101010101010101010101010101010101010101\":{");
    try expectContains(json, "\"storage\":{\"0x42\":\"0x64\"}"); // 100

    // Post should have new storage value
    try expectContains(json, "\"post\":{\"0x0101010101010101010101010101010101010101\":{");
    try expectContains(json, "\"0x42\":\"0xc8\""); // 200
}

test "storage: zero to non-zero transition" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onStorageWrite(addr(1), &mock_host, 0x10, 0, 500, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Zero value is omitted from pre storage
    try expectNotContains(json, "\"storage\":{\"0x10\":\"0x0\"}");
    // Non-zero in post
    try expectContains(json, "\"0x10\":\"0x1f4\""); // 500
}

test "storage: non-zero to zero (deletion)" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onStorageWrite(addr(1), &mock_host, 0x20, 300, 0, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Deleted slots should be excluded from both pre and post
    try expectNotContains(json, "\"0x20\"");
}

// ===== Configuration Options Tests =====

test "config: disableStorage omits storage field" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true, .disable_storage = true }); // disableStorage = true
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onBalanceChange(addr(1), &mock_host, 1000, 900);
    tracer.onStorageWrite(addr(1), &mock_host, 0x42, 100, 200, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Should not contain storage field at all
    try expectNotContains(json, "\"storage\"");
    try expectContains(json, "\"balance\"");
}

test "config: disableCode omits code field" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true, .disable_code = true }); // disableCode = true
    tracer.onTransactionStart();

    const code = [_]u8{ 0x60, 0x60, 0x60, 0x40 }; // PUSH1 PUSH1 PUSH1 PUSH1
    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onCodeRead(addr(1), &mock_host, &code);
    tracer.onBalanceChange(addr(1), &mock_host, 1000, 900);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectNotContains(json, "\"code\"");
    try expectContains(json, "\"balance\"");
}

test "config: includeEmpty shows empty accounts" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .include_empty = true }); // includeEmpty = true
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 0);
    tracer.onNonceRead(addr(1), &mock_host, 0);

    tracer.onTransactionEnd();

    try testing.expect(tracer.prestate.contains(addr(1)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectContains(json, "\"0x0101010101010101010101010101010101010101\"");
    try expectContains(json, "\"balance\":\"0x0\"");
    try expectContains(json, "\"nonce\":5");
}

test "config: excludeEmpty removes empty accounts" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    // Set up host to return empty account values
    mock_host.set_balance(0);
    mock_host.set_nonce(0);
    mock_host.code = &[_]u8{};

    tracer.configure(.{}); // includeEmpty = false
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 0);
    tracer.onNonceRead(addr(1), &mock_host, 0);

    tracer.onTransactionEnd();

    try testing.expect(!tracer.prestate.contains(addr(1)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectNotContains(json, "0x0101010101010101010101010101010101010101");
}

// ===== Field Modifications Tests =====

test "fields: balance only modification" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceChange(addr(1), &mock_host, 1000, 2000);
    tracer.onNonceRead(addr(1), &mock_host, 5); // Read nonce but don't modify

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Both should have nonce, but balance differs
    try expectContains(json, "\"nonce\":5");

    // Check pre has old balance
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];
    try expectContains(pre_section, "\"balance\":\"0x3e8\""); // 1000

    // Check post has new balance
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];
    try expectContains(post_section, "\"balance\":\"0x7d0\""); // 2000
}

test "fields: nonce only modification" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onNonceChange(addr(1), &mock_host, 5, 6);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Check nonce values
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];
    try expectContains(pre_section, "\"nonce\":5");

    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];
    try expectContains(post_section, "\"nonce\":6");
}

// ===== Complex Scenarios Tests =====

test "complex: multiple accounts with different operations" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    // Account 1: Read only (should be excluded)
    tracer.onBalanceRead(addr(1), &mock_host, 1000);

    // Account 2: Modified
    tracer.onBalanceChange(addr(2), &mock_host, 2000, 1500);

    // Account 3: Created
    tracer.onAccountCreated(addr(3), &mock_host, 100, 1, &[_]u8{});

    // Account 4: Deleted
    tracer.onBalanceRead(addr(4), &mock_host, 500);
    tracer.onAccountDestroyed(addr(4), &mock_host, addr(2), 500, false, false);

    tracer.onTransactionEnd();

    // Verify presence/absence
    try testing.expect(!tracer.prestate.contains(addr(1))); // Read-only excluded
    try testing.expect(tracer.prestate.contains(addr(2))); // Modified in both
    try testing.expect(!tracer.prestate.contains(addr(3))); // Created not in pre
    try testing.expect(tracer.prestate.contains(addr(4))); // Deleted in pre

    try testing.expect(!tracer.poststate.contains(addr(1))); // Read-only excluded
    try testing.expect(tracer.poststate.contains(addr(2))); // Modified in both
    try testing.expect(tracer.poststate.contains(addr(3))); // Created in post
    try testing.expect(!tracer.poststate.contains(addr(4))); // Deleted not in post
}

test "complex: mixed storage operations on same account" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);

    // Slot A: Modified
    tracer.onStorageWrite(addr(1), &mock_host, 0x10, 100, 200, false);
    // Slot B: Read only
    tracer.onStorageRead(addr(1), &mock_host, 0x20, 300, false);
    // Slot C: Deleted (non-zero to zero)
    tracer.onStorageWrite(addr(1), &mock_host, 0x30, 400, 0, false);
    // Slot D: Created (zero to non-zero)
    tracer.onStorageWrite(addr(1), &mock_host, 0x40, 0, 500, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Pre should have modified and read-only values, but NOT deleted slots
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];

    try expectContains(pre_section, "\"0x10\":\"0x64\""); // 100
    try expectContains(pre_section, "\"0x20\":\"0x12c\""); // 300
    try expectNotContains(pre_section, "\"0x30\""); // Deleted slot should be filtered out
    try expectNotContains(pre_section, "\"0x40\""); // Created slots (0->X) shouldn't appear in pre

    // Post should have only modified values (no deleted, no unchanged)
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];

    try expectContains(post_section, "\"0x10\":\"0xc8\""); // 200 (modified)
    try expectNotContains(post_section, "\"0x20\""); // 300 (unchanged)
    try expectNotContains(post_section, "\"0x30\""); // Deleted slot should be filtered out
    try expectContains(post_section, "\"0x40\":\"0x1f4\""); // 500 (created)
}

// ===== JSON Format Tests =====

test "json: correct structure for diffMode" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    tracer.onBalanceChange(addr(1), &mock_host, 100, 200);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Should start with {
    try testing.expect(json[0] == '{');
    // Should have "pre":{ structure
    try expectContains(json, "{\"pre\":{");
    // Should have "post":{ structure
    try expectContains(json, "},\"post\":{");
    // Should end with }}
    try testing.expect(json[json.len - 2] == '}');
    try testing.expect(json[json.len - 1] == '}');
}

test "json: correct structure for non-diffMode" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(addr(1), &mock_host, 100);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Should be a simple object without pre/post
    try testing.expect(json[0] == '{');
    try expectNotContains(json, "\"pre\"");
    try expectNotContains(json, "\"post\"");
    try testing.expect(json[json.len - 1] == '}');
}

test "json: address format validation" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(Address{ .bytes = [_]u8{ 0x12, 0x34 } ++ ([_]u8{0} ** 18) }, &mock_host, 100);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Address should be 0x prefixed, 40 hex chars
    try expectContains(json, "\"0x1234000000000000000000000000000000000000\"");
}

test "json: numeric format validation" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

        tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(addr(1), &mock_host, 0x123456789abcdef);
    tracer.onNonceRead(addr(1), &mock_host, 42);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Balance should be hex string with 0x
    try expectContains(json, "\"balance\":\"0x123456789abcdef\"");
    // Nonce should be decimal number (not string)
    try expectContains(json, "\"nonce\":5");
}

test "json: code format validation" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{});
    tracer.onTransactionStart();
    const code = [_]u8{ 0x60, 0x80, 0x60, 0x40 };
    tracer.onCodeRead(addr(1), &mock_host, &code);
    tracer.onBalanceRead(addr(1), &mock_host, 100);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Code should be hex string with 0x prefix
    try expectContains(json, "\"code\":\"0x60806040\"");
}

// ===== Edge Cases Tests =====

test "edge: multiple writes to same storage slot" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    // Write multiple times to same slot
    tracer.onStorageWrite(addr(1), &mock_host, 0x42, 0, 100, false);
    tracer.onStorageWrite(addr(1), &mock_host, 0x42, 100, 200, false);
    tracer.onStorageWrite(addr(1), &mock_host, 0x42, 200, 300, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Pre should omit zero value
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];
    try expectNotContains(pre_section, "\"0x42\":\"0x0\"");

    // Post should have final value (300)
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];
    try expectContains(post_section, "\"0x42\":\"0x12c\"");
}

test "edge: empty account becomes non-empty" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true }); // includeEmpty = false
    tracer.onTransactionStart();

    // Start with empty account
    tracer.onBalanceRead(addr(1), &mock_host, 0);
    tracer.onNonceRead(addr(1), &mock_host, 0);
    // Make it non-empty
    tracer.onBalanceChange(addr(1), &mock_host, 0, 1000);

    tracer.onTransactionEnd();

    // Should appear in both (now non-empty)
    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.poststate.contains(addr(1)));
}

test "edge: all configuration options combined" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    // All options enabled
    tracer.configure(.{ .diff_mode = true, .disable_storage = true, .disable_code = true, .include_empty = true }); // diff, no storage, no code, include empty
    tracer.onTransactionStart();

    const code = [_]u8{ 0x60, 0x60 };
    tracer.onBalanceRead(addr(1), &mock_host, 0);
    tracer.onCodeRead(addr(1), &mock_host, &code);
    tracer.onStorageWrite(addr(1), &mock_host, 0x1, 0, 100, false);
    tracer.onBalanceChange(addr(1), &mock_host, 0, 100);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Should have balance and nonce but no code or storage
    try expectContains(json, "\"balance\"");
    try expectContains(json, "\"nonce\"");
    try expectNotContains(json, "\"code\"");
    try expectNotContains(json, "\"storage\"");

    // Empty account should be included due to includeEmpty
    try testing.expect(tracer.prestate.contains(addr(1)));
}

// ===== Tests =====
test "PrestateTracer diff mode correctly handles modifications" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const addr1 = Address{ .bytes = [_]u8{1} ** 20 };
    const addr2 = Address{ .bytes = [_]u8{2} ** 20 };

    // Account 1: read and modified
    tracer.onBalanceRead(addr1, &mock_host, 1000);
    tracer.onNonceRead(addr1, &mock_host, 5);
    tracer.onStorageRead(addr1, &mock_host, 0x42, 100, false);
    
    // Update mock host to reflect the balance change
    mock_host.set_balance(900);
    tracer.onBalanceChange(addr1, &mock_host, 1000, 900);
    
    // Update storage in mock host
    mock_host.set_storage(addr1, 0x42, 200);
    tracer.onStorageWrite(addr1, &mock_host, 0x42, 100, 200, true);

    // Account 2: modified from non-existent
    mock_host.set_balance(100);
    tracer.onBalanceChange(addr2, &mock_host, 0, 100);

    tracer.onTransactionEnd();

    // In diff mode, modified accounts appear in both pre and post
    try std.testing.expect(tracer.prestate.contains(addr1));
    try std.testing.expect(tracer.poststate.contains(addr1));

    // Account 2 was modified, should be in both
    try std.testing.expect(tracer.prestate.contains(addr2));
    try std.testing.expect(tracer.poststate.contains(addr2));

    const account1_pre = tracer.prestate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 1000), account1_pre.balance);
    try std.testing.expectEqual(@as(u64, 5), account1_pre.nonce);
    try std.testing.expectEqual(@as(u256, 100), account1_pre.storage.get(0x42).?);

    const account1_post = tracer.poststate.get(addr1).?;
    try std.testing.expectEqual(@as(u256, 900), account1_post.balance);
    try std.testing.expectEqual(@as(u256, 200), account1_post.storage.get(0x42).?);
}

test "PrestateTracer non-diff mode only shows prestate" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{}); // diff_mode = false
    tracer.onTransactionStart();

    // Access and modify account
    tracer.onBalanceRead(addr(1), &mock_host, 500);
    tracer.onBalanceChange(addr(1), &mock_host, 500, 600);
    tracer.onStorageRead(addr(1), &mock_host, 0x01, 50, false);
    tracer.onStorageWrite(addr(1), &mock_host, 0x01, 50, 75, true);

    tracer.onTransactionEnd();

    // In non-diff mode, only prestate is populated
    try std.testing.expect(tracer.prestate.contains(addr(1)));
    try std.testing.expectEqual(@as(usize, 0), tracer.poststate.count());

    // Prestate should have original values
    const account_pre = tracer.prestate.get(addr(1)).?;
    try std.testing.expectEqual(@as(u256, 500), account_pre.balance);
    try std.testing.expectEqual(@as(u256, 50), account_pre.storage.get(0x01).?);
}

test "PrestateTracer handles account creation and deletion" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const created_addr = addr(4);
    const deleted_addr = addr(5);

    // Set up account to be deleted
    tracer.onBalanceRead(deleted_addr, &mock_host, 1000);
    tracer.onAccountDestroyed(deleted_addr, &mock_host, created_addr, 1000, false, false);

    // Create new account
    tracer.onAccountCreated(created_addr, &mock_host, 1000, 1, &[_]u8{});

    tracer.onTransactionEnd();

    // Created account should only be in poststate
    try std.testing.expect(!tracer.prestate.contains(created_addr));
    try std.testing.expect(tracer.poststate.contains(created_addr));

    // Deleted account should only be in prestate
    try std.testing.expect(tracer.prestate.contains(deleted_addr));
    try std.testing.expect(!tracer.poststate.contains(deleted_addr));
}

test "prestate tracer handles empty accounts correctly" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    // Set up host to return empty values for empty account test
    mock_host.set_balance(0);
    mock_host.set_nonce(0);
    mock_host.code = &[_]u8{};

    // Test with include_empty = false (default)
    tracer.configure(.{});
    tracer.onTransactionStart();

    const empty_addr = addr(6);
    const non_empty_addr = addr(7);

    // Access empty account
    tracer.onBalanceRead(empty_addr, &mock_host, 0);
    tracer.onNonceRead(empty_addr, &mock_host, 0);
    
    // Update host for non-empty account
    mock_host.set_balance(1000);

    // Access non-empty account
    tracer.onBalanceRead(non_empty_addr, &mock_host, 1000);

    tracer.onTransactionEnd();

    // Empty account should be excluded
    try std.testing.expect(!tracer.prestate.contains(empty_addr));
    // Non-empty account should be included
    try std.testing.expect(tracer.prestate.contains(non_empty_addr));
}

test "prestate tracer with include_empty shows all accounts" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    // Set up host for empty account test
    mock_host.set_balance(0);
    mock_host.set_nonce(0);
    mock_host.code = &[_]u8{};

    // Test with include_empty = true
    tracer.configure(.{ .include_empty = true });
    tracer.onTransactionStart();

    const empty_addr = addr(8);

    // Access empty account
    tracer.onBalanceRead(empty_addr, &mock_host, 0);
    tracer.onNonceRead(empty_addr, &mock_host, 0);

    tracer.onTransactionEnd();

    // Empty account should be included when include_empty = true
    try std.testing.expect(tracer.prestate.contains(empty_addr));
}

test "prestate tracer diff mode read-only accounts excluded" {
    const allocator = std.testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();

    tracer.configure(.{ .diff_mode = true }); // diff_mode = true
    tracer.onTransactionStart();

    const read_only_addr = addr(9);
    const modified_addr = addr(10);

    // Read-only access
    tracer.onBalanceRead(read_only_addr, &mock_host, 500);
    tracer.onStorageRead(read_only_addr, &mock_host, 0x01, 100, false);

    // Modified account
    tracer.onBalanceRead(modified_addr, &mock_host, 1000);
    tracer.onBalanceChange(modified_addr, &mock_host, 1000, 2000);

    tracer.onTransactionEnd();

    // In diff mode, read-only accounts should be excluded
    try std.testing.expect(!tracer.prestate.contains(read_only_addr));
    try std.testing.expect(!tracer.poststate.contains(read_only_addr));

    // Modified accounts should be in both
    try std.testing.expect(tracer.prestate.contains(modified_addr));
    try std.testing.expect(tracer.poststate.contains(modified_addr));
}

// ===== REFACTORED API TESTS - Host Parameter Integration =====

test "REFACTORED API: onBalanceRead with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(1500);
    
    tracer.configure(.{});
    tracer.onTransactionStart();
    
    // Test new API with host parameter
    tracer.onBalanceRead(addr(1), &mock_host, 1500);
    
    tracer.onTransactionEnd();
    
    // Verify account was tracked correctly
    try testing.expect(tracer.prestate.contains(addr(1)));
    const account = tracer.prestate.get(addr(1)).?;
    try testing.expectEqual(@as(u256, 1500), account.balance);
}

test "REFACTORED API: onBalanceChange with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(2000);
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // Test new API with host parameter - balance change should trigger onAccountTouched
    tracer.onBalanceChange(addr(1), &mock_host, 1000, 2000);
    
    tracer.onTransactionEnd();
    
    // Verify both prestate and poststate were updated correctly
    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.poststate.contains(addr(1)));
    
    const pre_account = tracer.prestate.get(addr(1)).?;
    const post_account = tracer.poststate.get(addr(1)).?;
    
    // Prestate should capture the original balance (1000) from the balance change
    try testing.expectEqual(@as(u256, 1000), pre_account.balance);
    // Poststate should capture the final balance (2000) from the balance change
    try testing.expectEqual(@as(u256, 2000), post_account.balance);
}

test "REFACTORED API: onStorageRead with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    try mock_host.storage_values.put(0x42, 300);
    
    tracer.configure(.{});
    tracer.onTransactionStart();
    
    // Test new API with host parameter
    tracer.onStorageRead(addr(1), &mock_host, 0x42, 300, false);
    
    tracer.onTransactionEnd();
    
    // Verify account and storage were tracked
    try testing.expect(tracer.prestate.contains(addr(1)));
    const account = tracer.prestate.get(addr(1)).?;
    try testing.expectEqual(@as(u256, 300), account.storage.get(0x42).?);
}

test "REFACTORED API: onStorageWrite with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(1000);
    try mock_host.storage_values.put(0x10, 150);
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // Test new API with host parameter - storage write should trigger onAccountTouched
    tracer.onStorageWrite(addr(2), &mock_host, 0x10, 150, 250, true);
    
    tracer.onTransactionEnd();
    
    // Verify both prestate and poststate
    try testing.expect(tracer.prestate.contains(addr(2)));
    try testing.expect(tracer.poststate.contains(addr(2)));
    
    const pre_account = tracer.prestate.get(addr(2)).?;
    const post_account = tracer.poststate.get(addr(2)).?;
    
    // Prestate should have original storage value
    try testing.expectEqual(@as(u256, 150), pre_account.storage.get(0x10).?);
    // Poststate should have new storage value
    try testing.expectEqual(@as(u256, 250), post_account.storage.get(0x10).?);
    
    // Both should have balance from host
    try testing.expectEqual(@as(u256, 1000), pre_account.balance);
    try testing.expectEqual(@as(u256, 1000), post_account.balance);
}

test "REFACTORED API: onAccountCreated with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    const code = [_]u8{0x60, 0x40, 0x80};
    // Test new API with host parameter
    tracer.onAccountCreated(addr(3), &mock_host, 500, 1, &code);
    
    tracer.onTransactionEnd();
    
    // Created accounts should only appear in poststate
    try testing.expect(!tracer.prestate.contains(addr(3)));
    try testing.expect(tracer.poststate.contains(addr(3)));
    
    const post_account = tracer.poststate.get(addr(3)).?;
    try testing.expectEqual(@as(u256, 500), post_account.balance);
    try testing.expectEqual(@as(u64, 1), post_account.nonce);
    try testing.expectEqualSlices(u8, &code, post_account.code);
}

test "REFACTORED API: onAccountDestroyed with host parameter" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(750);
    mock_host.set_nonce(10);
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // First access the account to establish prestate
    tracer.onBalanceRead(addr(4), &mock_host, 750);
    
    // Test new API with host parameter
    tracer.onAccountDestroyed(addr(4), &mock_host, addr(5), 750, true, false);
    
    tracer.onTransactionEnd();
    
    // Destroyed accounts should only appear in prestate
    try testing.expect(tracer.prestate.contains(addr(4)));
    try testing.expect(!tracer.poststate.contains(addr(4)));
    
    const pre_account = tracer.prestate.get(addr(4)).?;
    try testing.expectEqual(@as(u256, 750), pre_account.balance);
    try testing.expectEqual(@as(u64, 10), pre_account.nonce);
}

// ===== onAccountTouched Integration Tests =====

test "REFACTORED API: onAccountTouched pre-phase captures original state" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(2000);
    mock_host.set_nonce(15);
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // Test onAccountTouched in pre-phase with known values
    tracer.onAccountTouched(addr(1), &mock_host, .pre, 2000, 15, null);
    
    tracer.onTransactionEnd();
    
    // In diff mode, read-only accounts are removed from both pre and post
    // Since this account was only accessed (not modified), it should not appear
    try testing.expect(!tracer.prestate.contains(addr(1)));
    try testing.expect(!tracer.poststate.contains(addr(1)));
}

test "REFACTORED API: onAccountTouched post-phase captures final state" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(3000);
    mock_host.set_nonce(20);
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // First establish prestate
    tracer.onAccountTouched(addr(1), &mock_host, .pre, 1500, 10, null);
    
    // Then test post-phase  
    tracer.onAccountTouched(addr(1), &mock_host, .post, null, null, null);
    
    tracer.onTransactionEnd();
    
    // In diff mode, read-only accounts (accessed but not modified) are removed
    // Since this account was only accessed (not modified), it should not appear
    try testing.expect(!tracer.prestate.contains(addr(1)));
    try testing.expect(!tracer.poststate.contains(addr(1)));
}

test "REFACTORED API: multiple onAccountTouched calls preserve original prestate" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(1000);
    
    tracer.configure(.{ .diff_mode = false });
    tracer.onTransactionStart();
    
    // First onAccountTouched should establish prestate
    tracer.onAccountTouched(addr(1), &mock_host, .pre, 1000, 5, null);
    
    // Subsequent calls should not overwrite prestate
    mock_host.set_balance(1500);
    tracer.onAccountTouched(addr(1), &mock_host, .pre, 1500, 8, null);
    
    tracer.onTransactionEnd();
    
    try testing.expect(tracer.prestate.contains(addr(1)));
    const pre_account = tracer.prestate.get(addr(1)).?;
    
    // Should preserve the ORIGINAL values from first call
    try testing.expectEqual(@as(u256, 1000), pre_account.balance);
    try testing.expectEqual(@as(u64, 5), pre_account.nonce);
}

// ===== Integration and Edge Case Tests =====

test "REFACTORED API: complex transaction with all hook types" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    
    // Simulate complex transaction with multiple account interactions
    
    // Account 1: Balance read and modification
    mock_host.set_balance(1000);
    tracer.onBalanceRead(addr(1), &mock_host, 1000);
    tracer.onBalanceChange(addr(1), &mock_host, 1000, 800);
    
    // Account 2: Storage operations
    mock_host.set_balance(500);
    try mock_host.storage_values.put(0x20, 100);
    tracer.onStorageRead(addr(2), &mock_host, 0x20, 100, false);
    tracer.onStorageWrite(addr(2), &mock_host, 0x20, 100, 200, true);
    
    // Account 3: Account creation
    const code = [_]u8{0x60, 0x80};
    tracer.onAccountCreated(addr(3), &mock_host, 300, 1, &code);
    
    // Account 4: Account destruction  
    mock_host.set_balance(400);
    tracer.onBalanceRead(addr(4), &mock_host, 400);
    tracer.onAccountDestroyed(addr(4), &mock_host, addr(1), 400, false, false);
    
    tracer.onTransactionEnd();
    
    // Verify all accounts are tracked correctly according to diff mode rules
    
    // Account 1: Modified, should be in both
    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.poststate.contains(addr(1)));
    
    // Account 2: Modified storage, should be in both  
    try testing.expect(tracer.prestate.contains(addr(2)));
    try testing.expect(tracer.poststate.contains(addr(2)));
    
    // Account 3: Created, should be in post only
    try testing.expect(!tracer.prestate.contains(addr(3)));
    try testing.expect(tracer.poststate.contains(addr(3)));
    
    // Account 4: Destroyed, should be in pre only
    try testing.expect(tracer.prestate.contains(addr(4)));
    try testing.expect(!tracer.poststate.contains(addr(4)));
    
    // Verify specific values
    const account1_pre = tracer.prestate.get(addr(1)).?;
    const account1_post = tracer.poststate.get(addr(1)).?;
    try testing.expectEqual(@as(u256, 1000), account1_pre.balance);
    try testing.expectEqual(@as(u256, 800), account1_post.balance);
    
    const account2_pre = tracer.prestate.get(addr(2)).?;
    const account2_post = tracer.poststate.get(addr(2)).?;
    try testing.expectEqual(@as(u256, 100), account2_pre.storage.get(0x20).?);
    try testing.expectEqual(@as(u256, 200), account2_post.storage.get(0x20).?);
}

test "REFACTORED API: host queries fallback when known values null" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    mock_host.set_balance(9999);
    mock_host.set_nonce(42);
    
    tracer.configure(.{});
    tracer.onTransactionStart();
    
    // Test onAccountTouched with null known values - should query host
    tracer.onAccountTouched(addr(1), &mock_host, .pre, null, null, null);
    
    tracer.onTransactionEnd();
    
    try testing.expect(tracer.prestate.contains(addr(1)));
    const account = tracer.prestate.get(addr(1)).?;
    
    // Should have queried host for these values
    try testing.expectEqual(@as(u256, 9999), account.balance);
    try testing.expectEqual(@as(u64, 42), account.nonce);
}

test "REFACTORED API: zero overhead when not in diff mode" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();
    
    var mock_host = MockHost.init(allocator);
    defer mock_host.deinit();
    
    tracer.configure(.{}); // diff_mode = false
    tracer.onTransactionStart();
    
    // In non-diff mode, post-phase onAccountTouched should be no-op
    tracer.onAccountTouched(addr(1), &mock_host, .pre, 1000, 5, null);
    tracer.onAccountTouched(addr(1), &mock_host, .post, null, null, null);
    
    tracer.onTransactionEnd();
    
    // Should only have prestate, no poststate
    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expectEqual(@as(usize, 0), tracer.poststate.count());
}