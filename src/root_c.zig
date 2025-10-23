//! C API for Guillotine EVM
//! Provides a simple, ergonomic C-compatible interface

const std = @import("std");
const root = @import("root.zig");
const primitives = @import("primitives");

// The C API expects the user to pass in build time flags
const config = root.EvmConfig.fromBuildOptions();
const Evm = root.Evm(config);
const Database = @import("storage/database.zig").Database;
const BlockInfoNative = @import("block/block_info.zig").BlockInfo(.{});
const TransactionContextNative = @import("block/transaction_context.zig").TransactionContext;

// ============================================================================
// C-Compatible Types
// ============================================================================

/// C-compatible address (20 bytes)
pub const CAddress = extern struct {
    bytes: [20]u8,
};

/// C-compatible u256 (32 bytes, little-endian)
pub const CU256 = extern struct {
    bytes: [32]u8,
};

/// C-compatible block info structure
pub const CBlockInfo = extern struct {
    chain_id: u64,
    number: u64,
    parent_hash: [32]u8,
    timestamp: u64,
    difficulty: u64,
    gas_limit: u64,
    coinbase: CAddress,
    base_fee: u64,
    prev_randao: [32]u8,
    blob_base_fee: u64,
    // Note: beacon_root is optional, handle separately if needed
};

/// C-compatible transaction context
pub const CTransactionContext = extern struct {
    gas_limit: u64,
    coinbase: CAddress,
    chain_id: u16,
    blob_base_fee: CU256,
};

/// C-compatible execution result
pub const CExecutionResult = extern struct {
    success: bool,
    gas_used: u64,
    gas_refunded: u64,
    output_ptr: [*]const u8,
    output_len: usize,
    error_message: [*:0]const u8,
};

// ============================================================================
// Global State Management
// ============================================================================

const CApiState = struct {
    const Self = @This();

    var singleton: ?*Self = null;
    var init_mutex: std.Thread.Mutex = .{};

    allocator: std.mem.Allocator,
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    last_error: [512]u8 = undefined,
    last_error_len: usize = 0,
    // Keep track of allocated results for cleanup
    last_result_output: ?[]const u8 = null,

    fn get_or_init() !*Self {
        init_mutex.lock();
        defer init_mutex.unlock();

        if (singleton) |state| {
            return state;
        }

        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        const state = try allocator.create(Self);
        state.* = Self{
            .allocator = allocator,
            .gpa = gpa,
            .last_error = undefined,
            .last_error_len = 0,
            .last_result_output = null,
        };

        singleton = state;
        return state;
    }

    fn set_error(self: *Self, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.bufPrint(&self.last_error, fmt, args) catch {
            @memcpy(self.last_error[0.."Error formatting error message".len], "Error formatting error message");
            self.last_error_len = "Error formatting error message".len;
            return;
        };
        self.last_error_len = msg.len;
    }
};

// ============================================================================
// Initialization & Cleanup
// ============================================================================

/// Initialize the C API (must be called before any other functions)
/// Returns 0 on success, -1 on failure
export fn guillotine_init() c_int {
    _ = CApiState.get_or_init() catch return -1;
    return 0;
}

/// Get the last error message
/// Returns a null-terminated string, valid until next API call
export fn guillotine_get_last_error() [*:0]const u8 {
    const state = CApiState.get_or_init() catch return "";
    if (state.last_error_len == 0) return "";
    state.last_error[state.last_error_len] = 0;
    return @ptrCast(&state.last_error);
}

// ============================================================================
// Database Management
// ============================================================================

/// Opaque database handle
pub const DatabaseHandle = opaque {};

/// Create a new in-memory database
/// Returns null on failure
export fn database_create() ?*DatabaseHandle {
    const state = CApiState.get_or_init() catch return null;

    const db = state.allocator.create(Database) catch {
        state.set_error("Failed to allocate database", .{});
        return null;
    };

    db.* = Database.init(state.allocator) catch {
        state.allocator.destroy(db);
        state.set_error("Failed to initialize database", .{});
        return null;
    };

    return @ptrCast(db);
}

/// Destroy a database and free its resources
export fn database_destroy(handle: ?*DatabaseHandle) void {
    if (handle == null) return;
    const state = CApiState.get_or_init() catch return;

    const db: *Database = @ptrCast(@alignCast(handle));
    db.deinit();
    state.allocator.destroy(db);
}

/// Set account balance in the database
/// Returns 0 on success, -1 on failure
export fn database_set_balance(handle: ?*DatabaseHandle, address: *const CAddress, balance: *const CU256) c_int {
    if (handle == null) return -1;
    const state = CApiState.get_or_init() catch return -1;

    const db: *Database = @ptrCast(@alignCast(handle));
    const addr = primitives.Address{ .bytes = address.bytes };
    const bal = std.mem.readInt(u256, &balance.bytes, .little);

    db.setBalance(addr, bal) catch {
        state.set_error("Failed to set balance", .{});
        return -1;
    };

    return 0;
}

/// Set account code in the database
/// Returns 0 on success, -1 on failure
export fn database_set_code(handle: ?*DatabaseHandle, address: *const CAddress, code: [*]const u8, code_len: usize) c_int {
    if (handle == null) return -1;
    const state = CApiState.get_or_init() catch return -1;

    const db: *Database = @ptrCast(@alignCast(handle));
    const addr = primitives.Address{ .bytes = address.bytes };
    const code_slice = code[0..code_len];

    db.setCode(addr, code_slice) catch {
        state.set_error("Failed to set code", .{});
        return -1;
    };

    return 0;
}

/// Set account nonce in the database
/// Returns 0 on success, -1 on failure
export fn database_set_nonce(handle: ?*DatabaseHandle, address: *const CAddress, nonce: u64) c_int {
    if (handle == null) return -1;
    const state = CApiState.get_or_init() catch return -1;

    const db: *Database = @ptrCast(@alignCast(handle));
    const addr = primitives.Address{ .bytes = address.bytes };

    db.setNonce(addr, nonce) catch {
        state.set_error("Failed to set nonce", .{});
        return -1;
    };

    return 0;
}

/// Set storage slot in the database
/// Returns 0 on success, -1 on failure
export fn database_set_storage(handle: ?*DatabaseHandle, address: *const CAddress, slot: *const CU256, value: *const CU256) c_int {
    if (handle == null) return -1;
    const state = CApiState.get_or_init() catch return -1;

    const db: *Database = @ptrCast(@alignCast(handle));
    const addr = primitives.Address{ .bytes = address.bytes };
    const slot_val = std.mem.readInt(u256, &slot.bytes, .little);
    const storage_val = std.mem.readInt(u256, &value.bytes, .little);

    db.setStorage(addr, slot_val, storage_val) catch {
        state.set_error("Failed to set storage", .{});
        return -1;
    };

    return 0;
}

// ============================================================================
// EVM Management
// ============================================================================

/// Opaque EVM handle
pub const EvmHandle = opaque {};

/// Create a new EVM instance
/// All parameters are required except database (if null, an internal one is created)
/// Returns null on failure
export fn evm_create(
    database: ?*DatabaseHandle,
    block_info: *const CBlockInfo,
    transaction_context: *const CTransactionContext,
    gas_price: *const CU256,
    origin: *const CAddress,
) ?*EvmHandle {
    const state = CApiState.get_or_init() catch return null;

    // Convert C types to Zig types
    const native_block_info = BlockInfoNative{
        .chain_id = block_info.chain_id,
        .number = block_info.number,
        .parent_hash = block_info.parent_hash,
        .timestamp = block_info.timestamp,
        .difficulty = block_info.difficulty,
        .gas_limit = block_info.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info.coinbase.bytes },
        .base_fee = block_info.base_fee,
        .prev_randao = block_info.prev_randao,
        .blob_base_fee = block_info.blob_base_fee,
    };

    const native_tx_context = TransactionContextNative{
        .gas_limit = transaction_context.gas_limit,
        .coinbase = primitives.Address{ .bytes = transaction_context.coinbase.bytes },
        .chain_id = transaction_context.chain_id,
        .blob_base_fee = std.mem.readInt(u256, &transaction_context.blob_base_fee.bytes, .little),
    };

    const native_gas_price = std.mem.readInt(u256, &gas_price.bytes, .little);
    const native_origin = primitives.Address{ .bytes = origin.bytes };

    // Get or create database
    const db_ptr: *Database = if (database) |db_handle|
        @ptrCast(@alignCast(db_handle))
    else blk: {
        const new_db = state.allocator.create(Database) catch {
            state.set_error("Failed to allocate database", .{});
            return null;
        };
        new_db.* = Database.init(state.allocator) catch {
            state.allocator.destroy(new_db);
            state.set_error("Failed to initialize database", .{});
            return null;
        };
        break :blk new_db;
    };

    // Create EVM
    const evm_ptr = state.allocator.create(Evm) catch {
        state.set_error("Failed to allocate EVM", .{});
        return null;
    };

    evm_ptr.* = Evm.init(
        state.allocator,
        db_ptr,
        native_block_info,
        native_tx_context,
        native_gas_price,
        native_origin,
    ) catch |err| {
        state.allocator.destroy(evm_ptr);
        state.set_error("Failed to initialize EVM: {any}", .{err});
        return null;
    };

    return @ptrCast(evm_ptr);
}

/// Execute a transaction (CALL)
/// Returns execution result (valid until next evm_transact call or evm_destroy)
export fn evm_transact(
    handle: ?*EvmHandle,
    caller: *const CAddress,
    to: *const CAddress,
    value: *const CU256,
    data: [*]const u8,
    data_len: usize,
    gas_limit: u64,
) ?*const CExecutionResult {
    if (handle == null) return null;
    const state = CApiState.get_or_init() catch return null;

    const evm: *Evm = @ptrCast(@alignCast(handle));

    const native_caller = primitives.Address{ .bytes = caller.bytes };
    const native_to = primitives.Address{ .bytes = to.bytes };
    const native_value = std.mem.readInt(u256, &value.bytes, .little);
    const input_data = data[0..data_len];

    // Clean up previous result
    if (state.last_result_output) |old_output| {
        state.allocator.free(old_output);
        state.last_result_output = null;
    }

    const call_params = Evm.CallParams{
        .caller = native_caller,
        .to = native_to,
        .value = native_value,
        .input = input_data,
        .gas_limit = gas_limit,
        .is_static = false,
    };

    const result = evm.call(call_params) catch |err| {
        state.set_error("EVM call failed: {any}", .{err});
        return null;
    };

    // Allocate result structure
    const c_result = state.allocator.create(CExecutionResult) catch return null;

    // Copy output data
    const output_copy = state.allocator.dupe(u8, result.output) catch {
        state.allocator.destroy(c_result);
        return null;
    };
    state.last_result_output = output_copy;

    const error_msg = if (result.reverted) "Execution reverted" else "";

    c_result.* = CExecutionResult{
        .success = !result.reverted and result.success,
        .gas_used = result.gas_used,
        .gas_refunded = result.gas_refunded,
        .output_ptr = output_copy.ptr,
        .output_len = output_copy.len,
        .error_message = error_msg.ptr,
    };

    return c_result;
}

/// Execute a contract creation (CREATE)
/// Returns execution result (valid until next evm_transact call or evm_destroy)
export fn evm_create_contract(
    handle: ?*EvmHandle,
    caller: *const CAddress,
    value: *const CU256,
    init_code: [*]const u8,
    init_code_len: usize,
    gas_limit: u64,
) ?*const CExecutionResult {
    if (handle == null) return null;
    const state = CApiState.get_or_init() catch return null;

    const evm: *Evm = @ptrCast(@alignCast(handle));

    const native_caller = primitives.Address{ .bytes = caller.bytes };
    const native_value = std.mem.readInt(u256, &value.bytes, .little);
    const init_code_slice = init_code[0..init_code_len];

    // Clean up previous result
    if (state.last_result_output) |old_output| {
        state.allocator.free(old_output);
        state.last_result_output = null;
    }

    const create_params = Evm.CallParams{
        .caller = native_caller,
        .to = primitives.ZERO_ADDRESS, // CREATE uses zero address
        .value = native_value,
        .input = init_code_slice,
        .gas_limit = gas_limit,
        .is_static = false,
    };

    const result = evm.create(create_params) catch |err| {
        state.set_error("EVM create failed: {any}", .{err});
        return null;
    };

    // Allocate result structure
    const c_result = state.allocator.create(CExecutionResult) catch return null;

    // Copy output data (created contract address)
    const output_copy = state.allocator.dupe(u8, result.output) catch {
        state.allocator.destroy(c_result);
        return null;
    };
    state.last_result_output = output_copy;

    const error_msg = if (result.reverted) "Contract creation reverted" else "";

    c_result.* = CExecutionResult{
        .success = !result.reverted and result.success,
        .gas_used = result.gas_used,
        .gas_refunded = result.gas_refunded,
        .output_ptr = output_copy.ptr,
        .output_len = output_copy.len,
        .error_message = error_msg.ptr,
    };

    return c_result;
}

/// Destroy an EVM instance and free its resources
export fn evm_destroy(handle: ?*EvmHandle) void {
    if (handle == null) return;
    const state = CApiState.get_or_init() catch return;

    const evm: *Evm = @ptrCast(@alignCast(handle));
    evm.deinit();
    state.allocator.destroy(evm);

    // Clean up any remaining result output
    if (state.last_result_output) |output| {
        state.allocator.free(output);
        state.last_result_output = null;
    }
}

/// Cleanup global state (call at program exit)
export fn guillotine_cleanup() void {
    CApiState.init_mutex.lock();
    defer CApiState.init_mutex.unlock();

    if (CApiState.singleton) |state| {
        if (state.last_result_output) |output| {
            state.allocator.free(output);
        }
        const allocator = state.allocator;
        _ = state.gpa.deinit();
        allocator.destroy(state);
        CApiState.singleton = null;
    }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Helper to create a default block info structure
export fn block_info_create_default() CBlockInfo {
    return CBlockInfo{
        .chain_id = 1,
        .number = 0,
        .parent_hash = [_]u8{0} ** 32,
        .timestamp = 0,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = CAddress{ .bytes = [_]u8{0} ** 20 },
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
    };
}

/// Helper to create a default transaction context
export fn transaction_context_create_default() CTransactionContext {
    return CTransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = CAddress{ .bytes = [_]u8{0} ** 20 },
        .chain_id = 1,
        .blob_base_fee = CU256{ .bytes = [_]u8{0} ** 32 },
    };
}

/// Helper to convert a hex string to an address
/// Returns 0 on success, -1 on failure
export fn address_from_hex(hex: [*:0]const u8, out: *CAddress) c_int {
    const hex_str = std.mem.span(hex);

    // Remove "0x" prefix if present
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    if (clean_hex.len != 40) return -1;

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        out.bytes[i] = std.fmt.parseInt(u8, clean_hex[i * 2 .. i * 2 + 2], 16) catch return -1;
    }

    return 0;
}

/// Helper to convert a hex string to u256
/// Returns 0 on success, -1 on failure
export fn u256_from_hex(hex: [*:0]const u8, out: *CU256) c_int {
    const hex_str = std.mem.span(hex);

    // Remove "0x" prefix if present
    const clean_hex = if (std.mem.startsWith(u8, hex_str, "0x"))
        hex_str[2..]
    else
        hex_str;

    if (clean_hex.len > 64) return -1;

    // Pad with zeros on the left
    var padded: [64]u8 = [_]u8{'0'} ** 64;
    @memcpy(padded[64 - clean_hex.len ..], clean_hex);

    // Parse as big-endian, store as little-endian
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const byte_idx = 31 - i; // Reverse for little-endian
        out.bytes[byte_idx] = std.fmt.parseInt(u8, padded[i * 2 .. i * 2 + 2], 16) catch return -1;
    }

    return 0;
}

/// Helper to convert a decimal string to u64
/// Returns the value, or 0 on failure
export fn u64_from_string(str: [*:0]const u8) u64 {
    const str_slice = std.mem.span(str);
    return std.fmt.parseInt(u64, str_slice, 10) catch 0;
}
