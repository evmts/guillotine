const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

test "unconditional JUMP (fused PUSH+JUMP) skips revert and returns 1" {
    const allocator = testing.allocator;

    // Bytecode layout:
    // 00: 60 08      PUSH1 0x08 (dest)
    // 02: 56         JUMP
    // 03: 60 00      PUSH1 0x00
    // 05: 60 00      PUSH1 0x00
    // 07: fd         REVERT
    // 08: 5b         JUMPDEST
    // 09: 60 01      PUSH1 1
    // 11: 60 1f      PUSH1 31
    // 13: 52         MSTORE
    // 14: 60 00      PUSH1 0
    // 16: 60 20      PUSH1 32
    // 18: f3         RETURN
    const bytecode = [_]u8{
        0x60, 0x08, 0x56, 0x60, 0x00, 0x60, 0x00, 0xfd, 0x5b,
        0x60, 0x01, 0x60, 0x1f, 0x52, 0x60, 0x00, 0x60, 0x20,
        0xf3,
    };

    // REVM setup
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x1111111111111111111111111111111111111111");
    const contract = try Address.from_hex("0x2222222222222222222222222222222222222222");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(contract, &bytecode);
    var r = try revm_vm.call(caller, contract, 0, &[_]u8{}, 1_000_000);
    defer r.deinit();

    // Guillotine setup
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(contract, &bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &[_]u8{}, .gas = 1_000_000 } };
    const z = try vm.call(params);
    defer if (z.output) |o| allocator.free(o);

    // Both should succeed and return 32-byte 1
    try testing.expectEqual(r.success, z.success);
    try testing.expect(r.success);
    try testing.expect(z.output != null);
    try testing.expectEqual(@as(usize, 32), r.output.len);
    try testing.expectEqual(@as(usize, 32), z.output.?.len);
    const v1 = std.mem.readInt(u256, r.output[0..32], .big);
    const v2 = std.mem.readInt(u256, z.output.?[0..32], .big);
    try testing.expectEqual(v1, v2);
    try testing.expectEqual(@as(u256, 1), v1);
}

test "unconditional JUMP to JUMPDEST immediately (no-op jump) returns 1" {
    const allocator = testing.allocator;

    // Layout:
    // 00: 60 03  PUSH1 3 (dest at pc=3)
    // 02: 56     JUMP
    // 03: 5b     JUMPDEST
    // 04: 60 01  PUSH1 1
    // 06: 60 1f  PUSH1 31
    // 08: 52     MSTORE
    // 09: 60 00  PUSH1 0
    // 0b: 60 20  PUSH1 32
    // 0d: f3     RETURN
    const bytecode = [_]u8{ 0x60, 0x03, 0x56, 0x5b, 0x60, 0x01, 0x60, 0x1f, 0x52, 0x60, 0x00, 0x60, 0x20, 0xf3 };

    // REVM
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x3333333333333333333333333333333333333333");
    const contract = try Address.from_hex("0x4444444444444444444444444444444444444444");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(contract, &bytecode);
    var r = try revm_vm.call(caller, contract, 0, &[_]u8{}, 1_000_000);
    defer r.deinit();

    // Guillotine
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(contract, &bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &[_]u8{}, .gas = 1_000_000 } };
    const z = try vm.call(params);
    defer if (z.output) |o| allocator.free(o);

    try testing.expectEqual(r.success, z.success);
    try testing.expect(r.success);
    try testing.expect(z.output != null);
    try testing.expectEqual(@as(usize, 32), r.output.len);
    try testing.expectEqual(@as(usize, 32), z.output.?.len);
    const v1 = std.mem.readInt(u256, r.output[0..32], .big);
    const v2 = std.mem.readInt(u256, z.output.?[0..32], .big);
    try testing.expectEqual(v1, v2);
    try testing.expectEqual(@as(u256, 1), v1);
}
