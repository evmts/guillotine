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
    const config = evm.EvmConfig.init(.CANCUN);
    const EvmType = evm.Evm(config);
    var vm = try EvmType.init(allocator, db.to_database_interface(), null, 0, false, null);
    
    var contract = evm.Contract.init(
        primitives.Address.ZERO,
        primitives.Address.ZERO,
        0,
        1000000,
        code,
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

// Comprehensive PUSH operations fuzz testing (PUSH1-PUSH32)
test "fuzz_push_operations_all_sizes" {
    const allocator = testing.allocator;
    
    // Test all PUSH operations from PUSH1 to PUSH32
    for (1..33) |push_size| {
        const opcode = 0x60 + push_size - 1; // PUSH1=0x60, PUSH2=0x61, ..., PUSH32=0x7F
        
        // Create test data of the appropriate size
        var test_data = try allocator.alloc(u8, push_size);
        defer allocator.free(test_data);
        
        // Fill with pattern data
        for (test_data, 0..) |*byte, i| {
            byte.* = @intCast((i + 1) % 256);
        }
        
        // Create bytecode: PUSH<N> <data>
        var bytecode = try allocator.alloc(u8, 1 + push_size);
        defer allocator.free(bytecode);
        bytecode[0] = @intCast(opcode);
        @memcpy(bytecode[1..], test_data);
        
        var ctx = try create_evm_context_with_code(allocator, bytecode);
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
        
        const result = try ctx.frame.stack.pop();
        
        // Convert test data to u256 (big-endian)
        var expected: u256 = 0;
        for (test_data, 0..) |byte, i| {
            expected = (expected << 8) | byte;
        }
        
        try testing.expectEqual(expected, result);
    }
}

// Test PUSH operations with specific value patterns
test "fuzz_push_value_patterns" {
    const allocator = testing.allocator;
    
    const push_tests = [_]struct {
        push_size: usize,
        data: []const u8,
        expected: u256,
        description: []const u8,
    }{
        // PUSH1 tests
        .{
            .push_size = 1,
            .data = &[_]u8{0x00},
            .expected = 0x00,
            .description = "PUSH1 zero",
        },
        .{
            .push_size = 1,
            .data = &[_]u8{0xFF},
            .expected = 0xFF,
            .description = "PUSH1 max byte",
        },
        .{
            .push_size = 1,
            .data = &[_]u8{0x42},
            .expected = 0x42,
            .description = "PUSH1 arbitrary value",
        },
        
        // PUSH2 tests
        .{
            .push_size = 2,
            .data = &[_]u8{0x12, 0x34},
            .expected = 0x1234,
            .description = "PUSH2 word",
        },
        .{
            .push_size = 2,
            .data = &[_]u8{0xFF, 0xFF},
            .expected = 0xFFFF,
            .description = "PUSH2 max",
        },
        
        // PUSH4 tests (32-bit values)
        .{
            .push_size = 4,
            .data = &[_]u8{0x12, 0x34, 0x56, 0x78},
            .expected = 0x12345678,
            .description = "PUSH4 dword",
        },
        
        // PUSH8 tests (64-bit values)
        .{
            .push_size = 8,
            .data = &[_]u8{0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0},
            .expected = 0x123456789ABCDEF0,
            .description = "PUSH8 qword",
        },
        
        // PUSH20 tests (address-sized)
        .{
            .push_size = 20,
            .data = &([_]u8{0xAA} ** 20),
            .expected = 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,
            .description = "PUSH20 address pattern",
        },
        
        // PUSH32 tests (full word)
        .{
            .push_size = 32,
            .data = &[_]u8{0x12, 0x34, 0x56, 0x78} ++ ([_]u8{0x00} ** 28),
            .expected = 0x12345678000000000000000000000000000000000000000000000000000000000,
            .description = "PUSH32 with leading bytes",
        },
        .{
            .push_size = 32,
            .data = &([_]u8{0x00} ** 28) ++ [_]u8{0x12, 0x34, 0x56, 0x78},
            .expected = 0x12345678,
            .description = "PUSH32 with trailing bytes",
        },
        .{
            .push_size = 32,
            .data = &([_]u8{0xFF} ** 32),
            .expected = std.math.maxInt(u256),
            .description = "PUSH32 max value",
        },
    };
    
    for (push_tests) |test_case| {
        const opcode = 0x60 + test_case.push_size - 1;
        
        // Create bytecode: PUSH<N> <data>
        var bytecode = try allocator.alloc(u8, 1 + test_case.data.len);
        defer allocator.free(bytecode);
        bytecode[0] = @intCast(opcode);
        @memcpy(bytecode[1..], test_case.data);
        
        var ctx = try create_evm_context_with_code(allocator, bytecode);
        defer deinit_evm_context(ctx, allocator);
        
        // Clear stack
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = evm.Operation.State = &ctx.frame;
        _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
        
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(test_case.expected, result);
    }
}

// Comprehensive POP operation fuzz testing
test "fuzz_pop_operation_edge_cases" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x50}; // POP
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    const test_values = [_]u256{
        0,
        1,
        0xFF,
        0xFFFF,
        0xFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        std.math.maxInt(u256),
        0x123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0,
        1 << 128,
        1 << 255,
    };
    
    for (test_values) |test_value| {
        // Clear stack and push test value
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(test_value);
        const initial_stack_size = ctx.frame.stack.items.len;
        
        // Execute POP
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x50); // POP
        
        // Verify stack size decreased by 1
        try testing.expectEqual(initial_stack_size - 1, ctx.frame.stack.items.len);
    }
    
    // Test POP on empty stack (should fail)
    {
        // Clear stack completely
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // POP on empty stack should fail
        try testing.expectError(error.StackUnderflow, ctx.vm.table.execute(0, interpreter, state, 0x50));
    }
}

// Comprehensive DUP operations fuzz testing (DUP1-DUP16)
test "fuzz_dup_operations_all_positions" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x80}; // DUP1
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test all DUP operations from DUP1 to DUP16
    for (1..17) |dup_position| {
        const opcode = 0x80 + dup_position - 1; // DUP1=0x80, DUP2=0x81, ..., DUP16=0x8F
        
        // Clear stack and set up test data
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // Push enough values to test the DUP operation
        // DUP1 duplicates top (position 1), DUP2 duplicates second from top (position 2), etc.
        const stack_values = [_]u256{
            0x1111111111111111111111111111111111111111111111111111111111111111,
            0x2222222222222222222222222222222222222222222222222222222222222222,
            0x3333333333333333333333333333333333333333333333333333333333333333,
            0x4444444444444444444444444444444444444444444444444444444444444444,
            0x5555555555555555555555555555555555555555555555555555555555555555,
            0x6666666666666666666666666666666666666666666666666666666666666666,
            0x7777777777777777777777777777777777777777777777777777777777777777,
            0x8888888888888888888888888888888888888888888888888888888888888888,
            0x9999999999999999999999999999999999999999999999999999999999999999,
            0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,
            0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB,
            0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC,
            0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD,
            0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
            0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF,
        };
        
        // Push values onto stack (in reverse order so first value is on top)
        for (0..dup_position) |i| {
            try ctx.frame.stack.append(stack_values[dup_position - 1 - i]);
        }
        
        const initial_stack_size = ctx.frame.stack.items.len;
        const expected_value = stack_values[dup_position - 1]; // Value that should be duplicated
        
        // Execute DUP operation
        _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
        
        // Verify stack size increased by 1
        try testing.expectEqual(initial_stack_size + 1, ctx.frame.stack.items.len);
        
        // Verify the top value is the duplicated value
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(expected_value, result);
        
        // Verify the original value is still in its position
        const original_position_value = ctx.frame.stack.items[ctx.frame.stack.items.len - dup_position];
        try testing.expectEqual(expected_value, original_position_value);
    }
}

// Test DUP operations with insufficient stack depth
test "fuzz_dup_stack_underflow_cases" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x80}; // DUP1
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test DUP operations with insufficient stack depth
    for (1..17) |dup_position| {
        const opcode = 0x80 + dup_position - 1;
        
        // Test with stack depth less than required
        for (0..dup_position) |stack_depth| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            // Push only stack_depth values (less than required)
            for (0..stack_depth) |i| {
                try ctx.frame.stack.append(@as(u256, i + 1));
            }
            
            if (stack_depth < dup_position) {
                // Should fail with stack underflow
                try testing.expectError(error.StackUnderflow, ctx.vm.table.execute(0, interpreter, state, @intCast(opcode)));
            } else {
                // Should succeed
                _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
                
                // Clean up for next iteration
                _ = try ctx.frame.stack.pop(); // Remove the duplicated value
            }
        }
    }
}

// Comprehensive SWAP operations fuzz testing (SWAP1-SWAP16)
test "fuzz_swap_operations_all_positions" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x90}; // SWAP1
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test all SWAP operations from SWAP1 to SWAP16
    for (1..17) |swap_position| {
        const opcode = 0x90 + swap_position - 1; // SWAP1=0x90, SWAP2=0x91, ..., SWAP16=0x9F
        
        // Clear stack and set up test data
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        // SWAP1 swaps top with second (positions 1 and 2)
        // SWAP2 swaps top with third (positions 1 and 3), etc.
        const stack_values = [_]u256{
            0x1111111111111111111111111111111111111111111111111111111111111111,
            0x2222222222222222222222222222222222222222222222222222222222222222,
            0x3333333333333333333333333333333333333333333333333333333333333333,
            0x4444444444444444444444444444444444444444444444444444444444444444,
            0x5555555555555555555555555555555555555555555555555555555555555555,
            0x6666666666666666666666666666666666666666666666666666666666666666,
            0x7777777777777777777777777777777777777777777777777777777777777777,
            0x8888888888888888888888888888888888888888888888888888888888888888,
            0x9999999999999999999999999999999999999999999999999999999999999999,
            0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA,
            0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB,
            0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC,
            0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD,
            0xEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE,
            0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF,
            0x1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF,
            0xFEDCBA0987654321FEDCBA0987654321FEDCBA0987654321FEDCBA0987654321,
        };
        
        // Push enough values for the swap operation (swap_position + 1 minimum)
        for (0..swap_position + 1) |i| {
            try ctx.frame.stack.append(stack_values[i]);
        }
        
        const initial_stack_size = ctx.frame.stack.items.len;
        const top_value = stack_values[swap_position]; // Will be the top value after pushing
        const swap_target_value = stack_values[0]; // Will be at swap_position from top
        
        // Execute SWAP operation
        _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
        
        // Verify stack size unchanged
        try testing.expectEqual(initial_stack_size, ctx.frame.stack.items.len);
        
        // Verify the swap occurred
        const new_top = ctx.frame.stack.items[ctx.frame.stack.items.len - 1];
        const new_swap_target = ctx.frame.stack.items[ctx.frame.stack.items.len - 1 - swap_position];
        
        try testing.expectEqual(swap_target_value, new_top);
        try testing.expectEqual(top_value, new_swap_target);
    }
}

// Test SWAP operations with insufficient stack depth
test "fuzz_swap_stack_underflow_cases" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x90}; // SWAP1
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test SWAP operations with insufficient stack depth
    for (1..17) |swap_position| {
        const opcode = 0x90 + swap_position - 1;
        const required_depth = swap_position + 1; // SWAP1 needs 2 items, SWAP2 needs 3, etc.
        
        // Test with stack depth less than required
        for (0..required_depth + 1) |stack_depth| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            // Push only stack_depth values
            for (0..stack_depth) |i| {
                try ctx.frame.stack.append(@as(u256, i + 1));
            }
            
            if (stack_depth < required_depth) {
                // Should fail with stack underflow
                try testing.expectError(error.StackUnderflow, ctx.vm.table.execute(0, interpreter, state, @intCast(opcode)));
            } else {
                // Should succeed
                _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
            }
        }
    }
}

// Test stack operations with maximum stack depth
test "fuzz_stack_operations_max_depth" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x60}; // PUSH1
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    const max_stack_size = 1024; // EVM stack limit
    
    // Fill stack to near maximum
    for (0..max_stack_size - 1) |i| {
        try ctx.frame.stack.append(@as(u256, i));
    }
    
    // Test PUSH on nearly full stack (should succeed)
    {
        const push1_code = [_]u8{0x60, 0x42}; // PUSH1 0x42
        var push_ctx = try create_evm_context_with_code(allocator, &push1_code);
        defer deinit_evm_context(push_ctx, allocator);
        
        // Copy stack state
        push_ctx.frame.stack.clearRetainingCapacity();
        for (0..max_stack_size - 1) |i| {
            try push_ctx.frame.stack.append(@as(u256, i));
        }
        
        var push_interpreter = evm.Operation.Interpreter = &push_ctx.vm;
        var push_state = evm.Operation.State = &push_ctx.frame;
        
        // This should succeed (brings stack to exactly max_stack_size)
        _ = try push_ctx.vm.table.execute(0, &push_interpreter, &push_state, 0x60);
        try testing.expectEqual(max_stack_size, push_ctx.frame.stack.items.len);
        
        // Trying to push one more should fail
        push_ctx.frame.pc = 0; // Reset PC for next instruction
        try testing.expectError(error.StackOverflow, push_ctx.vm.table.execute(0, &push_interpreter, &push_state, 0x60));
    }
    
    // Test DUP operations on nearly full stack
    {
        for (1..17) |dup_pos| {
            if (max_stack_size - 1 >= dup_pos) { // Ensure we have enough items to duplicate
                const opcode = 0x80 + dup_pos - 1;
                
                ctx.frame.stack.clearRetainingCapacity();
                for (0..max_stack_size - 1) |i| {
                    try ctx.frame.stack.append(@as(u256, i));
                }
                
                // DUP should succeed (brings stack to max_stack_size)
                _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
                try testing.expectEqual(max_stack_size, ctx.frame.stack.items.len);
                
                // Remove the duplicated item for next test
                _ = try ctx.frame.stack.pop();
            }
        }
    }
}

// Complex stack operations stress test
test "fuzz_stack_operations_complex_patterns" {
    const allocator = testing.allocator;
    const simple_code = [_]u8{0x01}; // ADD
    var ctx = try create_evm_context_with_code(allocator, &simple_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Perform many random stack operations
    for (0..1000) |_| {
        const operation = random.intRangeAtMost(u8, 0, 3);
        
        switch (operation) {
            0 => { // PUSH1 random value
                if (ctx.frame.stack.items.len < 1024) { // Avoid stack overflow
                    const value = random.int(u8);
                    try ctx.frame.stack.append(@as(u256, value));
                }
            },
            1 => { // POP if possible
                if (ctx.frame.stack.items.len > 0) {
                    _ = try ctx.frame.stack.pop();
                }
            },
            2 => { // DUP random position if possible
                if (ctx.frame.stack.items.len > 0 and ctx.frame.stack.items.len < 1024) {
                    const dup_pos = random.intRangeAtMost(usize, 1, @min(16, ctx.frame.stack.items.len));
                    const opcode = 0x80 + dup_pos - 1;
                    
                    const stack_len = ctx.frame.stack.items.len;
                    const expected_value = ctx.frame.stack.items[stack_len - dup_pos];
                    
                    _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
                    
                    // Verify duplication worked
                    const result = ctx.frame.stack.items[ctx.frame.stack.items.len - 1];
                    try testing.expectEqual(expected_value, result);
                }
            },
            3 => { // SWAP random position if possible
                if (ctx.frame.stack.items.len > 1) {
                    const swap_pos = random.intRangeAtMost(usize, 1, @min(16, ctx.frame.stack.items.len - 1));
                    const opcode = 0x90 + swap_pos - 1;
                    
                    const stack_len = ctx.frame.stack.items.len;
                    const top_value = ctx.frame.stack.items[stack_len - 1];
                    const swap_target_value = ctx.frame.stack.items[stack_len - 1 - swap_pos];
                    
                    _ = try ctx.vm.table.execute(0, interpreter, state, @intCast(opcode));
                    
                    // Verify swap worked
                    const new_top = ctx.frame.stack.items[stack_len - 1];
                    const new_swap_target = ctx.frame.stack.items[stack_len - 1 - swap_pos];
                    
                    try testing.expectEqual(swap_target_value, new_top);
                    try testing.expectEqual(top_value, new_swap_target);
                }
            },
            else => unreachable,
        }
        
        // Maintain some invariants
        try testing.expect(ctx.frame.stack.items.len <= 1024); // Never exceed max stack size
    }
}

// Test PUSH0 operation (EIP-3855, introduced in Shanghai)
test "fuzz_push0_operation" {
    const allocator = testing.allocator;
    const push0_code = [_]u8{0x5F}; // PUSH0
    var ctx = try create_evm_context_with_code(allocator, &push0_code);
    defer deinit_evm_context(ctx, allocator);
    
    var interpreter = evm.Operation.Interpreter = &ctx.vm;
    var state = *evm.Operation.State = @ptrCast(&ctx.frame);
    
    // Test PUSH0 multiple times
    for (0..10) |_| {
        const initial_stack_size = ctx.frame.stack.items.len;
        
        // Execute PUSH0
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x5F);
        
        // Verify stack size increased by 1
        try testing.expectEqual(initial_stack_size + 1, ctx.frame.stack.items.len);
        
        // Verify the pushed value is 0
        const result = try ctx.frame.stack.pop();
        try testing.expectEqual(@as(u256, 0), result);
    }
    
    // Test PUSH0 on nearly full stack
    {
        // Fill stack to near maximum
        ctx.frame.stack.clearRetainingCapacity();
        for (0..1023) |i| {
            try ctx.frame.stack.append(@as(u256, i));
        }
        
        // PUSH0 should succeed (brings stack to exactly 1024)
        _ = try ctx.vm.table.execute(0, interpreter, state, 0x5F);
        try testing.expectEqual(@as(usize, 1024), ctx.frame.stack.items.len);
        
        // Verify the pushed value is 0
        const top_value = ctx.frame.stack.items[ctx.frame.stack.items.len - 1];
        try testing.expectEqual(@as(u256, 0), top_value);
        
        // Trying to push one more should fail
        try testing.expectError(error.StackOverflow, ctx.vm.table.execute(0, interpreter, state, 0x5F));
    }
}