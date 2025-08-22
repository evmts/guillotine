const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

test "KECCAK256 32 bytes at 0 should return same digest in REVM and Guillotine" {
    const allocator = testing.allocator;
    // Bytecode: PUSH1 32; PUSH1 0; KECCAK256; MSTORE 0x00; RETURN 32
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x20, // KECCAK256
        0x60, 0x00, // PUSH1 0 (offset)
        0x52, // MSTORE (store hash at mem[0..32])
        0x60, 0x00, // PUSH1 0
        0x60, 0x20, // PUSH1 32
        0xf3, // RETURN
    };

    // REVM
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0x9999999999999999999999999999999999999999");
    const contract = try Address.from_hex("0x8888888888888888888888888888888888888888");
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

    try testing.expect(r.success and z.success);
    try testing.expect(z.output != null);
    try testing.expectEqual(@as(usize, 32), r.output.len);
    try testing.expectEqual(@as(usize, 32), z.output.?.len);
    try testing.expectEqualSlices(u8, r.output, z.output.?);
}
