const std = @import("std");
const primitives = @import("primitives");
const RunResult = @import("run_result.zig").RunResult;
const ExecutionError = @import("../execution/execution_error.zig");

/// Result of executing a basic block of EVM bytecode.
///
/// A basic block is a sequence of instructions with:
/// - Single entry point (first instruction)
/// - Single exit point (last instruction or control flow change)
/// - No internal jumps or branches
///
/// Block execution is an optimization that:
/// 1. Pre-validates gas and stack requirements for the entire block
/// 2. Executes all instructions without per-instruction checks
/// 3. Returns control flow information for the next block
pub const BlockResult = struct {
    /// Type of block exit
    pub const ExitType = enum {
        /// Block continues to next sequential block
        continue_sequential,
        /// Unconditional jump to specific PC
        jump,
        /// Conditional jump based on stack value
        conditional_jump,
        /// Execution stopped (STOP opcode)
        stop,
        /// Return from current context (RETURN)
        return_,
        /// Revert execution (REVERT)
        revert,
        /// Call to another contract
        call,
        /// Create new contract
        create,
        /// Execution error occurred
        error_,
    };

    /// How the block exited
    exit_type: ExitType,

    /// For jumps: target PC
    jump_target: ?usize = null,

    /// For conditional jumps: whether condition was true
    condition: bool = false,

    /// For sequential execution: PC after last instruction
    next_pc: usize = 0,

    /// For RETURN/REVERT: output data
    output: ?[]const u8 = null,

    /// For calls: call parameters
    call_params: ?CallParams = null,

    /// For errors: the specific error
    err: ?ExecutionError.Error = null,

    /// Gas consumed by the block
    gas_used: u64 = 0,

    /// Whether block modified state (for static call checks)
    state_modified: bool = false,

    /// Parameters for CALL family opcodes
    pub const CallParams = struct {
        /// Type of call (CALL, DELEGATECALL, STATICCALL, etc)
        call_type: CallType,
        /// Target address
        to: primitives.Address.Address,
        /// Value to transfer (0 for DELEGATECALL/STATICCALL)
        value: u256,
        /// Input data offset in memory
        input_offset: usize,
        /// Input data size
        input_size: usize,
        /// Output data offset in memory
        output_offset: usize,
        /// Output data size
        output_size: usize,
        /// Gas limit for the call
        gas: u64,
    };

    pub const CallType = enum {
        call,
        delegatecall,
        staticcall,
        callcode,
    };

    /// Create a result for sequential continuation
    pub fn continue_sequential(next_pc: usize, gas_used: u64) BlockResult {
        return .{
            .exit_type = .continue_sequential,
            .next_pc = next_pc,
            .gas_used = gas_used,
        };
    }

    /// Create a result for unconditional jump
    pub fn jump(target: usize, gas_used: u64) BlockResult {
        return .{
            .exit_type = .jump,
            .jump_target = target,
            .gas_used = gas_used,
        };
    }

    /// Create a result for conditional jump
    pub fn conditional_jump(target: usize, condition: bool, next_pc: usize, gas_used: u64) BlockResult {
        return .{
            .exit_type = .conditional_jump,
            .jump_target = target,
            .condition = condition,
            .next_pc = next_pc,
            .gas_used = gas_used,
        };
    }

    /// Create a result for STOP
    pub fn stop(gas_used: u64) BlockResult {
        return .{
            .exit_type = .stop,
            .gas_used = gas_used,
        };
    }

    /// Create a result for RETURN
    pub fn return_(output: ?[]const u8, gas_used: u64) BlockResult {
        return .{
            .exit_type = .return_,
            .output = output,
            .gas_used = gas_used,
        };
    }

    /// Create a result for REVERT
    pub fn revert(output: ?[]const u8, gas_used: u64) BlockResult {
        return .{
            .exit_type = .revert,
            .output = output,
            .gas_used = gas_used,
        };
    }

    /// Create a result for CALL
    pub fn call(params: CallParams, gas_used: u64) BlockResult {
        return .{
            .exit_type = .call,
            .call_params = params,
            .gas_used = gas_used,
        };
    }

    /// Create a result for error
    pub fn error_(err: ExecutionError.Error, gas_used: u64) BlockResult {
        return .{
            .exit_type = .error_,
            .err = err,
            .gas_used = gas_used,
        };
    }

    /// Convert block result to RunResult for final execution result
    pub fn to_run_result(self: BlockResult, initial_gas: u64, gas_remaining: u64) RunResult {
        _ = initial_gas - gas_remaining + self.gas_used; // total gas used
        
        return switch (self.exit_type) {
            .stop => RunResult.init(
                initial_gas,
                gas_remaining - self.gas_used,
                .Success,
                null,
                self.output,
            ),
            .return_ => RunResult.init(
                initial_gas,
                gas_remaining - self.gas_used,
                .Success,
                null,
                self.output,
            ),
            .revert => RunResult.init(
                initial_gas,
                gas_remaining - self.gas_used,
                .Revert,
                null,
                self.output,
            ),
            .error_ => RunResult.init(
                initial_gas,
                0,
                .Invalid,
                self.err,
                null,
            ),
            else => unreachable, // Other exit types don't produce final results
        };
    }
};

test "BlockResult creation helpers" {
    const testing = std.testing;

    // Test sequential continuation
    const seq = BlockResult.continue_sequential(100, 50);
    try testing.expectEqual(BlockResult.ExitType.continue_sequential, seq.exit_type);
    try testing.expectEqual(@as(usize, 100), seq.next_pc);
    try testing.expectEqual(@as(u64, 50), seq.gas_used);

    // Test jump
    const jmp = BlockResult.jump(200, 10);
    try testing.expectEqual(BlockResult.ExitType.jump, jmp.exit_type);
    try testing.expectEqual(@as(?usize, 200), jmp.jump_target);
    try testing.expectEqual(@as(u64, 10), jmp.gas_used);

    // Test conditional jump (taken)
    const cjmp_taken = BlockResult.conditional_jump(300, true, 150, 15);
    try testing.expectEqual(BlockResult.ExitType.conditional_jump, cjmp_taken.exit_type);
    try testing.expectEqual(@as(?usize, 300), cjmp_taken.jump_target);
    try testing.expect(cjmp_taken.condition);
    try testing.expectEqual(@as(usize, 150), cjmp_taken.next_pc);

    // Test conditional jump (not taken)
    const cjmp_not_taken = BlockResult.conditional_jump(300, false, 150, 15);
    try testing.expect(!cjmp_not_taken.condition);

    // Test stop
    const stp = BlockResult.stop(100);
    try testing.expectEqual(BlockResult.ExitType.stop, stp.exit_type);

    // Test return with output
    const output = &[_]u8{0x42, 0x43};
    const ret = BlockResult.return_(output, 200);
    try testing.expectEqual(BlockResult.ExitType.return_, ret.exit_type);
    try testing.expectEqualSlices(u8, output, ret.output.?);

    // Test revert
    const rev = BlockResult.revert(null, 50);
    try testing.expectEqual(BlockResult.ExitType.revert, rev.exit_type);
    try testing.expect(rev.output == null);

    // Test error
    const err = BlockResult.error_(error.OutOfGas, 1000);
    try testing.expectEqual(BlockResult.ExitType.error_, err.exit_type);
    try testing.expectEqual(@as(?anyerror, error.OutOfGas), err.err);
}

test "BlockResult call parameters" {
    const testing = std.testing;
    const Address = primitives.Address;

    const call_params = BlockResult.CallParams{
        .call_type = .call,
        .to = Address.from_u256(0x1234),
        .value = 1000,
        .input_offset = 0,
        .input_size = 32,
        .output_offset = 64,
        .output_size = 32,
        .gas = 50000,
    };

    const result = BlockResult.call(call_params, 100);
    try testing.expectEqual(BlockResult.ExitType.call, result.exit_type);
    try testing.expect(result.call_params != null);
    try testing.expectEqual(BlockResult.CallType.call, result.call_params.?.call_type);
    try testing.expectEqual(@as(u256, 1000), result.call_params.?.value);
    try testing.expectEqual(@as(u64, 50000), result.call_params.?.gas);
}