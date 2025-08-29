/// Benchmarks for bytecode analysis performance
const std = @import("std");
const zbench = @import("zbench");
const Bytecode = @import("bytecode.zig").Bytecode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Opcode = @import("opcode.zig").Opcode;

/// Generate bytecode with no jumps - just normal opcodes
fn generateNoJumpsBytecode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var code = try allocator.alloc(u8, size);
    var i: usize = 0;
    
    // Fill with a mix of simple opcodes (no PUSH, no JUMP/JUMPDEST)
    const simple_opcodes = [_]u8{
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.SUB),
        @intFromEnum(Opcode.DIV),
        @intFromEnum(Opcode.MOD),
        @intFromEnum(Opcode.LT),
        @intFromEnum(Opcode.GT),
        @intFromEnum(Opcode.EQ),
        @intFromEnum(Opcode.AND),
        @intFromEnum(Opcode.OR),
        @intFromEnum(Opcode.XOR),
        @intFromEnum(Opcode.NOT),
        @intFromEnum(Opcode.DUP1),
        @intFromEnum(Opcode.SWAP1),
        @intFromEnum(Opcode.POP),
    };
    
    while (i < size) : (i += 1) {
        code[i] = simple_opcodes[i % simple_opcodes.len];
    }
    
    return code;
}

/// Generate bytecode with fusion candidates (PUSH followed by fusable opcodes)
fn generateFusionBytecode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    var code = try allocator.alloc(u8, size);
    var i: usize = 0;
    
    // Fusable opcodes that can follow PUSH (excluding JUMP/JUMPI which need valid destinations)
    const fusable_ops = [_]u8{
        @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.SUB),
        @intFromEnum(Opcode.DIV),
        @intFromEnum(Opcode.AND),
        @intFromEnum(Opcode.OR),
        @intFromEnum(Opcode.XOR),
        @intFromEnum(Opcode.LT),
        @intFromEnum(Opcode.GT),
        @intFromEnum(Opcode.EQ),
    };
    
    while (i + 2 < size) {
        // PUSH1 followed by a fusable opcode
        code[i] = @intFromEnum(Opcode.PUSH1);
        code[i + 1] = @truncate(i); // Some push data
        code[i + 2] = fusable_ops[(i / 3) % fusable_ops.len];
        i += 3;
    }
    
    // Fill remaining bytes
    while (i < size) : (i += 1) {
        code[i] = @intFromEnum(Opcode.STOP);
    }
    
    return code;
}

/// Load bytecode from a file
fn loadBytecodeFromFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    
    const content = try file.readToEndAlloc(allocator, 1024 * 1024); // Max 1MB
    defer allocator.free(content);
    
    // Parse hex string (remove 0x prefix if present)
    const hex_start: usize = if (std.mem.startsWith(u8, content, "0x")) 2 else 0;
    const hex_content = std.mem.trim(u8, content[hex_start..], " \n\r\t");
    
    var bytecode = try allocator.alloc(u8, hex_content.len / 2);
    var i: usize = 0;
    while (i < hex_content.len) : (i += 2) {
        const byte = try std.fmt.parseInt(u8, hex_content[i..i + 2], 16);
        bytecode[i / 2] = byte;
    }
    
    return bytecode;
}

// Benchmark functions
fn benchmarkNoJumps4(allocator: std.mem.Allocator) void {
    const code = generateNoJumpsBytecode(allocator, 1000) catch |err| {
        std.debug.print("Failed to generate no jumps bytecode: {}\n", .{err});
        return;
    };
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch |err| {
        std.debug.print("Failed to init no jumps bytecode: {}\n", .{err});
        return;
    };
    defer bytecode.deinit();
}

fn benchmarkNoJumps5(allocator: std.mem.Allocator) void {
    const code = generateNoJumpsBytecode(allocator, 1000) catch |err| {
        std.debug.print("Failed to generate no jumps bytecode: {}\n", .{err});
        return;
    };
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch |err| {
        std.debug.print("Failed to init no jumps bytecode: {}\n", .{err});
        return;
    };
    defer bytecode.deinit();
}

fn benchmarkFusions4(allocator: std.mem.Allocator) void {
    const code = generateFusionBytecode(allocator, 1000) catch |err| {
        std.debug.print("Failed to generate fusion bytecode: {}\n", .{err});
        return;
    };
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch |err| {
        std.debug.print("Failed to init fusion bytecode: {}\n", .{err});
        return;
    };
    defer bytecode.deinit();
}

fn benchmarkFusions5(allocator: std.mem.Allocator) void {
    const code = generateFusionBytecode(allocator, 1000) catch |err| {
        std.debug.print("Failed to generate fusion bytecode: {}\n", .{err});
        return;
    };
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch |err| {
        std.debug.print("Failed to init fusion bytecode: {}\n", .{err});
        return;
    };
    defer bytecode.deinit();
}

fn benchmarkERC204(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/erc20-transfer/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

fn benchmarkERC205(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/erc20-transfer/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

fn benchmarkSnailTracer4(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/snailtracer/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

fn benchmarkSnailTracer5(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/snailtracer/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

fn benchmarkTenThousandHashes4(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/ten-thousand-hashes/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

fn benchmarkTenThousandHashes5(allocator: std.mem.Allocator) void {
    const code = loadBytecodeFromFile(allocator, "bench/cases/ten-thousand-hashes/bytecode.txt") catch unreachable;
    defer allocator.free(code);
    
    var bytecode = Bytecode(BytecodeConfig{}).init(allocator, code) catch unreachable;
    defer bytecode.deinit();
    
}

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bench = zbench.Benchmark.init(allocator, .{
        .iterations = 100,  // Run fewer iterations for testing
    });
    defer bench.deinit();

    try stdout.print("\\n🚀 Bytecode Analysis Benchmarks\\n", .{});
    try stdout.print("================================\\n\\n", .{});
    try stdout.flush();

    try stdout.print("Adding benchmarks...\\n", .{});
    try stdout.flush();
    
    try bench.add("bytecode4/no_jumps_1000", benchmarkNoJumps4, .{});
    try bench.add("bytecode5/no_jumps_1000", benchmarkNoJumps5, .{});
    try bench.add("bytecode4/fusions_1000", benchmarkFusions4, .{});
    try bench.add("bytecode5/fusions_1000", benchmarkFusions5, .{});
    try bench.add("bytecode4/erc20", benchmarkERC204, .{});
    try bench.add("bytecode5/erc20", benchmarkERC205, .{});
    try bench.add("bytecode4/snailtracer", benchmarkSnailTracer4, .{});
    try bench.add("bytecode5/snailtracer", benchmarkSnailTracer5, .{});
    try bench.add("bytecode4/10k_hashes", benchmarkTenThousandHashes4, .{});
    try bench.add("bytecode5/10k_hashes", benchmarkTenThousandHashes5, .{});

    try stdout.print("Running benchmarks...\\n\\n", .{});
    try stdout.flush();
    try bench.run(stdout);
}

// Test that benchmarks compile and work correctly
test "bytecode benchmarks compile" {
    const allocator = std.testing.allocator;
    
    // Test no jumps generation
    const no_jumps = try generateNoJumpsBytecode(allocator, 100);
    defer allocator.free(no_jumps);
    try std.testing.expectEqual(@as(usize, 100), no_jumps.len);
    
    // Test fusion generation
    const fusion = try generateFusionBytecode(allocator, 100);
    defer allocator.free(fusion);
    try std.testing.expectEqual(@as(usize, 100), fusion.len);
    
    // Verify first fusion pattern
    try std.testing.expectEqual(@intFromEnum(Opcode.PUSH1), fusion[0]);
    try std.testing.expectEqual(@intFromEnum(Opcode.ADD), fusion[2]); // First fusable op
}

test "bytecode analysis on generated code" {
    const allocator = std.testing.allocator;
    
    // Test with no jumps code
    const no_jumps = try generateNoJumpsBytecode(allocator, 50);
    defer allocator.free(no_jumps);
    
    var bytecode1 = try Bytecode(BytecodeConfig{}).init(allocator, no_jumps);
    defer bytecode1.deinit();
    
    // Check that no JUMPDESTs were found
    var has_jumpdest = false;
    for (0..no_jumps.len) |i| {
        if (bytecode1.isValidJumpDest(@intCast(i))) has_jumpdest = true;
    }
    try std.testing.expect(!has_jumpdest);
    
    // Test with fusion code
    const fusion = try generateFusionBytecode(allocator, 30);
    defer allocator.free(fusion);
    
    var bytecode2 = try Bytecode(BytecodeConfig{}).init(allocator, fusion);
    defer bytecode2.deinit();
    
    // Just verify it initializes without error
    try std.testing.expect(bytecode2.runtime_code.len > 0);
}
