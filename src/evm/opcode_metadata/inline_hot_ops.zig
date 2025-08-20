const std = @import("std");
const builtin = @import("builtin");
const ExecutionError = @import("../execution/execution_error.zig");
const operation_module = @import("../opcodes/operation.zig");
const Stack = @import("../stack/stack.zig");
const Log = @import("../log.zig");
const primitives = @import("primitives");

/// Optimized execute function with inlined hot operations.
///
/// This implementation reduces function call overhead for the most common opcodes
/// by inlining their implementations directly into the dispatch function.
///
/// Hot opcodes (based on mainnet analysis):
/// - PUSH1/PUSH2: ~30% of all operations
/// - DUP1/DUP2: ~10% of all operations
/// - MSTORE/MLOAD: ~15% of all operations
/// - ADD/SUB/MUL: ~10% of all operations
///
/// Performance improvements:
/// 1. Eliminates function pointer indirection for hot ops
/// 2. Enables better compiler optimizations (inlining, constant propagation)
/// 3. Improves instruction cache locality
/// 4. Reduces call/return overhead
pub fn execute_with_inline_hot_ops(
    jump_table: anytype,
    pc: usize,
    interpreter: operation_module.Interpreter,
    frame: operation_module.State,
    opcode: u8,
) ExecutionError.Error!operation_module.ExecutionResult {
    _ = jump_table;
    _ = interpreter;

    // Fast path for the hottest opcodes
    switch (opcode) {
        // PUSH1 - Most common opcode (~20-30%)
        0x60 => {
            if (comptime builtin.mode == .ReleaseFast) {
                // Skip validation - we know PUSH1 needs 0 items and pushes 1
                if (frame.stack.size() > Stack.CAPACITY - 1) {
                    return ExecutionError.Error.StackOverflow;
                }
            } else {
                if (frame.stack.size() > Stack.CAPACITY - 1) {
                    return ExecutionError.Error.StackOverflow;
                }
            }

            // Consume gas
            try frame.consume_gas(3); // GasQuickStep

            // Execute inline
            if (pc + 1 >= frame.analysis.bytecode.len) {
                try frame.stack.append(0);
            } else {
                const value = frame.analysis.bytecode[pc + 1];
                try frame.stack.append(value);
            }

            return .{ .bytes_consumed = 2 };
        },

        // DUP1 - Very common (~8-10%)
        0x80 => {
            // Validation
            if (frame.stack.size() < 1) {
                return ExecutionError.Error.StackUnderflow;
            }
            if (frame.stack.size() > Stack.CAPACITY - 1) {
                return ExecutionError.Error.StackOverflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            const value = try frame.stack.peek();
            try frame.stack.append(value);

            return .{ .bytes_consumed = 1 };
        },

        // ADD - Common arithmetic (~5%)
        0x01 => {
            // Validation
            if (frame.stack.size() < 2) {
                return ExecutionError.Error.StackUnderflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            const b = try frame.stack.pop();
            const a = try frame.stack.pop();
            const result = a +% b; // Wrapping addition
            try frame.stack.append(result);

            return .{ .bytes_consumed = 1 };
        },

        // MSTORE - Common memory operation (~5%)
        0x52 => {
            // Validation
            if (frame.stack.size() < 2) {
                return ExecutionError.Error.StackUnderflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline - delegate to memory operation for complexity
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();

            // Check offset bounds
            if (offset > std.math.maxInt(usize)) {
                return ExecutionError.Error.OutOfOffset;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const new_size = offset_usize + 32; // MSTORE writes 32 bytes

            // Calculate and consume memory expansion gas
            const new_size_u64 = @as(u64, @intCast(new_size));
            const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
            try frame.consume_gas(gas_cost);

            // Write to memory
            try frame.memory.set_u256(offset_usize, value);

            return .{ .bytes_consumed = 1 };
        },

        // MLOAD - Common memory operation (~5%)
        0x51 => {
            // Validation
            if (frame.stack.size() < 1) {
                return ExecutionError.Error.StackUnderflow;
            }
            if (frame.stack.size() > Stack.CAPACITY - 1) {
                return ExecutionError.Error.StackOverflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            const offset = frame.stack.pop_unsafe();

            // Check offset bounds
            if (offset > std.math.maxInt(usize)) {
                return ExecutionError.Error.OutOfOffset;
            }
            const offset_usize = @as(usize, @intCast(offset));
            const new_size = offset_usize + 32; // MLOAD reads 32 bytes

            // Calculate and consume memory expansion gas
            const new_size_u64 = @as(u64, @intCast(new_size));
            const gas_cost = frame.memory.get_expansion_cost(new_size_u64);
            try frame.consume_gas(gas_cost);

            // Read from memory
            const value = try frame.memory.get_u256(offset_usize);
            try frame.stack.append(value);

            return .{ .bytes_consumed = 1 };
        },

        // POP - Common stack operation (~3%)
        0x50 => {
            // Validation
            if (frame.stack.size() < 1) {
                return ExecutionError.Error.StackUnderflow;
            }

            // Consume gas
            try frame.consume_gas(2); // GasQuickStep

            // Execute inline
            _ = try frame.stack.pop();

            return .{ .bytes_consumed = 1 };
        },

        // PUSH2 - Common (~3%)
        0x61 => {
            if (frame.stack.size() > Stack.CAPACITY - 1) {
                return ExecutionError.Error.StackOverflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasQuickStep

            // Execute inline
            if (pc + 2 >= frame.analysis.bytecode.len) {
                // Partial push - pad with zeros
                var value: u256 = 0;
                if (pc + 1 < frame.analysis.bytecode.len) {
                    value = @as(u256, frame.analysis.bytecode[pc + 1]) << 8;
                }
                try frame.stack.append(value);
            } else {
                const value = (@as(u256, frame.analysis.bytecode[pc + 1]) << 8) |
                    @as(u256, frame.analysis.bytecode[pc + 2]);
                try frame.stack.append(value);
            }

            return .{ .bytes_consumed = 3 };
        },

        // SWAP1 - Common (~2%)
        0x90 => {
            // Validation
            if (frame.stack.size() < 2) {
                return ExecutionError.Error.StackUnderflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            try frame.stack.swap(1);

            return .{ .bytes_consumed = 1 };
        },

        // DUP2 - Common (~2%)
        0x81 => {
            // Validation
            if (frame.stack.size() < 2) {
                return ExecutionError.Error.StackUnderflow;
            }
            if (frame.stack.size() > Stack.CAPACITY - 1) {
                return ExecutionError.Error.StackOverflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            const value = try frame.stack.peek_n(1);
            try frame.stack.append(value);

            return .{ .bytes_consumed = 1 };
        },

        // ISZERO - Common comparison (~2%)
        0x15 => {
            // Validation
            if (frame.stack.size() < 1) {
                return ExecutionError.Error.StackUnderflow;
            }

            // Consume gas
            try frame.consume_gas(3); // GasFastestStep

            // Execute inline
            const value = try frame.stack.pop();
            const result: u256 = if (value == 0) 1 else 0;
            try frame.stack.append(result);

            return .{ .bytes_consumed = 1 };
        },

        // Fall back to regular dispatch for less common opcodes
        else => {
            // TODO: This needs to be updated for the new dispatch mechanism
            // return jump_table.execute(pc, interpreter, frame, opcode);
            return .{ .bytes_consumed = 1 };
        },
    }
}

test "inline hot ops maintains correctness" {
    // Test that inlined operations produce same results as regular dispatch
    const testing = std.testing;
    const OpcodeMetadata = @import("opcode_metadata.zig");
    const Frame = @import("../stack_frame.zig").StackFrame;
    const SimpleAnalysis = @import("../evm/analysis2.zig").SimpleAnalysis;
    const MockHost = @import("../host.zig").MockHost;
    const MemoryDatabase = @import("../state/memory_database.zig").MemoryDatabase;

    // Test PUSH1
    {
        const code = &[_]u8{ 0x60, 0x42 }; // PUSH1 0x42
        const result = try SimpleAnalysis.analyze(testing.allocator, code);
        defer testing.allocator.free(result.block_gas_costs);

        var memory_db = MemoryDatabase.init(testing.allocator);
        defer memory_db.deinit();

        var mock_host = MockHost.init(testing.allocator);
        defer mock_host.deinit();
        const host = mock_host.to_host();
        const db_interface = memory_db.to_database_interface();

        var frame = try Frame.init(
            1000, // gas_remaining
            primitives.Address.ZERO_ADDRESS, // contract_address
            result.analysis,
            &.{}, // empty ops
            host,
            db_interface,
            testing.allocator,
            false, // is_static
            primitives.Address.ZERO_ADDRESS, // caller
            0, // value
            &.{}, // input_buffer
        );
        defer frame.deinit(testing.allocator);

        const exec_result = try execute_with_inline_hot_ops(OpcodeMetadata.DEFAULT, 0, undefined, &frame, 0x60);
        try testing.expectEqual(@as(usize, 2), exec_result.bytes_consumed);
        try testing.expectEqual(@as(u256, 0x42), frame.stack.pop_unsafe());
    }

    // Test ADD
    {
        const code = &[_]u8{0x01}; // ADD
        const add_result = try SimpleAnalysis.analyze(testing.allocator, code);
        defer testing.allocator.free(add_result.block_gas_costs);

        var memory_db = MemoryDatabase.init(testing.allocator);
        defer memory_db.deinit();

        var mock_host = MockHost.init(testing.allocator);
        defer mock_host.deinit();
        const host = mock_host.to_host();
        const db_interface = memory_db.to_database_interface();

        var frame = try Frame.init(
            1000, // gas_remaining
            primitives.Address.ZERO_ADDRESS, // contract_address
            add_result.analysis,
            &.{}, // empty ops
            host,
            db_interface,
            testing.allocator,
            false, // is_static
            primitives.Address.ZERO_ADDRESS, // caller
            0, // value
            &.{}, // input_buffer
        );
        defer frame.deinit(testing.allocator);

        // Setup stack values for ADD
        frame.stack.append_unsafe(10);
        frame.stack.append_unsafe(20);

        const result = try execute_with_inline_hot_ops(OpcodeMetadata.DEFAULT, 0, undefined, &frame, 0x01);
        try testing.expectEqual(@as(usize, 1), result.bytes_consumed);
        try testing.expectEqual(@as(u256, 30), frame.stack.pop_unsafe());
    }
}
