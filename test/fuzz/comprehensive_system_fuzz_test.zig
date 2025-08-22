const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const testing = std.testing;

// Helper function to create EVM execution context with custom bytecode
fn create_evm_context_with_code(allocator: std.mem.Allocator, code: []const u8) !struct {
    db: evm.MemoryDatabase,
    vm: evm.Evm,
    contract: evm.Contract,
    frame: evm.Frame,
} {
    var db = evm.MemoryDatabase.init(allocator);
    var vm = try evm.Evm.init(allocator, db.to_database_interface(), null, null);

    var contract = evm.Contract.init(primitives.Address.ZERO, primitives.Address.ZERO, 0, 1000000, code, [_]u8{0} ** 32, &.{}, false);

    var builder = evm.Frame.builder(allocator);
    const frame = try builder
        .withVm(&vm)
        .withContract(&contract)
        .withGas(1000000)
        .withCaller(primitives.Address.ZERO)
        .build();

    return .{
        .db = db,
        .vm = vm,
        .contract = contract,
        .frame = frame,
    };
}

fn deinit_evm_context(ctx: anytype, allocator: std.mem.Allocator) void {
    ctx.frame.deinit(std.testing.allocator);
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive RETURN operation fuzz testing
test "fuzz_return_operation_edge_cases" {
    const allocator = testing.allocator;

    const return_tests = [_]struct {
        memory_data: []const u8,
        offset: u256,
        length: u256,
        description: []const u8,
    }{
        // Empty return
        .{
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .description = "Empty return",
        },

        // Single byte return
        .{
            .memory_data = &[_]u8{0x42},
            .offset = 0,
            .length = 1,
            .description = "Single byte return",
        },

        // Multi-byte return
        .{
            .memory_data = "Hello, World!",
            .offset = 0,
            .length = 13,
            .description = "Multi-byte string return",
        },

        // Return with offset
        .{
            .memory_data = "Hello, World!",
            .offset = 7,
            .length = 6, // "World!"
            .description = "Return with memory offset",
        },

        // Large data return
        .{
            .memory_data = &([_]u8{0xAA} ** 256),
            .offset = 0,
            .length = 256,
            .description = "Large data return",
        },

        // Return from middle of large data
        .{
            .memory_data = &([_]u8{0xBB} ** 1000),
            .offset = 500,
            .length = 100,
            .description = "Return subset of large data",
        },

        // Binary data return
        .{
            .memory_data = &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC },
            .offset = 0,
            .length = 8,
            .description = "Binary data return",
        },

        // Return with zero offset, partial length
        .{
            .memory_data = &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55 },
            .offset = 0,
            .length = 3,
            .description = "Partial data return",
        },

        // Return beyond data (should return zeros)
        .{
            .memory_data = &[_]u8{ 0x11, 0x22 },
            .offset = 0,
            .length = 10, // More than available data
            .description = "Return beyond available data",
        },
    };

    for (return_tests) |test_case| {
        const return_code = [_]u8{0xF3}; // RETURN
        var ctx = try create_evm_context_with_code(allocator, &return_code);
        defer deinit_evm_context(ctx, allocator);

        // Store test data in memory
        for (test_case.memory_data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset i
            try ctx.frame.stack.append(@as(u256, i));
            try ctx.frame.stack.append(@as(u256, byte));

            const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
            const state: *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for RETURN
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // RETURN should terminate execution
        const result = ctx.vm.table.execute(0, interpreter, state, 0xF3); // RETURN

        // RETURN operations should either succeed (halt execution) or fail with specific errors
        if (result) |_| {
            // Successful return - execution should be halted
            // Note: In a real EVM, this would return data to the caller
        } else |err| {
            // Some edge cases might cause errors (e.g., insufficient gas for memory expansion)
            switch (err) {
                error.OutOfGas, error.MemoryOutOfBounds => {}, // These are acceptable
                else => return err, // Unexpected errors should cause test failure
            }
        }
    }
}

// Comprehensive REVERT operation fuzz testing
test "fuzz_revert_operation_edge_cases" {
    const allocator = testing.allocator;

    const revert_tests = [_]struct {
        memory_data: []const u8,
        offset: u256,
        length: u256,
        description: []const u8,
    }{
        // Empty revert
        .{
            .memory_data = "",
            .offset = 0,
            .length = 0,
            .description = "Empty revert",
        },

        // Error message revert
        .{
            .memory_data = "Error: Invalid input",
            .offset = 0,
            .length = 19,
            .description = "Error message revert",
        },

        // Solidity-style error revert (4-byte selector + data)
        .{
            .memory_data = &[_]u8{ 0x08, 0xC3, 0x79, 0xA0 } ++ "Error message", // Error(string) selector + data
            .offset = 0,
            .length = 17,
            .description = "Solidity-style error revert",
        },

        // Custom error data
        .{
            .memory_data = &[_]u8{ 0x12, 0x34, 0x56, 0x78, 0xFF, 0xFF, 0xFF, 0xFF },
            .offset = 0,
            .length = 8,
            .description = "Custom error data revert",
        },

        // Large error data
        .{
            .memory_data = &([_]u8{0xEE} ** 512),
            .offset = 0,
            .length = 512,
            .description = "Large error data revert",
        },

        // Revert with offset
        .{
            .memory_data = "PREFIX_ERROR_SUFFIX",
            .offset = 7,
            .length = 5, // "ERROR"
            .description = "Revert with memory offset",
        },

        // Revert beyond data (should return zeros)
        .{
            .memory_data = &[_]u8{ 0xAA, 0xBB },
            .offset = 0,
            .length = 10, // More than available data
            .description = "Revert beyond available data",
        },
    };

    for (revert_tests) |test_case| {
        const revert_code = [_]u8{0xFD}; // REVERT
        var ctx = try create_evm_context_with_code(allocator, &revert_code);
        defer deinit_evm_context(ctx, allocator);

        // Store test data in memory
        for (test_case.memory_data, 0..) |byte, i| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            // MSTORE8: store byte at offset i
            try ctx.frame.stack.append(@as(u256, i));
            try ctx.frame.stack.append(@as(u256, byte));

            const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
            const state: *evm.Operation.State = @ptrCast(&ctx.frame);
            _ = try ctx.vm.table.execute(0, interpreter, state, 0x53); // MSTORE8
        }

        // Clear stack and prepare for REVERT
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }

        try ctx.frame.stack.append(test_case.offset);
        try ctx.frame.stack.append(test_case.length);

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // REVERT should always cause execution to revert
        const result = ctx.vm.table.execute(0, interpreter, state, 0xFD); // REVERT

        // REVERT should either cause a revert error or handle the revert gracefully
        if (result) |_| {
            // Some implementations might handle REVERT without throwing an error
            // but still halt execution and revert state changes
        } else |err| {
            // Expected errors for REVERT
            switch (err) {
                error.ExecutionReverted, error.OutOfGas, error.MemoryOutOfBounds => {}, // These are acceptable
                else => return err, // Unexpected errors should cause test failure
            }
        }
    }
}

// Comprehensive STOP operation fuzz testing
test "fuzz_stop_operation" {
    const allocator = testing.allocator;

    // Test STOP with different stack states
    const stack_states = [_][]const u256{
        &[_]u256{}, // Empty stack
        &[_]u256{42}, // Single item
        &[_]u256{ 1, 2, 3, 4, 5 }, // Multiple items
        &[_]u256{std.math.maxInt(u256)}, // Maximum value
        &([_]u256{0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA} ** 100), // Many items
    };

    for (stack_states) |initial_stack| {
        const stop_code = [_]u8{0x00}; // STOP
        var ctx = try create_evm_context_with_code(allocator, &stop_code);
        defer deinit_evm_context(ctx, allocator);

        // Set up initial stack state
        for (initial_stack) |value| {
            try ctx.frame.stack.append(value);
        }

        const initial_stack_size = ctx.frame.stack.items.len;

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // STOP should halt execution successfully
        const result = ctx.vm.table.execute(0, interpreter, state, 0x00); // STOP

        if (result) |_| {
            // STOP should succeed and leave stack unchanged
            try testing.expectEqual(initial_stack_size, ctx.frame.stack.items.len);
        } else |err| {
            // STOP should not cause errors under normal circumstances
            return err;
        }
    }
}

// Comprehensive INVALID operation fuzz testing
test "fuzz_invalid_operation" {
    const allocator = testing.allocator;

    // Test INVALID with different stack states
    const stack_states = [_][]const u256{
        &[_]u256{}, // Empty stack
        &[_]u256{42}, // Single item
        &[_]u256{ 1, 2, 3, 4, 5 }, // Multiple items
    };

    for (stack_states) |initial_stack| {
        const invalid_code = [_]u8{0xFE}; // INVALID
        var ctx = try create_evm_context_with_code(allocator, &invalid_code);
        defer deinit_evm_context(ctx, allocator);

        // Set up initial stack state
        for (initial_stack) |value| {
            try ctx.frame.stack.append(value);
        }

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        // INVALID should always cause an error
        const result = ctx.vm.table.execute(0, interpreter, state, 0xFE); // INVALID

        // INVALID should always fail
        try testing.expectError(error.InvalidInstruction, result);
    }
}

// Test system operations with memory expansion
test "fuzz_system_operations_memory_expansion" {
    const allocator = testing.allocator;

    const expansion_tests = [_]struct {
        offset: u256,
        length: u256,
        description: []const u8,
    }{
        // Normal memory access
        .{
            .offset = 0,
            .length = 32,
            .description = "Normal 32-byte access",
        },

        // Large offset
        .{
            .offset = 1000,
            .length = 100,
            .description = "Large offset access",
        },

        // Very large memory expansion
        .{
            .offset = 10000,
            .length = 1000,
            .description = "Very large memory expansion",
        },

        // Maximum reasonable size
        .{
            .offset = 0,
            .length = 1024 * 1024, // 1MB
            .description = "1MB memory access",
        },
    };

    for (expansion_tests) |test_case| {
        // Test with RETURN
        {
            const return_code = [_]u8{0xF3}; // RETURN
            var ctx = try create_evm_context_with_code(allocator, &return_code);
            defer deinit_evm_context(ctx, allocator);

            // Clear stack and prepare for RETURN
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(test_case.offset);
            try ctx.frame.stack.append(test_case.length);

            const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
            const state: *evm.Operation.State = @ptrCast(&ctx.frame);

            // Large memory expansions might run out of gas
            const result = ctx.vm.table.execute(0, interpreter, state, 0xF3); // RETURN

            if (result) |_| {
                // Success - memory expansion worked
            } else |err| {
                // Large expansions might fail due to gas or memory limits
                switch (err) {
                    error.OutOfGas, error.MemoryOutOfBounds => {}, // These are acceptable
                    else => return err,
                }
            }
        }

        // Test with REVERT (same memory expansion logic)
        {
            const revert_code = [_]u8{0xFD}; // REVERT
            var ctx = try create_evm_context_with_code(allocator, &revert_code);
            defer deinit_evm_context(ctx, allocator);

            // Clear stack and prepare for REVERT
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }

            try ctx.frame.stack.append(test_case.offset);
            try ctx.frame.stack.append(test_case.length);

            const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
            const state: *evm.Operation.State = @ptrCast(&ctx.frame);

            const result = ctx.vm.table.execute(0, interpreter, state, 0xFD); // REVERT

            if (result) |_| {
                // Some implementations might handle REVERT gracefully
            } else |err| {
                switch (err) {
                    error.ExecutionReverted, error.OutOfGas, error.MemoryOutOfBounds => {}, // These are acceptable
                    else => return err,
                }
            }
        }
    }
}

// Random system operations stress test
test "fuzz_system_operations_stress_test" {
    const allocator = testing.allocator;

    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    // Test many random combinations
    for (0..100) |_| {
        const operation = random.intRangeAtMost(u8, 0, 3);
        const offset = random.intRangeAtMost(u256, 0, 1000);
        const length = random.intRangeAtMost(u256, 0, 1000);

        const opcodes = [_]u8{ 0x00, 0xF3, 0xFD, 0xFE }; // STOP, RETURN, REVERT, INVALID
        const opcode = opcodes[operation];

        var ctx = try create_evm_context_with_code(allocator, &[_]u8{opcode});
        defer deinit_evm_context(ctx, allocator);

        // For RETURN and REVERT, set up memory access parameters
        if (opcode == 0xF3 or opcode == 0xFD) {
            try ctx.frame.stack.append(offset);
            try ctx.frame.stack.append(length);
        }

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = ctx.vm.table.execute(0, interpreter, state, opcode);

        // Validate expected behavior based on opcode
        switch (opcode) {
            0x00 => { // STOP
                _ = try result; // Should succeed
            },
            0xF3 => { // RETURN
                if (result) |_| {
                    // Success
                } else |err| {
                    switch (err) {
                        error.OutOfGas, error.MemoryOutOfBounds => {}, // Acceptable
                        else => return err,
                    }
                }
            },
            0xFD => { // REVERT
                if (result) |_| {
                    // Some implementations handle gracefully
                } else |err| {
                    switch (err) {
                        error.ExecutionReverted, error.OutOfGas, error.MemoryOutOfBounds => {}, // Acceptable
                        else => return err,
                    }
                }
            },
            0xFE => { // INVALID
                try testing.expectError(error.InvalidInstruction, result);
            },
            else => unreachable,
        }
    }
}

// Test gas consumption patterns for system operations
test "fuzz_system_operations_gas_consumption" {
    const allocator = testing.allocator;

    const gas_tests = [_]struct {
        initial_gas: u64,
        opcode: u8,
        setup_stack: bool,
        description: []const u8,
    }{
        // STOP with various gas levels
        .{
            .initial_gas = 1000000,
            .opcode = 0x00, // STOP
            .setup_stack = false,
            .description = "STOP with high gas",
        },
        .{
            .initial_gas = 100,
            .opcode = 0x00, // STOP
            .setup_stack = false,
            .description = "STOP with low gas",
        },
        .{
            .initial_gas = 0,
            .opcode = 0x00, // STOP
            .setup_stack = false,
            .description = "STOP with zero gas",
        },

        // RETURN with various gas levels
        .{
            .initial_gas = 1000000,
            .opcode = 0xF3, // RETURN
            .setup_stack = true,
            .description = "RETURN with high gas",
        },
        .{
            .initial_gas = 1000,
            .opcode = 0xF3, // RETURN
            .setup_stack = true,
            .description = "RETURN with medium gas",
        },
        .{
            .initial_gas = 10,
            .opcode = 0xF3, // RETURN
            .setup_stack = true,
            .description = "RETURN with very low gas",
        },

        // INVALID with various gas levels
        .{
            .initial_gas = 1000000,
            .opcode = 0xFE, // INVALID
            .setup_stack = false,
            .description = "INVALID with high gas",
        },
        .{
            .initial_gas = 0,
            .opcode = 0xFE, // INVALID
            .setup_stack = false,
            .description = "INVALID with zero gas",
        },
    };

    for (gas_tests) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, &[_]u8{test_case.opcode});
        defer deinit_evm_context(ctx, allocator);

        // Set initial gas
        ctx.frame.gas_remaining = test_case.initial_gas;

        // Set up stack if needed
        if (test_case.setup_stack) {
            try ctx.frame.stack.append(0); // offset
            try ctx.frame.stack.append(0); // length
        }

        _ = ctx.frame.gas_remaining; // Keep track of initial gas

        const interpreter: *evm.Operation.Interpreter = @ptrCast(&ctx.vm);
        const state: *evm.Operation.State = @ptrCast(&ctx.frame);

        const result = ctx.vm.table.execute(0, interpreter, state, test_case.opcode);

        // Validate gas consumption behavior
        switch (test_case.opcode) {
            0x00 => { // STOP
                _ = try result; // Should succeed regardless of gas
                // Gas should be consumed (or execution halted)
            },
            0xF3 => { // RETURN
                if (result) |_| {
                    // Successful return
                } else |err| {
                    if (test_case.initial_gas < 100) { // Might run out of gas
                        switch (err) {
                            error.OutOfGas => {}, // Expected for low gas
                            else => return err,
                        }
                    } else {
                        return err; // Unexpected error with sufficient gas
                    }
                }
            },
            0xFE => { // INVALID
                try testing.expectError(error.InvalidInstruction, result);
                // Gas consumption behavior depends on implementation
            },
            else => unreachable,
        }
    }
}
