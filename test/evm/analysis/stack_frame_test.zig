const std = @import("std");
const StackFrame = @import("evm/stack_frame.zig").StackFrame;
const SimpleAnalysis = @import("evm/evm/analysis2.zig").SimpleAnalysis;
const primitives = @import("primitives");
const Host = @import("evm/host.zig");
const MemoryDatabase = @import("evm/state/memory_database.zig").MemoryDatabase;

test "StackFrame owns SimpleAnalysis and execution state" {
    const allocator = std.testing.allocator;
    
    // Create test bytecode
    const code = &[_]u8{ 0x60, 0x05, 0x60, 0x0A, 0x01, 0x00 }; // PUSH 5, PUSH 10, ADD, STOP
    
    // Analyze code and get block gas costs
    const result = try SimpleAnalysis.analyze(allocator, code);
    const analysis = result.analysis;
    const block_gas_costs = result.block_gas_costs;
    defer allocator.free(block_gas_costs);
    
    // Create ops array (simplified for test)
    const ops = try allocator.alloc(*const anyopaque, analysis.inst_count);
    @memset(ops, @ptrCast(&ops));
    
    // Create mock host and database
    var mock_host = Host.MockHost.init(allocator);
    defer mock_host.deinit();
    const host = mock_host.to_host();
    
    var db = try MemoryDatabase.init(allocator);
    defer db.deinit();
    
    // Create StackFrame that owns everything
    var frame = try StackFrame.init(
        1000000, // gas
        primitives.Address.ZERO_ADDRESS,
        analysis,
        ops,
        host,
        db.to_database_interface(),
        allocator,
    );
    defer frame.deinit(allocator);
    
    // Verify ownership
    try std.testing.expectEqual(@as(usize, 0), frame.ip);
    try std.testing.expectEqual(@as(u16, analysis.inst_count), frame.analysis.inst_count);
    try std.testing.expectEqual(ops.len, frame.ops.len);
    
    // Test that we can access analysis data directly
    const pc = frame.analysis.getPc(0);
    try std.testing.expectEqual(@as(u16, 0), pc);
}

test "StackFrame iteration safety check" {
    const allocator = std.testing.allocator;
    
    const code = &[_]u8{0x00}; // STOP
    const result = try SimpleAnalysis.analyze(allocator, code);
    const analysis = result.analysis;
    const metadata = result.metadata;
    
    const ops = try allocator.alloc(*const anyopaque, 1);
    @memset(ops, @ptrCast(&ops));
    
    var mock_host = Host.MockHost.init(allocator);
    defer mock_host.deinit();
    
    var db = try MemoryDatabase.init(allocator);
    defer db.deinit();
    
    var frame = try StackFrame.init(
        1000000,
        false,
        primitives.Address.ZERO_ADDRESS,
        primitives.Address.ZERO_ADDRESS,
        0,
        analysis,
        metadata,
        ops,
        mock_host.to_host(),
        db.to_database_interface(),
        allocator,
    );
    defer frame.deinit(allocator);
    
    // Check iteration safety works
    try frame.check_iteration_limit();
    try std.testing.expectEqual(@as(usize, 1), frame.tailcall_iterations);
}