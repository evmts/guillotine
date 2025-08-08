const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const primitives = @import("primitives");

const Address = primitives.Address;
const MemoryDatabase = Evm.MemoryDatabase;
const Vm = Evm.Vm;
const Frame = Evm.Frame;
const Contract = Evm.Contract;
const ExecutionError = Evm.ExecutionError;
const GasConstants = primitives.GasConstants;

test "CALL charges memory expansion gas for arguments" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // CALL with arguments that require memory expansion
    // Stack: gas, to, value, args_offset, args_size, ret_offset, ret_size
    const bytecode = [_]u8{
        // Push parameters in reverse order (top of stack last)
        0x60, 0x20,       // PUSH1 0x20 (ret_size = 32)
        0x60, 0x00,       // PUSH1 0x00 (ret_offset = 0)
        0x60, 0x20,       // PUSH1 0x20 (args_size = 32)
        0x61, 0x01, 0x00, // PUSH2 0x0100 (args_offset = 256)
        0x60, 0x00,       // PUSH1 0x00 (value = 0)
        0x60, 0x00,       // PUSH1 0x00 (to = address 0)
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xf1,             // CALL
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas: u64 = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    // Execute the bytecode
    try vm.interpret(&frame);

    // The frame should have consumed gas for:
    // 1. Static gas for PUSH operations and CALL
    // 2. Dynamic gas for memory expansion:
    //    - args memory: offset 256 + size 32 = 288 bytes (9 words)
    //    - ret memory: offset 0 + size 32 = 32 bytes (1 word)
    //    - Max of both: 288 bytes (9 words)
    //    - Memory cost = (9 * 9) / 512 + (3 * 9) = 0 + 27 = 27 gas
    
    const push_gas = 3 * 2 + 3 * 5; // 2 PUSH1s + 5 PUSH2s
    const call_base_gas = 700; // Post-Tangerine Whistle
    const memory_expansion_gas = 27;
    
    // Minimum gas that should be consumed
    const min_consumed = push_gas + call_base_gas + memory_expansion_gas;
    const actual_consumed = initial_gas - frame.gas_remaining;
    
    std.log.warn("Initial gas: {}, Remaining: {}, Consumed: {}, Min expected: {}", .{
        initial_gas, frame.gas_remaining, actual_consumed, min_consumed
    });
    
    // The actual consumption should be at least the minimum
    // (will be more due to call execution, but we're testing memory gas is charged)
    try testing.expect(actual_consumed >= min_consumed);
}

test "CALL charges memory expansion gas for both args and return" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // CALL with return area that requires more memory than args
    const bytecode = [_]u8{
        // Push parameters in reverse order
        0x61, 0x01, 0x00, // PUSH2 0x0100 (ret_size = 256)
        0x61, 0x02, 0x00, // PUSH2 0x0200 (ret_offset = 512)
        0x60, 0x20,       // PUSH1 0x20 (args_size = 32)
        0x60, 0x00,       // PUSH1 0x00 (args_offset = 0)
        0x60, 0x00,       // PUSH1 0x00 (value = 0)
        0x60, 0x00,       // PUSH1 0x00 (to = address 0)
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xf1,             // CALL
        0x00,             // STOP
    };

    var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    const initial_gas: u64 = 100000;
    var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
    defer frame.deinit();

    try vm.interpret(&frame);

    // Memory expansion for:
    // - args: 0 + 32 = 32 bytes (1 word)
    // - ret: 512 + 256 = 768 bytes (24 words)
    // Max: 768 bytes (24 words)
    // Memory cost = (24 * 24) / 512 + (3 * 24) = 1 + 72 = 73 gas
    
    const memory_expansion_gas = 73;
    const push_gas = 3 * 2 + 3 * 4; // 2 PUSH1s + 4 PUSH2s
    const call_base_gas = 700;
    
    const min_consumed = push_gas + call_base_gas + memory_expansion_gas;
    const actual_consumed = initial_gas - frame.gas_remaining;
    
    std.log.warn("Return memory test - Consumed: {}, Min expected: {}", .{
        actual_consumed, min_consumed
    });
    
    try testing.expect(actual_consumed >= min_consumed);
}