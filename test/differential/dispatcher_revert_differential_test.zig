const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");

test "dispatcher no-match should revert identically in REVM and Guillotine" {
    const allocator = testing.allocator;

    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0
        0x35, // CALLDATALOAD
        0x60, 0xe0, // PUSH1 0xe0
        0x1c, // SHR
        0x63, 0x11, 0x22, 0x33, 0x44, // PUSH4 0x11223344
        0x14, // EQ
        0x60, 0x16, // PUSH1 0x16
        0x57, // JUMPI
        0x60, 0x00, // PUSH1 0
        0x60, 0x00, // PUSH1 0
        0xfd, // REVERT
        0x5b, // JUMPDEST (0x16)
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x20, // PUSH1 32 (size)
        0xf3, // RETURN
    };

    const calldata = [_]u8{ 0xaa, 0xbb, 0xcc, 0xdd }; // no match

    // REVM
    var revm_vm = try revm_wrapper.Revm.init(allocator, .{});
    defer revm_vm.deinit();
    const caller = try Address.from_hex("0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const contract = try Address.from_hex("0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try revm_vm.setBalance(caller, 10_000_000);
    try revm_vm.setCode(contract, &bytecode);
    var r = try revm_vm.call(caller, contract, 0, &calldata, 1_000_000);
    defer r.deinit();

    // Guillotine
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    var vm = try evm.Evm.init(allocator, memory_db.to_database_interface(), null, null, null, null);
    defer vm.deinit();
    try vm.state.set_code(contract, &bytecode);
    const params = evm.CallParams{ .call = .{ .caller = caller, .to = contract, .value = 0, .input = &calldata, .gas = 1_000_000 } };
    const z = try vm.call(params);
    defer if (z.output) |o| allocator.free(o);

    try testing.expectEqual(r.success, z.success);
    try testing.expect(!r.success);
    // Both paths revert with 0-length output in this minimal case
    try testing.expectEqual(@as(usize, 0), r.output.len);
    try testing.expect(z.output == null or z.output.?.len == 0);
}
