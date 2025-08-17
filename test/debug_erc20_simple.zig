const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test {
    std.testing.log_level = .warn;
}

test "simple ERC20 call debug" {
    const allocator = std.testing.allocator;

    // Simple bytecode that just returns 32 bytes with 1 in the last position
    // PUSH1 0x20 (32 bytes)
    // PUSH1 0x00 (offset 0)
    // MSTORE (store 32 at memory[0])
    // PUSH1 0x01 (value 1)
    // PUSH1 0x1F (offset 31)
    // MSTORE8 (store 1 at memory[31])
    // PUSH1 0x20 (size 32)
    // PUSH1 0x00 (offset 0)
    // RETURN
    const simple_return_true = [_]u8{
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x52, // MSTORE
        0x60, 0x01, // PUSH1 1
        0x60, 0x1F, // PUSH1 31
        0x53, // MSTORE8
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xF3, // RETURN
    };

    // Set up VM
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, null);
    defer vm.deinit();

    const caller = primitives.Address.from_u256(0x1000000000000000000000000000000000000001);
    const contract = primitives.Address.from_u256(0x2000000000000000000000000000000000000002);

    // Set up contract code
    try vm.state.set_code(contract, &simple_return_true);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Call the contract
    const params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1_000_000,
    } };

    std.log.debug("Calling simple contract...", .{});
    const result = try vm.call(params);

    std.log.debug("Call result: success={}, gas_left={}", .{ result.success, result.gas_left });

    if (result.output) |output| {
        std.log.debug("Output length: {}", .{output.len});
        if (output.len > 0) {
            std.log.debug("Output bytes: {x}", .{output});
        }

        try std.testing.expect(output.len == 32);
        try std.testing.expect(output[31] == 1);
    } else {
        std.log.err("No output returned!", .{});
        try std.testing.expect(false);
    }
}
