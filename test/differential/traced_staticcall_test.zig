const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const trace_utils = @import("trace_utils.zig");

// This is a standalone test that demonstrates how to trace the STATICCALL execution
// to debug the differential test failure

test "traced STATICCALL execution" {
    const allocator = testing.allocator;
    
    // Create trace config
    var trace_config = trace_utils.TraceConfig{
        .enable_always = true,
        .output_dir = "staticcall_traces",
        .allocator = allocator,
    };
    
    // Initialize trace collector for Guillotine
    var guillotine_trace = try trace_utils.initTestTracing(&trace_config, "staticcall", "guillotine");
    defer if (guillotine_trace) |*gt| gt.deinit();
    
    // Simple STATICCALL test bytecode that stores a value and then tries to read it
    // This is a minimal reproduction of the issue
    const test_bytecode = [_]u8{
        // Store 0x99 in memory at offset 0
        0x60, 0x99, // PUSH1 0x99
        0x60, 0x00, // PUSH1 0x00
        0x52,       // MSTORE
        
        // Prepare STATICCALL parameters
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x73, // PUSH20 (address follows)
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
        0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, // target address
        0x61, 0x10, 0x00, // PUSH2 0x1000 (gas)
        0xfa, // STATICCALL
        
        // The result (0 or 1) is now on the stack
        // Store it at memory offset 0x20
        0x60, 0x20, // PUSH1 0x20
        0x52,       // MSTORE
        
        // Return both values (original 0x99 and STATICCALL result)
        0x60, 0x40, // PUSH1 64 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3,       // RETURN
    };
    
    // Target contract that tries to do SSTORE (should fail in STATICCALL)
    const target_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42
        0x60, 0x01, // PUSH1 0x01
        0x55,       // SSTORE - this should cause STATICCALL to fail
        0x00,       // STOP
    };
    
    // Setup Guillotine with tracing
    var memory_db = try evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.to_database_interface();
    var vm = try trace_utils.createTracedEvm(allocator, db_interface, guillotine_trace);
    defer vm.deinit();
    
    // Deploy contracts
    const main_address = Address.from_u256(0x1111111111111111111111111111111111111111);
    const target_address = Address.from_u256(0x2222222222222222222222222222222222222222);
    
    try vm.state.set_code(main_address, &test_bytecode);
    try vm.state.set_code(target_address, &target_bytecode);
    
    // Execute the main contract
    const call_params = evm.CallParams{ .call = .{
        .caller = Address.from_u256(0x0),
        .to = main_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 100000,
    } };
    
    std.debug.print("\n=== Executing STATICCALL test with tracing ===\n", .{});
    const result = try vm.call(call_params);
    defer if (result.output) |output| allocator.free(output);
    
    // Print results
    std.debug.print("Execution success: {}\n", .{result.success});
    std.debug.print("Gas used: {}\n", .{call_params.call.gas - result.gas_left});
    
    if (result.output) |output| {
        std.debug.print("Output length: {} bytes\n", .{output.len});
        if (output.len >= 32) {
            const first_value = std.mem.readInt(u256, output[0..32], .big);
            std.debug.print("First 32 bytes (original value): 0x{x}\n", .{first_value});
            
            if (output.len >= 64) {
                const second_value = std.mem.readInt(u256, output[32..64], .big);
                std.debug.print("Second 32 bytes (STATICCALL result): 0x{x}\n", .{second_value});
            }
        }
    }
    
    std.debug.print("\nTrace saved to: {s}/staticcall_guillotine_{d}.json\n", .{ trace_config.output_dir, std.time.timestamp() });
    std.debug.print("You can compare this trace with REVM's trace to find the divergence point.\n", .{});
}