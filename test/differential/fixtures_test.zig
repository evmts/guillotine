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

test "differential: curated fixtures run" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-push-pop",
        "src/evm/fixtures/opcodes-dup",
        "src/evm/fixtures/opcodes-swap",
        "src/evm/fixtures/opcodes-memory",
        "src/evm/fixtures/opcodes-arithmetic",
        "src/evm/fixtures/opcodes-comparison",
    };

    var cwd = std.fs.cwd();
    for (fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
        defer allocator.free(bc_text);
        const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata ("0x") via this helper
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}
