const std = @import("std");
const Evm = @import("evm");
const primitives = @import("primitives");

test "debug SIGILL step by step" {
    std.testing.log_level = .debug;
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.debug("Step 1: Creating memory database...", .{});
    var memory_db = Evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    std.log.debug("✓ Memory database created", .{});
    
    std.log.debug("Step 2: Creating EVM instance...", .{});
    const db_interface = memory_db.to_database_interface();
    var evm_instance = try Evm.Evm.init(allocator, db_interface);
    defer evm_instance.deinit();
    std.log.debug("✓ EVM instance created", .{});
    
    std.log.debug("Step 3: Creating contract...", .{});
    const simple_bytecode = [_]u8{
        0x60, 0x2A, // PUSH1 42
        0x60, 0x2A, // PUSH1 42  
        0x01,       // ADD
        0x00,       // STOP
    };
    
    var contract = Evm.Contract.init_at_address(
        primitives.Address.ZERO, // caller
        primitives.Address.ZERO, // address where code executes
        0, // value
        100_000, // gas
        &simple_bytecode,
        &[_]u8{}, // empty input
        false, // not static
    );
    defer contract.deinit(allocator, null);
    std.log.debug("✓ Contract created", .{});
    
    std.log.debug("Step 4: Creating frame...", .{});
    var builder = Evm.Frame.builder(allocator);
    var frame = try builder
        .withVm(&evm_instance)
        .withContract(&contract)
        .withGas(100_000)
        .withCaller(.{})
        .build();
    defer frame.deinit();
    std.log.debug("✓ Frame created", .{});
    
    std.log.debug("Step 5: Manually pushing values to stack...", .{});
    try frame.stack.append(42);
    try frame.stack.append(42);
    std.log.debug("✓ Values pushed to stack", .{});
    
    std.log.debug("Step 6: Attempting ADD operation...", .{});
    const interpreter_ptr: *Evm.Operation.Interpreter = @ptrCast(@alignCast(&evm_instance));
    const state_ptr: *Evm.Operation.State = @ptrCast(@alignCast(&frame));
    
    std.log.debug("About to call evm.table.execute...", .{});
    _ = try evm_instance.table.execute(0, interpreter_ptr, state_ptr, 0x01);
    std.log.debug("✓ ADD operation completed", .{});
    
    const result = try frame.stack.pop();
    std.log.debug("Result: {}", .{result});
    try std.testing.expectEqual(@as(u256, 84), result);
    
    std.log.debug("Test completed successfully!", .{});
}