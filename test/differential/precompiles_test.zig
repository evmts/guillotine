const std = @import("std");
const DifferentialTestor = @import("differential_testor.zig").DifferentialTestor;
const testing = std.testing;

fn parse_hex_alloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
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

test "differential: precompile-ecrecover" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-ecrecover/bytecode.txt";
    const cd_path = "fixtures/precompile-ecrecover/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-sha256" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-sha256/bytecode.txt";
    const cd_path = "fixtures/precompile-sha256/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-ripemd160" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-ripemd160/bytecode.txt";
    const cd_path = "fixtures/precompile-ripemd160/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-identity" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-identity/bytecode.txt";
    const cd_path = "fixtures/precompile-identity/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-modexp" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-modexp/bytecode.txt";
    const cd_path = "fixtures/precompile-modexp/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-bn256add" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-bn256add/bytecode.txt";
    const cd_path = "fixtures/precompile-bn256add/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-bn256mul" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-bn256mul/bytecode.txt";
    const cd_path = "fixtures/precompile-bn256mul/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-bn256pairing" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-bn256pairing/bytecode.txt";
    const cd_path = "fixtures/precompile-bn256pairing/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-blake2f" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-blake2f/bytecode.txt";
    const cd_path = "fixtures/precompile-blake2f/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}

test "differential: precompile-pointevaluation" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    var cwd = std.fs.cwd();
    const bc_path = "fixtures/precompile-pointevaluation/bytecode.txt";
    const cd_path = "fixtures/precompile-pointevaluation/calldata.txt";

    const bc_text = try cwd.readFileAlloc(allocator, bc_path, 1024 * 1024);
    defer allocator.free(bc_text);
    const cd_text = try cwd.readFileAlloc(allocator, cd_path, 1024 * 1024);
    defer allocator.free(cd_text);

    const bc_bytes = try parse_hex_alloc(allocator, bc_text);
    defer allocator.free(bc_bytes);

    if (std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
        try testor.test_bytecode(bc_bytes);
    } else {
        const cd_bytes = try parse_hex_alloc(allocator, cd_text);
        defer allocator.free(cd_bytes);
        try testor.test_bytecode_with_calldata(bc_bytes, cd_bytes);
    }
}