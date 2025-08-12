const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");
const trace_utils = @import("trace_utils.zig");

// Test demonstrating how to use tracing with both REVM and Guillotine
test "differential test with tracing - ADD opcode" {
    const allocator = testing.allocator;
    
    // Create trace directory
    try std.fs.cwd().makePath("differential_traces");
    
    // Simple ADD bytecode: PUSH1 5, PUSH1 10, ADD, RETURN
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x0A, // PUSH1 10
        0x01,       // ADD
        0x60, 0x00, // PUSH1 0 (offset)
        0x52,       // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    // Execute on REVM with tracing
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();
    
    const contract_address = try Address.from_hex("0x2222222222222222222222222222222222222222");
    const caller = try Address.from_hex("0x1111111111111111111111111111111111111111");
    
    try revm_vm.setBalance(caller, 10000000);
    try revm_vm.setCode(contract_address, &bytecode);
    
    const revm_trace_path = "differential_traces/add_revm.json";
    var revm_result = try revm_vm.callWithTrace(
        caller,
        contract_address,
        0,
        &[_]u8{},
        1000000,
        revm_trace_path,
    );
    defer revm_result.deinit();
    
    // Execute on Guillotine with tracing
    var trace_config = trace_utils.TraceConfig{
        .enable_always = true,
        .output_dir = "differential_traces",
        .allocator = allocator,
    };
    
    var guillotine_trace = try trace_utils.initTestTracing(&trace_config, "add", "guillotine");
    defer if (guillotine_trace) |*gt| gt.deinit();
    
    var memory_db = try evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try trace_utils.createTracedEvm(allocator, db_interface, guillotine_trace);
    defer vm.deinit();
    
    try vm.state.set_code(contract_address, &bytecode);
    
    const call_params = evm.CallParams{ .call = .{
        .caller = caller,
        .to = contract_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 1000000,
    } };
    
    const guillotine_result = try vm.call(call_params);
    defer if (guillotine_result.output) |output| allocator.free(output);
    
    // Compare results
    try testing.expect(revm_result.success == guillotine_result.success);
    
    if (revm_result.success and guillotine_result.success) {
        try testing.expect(revm_result.output.len == 32);
        try testing.expect(guillotine_result.output != null);
        try testing.expect(guillotine_result.output.?.len == 32);
        
        const revm_value = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const guillotine_value = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);
        
        try testing.expectEqual(@as(u256, 15), revm_value);
        try testing.expectEqual(@as(u256, 15), guillotine_value);
    }
    
    std.debug.print("\n=== Differential test with tracing complete ===\n", .{});
    std.debug.print("REVM trace: {s}\n", .{revm_trace_path});
    std.debug.print("Guillotine trace: differential_traces/add_guillotine_*.json\n", .{});
    std.debug.print("You can now compare the traces to see step-by-step execution.\n", .{});
}