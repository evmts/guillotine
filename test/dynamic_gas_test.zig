const std = @import("std");
const evm = @import("evm");
const Address = @import("Address");
const primitives = @import("primitives");
const Frame = evm.Frame;
const Evm = evm.Evm;
const MemoryDatabase = evm.MemoryDatabase;
const ExecutionError = evm.ExecutionError;
const GasConstants = primitives.GasConstants;

test "CALL charges memory expansion gas" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Create bytecode for CALL with memory access
    // PUSH1 0x00 (ret_size)
    // PUSH1 0x00 (ret_offset)
    // PUSH1 0x20 (args_size = 32 bytes)
    // PUSH1 0x00 (args_offset)
    // PUSH1 0x00 (value)
    // PUSH20 <address>
    // PUSH2 0x2710 (gas = 10000)
    // CALL
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (ret_size)
        0x60, 0x00, // PUSH1 0x00 (ret_offset)
        0x60, 0x20, // PUSH1 0x20 (args_size = 32)
        0x60, 0x00, // PUSH1 0x00 (args_offset)
        0x60, 0x00, // PUSH1 0x00 (value)
        0x73, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH20 address
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xF1, // CALL
    };

    // Create and analyze contract bytecode
    const contract_bytecode = try allocator.dupe(u8, &bytecode);
    defer allocator.free(contract_bytecode);
    const analysis = try evm.CodeAnalysis.from_code(allocator, contract_bytecode, &evm.JumpTable.DEFAULT);
    defer analysis.deinit();

    // Start with enough gas to cover the operation
    const initial_gas: u64 = 100000;
    // Create frame with analyzed bytecode
    var frame = Frame{
        .allocator = allocator,
        .vm = &vm,
        .gas_remaining = initial_gas,
        .memory = try evm.Memory.init_default(allocator),
        .stack = evm.Stack.init(),
        .analysis = analysis,
        .bytecode = contract_bytecode,
        .execution_address = Address.ZERO,
        .caller = Address.ZERO,
        .is_static = false,
        .output = std.ArrayList(u8).init(allocator),
    };
    defer frame.memory.deinit();
    defer frame.output.deinit();

    // Store initial gas for comparison
    const gas_before = frame.gas_remaining;

    // Execute the bytecode
    try vm.execute(&frame);

    const gas_used = gas_before - frame.gas_remaining;

    // Calculate expected gas:
    // - Static costs for PUSH operations (3 gas each for PUSH1, 3 for PUSH2, 3 for PUSH20)
    // - CALL base cost (varies by fork, but typically 700 in latest)
    // - Memory expansion for 32 bytes: 3 * 1 + 1 * 1 / 512 = 3 gas
    const push_gas = 3 * 5 + 3 + 3; // 5 PUSH1s, 1 PUSH2, 1 PUSH20 = 21
    const call_base = 700; // Base CALL cost
    const memory_expansion = 3; // For 32 bytes (1 word)
    const min_expected = push_gas + call_base + memory_expansion;

    // Gas used should be at least the minimum expected
    // (may be more due to other factors like address access costs)
    try std.testing.expect(gas_used >= min_expected);

    // Verify memory was expanded
    try std.testing.expect(frame.memory.size() >= 32);
}

test "CALL with large memory expansion charges correct gas" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Create bytecode for CALL with large memory access (1KB)
    // This should trigger significant memory expansion gas
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (ret_size)
        0x60, 0x00, // PUSH1 0x00 (ret_offset)
        0x61, 0x04, 0x00, // PUSH2 0x0400 (args_size = 1024 bytes)
        0x60, 0x00, // PUSH1 0x00 (args_offset)
        0x60, 0x00, // PUSH1 0x00 (value)
        0x73, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH20 address
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xF1, // CALL
    };

    // Create and analyze contract bytecode
    const contract_bytecode = try allocator.dupe(u8, &bytecode);
    defer allocator.free(contract_bytecode);
    const analysis = try evm.CodeAnalysis.from_code(allocator, contract_bytecode, &evm.JumpTable.DEFAULT);
    defer analysis.deinit();

    const initial_gas: u64 = 100000;
    // Create frame with analyzed bytecode
    var frame = Frame{
        .allocator = allocator,
        .vm = &vm,
        .gas_remaining = initial_gas,
        .memory = try evm.Memory.init_default(allocator),
        .stack = evm.Stack.init(),
        .analysis = analysis,
        .bytecode = contract_bytecode,
        .execution_address = Address.ZERO,
        .caller = Address.ZERO,
        .is_static = false,
        .output = std.ArrayList(u8).init(allocator),
    };
    defer frame.memory.deinit();
    defer frame.output.deinit();

    const gas_before = frame.gas_remaining;

    try vm.execute(&frame);

    const gas_used = gas_before - frame.gas_remaining;

    // For 1024 bytes (32 words):
    // Memory gas = 3 * 32 + (32 * 32) / 512 = 96 + 2 = 98
    const words: u64 = 32;
    const memory_gas = 3 * words + (words * words) / 512;
    try std.testing.expectEqual(@as(u64, 98), memory_gas);

    // Total should include this memory expansion cost
    const push_gas = 3 * 4 + 3 * 2 + 3; // 4 PUSH1s, 2 PUSH2s, 1 PUSH20
    const call_base = 700;
    const min_expected = push_gas + call_base + memory_gas;

    try std.testing.expect(gas_used >= min_expected);

    // Memory should be expanded to at least 1024 bytes
    try std.testing.expect(frame.memory.size() >= 1024);
}

test "CREATE2 charges memory expansion and hashing gas" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // CREATE2 bytecode with 64 bytes of init code
    // Stack: value, offset, size, salt
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0x00 (salt)
        0x60, 0x40, // PUSH1 0x40 (size = 64 bytes)
        0x60, 0x00, // PUSH1 0x00 (offset)
        0x60, 0x00, // PUSH1 0x00 (value)
        0xF5, // CREATE2
    };

    // Create and analyze contract bytecode
    const contract_bytecode = try allocator.dupe(u8, &bytecode);
    defer allocator.free(contract_bytecode);
    const analysis = try evm.CodeAnalysis.from_code(allocator, contract_bytecode, &evm.JumpTable.DEFAULT);
    defer analysis.deinit();

    const initial_gas: u64 = 100000;
    // Create frame with analyzed bytecode
    var frame = Frame{
        .allocator = allocator,
        .vm = &vm,
        .gas_remaining = initial_gas,
        .memory = try evm.Memory.init_default(allocator),
        .stack = evm.Stack.init(),
        .analysis = analysis,
        .bytecode = contract_bytecode,
        .execution_address = Address.ZERO,
        .caller = Address.ZERO,
        .is_static = false,
        .output = std.ArrayList(u8).init(allocator),
    };
    defer frame.memory.deinit();
    defer frame.output.deinit();

    const gas_before = frame.gas_remaining;

    try vm.execute(&frame);

    const gas_used = gas_before - frame.gas_remaining;

    // CREATE2 dynamic gas includes:
    // 1. Memory expansion for 64 bytes (2 words): 3 * 2 + (2 * 2) / 512 = 6 gas
    // 2. Keccak256 for init code: 6 gas per word = 6 * 2 = 12 gas
    const memory_words: u64 = 2;
    const memory_gas = 3 * memory_words + (memory_words * memory_words) / 512;
    const hash_gas = GasConstants.Keccak256WordGas * memory_words;

    const push_gas = 3 * 4; // 4 PUSH1 operations
    const create2_base = 32000; // Base CREATE2 cost
    const min_expected = push_gas + create2_base + memory_gas + hash_gas;

    try std.testing.expect(gas_used >= min_expected);
}

test "DELEGATECALL uses correct stack positions for memory parameters" {
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // DELEGATECALL has no value parameter, so stack positions differ from CALL
    // Stack: gas, to, args_offset, args_size, ret_offset, ret_size
    const bytecode = [_]u8{
        0x60, 0x20, // PUSH1 0x20 (ret_size = 32)
        0x61, 0x01, 0x00, // PUSH2 0x0100 (ret_offset = 256)
        0x60, 0x40, // PUSH1 0x40 (args_size = 64)
        0x60, 0x00, // PUSH1 0x00 (args_offset)
        0x73, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00, 0x00,
        0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // PUSH20 address
        0x61, 0x27, 0x10, // PUSH2 0x2710 (gas = 10000)
        0xF4, // DELEGATECALL
    };

    // Create and analyze contract bytecode
    const contract_bytecode = try allocator.dupe(u8, &bytecode);
    defer allocator.free(contract_bytecode);
    const analysis = try evm.CodeAnalysis.from_code(allocator, contract_bytecode, &evm.JumpTable.DEFAULT);
    defer analysis.deinit();

    const initial_gas: u64 = 100000;
    // Create frame with analyzed bytecode
    var frame = Frame{
        .allocator = allocator,
        .vm = &vm,
        .gas_remaining = initial_gas,
        .memory = try evm.Memory.init_default(allocator),
        .stack = evm.Stack.init(),
        .analysis = analysis,
        .bytecode = contract_bytecode,
        .execution_address = Address.ZERO,
        .caller = Address.ZERO,
        .is_static = false,
        .output = std.ArrayList(u8).init(allocator),
    };
    defer frame.memory.deinit();
    defer frame.output.deinit();

    const gas_before = frame.gas_remaining;

    try vm.execute(&frame);

    const gas_used = gas_before - frame.gas_remaining;

    // Memory expansion should account for both:
    // - args: 64 bytes at offset 0 = 64 bytes total
    // - ret: 32 bytes at offset 256 = 288 bytes total
    // We need 288 bytes = 9 words
    const memory_words: u64 = 9;
    const memory_gas = 3 * memory_words + (memory_words * memory_words) / 512;

    const push_gas = 3 * 3 + 3 * 2 + 3; // 3 PUSH1s, 2 PUSH2s, 1 PUSH20
    const delegatecall_base = 700; // Base DELEGATECALL cost
    const min_expected = push_gas + delegatecall_base + memory_gas;

    try std.testing.expect(gas_used >= min_expected);

    // Memory should be expanded to at least 288 bytes
    try std.testing.expect(frame.memory.size() >= 288);
}

test "Dynamic gas architecture integration" {
    // This test verifies the complete dynamic gas architecture is working
    const allocator = std.testing.allocator;

    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try Evm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test that analysis correctly identifies and tags dynamic gas opcodes
    const test_code = [_]u8{
        0x60, 0x01, // PUSH1 0x01
        0x60, 0x02, // PUSH1 0x02
        0x01, // ADD (regular opcode)
        0x58, // PC (regular opcode)
        0x5A, // GAS (dynamic gas opcode)
        0x00, // STOP
    };

    var contract = try Contract.init(allocator, &test_code, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);

    // Verify the analysis correctly tagged GAS as dynamic
    const instructions = contract.analysis.instructions;

    // Find the GAS instruction (should be after BEGINBLOCK, 2 PUSHes, ADD, PC)
    var found_gas = false;
    var found_dynamic = false;

    for (instructions) |inst| {
        if (inst.arg == .dynamic_gas) {
            found_dynamic = true;
            // GAS opcode should have static cost but no dynamic function
            const dyn_gas = inst.arg.dynamic_gas;
            try std.testing.expect(dyn_gas.static_cost > 0);
            try std.testing.expect(dyn_gas.gas_fn != null); // GAS has a function (returns 0)

            // Call the function to ensure it works
            var test_frame = try Frame.init(allocator, &vm, 1000, contract, Address.ZERO, &.{});
            defer test_frame.deinit();

            const additional_gas = try dyn_gas.gas_fn.?(&test_frame);
            try std.testing.expectEqual(@as(u64, 0), additional_gas); // GAS returns 0
            found_gas = true;
        }
    }

    try std.testing.expect(found_gas);
    try std.testing.expect(found_dynamic);
}
