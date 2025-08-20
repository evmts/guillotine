const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

// Repro for CALL-family pop-order bug: pass distinct small integers to verify mapping

fn runBoth(bytecode: []const u8, target: Address.Address, gas: u64) !struct { ok1: bool, out1: []const u8, ok2: bool, out2: ?[]const u8 } {
    const allocator = testing.allocator;
    // REVM
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x1111111111111111111111111111111111111111");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(target, bytecode);
    var r = try revm_vm.call(caller, target, 0, &[_]u8{}, gas);
    const r_out_copy = try allocator.dupe(u8, r.output);
    defer r.deinit();

    // Zig
    const MemoryDatabase = evm.MemoryDatabase;
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(target, bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = target, .value = 0, .input = &[_]u8{}, .gas = gas } };
    const z = try vm.call(params);
    // Copy the output since VM owns it
    const z_out_copy = if (z.output) |out| try allocator.dupe(u8, out) else null;
    return .{ .ok1 = r.success, .out1 = r_out_copy, .ok2 = z.success, .out2 = z_out_copy };
}

test "CALL pop order: ret/args/gas,to,value wiring matches REVM" {
    const allocator = testing.allocator;
    // Minimal callee: returns 32 bytes with value=1 to signal success
    const callee = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const target = Address.from_u256(0x2222222222222222222222222222222222222222);
    const res = try runBoth(&callee, target, 1000000);
    try testing.expectEqual(res.ok1, res.ok2);
    if (res.ok1 and res.ok2) {
        try testing.expect(res.out2 != null);
        try testing.expectEqual(@as(usize, 32), res.out1.len);
        try testing.expectEqual(@as(usize, 32), res.out2.?.len);
        const v1 = std.mem.readInt(u256, res.out1[0..32], .big);
        const v2 = std.mem.readInt(u256, res.out2.?[0..32], .big);
        try testing.expectEqual(v1, v2);
        try testing.expectEqual(@as(u256, 1), v1);
    }
    allocator.free(res.out1);
    if (res.out2) |o| allocator.free(o);
}
