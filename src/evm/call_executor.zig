const std = @import("std");
const Allocator = std.mem.Allocator;
const Address = @import("../address/address.zig").Address;
const primitives = @import("primitives");

const CallFrameStack = @import("call_frame_stack.zig").CallFrameStack;
const CallType = @import("call_frame_stack.zig").CallType;
const CallParams = @import("call_frame_stack.zig").CallParams;
const Host = @import("root.zig").Host;
const Frame = @import("frame.zig").Frame;
const Evm = @import("evm.zig").Evm;
const ExecutionError = @import("execution/execution_error.zig").ExecutionError;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const CodeAnalysis = @import("analysis.zig").CodeAnalysis;

/// Result of a call execution
pub const CallExecutionResult = struct {
    /// Whether the call succeeded
    success: bool,
    /// Gas remaining after execution
    gas_left: u64,
    /// Output data from the call
    output: []const u8,
    /// Created address (for CREATE/CREATE2)
    created_address: ?Address = null,
    
    pub fn success_result(gas_left: u64, output: []const u8) CallExecutionResult {
        return CallExecutionResult{
            .success = true,
            .gas_left = gas_left,
            .output = output,
        };
    }
    
    pub fn failure_result(gas_left: u64, output: []const u8) CallExecutionResult {
        return CallExecutionResult{
            .success = false,
            .gas_left = gas_left,
            .output = output,
        };
    }
    
    pub fn create_success_result(gas_left: u64, output: []const u8, created_address: Address) CallExecutionResult {
        return CallExecutionResult{
            .success = true,
            .gas_left = gas_left,
            .output = output,
            .created_address = created_address,
        };
    }
};

/// Call execution engine that manages the CallFrameStack
pub const CallExecutor = struct {
    /// Pre-allocated call frame stack
    call_stack: CallFrameStack,
    /// EVM interpreter for executing bytecode
    evm: *Evm,
    /// Allocator for temporary allocations
    allocator: Allocator,
    
    pub fn init(allocator: Allocator, evm: *Evm, host: Host) !CallExecutor {
        return CallExecutor{
            .call_stack = try CallFrameStack.init(allocator, host),
            .evm = evm,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *CallExecutor) void {
        self.call_stack.deinit();
    }
    
    /// Execute a CALL operation
    pub fn execute_call(
        self: *CallExecutor,
        caller_frame: *Frame,
        to_address: Address,
        value: u256,
        input: []const u8,
        gas_limit: u64,
        is_static: bool,
    ) !CallExecutionResult {
        // TODO: Get code analysis for the target address
        // This would require looking up the contract code and analyzing it
        // For now, we'll use a placeholder
        const placeholder_analysis = CodeAnalysis{
            .code = &.{}, // Empty code
            .jumpdest_array = undefined, // Would be properly initialized
        };
        
        const params = CallParams{
            .target = to_address,
            .gas_limit = gas_limit,
            .input = input,
            .value = value,
        };
        
        const child_frame = try self.call_stack.init_call_frame(
            .CALL,
            caller_frame,
            params,
            &placeholder_analysis,
        );
        
        // Execute the child frame
        const result = self.execute_frame(child_frame) catch |err| {
            // Revert on error
            self.call_stack.revert_frame(child_frame);
            return CallExecutionResult.failure_result(0, &.{});
        };
        
        if (result.success) {
            self.call_stack.complete_frame(child_frame);
        } else {
            self.call_stack.revert_frame(child_frame);
        }
        
        return result;
    }
    
    /// Execute a DELEGATECALL operation
    pub fn execute_delegatecall(
        self: *CallExecutor,
        caller_frame: *Frame,
        to_address: Address,
        input: []const u8,
        gas_limit: u64,
    ) !CallExecutionResult {
        const placeholder_analysis = CodeAnalysis{
            .code = &.{},
            .jumpdest_array = undefined,
        };
        
        const params = CallParams{
            .target = to_address,
            .gas_limit = gas_limit,
            .input = input,
            .value = 0, // DELEGATECALL preserves original value
        };
        
        const child_frame = try self.call_stack.init_call_frame(
            .DELEGATECALL,
            caller_frame,
            params,
            &placeholder_analysis,
        );
        
        const result = self.execute_frame(child_frame) catch |err| {
            self.call_stack.revert_frame(child_frame);
            return CallExecutionResult.failure_result(0, &.{});
        };
        
        if (result.success) {
            self.call_stack.complete_frame(child_frame);
        } else {
            self.call_stack.revert_frame(child_frame);
        }
        
        return result;
    }
    
    /// Execute a STATICCALL operation
    pub fn execute_staticcall(
        self: *CallExecutor,
        caller_frame: *Frame,
        to_address: Address,
        input: []const u8,
        gas_limit: u64,
    ) !CallExecutionResult {
        const placeholder_analysis = CodeAnalysis{
            .code = &.{},
            .jumpdest_array = undefined,
        };
        
        const params = CallParams{
            .target = to_address,
            .gas_limit = gas_limit,
            .input = input,
            .value = 0,
        };
        
        const child_frame = try self.call_stack.init_call_frame(
            .STATICCALL,
            caller_frame,
            params,
            &placeholder_analysis,
        );
        
        const result = self.execute_frame(child_frame) catch |err| {
            self.call_stack.revert_frame(child_frame);
            return CallExecutionResult.failure_result(0, &.{});
        };
        
        if (result.success) {
            self.call_stack.complete_frame(child_frame);
        } else {
            self.call_stack.revert_frame(child_frame);
        }
        
        return result;
    }
    
    /// Execute a CREATE operation
    pub fn execute_create(
        self: *CallExecutor,
        caller_frame: *Frame,
        value: u256,
        init_code: []const u8,
        gas_limit: u64,
    ) !CallExecutionResult {
        // Calculate CREATE address using nonce
        const creator_address = caller_frame.contract_address;
        const nonce = 0; // TODO: Get actual nonce from state
        const new_address = try primitives.Address.calculate_create_address(creator_address, nonce);
        
        const placeholder_analysis = CodeAnalysis{
            .code = init_code,
            .jumpdest_array = undefined,
        };
        
        const params = CallParams{
            .target = new_address,
            .gas_limit = gas_limit,
            .input = &.{}, // CREATE uses empty input, init_code is the "code"
            .value = value,
            .init_code = init_code,
        };
        
        const child_frame = try self.call_stack.init_call_frame(
            .CREATE,
            caller_frame,
            params,
            &placeholder_analysis,
        );
        
        const result = self.execute_frame(child_frame) catch |err| {
            self.call_stack.revert_frame(child_frame);
            return CallExecutionResult.failure_result(0, &.{});
        };
        
        if (result.success) {
            self.call_stack.complete_frame(child_frame);
            return CallExecutionResult.create_success_result(result.gas_left, result.output, new_address);
        } else {
            self.call_stack.revert_frame(child_frame);
        }
        
        return result;
    }
    
    /// Execute a CREATE2 operation
    pub fn execute_create2(
        self: *CallExecutor,
        caller_frame: *Frame,
        value: u256,
        init_code: []const u8,
        salt: u256,
        gas_limit: u64,
    ) !CallExecutionResult {
        // Calculate CREATE2 address
        const creator_address = caller_frame.contract_address;
        const new_address = try primitives.Address.calculate_create2_address(
            self.allocator,
            creator_address,
            salt,
            init_code,
        );
        
        const placeholder_analysis = CodeAnalysis{
            .code = init_code,
            .jumpdest_array = undefined,
        };
        
        const params = CallParams{
            .target = new_address,
            .gas_limit = gas_limit,
            .input = &.{},
            .value = value,
            .salt = salt,
            .init_code = init_code,
        };
        
        const child_frame = try self.call_stack.init_call_frame(
            .CREATE2,
            caller_frame,
            params,
            &placeholder_analysis,
        );
        
        const result = self.execute_frame(child_frame) catch |err| {
            self.call_stack.revert_frame(child_frame);
            return CallExecutionResult.failure_result(0, &.{});
        };
        
        if (result.success) {
            self.call_stack.complete_frame(child_frame);
            return CallExecutionResult.create_success_result(result.gas_left, result.output, new_address);
        } else {
            self.call_stack.revert_frame(child_frame);
        }
        
        return result;
    }
    
    /// Execute a single frame using the EVM interpreter
    fn execute_frame(self: *CallExecutor, frame: *Frame) !CallExecutionResult {
        // This is where we would call the EVM interpreter
        // For now, we'll just return a placeholder result
        
        // In the real implementation, this would be something like:
        // try self.evm.interpret(frame);
        
        // Check if execution was successful
        const success = frame.gas_remaining > 0; // Placeholder logic
        
        return CallExecutionResult{
            .success = success,
            .gas_left = frame.gas_remaining,
            .output = frame.output,
        };
    }
};

test "CallExecutor basic CALL execution" {
    const allocator = std.testing.allocator;
    
    // This test is a placeholder since we need a full EVM setup
    // In practice, we'd need:
    // 1. A mock EVM instance
    // 2. A mock database
    // 3. Proper code analysis
    // 4. Frame initialization
    
    // For now, just test that the structure compiles
    const mock_evm: *Evm = undefined;
    var executor = try CallExecutor.init(allocator, mock_evm);
    defer executor.deinit();
    
    // The actual test would execute calls and verify results
    // but requires more infrastructure
}

test "CallExecutor CREATE address calculation" {
    const allocator = std.testing.allocator;
    
    // Test CREATE address calculation
    const creator = Address.ZERO;
    const nonce: u64 = 0;
    
    const address = try primitives.Address.calculate_create_address(creator, nonce);
    
    // Verify it's a valid address (20 bytes)
    try std.testing.expectEqual(@as(usize, 20), address.len);
    
    // CREATE addresses should be deterministic
    const address2 = try primitives.Address.calculate_create_address(creator, nonce);
    try std.testing.expectEqualSlices(u8, &address, &address2);
}