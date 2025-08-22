const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

// Differential tests focused on fused/synthetic opcodes

fn runBoth(bytecode: []const u8, gas: u64) !struct { revm_ok: bool, revm_out: []const u8, zig_ok: bool, zig_out: ?[]const u8 } {
    const allocator = testing.allocator;

    // REVM side
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const deployer = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract = try Address.from_hex("0x2222222222222222222222222222222222222222");
    try revm_vm.setBalance(deployer, 10_000_000);
    try revm_vm.setCode(contract, bytecode);
    var revm_result = try revm_vm.call(deployer, contract, 0, &[_]u8{}, gas);
    const revm_out_copy = try allocator.dupe(u8, revm_result.output);
    defer revm_result.deinit();

    // Guillotine side
    const MemoryDatabase = evm.MemoryDatabase;
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm_instance = try evm.Evm.init(allocator, db_interface, null, null, null, null);
    defer vm_instance.deinit();
    try vm_instance.state.set_code(contract, bytecode);
    const params = evm.CallParams{ .call = .{
        .caller = deployer,
        .to = contract,
        .value = 0,
        .input = &[_]u8{},
        .gas = gas,
    } };
    const zig_result = try vm_instance.call(params);
    
    // Copy the Guillotine output since the VM owns it and may reuse the buffer
    const zig_out_copy = if (zig_result.output) |out| try allocator.dupe(u8, out) else null;

    return .{ .revm_ok = revm_result.success, .revm_out = revm_out_copy, .zig_ok = zig_result.success, .zig_out = zig_out_copy };
}

test "fusion: PUSH+JUMP immediate fused target matches REVM" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 0x04 (pc of JUMPDEST below)
        0x56, // JUMP
        0x00, // STOP (not executed)
        0x5b, // JUMPDEST at pc=4
        0x60, 0x01, // PUSH1 1
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const res = try runBoth(&bytecode, 1_000_000);
    try testing.expectEqual(res.revm_ok, res.zig_ok);
    if (res.revm_ok and res.zig_ok) {
        try testing.expect(res.zig_out != null);
        try testing.expectEqual(@as(usize, 32), res.revm_out.len);
        try testing.expectEqual(@as(usize, 32), res.zig_out.?.len);
        const revm_val = std.mem.readInt(u256, res.revm_out[0..32], .big);
        const zig_val = std.mem.readInt(u256, res.zig_out.?[0..32], .big);
        try testing.expectEqual(revm_val, zig_val);
        try testing.expectEqual(@as(u256, 1), revm_val);
    }
    allocator.free(res.revm_out);
    if (res.zig_out) |o| allocator.free(o);
}

test "fusion: arithmetic fusion PUSH+PUSH+ADD matches REVM" {
    const allocator = testing.allocator;
    const bytecode = [_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x01, // ADD (may be precomputed/fused)
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE (store result at [0..32])
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3, // RETURN
    };
    const res = try runBoth(&bytecode, 1_000_000);
    try testing.expectEqual(res.revm_ok, res.zig_ok);
    if (res.revm_ok and res.zig_ok) {
        try testing.expect(res.zig_out != null);
        try testing.expectEqual(@as(usize, 32), res.revm_out.len);
        try testing.expectEqual(@as(usize, 32), res.zig_out.?.len);
        const revm_val = std.mem.readInt(u256, res.revm_out[0..32], .big);
        const zig_val = std.mem.readInt(u256, res.zig_out.?[0..32], .big);
        try testing.expectEqual(revm_val, zig_val);
        try testing.expectEqual(@as(u256, 5), revm_val);
    }
    allocator.free(res.revm_out);
    if (res.zig_out) |o| allocator.free(o);
}
