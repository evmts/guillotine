const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;

test "interpret2_simple: basic MUL" {
    const allocator = testing.allocator;
    
    const code = [_]u8{ 
        0x60, 0x03,  // PUSH1 3
        0x60, 0x0A,  // PUSH1 10
        0x02,        // MUL
        0x00,        // STOP
    };
    
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    var mock_host = evm.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    const metadata = evm.OpcodeMetadata.init();
    var analysis = try evm.CodeAnalysis.from_code(allocator, &code, &metadata);
    defer analysis.deinit();
    
    var frame = try evm.Frame.init(
        1_000_000,
        false,
        0,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        &analysis,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame, &code);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    const stack_size = frame.stack.size();
    std.debug.print("\nStack size after MUL: {}\n", .{stack_size});
    
    if (stack_size > 0) {
        const top = try frame.stack.pop();
        std.debug.print("Result of 3 * 10: {}\n", .{top});
        try testing.expectEqual(@as(u256, 30), top);
    } else {
        return error.StackEmpty;
    }
}