const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;

const testing = std.testing;

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
    
    const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{fixture_dir});
    defer allocator.free(bc_path);
    const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{fixture_dir});
    defer allocator.free(cd_path);

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);
    
    const cd_trimmed = std.mem.trim(u8, cd_text, &std.ascii.whitespace);
    
    // Parse calldata - handle empty case "0x" or just whitespace
    const cd_bytes = if (std.mem.eql(u8, cd_trimmed, "0x") or cd_trimmed.len == 0)
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

    // Assert results match
    if (!diff.result_match or !diff.trace_match) {
        testor.printDiff(diff, fixture_dir);
        return error.FixtureMismatch;
    }
}

test "differential: snailtracer fixture" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    try run_fixture_test(allocator, &testor, "src/evm/fixtures/snailtracer");
}

test "differential: erc20-transfer fixture" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    try run_fixture_test(allocator, &testor, "src/evm/fixtures/erc20-transfer");
}

test "differential: erc20-approval-transfer fixture" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    try run_fixture_test(allocator, &testor, "src/evm/fixtures/erc20-approval-transfer");
}

test "differential: erc20-mint fixture" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    try run_fixture_test(allocator, &testor, "src/evm/fixtures/erc20-mint");
}

test "differential: ten-thousand-hashes fixture" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    try run_fixture_test(allocator, &testor, "src/evm/fixtures/ten-thousand-hashes");
}