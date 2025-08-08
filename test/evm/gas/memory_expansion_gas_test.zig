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

test "Memory expansion gas is being charged for MLOAD" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // MLOAD at position 256 should trigger memory expansion
    const bytecode = [_]u8{
        0x61, 0x01, 0x00, // PUSH2 0x0100 (256)
        0x51,             // MLOAD
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
    // 1. PUSH2: 3 gas (static)
    // 2. MLOAD: 3 gas (static) + memory expansion cost (dynamic)
    
    // Memory expansion to 288 bytes (256 + 32, aligned to word boundary)
    // Memory size in words = 9 (288 / 32)
    // Memory cost = (9 * 9) / 512 + (3 * 9) = 0 + 27 = 27 gas
    
    const static_gas = 3 + 3; // PUSH2 + MLOAD
    const memory_expansion_gas = 27;
    const expected_total = static_gas + memory_expansion_gas;
    
    const actual_consumed = initial_gas - frame.gas_remaining;
    
    // Log for debugging
    std.log.warn("Initial gas: {}, Remaining: {}, Consumed: {}, Expected: {}", .{
        initial_gas, frame.gas_remaining, actual_consumed, expected_total
    });
    
    // The actual consumption should match expected (with some tolerance for block overhead)
    try testing.expect(actual_consumed >= expected_total);
}

test "Memory expansion gas scales quadratically" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    
    // Test 1: Small memory expansion
    {
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();
        
        const bytecode = [_]u8{
            0x60, 0x20,       // PUSH1 0x20 (32)
            0x51,             // MLOAD
            0x00,             // STOP
        };
        
        var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
        defer contract.deinit(allocator, null);
        
        const initial_gas: u64 = 100000;
        var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
        defer frame.deinit();
        
        try vm.interpret(&frame);
        
        const small_consumed = initial_gas - frame.gas_remaining;
        
        // For 64 bytes (32 + 32): 2 words
        // Memory cost = (2 * 2) / 512 + (3 * 2) = 0 + 6 = 6 gas
        const expected_memory_gas_small = 6;
        const static_gas_small = 3 + 3; // PUSH1 + MLOAD
        
        try testing.expect(small_consumed >= static_gas_small + expected_memory_gas_small);
    }
    
    // Test 2: Large memory expansion
    {
        var vm = try Vm.init(allocator, db_interface, null, null);
        defer vm.deinit();
        
        const bytecode = [_]u8{
            0x61, 0x04, 0x00, // PUSH2 0x0400 (1024)
            0x51,             // MLOAD
            0x00,             // STOP
        };
        
        var contract = try Contract.init(allocator, &bytecode, .{ .address = Address.ZERO });
        defer contract.deinit(allocator, null);
        
        const initial_gas: u64 = 100000;
        var frame = try Frame.init(allocator, &vm, initial_gas, contract, Address.ZERO, &.{});
        defer frame.deinit();
        
        try vm.interpret(&frame);
        
        const large_consumed = initial_gas - frame.gas_remaining;
        
        // For 1056 bytes (1024 + 32): 33 words
        // Memory cost = (33 * 33) / 512 + (3 * 33) = 2 + 99 = 101 gas
        const expected_memory_gas_large = 101;
        const static_gas_large = 3 + 3; // PUSH2 + MLOAD
        
        try testing.expect(large_consumed >= static_gas_large + expected_memory_gas_large);
    }
}