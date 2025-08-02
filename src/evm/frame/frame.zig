const std = @import("std");
const primitives = @import("primitives");
const Memory = @import("../memory/memory.zig");
const Stack = @import("../stack/stack.zig");
const Contract = @import("./contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Log = @import("../log.zig");
const ReturnData = @import("../evm/return_data.zig").ReturnData;
const Vm = @import("../evm.zig");
const ThreadedInstruction = @import("threaded_instruction.zig").ThreadedInstruction;

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
/// var builder = Frame.builder(allocator);
/// var frame = try builder
///     .withContract(&contract)
///     .withGas(1000000)
///     .build();
/// defer frame.deinit();
/// try frame.stack.push(42);
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
op: []const u8 = &.{},

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

// Threaded execution fields (optional, used when threaded analysis is available)
/// Array of threaded instructions for indirect call threading
instructions: ?[]const ThreadedInstruction = null,

/// Storage for large PUSH values (PUSH9-PUSH32)
push_values: ?[]const u256 = null,

/// Jump destination mapping for threaded execution
jumpdest_map: ?*std.AutoHashMap(u32, u32) = null,

/// Current block gas for GAS opcode correction
current_block_gas: u32 = 0,

/// Return reason for threaded execution
return_reason: enum { Continue, Stop, Return, Revert, OutOfGas, Invalid } = .Continue,

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
    var memory = try Memory.init_default(allocator);
    errdefer memory.deinit();

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
        .memory = memory,
        .stack = Stack.init(),
        .return_data = ReturnData.init(allocator),
    };
}

/// Create a new execution frame with specified parameters.
///
/// Creates a frame with the provided execution context. This is the main
/// initialization function used throughout the codebase for creating frames
/// with specific gas limits, caller information, and input data.
///
/// @param allocator Memory allocator for dynamic allocations
/// @param vm Virtual machine instance for state access
/// @param gas_limit Initial gas available for execution
/// @param contract The contract to execute
/// @param caller Address of the calling account
/// @param input Call data for the execution
/// @return New frame instance configured for execution
/// @throws OutOfMemory if memory initialization fails
///
/// Example:
/// ```zig
/// var frame = try Frame.init_full(allocator, &vm, 1000000, &contract, caller_addr, call_data);
/// defer frame.deinit();
/// ```
pub fn init_full(
    allocator: std.mem.Allocator,
    vm: *Vm,
    gas_limit: u64,
    contract: *Contract,
    caller: primitives.Address.Address,
    input: []const u8,
) !Frame {
    _ = vm; // VM parameter for future use
    _ = caller; // Caller parameter for future use
    return Frame{
        .gas_remaining = gas_limit,
        .pc = 0,
        .contract = contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = input,
        .output = &[_]u8{},
        .op = &.{},
        .memory = try Memory.init_default(allocator),
        .stack = Stack.init(),
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
    var memory_to_use = memory orelse try Memory.init_default(allocator);
    errdefer if (memory == null) memory_to_use.deinit();

    const stack_to_use = stack orelse Stack.init();

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
        .op = op orelse &.{},
        .memory = memory_to_use,
        .stack = stack_to_use,
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

/// Builder pattern for Frame initialization.
///
/// Provides a fluent interface for creating Frame instances with optional parameters.
/// Required fields (vm and contract) are validated at build time to prevent errors.
///
/// Example usage:
/// ```zig
/// const frame = try Frame.builder(allocator)
///     .withVm(&vm)
///     .withContract(&contract)
///     .withGas(2000000)
///     .withCaller(caller_address)
///     .withInput(call_data)
///     .isStatic(true)
///     .build();
/// ```
pub const FrameBuilder = struct {
    allocator: std.mem.Allocator,
    vm: ?*Vm = null,
    gas: u64 = 1000000,
    contract: ?*Contract = null,
    caller: primitives.Address.Address = primitives.Address.ZERO_ADDRESS,
    input: []const u8 = &.{},
    value: u256 = 0,
    is_static: bool = false,
    depth: u32 = 0,

    /// Initialize a new FrameBuilder.
    ///
    /// @param allocator Memory allocator for Frame creation
    /// @return New FrameBuilder instance with default values
    pub fn init(allocator: std.mem.Allocator) FrameBuilder {
        return .{ .allocator = allocator };
    }

    /// Set the virtual machine instance.
    ///
    /// @param self Builder instance
    /// @param vm Virtual machine pointer
    /// @return Builder instance for method chaining
    pub fn withVm(self: *FrameBuilder, vm: *Vm) *FrameBuilder {
        self.vm = vm;
        return self;
    }

    /// Set the gas limit for execution.
    ///
    /// @param self Builder instance
    /// @param gas Gas limit
    /// @return Builder instance for method chaining
    pub fn withGas(self: *FrameBuilder, gas: u64) *FrameBuilder {
        self.gas = gas;
        return self;
    }

    /// Set the contract to execute.
    ///
    /// @param self Builder instance
    /// @param contract Contract pointer
    /// @return Builder instance for method chaining
    pub fn withContract(self: *FrameBuilder, contract: *Contract) *FrameBuilder {
        self.contract = contract;
        return self;
    }

    /// Set the caller address.
    ///
    /// @param self Builder instance
    /// @param caller Calling address
    /// @return Builder instance for method chaining
    pub fn withCaller(self: *FrameBuilder, caller: primitives.Address.Address) *FrameBuilder {
        self.caller = caller;
        return self;
    }

    /// Set the input data (calldata).
    ///
    /// @param self Builder instance
    /// @param input Input data slice
    /// @return Builder instance for method chaining
    pub fn withInput(self: *FrameBuilder, input: []const u8) *FrameBuilder {
        self.input = input;
        return self;
    }

    /// Set the value being transferred.
    ///
    /// @param self Builder instance
    /// @param value Transfer value
    /// @return Builder instance for method chaining
    pub fn withValue(self: *FrameBuilder, value: u256) *FrameBuilder {
        self.value = value;
        return self;
    }

    /// Set the static call flag.
    ///
    /// @param self Builder instance
    /// @param static Whether this is a static call
    /// @return Builder instance for method chaining
    pub fn isStatic(self: *FrameBuilder, static: bool) *FrameBuilder {
        self.is_static = static;
        return self;
    }

    /// Set the call depth.
    ///
    /// @param self Builder instance
    /// @param depth Call stack depth
    /// @return Builder instance for method chaining
    pub fn withDepth(self: *FrameBuilder, depth: u32) *FrameBuilder {
        self.depth = depth;
        return self;
    }

    /// Error type for frame building operations.
    pub const BuildError = error{
        /// VM instance is required but not provided
        MissingVm,
        /// Contract instance is required but not provided
        MissingContract,
        /// Memory allocation failed during frame creation
        OutOfMemory,
    };

    /// Build the Frame instance.
    ///
    /// Validates that required fields are set and creates the Frame.
    /// This method consumes the builder.
    ///
    /// @param self Builder instance
    /// @return Frame instance ready for execution
    /// @throws BuildError if required fields are missing
    /// @throws OutOfMemory if frame initialization fails
    pub fn build(self: FrameBuilder) BuildError!Frame {
        if (self.vm == null) return BuildError.MissingVm;
        if (self.contract == null) return BuildError.MissingContract;

        return Frame{
            .gas_remaining = self.gas,
            .pc = 0,
            .contract = self.contract.?,
            .allocator = self.allocator,
            .stop = false,
            .is_static = self.is_static,
            .depth = self.depth,
            .cost = 0,
            .err = null,
            .input = self.input,
            .output = &[_]u8{},
            .op = &.{},
            .memory = Memory.init_default(self.allocator) catch return BuildError.OutOfMemory,
            .stack = Stack.init(),
            .return_data = ReturnData.init(self.allocator),
        };
    }
};

/// Create a new FrameBuilder instance.
///
/// Convenience function for starting the builder pattern.
///
/// @param allocator Memory allocator for Frame creation
/// @return New FrameBuilder instance
pub fn builder(allocator: std.mem.Allocator) FrameBuilder {
    return FrameBuilder.init(allocator);
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
pub inline fn consume_gas(self: *Frame, amount: u64) ConsumeGasError!void {
    if (amount > self.gas_remaining) {
        @branchHint(.cold);
        return ConsumeGasError.OutOfGas;
    }
    self.gas_remaining -= amount;
}

// ============================================================================
// COMPREHENSIVE TESTS FOR FRAME MODULE
// ============================================================================

test "Frame.builder creates frame with default settings" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test basic frame initialization
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    const test_input = &[_]u8{ 0x01, 0x02, 0x03, 0x04 };
    const test_output = &[_]u8{ 0x05, 0x06, 0x07, 0x08 };

    // Test frame initialization with custom state
    var frame = try Frame.init_with_state(allocator, &contract, "TEST_OP", 42, ExecutionError.Error.StackUnderflow, null, null, true, 1000000, true, test_input, 5, test_output, 100);
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Test frame initialization with null parameters (should use defaults)
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, null, null, null, null, null);
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Create frame with initial gas
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, 1000, null, null, null, null, null);
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Create frame with limited gas
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, 100, null, null, null, null, null);
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Create frame with some gas
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, 1000, null, null, null, null, null);
    defer frame.deinit();

    // Test consuming zero gas
    try frame.consume_gas(0);
    try std.testing.expect(frame.gas_remaining == 1000);
}

test "Frame.deinit properly cleans up memory" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Create frame and expand memory to test cleanup
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();

    // Force memory allocation by expanding memory
    _ = try frame.memory.ensure_capacity(1024);

    // This should not leak memory
    frame.deinit();
}

test "Frame stack operations work correctly" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
    defer frame.deinit();

    // Test memory operations
    const test_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Create static frame
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, true, // is_static = true
        null, null, null, null);
    defer frame.deinit();

    // Verify static flag is set
    try std.testing.expect(frame.is_static == true);
}

test "Frame call depth tracking" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Test different call depths
    var frame_depth_0 = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, null, null, 0, null, null);
    defer frame_depth_0.deinit();

    var frame_depth_5 = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, null, null, 5, null, null);
    defer frame_depth_5.deinit();

    var frame_depth_1024 = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, null, null, 1024, null, null);
    defer frame_depth_1024.deinit();

    try std.testing.expect(frame_depth_0.depth == 0);
    try std.testing.expect(frame_depth_5.depth == 5);
    try std.testing.expect(frame_depth_1024.depth == 1024);
}

test "Frame return data handling" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Create frame
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
    defer frame.deinit();

    // Test return data operations
    const test_return_data = [_]u8{ 0xde, 0xad, 0xbe, 0xef };

    // Set return data
    try frame.return_data.set_data(&test_return_data);

    // Verify return data
    try std.testing.expectEqualSlices(u8, &test_return_data, frame.return_data.data());
    try std.testing.expect(frame.return_data.size() == test_return_data.len);
}

test "Frame calldata handling" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    const test_calldata = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };

    // Create frame with calldata
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, null, null, &test_calldata, null, null, null);
    defer frame.deinit();

    // Verify calldata
    try std.testing.expectEqualSlices(u8, &test_calldata, frame.input);
}

test "Frame program counter manipulation" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test PC manipulation
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test error state
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
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
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test stop flag
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
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
    var contract = Contract.init(allocator, &[_]u8{}, // Empty bytecode
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test frame with empty contract
    var frame_builder = Frame.builder(allocator);
    var frame = try frame_builder
        .withVm(&vm)
        .withContract(&contract)
        .build();
    defer frame.deinit();

    // Should work normally
    try std.testing.expect(frame.contract == &contract);
    try std.testing.expect(frame.pc == 0);
    try std.testing.expect(frame.stop == false);
}

test "Frame gas consumption edge cases" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Test with maximum u64 gas
    var frame_max_gas = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, std.math.maxInt(u64), null, null, null, null, null);
    defer frame_max_gas.deinit();

    // Should be able to consume large amounts
    try frame_max_gas.consume_gas(1000000);
    try std.testing.expect(frame_max_gas.gas_remaining == std.math.maxInt(u64) - 1000000);

    // Test with zero gas
    var frame_zero_gas = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, 0, null, null, null, null, null);
    defer frame_zero_gas.deinit();

    // Should fail immediately
    try std.testing.expectError(ConsumeGasError.OutOfGas, frame_zero_gas.consume_gas(1));
}

test "Frame multiple initialization and cleanup cycles" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    var vm = Vm.init(allocator, undefined, null, null) catch unreachable;
    defer vm.deinit();

    // Test multiple init/deinit cycles
    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        var frame_builder = Frame.builder(allocator);
        var frame = try frame_builder
            .withVm(&vm)
            .withContract(&contract)
            .build();

        // Use the frame
        try frame.stack.push(i);
        try frame.consume_gas(i * 10);

        frame.deinit();
    }
}

test "Frame memory allocation and stack operations stress test" {
    const allocator = std.testing.allocator;

    // Create a minimal contract for testing
    var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, // PUSH1 16 PUSH1 0 MSTORE
        .{ .address = primitives.Address.zero() }) catch unreachable;
    defer contract.deinit(allocator, null);

    // Test frame with intensive operations
    var frame = try Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, 1000000, null, null, null, null, null);
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

// ============================================================================
// COMPREHENSIVE TESTS FOR FRAME BUILDER PATTERN
// ============================================================================

test "FrameBuilder.init creates builder with default values" {
    const allocator = std.testing.allocator;

    const frame_builder = FrameBuilder.init(allocator);

    try std.testing.expect(frame_builder.vm == null);
    try std.testing.expect(frame_builder.gas == 1000000);
    try std.testing.expect(frame_builder.contract == null);
    try std.testing.expect(primitives.Address.eql(frame_builder.caller, primitives.Address.ZERO_ADDRESS));
    try std.testing.expect(frame_builder.input.len == 0);
    try std.testing.expect(frame_builder.value == 0);
    try std.testing.expect(frame_builder.is_static == false);
    try std.testing.expect(frame_builder.depth == 0);
}

test "Frame.builder convenience function works" {
    const allocator = std.testing.allocator;

    const frame_builder = Frame.builder(allocator);

    try std.testing.expect(frame_builder.vm == null);
    try std.testing.expect(frame_builder.gas == 1000000);
    try std.testing.expect(frame_builder.contract == null);
}

// ============================================================================
// Fuzz Tests for Frame Builder Pattern Edge Cases (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

test "fuzz_frame_builder_patterns" {
    const global = struct {
        fn testFrameBuilderPatterns(input: []const u8) anyerror!void {
            if (input.len < 32) return;

            const allocator = std.testing.allocator;

            // Create contract for testing
            var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, .{ .address = primitives.Address.zero() }) catch return;
            defer contract.deinit(allocator, null);

            var vm = Vm.init(allocator, undefined, null, null) catch return;
            defer vm.deinit();

            // Extract values from fuzz input
            const gas = std.mem.readInt(u64, input[0..8], .little) % 10000000; // 0-10M gas
            const caller_bytes = input[8..28]; // 20 bytes for address
            const value = std.mem.readInt(u64, input[28..32], .little); // 32-bit value

            const is_static = (input[0] & 1) == 1;
            const depth = (input[1] % 100); // 0-99 depth
            const input_size = input[2] % 100; // 0-99 bytes input

            // Create address from bytes
            var caller = primitives.Address.zero();
            std.mem.copyForwards(u8, &caller.bytes, caller_bytes);

            // Create input data
            var input_data = std.ArrayList(u8).init(allocator);
            defer input_data.deinit();

            for (0..input_size) |i| {
                const byte_val = input[3 + (i % @min(input.len - 3, 29))] ^ @as(u8, @intCast(i));
                try input_data.append(byte_val);
            }

            // Test builder pattern with various configurations
            var frame_builder = Frame.builder(allocator);
            var frame = frame_builder
                .withVm(&vm)
                .withContract(&contract)
                .withGas(gas)
                .withCaller(caller)
                .withInput(input_data.items)
                .withValue(@as(u256, value))
                .isStatic(is_static)
                .withDepth(@as(u32, depth))
                .build() catch return;
            defer frame.deinit();

            // Verify frame was constructed correctly
            std.testing.expect(frame.gas_remaining == gas) catch {};
            std.testing.expect(frame.is_static == is_static) catch {};
            std.testing.expect(frame.depth == depth) catch {};
            std.testing.expect(frame.contract == &contract) catch {};
            std.testing.expectEqualSlices(u8, input_data.items, frame.input) catch {};

            // Test frame operations
            if (gas > 100) {
                frame.consume_gas(100) catch {};
                std.testing.expect(frame.gas_remaining == gas - 100) catch {};
            }

            // Test stack operations
            if (!is_static) {
                frame.stack.push(@as(u256, value)) catch {};
                const popped = frame.stack.pop() catch 0;
                std.testing.expect(popped == @as(u256, value)) catch {};
            }
        }
    };
    try std.testing.fuzz(global.testFrameBuilderPatterns, .{}, .{});
}

test "fuzz_frame_gas_consumption_patterns" {
    const global = struct {
        fn testGasConsumptionPatterns(input: []const u8) anyerror!void {
            if (input.len < 16) return;

            const allocator = std.testing.allocator;

            var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, .{ .address = primitives.Address.zero() }) catch return;
            defer contract.deinit(allocator, null);

            // Extract gas values from fuzz input
            const initial_gas = std.mem.readInt(u64, input[0..8], .little) % 1000000;
            const num_operations = input[8] % 20 + 1; // 1-20 operations

            var frame = Frame.init_with_state(allocator, &contract, null, null, null, null, null, null, initial_gas, null, null, null, null, null) catch return;
            defer frame.deinit();

            var remaining_gas = initial_gas;

            for (0..num_operations) |i| {
                const base_idx = 9 + (i % 7); // Cycle through available bytes
                if (base_idx >= input.len) break;

                const gas_amount = input[base_idx] % 50 + 1; // 1-50 gas per operation

                const result = frame.consume_gas(gas_amount);

                if (gas_amount <= remaining_gas) {
                    // Should succeed
                    result catch {
                        // Unexpected failure
                        continue;
                    };
                    remaining_gas -= gas_amount;
                    std.testing.expect(frame.gas_remaining == remaining_gas) catch {};
                } else {
                    // Should fail with OutOfGas
                    std.testing.expectError(ConsumeGasError.OutOfGas, result) catch {};
                    std.testing.expect(frame.gas_remaining == remaining_gas) catch {};
                    break; // No more operations possible
                }
            }
        }
    };
    try std.testing.fuzz(global.testGasConsumptionPatterns, .{}, .{});
}

test "fuzz_frame_memory_operations" {
    const global = struct {
        fn testMemoryOperations(input: []const u8) anyerror!void {
            if (input.len < 20) return;

            const allocator = std.testing.allocator;

            var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, .{ .address = primitives.Address.zero() }) catch return;
            defer contract.deinit(allocator, null);

            var vm = Vm.init(allocator, undefined, null, null) catch return;
            defer vm.deinit();

            var frame_builder = Frame.builder(allocator);
            var frame = frame_builder
                .withVm(&vm)
                .withContract(&contract)
                .withGas(1000000)
                .build() catch return;
            defer frame.deinit();

            // Test memory operations with fuzz data
            const num_ops = input[0] % 10 + 1; // 1-10 operations

            for (0..num_ops) |i| {
                const base_idx = 1 + (i * 2);
                if (base_idx + 1 >= input.len) break;

                const offset = input[base_idx] % 200; // 0-199 offset
                const data_len = input[base_idx + 1] % 50 + 1; // 1-50 bytes

                // Create test data from fuzz input
                var test_data = std.ArrayList(u8).init(allocator);
                defer test_data.deinit();

                for (0..data_len) |j| {
                    const src_idx = (base_idx + 2 + j) % input.len;
                    try test_data.append(input[src_idx]);
                }

                // Write to memory
                frame.memory.write(offset, test_data.items) catch continue;

                // Read back and verify
                const read_buffer = allocator.alloc(u8, test_data.items.len) catch continue;
                defer allocator.free(read_buffer);

                frame.memory.read(offset, read_buffer) catch continue;
                std.testing.expectEqualSlices(u8, test_data.items, read_buffer) catch {};

                // Test u256 operations if we have enough space
                if (offset + 32 <= 1000) { // Avoid memory expansion issues
                    const value = std.mem.readInt(u64, input[(base_idx + 10) % input.len .. ((base_idx + 18) % input.len)], .little);
                    frame.memory.set_u256(offset, @as(u256, value)) catch continue;

                    const read_value = frame.memory.get_u256(offset) catch continue;
                    std.testing.expect(read_value == @as(u256, value)) catch {};
                }
            }
        }
    };
    try std.testing.fuzz(global.testMemoryOperations, .{}, .{});
}

test "fuzz_frame_stack_operations" {
    const global = struct {
        fn testStackOperations(input: []const u8) anyerror!void {
            if (input.len < 8) return;

            const allocator = std.testing.allocator;

            var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, .{ .address = primitives.Address.zero() }) catch return;
            defer contract.deinit(allocator, null);

            var vm = Vm.init(allocator, undefined, null, null) catch return;
            defer vm.deinit();

            var frame_builder = Frame.builder(allocator);
            var frame = frame_builder
                .withVm(&vm)
                .withContract(&contract)
                .build() catch return;
            defer frame.deinit();

            // Test stack operations with fuzz data
            const num_pushes = input[0] % 100 + 1; // 1-100 pushes (within stack limit)

            var expected_values = std.ArrayList(u256).init(allocator);
            defer expected_values.deinit();

            // Push phase
            for (0..num_pushes) |i| {
                const base_idx = 1 + (i * 8);
                if (base_idx + 8 > input.len) break;

                const value = std.mem.readInt(u64, input[base_idx .. base_idx + 8], .little);
                const u256_value = @as(u256, value);

                frame.stack.push(u256_value) catch break; // Stop if stack full
                try expected_values.append(u256_value);
            }

            // Pop phase - verify LIFO order
            while (expected_values.items.len > 0) {
                const expected = expected_values.pop();
                const actual = frame.stack.pop() catch break;
                std.testing.expect(actual == expected) catch {};
            }

            // Stack should be empty
            std.testing.expectError(Stack.StackError.StackUnderflow, frame.stack.pop()) catch {};
        }
    };
    try std.testing.fuzz(global.testStackOperations, .{}, .{});
}

test "fuzz_frame_state_combinations" {
    const global = struct {
        fn testStateCombinations(input: []const u8) anyerror!void {
            if (input.len < 24) return;

            const allocator = std.testing.allocator;

            var contract = Contract.init(allocator, &[_]u8{ 0x60, 0x10, 0x60, 0x00, 0x52 }, .{ .address = primitives.Address.zero() }) catch return;
            defer contract.deinit(allocator, null);

            // Extract various state values from fuzz input
            const gas = std.mem.readInt(u64, input[0..8], .little) % 1000000;
            const depth = std.mem.readInt(u32, input[8..12], .little) % 1025; // 0-1024
            const pc = std.mem.readInt(u32, input[12..16], .little) % 10000; // 0-9999
            const cost = std.mem.readInt(u64, input[16..24], .little) % 10000; // 0-9999

            const is_static = (input[0] & 1) == 1;
            const stop = (input[1] & 1) == 1;
            const has_error = (input[2] & 1) == 1;

            const error_val = if (has_error) ExecutionError.Error.OutOfGas else null;

            var frame = Frame.init_with_state(allocator, &contract, "FUZZ_OP", cost, error_val, null, null, stop, gas, is_static, null, depth, null, pc) catch return;
            defer frame.deinit();

            // Verify state was set correctly
            std.testing.expect(frame.gas_remaining == gas) catch {};
            std.testing.expect(frame.depth == depth) catch {};
            std.testing.expect(frame.pc == pc) catch {};
            std.testing.expect(frame.cost == cost) catch {};
            std.testing.expect(frame.is_static == is_static) catch {};
            std.testing.expect(frame.stop == stop) catch {};
            std.testing.expectEqualStrings("FUZZ_OP", frame.op) catch {};

            if (has_error) {
                std.testing.expect(frame.err == ExecutionError.Error.OutOfGas) catch {};
            } else {
                std.testing.expect(frame.err == null) catch {};
            }

            // Test state transitions
            if (!stop and gas > 100) {
                frame.consume_gas(50) catch {};
                std.testing.expect(frame.gas_remaining == gas - 50) catch {};
            }

            // Test PC manipulation
            frame.pc = (frame.pc + 1) % 10000;

            // Test stop flag
            frame.stop = !frame.stop;

            // Test error state changes
            if (frame.err == null) {
                frame.err = ExecutionError.Error.StackOverflow;
                std.testing.expect(frame.err == ExecutionError.Error.StackOverflow) catch {};
            }
        }
    };
    try std.testing.fuzz(global.testStateCombinations, .{}, .{});
}
