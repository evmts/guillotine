const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");

// Import interpret2 components
const interpret2 = evm.interpret2;
const SimpleAnalysis = evm.SimpleAnalysis;

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
        .block_boundaries = std.bit_set.DynamicBitSet.initEmpty(testing.allocator, 0) catch @panic("OOM"),
        .bucket_indices = &.{},
        .u16_bucket = &.{},
        .u32_bucket = &.{},
        .u64_bucket = &.{},
        .u256_bucket = &.{},
    };
    // No longer need metadata - using bucket system
    const empty_ops: []*const fn (*evm.Frame) evm.ExecutionError.Error!noreturn = &.{};
    
    var frame = try evm.Frame.init(
        1_000_000,                    // gas_remaining
        primitives.Address.ZERO_ADDRESS,  // contract_address
        empty_analysis,               // analysis
        empty_ops,                    // ops
        host,                         // host
        memory_db.to_database_interface(), // state
        allocator,                    // allocator
        false,                        // is_static
        primitives.Address.ZERO_ADDRESS,  // caller
        0,                            // value
        &.{},                         // input_buffer
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