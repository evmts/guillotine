const std = @import("std");
const testing = std.testing;

// External C FFI declarations
extern fn guillotine_init() void;
extern fn guillotine_cleanup() void;
extern fn guillotine_evm_create(block_info_ptr: *const BlockInfoFFI) ?*anyopaque;
extern fn guillotine_evm_create_tracing(block_info_ptr: *const BlockInfoFFI) ?*anyopaque;
extern fn guillotine_evm_destroy(handle: *anyopaque) void;
extern fn guillotine_evm_destroy_tracing(handle: *anyopaque) void;
extern fn guillotine_set_code(handle: *anyopaque, address: *const [20]u8, code: [*]const u8, code_len: usize) bool;
extern fn guillotine_set_code_tracing(handle: *anyopaque, address: *const [20]u8, code: [*]const u8, code_len: usize) bool;
extern fn guillotine_call(handle: *anyopaque, params: *const CallParams) ?*EvmResult;
extern fn guillotine_call_tracing(handle: *anyopaque, params: *const CallParams) ?*EvmResult;
extern fn guillotine_free_result(result: ?*EvmResult) void;
extern fn guillotine_simulate(handle: *anyopaque, params: *const CallParams) ?*EvmResult;

// FFI type definitions
const BlockInfoFFI = extern struct {
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    coinbase: [20]u8,
    base_fee: u64,
    chain_id: u64,
    difficulty: u64,
    prev_randao: [32]u8,
};

const CallParams = extern struct {
    caller: [20]u8,
    bytecode_address: [20]u8,
    value: [32]u8,
    input_ptr: [*]const u8,
    input_len: usize,
    gas_limit: u64,
    call_type: CallType,
    is_static: bool,
    salt: [32]u8,
};

const CallType = enum(u8) {
    Call = 0,
    Create = 1,
    Create2 = 2,
};

const EvmResult = extern struct {
    success: bool,
    output: [*]u8,
    output_len: usize,
    gas_used: u64,
    execution_error: ?[*:0]const u8,
    create_address: ?*const [20]u8,
    logs_json: ?[*:0]const u8,
    trace_json: ?[*:0]const u8,
};

// Test the C FFI API tracing functionality
test "C FFI API - create tracing EVM and verify trace JSON output" {
    const allocator = testing.allocator;
    
    // Initialize FFI
    guillotine_init();
    defer guillotine_cleanup();
    
    // Create block info
    const block_info = BlockInfoFFI{
        .number = 100,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    
    // Create tracing EVM instance
    const handle = guillotine_evm_create_tracing(&block_info);
    try testing.expect(handle != null);
    defer if (handle) |h| guillotine_evm_destroy_tracing(h);
    
    // Set up contract with simple bytecode: PUSH1 3, PUSH1 2, ADD, STOP
    const bytecode = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x02,  // PUSH1 2
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const contract_addr = @as([20]u8, @splat(0x01));
    const success = guillotine_set_code_tracing(handle.?, &contract_addr, &bytecode, bytecode.len);
    try testing.expect(success);
    
    // Prepare call parameters
    const caller = @as([20]u8, @splat(0));
    const value = @as([32]u8, @splat(0)); // 0 value
    const empty_input = [_]u8{};
    const salt = @as([32]u8, @splat(0));
    
    const params = CallParams{
        .caller = caller,
        .bytecode_address = contract_addr,
        .value = value,
        .input_ptr = &empty_input,
        .input_len = 0,
        .gas_limit = 100_000,
        .call_type = CallType.Call,
        .is_static = false,
        .salt = salt,
    };
    
    // Execute call with tracing
    const result = guillotine_call_tracing(handle.?, &params);
    try testing.expect(result != null);
    defer if (result) |r| guillotine_free_result(r);
    
    // Verify execution succeeded
    try testing.expect(result.?.success);
    try testing.expect(result.?.gas_used > 0); // Some gas was consumed
    
    // Verify trace JSON was generated
    try testing.expect(result.?.trace_json != null);
    
    // Parse and validate trace JSON
    if (result.?.trace_json == null) {
        std.debug.print("ERROR: trace_json is null\n", .{});
        return error.NoTraceJSON;
    }
    const trace_json = std.mem.span(result.?.trace_json.?);
    
    // Basic JSON structure validation
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"structLogs\"") != null);
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"pc\"") != null);
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\"") != null);
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"gas\"") != null);
    
    // Verify we see the expected opcodes in trace
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\":\"PUSH1\"") != null);
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\":\"ADD\"") != null);
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\":\"STOP\"") != null);
    
    // Parse JSON for more detailed validation
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trace_json, .{}) catch |err| {
        std.debug.print("Failed to parse trace JSON: {s}\n", .{trace_json});
        return err;
    };
    defer parsed.deinit();
    
    // Access structLogs array
    const struct_logs = parsed.value.object.get("structLogs").?.array;
    
    // We expect 4 steps: PUSH1, PUSH1, ADD, STOP
    try testing.expectEqual(@as(usize, 4), struct_logs.items.len);
    
    // Validate first step (PUSH1 3)
    const step0 = struct_logs.items[0].object;
    try testing.expectEqual(@as(i64, 0), step0.get("pc").?.integer);
    try testing.expectEqualStrings("PUSH1", step0.get("op").?.string);
    
    // Validate second step (PUSH1 2) 
    const step1 = struct_logs.items[1].object;
    try testing.expectEqual(@as(i64, 2), step1.get("pc").?.integer);
    try testing.expectEqualStrings("PUSH1", step1.get("op").?.string);
    
    // Validate third step (ADD)
    const step2 = struct_logs.items[2].object;
    try testing.expectEqual(@as(i64, 4), step2.get("pc").?.integer);
    try testing.expectEqualStrings("ADD", step2.get("op").?.string);
    
    // Validate fourth step (STOP)
    const step3 = struct_logs.items[3].object;
    try testing.expectEqual(@as(i64, 5), step3.get("pc").?.integer);
    try testing.expectEqualStrings("STOP", step3.get("op").?.string);
    
    // Validate stack evolution
    const stack0 = step0.get("stack").?.array;
    const stack1 = step1.get("stack").?.array;
    const stack2 = step2.get("stack").?.array;
    const stack3 = step3.get("stack").?.array;
    
    try testing.expectEqual(@as(usize, 0), stack0.items.len); // Empty before first PUSH
    try testing.expectEqual(@as(usize, 1), stack1.items.len); // [3] after first PUSH
    try testing.expectEqual(@as(usize, 2), stack2.items.len); // [3, 2] after second PUSH
    try testing.expectEqual(@as(usize, 1), stack3.items.len); // [5] after ADD
}

test "C FFI API - tracing captures REVERT with trace" {
    const allocator = testing.allocator;
    
    // Initialize FFI
    guillotine_init();
    defer guillotine_cleanup();
    
    // Create block info
    const block_info = BlockInfoFFI{
        .number = 100,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    
    // Create tracing EVM instance
    const handle = guillotine_evm_create_tracing(&block_info);
    try testing.expect(handle != null);
    defer if (handle) |h| guillotine_evm_destroy_tracing(h);
    
    // Bytecode that stores "FAIL" and reverts
    const bytecode = [_]u8{
        0x63, 0x46, 0x41, 0x49, 0x4C,  // PUSH4 "FAIL"
        0x60, 0x00,                      // PUSH1 0
        0x52,                            // MSTORE
        0x60, 0x04,                      // PUSH1 4 (size)
        0x60, 0x1C,                      // PUSH1 28 (offset)
        0xfd,                            // REVERT
    };
    
    const contract_addr = @as([20]u8, @splat(0x02));
    const success = guillotine_set_code_tracing(handle.?, &contract_addr, &bytecode, bytecode.len);
    try testing.expect(success);
    
    // Prepare call parameters
    const caller = @as([20]u8, @splat(0));
    const value = @as([32]u8, @splat(0)); // 0 value
    const empty_input = [_]u8{};
    const salt = @as([32]u8, @splat(0));
    
    const params = CallParams{
        .caller = caller,
        .bytecode_address = contract_addr,
        .value = value,
        .input_ptr = &empty_input,
        .input_len = 0,
        .gas_limit = 100_000,
        .call_type = CallType.Call,
        .is_static = false,
        .salt = salt,
    };
    
    // Execute call with tracing
    const result = guillotine_call_tracing(handle.?, &params);
    try testing.expect(result != null);
    defer if (result) |r| guillotine_free_result(r);
    
    // Verify execution failed (REVERT)
    try testing.expect(!result.?.success);
    
    // Verify output contains "FAIL"
    try testing.expect(result.?.output_len >= 4);
    const output = result.?.output[result.?.output_len - 4..result.?.output_len];
    try testing.expectEqualSlices(u8, "FAIL", output);
    
    // CRITICAL: Verify trace JSON was still generated even on revert
    try testing.expect(result.?.trace_json != null);
    
    if (result.?.trace_json == null) {
        std.debug.print("ERROR: trace_json is null\n", .{});
        return error.NoTraceJSON;
    }
    const trace_json = std.mem.span(result.?.trace_json.?);
    
    // Verify we see REVERT opcode in trace
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\":\"REVERT\"") != null);
    
    // Parse and validate trace
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trace_json, .{}) catch |err| {
        std.debug.print("Failed to parse trace JSON: {s}\n", .{trace_json});
        return err;
    };
    defer parsed.deinit();
    
    const struct_logs = parsed.value.object.get("structLogs").?.array;
    
    // Find REVERT step
    var found_revert = false;
    for (struct_logs.items) |item| {
        const op = item.object.get("op").?.string;
        if (std.mem.eql(u8, op, "REVERT")) {
            found_revert = true;
            break;
        }
    }
    try testing.expect(found_revert);
}

test "C FFI API - tracing captures CREATE operation" {
    const allocator = testing.allocator;
    
    // Initialize FFI
    guillotine_init();
    defer guillotine_cleanup();
    
    // Create block info
    const block_info = BlockInfoFFI{
        .number = 100,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    
    // Create tracing EVM instance
    const handle = guillotine_evm_create_tracing(&block_info);
    try testing.expect(handle != null);
    defer if (handle) |h| guillotine_evm_destroy_tracing(h);
    
    // Simple init code that returns empty (creates empty contract)
    const init_code = [_]u8{
        0x60, 0x00,  // PUSH1 0 (size)
        0x60, 0x00,  // PUSH1 0 (offset)
        0xf3,        // RETURN
    };
    
    // Prepare CREATE parameters
    const caller = @as([20]u8, @splat(0x03));
    const to = @as([20]u8, @splat(0)); // CREATE doesn't use 'to'
    const value = @as([32]u8, @splat(0)); // 0 value
    const salt = @as([32]u8, @splat(0));
    
    const params = CallParams{
        .caller = caller,
        .bytecode_address = to,
        .value = value,
        .input_ptr = &init_code,
        .input_len = init_code.len,
        .gas_limit = 100_000,
        .call_type = CallType.Create,
        .is_static = false,
        .salt = salt,
    };
    
    // Execute CREATE with tracing
    const result = guillotine_call_tracing(handle.?, &params);
    try testing.expect(result != null);
    defer if (result) |r| guillotine_free_result(r);
    
    // Verify CREATE succeeded
    try testing.expect(result.?.success);
    
    // Verify created address is populated
    try testing.expect(result.?.create_address != null);
    
    // Verify trace JSON was generated
    try testing.expect(result.?.trace_json != null);
    
    if (result.?.trace_json == null) {
        std.debug.print("ERROR: trace_json is null\n", .{});
        return error.NoTraceJSON;
    }
    const trace_json = std.mem.span(result.?.trace_json.?);
    
    // Verify we see RETURN opcode in trace (from init code)
    try testing.expect(std.mem.indexOf(u8, trace_json, "\"op\":\"RETURN\"") != null);
    
    // Parse and validate
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trace_json, .{}) catch |err| {
        std.debug.print("Failed to parse trace JSON: {s}\n", .{trace_json});
        return err;
    };
    defer parsed.deinit();
    
    const struct_logs = parsed.value.object.get("structLogs").?.array;
    try testing.expect(struct_logs.items.len > 0);
    
    // Find RETURN step
    var found_return = false;
    for (struct_logs.items) |item| {
        const op = item.object.get("op").?.string;
        if (std.mem.eql(u8, op, "RETURN")) {
            found_return = true;
            break;
        }
    }
    try testing.expect(found_return);
}

test "C FFI API - non-tracing EVM returns no trace" {
    // Initialize FFI
    guillotine_init();
    defer guillotine_cleanup();
    
    // Create block info
    const block_info = BlockInfoFFI{
        .number = 100,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    
    // Create regular (non-tracing) EVM instance
    const handle = guillotine_evm_create(&block_info);
    try testing.expect(handle != null);
    defer if (handle) |h| guillotine_evm_destroy(h);
    
    // Set up simple contract
    const bytecode = [_]u8{
        0x60, 0x03,  // PUSH1 3
        0x60, 0x02,  // PUSH1 2
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const contract_addr = @as([20]u8, @splat(0x04));
    const success = guillotine_set_code(handle.?, &contract_addr, &bytecode, bytecode.len);
    try testing.expect(success);
    
    // Prepare call parameters
    const caller = @as([20]u8, @splat(0));
    const value = @as([32]u8, @splat(0));
    const empty_input = [_]u8{};
    const salt = @as([32]u8, @splat(0));
    
    const params = CallParams{
        .caller = caller,
        .bytecode_address = contract_addr,
        .value = value,
        .input_ptr = &empty_input,
        .input_len = 0,
        .gas_limit = 100_000,
        .call_type = CallType.Call,
        .is_static = false,
        .salt = salt,
    };
    
    // Execute call WITHOUT tracing
    const result = guillotine_call(handle.?, &params);
    try testing.expect(result != null);
    defer if (result) |r| guillotine_free_result(r);
    
    // Verify execution succeeded
    try testing.expect(result.?.success);
    
    // Verify NO trace JSON was generated
    try testing.expect(result.?.trace_json == null);
}

test "C FFI API - tracing handles complex stack operations" {
    const allocator = testing.allocator;
    
    // Initialize FFI
    guillotine_init();
    defer guillotine_cleanup();
    
    // Create block info
    const block_info = BlockInfoFFI{
        .number = 100,
        .timestamp = 1000,
        .gas_limit = 30_000_000,
        .coinbase = @as([20]u8, @splat(0)),
        .base_fee = 0,
        .chain_id = 1,
        .difficulty = 0,
        .prev_randao = @as([32]u8, @splat(0)),
    };
    
    // Create tracing EVM instance
    const handle = guillotine_evm_create_tracing(&block_info);
    try testing.expect(handle != null);
    defer if (handle) |h| guillotine_evm_destroy_tracing(h);
    
    // Complex bytecode with DUP, SWAP operations
    const bytecode = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x03,  // PUSH1 3
        0x80,        // DUP1 (duplicate top item)
        0x90,        // SWAP1 (swap top two items)
        0x01,        // ADD
        0x00,        // STOP
    };
    
    const contract_addr = @as([20]u8, @splat(0x05));
    const success = guillotine_set_code_tracing(handle.?, &contract_addr, &bytecode, bytecode.len);
    try testing.expect(success);
    
    // Prepare call parameters
    const caller = @as([20]u8, @splat(0));
    const value = @as([32]u8, @splat(0));
    const empty_input = [_]u8{};
    const salt = @as([32]u8, @splat(0));
    
    const params = CallParams{
        .caller = caller,
        .bytecode_address = contract_addr,
        .value = value,
        .input_ptr = &empty_input,
        .input_len = 0,
        .gas_limit = 100_000,
        .call_type = CallType.Call,
        .is_static = false,
        .salt = salt,
    };
    
    // Execute call with tracing
    const result = guillotine_call_tracing(handle.?, &params);
    try testing.expect(result != null);
    defer if (result) |r| guillotine_free_result(r);
    
    // Verify execution succeeded
    try testing.expect(result.?.success);
    
    // Parse trace JSON
    if (result.?.trace_json == null) {
        std.debug.print("ERROR: trace_json is null\n", .{});
        return error.NoTraceJSON;
    }
    const trace_json = std.mem.span(result.?.trace_json.?);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trace_json, .{}) catch |err| {
        std.debug.print("Failed to parse trace JSON: {s}\n", .{trace_json});
        return err;
    };
    defer parsed.deinit();
    
    const struct_logs = parsed.value.object.get("structLogs").?.array;
    
    // Verify we see DUP and SWAP operations
    var found_dup = false;
    var found_swap = false;
    
    for (struct_logs.items) |item| {
        const op = item.object.get("op").?.string;
        if (std.mem.eql(u8, op, "DUP1")) found_dup = true;
        if (std.mem.eql(u8, op, "SWAP1")) found_swap = true;
    }
    
    try testing.expect(found_dup);
    try testing.expect(found_swap);
    
    // Validate stack evolution through DUP and SWAP
    // After PUSH1 5: [5]
    // After PUSH1 3: [5, 3]  
    // After DUP1: [5, 3, 3]
    // After SWAP1: [5, 3, 3] -> [5, 3, 3] (swap top two)
    // After ADD: [5, 6]
    
    // Find the DUP1 step and verify stack
    for (struct_logs.items, 0..) |item, i| {
        const op = item.object.get("op").?.string;
        if (std.mem.eql(u8, op, "DUP1")) {
            // Stack before DUP should have [5, 3]
            const stack = item.object.get("stack").?.array;
            try testing.expectEqual(@as(usize, 2), stack.items.len);
            
            // Next step should show duplicated item
            if (i + 1 < struct_logs.items.len) {
                const next_stack = struct_logs.items[i + 1].object.get("stack").?.array;
                try testing.expectEqual(@as(usize, 3), next_stack.items.len);
            }
            break;
        }
    }
}