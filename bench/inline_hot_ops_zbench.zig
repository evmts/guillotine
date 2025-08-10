const std = @import("std");
const Allocator = std.mem.Allocator;

/// Benchmark for inline hot operations vs regular dispatch
/// Tests the performance improvement from inlining hot opcodes
pub fn zbench_regular_dispatch(allocator: Allocator) void {
    const Evm = @import("evm");
    const primitives = @import("primitives");

    // Create test bytecode with hot opcodes
    // Pattern: Load value, duplicate, add, store, repeat
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // PUSH1 0x00, PUSH1 0x01 (initial values)
    bytecode.appendSlice(&[_]u8{ 0x60, 0x00, 0x60, 0x01 }) catch unreachable;

    // Main loop body (repeated 50 times for benchmark)
    for (0..50) |_| {
        bytecode.appendSlice(&[_]u8{
            0x80, // DUP1
            0x80, // DUP1
            0x01, // ADD
            0x60, 0x00, // PUSH1 0x00
            0x52, // MSTORE
            0x60, 0x00, // PUSH1 0x00
            0x51, // MLOAD
            0x90, // SWAP1
            0x50, // POP
        }) catch unreachable;
    }

    // End with STOP
    bytecode.append(0x00) catch unreachable;

    // Setup VM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Vm.init(allocator, db_interface, null, null) catch unreachable;
    defer vm.deinit();

    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x1000);
    vm.state.set_balance(caller, std.math.maxInt(u256)) catch unreachable;
    vm.state.set_code(contract_addr, bytecode.items) catch unreachable;

    // Execute with regular dispatch
    var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
    const result = vm.interpret(&contract, &.{}, false) catch unreachable;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark for inline hot operations
/// This would test the inline hot ops implementation if it were enabled
pub fn zbench_inline_hot_ops(allocator: Allocator) void {
    const Evm = @import("evm");
    const primitives = @import("primitives");

    // Create same test bytecode
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    bytecode.appendSlice(&[_]u8{ 0x60, 0x00, 0x60, 0x01 }) catch unreachable;

    for (0..50) |_| {
        bytecode.appendSlice(&[_]u8{
            0x80, // DUP1
            0x80, // DUP1
            0x01, // ADD
            0x60, 0x00, // PUSH1 0x00
            0x52, // MSTORE
            0x60, 0x00, // PUSH1 0x00
            0x51, // MLOAD
            0x90, // SWAP1
            0x50, // POP
        }) catch unreachable;
    }

    bytecode.append(0x00) catch unreachable;

    // Setup VM
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    // TODO: This would create a VM with inline hot ops enabled
    // For now, it's the same as regular dispatch
    var vm = Evm.Vm.init(allocator, db_interface, null, null) catch unreachable;
    defer vm.deinit();

    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x1000);
    vm.state.set_balance(caller, std.math.maxInt(u256)) catch unreachable;
    vm.state.set_code(contract_addr, bytecode.items) catch unreachable;

    // Execute (would use inline dispatch if enabled)
    var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
    const result = vm.interpret(&contract, &.{}, false) catch unreachable;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark hot opcode heavy workload
pub fn zbench_hot_opcode_workload(allocator: Allocator) void {
    const Evm = @import("evm");
    const primitives = @import("primitives");

    // Create bytecode that represents typical DeFi contract patterns
    // Heavy on PUSH1, DUP1, ADD, MSTORE, MLOAD
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Simulate token transfer logic pattern
    for (0..20) |_| {
        bytecode.appendSlice(&[_]u8{
            0x60, 0x20, // PUSH1 32 (storage slot)
            0x51, // MLOAD (load balance)
            0x60, 0x64, // PUSH1 100 (amount)
            0x80, // DUP1
            0x82, // DUP3
            0x11, // GT (check sufficient balance)
            0x15, // ISZERO
            0x60, 0x00, // PUSH1 0
            0x57, // JUMPI (revert if insufficient)
            0x03, // SUB (deduct amount)
            0x60, 0x20, // PUSH1 32
            0x52, // MSTORE (update balance)
        }) catch unreachable;
    }

    bytecode.append(0x00) catch unreachable; // STOP

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Vm.init(allocator, db_interface, null, null) catch unreachable;
    defer vm.deinit();

    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x2000);
    vm.state.set_balance(caller, std.math.maxInt(u256)) catch unreachable;
    vm.state.set_code(contract_addr, bytecode.items) catch unreachable;

    var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
    const result = vm.interpret(&contract, &.{}, false) catch unreachable;
    defer if (result.output) |output| allocator.free(output);
}

/// Benchmark cold opcode workload (opcodes not inlined)
pub fn zbench_cold_opcode_workload(allocator: Allocator) void {
    const Evm = @import("evm");
    const primitives = @import("primitives");

    // Create bytecode with less common opcodes
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();

    // Use opcodes that are NOT inlined
    for (0..20) |_| {
        bytecode.appendSlice(&[_]u8{
            0x60, 0xFF, // PUSH1 255
            0x60, 0x10, // PUSH1 16
            0x02, // MUL
            0x60, 0x08, // PUSH1 8
            0x06, // MOD
            0x60, 0x02, // PUSH1 2
            0x0A, // EXP
            0x16, // AND
            0x19, // NOT
            0x1B, // SHL
        }) catch unreachable;
    }

    bytecode.append(0x00) catch unreachable; // STOP

    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = Evm.Vm.init(allocator, db_interface, null, null) catch unreachable;
    defer vm.deinit();

    const caller = primitives.Address.ZERO;
    const contract_addr = primitives.Address.from_u256(0x3000);
    vm.state.set_balance(caller, std.math.maxInt(u256)) catch unreachable;
    vm.state.set_code(contract_addr, bytecode.items) catch unreachable;

    var contract = Evm.Contract.init_at_address(caller, contract_addr, 0, 10_000_000, bytecode.items, &.{}, false);
    const result = vm.interpret(&contract, &.{}, false) catch unreachable;
    defer if (result.output) |output| allocator.free(output);
}
