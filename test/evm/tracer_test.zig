const std = @import("std");
const testing = std.testing;
const Evm = @import("evm");
const MemoryDatabase = @import("evm").MemoryDatabase;
const Address = @import("evm").primitives.Address;

// Test that we can create a tracer and capture execution traces
test "tracer captures opcode execution" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
    
    // Create a tracer that writes to a buffer
    var trace_buffer = std.ArrayList(u8).init(allocator);
    defer trace_buffer.deinit();
    
    // Enable tracing on the builder
    _ = builder.withTracer(trace_buffer.writer().any());
    
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Simple bytecode: PUSH1 0x05, PUSH1 0x03, ADD, STOP
    const bytecode = &[_]u8{
        0x60, 0x05,  // PUSH1 0x05
        0x60, 0x03,  // PUSH1 0x03
        0x01,        // ADD
        0x00,        // STOP
    };

    // Deploy the contract
    const create_result = try vm.create_contract(caller, 0, bytecode, 1000000);
    try testing.expect(create_result.success);

    // Parse the trace output
    const trace_output = trace_buffer.items;
    
    // Verify we have trace entries
    try testing.expect(trace_output.len > 0);
    
    // Debug print can be removed now that JSON is working
    
    // Parse JSON lines and verify structure
    var line_it = std.mem.tokenizeScalar(u8, trace_output, '\n');
    var found_push1 = false;
    var found_add = false;
    
    while (line_it.next()) |line| {
        const parsed = try std.json.parseFromSlice(TraceEntry, allocator, line, .{});
        defer parsed.deinit();
        
        const entry = parsed.value;
        
        // Check for PUSH1 at pc=0
        if (entry.pc == 0 and entry.op == 0x60) {
            found_push1 = true;
            try testing.expectEqual(@as(usize, 0), entry.stack.len);
        }
        
        // Check for ADD at pc=4
        if (entry.pc == 4 and entry.op == 0x01) {
            found_add = true;
            try testing.expectEqual(@as(usize, 2), entry.stack.len);
            try testing.expectEqualStrings("0x5", entry.stack[0]);
            try testing.expectEqualStrings("0x3", entry.stack[1]);
        }
    }
    
    try testing.expect(found_push1);
    try testing.expect(found_add);
}

// Test trace format matches REVM's format
test "trace format matches REVM JSON structure" {
    const allocator = testing.allocator;
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var builder = try Evm.Evm.init(allocator, db_interface, null, null, null, null);
    
    var trace_buffer = std.ArrayList(u8).init(allocator);
    defer trace_buffer.deinit();
    
    _ = builder.withTracer(trace_buffer.writer().any());
    
    var vm = try builder.build();
    defer vm.deinit();

    const caller = Address.from_u256(0x1000000000000000000000000000000000000001);
    try vm.state.set_balance(caller, std.math.maxInt(u256));

    // Single STOP instruction
    const bytecode = &[_]u8{0x00};

    const create_result = try vm.create_contract(caller, 0, bytecode, 1000000);
    // Parse first trace line
    var line_it = std.mem.tokenizeScalar(u8, trace_buffer.items, '\n');
    const first_line = line_it.next().?;
    
    const parsed = try std.json.parseFromSlice(TraceEntry, allocator, first_line, .{});
    defer parsed.deinit();
    
    const entry = parsed.value;
    
    // Verify all required fields are present
    try testing.expectEqual(@as(usize, 0), entry.pc);
    try testing.expectEqual(@as(u8, 0x00), entry.op);
    try testing.expect(entry.gas != null);
    try testing.expect(entry.gasCost != null);
    try testing.expect(entry.stack.len == 0);
    try testing.expect(entry.depth != null);
    try testing.expect(entry.opName != null);
}

// Trace entry structure matching REVM's format
const TraceEntry = struct {
    pc: usize,
    op: u8,
    gas: ?[]const u8 = null,
    gasCost: ?[]const u8 = null,
    stack: []const []const u8,  // Stack values as hex strings
    depth: ?u32 = null,
    returnData: ?[]const u8 = null,
    refund: ?[]const u8 = null,
    memSize: ?usize = null,
    opName: ?[]const u8 = null,
};