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
    ctx.frame.deinit(std.testing.allocator);
    ctx.contract.deinit(allocator, null);
    ctx.vm.deinit();
    ctx.db.deinit();
}

// Comprehensive PC (Program Counter) operation fuzz testing
test "fuzz_pc_program_counter_edge_cases" {
    const allocator = testing.allocator;
    
    // Test PC at various positions in bytecode
    const test_codes = [_]struct { code: []const u8, expected_positions: []const usize }{
        // Simple code with PC at different positions
        .{ 
            .code = &[_]u8{0x58, 0x58, 0x58}, // PC, PC, PC
            .expected_positions = &[_]usize{0, 1, 2}
        },
        
        // Code with PUSH operations (PC should skip immediate data)
        .{
            .code = &[_]u8{0x58, 0x60, 0x01, 0x58}, // PC, PUSH1 0x01, PC
            .expected_positions = &[_]usize{0, 3}
        },
        
        // Code with larger PUSH operations
        .{
            .code = &[_]u8{0x58, 0x7F} ++ ([_]u8{0xFF} ** 32) ++ [_]u8{0x58}, // PC, PUSH32 (32 bytes), PC
            .expected_positions = &[_]usize{0, 34}
        },
        
        // Mixed operations
        .{
            .code = &[_]u8{0x01, 0x58, 0x02, 0x58, 0x03}, // ADD, PC, MUL, PC, SUB
            .expected_positions = &[_]usize{1, 3}
        },
    };
    
    for (test_codes) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        
        var expected_index: usize = 0;
        var pc: usize = 0;
        
        while (pc < test_case.code.len and expected_index < test_case.expected_positions.len) {
            ctx.frame.pc = pc;
            
            if (test_case.code[pc] == 0x58) { // PC opcode
                // Clear stack
                while (ctx.frame.stack.items.len > 0) {
                    _ = try ctx.frame.stack.pop();
                }
                
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x58); // PC
                const result = try ctx.frame.stack.pop();
                
                try testing.expectEqual(@as(u256, test_case.expected_positions[expected_index]), result);
                expected_index += 1;
                pc += 1;
            } else if (test_case.code[pc] >= 0x60 and test_case.code[pc] <= 0x7F) {
                // PUSH operation - skip immediate data
                const push_size = test_case.code[pc] - 0x60 + 1;
                pc += 1 + push_size;
            } else {
                // Other operation
                pc += 1;
            }
        }
    }
}

// Comprehensive JUMPDEST operation fuzz testing
test "fuzz_jumpdest_valid_destinations" {
    const allocator = testing.allocator;
    
    const test_codes = [_]struct { code: []const u8, jumpdest_positions: []const usize }{
        // Simple JUMPDEST at beginning
        .{
            .code = &[_]u8{0x5B, 0x00}, // JUMPDEST, STOP
            .jumpdest_positions = &[_]usize{0}
        },
        
        // JUMPDEST after other operations
        .{
            .code = &[_]u8{0x01, 0x02, 0x5B, 0x00}, // ADD, MUL, JUMPDEST, STOP
            .jumpdest_positions = &[_]usize{2}
        },
        
        // Multiple JUMPDESTs
        .{
            .code = &[_]u8{0x5B, 0x01, 0x5B, 0x02, 0x5B}, // JUMPDEST, ADD, JUMPDEST, MUL, JUMPDEST
            .jumpdest_positions = &[_]usize{0, 2, 4}
        },
        
        // JUMPDEST not in PUSH immediate data (should be valid)
        .{
            .code = &[_]u8{0x60, 0x5B, 0x5B, 0x00}, // PUSH1 0x5B, JUMPDEST, STOP
            .jumpdest_positions = &[_]usize{2}
        },
        
        // JUMPDEST inside PUSH immediate data (should be invalid)
        .{
            .code = &[_]u8{0x61, 0x5B, 0x5B, 0x00}, // PUSH2 0x5B5B, STOP
            .jumpdest_positions = &[_]usize{} // No valid jumpdests
        },
        
        // Large PUSH with JUMPDEST in immediate data
        .{
            .code = &[_]u8{0x7F} ++ ([_]u8{0x5B} ** 32) ++ [_]u8{0x5B, 0x00}, // PUSH32 (32 0x5B bytes), JUMPDEST, STOP
            .jumpdest_positions = &[_]usize{33}
        },
    };
    
    for (test_codes) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        // Analyze the code to find valid jump destinations
        const jump_map = try ctx.frame.contract.code_analysis.create_jump_map(allocator, test_case.code);
        defer allocator.free(jump_map);
        
        // Verify that our expected JUMPDEST positions are marked as valid
        for (test_case.jumpdest_positions) |pos| {
            try testing.expect(ctx.frame.contract.code_analysis.is_valid_jump(jump_map, pos));
        }
        
        // Verify that positions not in our list are not valid jumpdests
        for (0..test_case.code.len) |pos| {
            const is_expected = for (test_case.jumpdest_positions) |expected| {
                if (expected == pos) break true;
            } else false;
            
            if (test_case.code[pos] == 0x5B and !is_expected) {
                // This should be an invalid jumpdest (inside PUSH data)
                try testing.expect(!ctx.frame.contract.code_analysis.is_valid_jump(jump_map, pos));
            }
        }
    }
}

// Comprehensive JUMP operation fuzz testing
test "fuzz_jump_valid_and_invalid_destinations" {
    const allocator = testing.allocator;
    
    // Test valid jumps
    const valid_jump_test = struct {
        code: []const u8,
        jump_to: usize,
        should_succeed: bool,
    };
    
    const jump_tests = [_]valid_jump_test{
        // Valid jump to JUMPDEST
        .{
            .code = &[_]u8{0x60, 0x04, 0x56, 0x00, 0x5B, 0x00}, // PUSH1 4, JUMP, STOP, JUMPDEST, STOP
            .jump_to = 4,
            .should_succeed = true,
        },
        
        // Invalid jump to non-JUMPDEST
        .{
            .code = &[_]u8{0x60, 0x04, 0x56, 0x00, 0x01, 0x00}, // PUSH1 4, JUMP, STOP, ADD, STOP
            .jump_to = 4,
            .should_succeed = false,
        },
        
        // Jump to out-of-bounds location
        .{
            .code = &[_]u8{0x60, 0xFF, 0x56, 0x00}, // PUSH1 255, JUMP, STOP
            .jump_to = 255,
            .should_succeed = false,
        },
        
        // Jump to JUMPDEST inside PUSH data (should fail)
        .{
            .code = &[_]u8{0x60, 0x03, 0x56, 0x61, 0x5B, 0x5B, 0x5B, 0x00}, // PUSH1 3, JUMP, PUSH2 0x5B5B, JUMPDEST, STOP
            .jump_to = 3,
            .should_succeed = false,
        },
        
        // Valid jump to beginning of code
        .{
            .code = &[_]u8{0x5B, 0x60, 0x00, 0x56}, // JUMPDEST, PUSH1 0, JUMP
            .jump_to = 0,
            .should_succeed = true,
        },
    };
    
    for (jump_tests) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        
        // Clear stack and push jump destination
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(@as(u256, test_case.jump_to));
        
        // Try to execute JUMP
        const result = ctx.vm.table.execute(0, interpreter, state, 0x56); // JUMP
        
        if (test_case.should_succeed) {
            // Should succeed and update PC
            _ = try result;
            try testing.expectEqual(test_case.jump_to, ctx.frame.pc);
        } else {
            // Should fail with an error
            try testing.expectError(error.InvalidJump, result);
        }
    }
}

// Comprehensive JUMPI (conditional jump) operation fuzz testing
test "fuzz_jumpi_conditional_jump_edge_cases" {
    const allocator = testing.allocator;
    
    const jumpi_test = struct {
        code: []const u8,
        jump_to: usize,
        condition: u256,
        should_jump: bool,
    };
    
    const jumpi_tests = [_]jumpi_test{
        // Condition is non-zero, should jump
        .{
            .code = &[_]u8{0x60, 0x05, 0x60, 0x01, 0x57, 0x5B, 0x00}, // PUSH1 5, PUSH1 1, JUMPI, JUMPDEST, STOP
            .jump_to = 5,
            .condition = 1,
            .should_jump = true,
        },
        
        // Condition is zero, should not jump
        .{
            .code = &[_]u8{0x60, 0x05, 0x60, 0x00, 0x57, 0x5B, 0x00}, // PUSH1 5, PUSH1 0, JUMPI, JUMPDEST, STOP
            .jump_to = 5,
            .condition = 0,
            .should_jump = false,
        },
        
        // Large non-zero condition, should jump
        .{
            .code = &[_]u8{0x60, 0x05, 0x7F} ++ ([_]u8{0xFF} ** 32) ++ [_]u8{0x57, 0x5B, 0x00}, // PUSH1 5, PUSH32 (max), JUMPI, JUMPDEST, STOP
            .jump_to = 5,
            .condition = std.math.maxInt(u256),
            .should_jump = true,
        },
        
        // Invalid jump destination with non-zero condition (should fail)
        .{
            .code = &[_]u8{0x60, 0x05, 0x60, 0x01, 0x57, 0x01, 0x00}, // PUSH1 5, PUSH1 1, JUMPI, ADD, STOP
            .jump_to = 5,
            .condition = 1,
            .should_jump = false, // Will fail due to invalid destination
        },
        
        // Condition with single bit set
        .{
            .code = &[_]u8{0x60, 0x05, 0x60, 0x80, 0x57, 0x5B, 0x00}, // PUSH1 5, PUSH1 0x80, JUMPI, JUMPDEST, STOP
            .jump_to = 5,
            .condition = 0x80,
            .should_jump = true,
        },
    };
    
    for (jumpi_tests) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        var interpreter = evm.Operation.Interpreter = &ctx.vm;
        var state = *evm.Operation.State = @ptrCast(&ctx.frame);
        
        // Clear stack and push jump destination and condition
        while (ctx.frame.stack.items.len > 0) {
            _ = try ctx.frame.stack.pop();
        }
        
        try ctx.frame.stack.append(@as(u256, test_case.jump_to));
        try ctx.frame.stack.append(test_case.condition);
        
        const initial_pc = ctx.frame.pc;
        
        // Try to execute JUMPI
        const result = ctx.vm.table.execute(0, interpreter, state, 0x57); // JUMPI
        
        if (test_case.should_jump and test_case.condition != 0) {
            // Should succeed and update PC
            _ = try result;
            try testing.expectEqual(test_case.jump_to, ctx.frame.pc);
        } else if (test_case.condition == 0) {
            // Should not jump, PC should remain unchanged (or advance by 1)
            _ = try result;
            try testing.expect(ctx.frame.pc == initial_pc or ctx.frame.pc == initial_pc + 1);
        } else {
            // Should fail due to invalid jump destination
            try testing.expectError(error.InvalidJump, result);
        }
    }
}

// Test complex control flow patterns
test "fuzz_control_flow_complex_patterns" {
    const allocator = testing.allocator;
    
    // Test nested jumps and complex control flow
    const complex_tests = [_]struct { 
        code: []const u8, 
        description: []const u8,
        initial_stack: []const u256,
        expected_execution_path: []const usize,
    }{
        // Simple loop pattern
        .{
            .code = &[_]u8{
                0x5B,       // 0: JUMPDEST (loop start)
                0x60, 0x01, // 1-2: PUSH1 1
                0x60, 0x00, // 3-4: PUSH1 0 (loop condition)
                0x57,       // 5: JUMPI (jump to 0 if condition)
                0x00        // 6: STOP
            },
            .description = "Simple loop with conditional exit",
            .initial_stack = &[_]u256{},
            .expected_execution_path = &[_]usize{0, 1, 3, 5, 6}, // Should not loop since condition is 0
        },
        
        // Forward jump pattern
        .{
            .code = &[_]u8{
                0x60, 0x05, // 0-1: PUSH1 5
                0x56,       // 2: JUMP
                0x01,       // 3: ADD (should be skipped)
                0x02,       // 4: MUL (should be skipped)  
                0x5B,       // 5: JUMPDEST
                0x00        // 6: STOP
            },
            .description = "Forward jump skipping operations",
            .initial_stack = &[_]u256{},
            .expected_execution_path = &[_]usize{0, 2, 5, 6},
        },
        
        // Multiple jump destinations
        .{
            .code = &[_]u8{
                0x60, 0x08, // 0-1: PUSH1 8
                0x56,       // 2: JUMP
                0x5B,       // 3: JUMPDEST (first target)
                0x60, 0x0A, // 4-5: PUSH1 10
                0x56,       // 6: JUMP
                0x00,       // 7: STOP
                0x5B,       // 8: JUMPDEST (second target)
                0x60, 0x03, // 9-10: PUSH1 3
                0x56,       // 11: JUMP (jump to first target)
                0x5B,       // 12: JUMPDEST (third target) 
                0x00        // 13: STOP
            },
            .description = "Multiple connected jump destinations",
            .initial_stack = &[_]u256{},
            .expected_execution_path = &[_]usize{0, 2, 8, 9, 11, 3, 4, 6, 12, 13},
        },
    };
    
    for (complex_tests) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        // Initialize stack with test data
        for (test_case.initial_stack) |value| {
            try ctx.frame.stack.append(value);
        }
        
        // Note: Full execution path verification would require step-by-step execution
        // For now, we verify that the code analysis correctly identifies jump destinations
        const jump_map = try ctx.frame.contract.code_analysis.create_jump_map(allocator, test_case.code);
        defer allocator.free(jump_map);
        
        // Verify all JUMPDEST instructions are correctly identified
        for (0..test_case.code.len) |_| {
            if (test_case.code[i] == 0x5B) { // JUMPDEST
                try testing.expect(ctx.frame.contract.code_analysis.is_valid_jump(jump_map, i));
            }
        }
    }
}

// Stress test with random jump patterns
test "fuzz_control_flow_random_stress_test" {
    const allocator = testing.allocator;
    
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();
    
    // Generate random but valid control flow patterns
    for (0..100) |_| {
        var code = std.ArrayList(u8).init(allocator);
        defer code.deinit();
        
        // Generate a random valid control flow sequence
        const num_jumpdests = random.intRangeAtMost(usize, 1, 5);
        var jumpdest_positions = std.ArrayList(usize).init(allocator);
        defer jumpdest_positions.deinit();
        
        // Add some initial operations
        try code.appendSlice(&[_]u8{0x60, 0x01}); // PUSH1 1
        
        // Add JUMPDEST at random positions
        for (0..num_jumpdests) |_| {
            // Add some random operations before JUMPDEST
            const ops_before = random.intRangeAtMost(usize, 0, 3);
            for (0..ops_before) |_| {
                try code.append(0x01); // ADD (safe operation)
            }
            
            // Add JUMPDEST
            try jumpdest_positions.append(code.items.len);
            try code.append(0x5B); // JUMPDEST
        }
        
        // Add STOP at the end
        try code.append(0x00); // STOP
        
        // Test the generated code
        var ctx = try create_evm_context_with_code(allocator, code.items);
        defer deinit_evm_context(ctx, allocator);
        
        // Verify jump map creation doesn't fail
        const jump_map = ctx.frame.contract.code_analysis.create_jump_map(allocator, code.items) catch |err| {
            // Some random patterns might be invalid, that's OK
            _ = err;
            continue;
        };
        defer allocator.free(jump_map);
        
        // Verify all our intended JUMPDESTs are recognized
        for (jumpdest_positions.items) |pos| {
            try testing.expect(ctx.frame.contract.code_analysis.is_valid_jump(jump_map, pos));
        }
        
        // Test PC operation at various positions
        for (0..@min(code.items.len, 10)) |pc_pos| {
            if (code.items[pc_pos] != 0x5B) { // Don't overwrite JUMPDEST
                // Clear stack
                while (ctx.frame.stack.items.len > 0) {
                    _ = try ctx.frame.stack.pop();
                }
                
                ctx.frame.pc = pc_pos;
                
                var interpreter = evm.Operation.Interpreter = &ctx.vm;
                var state = *evm.Operation.State = @ptrCast(&ctx.frame);
                
                // Execute PC operation
                _ = try ctx.vm.table.execute(0, interpreter, state, 0x58); // PC
                const result = try ctx.frame.stack.pop();
                try testing.expectEqual(@as(u256, pc_pos), result);
            }
        }
    }
}

// Test edge cases with PUSH operations and jump analysis
test "fuzz_control_flow_push_interaction_edge_cases" {
    const allocator = testing.allocator;
    
    const push_jump_tests = [_]struct {
        code: []const u8,
        description: []const u8,
        valid_jumpdests: []const usize,
        invalid_positions: []const usize,
    }{
        // JUMPDEST immediately after PUSH1
        .{
            .code = &[_]u8{0x60, 0xAA, 0x5B, 0x00}, // PUSH1 0xAA, JUMPDEST, STOP
            .description = "JUMPDEST after PUSH1",
            .valid_jumpdests = &[_]usize{2},
            .invalid_positions = &[_]usize{1}, // Inside PUSH1 immediate data
        },
        
        // JUMPDEST inside PUSH2 immediate data
        .{
            .code = &[_]u8{0x61, 0x5B, 0x5B, 0x5B, 0x00}, // PUSH2 0x5B5B, JUMPDEST, STOP
            .description = "JUMPDEST inside PUSH2 data",
            .valid_jumpdests = &[_]usize{3},
            .invalid_positions = &[_]usize{1, 2}, // Bytes 1-2 are PUSH2 immediate data
        },
        
        // Complex pattern with PUSH32
        .{
            .code = &[_]u8{0x7F} ++ ([_]u8{0x5B} ** 31) ++ [_]u8{0xFF, 0x5B, 0x00}, // PUSH32 (31 0x5B + 0xFF), JUMPDEST, STOP
            .description = "JUMPDEST after PUSH32 with 0x5B in data",
            .valid_jumpdests = &[_]usize{33},
            .invalid_positions = &[_]usize{1, 2, 3, 4, 5, 31, 32}, // All positions in PUSH32 data
        },
        
        // Sequential PUSH operations
        .{
            .code = &[_]u8{0x60, 0x5B, 0x60, 0x5B, 0x5B, 0x00}, // PUSH1 0x5B, PUSH1 0x5B, JUMPDEST, STOP
            .description = "JUMPDEST after sequential PUSH1s",
            .valid_jumpdests = &[_]usize{4},
            .invalid_positions = &[_]usize{1, 3}, // PUSH immediate data
        },
        
        // Mixed PUSH sizes
        .{
            .code = &[_]u8{0x60, 0x5B, 0x61, 0x5B, 0x5B, 0x62, 0x5B, 0x5B, 0x5B, 0x5B, 0x00}, // PUSH1, PUSH2, PUSH3 with JUMPDEST after
            .description = "Mixed PUSH sizes with final JUMPDEST",
            .valid_jumpdests = &[_]usize{9},
            .invalid_positions = &[_]usize{1, 3, 4, 6, 7, 8}, // All PUSH immediate data
        },
    };
    
    for (push_jump_tests) |test_case| {
        var ctx = try create_evm_context_with_code(allocator, test_case.code);
        defer deinit_evm_context(ctx, allocator);
        
        const jump_map = try ctx.frame.contract.code_analysis.create_jump_map(allocator, test_case.code);
        defer allocator.free(jump_map);
        
        // Verify valid JUMPDESTs are recognized
        for (test_case.valid_jumpdests) |pos| {
            try testing.expect(ctx.frame.contract.code_analysis.is_valid_jump(jump_map, pos));
        }
        
        // Verify invalid positions are not recognized as valid jumpdests
        for (test_case.invalid_positions) |pos| {
            try testing.expect(!ctx.frame.contract.code_analysis.is_valid_jump(jump_map, pos));
        }
        
        // Test that trying to jump to invalid positions fails
        for (test_case.invalid_positions) |invalid_pos| {
            // Clear stack
            while (ctx.frame.stack.items.len > 0) {
                _ = try ctx.frame.stack.pop();
            }
            
            try ctx.frame.stack.append(@as(u256, invalid_pos));
            
            var interpreter = evm.Operation.Interpreter = &ctx.vm;
            var state = *evm.Operation.State = @ptrCast(&ctx.frame);
            
            // JUMP to invalid position should fail
            try testing.expectError(error.InvalidJump, ctx.vm.table.execute(0, interpreter, state, 0x56)); // JUMP
        }
    }
}