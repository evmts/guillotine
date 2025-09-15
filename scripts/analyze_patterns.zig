const std = @import("std");
const evm = @import("evm");
const BytecodeStats = evm.BytecodeStats;
const Opcode = evm.Opcode;

const Config = struct {
    verbose: bool = false,
    show_all_patterns: bool = false,
    min_pattern_count: u32 = 2,
    max_files: ?usize = null,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    var file_path: ?[]const u8 = null;

    // Parse arguments
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--verbose") or std.mem.eql(u8, args[i], "-v")) {
            config.verbose = true;
        } else if (std.mem.eql(u8, args[i], "--all")) {
            config.show_all_patterns = true;
        } else if (std.mem.eql(u8, args[i], "--min-count")) {
            i += 1;
            if (i < args.len) {
                config.min_pattern_count = try std.fmt.parseInt(u32, args[i], 10);
            }
        } else if (std.mem.eql(u8, args[i], "--max-files")) {
            i += 1;
            if (i < args.len) {
                config.max_files = try std.fmt.parseInt(usize, args[i], 10);
            }
        } else if (!std.mem.startsWith(u8, args[i], "--")) {
            file_path = args[i];
        }
    }

    if (file_path == null) {
        std.debug.print("Usage: {s} <json_fixture_file> [options]\n", .{args[0]});
        std.debug.print("Options:\n", .{});
        std.debug.print("  --verbose, -v     Show detailed output\n", .{});
        std.debug.print("  --all            Show all patterns (not just top 3)\n", .{});
        std.debug.print("  --min-count N    Only show patterns with count >= N\n", .{});
        std.debug.print("  --max-files N    Limit analysis to first N test cases\n", .{});
        return;
    }

    // Read and parse the JSON file
    const file = try std.fs.cwd().openFile(file_path.?, .{});
    defer file.close();

    const file_size = try file.getEndPos();
    const content = try allocator.alloc(u8, file_size);
    defer allocator.free(content);
    _ = try file.read(content);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
    defer parsed.deinit();

    std.debug.print("\n📊 Analyzing bytecode patterns in {s}\n", .{std.fs.path.basename(file_path.?)});
    std.debug.print("=" ** 60 ++ "\n", .{});

    var stats = AnalysisStats{};
    
    // Handle both object and array JSON structures
    if (parsed.value == .object) {
        var test_iter = parsed.value.object.iterator();
        while (test_iter.next()) |test_entry| {
            if (config.max_files) |max| {
                if (stats.tests_analyzed >= max) break;
            }
            
            const test_data = test_entry.value_ptr.*;
            if (test_data == .object) {
                try analyzeTestCase(allocator, test_data, test_entry.key_ptr.*, &stats, config);
            }
        }
    } else if (parsed.value == .array) {
        for (parsed.value.array.items, 0..) |test_case, idx| {
            if (config.max_files) |max| {
                if (stats.tests_analyzed >= max) break;
            }
            
            if (test_case == .object) {
                var test_name_buf: [256]u8 = undefined;
                const test_name = try std.fmt.bufPrint(&test_name_buf, "Test_{}", .{idx});
                try analyzeTestCase(allocator, test_case, test_name, &stats, config);
            }
        }
    }

    // Print summary
    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("📈 Analysis Summary\n", .{});
    std.debug.print("  Tests analyzed: {}\n", .{stats.tests_analyzed});
    std.debug.print("  Accounts with code: {}\n", .{stats.accounts_with_code});
    std.debug.print("  Total bytecode: {} bytes\n", .{stats.total_bytecode_bytes});
    std.debug.print("  Unique opcodes used: {}\n", .{stats.unique_opcodes});
    
    if (stats.most_common_pattern_2) |pattern| {
        std.debug.print("\n  Most common 2-opcode pattern: ", .{});
        printPatternOpcodes(pattern.opcodes);
        std.debug.print(" ({} occurrences)\n", .{pattern.count});
    }
    
    if (stats.most_common_pattern_3) |pattern| {
        std.debug.print("  Most common 3-opcode pattern: ", .{});
        printPatternOpcodes(pattern.opcodes);
        std.debug.print(" ({} occurrences)\n", .{pattern.count});
    }
}

const AnalysisStats = struct {
    tests_analyzed: usize = 0,
    accounts_with_code: usize = 0,
    total_bytecode_bytes: usize = 0,
    unique_opcodes: usize = 0,
    most_common_pattern_2: ?PatternInfo = null,
    most_common_pattern_3: ?PatternInfo = null,
};

const PatternInfo = struct {
    opcodes: []const u8,
    count: u32,
};

fn analyzeTestCase(
    allocator: std.mem.Allocator,
    test_data: std.json.Value,
    test_name: []const u8,
    stats: *AnalysisStats,
    config: Config,
) !void {
    var found_code = false;
    
    // Look in pre state
    if (test_data.object.get("pre")) |pre| {
        if (pre == .object) {
            var iter = pre.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.*.object.get("code")) |code| {
                        if (code == .string and code.string.len > 2) {
                            if (!found_code and config.verbose) {
                                std.debug.print("\n🔍 {s}\n", .{test_name});
                            }
                            try analyzeCode(allocator, code.string, entry.key_ptr.*, stats, config);
                            found_code = true;
                        }
                    }
                }
            }
        }
    }
    
    // Look in post state
    if (test_data.object.get("postState")) |post| {
        if (post == .object) {
            var iter = post.object.iterator();
            while (iter.next()) |entry| {
                if (entry.value_ptr.* == .object) {
                    if (entry.value_ptr.*.object.get("code")) |code| {
                        if (code == .string and code.string.len > 2) {
                            if (!found_code and config.verbose) {
                                std.debug.print("\n🔍 {s}\n", .{test_name});
                            }
                            try analyzeCode(allocator, code.string, entry.key_ptr.*, stats, config);
                            found_code = true;
                        }
                    }
                }
            }
        }
    }
    
    if (found_code) {
        stats.tests_analyzed += 1;
    }
}

fn analyzeCode(
    allocator: std.mem.Allocator,
    hex_code: []const u8,
    address: []const u8,
    stats: *AnalysisStats,
    config: Config,
) !void {
    const code_str = if (std.mem.startsWith(u8, hex_code, "0x")) hex_code[2..] else hex_code;
    if (code_str.len == 0) return;
    
    const bytecode_len = code_str.len / 2;
    const bytecode = try allocator.alloc(u8, bytecode_len);
    defer allocator.free(bytecode);
    
    for (0..bytecode_len) |i| {
        const byte_str = code_str[i * 2 .. i * 2 + 2];
        bytecode[i] = try std.fmt.parseInt(u8, byte_str, 16);
    }
    
    if (config.verbose) {
        std.debug.print("  📍 {s}: {} bytes\n", .{ address, bytecode.len });
    }
    
    stats.accounts_with_code += 1;
    stats.total_bytecode_bytes += bytecode.len;
    
    var analysis = try BytecodeStats.analyze(allocator, bytecode);
    defer analysis.deinit(allocator);
    
    // Count unique opcodes
    for (analysis.opcode_counts) |count| {
        if (count > 0) stats.unique_opcodes += 1;
    }
    
    // Update most common patterns
    if (analysis.patterns_2.len > 0) {
        if (stats.most_common_pattern_2 == null or 
            analysis.patterns_2[0].count > stats.most_common_pattern_2.?.count) {
            // Need to copy the pattern data
            const opcodes_copy = try allocator.dupe(u8, analysis.patterns_2[0].opcodes);
            if (stats.most_common_pattern_2) |old| {
                allocator.free(old.opcodes);
            }
            stats.most_common_pattern_2 = PatternInfo{
                .opcodes = opcodes_copy,
                .count = analysis.patterns_2[0].count,
            };
        }
    }
    
    if (analysis.patterns_3.len > 0) {
        if (stats.most_common_pattern_3 == null or 
            analysis.patterns_3[0].count > stats.most_common_pattern_3.?.count) {
            const opcodes_copy = try allocator.dupe(u8, analysis.patterns_3[0].opcodes);
            if (stats.most_common_pattern_3) |old| {
                allocator.free(old.opcodes);
            }
            stats.most_common_pattern_3 = PatternInfo{
                .opcodes = opcodes_copy,
                .count = analysis.patterns_3[0].count,
            };
        }
    }
    
    if (config.verbose) {
        // Show top patterns for this contract
        if (analysis.patterns_2.len > 0) {
            std.debug.print("    Top 2-patterns: ", .{});
            const limit = if (config.show_all_patterns) analysis.patterns_2.len else @min(2, analysis.patterns_2.len);
            for (analysis.patterns_2[0..limit], 0..) |pattern, idx| {
                if (pattern.count < config.min_pattern_count) continue;
                if (idx > 0) std.debug.print(", ", .{});
                printPatternOpcodes(pattern.opcodes);
                std.debug.print(" ×{}", .{pattern.count});
            }
            std.debug.print("\n", .{});
        }
        
        if (analysis.patterns_3.len > 0) {
            std.debug.print("    Top 3-patterns: ", .{});
            const limit = if (config.show_all_patterns) analysis.patterns_3.len else @min(2, analysis.patterns_3.len);
            for (analysis.patterns_3[0..limit], 0..) |pattern, idx| {
                if (pattern.count < config.min_pattern_count) continue;
                if (idx > 0) std.debug.print(", ", .{});
                printPatternOpcodes(pattern.opcodes);
                std.debug.print(" ×{}", .{pattern.count});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn printPatternOpcodes(opcodes: []const u8) void {
    std.debug.print("[", .{});
    for (opcodes, 0..) |op, i| {
        if (i > 0) std.debug.print(",", .{});
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
            .MUL => "MUL",
            .DIV => "DIV",
            .MSTORE => "MSTORE",
            .MLOAD => "MLOAD",
            .SSTORE => "SSTORE",
            .SLOAD => "SLOAD",
            .JUMP => "JUMP",
            .JUMPI => "JUMPI",
            .JUMPDEST => "JDEST",
            .RETURN => "RET",
            .STOP => "STOP",
            .CALLDATASIZE => "CSIZE",
            .CALLDATALOAD => "CLOAD",
            .CODECOPY => "CCOPY",
            else => @tagName(opcode_enum),
        };
        std.debug.print("{s}", .{name});
    }
    std.debug.print("]", .{});
}