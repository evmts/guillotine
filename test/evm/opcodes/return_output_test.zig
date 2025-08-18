const std = @import("std");
const testing = std.testing;

// test {
//     std.testing.log_level = .warn;
// }
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;

test "RETURN sets output correctly" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    // Bytecode that stores 0xDEADBEEF and returns it
    const bytecode = &[_]u8{
        0x63, 0xde, 0xad, 0xbe, 0xef, // PUSH4 0xDEADBEEF
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x04, // PUSH1 4 (size)
        0x60, 0x1c, // PUSH1 28 (offset - to get last 4 bytes of the 32-byte word)
        0xf3, // RETURN
    };

    var contract = Evm.Contract.init(
        [_]u8{0} ** 20,
        [_]u8{0} ** 20,
        0,
        1000000,
        bytecode,
        [_]u8{0} ** 32,
        &[_]u8{},
        false,
    );
    defer contract.deinit(allocator, null);

    const result = try evm.interpret2(&contract, &[_]u8{}, false);
    try testing.expect(result.status == .Success);
    try testing.expect(result.output != null);

    if (result.output) |output| {
        try testing.expectEqual(@as(usize, 4), output.len);
        try testing.expectEqual(@as(u8, 0xde), output[0]);
        try testing.expectEqual(@as(u8, 0xad), output[1]);
        try testing.expectEqual(@as(u8, 0xbe), output[2]);
        try testing.expectEqual(@as(u8, 0xef), output[3]);
    }
}

test "Top-level call returns 32-byte value via RETURN" {
    const allocator = std.testing.allocator;
    const Prim = @import("primitives");
    const ReturnAddr = Prim.Address.Address;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();

    var vm = try Evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    // runtime: returns 32-byte 0x01
    const runtime = [_]u8{
        0x60, 0x01, // PUSH1 1
        0x60, 0x1f, // PUSH1 31
        0x52, // MSTORE
        0x60, 0x00, // PUSH1 0 (ret offset)
        0x60, 0x20, // PUSH1 32 (ret size)
        0xf3, // RETURN
    };

    const caller: ReturnAddr = [_]u8{0x01} ** 20;
    const callee: ReturnAddr = [_]u8{0x02} ** 20;
    try memory_db.set_code(callee, &runtime);
    try vm.state.set_balance(caller, 1_000_000_000_000_000_000);

    const params = Evm.CallParams{ .call = .{
        .to = callee,
        .caller = caller,
        .input = &.{},
        .value = 0,
        .gas = 200_000,
    } };

    const res = try vm.call(params);
    try std.testing.expect(res.success);
    try std.testing.expect(res.output != null);
    const out = res.output.?;
    
    try std.testing.expectEqual(@as(usize, 32), out.len);
    try std.testing.expectEqual(@as(u8, 1), out[31]);
}

test "constructor returns runtime code" {
    const allocator = testing.allocator;

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var evm = try Evm.init(allocator, db_interface, null, null, null, 0, false, null);

    // Simple constructor that returns "HELLO"
    const init_code = &[_]u8{
        // Constructor copies runtime code to memory and returns it
        0x64, 0x48, 0x45, 0x4c, 0x4c, 0x4f, // PUSH5 "HELLO" (6 bytes) - 0x64 is PUSH5
        0x60, 0x00, // PUSH1 0 (2 bytes)
        0x52, // MSTORE (1 byte)
        0x60, 0x05, // PUSH1 5 (size) (2 bytes)
        0x60, 0x1b, // PUSH1 27 (offset to get last 5 bytes) (2 bytes)
        0xf3, // RETURN (1 byte)
    };
    const deployer: Address.Address = [_]u8{0x12} ** 20;

    const create_result = try evm.create_contract(deployer, 0, init_code, 1000000);
    try testing.expect(create_result.success);
    try testing.expect(create_result.output != null);

    if (create_result.output) |output| {
        try testing.expectEqual(@as(usize, 5), output.len);
        try testing.expectEqualSlices(u8, "HELLO", output);
    }
}
