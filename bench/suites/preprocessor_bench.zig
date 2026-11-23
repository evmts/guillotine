const std = @import("std");
const micro = @import("micro");
const evm = @import("guillotine");

const FusedEvm = evm.Evm(.{
    .eips = .{ .hardfork = .OSAKA },
    .enable_fusion = true,
    .tracer_config = .disabled,
});
const UnfusedEvm = evm.Evm(.{
    .eips = .{ .hardfork = .OSAKA },
    .enable_fusion = false,
    .tracer_config = .disabled,
});

fn makeFusionHeavyCode(allocator: std.mem.Allocator, size: usize) ![]u8 {
    const code = try allocator.alloc(u8, size);
    const ops = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x16, 0x17, 0x18, 0x51, 0x52 };
    var i: usize = 0;
    while (i + 3 < size) : (i += 3) {
        code[i] = 0x60;
        code[i + 1] = @truncate(i);
        code[i + 2] = ops[(i / 3) % ops.len];
    }
    while (i < size) : (i += 1) code[i] = 0x00;
    return code;
}

fn makeJumpTableCode(allocator: std.mem.Allocator, blocks: usize) ![]u8 {
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    for (0..blocks) |b| {
        try code.append(allocator, 0x5b); // JUMPDEST
        try code.append(allocator, 0x60);
        try code.append(allocator, @truncate(b));
        try code.append(allocator, 0x50); // POP
    }
    try code.append(allocator, 0x00); // STOP
    return code.toOwnedSlice(allocator);
}

fn compileSchedule(comptime EvmT: type, allocator: std.mem.Allocator, code: []const u8) !usize {
    const Frame = EvmT.Frame;
    var bc = try EvmT.Bytecode.init(allocator, code);
    defer bc.deinit();
    const handlers = &Frame.opcode_handlers;
    var schedule = try Frame.Dispatch.DispatchSchedule.init(allocator, bc, handlers, null);
    defer schedule.deinit();
    return schedule.items.len;
}

fn benchDispatchCompileFused4KB(allocator: std.mem.Allocator) !u64 {
    const code = try makeFusionHeavyCode(allocator, 4096);
    defer allocator.free(code);
    return try compileSchedule(FusedEvm, allocator, code);
}

fn benchDispatchCompileUnfused4KB(allocator: std.mem.Allocator) !u64 {
    const code = try makeFusionHeavyCode(allocator, 4096);
    defer allocator.free(code);
    return try compileSchedule(UnfusedEvm, allocator, code);
}

fn benchJumpTableBuildAndLookup(allocator: std.mem.Allocator) !u64 {
    const Frame = FusedEvm.Frame;
    const blocks: usize = 256;
    const code = try makeJumpTableCode(allocator, blocks);
    defer allocator.free(code);
    var bc = try FusedEvm.Bytecode.init(allocator, code);
    defer bc.deinit();
    var schedule = try Frame.Dispatch.DispatchSchedule.init(allocator, bc, &Frame.opcode_handlers, null);
    defer schedule.deinit();
    const jt = try Frame.Dispatch.createJumpTable(allocator, schedule.items, bc);
    defer allocator.free(jt.entries);
    var hits: u64 = 0;
    for (0..blocks) |b| {
        const pc: Frame.PcType = @intCast(b * 4);
        if (jt.findJumpTarget(pc) != null) hits += 1;
    }
    return hits;
}

fn benchJumpTableLookupHot(allocator: std.mem.Allocator) !u64 {
    const Frame = FusedEvm.Frame;
    const blocks: usize = 256;
    const code = try makeJumpTableCode(allocator, blocks);
    defer allocator.free(code);
    var bc = try FusedEvm.Bytecode.init(allocator, code);
    defer bc.deinit();
    var schedule = try Frame.Dispatch.DispatchSchedule.init(allocator, bc, &Frame.opcode_handlers, null);
    defer schedule.deinit();
    const jt = try Frame.Dispatch.createJumpTable(allocator, schedule.items, bc);
    defer allocator.free(jt.entries);
    var hits: u64 = 0;
    for (0..2048) |i| {
        const pc: Frame.PcType = @intCast(((i * 37) % blocks) * 4);
        if (jt.findJumpTarget(pc) != null) hits += 1;
    }
    return hits;
}

pub fn main() void {
    // Touch Evm.init so Zig resolves Frame before DispatchSchedule
    _ = FusedEvm.init;
    _ = UnfusedEvm.init;
    micro.runSuite("preprocessor", &.{
        .{ .name = "preprocessor/dispatch-compile-fused-4KB", .operations = 1, .bytes = 4096, .run = benchDispatchCompileFused4KB },
        .{ .name = "preprocessor/dispatch-compile-unfused-4KB", .operations = 1, .bytes = 4096, .run = benchDispatchCompileUnfused4KB },
        .{ .name = "preprocessor/jumptable-build-lookup-256", .operations = 256, .run = benchJumpTableBuildAndLookup },
        .{ .name = "preprocessor/jumptable-lookup-2048", .operations = 2048, .run = benchJumpTableLookupHot },
    });
}
