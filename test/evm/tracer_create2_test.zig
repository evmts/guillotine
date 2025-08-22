const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");

test "tracer passed to CREATE2 nested calls" {
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
    std.log.debug("Initial VM tracer: has_tracer={}, ptr=0x{x}", .{ vm.tracer != null, @intFromPtr(&vm) });
    
    // CREATE2 bytecode that creates a simple contract
    // This will push salt, size, offset, value onto stack then call CREATE2
    const init_code = [_]u8{
        // Constructor code that returns runtime code
        0x60, 0x0a, // PUSH1 10 (size of runtime code)
        0x60, 0x0c, // PUSH1 12 (offset in memory)
        0x60, 0x00, // PUSH1 0 (destination in memory)
        0x39,       // CODECOPY
        0x60, 0x0a, // PUSH1 10 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
        // Runtime code (10 bytes) - just returns 42
        0x60, 0x2a, // PUSH1 42
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    const deployer_code = [_]u8{
        // Store init code in memory
        0x7f, // PUSH32
    } ++ init_code[0..32] ++ [_]u8{
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20 - 32 + @as(u8, init_code.len), // PUSH1 remaining_size
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0x39,       // CODECOPY
        
        // CREATE2 params
        0x60, 0x42, // PUSH1 0x42 (salt)
        0x60, @as(u8, init_code.len), // PUSH1 size
        0x60, 0x00, // PUSH1 0 (offset)
        0x60, 0x00, // PUSH1 0 (value)
        0xf5,       // CREATE2
        
        // Return the created address
        0x60, 0x00, // PUSH1 0
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32
        0x60, 0x00, // PUSH1 0
        0xf3,       // RETURN
    };
    
    // Set up contract
    const caller = primitives.Address.ZERO;
    const call_params = evm.CallParams{
        .call = .{
            .caller = caller,
            .to = primitives.Address.ZERO,
            .value = 0,
            .input = &[_]u8{},
            .gas = 1000000,
        },
    };
    
    // Deploy the deployer contract
    vm.state.set_code(primitives.Address.ZERO, &deployer_code) catch {};
    
    const result = try vm.call(call_params);
    try std.testing.expect(result.success);
    
    // Check that we got traces
    const trace_output = trace_buf.items;
    std.log.debug("Trace output length: {}", .{trace_output.len});
    
    // We should have traces from both the outer call and the CREATE2 call
    try std.testing.expect(trace_output.len > 0);
    
    // Look for evidence of nested call tracing
    // We should see traces at depth 0 and depth 1
    var found_depth_0 = false;
    var found_depth_1 = false;
    
    var lines = std.mem.tokenize(u8, trace_output, "\n");
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"depth\":0") != null) {
            found_depth_0 = true;
        }
        if (std.mem.indexOf(u8, line, "\"depth\":1") != null) {
            found_depth_1 = true;
        }
    }
    
    std.log.debug("Found depth 0: {}, Found depth 1: {}", .{ found_depth_0, found_depth_1 });
    
    // We should have traces from both depths
    try std.testing.expect(found_depth_0);
    try std.testing.expect(found_depth_1);
}