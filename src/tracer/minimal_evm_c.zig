/// C wrapper for MinimalEvm - minimal interface for WASM
const std = @import("std");
const minimal_evm = @import("minimal_evm.zig");
const MinimalEvm = minimal_evm.MinimalEvm;
const CallResult = minimal_evm.CallResult;
const StorageSlotKey = minimal_evm.StorageSlotKey;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

// Global allocator for C interface
// NOTE: Thread safety - WASM is single-threaded, but multiple create/destroy cycles
// need proper cleanup. Each EvmHandle owns its own allocations.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

/// Global cleanup - deinitializes the allocator and checks for leaks
/// Should be called when shutting down the WASM module
export fn evm_cleanup_global() bool {
    const status = gpa.deinit();
    return status == .ok;
}

// Opaque handle for EVM instance
const EvmHandle = opaque {};

// Store execution context for later use
const ExecutionContext = struct {
    evm: *MinimalEvm,
    bytecode: []const u8,
    gas: i64,
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,
    result: ?CallResult,
};

/// Create a new MinimalEvm instance
export fn evm_create() ?*EvmHandle {
    const ctx = allocator.create(ExecutionContext) catch return null;

    const evm = allocator.create(MinimalEvm) catch {
        allocator.destroy(ctx);
        return null;
    };

    evm.* = MinimalEvm.init(allocator) catch {
        allocator.destroy(evm);
        allocator.destroy(ctx);
        return null;
    };

    ctx.* = ExecutionContext{
        .evm = evm,
        .bytecode = &[_]u8{},
        .gas = 0,
        .caller = ZERO_ADDRESS,
        .address = ZERO_ADDRESS,
        .value = 0,
        .calldata = &[_]u8{},
        .result = null,
    };

    return @ptrCast(ctx);
}

/// Destroy an EVM instance
export fn evm_destroy(handle: ?*EvmHandle) void {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        // Free bytecode if allocated
        if (ctx.bytecode.len > 0 and ctx.bytecode.ptr != @as([*]const u8, @ptrCast(&[_]u8{}))) {
            allocator.free(ctx.bytecode);
        }

        // Free calldata if allocated
        if (ctx.calldata.len > 0 and ctx.calldata.ptr != @as([*]const u8, @ptrCast(&[_]u8{}))) {
            allocator.free(ctx.calldata);
        }

        ctx.evm.deinit();
        allocator.destroy(ctx.evm);
        allocator.destroy(ctx);
    }
}

/// Set bytecode for execution
export fn evm_set_bytecode(handle: ?*EvmHandle, bytecode: [*]const u8, bytecode_len: usize) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        // Allocate and copy bytecode
        const bytecode_copy = allocator.alloc(u8, bytecode_len) catch return false;
        @memcpy(bytecode_copy, bytecode[0..bytecode_len]);

        // Free old bytecode if any
        if (ctx.bytecode.len > 0) {
            allocator.free(ctx.bytecode);
        }

        ctx.bytecode = bytecode_copy;
        return true;
    }
    return false;
}

/// Set execution context
export fn evm_set_execution_context(
    handle: ?*EvmHandle,
    gas: i64,
    caller_bytes: [*]const u8,
    address_bytes: [*]const u8,
    value_bytes: [*]const u8,  // 32 bytes representing u256
    calldata: [*]const u8,
    calldata_len: usize,
) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        ctx.gas = gas;

        @memcpy(&ctx.caller.bytes, caller_bytes[0..20]);
        @memcpy(&ctx.address.bytes, address_bytes[0..20]);

        // Convert bytes to u256 (big-endian)
        var value: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            value = (value << 8) | value_bytes[i];
        }
        ctx.value = value;

        // Allocate and copy calldata
        if (calldata_len > 0) {
            const calldata_copy = allocator.alloc(u8, calldata_len) catch return false;
            @memcpy(calldata_copy, calldata[0..calldata_len]);

            // Free old calldata if any
            if (ctx.calldata.len > 0) {
                allocator.free(ctx.calldata);
            }

            ctx.calldata = calldata_copy;
        } else {
            ctx.calldata = &[_]u8{};
        }

        return true;
    }
    return false;
}

/// Set blockchain context
export fn evm_set_blockchain_context(
    handle: ?*EvmHandle,
    chain_id: u64,
    block_number: u64,
    block_timestamp: u64,
    block_coinbase_bytes: [*]const u8,
    block_gas_limit: u64,
) void {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        var block_coinbase: Address = undefined;
        @memcpy(&block_coinbase.bytes, block_coinbase_bytes[0..20]);

        ctx.evm.setBlockchainContext(
            chain_id,
            block_number,
            block_timestamp,
            0, // block_difficulty
            0, // block_prevrandao
            block_coinbase,
            block_gas_limit,
            0, // block_base_fee
            0, // blob_base_fee
        );
    }
}

/// Execute the EVM with current context
export fn evm_execute(handle: ?*EvmHandle) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        if (ctx.bytecode.len == 0) return false;

        const result = ctx.evm.execute(
            ctx.bytecode,
            ctx.gas,
            ctx.caller,
            ctx.address,
            ctx.value,
            ctx.calldata,
        ) catch return false;

        ctx.result = result;
        return result.success;
    }
    return false;
}

/// Get gas remaining after execution
export fn evm_get_gas_remaining(handle: ?*EvmHandle) i64 {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));
        if (ctx.result) |result| {
            return @intCast(result.gas_left);
        }
    }
    return 0;
}

/// Get gas used during execution
export fn evm_get_gas_used(handle: ?*EvmHandle) i64 {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));
        if (ctx.result) |result| {
            const gas_used = @as(i64, @intCast(ctx.gas)) - @as(i64, @intCast(result.gas_left));
            return gas_used;
        }
    }
    return 0;
}

/// Check if execution was successful
export fn evm_is_success(handle: ?*EvmHandle) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));
        if (ctx.result) |result| {
            return result.success;
        }
    }
    return false;
}

/// Get output data length
export fn evm_get_output_len(handle: ?*EvmHandle) usize {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));
        if (ctx.result) |result| {
            return result.output.len;
        }
    }
    return 0;
}

/// Copy output data to buffer
export fn evm_get_output(handle: ?*EvmHandle, buffer: [*]u8, buffer_len: usize) usize {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));
        if (ctx.result) |result| {
            const copy_len = @min(buffer_len, result.output.len);
            @memcpy(buffer[0..copy_len], result.output[0..copy_len]);
            return copy_len;
        }
    }
    return 0;
}

/// Set storage value for an address
export fn evm_set_storage(
    handle: ?*EvmHandle,
    address_bytes: [*]const u8,
    slot_bytes: [*]const u8,  // 32 bytes
    value_bytes: [*]const u8, // 32 bytes
) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        var address: Address = undefined;
        @memcpy(&address.bytes, address_bytes[0..20]);

        // Convert slot bytes to u256
        var slot: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            slot = (slot << 8) | slot_bytes[i];
        }

        // Convert value bytes to u256
        var value: u256 = 0;
        i = 0;
        while (i < 32) : (i += 1) {
            value = (value << 8) | value_bytes[i];
        }

        const key = StorageSlotKey{ .address = address, .slot = slot };
        ctx.evm.storage.put(key, value) catch return false;
        return true;
    }
    return false;
}

/// Get storage value for an address
export fn evm_get_storage(
    handle: ?*EvmHandle,
    address_bytes: [*]const u8,
    slot_bytes: [*]const u8,  // 32 bytes
    value_bytes: [*]u8,       // 32 bytes output
) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        var address: Address = undefined;
        @memcpy(&address.bytes, address_bytes[0..20]);

        // Convert slot bytes to u256
        var slot: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            slot = (slot << 8) | slot_bytes[i];
        }

        const key = StorageSlotKey{ .address = address, .slot = slot };
        const value = ctx.evm.storage.get(key) orelse 0;

        // Convert u256 to bytes (big-endian)
        i = 32;
        var temp_value = value;
        while (i > 0) : (i -= 1) {
            value_bytes[i - 1] = @truncate(temp_value & 0xFF);
            temp_value >>= 8;
        }

        return true;
    }
    return false;
}

/// Set account balance
export fn evm_set_balance(
    handle: ?*EvmHandle,
    address_bytes: [*]const u8,
    balance_bytes: [*]const u8, // 32 bytes
) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        var address: Address = undefined;
        @memcpy(&address.bytes, address_bytes[0..20]);

        // Convert balance bytes to u256
        var balance: u256 = 0;
        var i: usize = 0;
        while (i < 32) : (i += 1) {
            balance = (balance << 8) | balance_bytes[i];
        }

        ctx.evm.setBalance(address, balance) catch return false;
        return true;
    }
    return false;
}

/// Set account code
export fn evm_set_code(
    handle: ?*EvmHandle,
    address_bytes: [*]const u8,
    code: [*]const u8,
    code_len: usize,
) bool {
    if (handle) |h| {
        const ctx: *ExecutionContext = @ptrCast(@alignCast(h));

        var address: Address = undefined;
        @memcpy(&address.bytes, address_bytes[0..20]);

        const code_slice = if (code_len > 0) code[0..code_len] else &[_]u8{};
        ctx.evm.setCode(address, code_slice) catch return false;
        return true;
    }
    return false;
}

// ============================================================================
// Memory Safety Tests
// ============================================================================

test "minimal_evm_c: create and destroy without leaks" {
    const handle = evm_create();
    try std.testing.expect(handle != null);
    evm_destroy(handle);
}

test "minimal_evm_c: multiple create/destroy cycles" {
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const handle = evm_create();
        try std.testing.expect(handle != null);
        evm_destroy(handle);
    }
}

test "minimal_evm_c: bytecode allocation and cleanup" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1 PUSH1 2 ADD STOP
    const success = evm_set_bytecode(handle, &bytecode, bytecode.len);
    try std.testing.expect(success);
}

test "minimal_evm_c: multiple bytecode sets" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    // Set bytecode multiple times to test memory management
    const bytecode1 = [_]u8{ 0x60, 0x01, 0x00 };
    var success = evm_set_bytecode(handle, &bytecode1, bytecode1.len);
    try std.testing.expect(success);

    const bytecode2 = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    success = evm_set_bytecode(handle, &bytecode2, bytecode2.len);
    try std.testing.expect(success);

    const bytecode3 = [_]u8{ 0x60, 0x05, 0x60, 0x06, 0x02, 0x00 };
    success = evm_set_bytecode(handle, &bytecode3, bytecode3.len);
    try std.testing.expect(success);
}

test "minimal_evm_c: calldata allocation and cleanup" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;
    const calldata = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };

    const success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata,
        calldata.len,
    );
    try std.testing.expect(success);
}

test "minimal_evm_c: multiple calldata sets" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;

    // Set calldata multiple times
    const calldata1 = [_]u8{ 0xAA, 0xBB };
    var success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata1,
        calldata1.len,
    );
    try std.testing.expect(success);

    const calldata2 = [_]u8{ 0xCC, 0xDD, 0xEE, 0xFF };
    success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata2,
        calldata2.len,
    );
    try std.testing.expect(success);

    const calldata3 = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66 };
    success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata3,
        calldata3.len,
    );
    try std.testing.expect(success);
}

test "minimal_evm_c: empty calldata handling" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;

    // Set empty calldata
    const success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        undefined,
        0,
    );
    try std.testing.expect(success);
}

test "minimal_evm_c: large bytecode allocation" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    // Allocate 10KB bytecode
    var large_bytecode: [10000]u8 = undefined;
    for (&large_bytecode, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const success = evm_set_bytecode(handle, &large_bytecode, large_bytecode.len);
    try std.testing.expect(success);
}

test "minimal_evm_c: large calldata allocation" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;

    // Allocate 10KB calldata
    var large_calldata: [10000]u8 = undefined;
    for (&large_calldata, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }

    const success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &large_calldata,
        large_calldata.len,
    );
    try std.testing.expect(success);
}

test "minimal_evm_c: full execution cycle with memory cleanup" {
    const handle = evm_create();
    defer evm_destroy(handle);
    try std.testing.expect(handle != null);

    // Set bytecode (PUSH1 1 PUSH1 2 ADD STOP)
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 };
    var success = evm_set_bytecode(handle, &bytecode, bytecode.len);
    try std.testing.expect(success);

    // Set execution context
    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;
    const calldata = [_]u8{};
    success = evm_set_execution_context(
        handle,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata,
        0,
    );
    try std.testing.expect(success);

    // Set blockchain context
    evm_set_blockchain_context(
        handle,
        1, // chain_id
        100, // block_number
        1000000, // timestamp
        &ZERO_ADDRESS.bytes,
        30000000, // gas_limit
    );

    // Execute
    success = evm_execute(handle);
    try std.testing.expect(success);

    // Verify success
    const is_success = evm_is_success(handle);
    try std.testing.expect(is_success);
}

test "minimal_evm_c: null handle operations" {
    // All operations should safely handle null handles
    evm_destroy(null);

    const success = evm_set_bytecode(null, undefined, 0);
    try std.testing.expect(!success);

    const exec_success = evm_execute(null);
    try std.testing.expect(!exec_success);

    const gas = evm_get_gas_remaining(null);
    try std.testing.expect(gas == 0);

    const is_success = evm_is_success(null);
    try std.testing.expect(!is_success);

    const output_len = evm_get_output_len(null);
    try std.testing.expect(output_len == 0);
}

test "minimal_evm_c: interleaved operations stress test" {
    // Create multiple handles and perform interleaved operations
    const handle1 = evm_create();
    const handle2 = evm_create();
    const handle3 = evm_create();

    defer evm_destroy(handle1);
    defer evm_destroy(handle2);
    defer evm_destroy(handle3);

    try std.testing.expect(handle1 != null);
    try std.testing.expect(handle2 != null);
    try std.testing.expect(handle3 != null);

    // Set different bytecodes
    const bytecode1 = [_]u8{ 0x60, 0x01, 0x00 };
    const bytecode2 = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
    const bytecode3 = [_]u8{ 0x60, 0x05, 0x00 };

    var success = evm_set_bytecode(handle1, &bytecode1, bytecode1.len);
    try std.testing.expect(success);

    success = evm_set_bytecode(handle2, &bytecode2, bytecode2.len);
    try std.testing.expect(success);

    success = evm_set_bytecode(handle3, &bytecode3, bytecode3.len);
    try std.testing.expect(success);

    // Set different calldata
    const calldata1 = [_]u8{0x11};
    const calldata2 = [_]u8{ 0x22, 0x33 };
    const calldata3 = [_]u8{ 0x44, 0x55, 0x66 };

    const caller = ZERO_ADDRESS;
    const address = ZERO_ADDRESS;
    const value = [_]u8{0} ** 32;

    success = evm_set_execution_context(
        handle1,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata1,
        calldata1.len,
    );
    try std.testing.expect(success);

    success = evm_set_execution_context(
        handle2,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata2,
        calldata2.len,
    );
    try std.testing.expect(success);

    success = evm_set_execution_context(
        handle3,
        1000000,
        &caller.bytes,
        &address.bytes,
        &value,
        &calldata3,
        calldata3.len,
    );
    try std.testing.expect(success);
}