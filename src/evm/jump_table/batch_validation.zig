const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Contract = @import("../frame/contract.zig");
const CodeAnalysis = @import("../frame/code_analysis.zig");
const BlockMetadata = CodeAnalysis.BlockMetadata;
const ExecutionError = @import("../execution/execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Vm = @import("../evm.zig");
const Address = @import("primitives").Address;
const Memory = @import("../memory/memory.zig");
const ReturnData = @import("../evm/return_data.zig").ReturnData;

/// Validates that a block can be executed with available gas and stack.
///
/// This function performs batch validation of gas and stack requirements
/// for an entire basic block, avoiding per-instruction checks.
///
/// Returns error if:
/// - Insufficient gas for the block
/// - Stack underflow (not enough items for operations)
/// - Stack overflow (too many items pushed)
pub fn validate_block(frame: *Frame, block: *const BlockMetadata) ExecutionError.Error!void {
    // Validate gas
    if (frame.gas_remaining < block.gas_cost) {
        return ExecutionError.Error.OutOfGas;
    }
    
    // Validate stack requirements
    const stack_size = @as(i16, @intCast(frame.stack.size));
    if (stack_size < block.stack_req) {
        return ExecutionError.Error.StackUnderflow;
    }
    
    // Validate stack capacity
    if (stack_size + block.stack_max > Stack.CAPACITY) {
        return ExecutionError.Error.StackOverflow;
    }
}

/// Consumes gas for an entire block at once.
///
/// This avoids per-instruction gas checks for blocks that have
/// been pre-validated.
pub fn consume_block_gas(frame: *Frame, block: *const BlockMetadata) void {
    frame.gas_remaining -= block.gas_cost;
}

test "validate_block detects insufficient gas" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 50,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    const block = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    const result = validate_block(&frame, &block);
    try std.testing.expectError(ExecutionError.Error.OutOfGas, result);
}

test "validate_block accepts sufficient gas" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 150,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    const block = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    try validate_block(&frame, &block);
    // Should not error
}

test "validate_block detects stack underflow" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 1000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    // Push 2 items to stack
    try frame.stack.push(1);
    try frame.stack.push(2);
    
    const block = BlockMetadata{
        .gas_cost = 10,
        .stack_req = 3, // Requires 3 items but only have 2
        .stack_max = 0,
    };
    
    const result = validate_block(&frame, &block);
    try std.testing.expectError(ExecutionError.Error.StackUnderflow, result);
}

test "validate_block detects stack overflow" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 1000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    // Fill stack to near capacity
    var i: usize = 0;
    while (i < Stack.CAPACITY - 2) : (i += 1) {
        try frame.stack.push(@intCast(i));
    }
    
    const block = BlockMetadata{
        .gas_cost = 10,
        .stack_req = 0,
        .stack_max = 5, // Would push 5 more items, exceeding capacity
    };
    
    const result = validate_block(&frame, &block);
    try std.testing.expectError(ExecutionError.Error.StackOverflow, result);
}

test "validate_block allows maximum valid stack operations" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 1000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    // Add exactly enough items for the block's requirements
    try frame.stack.push(10);
    try frame.stack.push(20);
    try frame.stack.push(30);
    
    const block = BlockMetadata{
        .gas_cost = 50,
        .stack_req = 3, // Needs exactly 3 items
        .stack_max = 2, // Will grow by 2 (net growth after consuming 3)
    };
    
    try validate_block(&frame, &block);
    // Should not error
}

test "consume_block_gas reduces gas correctly" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 1000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    const block = BlockMetadata{
        .gas_cost = 250,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    consume_block_gas(&frame, &block);
    try std.testing.expectEqual(@as(u64, 750), frame.gas_remaining);
}

test "batch validation for complex block" {
    const allocator = std.testing.allocator;
    
    // Simulate a complex block:
    // PUSH1 0x10, PUSH1 0x20, ADD, PUSH1 0x30, MUL
    // Gas: 3 + 3 + 3 + 3 + 5 = 17
    // Stack: starts 0, pushes 2, consumes 2 (ADD), pushes 1, net +1, then consumes 2 (MUL), final net 0
    // Stack req: 0 (starts empty)
    // Stack max: 2 (peak when both values pushed before ADD)
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 100,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    const block = BlockMetadata{
        .gas_cost = 17,
        .stack_req = 0,
        .stack_max = 2,
    };
    
    // Validate block
    try validate_block(&frame, &block);
    
    // Consume gas for block
    consume_block_gas(&frame, &block);
    try std.testing.expectEqual(@as(u64, 83), frame.gas_remaining);
}

test "validate_block with negative stack requirements" {
    const allocator = std.testing.allocator;
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{ .address = Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = Frame{
        .gas_remaining = 1000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack{},
        .return_data = ReturnData.init(allocator),
    };
    defer frame.deinit();
    
    // A block with negative stack_req should be treated as 0
    const block = BlockMetadata{
        .gas_cost = 10,
        .stack_req = -5, // Negative requirement
        .stack_max = 1,
    };
    
    // Should validate successfully even with empty stack
    try validate_block(&frame, &block);
}