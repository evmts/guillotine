// Specific differential tests for ten-thousand-hashes and snailtracer

const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

fn parse_hex_alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    // First pass: count hex digits ignoring whitespace and 0x prefix occurrences
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        count += 1;
    }
    if (count == 0) return allocator.alloc(u8, 0);
    if (count % 2 != 0) return error.InvalidHex;

    var out = try allocator.alloc(u8, count / 2);
    errdefer allocator.free(out);

    // Second pass: decode
    var idx: usize = 0;
    i = 0;
    var hi_digit: ?u8 = null;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '0' and i + 1 < text.len and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) continue;
        const d = std.fmt.charToDigit(c, 16) catch return error.InvalidHex;
        if (hi_digit == null) {
            hi_digit = d;
        } else {
            const hi = hi_digit.?;
            out[idx] = @intCast((hi << 4) | d);
            idx += 1;
            hi_digit = null;
        }
    }
    return out;
}

fn run_fixture_test(allocator: std.mem.Allocator, testor: *DifferentialTestor, fixture_dir: []const u8) !void {
    var cwd = std.fs.cwd();
    var dir = cwd.openDir(fixture_dir, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => {
            std.log.warn("Fixture directory not found: {s}", .{fixture_dir});
            return;
        },
        else => return e,
    };
    defer dir.close();

    var iter = dir.iterate();
    var total_tests: usize = 0;
    var passed_tests: usize = 0;
    var failed_tests: usize = 0;
    
    var total_guillotine_ns: u64 = 0;
    var total_revm_ns: u64 = 0;

    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        std.log.info("Running fixture: {s}/{s}", .{ fixture_dir, entry.name });
        
        const file = try dir.openFile(entry.name, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(contents);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch |err| {
            std.log.warn("Failed to parse JSON in {s}: {}", .{ entry.name, err });
            continue;
        };
        defer parsed.deinit();

        if (parsed.value != .object) continue;
        const root_obj = parsed.value.object;
        
        for (root_obj.keys(), root_obj.values()) |test_name, test_case| {
            if (test_case != .object) continue;
            
            total_tests += 1;
            const result = run_single_test_with_timing(allocator, testor, test_name, test_case.object) catch |err| blk: {
                std.log.err("Error running test {s}: {}", .{ test_name, err });
                break :blk TestResult{ .passed = false, .guillotine_ns = 0, .revm_ns = 0 };
            };
            
            if (result.passed) {
                passed_tests += 1;
            } else {
                failed_tests += 1;
            }
            
            total_guillotine_ns += result.guillotine_ns;
            total_revm_ns += result.revm_ns;
        }
    }

    std.log.info("Fixture test results for {s}:", .{fixture_dir});
    std.log.info("  Total: {d}, Passed: {d}, Failed: {d}", .{ total_tests, passed_tests, failed_tests });
    
    if (total_tests > 0) {
        const avg_guillotine_us = total_guillotine_ns / total_tests / 1000;
        const avg_revm_us = total_revm_ns / total_tests / 1000;
        const speedup = @as(f64, @floatFromInt(total_revm_ns)) / @as(f64, @floatFromInt(total_guillotine_ns));
        
        std.debug.print("\n📊 Performance Summary for {s}:\n", .{fixture_dir});
        std.debug.print("  Guillotine avg: {d} µs\n", .{avg_guillotine_us});
        std.debug.print("  REVM avg:       {d} µs\n", .{avg_revm_us});
        std.debug.print("  Speedup:        {d:.2}x {s}\n", .{
            if (speedup > 1) speedup else 1.0 / speedup,
            if (speedup > 1) "faster ✅" else "slower ⚠️"
        });
    }
    
    if (failed_tests > 0) {
        return error.TestsFailed;
    }
}

const TestResult = struct {
    passed: bool,
    guillotine_ns: u64,
    revm_ns: u64,
};

fn run_single_test_with_timing(allocator: std.mem.Allocator, testor: *DifferentialTestor, test_name: []const u8, test_obj: std.json.ObjectMap) !TestResult {
    // Extract bytecode (bc)
    const bc_str = test_obj.get("bc") orelse test_obj.get("bytecode") orelse return TestResult{ .passed = false, .guillotine_ns = 0, .revm_ns = 0 };
    if (bc_str != .string) return TestResult{ .passed = false, .guillotine_ns = 0, .revm_ns = 0 };
    
    const bc_bytes = try parse_hex_alloc(allocator, bc_str.string);
    defer allocator.free(bc_bytes);
    
    // Extract calldata (cd) - optional
    const cd_text = if (test_obj.get("cd")) |cd| 
        if (cd == .string) cd.string else ""
    else if (test_obj.get("calldata")) |cd|
        if (cd == .string) cd.string else ""
    else 
        "";
    
    const cd_bytes = if (cd_text.len == 0)
        try allocator.alloc(u8, 0)
    else
        try parse_hex_alloc(allocator, cd_text);
    defer allocator.free(cd_bytes);
    
    // Deploy bytecode to both EVMs
    try testor.revm_instance.setCode(testor.contract, bc_bytes);
    
    const code_hash = try testor.guillotine_db.set_code(bc_bytes);
    try testor.guillotine_db.set_account(testor.contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Time REVM execution
    const revm_start = std.time.nanoTimestamp();
    var revm_result = try testor.executeRevmWithTrace(testor.caller, testor.contract, 0, cd_bytes, 100000);
    const revm_end = std.time.nanoTimestamp();
    defer revm_result.deinit();
    const revm_ns = @as(u64, @intCast(revm_end - revm_start));
    
    // Time Guillotine execution
    const guillotine_start = std.time.nanoTimestamp();
    var guillotine_result = try testor.executeGuillotineWithTrace(testor.caller, testor.contract, 0, cd_bytes, 100000);
    const guillotine_end = std.time.nanoTimestamp();
    defer guillotine_result.deinit();
    const guillotine_ns = @as(u64, @intCast(guillotine_end - guillotine_start));
    
    // Generate diff to check if they match
    var diff = try testor.generateDiff(revm_result, guillotine_result);
    defer diff.deinit();
    
    const test_passed = diff.result_match and diff.trace_match;
    
    if (!test_passed) {
        testor.printDiff(diff, test_name);
    }
    
    return TestResult{
        .passed = test_passed,
        .guillotine_ns = guillotine_ns,
        .revm_ns = revm_ns,
    };
}

fn run_single_test(allocator: std.mem.Allocator, testor: *DifferentialTestor, test_name: []const u8, test_obj: std.json.ObjectMap) !bool {
    // Extract bytecode (bc)
    const bc_str = test_obj.get("bc") orelse test_obj.get("bytecode") orelse return false;
    if (bc_str != .string) return false;
    
    const bc_bytes = try parse_hex_alloc(allocator, bc_str.string);
    defer allocator.free(bc_bytes);
    
    // Extract calldata (cd) - optional
    const cd_text = if (test_obj.get("cd")) |cd| 
        if (cd == .string) cd.string else ""
    else if (test_obj.get("calldata")) |cd|
        if (cd == .string) cd.string else ""
    else 
        "";
    
    const cd_bytes = if (cd_text.len == 0)
        try allocator.alloc(u8, 0)
    else
        try parse_hex_alloc(allocator, cd_text);
    defer allocator.free(cd_bytes);
    
    // Deploy bytecode to both EVMs
    try testor.revm_instance.setCode(testor.contract, bc_bytes);
    
    const code_hash = try testor.guillotine_db.set_code(bc_bytes);
    try testor.guillotine_db.set_account(testor.contract.bytes, .{
        .balance = 0,
        .nonce = 1,
        .code_hash = code_hash,
        .storage_root = [_]u8{0} ** 32,
    });
    
    // Execute with calldata on both EVMs and compare results
    var diff = try testor.executeAndDiff(
        testor.caller,
        testor.contract,
        0, // value
        cd_bytes,
        100000, // gas_limit
    );
    defer diff.deinit();
    
    // Check if test passed
    const test_passed = diff.result_match and diff.trace_match;
    
    if (!test_passed) {
        testor.printDiff(diff, test_name);
    }
    
    return test_passed;
}

test "differential: snailtracer fixture" {
    std.debug.print("\n=== Running snailtracer fixture test ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    try run_fixture_test(allocator, &testor, "src/evm/fixtures/snailtracer");
    
    std.debug.print("=== snailtracer fixture test completed ===\n", .{});
}

test "differential: ten-thousand-hashes fixture" {
    std.debug.print("\n=== Running ten-thousand-hashes fixture test ===\n", .{});
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();
    try run_fixture_test(allocator, &testor, "src/evm/fixtures/ten-thousand-hashes");
    
    std.debug.print("=== ten-thousand-hashes fixture test completed ===\n", .{});
}