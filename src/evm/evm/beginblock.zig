/// BEGINBLOCK instruction implementation for optimized block execution.
///
/// This module implements the BEGINBLOCK intrinsic instruction that validates
/// gas and stack requirements for an entire basic block. By performing these
/// checks once per block instead of per instruction, we significantly reduce
/// execution overhead.
///
/// ## Design
///
/// BEGINBLOCK is executed at the start of each basic block and:
/// 1. Validates gas availability for the entire block
/// 2. Checks stack underflow/overflow conditions
/// 3. Stores block metadata for gas correction
///
/// If validation fails, execution terminates immediately with the appropriate error.

const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const BlockMetadata = @import("../frame/code_analysis.zig").BlockMetadata;
const Stack = @import("../stack/stack.zig");
const Log = @import("../log.zig");

/// Result of BEGINBLOCK execution.
/// Uses an enum to eliminate the boolean and provide better type safety.
pub const BeginBlockResult = union(enum) {
    /// Continue execution with the gas that was deducted
    continue_execution: struct {
        /// Gas cost that was deducted for the entire block
        gas_deducted: u64,
    },
    
    /// Exit execution due to an error
    exit: struct {
        /// The error that caused execution to stop
        error_: ExecutionError.Error,
    },
    
    /// Helper to check if execution should continue
    pub fn should_continue(self: BeginBlockResult) bool {
        return switch (self) {
            .continue_execution => true,
            .exit => false,
        };
    }
    
    /// Get the error if execution failed
    pub fn get_error(self: BeginBlockResult) ?ExecutionError.Error {
        return switch (self) {
            .continue_execution => null,
            .exit => |e| e.error_,
        };
    }
    
    /// Get gas deducted if execution continues
    pub fn get_gas_deducted(self: BeginBlockResult) u64 {
        return switch (self) {
            .continue_execution => |c| c.gas_deducted,
            .exit => 0,
        };
    }
};

/// Execute the BEGINBLOCK instruction.
///
/// This function performs all validation for the basic block before
/// any instructions in the block are executed.
///
/// ## Parameters
/// - `vm`: The VM instance
/// - `frame`: Current execution frame
/// - `block_metadata`: Metadata for the block being entered
///
/// ## Returns
/// BeginBlockResult indicating whether to continue execution
pub fn execute_beginblock(
    vm: *Vm,
    frame: *Frame,
    block_metadata: BlockMetadata
) BeginBlockResult {
    _ = vm; // VM might be needed for future extensions
    
    Log.debug("BEGINBLOCK: gas_cost={}, stack_req={}, stack_max={}", .{
        block_metadata.gas_cost,
        block_metadata.stack_req,
        block_metadata.stack_max,
    });
    
    // 1. Validate gas availability
    if (frame.gas_remaining < block_metadata.gas_cost) {
        @branchHint(.unlikely);
        Log.debug("BEGINBLOCK: Insufficient gas. Required: {}, Available: {}", .{
            block_metadata.gas_cost,
            frame.gas_remaining,
        });
        return BeginBlockResult{
            .exit = .{ .error_ = ExecutionError.Error.OutOfGas },
        };
    }
    
    // 2. Validate stack requirements
    const current_stack_size = @as(i16, @intCast(frame.stack.size()));
    
    // Check for stack underflow
    if (current_stack_size < block_metadata.stack_req) {
        @branchHint(.unlikely);
        Log.debug("BEGINBLOCK: Stack underflow. Required: {}, Current: {}", .{
            block_metadata.stack_req,
            current_stack_size,
        });
        return BeginBlockResult{
            .exit = .{ .error_ = ExecutionError.Error.StackUnderflow },
        };
    }
    
    // Check for potential stack overflow
    const max_stack_after_block = current_stack_size + block_metadata.stack_max;
    if (max_stack_after_block > Stack.CAPACITY) {
        @branchHint(.unlikely);
        Log.debug("BEGINBLOCK: Potential stack overflow. Current: {}, Max growth: {}", .{
            current_stack_size,
            block_metadata.stack_max,
        });
        return BeginBlockResult{
            .exit = .{ .error_ = ExecutionError.Error.StackOverflow },
        };
    }
    
    // 3. Deduct gas for the entire block
    frame.gas_remaining -= block_metadata.gas_cost;
    
    // 4. Store block cost for potential gas corrections
    // This is useful for instructions like CALL that need to adjust gas calculations
    frame.current_block_cost = block_metadata.gas_cost;
    
    Log.debug("BEGINBLOCK: Validation passed. Gas deducted: {}", .{block_metadata.gas_cost});
    
    return BeginBlockResult{
        .continue_execution = .{ .gas_deducted = block_metadata.gas_cost },
    };
}

/// Execute BEGINBLOCK in unsafe mode (for use in execute_opcode_unsafe).
///
/// This is a streamlined version that assumes the frame and metadata are valid.
/// It still performs the validations but with minimal overhead.
pub fn execute_beginblock_unsafe(
    frame: *Frame,
    gas_cost: u32,
    stack_req: i16,
    stack_max: i16
) bool {
    // Gas check
    if (frame.gas_remaining < gas_cost) {
        @branchHint(.unlikely);
        return false;
    }
    
    // Stack checks
    const stack_size = @as(i16, @intCast(frame.stack.size()));
    if (stack_size < stack_req or stack_size + stack_max > Stack.CAPACITY) {
        @branchHint(.unlikely);
        return false;
    }
    
    // Deduct gas
    frame.gas_remaining -= gas_cost;
    frame.current_block_cost = gas_cost;
    
    return true;
}

test "BEGINBLOCK gas validation" {
    const testing = std.testing;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const Address = @import("primitives").Address.Address;
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Test 1: Sufficient gas
    const metadata1 = BlockMetadata{
        .gas_cost = 500,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    const result1 = execute_beginblock(&vm, &frame, metadata1);
    try testing.expect(result1.should_continue());
    try testing.expectEqual(@as(u64, 500), result1.get_gas_deducted());
    try testing.expectEqual(@as(u64, 500), frame.gas_remaining);
    
    // Test 2: Insufficient gas
    const metadata2 = BlockMetadata{
        .gas_cost = 600,
        .stack_req = 0,
        .stack_max = 0,
    };
    
    const result2 = execute_beginblock(&vm, &frame, metadata2);
    try testing.expect(!result2.should_continue());
    try testing.expectEqual(ExecutionError.Error.OutOfGas, result2.get_error());
    try testing.expectEqual(@as(u64, 0), result2.get_gas_deducted());
}

test "BEGINBLOCK stack validation" {
    const testing = std.testing;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const Address = @import("primitives").Address.Address;
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 10000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Push some items on stack
    try frame.stack.append(100);
    try frame.stack.append(200);
    try frame.stack.append(300);
    
    // Test 1: Stack requirements met
    const metadata1 = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 3,
        .stack_max = 2,
    };
    
    const result1 = execute_beginblock(&vm, &frame, metadata1);
    try testing.expect(result1.should_continue());
    
    // Test 2: Stack underflow
    const metadata2 = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 5,
        .stack_max = 0,
    };
    
    const result2 = execute_beginblock(&vm, &frame, metadata2);
    try testing.expect(!result2.should_continue());
    try testing.expectEqual(ExecutionError.Error.StackUnderflow, result2.get_error());
    
    // Test 3: Stack overflow
    const metadata3 = BlockMetadata{
        .gas_cost = 100,
        .stack_req = 3,
        .stack_max = 1022, // 3 + 1022 > 1024
    };
    
    const result3 = execute_beginblock(&vm, &frame, metadata3);
    try testing.expect(!result3.should_continue());
    try testing.expectEqual(ExecutionError.Error.StackOverflow, result3.get_error());
}

test "BEGINBLOCK unsafe execution" {
    const testing = std.testing;
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const Address = @import("primitives").Address.Address;
    
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    var contract = try Contract.init(allocator, &[_]u8{0x00}, .{
        .address = Address.ZERO,
    });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000, contract, Address.ZERO, &[_]u8{});
    defer frame.deinit();
    
    // Test unsafe execution
    const success = execute_beginblock_unsafe(&frame, 500, 0, 10);
    try testing.expect(success);
    try testing.expectEqual(@as(u64, 500), frame.gas_remaining);
    try testing.expectEqual(@as(u64, 500), frame.current_block_cost);
}