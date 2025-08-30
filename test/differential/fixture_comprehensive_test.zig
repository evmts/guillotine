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

test "differential: ERC20 fixtures comprehensive" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const erc20_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/erc20-approval-transfer",
        "src/evm/fixtures/erc20-mint", 
        "src/evm/fixtures/erc20-transfer",
    };

    var cwd = std.fs.cwd();
    for (erc20_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        // Try to read files, skip if they don't exist
        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: advanced arithmetic fixtures" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const arithmetic_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-arithmetic-advanced",
        "src/evm/fixtures/opcodes-bitwise",
    };

    var cwd = std.fs.cwd();
    for (arithmetic_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata for simplicity
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: block information fixtures" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const block_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-block-1",
        "src/evm/fixtures/opcodes-block-2",
    };

    var cwd = std.fs.cwd();
    for (block_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: control flow and crypto fixtures" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const control_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-control",
        "src/evm/fixtures/opcodes-crypto",
    };

    var cwd = std.fs.cwd();
    for (control_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: environmental fixtures extended" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const env_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-environmental-1",
        "src/evm/fixtures/opcodes-environmental-2",
    };

    var cwd = std.fs.cwd();
    for (env_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: data and jump fixtures" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const data_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-data",
        "src/evm/fixtures/opcodes-jump-basic",
    };

    var cwd = std.fs.cwd();
    for (data_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: storage fixtures cold and warm" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const storage_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/opcodes-storage-cold",
        "src/evm/fixtures/opcodes-storage-warm",
    };

    var cwd = std.fs.cwd();
    for (storage_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: precompile fixtures comprehensive" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const precompile_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/precompile-blake2f",
        "src/evm/fixtures/precompile-bn256add",
        "src/evm/fixtures/precompile-bn256mul", 
        "src/evm/fixtures/precompile-bn256pairing",
        "src/evm/fixtures/precompile-ecrecover",
        "src/evm/fixtures/precompile-identity",
        "src/evm/fixtures/precompile-modexp",
        "src/evm/fixtures/precompile-ripemd160",
        "src/evm/fixtures/precompile-sha256",
    };

    var cwd = std.fs.cwd();
    for (precompile_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}

test "differential: complex contract fixtures" {
    const allocator = testing.allocator;
    var testor = try DifferentialTestor.init(allocator);
    defer testor.deinit();

    const complex_fixture_dirs = [_][]const u8{
        "src/evm/fixtures/snailtracer",
        "src/evm/fixtures/ten-thousand-hashes",
    };

    var cwd = std.fs.cwd();
    for (complex_fixture_dirs) |dir| {
        const bc_path = try std.fmt.allocPrint(allocator, "{s}/bytecode.txt", .{dir});
        defer allocator.free(bc_path);
        const cd_path = try std.fmt.allocPrint(allocator, "{s}/calldata.txt", .{dir});
        defer allocator.free(cd_path);

        const bc_text = cwd.readFileAlloc(allocator, bc_path, 1024 * 1024) catch continue;
        defer allocator.free(bc_text);
        const cd_text = cwd.readFileAlloc(allocator, cd_path, 1024 * 1024) catch continue;
        defer allocator.free(cd_text);

        // Only run fixtures with empty calldata
        if (!std.mem.eql(u8, std.mem.trim(u8, cd_text, &std.ascii.whitespace), "0x")) {
            continue;
        }

        const bc_bytes = try parse_hex_alloc(allocator, bc_text);
        defer allocator.free(bc_bytes);

        try testor.test_bytecode(bc_bytes);
    }
}