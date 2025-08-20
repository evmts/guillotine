const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;
const SimpleAnalysis = evm.SimpleAnalysis;
const InstructionMetadata = evm.analysis2.InstructionMetadata;

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
    
    const empty_analysis = SimpleAnalysis{
        .inst_to_pc = &.{},
        .pc_to_inst = &.{},
        .bytecode = &code,
        .inst_count = 0,
    };
    const empty_metadata: []InstructionMetadata = &.{};
    const empty_ops: []*const anyopaque = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,
        primitives.Address.ZERO_ADDRESS,
        empty_analysis,
        empty_metadata,
        empty_ops,
        host,
        memory_db.to_database_interface(),
        allocator
    );
    defer frame.deinit(allocator);
    
    const result = interpret2.interpret2(&frame);
    try testing.expectError(evm.ExecutionError.Error.STOP, result);
    
    const stack_size = frame.stack.size();
    
    if (stack_size > 0) {
        const top = try frame.stack.pop();
        try testing.expectEqual(@as(u256, 30), top);
    } else {
        return error.StackEmpty;
    }
}