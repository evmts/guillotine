const std = @import("std");
const primitives = @import("primitives");
const Memory = @import("../memory/memory.zig");
const Stack = @import("../stack/stack.zig");
const Contract = @import("./contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Log = @import("../log.zig");
const ReturnData = @import("../evm/return_data.zig").ReturnData;

/// EVM execution frame representing a single call context.
///
/// A Frame encapsulates all the state needed to execute a contract call,
/// including the stack, memory, gas tracking, and execution context.
/// Each contract call or message creates a new frame.
///
/// ## Frame Hierarchy
/// Frames form a call stack during execution:
/// - External transactions create the root frame
/// - CALL/CREATE operations create child frames
/// - Frames are limited by maximum call depth (1024)
///
/// ## Execution Model
/// The frame tracks:
/// - Computational state (stack, memory, PC)
/// - Gas consumption and limits
/// - Input/output data
/// - Static call restrictions
///
/// ## Memory Management
/// Each frame has its own memory space that:
/// - Starts empty and expands as needed
/// - Is cleared when the frame completes
/// - Charges quadratic gas for expansion
///
/// Example:
/// ```zig
/// var frame = try Frame.init(allocator, &contract);
/// defer frame.deinit();
/// frame.gas_remaining = 1000000;
/// try frame.stack.append(42);
/// ```
const Frame = @This();

// Hot fields (frequently accessed, placed first for optimal cache performance)
/// Remaining gas for this execution.
/// Decremented by each operation; execution fails at 0.
gas_remaining: u64 = 0,

/// Current position in contract bytecode.
/// Incremented by opcode size, modified by JUMP/JUMPI.
pc: usize = 0,

/// Contract being executed in this frame.
/// Contains code, address, and contract metadata.
contract: *Contract,

/// Allocator for dynamic memory allocations.
allocator: std.mem.Allocator,

// Medium-hot fields (moderately accessed)
/// Flag indicating execution should halt.
/// Set by STOP, RETURN, REVERT, or errors.
stop: bool = false,

/// Whether this is a STATICCALL context.
/// Prohibits state modifications (SSTORE, CREATE, SELFDESTRUCT).
is_static: bool = false,

/// Current call depth in the call stack.
/// Limited to 1024 to prevent stack overflow attacks.
depth: u32 = 0,

/// Gas cost of current operation.
cost: u64 = 0,

/// Error that occurred during execution, if any.
err: ?ExecutionError.Error = null,

// Data fields (less frequently accessed)
/// Input data for this call (calldata).
/// Accessed by CALLDATALOAD, CALLDATASIZE, CALLDATACOPY.
input: []const u8 = &[_]u8{},

/// Output data to be returned from this frame.
/// Set by RETURN or REVERT operations.
output: []const u8 = &[_]u8{},

/// Current opcode being executed (for debugging/tracing).
op: []const u8 = undefined,

// Large allocations (placed last to avoid increasing offsets of hot fields)
/// Frame's memory space for temporary data storage.
/// Grows dynamically and charges gas quadratically.
memory: Memory,

/// Operand stack for the stack machine.
/// Limited to 1024 elements per EVM rules.
stack: Stack,

/// Return data from child calls.
/// Used by RETURNDATASIZE and RETURNDATACOPY opcodes.
return_data: ReturnData,

/// Create a new execution frame with default settings.
///
/// Initializes a frame with empty stack and memory, ready for execution.
/// Gas and other parameters must be set after initialization.
///
/// @param allocator Memory allocator for dynamic allocations
/// @param contract The contract to execute
/// @return New frame instance
/// @throws OutOfMemory if memory initialization fails
///
/// Example:
/// ```zig
/// var frame = try Frame.init(allocator, &contract);
/// defer frame.deinit();
/// frame.gas_remaining = gas_limit;
/// frame.input = calldata;
/// ```
pub fn init(allocator: std.mem.Allocator, contract: *Contract) !Frame {
    return Frame{
        .gas_remaining = 0,
        .pc = 0,
        .contract = contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = undefined,
        .memory = try Memory.init_default(allocator),
        .stack = .{},
        .return_data = ReturnData.init(allocator),
    };
}

/// Create a frame with specific initial state.
///
/// Used for creating frames with pre-existing state, such as when
/// resuming execution or creating child frames with inherited state.
/// All parameters are optional and default to sensible values.
///
/// @param allocator Memory allocator
/// @param contract Contract to execute
/// @param op Current opcode (optional)
/// @param cost Gas cost of current op (optional)
/// @param err Existing error state (optional)
/// @param memory Pre-initialized memory (optional)
/// @param stack Pre-initialized stack (optional)
/// @param stop Halt flag (optional)
/// @param gas_remaining Available gas (optional)
/// @param is_static Static call flag (optional)
/// @param input Call data (optional)
/// @param depth Call stack depth (optional)
/// @param output Output buffer (optional)
/// @param pc Current PC (optional)
/// @return Configured frame instance
/// @throws OutOfMemory if memory initialization fails
///
/// Example:
/// ```zig
/// // Create child frame inheriting depth and static mode
/// const child_frame = try Frame.init_with_state(
///     allocator,
///     &child_contract,
///     .{ .depth = parent.depth + 1, .is_static = parent.is_static }
/// );
/// ```
pub fn init_with_state(
    allocator: std.mem.Allocator,
    contract: *Contract,
    op: ?[]const u8,
    cost: ?u64,
    err: ?ExecutionError.Error,
    memory: ?Memory,
    stack: ?Stack,
    stop: ?bool,
    gas_remaining: ?u64,
    is_static: ?bool,
    input: ?[]const u8,
    depth: ?u32,
    output: ?[]const u8,
    pc: ?usize,
) !Frame {
    return Frame{
        .gas_remaining = gas_remaining orelse 0,
        .pc = pc orelse 0,
        .contract = contract,
        .allocator = allocator,
        .stop = stop orelse false,
        .is_static = is_static orelse false,
        .depth = depth orelse 0,
        .cost = cost orelse 0,
        .err = err,
        .input = input orelse &[_]u8{},
        .output = output orelse &[_]u8{},
        .op = op orelse undefined,
        .memory = memory orelse try Memory.init_default(allocator),
        .stack = stack orelse .{},
        .return_data = ReturnData.init(allocator),
    };
}

/// Clean up frame resources.
///
/// Releases memory allocated by the frame. Must be called when
/// the frame is no longer needed to prevent memory leaks.
///
/// @param self The frame to clean up
pub fn deinit(self: *Frame) void {
    self.memory.deinit();
    self.return_data.deinit();
}

/// Error type for gas consumption operations.
pub const ConsumeGasError = error{
    /// Insufficient gas to complete operation
    OutOfGas,
};

/// Consume gas from the frame's remaining gas.
///
/// Deducts the specified amount from gas_remaining. If insufficient
/// gas is available, returns OutOfGas error and execution should halt.
///
/// @param self The frame consuming gas
/// @param amount Gas units to consume
/// @throws OutOfGas if amount > gas_remaining
///
/// Example:
/// ```zig
/// // Charge gas for operation
/// try frame.consume_gas(operation.constant_gas);
///
/// // Charge dynamic gas
/// const memory_cost = calculate_memory_gas(size);
/// try frame.consume_gas(memory_cost);
/// ```
pub fn consume_gas(self: *Frame, amount: u64) ConsumeGasError!void {
    if (amount > self.gas_remaining) {
        @branchHint(.cold);
        return ConsumeGasError.OutOfGas;
    }
    self.gas_remaining -= amount;
}

// ============================================================================
// COMPREHENSIVE TESTS FOR FRAME MODULE
// ============================================================================

test "Frame.init creates frame with default settings" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test basic frame initialization
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Verify default values
    try std.testing.expect(frame.stop == false);
    try std.testing.expect(frame.gas_remaining == 0);
    try std.testing.expect(frame.is_static == false);
    try std.testing.expect(frame.depth == 0);
    try std.testing.expect(frame.pc == 0);
    try std.testing.expect(frame.cost == 0);
    try std.testing.expect(frame.err == null);
    try std.testing.expect(frame.input.len == 0);
    try std.testing.expect(frame.output.len == 0);
    
    // Verify contract reference
    try std.testing.expect(frame.contract == &contract);
    try std.testing.expect(frame.allocator.ptr == allocator.ptr);
}

test "Frame.init_with_state creates frame with custom settings" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    const test_input = &[_]u8{0x01, 0x02, 0x03, 0x04};
    const test_output = &[_]u8{0x05, 0x06, 0x07, 0x08};
    
    // Test frame initialization with custom state
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        "TEST_OP",
        42,
        ExecutionError.Error.StackUnderflow,
        null,
        null,
        true,
        1000000,
        true,
        test_input,
        5,
        test_output,
        100
    );
    defer frame.deinit();
    
    // Verify custom values were set correctly
    try std.testing.expectEqualStrings("TEST_OP", frame.op);
    try std.testing.expect(frame.cost == 42);
    try std.testing.expect(frame.err == ExecutionError.Error.StackUnderflow);
    try std.testing.expect(frame.stop == true);
    try std.testing.expect(frame.gas_remaining == 1000000);
    try std.testing.expect(frame.is_static == true);
    try std.testing.expect(frame.depth == 5);
    try std.testing.expect(frame.pc == 100);
    try std.testing.expectEqualSlices(u8, test_input, frame.input);
    try std.testing.expectEqualSlices(u8, test_output, frame.output);
}

test "Frame.init_with_state uses defaults for null parameters" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test frame initialization with null parameters (should use defaults)
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Verify defaults were used
    try std.testing.expect(frame.cost == 0);
    try std.testing.expect(frame.err == null);
    try std.testing.expect(frame.stop == false);
    try std.testing.expect(frame.gas_remaining == 0);
    try std.testing.expect(frame.is_static == false);
    try std.testing.expect(frame.depth == 0);
    try std.testing.expect(frame.pc == 0);
    try std.testing.expect(frame.input.len == 0);
    try std.testing.expect(frame.output.len == 0);
}

test "Frame.consume_gas with sufficient gas" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame with initial gas
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        1000,
        null,
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Test consuming gas within limits
    try frame.consume_gas(100);
    try std.testing.expect(frame.gas_remaining == 900);
    
    try frame.consume_gas(400);
    try std.testing.expect(frame.gas_remaining == 500);
    
    try frame.consume_gas(500);
    try std.testing.expect(frame.gas_remaining == 0);
}

test "Frame.consume_gas with insufficient gas returns OutOfGas" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame with limited gas
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        100,
        null,
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Test insufficient gas scenario
    try std.testing.expectError(ConsumeGasError.OutOfGas, frame.consume_gas(101));
    
    // Gas should remain unchanged after failed consumption
    try std.testing.expect(frame.gas_remaining == 100);
    
    // Test exact gas consumption
    try frame.consume_gas(100);
    try std.testing.expect(frame.gas_remaining == 0);
    
    // Test consumption when gas is zero
    try std.testing.expectError(ConsumeGasError.OutOfGas, frame.consume_gas(1));
}

test "Frame.consume_gas with zero amount" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame with some gas
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        1000,
        null,
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Test consuming zero gas
    try frame.consume_gas(0);
    try std.testing.expect(frame.gas_remaining == 1000);
}

test "Frame.deinit properly cleans up memory" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame and expand memory to test cleanup
    var frame = try Frame.init(allocator, &contract);
    
    // Force memory allocation by expanding memory
    _ = try frame.memory.ensure_capacity(1024);
    
    // This should not leak memory
    frame.deinit();
}

test "Frame stack operations work correctly" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Test stack operations
    try frame.stack.push(42);
    try frame.stack.push(100);
    
    const value1 = try frame.stack.pop();
    try std.testing.expect(value1 == 100);
    
    const value2 = try frame.stack.pop();
    try std.testing.expect(value2 == 42);
    
    // Stack should be empty now
    try std.testing.expectError(Stack.StackError.StackUnderflow, frame.stack.pop());
}

test "Frame memory operations work correctly" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Test memory operations
    const test_data = [_]u8{0x01, 0x02, 0x03, 0x04};
    
    // Write to memory
    try frame.memory.write(0, &test_data);
    
    // Read from memory
    var read_buffer: [4]u8 = undefined;
    try frame.memory.read(0, &read_buffer);
    
    try std.testing.expectEqualSlices(u8, &test_data, &read_buffer);
}

test "Frame static call restrictions" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create static frame
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        true, // is_static = true
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Verify static flag is set
    try std.testing.expect(frame.is_static == true);
}

test "Frame call depth tracking" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test different call depths
    var frame_depth_0 = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null
    );
    defer frame_depth_0.deinit();
    
    var frame_depth_5 = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        5,
        null,
        null
    );
    defer frame_depth_5.deinit();
    
    var frame_depth_1024 = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        1024,
        null,
        null
    );
    defer frame_depth_1024.deinit();
    
    try std.testing.expect(frame_depth_0.depth == 0);
    try std.testing.expect(frame_depth_5.depth == 5);
    try std.testing.expect(frame_depth_1024.depth == 1024);
}

test "Frame return data handling" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Create frame
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Test return data operations
    const test_return_data = [_]u8{0xde, 0xad, 0xbe, 0xef};
    
    // Set return data
    try frame.return_data.set_data(&test_return_data);
    
    // Verify return data
    try std.testing.expectEqualSlices(u8, &test_return_data, frame.return_data.data());
    try std.testing.expect(frame.return_data.size() == test_return_data.len);
}

test "Frame calldata handling" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    const test_calldata = [_]u8{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0};
    
    // Create frame with calldata
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        &test_calldata,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Verify calldata
    try std.testing.expectEqualSlices(u8, &test_calldata, frame.input);
}

test "Frame program counter manipulation" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test PC manipulation
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Initial PC should be 0
    try std.testing.expect(frame.pc == 0);
    
    // Modify PC
    frame.pc = 42;
    try std.testing.expect(frame.pc == 42);
    
    frame.pc += 10;
    try std.testing.expect(frame.pc == 52);
}

test "Frame error state management" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test error state
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Initially no error
    try std.testing.expect(frame.err == null);
    
    // Set error
    frame.err = ExecutionError.Error.OutOfGas;
    try std.testing.expect(frame.err == ExecutionError.Error.OutOfGas);
    
    // Clear error
    frame.err = null;
    try std.testing.expect(frame.err == null);
}

test "Frame stop flag management" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test stop flag
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Initially not stopped
    try std.testing.expect(frame.stop == false);
    
    // Set stop flag
    frame.stop = true;
    try std.testing.expect(frame.stop == true);
    
    // Clear stop flag
    frame.stop = false;
    try std.testing.expect(frame.stop == false);
}

test "Frame with empty contract" {
    const allocator = std.testing.allocator;
    
    // Create an empty contract
    var contract = Contract.init(
        allocator,
        &[_]u8{}, // Empty bytecode
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test frame with empty contract
    var frame = try Frame.init(allocator, &contract);
    defer frame.deinit();
    
    // Should work normally
    try std.testing.expect(frame.contract == &contract);
    try std.testing.expect(frame.pc == 0);
    try std.testing.expect(frame.stop == false);
}

test "Frame gas consumption edge cases" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test with maximum u64 gas
    var frame_max_gas = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        std.math.maxInt(u64),
        null,
        null,
        null,
        null,
        null
    );
    defer frame_max_gas.deinit();
    
    // Should be able to consume large amounts
    try frame_max_gas.consume_gas(1000000);
    try std.testing.expect(frame_max_gas.gas_remaining == std.math.maxInt(u64) - 1000000);
    
    // Test with zero gas
    var frame_zero_gas = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        0,
        null,
        null,
        null,
        null,
        null
    );
    defer frame_zero_gas.deinit();
    
    // Should fail immediately
    try std.testing.expectError(ConsumeGasError.OutOfGas, frame_zero_gas.consume_gas(1));
}

test "Frame multiple initialization and cleanup cycles" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test multiple init/deinit cycles
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var frame = try Frame.init(allocator, &contract);
        
        // Use the frame
        try frame.stack.push(i);
        try frame.consume_gas(i * 10);
        
        frame.deinit();
    }
}

test "Frame memory allocation and stack operations stress test" {
    const allocator = std.testing.allocator;
    
    // Create a minimal contract for testing
    var contract = Contract.init(
        allocator,
        &[_]u8{0x60, 0x10, 0x60, 0x00, 0x52}, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }
    ) catch unreachable;
    defer contract.deinit(allocator, null);
    
    // Test frame with intensive operations
    var frame = try Frame.init_with_state(
        allocator,
        &contract,
        null,
        null,
        null,
        null,
        null,
        null,
        1000000,
        null,
        null,
        null,
        null,
        null
    );
    defer frame.deinit();
    
    // Stress test stack operations
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        try frame.stack.push(i);
    }
    
    // Pop all values back
    i = 100;
    while (i > 0) : (i -= 1) {
        const value = try frame.stack.pop();
        try std.testing.expect(value == i - 1);
    }
    
    // Stress test memory operations
    const test_data = [_]u8{0xaa} ** 1024;
    try frame.memory.write(0, &test_data);
    
    var read_buffer: [1024]u8 = undefined;
    try frame.memory.read(0, &read_buffer);
    
    try std.testing.expectEqualSlices(u8, &test_data, &read_buffer);
}
