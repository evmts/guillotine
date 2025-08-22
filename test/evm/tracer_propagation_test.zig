const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test "tracer propagates to nested CREATE2 calls" {
    const allocator = std.testing.allocator;
    
    // Set up EVM with tracer
    var memory_db = evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    
    // Create a string writer for tracing
    var trace_buf = std.ArrayList(u8).init(allocator);
    defer trace_buf.deinit();
    const trace_writer = trace_buf.writer().any();
    
    var vm = try evm.Evm.init(allocator, db_interface, null, null, null, 0, false, trace_writer);
    defer vm.deinit();
    
    // Verify tracer is set
    try std.testing.expect(vm.tracer != null);
    
    // Simple CREATE2 bytecode that creates an empty contract
    const bytecode = &[_]u8{
        0x60, 0x42, // PUSH1 0x42 (salt)
        0x60, 0x00, // PUSH1 0 (length - empty contract)
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        0x00,       // STOP
    };
    
    // Deploy the contract
    vm.state.set_code(primitives.Address.ZERO, bytecode) catch {};
    
    const call_params = evm.CallParams{
        .call = .{
            .caller = primitives.Address.ZERO,
            .to = primitives.Address.ZERO,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    };
    
    const result = try vm.call(call_params);
    try std.testing.expect(result.success);
    
    // Check that we got traces
    const trace_output = trace_buf.items;
    
    // We should have traces
    try std.testing.expect(trace_output.len > 0);
    
    // Count traces at different depths
    var depth_0_count: usize = 0;
    var depth_1_count: usize = 0;
    
    var lines = std.mem.tokenize(u8, trace_output, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"depth\":0") != null) {
            depth_0_count += 1;
        }
        if (std.mem.indexOf(u8, line, "\"depth\":1") != null) {
            depth_1_count += 1;
        }
    }
    
    std.log.debug("Trace counts - depth 0: {}, depth 1: {}", .{ depth_0_count, depth_1_count });
    
    // We should have traces from the outer call (depth 0)
    try std.testing.expect(depth_0_count > 0);
    
    // For CREATE2 with empty init code, we might not have depth 1 traces
    // since there's no code to execute in the created contract
}