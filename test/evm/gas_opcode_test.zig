const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address.Address;

// Test that GAS opcode correctly returns gas available with block cost correction
test "GAS opcode with current_block_cost correction" {
    const allocator = testing.allocator;
    
    // Create EVM instance
    const memory_db = try allocator.create(Evm.MemoryDatabase);
    defer allocator.destroy(memory_db);
    memory_db.* = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var builder = Evm.EvmBuilder.init(allocator, db_interface);
    var evm = try builder.build();
    defer evm.deinit();
    
    // Create test code that uses GAS opcode
    // PUSH1 0x00, GAS, MSTORE, PUSH1 0x20, PUSH1 0x00, RETURN
    const code = [_]u8{
        0x60, 0x00,  // PUSH1 0x00
        0x5A,        // GAS
        0x52,        // MSTORE
        0x60, 0x20,  // PUSH1 0x20
        0x60, 0x00,  // PUSH1 0x00
        0xF3,        // RETURN
    };
    
    const addr = primitives.Address.ZERO_ADDRESS;
    const caller = primitives.Address.from_hex("0x0000000000000000000000000000000000002000") catch unreachable;
    
    // Set code in state
    try evm.state.set_code(addr, &code);
    
    // Create contract
    const gas_limit = 100000;
    var contract = Evm.Contract.init(
        caller,
        addr,
        0, // value
        gas_limit,
        &code,
        [_]u8{0} ** 32, // code_hash
        &[_]u8{}, // input
        false, // is_static
    );
    contract.code_size = code.len;
    
    // Execute contract
    const result = try evm.interpret(&contract, &[_]u8{}, false);
    defer if (result.output) |output| allocator.free(output);
    
    // Check result
    try testing.expectEqual(Evm.RunResult.Status.Success, result.status);
    try testing.expect(result.output != null);
    try testing.expectEqual(@as(usize, 32), result.output.?.len);
    
    // Convert output to u256
    var gas_value: u256 = 0;
    for (0..32) |i| {
        gas_value = (gas_value << 8) | result.output.?[i];
    }
    
    // Gas value should be less than gas_limit but greater than 0
    try testing.expect(gas_value > 0);
    try testing.expect(gas_value < gas_limit);
    
    std.debug.print("GAS opcode returned: {} (from gas_limit: {})\n", .{ gas_value, gas_limit });
}

// Test GAS opcode in block-based execution mode specifically
test "GAS opcode returns correct value with block cost" {
    // Create a Frame and manually test the gas_op function
    const stack = Evm.Stack{};
    
    // Mock frame with block cost - using a real Frame type with only the fields we care about
    var frame = Evm.Frame{
        .pc = 0,
        .gas_remaining = 900,
        .stack = stack,
        .memory = undefined,
        .contract = undefined,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = undefined,
        .cost = 0,
        .current_block_cost = 100,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .return_data = undefined,
    };
    
    // Execute GAS opcode
    const gas_op = Evm.execution.system.gas_op;
    _ = try gas_op(0, undefined, &frame);
    
    // Check stack result
    try testing.expectEqual(@as(usize, 1), frame.stack.size());
    const gas_on_stack = try frame.stack.pop();
    
    // Should be gas_remaining + current_block_cost = 900 + 100 = 1000
    try testing.expectEqual(@as(u256, 1000), gas_on_stack);
}