const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create a minimal EVM execution context
fn create_evm_context(allocator: std.mem.Allocator) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    const vm = try evm.Evm.init(allocator, db.to_database_interface(), null, null, null, null, null);
    
    const test_code = [_]u8{0x01}; // Simple ADD opcode
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        &test_code,
        [_]u8{0} ** 32,
        &.{},
        false
    );
    
    var frame = try evm.Frame.init(allocator, &contract);
    frame.gas_remaining = 1000000;
    
    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit();
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

test "fuzz_comparison_lt_operations" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(&ctx, allocator);
    
    // Test LT operation: 5 < 10
    try ctx.frame.stack.append(10); // b (first value popped, second operand)
    try ctx.frame.stack.append(5);  // a (second value popped, first operand)
    
    const interpreter: evm.Operation.Interpreter = &ctx.vm;
    const state: evm.Operation.State = &ctx.frame;
    _ = try ctx.vm.table.execute(0, interpreter, state, 0x10);
    
    const result = try ctx.frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
}

test "fuzz_comparison_eq_operations" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(&ctx, allocator);
    
    // Test EQ operation: 42 == 42
    try ctx.frame.stack.append(42); // b (first value popped)
    try ctx.frame.stack.append(42); // a (second value popped)
    
    const interpreter: evm.Operation.Interpreter = &ctx.vm;
    const state: evm.Operation.State = &ctx.frame;
    _ = try ctx.vm.table.execute(0, interpreter, state, 0x14);
    
    const result = try ctx.frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
}

test "fuzz_comparison_iszero_operations" {
    const allocator = testing.allocator;
    var ctx = try create_evm_context(allocator);
    defer deinit_evm_context(&ctx, allocator);
    
    // Test ISZERO operation with zero
    try ctx.frame.stack.append(0);
    
    const interpreter: evm.Operation.Interpreter = &ctx.vm;
    const state: evm.Operation.State = &ctx.frame;
    _ = try ctx.vm.table.execute(0, interpreter, state, 0x15);
    
    const result = try ctx.frame.stack.pop();
    try testing.expectEqual(@as(u256, 1), result); // true
    
    // Test ISZERO operation with non-zero
    try ctx.frame.stack.append(42);
    _ = try ctx.vm.table.execute(0, interpreter, state, 0x15);
    
    const result2 = try ctx.frame.stack.pop();
    try testing.expectEqual(@as(u256, 0), result2); // false
}