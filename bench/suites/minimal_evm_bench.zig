const std = @import("std");
const micro = @import("micro");
const evm = @import("guillotine");
const MinimalEvm = evm.MinimalEvm;
const Address = evm.Primitives.Address;

fn buildAddBatch(allocator: std.mem.Allocator, reps: usize) ![]u8 {
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    try code.appendSlice(allocator, &.{ 0x60, 1 });
    for (0..reps) |_| try code.appendSlice(allocator, &.{ 0x60, 7, 0x01 });
    try code.appendSlice(allocator, &.{ 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xf3 });
    return code.toOwnedSlice(allocator);
}

fn buildFib32(allocator: std.mem.Allocator) ![]u8 {
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    try code.appendSlice(allocator, &.{ 0x60, 0, 0x60, 1 });
    for (0..32) |_| try code.appendSlice(allocator, &.{ 0x81, 0x01, 0x90 });
    try code.appendSlice(allocator, &.{ 0x50, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xf3 });
    return code.toOwnedSlice(allocator);
}

fn buildKeccakLoop(allocator: std.mem.Allocator, reps: usize) ![]u8 {
    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    for (0..reps) |_| try code.appendSlice(allocator, &.{ 0x60, 32, 0x60, 0, 0x20, 0x60, 0, 0x52 });
    try code.appendSlice(allocator, &.{ 0x60, 32, 0x60, 0, 0xf3 });
    return code.toOwnedSlice(allocator);
}

fn runMinimal(allocator: std.mem.Allocator, code: []const u8) !u64 {
    var vm = try MinimalEvm.init(allocator);
    defer vm.deinit();
    const caller = Address.fromU256(0x1000);
    const to = Address.fromU256(0x1001);
    const res = try vm.execute(code, 10_000_000, caller, to, 0, &.{});
    if (!res.success or res.output.len != 32) return error.MinimalEvmFailed;
    return std.mem.readInt(u64, res.output[24..32], .big);
}

fn benchMinimalAdd128(allocator: std.mem.Allocator) !u64 {
    const code = try buildAddBatch(allocator, 128);
    defer allocator.free(code);
    return runMinimal(allocator, code);
}

fn benchMinimalFib32(allocator: std.mem.Allocator) !u64 {
    const code = try buildFib32(allocator);
    defer allocator.free(code);
    const got = try runMinimal(allocator, code);
    if (got != 2178309) return error.UnexpectedFibResult;
    return got;
}

fn benchMinimalKeccak64(allocator: std.mem.Allocator) !u64 {
    const code = try buildKeccakLoop(allocator, 64);
    defer allocator.free(code);
    return runMinimal(allocator, code);
}

pub fn main() void {
    micro.runSuite("minimal-evm", &.{
        .{ .name = "minimal-evm/add-128", .operations = 128, .run = benchMinimalAdd128 },
        .{ .name = "minimal-evm/fibonacci-32", .operations = 32, .run = benchMinimalFib32 },
        .{ .name = "minimal-evm/keccak-64", .operations = 64, .run = benchMinimalKeccak64 },
    });
}
