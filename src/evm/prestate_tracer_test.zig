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

    tracer.configure(.{ .diff_mode = true }); // diffMode = true
    tracer.onTransactionStart();

    // Only read account
    tracer.onBalanceRead(addr(1), 1000);
    tracer.onNonceRead(addr(1), 5);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    tracer.onBalanceChange(addr(1), 1000, 900);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onAccountCreated(addr(2), 500, 1, &[_]u8{});

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(3), 1000);
    tracer.onAccountDestroyed(addr(3), addr(4), 1000, false, false);

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

    tracer.configure(.{}); // diffMode = false
    tracer.onTransactionStart();

    // Read-only access
    tracer.onBalanceRead(addr(1), 100);
    // Modified account
    tracer.onBalanceChange(addr(2), 200, 300);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onStorageRead(addr(1), 0x42, 100, false);

    tracer.onTransactionEnd();

    try testing.expect(!tracer.prestate.contains(addr(1)));
    try testing.expect(!tracer.poststate.contains(addr(1)));
}

test "storage: modified appears in both with correct values" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000); // Need to access account
    tracer.onStorageWrite(addr(1), 0x42, 100, 200, true);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    tracer.onStorageWrite(addr(1), 0x10, 0, 500, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Zero value in pre storage
    try expectContains(json, "\"storage\":{\"0x10\":\"0x0\"}");
    // Non-zero in post
    try expectContains(json, "\"0x10\":\"0x1f4\""); // 500
}

test "storage: non-zero to zero (deletion)" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    tracer.onStorageWrite(addr(1), 0x20, 300, 0, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Non-zero in pre
    try expectContains(json, "\"storage\":{\"0x20\":\"0x12c\"}"); // 300
    // Should be excluded from post (zero values omitted)
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];
    try expectNotContains(post_section, "\"0x20\"");
}

// ===== Configuration Options Tests =====

test "config: disableStorage omits storage field" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true, .disable_storage = true }); // disableStorage = true
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    tracer.onBalanceChange(addr(1), 1000, 900);
    tracer.onStorageWrite(addr(1), 0x42, 100, 200, false);

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

    tracer.configure(.{ .diff_mode = true, .disable_code = true }); // disableCode = true
    tracer.onTransactionStart();

    const code = [_]u8{ 0x60, 0x60, 0x60, 0x40 }; // PUSH1 PUSH1 PUSH1 PUSH1
    tracer.onBalanceRead(addr(1), 1000);
    tracer.onCodeRead(addr(1), &code);
    tracer.onBalanceChange(addr(1), 1000, 900);

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

    tracer.configure(.{ .include_empty = true }); // includeEmpty = true
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 0);
    tracer.onNonceRead(addr(1), 0);

    tracer.onTransactionEnd();

    try testing.expect(tracer.prestate.contains(addr(1)));

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    try expectContains(json, "\"0x0101010101010101010101010101010101010101\"");
    try expectContains(json, "\"balance\":\"0x0\"");
    try expectContains(json, "\"nonce\":0");
}

test "config: excludeEmpty removes empty accounts" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{}); // includeEmpty = false
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 0);
    tracer.onNonceRead(addr(1), 0);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceChange(addr(1), 1000, 2000);
    tracer.onNonceRead(addr(1), 5); // Read nonce but don't modify

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    tracer.onNonceChange(addr(1), 5, 6);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    // Account 1: Read only (should be excluded)
    tracer.onBalanceRead(addr(1), 1000);

    // Account 2: Modified
    tracer.onBalanceChange(addr(2), 2000, 1500);

    // Account 3: Created
    tracer.onAccountCreated(addr(3), 100, 1, &[_]u8{});

    // Account 4: Deleted
    tracer.onBalanceRead(addr(4), 500);
    tracer.onAccountDestroyed(addr(4), addr(2), 500, false, false);

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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);

    // Slot A: Modified
    tracer.onStorageWrite(addr(1), 0x10, 100, 200, false);
    // Slot B: Read only
    tracer.onStorageRead(addr(1), 0x20, 300, false);
    // Slot C: Deleted (non-zero to zero)
    tracer.onStorageWrite(addr(1), 0x30, 400, 0, false);
    // Slot D: Created (zero to non-zero)
    tracer.onStorageWrite(addr(1), 0x40, 0, 500, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Pre should have all original values
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];

    try expectContains(pre_section, "\"0x10\":\"0x64\""); // 100
    try expectContains(pre_section, "\"0x20\":\"0x12c\""); // 300
    try expectContains(pre_section, "\"0x30\":\"0x190\""); // 400
    try expectContains(pre_section, "\"0x40\":\"0x0\""); // 0

    // Post should have only modified values
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];

    try expectContains(post_section, "\"0x10\":\"0xc8\""); // 200 (modified)
    try expectContains(post_section, "\"0x20\":\"0x12c\""); // 300 (unchanged)
    try expectNotContains(post_section, "\"0x30\""); // Deleted (zero)
    try expectContains(post_section, "\"0x40\":\"0x1f4\""); // 500 (created)
}

// ===== JSON Format Tests =====

test "json: correct structure for diffMode" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();
    tracer.onBalanceChange(addr(1), 100, 200);
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

    tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(addr(1), 100);
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

    tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(Address{ .bytes = [_]u8{ 0x12, 0x34 } ++ ([_]u8{0} ** 18) }, 100);
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

    tracer.configure(.{});
    tracer.onTransactionStart();
    tracer.onBalanceRead(addr(1), 0x123456789abcdef);
    tracer.onNonceRead(addr(1), 42);
    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Balance should be hex string with 0x
    try expectContains(json, "\"balance\":\"0x123456789abcdef\"");
    // Nonce should be decimal number (not string)
    try expectContains(json, "\"nonce\":42");
    try expectNotContains(json, "\"nonce\":\"42\"");
}

test "json: code format validation" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{});
    tracer.onTransactionStart();
    const code = [_]u8{ 0x60, 0x80, 0x60, 0x40 };
    tracer.onCodeRead(addr(1), &code);
    tracer.onBalanceRead(addr(1), 100);
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

    tracer.configure(.{ .diff_mode = true });
    tracer.onTransactionStart();

    tracer.onBalanceRead(addr(1), 1000);
    // Write multiple times to same slot
    tracer.onStorageWrite(addr(1), 0x42, 0, 100, false);
    tracer.onStorageWrite(addr(1), 0x42, 100, 200, false);
    tracer.onStorageWrite(addr(1), 0x42, 200, 300, false);

    tracer.onTransactionEnd();

    const json = try captureJson(&tracer, allocator);
    defer allocator.free(json);

    // Pre should have original value (0)
    const pre_start = std.mem.indexOf(u8, json, "\"pre\"").?;
    const pre_end = std.mem.indexOf(u8, json[pre_start..], "\"post\"").?;
    const pre_section = json[pre_start .. pre_start + pre_end];
    try expectContains(pre_section, "\"0x42\":\"0x0\"");

    // Post should have final value (300)
    const post_start = std.mem.indexOf(u8, json, "\"post\"").?;
    const post_section = json[post_start..];
    try expectContains(post_section, "\"0x42\":\"0x12c\"");
}

test "edge: empty account becomes non-empty" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    tracer.configure(.{ .diff_mode = true }); // includeEmpty = false
    tracer.onTransactionStart();

    // Start with empty account
    tracer.onBalanceRead(addr(1), 0);
    tracer.onNonceRead(addr(1), 0);
    // Make it non-empty
    tracer.onBalanceChange(addr(1), 0, 1000);

    tracer.onTransactionEnd();

    // Should appear in both (now non-empty)
    try testing.expect(tracer.prestate.contains(addr(1)));
    try testing.expect(tracer.poststate.contains(addr(1)));
}

test "edge: all configuration options combined" {
    const allocator = testing.allocator;
    var tracer = PrestateTracer.init(allocator);
    defer tracer.deinit();

    // All options enabled
    tracer.configure(.{ .diff_mode = true, .disable_storage = true, .disable_code = true, .include_empty = true }); // diff, no storage, no code, include empty
    tracer.onTransactionStart();

    const code = [_]u8{ 0x60, 0x60 };
    tracer.onBalanceRead(addr(1), 0);
    tracer.onCodeRead(addr(1), &code);
    tracer.onStorageWrite(addr(1), 0x1, 0, 100, false);
    tracer.onBalanceChange(addr(1), 0, 100);

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
