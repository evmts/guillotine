const std = @import("std");
const micro = @import("micro");
const bytecode_mod = @import("bytecode");
const Bytecode = bytecode_mod.Bytecode(.{});
const BytecodeNoFusion = bytecode_mod.Bytecode(.{ .fusions_enabled = false });

fn makeNoJumpsCode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const code = try allocator.alloc(u8, size);
    const ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x10, 0x11, 0x14, 0x16, 0x17, 0x18, 0x80, 0x90, 0x50 };
    for (code, 0..) |*b, i| b.* = ops[i % ops.len];
    code[size - 1] = 0x00;
    return code;
}

fn makeFusionHeavyCode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const code = try allocator.alloc(u8, size);
    const ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x16, 0x17, 0x18, 0x51, 0x52 };
    var i: usize = 0;
    while (i + 3 < size) : (i += 3) {
        code[i] = 0x60; // PUSH1
        code[i + 1] = @truncate(i);
        code[i + 2] = ops[(i / 3) % ops.len];
    }
    while (i < size) : (i += 1) code[i] = 0x00;
    return code;
}

fn makeJumpHeavyCode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const code = try allocator.alloc(u8, size);
    var i: usize = 0;
    while (i + 6 < size) : (i += 6) {
        const next_pc: u16 = @intCast(i + 6);
        code[i] = 0x5b; // JUMPDEST
        code[i + 1] = 0x61; // PUSH2
        code[i + 2] = @truncate(next_pc >> 8);
        code[i + 3] = @truncate(next_pc);
        code[i + 4] = 0x57; // JUMPI
        code[i + 5] = 0x01; // ADD
    }
    while (i < size) : (i += 1) code[i] = 0x5b;
    return code;
}

fn makePush32HeavyCode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const code = try allocator.alloc(u8, size);
    var i: usize = 0;
    while (i + 34 < size) : (i += 34) {
        code[i] = 0x7f; // PUSH32
        for (1..33) |j| code[i + j] = @truncate(i + j);
        code[i + 33] = 0x50; // POP
    }
    while (i < size) : (i += 1) code[i] = 0x00;
    return code;
}

fn benchAnalyzeNoJumps4KB(allocator: std.mem.Allocator) !u64 {
    const code = try makeNoJumpsCode(allocator, 4096);
    defer allocator.free(code);
    var bc = try Bytecode.init(allocator, code);
    defer bc.deinit();
    return bc.len() + bc.packed_bitmap.len;
}

fn benchAnalyzeFusion4KB(allocator: std.mem.Allocator) !u64 {
    const code = try makeFusionHeavyCode(allocator, 4096);
    defer allocator.free(code);
    var bc = try Bytecode.init(allocator, code);
    defer bc.deinit();
    return bc.len() + bc.packed_bitmap.len;
}

fn benchAnalyzeFusion4KBDisabled(allocator: std.mem.Allocator) !u64 {
    const code = try makeFusionHeavyCode(allocator, 4096);
    defer allocator.free(code);
    var bc = try BytecodeNoFusion.init(allocator, code);
    defer bc.deinit();
    return bc.len() + bc.packed_bitmap.len;
}

fn benchAnalyzeJumpHeavy4KB(allocator: std.mem.Allocator) !u64 {
    const code = try makeJumpHeavyCode(allocator, 4096);
    defer allocator.free(code);
    var bc = try Bytecode.init(allocator, code);
    defer bc.deinit();
    return bc.len() + bc.packed_bitmap.len;
}

fn benchAnalyzePush32Heavy16KB(allocator: std.mem.Allocator) !u64 {
    const code = try makePush32HeavyCode(allocator, 16384);
    defer allocator.free(code);
    var bc = try Bytecode.init(allocator, code);
    defer bc.deinit();
    return bc.len() + bc.packed_bitmap.len;
}

fn benchJumpDestLookup(allocator: std.mem.Allocator) !u64 {
    const code = try makeJumpHeavyCode(allocator, 4096);
    defer allocator.free(code);
    var bc = try Bytecode.init(allocator, code);
    defer bc.deinit();
    var hits: u64 = 0;
    for (0..256) |_| {
        for (0..4096) |pc| {
            if (bc.isValidJumpDest(@intCast(pc))) hits += 1;
        }
    }
    return hits;
}

pub fn main() void {
    micro.runSuite("bytecode", &.{
        .{ .name = "bytecode/analyze-no-jumps-4KB", .operations = 1, .bytes = 4096, .run = benchAnalyzeNoJumps4KB },
        .{ .name = "bytecode/analyze-fusion-4KB", .operations = 1, .bytes = 4096, .run = benchAnalyzeFusion4KB },
        .{ .name = "bytecode/analyze-no-fusion-4KB", .operations = 1, .bytes = 4096, .run = benchAnalyzeFusion4KBDisabled },
        .{ .name = "bytecode/analyze-jump-heavy-4KB", .operations = 1, .bytes = 4096, .run = benchAnalyzeJumpHeavy4KB },
        .{ .name = "bytecode/analyze-push32-16KB", .operations = 1, .bytes = 16384, .run = benchAnalyzePush32Heavy16KB },
        .{ .name = "bytecode/jumpdest-lookup-1M", .operations = 256 * 4096, .run = benchJumpDestLookup },
    });
}
