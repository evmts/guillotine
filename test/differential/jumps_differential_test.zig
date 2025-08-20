const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

fn runBoth(bytecode: []const u8, gas: u64) !struct { ok1: bool, out1: []const u8, ok2: bool, out2: ?[]const u8 } {
    const allocator = testing.allocator;
    // REVM
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract = try Address.from_hex("0x2222222222222222222222222222222222222222");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(contract, bytecode);
    var r = try revm_vm.call(caller, contract, 0, &[_]u8{}, gas);
    const r_out_copy = try allocator.dupe(u8, r.output);
    defer r.deinit();
    // Zig
    const MemoryDatabase = evm.MemoryDatabase;
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(contract, bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &[_]u8{}, .gas = gas } };
    const z = try vm.call(params);
    // Copy the output since VM owns it
    const z_out_copy = if (z.output) |out| try allocator.dupe(u8, out) else null;
    return .{ .ok1 = r.success, .out1 = r_out_copy, .ok2 = z.success, .out2 = z_out_copy };
}

// Repro 1: conditional_jump_unresolved pop order (condition, dest) => take branch
test "jumps: JUMPI dynamic pop order matches REVM (condition first)" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x06, // PUSH1 6 (dest pc)
        0x57, // JUMPI -> should jump to pc=4
        0x00, // STOP (not executed)
        0x5b, // JUMPDEST at pc=6
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const res = try runBoth(&bytecode, 1_000_000);
    try testing.expectEqual(res.ok1, res.ok2);
    if (res.ok1 and res.ok2) {
        try testing.expect(res.out2 != null);
        try testing.expectEqual(@as(usize, 32), res.out1.len);
        try testing.expectEqual(@as(usize, 32), res.out2.?.len);
        const v1 = std.mem.readInt(u256, res.out1[0..32], .big);
        const v2 = std.mem.readInt(u256, res.out2.?[0..32], .big);
        try testing.expectEqual(v1, v2);
        try testing.expectEqual(@as(u256, 42), v1);
    }
    allocator.free(res.out1);
    if (res.out2) |o| allocator.free(o);
}

// Repro 2: resolved conditional jump should also consume destination
test "jumps: resolved conditional jump consumes destination like REVM" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x07, // PUSH1 7 (dest pc)
        0x57, // JUMPI -> resolved via preceding PUSH
        0x60, 0x00, // PUSH1 0 (padding fallthrough)
        0x5b, // JUMPDEST at pc=7
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const res = try runBoth(&bytecode, 1_000_000);
    try testing.expectEqual(res.ok1, res.ok2);
    if (res.ok1 and res.ok2) {
        try testing.expect(res.out2 != null);
        try testing.expectEqual(@as(usize, 32), res.out1.len);
        try testing.expectEqual(@as(usize, 32), res.out2.?.len);
        const v1 = std.mem.readInt(u256, res.out1[0..32], .big);
        const v2 = std.mem.readInt(u256, res.out2.?[0..32], .big);
        try testing.expectEqual(v1, v2);
        try testing.expectEqual(@as(u256, 42), v1);
    }
    allocator.free(res.out1);
    if (res.out2) |o| allocator.free(o);
}
