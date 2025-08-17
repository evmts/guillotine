const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const Address = primitives.Address;
const revm_wrapper = @import("revm");
const trace_utils = @import("trace_utils.zig");

// This test runs the failing STATICCALL test with tracing enabled to help debug the issue
test "STATICCALL opcode with tracing - debug differential failure" {
    testing.log_level = .warn;
    const allocator = testing.allocator;

    // Create trace directory
    try std.fs.cwd().makePath("staticcall_debug_traces");

    // Contract D bytecode: performs multiple STATICCALLs and stores results
    const contract_d_staticcall_bytecode = [_]u8{
        // STATICCALL to contract A (should fail due to SSTORE)
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x73, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, // PUSH20 contract A address
        0x61, 0x10, 0x00, // PUSH2 4096 (gas)
        0xfa, // STATICCALL
        0x60, 0x00, // PUSH1 0 (memory offset to store result)
        0x52, // MSTORE (store call success/failure)

        // STATICCALL to contract B (should fail due to LOG0)
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x73, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, 0x44, // PUSH20 contract B address
        0x61, 0x10, 0x00, // PUSH2 4096 (gas)
        0xfa, // STATICCALL
        0x60, 0x20, // PUSH1 32 (memory offset to store result)
        0x52, // MSTORE

        // STATICCALL to contract C (should succeed - read-only ops)
        0x60, 0x20, // PUSH1 32 (return data size)
        0x60, 0x00, // PUSH1 0 (return data offset)
        0x60, 0x00, // PUSH1 0 (args size)
        0x60, 0x00, // PUSH1 0 (args offset)
        0x73, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, // PUSH20 contract C address
        0x61, 0x10, 0x00, // PUSH2 4096 (gas)
        0xfa, // STATICCALL
        0x60, 0x40, // PUSH1 64 (memory offset to store result)
        0x52, // MSTORE

        // Return all three results
        0x60, 0x60, // PUSH1 96 (size - 3 u256 values)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Contract A bytecode: attempts SSTORE (state modification)
    const contract_a_sstore_bytecode = [_]u8{
        0x60, 0x42, // PUSH1 0x42 (value)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x55, // SSTORE - this should fail in STATICCALL
        0x60, 0x01, // PUSH1 1 (return success)
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Contract C bytecode: read-only operations (SLOAD, BALANCE, etc)
    const contract_c_readonly_bytecode = [_]u8{
        // SLOAD (read storage)
        0x60, 0x01, // PUSH1 0x01 (key)
        0x54, // SLOAD
        0x50, // POP

        // BALANCE (read balance)
        0x30, // ADDRESS
        0x31, // BALANCE
        0x50, // POP

        // Store 0x99 (153 decimal) in memory and return it
        0x60, 0x99, // PUSH1 0x99
        0x60, 0x00, // PUSH1 0 (memory offset)
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32 (size)
        0x60, 0x00, // PUSH1 0 (offset)
        0xf3, // RETURN
    };

    // Setup REVM with tracing
    const revm_settings = revm_wrapper.RevmSettings{};
    var revm_vm = try revm_wrapper.Revm.init(allocator, revm_settings);
    defer revm_vm.deinit();

    const contract_a_address = Address.from_u256(0x3333333333333333333333333333333333333333);
    const contract_c_address = Address.from_u256(0x5555555555555555555555555555555555555555);
    const contract_d_address = Address.from_u256(0x2222222222222222222222222222222222222222);

    // Deploy contracts to REVM
    try revm_vm.setCode(contract_a_address, &contract_a_sstore_bytecode);
    try revm_vm.setCode(contract_c_address, &contract_c_readonly_bytecode);
    try revm_vm.setCode(contract_d_address, &contract_d_staticcall_bytecode);
    try revm_vm.setBalance(contract_c_address, 1000);

    // Execute with tracing
    const revm_trace_path = "staticcall_debug_traces/staticcall_revm.json";
    var revm_result = try revm_vm.callWithTrace(
        Address.from_u256(0x1111111111111111111111111111111111111111),
        contract_d_address,
        0,
        &[_]u8{},
        2000000,
        revm_trace_path,
    );
    defer revm_result.deinit();

    // Setup Guillotine with tracing
    var trace_config = trace_utils.TraceConfig{
        .enable_always = true,
        .output_dir = "staticcall_debug_traces",
        .allocator = allocator,
    };

    var guillotine_trace = try trace_utils.initTestTracing(&trace_config, "staticcall", "guillotine");
    defer if (guillotine_trace) |*gt| gt.deinit();

    var memory_db = try evm.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.to_database_interface();
    var vm = try trace_utils.createTracedEvm(allocator, db_interface, guillotine_trace);
    defer vm.deinit();

    // Deploy contracts to Guillotine
    try vm.state.set_code(contract_a_address, &contract_a_sstore_bytecode);
    try vm.state.set_code(contract_c_address, &contract_c_readonly_bytecode);
    try vm.state.set_code(contract_d_address, &contract_d_staticcall_bytecode);
    try vm.state.set_balance(contract_c_address, 1000);

    const call_params = evm.CallParams{ .call = .{
        .caller = Address.from_u256(0x1111111111111111111111111111111111111111),
        .to = contract_d_address,
        .value = 0,
        .input = &[_]u8{},
        .gas = 2000000,
    } };

    const guillotine_result = try vm.call(call_params);
    // VM owns guillotine_result.output; do not free here

    // Print results for debugging
    std.debug.print("\n=== STATICCALL Debug Results ===\n", .{});
    std.debug.print("REVM success: {}, output len: {}\n", .{ revm_result.success, revm_result.output.len });
    std.debug.print("Guillotine success: {}, output len: {}\n", .{ guillotine_result.success, if (guillotine_result.output) |o| o.len else 0 });

    if (revm_result.success and revm_result.output.len >= 96) {
        const revm_call_a = std.mem.readInt(u256, revm_result.output[0..32], .big);
        const revm_call_b = std.mem.readInt(u256, revm_result.output[32..64], .big);
        const revm_call_c = std.mem.readInt(u256, revm_result.output[64..96], .big);
        std.debug.print("REVM results: A={}, B={}, C={}\n", .{ revm_call_a, revm_call_b, revm_call_c });
    }

    if (guillotine_result.success and guillotine_result.output != null and guillotine_result.output.?.len >= 96) {
        const guillotine_call_a = std.mem.readInt(u256, guillotine_result.output.?[0..32], .big);
        const guillotine_call_b = std.mem.readInt(u256, guillotine_result.output.?[32..64], .big);
        const guillotine_call_c = std.mem.readInt(u256, guillotine_result.output.?[64..96], .big);
        std.debug.print("Guillotine results: A={}, B={}, C={}\n", .{ guillotine_call_a, guillotine_call_b, guillotine_call_c });
    }

    std.debug.print("\n=== Traces saved ===\n", .{});
    std.debug.print("REVM trace: {s}\n", .{revm_trace_path});
    std.debug.print("Guillotine trace: staticcall_debug_traces/staticcall_guillotine_*.json\n", .{});
    std.debug.print("\nRun the following to compare traces:\n", .{});
    std.debug.print("diff -u {s} staticcall_debug_traces/staticcall_guillotine_*.json | head -100\n", .{revm_trace_path});
}
