const std = @import("std");
const evm = @import("evm");
const BytecodeStats = evm.BytecodeStats;
const Opcode = evm.Opcode;

const Config = struct {
    verbose: bool = false,
    show_all: bool = false,
    min_count: u32 = 2,
    max_files: ?usize = null,
};

const PatternStats = struct {
    files_analyzed: usize = 0,
    total_bytes: usize = 0,
    unique_opcodes: usize = 0,
    patterns_2: std.AutoHashMap([2]u8, u32),
    patterns_3: std.AutoHashMap([3]u8, u32),
    patterns_4: std.AutoHashMap([4]u8, u32),
    patterns_5: std.AutoHashMap([5]u8, u32),
    patterns_6: std.AutoHashMap([6]u8, u32),
    patterns_7: std.AutoHashMap([7]u8, u32),
    patterns_8: std.AutoHashMap([8]u8, u32),
    
    fn init(allocator: std.mem.Allocator) PatternStats {
        return .{
            .patterns_2 = std.AutoHashMap([2]u8, u32).init(allocator),
            .patterns_3 = std.AutoHashMap([3]u8, u32).init(allocator),
            .patterns_4 = std.AutoHashMap([4]u8, u32).init(allocator),
            .patterns_5 = std.AutoHashMap([5]u8, u32).init(allocator),
            .patterns_6 = std.AutoHashMap([6]u8, u32).init(allocator),
            .patterns_7 = std.AutoHashMap([7]u8, u32).init(allocator),
            .patterns_8 = std.AutoHashMap([8]u8, u32).init(allocator),
        };
    }
    
    fn deinit(self: *PatternStats) void {
        self.patterns_2.deinit();
        self.patterns_3.deinit();
        self.patterns_4.deinit();
        self.patterns_5.deinit();
        self.patterns_6.deinit();
        self.patterns_7.deinit();
        self.patterns_8.deinit();
    }
};

fn analyzeFile(allocator: std.mem.Allocator, path: []const u8, stats: *PatternStats, config: Config) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024 * 10); // 10MB max
    defer allocator.free(content);

    // Trim whitespace and get bytecode
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    
    // Remove 0x prefix if present
    const bytecode_str = if (std.mem.startsWith(u8, trimmed, "0x"))
        trimmed[2..]
    else
        trimmed;

    // Convert hex string to bytes
    const bytecode_len = bytecode_str.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);
    
    for (0..bytecode_len) |i| {
        const byte_str = bytecode_str[i * 2 .. i * 2 + 2];
        bytecode[i] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    if (config.verbose) {
        std.debug.print("  📍 {s}: {} bytes\n", .{ std.fs.path.basename(path), bytecode.len });
    }
    
    stats.files_analyzed += 1;
    stats.total_bytes += bytecode.len;
    
    // Analyze with BytecodeStats
    var analysis = try BytecodeStats.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Count unique opcodes
    for (analysis.opcode_counts) |count| {
        if (count > 0) stats.unique_opcodes += 1;
    }
    
    // Aggregate patterns
    for (analysis.patterns_2) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [2]u8 = pattern.opcodes[0..2].*;
        const result = try stats.patterns_2.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_3) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [3]u8 = pattern.opcodes[0..3].*;
        const result = try stats.patterns_3.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_4) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [4]u8 = pattern.opcodes[0..4].*;
        const result = try stats.patterns_4.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_5) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [5]u8 = pattern.opcodes[0..5].*;
        const result = try stats.patterns_5.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_6) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [6]u8 = pattern.opcodes[0..6].*;
        const result = try stats.patterns_6.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_7) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [7]u8 = pattern.opcodes[0..7].*;
        const result = try stats.patterns_7.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
    
    for (analysis.patterns_8) |pattern| {
        if (pattern.count < config.min_count) break;
        const key: [8]u8 = pattern.opcodes[0..8].*;
        const result = try stats.patterns_8.getOrPut(key);
        if (result.found_existing) {
            result.value_ptr.* += pattern.count;
        } else {
            result.value_ptr.* = pattern.count;
        }
    }
}

fn printTopPatterns(comptime N: usize, map: anytype, config: Config) void {
    const Entry = struct {
        pattern: [N]u8,
        count: u32,
    };
    
    var entries = std.ArrayList(Entry).initCapacity(std.heap.page_allocator, map.count()) catch return;
    defer entries.deinit(std.heap.page_allocator);
    
    var iter = map.iterator();
    while (iter.next()) |entry| {
        entries.append(std.heap.page_allocator, .{
            .pattern = entry.key_ptr.*,
            .count = entry.value_ptr.*,
        }) catch continue;
    }
    
    // Sort by count
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.count > b.count;
        }
    }.lessThan);
    
    const limit = if (config.show_all) entries.items.len else @min(3, entries.items.len);
    for (entries.items[0..limit], 0..) |entry, i| {
        std.debug.print("    {}. ", .{i + 1});
        printPattern(&entry.pattern);
        std.debug.print(" × {} occurrences\n", .{entry.count});
    }
}

fn printPattern(pattern: []const u8) void {
    std.debug.print("[", .{});
    for (pattern, 0..) |op, i| {
        if (i > 0) std.debug.print(", ", .{});
        const opcode_enum = std.meta.intToEnum(Opcode, op) catch {
            std.debug.print("0x{x:0>2}", .{op});
            continue;
        };
        // Print short names for common opcodes
        const name = switch (opcode_enum) {
            .PUSH1 => "PUSH1",
            .PUSH2 => "PUSH2",
            .DUP1 => "DUP1",
            .DUP2 => "DUP2",
            .SWAP1 => "SWAP1",
            .POP => "POP",
            .ADD => "ADD",
            .SUB => "SUB",
            .MSTORE => "MSTORE",
            .MLOAD => "MLOAD",
            .SSTORE => "SSTORE",
            .SLOAD => "SLOAD",
            .JUMP => "JUMP",
            .JUMPI => "JUMPI",
            .JUMPDEST => "JDEST",
            else => @tagName(opcode_enum),
        };
        std.debug.print("{s}", .{name});
    }
    std.debug.print("]", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: {s} <bytecode_file_or_directory> [options]\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --verbose        Show detailed output\n", .{});
        std.debug.print("  --max-files N    Limit to N test cases\n", .{});
        std.debug.print("  --min-count N    Only show patterns with count >= N\n", .{});
        std.debug.print("  --all           Show all patterns (not just top 3)\n", .{});
        std.debug.print("\nExamples:\n", .{});
        std.debug.print("  {s} src/solidity/erc20_bytecode.txt\n", .{args[0]});
        std.debug.print("  {s} src/solidity/ --verbose\n", .{args[0]});
        return;
    }

    const input_path = args[1];
    var config = Config{};
    
    // Parse options
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--verbose")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            config.show_all = true;
        } else if (std.mem.eql(u8, args[i], "--min-count") and i + 1 < args.len) {
            i += 1;
            config.min_count = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--max-files") and i + 1 < args.len) {
            i += 1;
            config.max_files = try std.fmt.parseInt(usize, args[i], 10);
        }
    }
    
    var stats = PatternStats.init(allocator);
    defer stats.deinit();
    
    std.debug.print("\n📊 Bytecode Pattern Analysis\n", .{});
    std.debug.print("=" ** 60 ++ "\n", .{});
    
    // Process single file or directory
    const stat = try std.fs.cwd().statFile(input_path);
    if (stat.kind == .directory) {
        var dir = try std.fs.cwd().openDir(input_path, .{ .iterate = true });
        defer dir.close();

        var iter = dir.iterate();
        var file_count: usize = 0;
        while (try iter.next()) |entry| {
            if (config.max_files) |max| {
                if (file_count >= max) break;
            }
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".txt")) {
                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ input_path, entry.name });
                defer allocator.free(full_path);

                if (config.verbose) {
                    std.debug.print("Analyzing {s}...\n", .{full_path});
                }
                analyzeFile(allocator, full_path, &stats, config) catch |err| {
                    std.debug.print("Error analyzing {s}: {}\n", .{ full_path, err });
                };
                file_count += 1;
            }
        }
    } else {
        try analyzeFile(allocator, input_path, &stats, config);
    }
    
    // Print results
    std.debug.print("\n📈 Summary\n", .{});
    std.debug.print("  Files analyzed: {}\n", .{stats.files_analyzed});
    std.debug.print("  Total bytecode: {} bytes\n", .{stats.total_bytes});
    std.debug.print("  Unique opcodes: {}\n", .{stats.unique_opcodes});
    
    std.debug.print("\n🔍 Most Common 2-Opcode Patterns:\n", .{});
    printTopPatterns(2, stats.patterns_2, config);
    
    std.debug.print("\n🔍 Most Common 3-Opcode Patterns:\n", .{});
    printTopPatterns(3, stats.patterns_3, config);
    
    std.debug.print("\n🔍 Most Common 4-Opcode Patterns:\n", .{});
    printTopPatterns(4, stats.patterns_4, config);
    
    std.debug.print("\n🔍 Most Common 5-Opcode Patterns:\n", .{});
    printTopPatterns(5, stats.patterns_5, config);
    
    std.debug.print("\n🔍 Most Common 6-Opcode Patterns:\n", .{});
    printTopPatterns(6, stats.patterns_6, config);
    
    std.debug.print("\n🔍 Most Common 7-Opcode Patterns:\n", .{});
    printTopPatterns(7, stats.patterns_7, config);
    
    std.debug.print("\n🔍 Most Common 8-Opcode Patterns:\n", .{});
    printTopPatterns(8, stats.patterns_8, config);
}