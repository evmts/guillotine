const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Test static jump resolution in the dispatch system
test "static jump resolution works with forward jumps" {
    const allocator = testing.allocator;
    
    // Import required modules
    const bytecode_mod = evm.bytecode;
    const dispatch_mod = evm.dispatch;
    const frame_handlers = evm.frame_handlers;
    
    // Test configuration for Frame type
    const TestConfig = evm.FrameConfig{
        .stack_size = 1024,
        .WordType = u256,
        .max_bytecode_size = 1024,
        .block_gas_limit = 30_000_000,
        .DatabaseType = evm.Database,
        .TracerType = evm.NoOpTracer,
        .memory_initial_capacity = 4096,
        .memory_limit = 0xFFFFFF,
    };
    
    const TestFrame = evm.Frame(TestConfig);
    const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = 1024, .fusions_enabled = true });
    const TestDispatch = dispatch_mod.Dispatch(TestFrame);
    
    // Create bytecode with forward jump that should be fused
    // [PUSH 0x05] [JUMP] [STOP] [STOP] [JUMPDEST] [STOP]
    const code = [_]u8{ 0x60, 0x05, 0x56, 0x00, 0x00, 0x5b, 0x00 };
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();
    
    // Get opcode handlers
    const handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    
    // Initialize dispatch - this should detect the PUSH+JUMP fusion and resolve the forward jump
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);
    
    // Create jump table
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);
    
    // Verify that the jump table has the JUMPDEST at PC 5
    const jump_target = jump_table.findJumpTarget(5);
    try testing.expect(jump_target != null);
    
    // Look for static jump metadata in dispatch items
    // The fusion should have created a jump_to_static_location handler with resolved jump_static metadata
    var found_static_jump = false;
    for (dispatch_items, 0..) |_, i| {
        if (i + 1 < dispatch_items.len) {
            switch (dispatch_items[i + 1]) {
                .jump_static => |metadata| {
                    // The dispatch pointer should be resolved (not undefined/null)
                    const ptr = @intFromPtr(metadata.dispatch);
                    try testing.expect(ptr != 0);
                    found_static_jump = true;
                    
                    // Verify it points to a valid location in our dispatch
                    const target_dispatch = @as([*]const TestDispatch.Item, @ptrCast(@alignCast(metadata.dispatch)));
                    // The target should be within our dispatch items array
                    const target_index = (@intFromPtr(target_dispatch) - @intFromPtr(dispatch_items.ptr)) / @sizeOf(TestDispatch.Item);
                    try testing.expect(target_index < dispatch_items.len);
                },
                else => {},
            }
        }
    }
    
    // We should have found and resolved at least one static jump
    try testing.expect(found_static_jump);
}

test "static jumpi resolution for conditional forward jumps" {
    const allocator = testing.allocator;
    
    const bytecode_mod = evm.bytecode;
    const dispatch_mod = evm.dispatch;
    const frame_handlers = evm.frame_handlers;
    
    const TestConfig = evm.FrameConfig{
        .stack_size = 1024,
        .WordType = u256,
        .max_bytecode_size = 1024,
        .block_gas_limit = 30_000_000,
        .DatabaseType = evm.Database,
        .TracerType = evm.NoOpTracer,
        .memory_initial_capacity = 4096,
        .memory_limit = 0xFFFFFF,
    };
    
    const TestFrame = evm.Frame(TestConfig);
    const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = 1024, .fusions_enabled = true });
    const TestDispatch = dispatch_mod.Dispatch(TestFrame);
    
    // Create bytecode with PUSH+JUMPI fusion
    // [PUSH 0x05] [JUMPI] [STOP] [STOP] [JUMPDEST] [STOP]
    const code = [_]u8{ 0x60, 0x05, 0x57, 0x00, 0x00, 0x5b, 0x00 };
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();
    
    const handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);
    
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);
    
    // Verify JUMPDEST exists at PC 5
    try testing.expect(jump_table.findJumpTarget(5) != null);
    
    // Look for static jumpi metadata
    var found_static_jumpi = false;
    for (dispatch_items, 0..) |_, i| {
        if (i + 1 < dispatch_items.len) {
            switch (dispatch_items[i + 1]) {
                .jump_static => |metadata| {
                    const ptr = @intFromPtr(metadata.dispatch);
                    try testing.expect(ptr != 0);
                    found_static_jumpi = true;
                },
                else => {},
            }
        }
    }
    
    try testing.expect(found_static_jumpi);
}

test "multiple forward jumps are all resolved" {
    const allocator = testing.allocator;
    
    const bytecode_mod = evm.bytecode;
    const dispatch_mod = evm.dispatch;
    const frame_handlers = evm.frame_handlers;
    
    const TestConfig = evm.FrameConfig{
        .stack_size = 1024,
        .WordType = u256,
        .max_bytecode_size = 1024,
        .block_gas_limit = 30_000_000,
        .DatabaseType = evm.Database,
        .TracerType = evm.NoOpTracer,
        .memory_initial_capacity = 4096,
        .memory_limit = 0xFFFFFF,
    };
    
    const TestFrame = evm.Frame(TestConfig);
    const TestBytecode = bytecode_mod.Bytecode(.{ .max_bytecode_size = 1024, .fusions_enabled = true });
    const TestDispatch = dispatch_mod.Dispatch(TestFrame);
    
    // Complex bytecode with multiple forward jumps
    // [PUSH 0x08] [JUMP] ... [JUMPDEST] [PUSH 0x11] [JUMP] ... [JUMPDEST] [STOP]
    const code = [_]u8{ 
        0x60, 0x08,  // PUSH1 0x08 (PC 0-1)
        0x56,        // JUMP (PC 2)
        0x00, 0x00, 0x00, 0x00, 0x00,  // Padding (PC 3-7)
        0x5b,        // JUMPDEST at PC 0x08
        0x60, 0x11,  // PUSH1 0x11 (PC 9-10)
        0x56,        // JUMP (PC 11)
        0x00, 0x00, 0x00, 0x00, 0x00,  // Padding (PC 12-16)
        0x5b,        // JUMPDEST at PC 0x11 (17)
        0x00,        // STOP
    };
    
    var bytecode = try TestBytecode.init(allocator, &code);
    defer bytecode.deinit();
    
    const handlers = frame_handlers.getOpcodeHandlers(TestFrame);
    const dispatch_items = try TestDispatch.init(allocator, &bytecode, &handlers);
    defer allocator.free(dispatch_items);
    
    const jump_table = try TestDispatch.createJumpTable(allocator, dispatch_items, &bytecode);
    defer allocator.free(jump_table.entries);
    
    // Both jump destinations should exist
    try testing.expect(jump_table.findJumpTarget(0x08) != null);
    try testing.expect(jump_table.findJumpTarget(0x11) != null);
    
    // Count resolved static jumps
    var static_jump_count: usize = 0;
    for (dispatch_items, 0..) |_, i| {
        if (i + 1 < dispatch_items.len) {
            switch (dispatch_items[i + 1]) {
                .jump_static => |metadata| {
                    const ptr = @intFromPtr(metadata.dispatch);
                    if (ptr != 0) {
                        static_jump_count += 1;
                    }
                },
                else => {},
            }
        }
    }
    
    // Should have resolved both static jumps
    try testing.expect(static_jump_count >= 2);
}