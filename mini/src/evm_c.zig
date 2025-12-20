/// C wrapper for Evm - minimal interface for WASM
const std = @import("std");
const evm = @import("evm.zig");
const Evm = evm.Evm;
const CallResult = evm.CallResult;
const StorageSlotKey = evm.StorageSlotKey;
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const ZERO_ADDRESS = primitives.ZERO_ADDRESS;

// Global allocator for C interface
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var allocator = gpa.allocator();

// Opaque handle for EVM instance
const EvmHandle = opaque {};

// Store execution context for later use
const ExecutionContext = struct {
    evm: *Evm,
    bytecode: []const u8,
    gas: i64,
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,
    result: ?CallResult,
};

/// Create a new Evm instance
/// log_level: 0=none, 1=err, 2=warn, 3=info, 4=debug
export fn evm_create(log_level: u8) ?*EvmHandle {
    const ctx = allocator.create(ExecutionContext) catch return null;

    const evm_ptr = allocator.create(Evm) catch {
        allocator.destroy(ctx);
        return null;
    };

    const log = @import("logger.zig");
    const log_level_enum: log.LogLevel = @enumFromInt(log_level);

    evm_ptr.* = Evm.init(allocator, null, null, null, log_level_enum) catch {
        allocator.destroy(evm_ptr);
        allocator.destroy(ctx);
        return null;
    };

    ctx.* = ExecutionContext{
        .evm = evm_ptr,
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
    value_bytes: [*]const u8, // 32 bytes representing u256
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

        ctx.evm.block_context = .{
            .chain_id = chain_id,
            .block_number = block_number,
            .block_timestamp = block_timestamp,
            .block_difficulty = 0,
            .block_prevrandao = 0,
            .block_coinbase = block_coinbase,
            .block_gas_limit = block_gas_limit,
            .block_base_fee = 0,
            .blob_base_fee = 0,
        };
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
    slot_bytes: [*]const u8, // 32 bytes
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
    slot_bytes: [*]const u8, // 32 bytes
    value_bytes: [*]u8, // 32 bytes output
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

        ctx.evm.balances.put(address, balance) catch return false;
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
        const code_copy = ctx.evm.allocator.alloc(u8, code_slice.len) catch return false;
        @memcpy(code_copy, code_slice);
        ctx.evm.code.put(address, code_copy) catch return false;
        return true;
    }
    return false;
}
