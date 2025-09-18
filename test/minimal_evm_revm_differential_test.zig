const std = @import("std");
const primitives = @import("primitives");
const evm_module = @import("evm");
const MinimalEvm = evm_module.tracer.MinimalEvm;

fn runTestCase(allocator: std.mem.Allocator, test_case: std.json.Value) !void {
    const log = std.log.scoped(.revm_differential);
    
    // Create MinimalEvm instance (use initPtr to avoid arena corruption)
    const evm = try MinimalEvm.initPtr(allocator);
    defer evm.deinitPtr(allocator);
    
    // Extract fields from JSON
    const tc = test_case.object;
    const name = tc.get("name").?.string;
    const bytecode_str = tc.get("bytecode").?.string;
    const calldata_str = tc.get("calldata").?.string;
    const value_str = tc.get("value").?.string;
    const gas_limit = @as(u64, @intCast(tc.get("gas_limit").?.integer));
    const caller_str = tc.get("caller").?.string;
    const contract_str = tc.get("contract").?.string;
    const initial_state = tc.get("initial_state").?.object;
    const expected = tc.get("expected").?.object;
    
    // Parse bytecode
    const bytecode = if (bytecode_str.len > 0) try primitives.Hex.hex_to_bytes(allocator, bytecode_str) else try allocator.alloc(u8, 0);
    defer allocator.free(bytecode);
    
    // Parse calldata
    const calldata = if (calldata_str.len > 0) try primitives.Hex.hex_to_bytes(allocator, calldata_str) else try allocator.alloc(u8, 0);
    defer allocator.free(calldata);
    
    // Parse addresses
    const caller_addr = try primitives.Address.fromHex(caller_str);
    const contract_addr = try primitives.Address.fromHex(contract_str);
    
    // Parse value
    const value = if (value_str.len > 0) try primitives.Hex.hex_to_u256(value_str) else 0;
    
    // Set up blockchain context
    const block_info = initial_state.get("block_info").?.object;
    const block_number = @as(u64, @intCast(block_info.get("number").?.integer));
    const block_timestamp = @as(u64, @intCast(block_info.get("timestamp").?.integer));
    const block_gas_limit = @as(u64, @intCast(block_info.get("gas_limit").?.integer));
    const difficulty_str = block_info.get("difficulty").?.string;
    const base_fee_str = block_info.get("base_fee").?.string;
    
    evm.setBlockchainContext(
        1, // chain_id
        block_number,
        block_timestamp,
        if (difficulty_str.len > 0) try primitives.Hex.hex_to_u256(difficulty_str) else 0,
        primitives.ZERO_ADDRESS, // coinbase
        block_gas_limit,
        if (base_fee_str.len > 0) try primitives.Hex.hex_to_u256(base_fee_str) else 0,
        0, // blob_base_fee
    );
    
    // Set transaction context
    evm.setTransactionContext(caller_addr, 1); // gas_price = 1
    
    // Set up initial accounts
    if (initial_state.get("accounts")) |accounts| {
        if (accounts == .object) {
            var it = accounts.object.iterator();
            while (it.next()) |entry| {
                const addr_str = entry.key_ptr.*;
                const account = entry.value_ptr.*;
                
                if (account == .object) {
                    const addr = try primitives.Address.fromHex(addr_str);
                    if (account.object.get("balance")) |balance_val| {
                        if (balance_val == .string) {
                            const balance = if (balance_val.string.len > 0) try primitives.Hex.hex_to_u256(balance_val.string) else 0;
                            try evm.setBalance(addr, balance);
                        }
                    }
                }
            }
        }
    }
    
    // Set up initial storage
    if (initial_state.get("storage")) |storage| {
        if (storage == .object) {
            var it = storage.object.iterator();
            while (it.next()) |entry| {
                const addr_str = entry.key_ptr.*;
                const addr_storage = entry.value_ptr.*;
                
                if (addr_storage == .object) {
                    const addr = try primitives.Address.fromHex(addr_str);
                    var storage_it = addr_storage.object.iterator();
                    while (storage_it.next()) |storage_entry| {
                        const slot_str = storage_entry.key_ptr.*;
                        const storage_value_str = storage_entry.value_ptr.*;
                        
                        if (storage_value_str == .string) {
                            const slot = if (slot_str.len > 0) try primitives.Hex.hex_to_u256(slot_str) else 0;
                            const storage_value = if (storage_value_str.string.len > 0) try primitives.Hex.hex_to_u256(storage_value_str.string) else 0;
                            try evm.set_storage(addr, slot, storage_value);
                        }
                    }
                }
            }
        }
    }
    
    // Set contract code
    try evm.setCode(contract_addr, bytecode);
    
    // Execute
    const result = try evm.execute(
        bytecode,
        @intCast(gas_limit),
        caller_addr,
        contract_addr,
        value,
        calldata,
    );
    
    // Compare results
    const gas_used = gas_limit - @as(u64, @intCast(result.gas_left));
    const expected_success = expected.get("success").?.bool;
    const expected_gas_used = @as(u64, @intCast(expected.get("gas_used").?.integer));
    const expected_output_str = expected.get("output").?.string;
    
    if (result.success != expected_success) {
        log.err("Test {s}: Success mismatch - MinimalEvm: {}, revm: {}", .{
            name,
            result.success,
            expected_success,
        });
        return error.SuccessMismatch;
    }
    
    if (gas_used != expected_gas_used) {
        log.err("Test {s}: Gas mismatch - MinimalEvm: {}, revm: {}", .{
            name,
            gas_used,
            expected_gas_used,
        });
        return error.GasMismatch;
    }
    
    // Compare output - handle both hex and string outputs
    const expected_output = if (std.mem.startsWith(u8, expected_output_str, "HALT:")) 
        expected_output_str  // Use as-is for HALT messages
    else 
        try primitives.Hex.hex_to_bytes(allocator, expected_output_str);  // Parse hex
    defer if (!std.mem.startsWith(u8, expected_output_str, "HALT:")) 
        allocator.free(expected_output);
    
    // For HALT messages, we can't compare exactly, just check if it failed
    if (std.mem.startsWith(u8, expected_output_str, "HALT:")) {
        // Just check that MinimalEvm also failed 
        if (result.success) {
            log.err("Test {s}: Expected failure (HALT) but MinimalEvm succeeded", .{name});
            return error.SuccessMismatch;
        }
        // Don't compare exact error messages, just that it failed
        log.info("Test {s}: PASSED (both failed as expected)", .{name});
        return;
    }
    
    if (!std.mem.eql(u8, result.output, expected_output)) {
        log.err("Test {s}: Output mismatch", .{name});
        // Print hex output for debugging  
        log.err("  MinimalEvm output length: {}", .{result.output.len});
        log.err("  revm output length: {}", .{expected_output.len});
        // Print first few bytes in hex for debugging
        if (result.output.len > 0) {
            const len = @min(result.output.len, 32);
            log.err("  MinimalEvm first {} bytes: {any}", .{ len, result.output[0..len] });
        }
        if (expected_output.len > 0) {
            const len = @min(expected_output.len, 32);
            log.err("  revm first {} bytes: {any}", .{ len, expected_output[0..len] });
        }
        return error.OutputMismatch;
    }
    
    log.info("Test {s}: PASSED", .{name});
}

test "MinimalEvm vs revm differential tests" {
    const allocator = std.testing.allocator;
    
    // Load test cases from JSON from test directory
    const json_file = try std.fs.cwd().openFile("test/minimal_evm_revm_differential_test.json", .{});
    defer json_file.close();
    
    const json_content = try json_file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
    defer allocator.free(json_content);
    
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_content, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    
    const test_cases = parsed.value.array.items;
    
    std.log.info("Running {} test cases against revm reference", .{test_cases.len});
    
    var passed: usize = 0;
    var failed: usize = 0;
    
    for (test_cases) |test_case| {
        const tc_name = test_case.object.get("name").?.string;
        runTestCase(allocator, test_case) catch |err| {
            std.log.err("Test {s} failed: {}", .{ tc_name, err });
            failed += 1;
            continue;
        };
        passed += 1;
    }
    
    std.log.info("Results: {} passed, {} failed", .{ passed, failed });
    
    if (failed > 0) {
        return error.TestsFailed;
    }
}