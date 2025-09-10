//! C ABI wrapper for Guillotine EVM - WASM version
//! Provides FFI-compatible exports for TypeScript bindings

const std = @import("std");
const builtin = @import("builtin");

// Disable all logging for WASM to avoid Thread/IO dependencies
pub const std_options = std.Options{
    .logFn = struct {
        pub fn logFn(
            comptime message_level: std.log.Level,
            comptime scope: @TypeOf(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            _ = message_level;
            _ = scope;
            _ = format;
            _ = args;
            // No-op for WASM
        }
    }.logFn,
};

const evm = @import("evm");
const primitives = @import("primitives");

// Import types from evm module
const DefaultEvm = evm.DefaultEvm;
const TracerEvm = evm.Evm(.{ .TracerType = evm.tracer.JSONRPCTracer });
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Hardfork = evm.Hardfork;
const Account = evm.Account;

// Opaque handle for EVM instance
pub const EvmHandle = opaque {};

// Log entry for FFI
pub const LogEntry = extern struct {
    address: [20]u8,
    topics: [*]const [32]u8,
    topics_len: usize,
    data: [*]const u8,
    data_len: usize,
};

// Self-destruct record for FFI
pub const SelfDestructRecord = extern struct {
    contract: [20]u8,
    beneficiary: [20]u8,
};

// Storage access record for FFI
pub const StorageAccessRecord = extern struct {
    address: [20]u8,
    slot: [32]u8,
};

// Result structure for FFI - matches evm_c_api.zig
pub const EvmResult = extern struct {
    success: bool align(4), // Align to 4 bytes for C compatibility
    gas_left: u64,
    output: [*]const u8,
    output_len: usize,
    error_message: [*:0]const u8,
    logs: [*]const LogEntry,
    logs_len: usize,
    selfdestructs: [*]const SelfDestructRecord,
    selfdestructs_len: usize,
    accessed_addresses: [*]const [20]u8,
    accessed_addresses_len: usize,
    accessed_storage: [*]const StorageAccessRecord,
    accessed_storage_len: usize,
    created_address: [20]u8,
    has_created_address: bool,
    trace_json: [*]const u8,
    trace_json_len: usize,
};

// Call parameters for FFI
pub const CallParams = extern struct {
    caller: [20]u8,
    to: [20]u8,
    value: [32]u8, // u256 as bytes
    input: [*]const u8,
    input_len: usize,
    gas: u64,
    call_type: u8, // 0=CALL, 1=CALLCODE, 2=DELEGATECALL, 3=STATICCALL, 4=CREATE, 5=CREATE2
    salt: [32]u8, // For CREATE2
};

// Block info for FFI - all u64 fields first to avoid padding
pub const BlockInfoFFI = extern struct {
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    base_fee: u64,
    chain_id: u64,
    difficulty: u64,
    coinbase: [20]u8,
    prev_randao: [32]u8,
};

// Use page allocator for WASM (no libc dependency)
const allocator = if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
    std.heap.page_allocator
else
    std.heap.c_allocator;

// Thread-local allocator for FFI (in WASM this is just global)
var ffi_allocator: ?std.mem.Allocator = null;
var last_error: [256]u8 = undefined;
var last_error_z: [257]u8 = undefined;
const empty_error: [1]u8 = .{0};
const empty_buffer: [0]u8 = .{};

fn setError(comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(&last_error, fmt, args) catch "Unknown error";
    @memcpy(last_error_z[0..slice.len], slice);
    last_error_z[slice.len] = 0;
}

// Initialize FFI
export fn guillotine_init() void {
    if (ffi_allocator == null) {
        ffi_allocator = allocator;
    }
}

// Cleanup FFI
export fn guillotine_cleanup() void {
    ffi_allocator = null;
}

// Create EVM instance
export fn guillotine_evm_create(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };

    // Create database
    const db = alloc.create(evm.Database) catch {
        setError("Failed to allocate database", .{});
        return null;
    };
    db.* = evm.Database.init(alloc);

    // Set up block info
    const block_info = BlockInfo{
        .number = block_info_ptr.number,
        .timestamp = block_info_ptr.timestamp,
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .base_fee = block_info_ptr.base_fee,
        .chain_id = block_info_ptr.chain_id,
        .difficulty = block_info_ptr.difficulty,
        .prev_randao = block_info_ptr.prev_randao,
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_info.gas_limit,
        .coinbase = block_info.coinbase,
        .chain_id = @intCast(block_info.chain_id),
        .blob_versioned_hashes = &.{},
    };

    // Create EVM instance
    const evm_ptr = alloc.create(DefaultEvm) catch {
        alloc.destroy(db);
        setError("Failed to allocate EVM instance", .{});
        return null;
    };

    evm_ptr.* = DefaultEvm.init(
        alloc,
        db,
        block_info,
        tx_context,
        0, // gas_price
        primitives.Address.zero(), // origin
        Hardfork.DEFAULT,
    ) catch {
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        setError("Failed to initialize EVM", .{});
        return null;
    };

    return @ptrCast(evm_ptr);
}

// Create tracing EVM instance
export fn guillotine_evm_create_tracing(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };

    // Create database
    const db = alloc.create(evm.Database) catch {
        setError("Failed to allocate database", .{});
        return null;
    };
    db.* = evm.Database.init(alloc);

    // Set up block info
    const block_info = BlockInfo{
        .number = block_info_ptr.number,
        .timestamp = block_info_ptr.timestamp,
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .base_fee = block_info_ptr.base_fee,
        .chain_id = block_info_ptr.chain_id,
        .difficulty = block_info_ptr.difficulty,
        .prev_randao = block_info_ptr.prev_randao,
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_info.gas_limit,
        .coinbase = block_info.coinbase,
        .chain_id = @intCast(block_info.chain_id),
        .blob_versioned_hashes = &.{},
    };

    // Create tracing EVM instance
    const evm_ptr = alloc.create(TracerEvm) catch {
        alloc.destroy(db);
        setError("Failed to allocate tracing EVM instance", .{});
        return null;
    };

    evm_ptr.* = TracerEvm.init(
        alloc,
        db,
        block_info,
        tx_context,
        0, // gas_price
        primitives.Address.zero(), // origin
        Hardfork.DEFAULT,
    ) catch {
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        setError("Failed to initialize tracing EVM", .{});
        return null;
    };

    return @ptrCast(evm_ptr);
}

// Destroy EVM instance
export fn guillotine_evm_destroy(handle: *EvmHandle) void {
    const alloc = ffi_allocator orelse return;
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    // Deinit database
    const db_ptr: *evm.Database = @ptrCast(@alignCast(evm_ptr.database));
    db_ptr.deinit();
    alloc.destroy(db_ptr);
    
    // Destroy EVM
    evm_ptr.deinit();
    alloc.destroy(evm_ptr);
}

// Destroy tracing EVM instance
export fn guillotine_evm_destroy_tracing(handle: *EvmHandle) void {
    const alloc = ffi_allocator orelse return;
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));

    // Deinit database
    const db_ptr: *evm.Database = @ptrCast(@alignCast(evm_ptr.database));
    db_ptr.deinit();
    alloc.destroy(db_ptr);

    // Destroy EVM
    evm_ptr.deinit();
    alloc.destroy(evm_ptr);
}

// Set balance
export fn guillotine_set_balance(handle: *EvmHandle, address: *const [20]u8, balance: *const [32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const balance_value = std.mem.readInt(u256, balance, .big);
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account{ .balance = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32, .nonce = 0, .delegated_address = null };
    account.balance = balance_value;
    
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to set account balance", .{});
        return false;
    };
    
    return true;
}

// Set balance for tracing EVM
export fn guillotine_set_balance_tracing(handle: *EvmHandle, address: *const [20]u8, balance: *const [32]u8) bool {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const balance_value = std.mem.readInt(u256, balance, .big);
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account{ .balance = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32, .nonce = 0, .delegated_address = null };
    account.balance = balance_value;
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to set account balance", .{});
        return false;
    };
    return true;
}

// Set code
export fn guillotine_set_code(handle: *EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const code_slice = code[0..code_len];
    const code_hash = evm_ptr.database.set_code(code_slice) catch {
        setError("Failed to set code", .{});
        return false;
    };
    
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account{ .balance = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32, .nonce = 0, .delegated_address = null };
    account.code_hash = code_hash;
    
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to update account code hash", .{});
        return false;
    };
    
    return true;
}

// Set code for tracing EVM
export fn guillotine_set_code_tracing(handle: *EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const code_slice = code[0..code_len];
    const code_hash = evm_ptr.database.set_code(code_slice) catch {
        setError("Failed to set code", .{});
        return false;
    };
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account{ .balance = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32, .nonce = 0, .delegated_address = null };
    account.code_hash = code_hash;
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to update account code hash", .{});
        return false;
    };
    return true;
}

// Helper function to convert CallResult to EvmResult
fn convertCallResultToEvmResult(result: anytype, alloc: std.mem.Allocator) ?*EvmResult {
    // Allocate result structure on heap
    const evm_result = alloc.create(EvmResult) catch {
        setError("Failed to allocate result", .{});
        return null;
    };
    
    // Set basic fields
    evm_result.success = result.success;
    evm_result.gas_left = result.gas_left;
    evm_result.error_message = if (result.error_info) |info| blk: {
        _ = std.fmt.bufPrintZ(&last_error_z, "{s}", .{info}) catch "Unknown error";
        break :blk @ptrCast(&last_error_z);
    } else if (!result.success) @ptrCast(&last_error_z) else @as([*:0]const u8, @ptrCast(&empty_error));
    
    // Copy output if present
    if (result.output.len > 0) {
        const output_copy = alloc.alloc(u8, result.output.len) catch {
            setError("Failed to allocate output buffer", .{});
            alloc.destroy(evm_result);
            return null;
        };
        @memcpy(output_copy, result.output);
        evm_result.output = output_copy.ptr;
        evm_result.output_len = output_copy.len;
    } else {
        evm_result.output = @as([*]const u8, @ptrCast(&empty_error));
        evm_result.output_len = 0;
    }
    
    // Copy logs if present
    if (result.logs.len > 0) {
        const logs_copy = alloc.alloc(LogEntry, result.logs.len) catch {
            setError("Failed to allocate logs", .{});
            if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
            alloc.destroy(evm_result);
            return null;
        };
        
        for (result.logs, 0..) |log, i| {
            logs_copy[i].address = log.address.bytes;
            
            // Copy topics
            if (log.topics.len > 0) {
                const topics_copy = alloc.alloc([32]u8, log.topics.len) catch {
                    setError("Failed to allocate topics", .{});
                    // Clean up already allocated
                    for (logs_copy[0..i]) |prev_log| {
                        if (prev_log.topics_len > 0) alloc.free(prev_log.topics[0..prev_log.topics_len]);
                        if (prev_log.data_len > 0) alloc.free(prev_log.data[0..prev_log.data_len]);
                    }
                    alloc.free(logs_copy);
                    if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
                    alloc.destroy(evm_result);
                    return null;
                };
                for (log.topics, 0..) |topic, j| {
                    std.mem.writeInt(u256, &topics_copy[j], topic, .big);
                }
                logs_copy[i].topics = topics_copy.ptr;
                logs_copy[i].topics_len = topics_copy.len;
            } else {
                logs_copy[i].topics = @as([*]const [32]u8, @ptrCast(&empty_buffer));
                logs_copy[i].topics_len = 0;
            }
            
            // Copy data
            if (log.data.len > 0) {
                const data_copy = alloc.alloc(u8, log.data.len) catch {
                    setError("Failed to allocate log data", .{});
                    // Clean up
                    if (logs_copy[i].topics_len > 0) alloc.free(logs_copy[i].topics[0..logs_copy[i].topics_len]);
                    for (logs_copy[0..i]) |prev_log| {
                        if (prev_log.topics_len > 0) alloc.free(prev_log.topics[0..prev_log.topics_len]);
                        if (prev_log.data_len > 0) alloc.free(prev_log.data[0..prev_log.data_len]);
                    }
                    alloc.free(logs_copy);
                    if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
                    alloc.destroy(evm_result);
                    return null;
                };
                @memcpy(data_copy, log.data);
                logs_copy[i].data = data_copy.ptr;
                logs_copy[i].data_len = data_copy.len;
            } else {
                logs_copy[i].data = @as([*]const u8, @ptrCast(&empty_buffer));
                logs_copy[i].data_len = 0;
            }
        }
        
        evm_result.logs = logs_copy.ptr;
        evm_result.logs_len = logs_copy.len;
    } else {
        evm_result.logs = @as([*]const LogEntry, @ptrCast(@alignCast(&empty_buffer)));
        evm_result.logs_len = 0;
    }
    
    // Copy selfdestructs if present
    if (result.selfdestructs.len > 0) {
        const selfdestructs_copy = alloc.alloc(SelfDestructRecord, result.selfdestructs.len) catch {
            setError("Failed to allocate selfdestructs", .{});
            // Clean up logs
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log| {
                    if (log.topics_len > 0) alloc.free(log.topics[0..log.topics_len]);
                    if (log.data_len > 0) alloc.free(log.data[0..log.data_len]);
                }
                alloc.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
            alloc.destroy(evm_result);
            return null;
        };
        
        for (result.selfdestructs, 0..) |sd, i| {
            selfdestructs_copy[i].contract = sd.contract.bytes;
            selfdestructs_copy[i].beneficiary = sd.beneficiary.bytes;
        }
        
        evm_result.selfdestructs = selfdestructs_copy.ptr;
        evm_result.selfdestructs_len = selfdestructs_copy.len;
    } else {
        evm_result.selfdestructs = @as([*]const SelfDestructRecord, @ptrCast(&empty_buffer));
        evm_result.selfdestructs_len = 0;
    }
    
    // Copy accessed addresses if present
    if (result.accessed_addresses.len > 0) {
        const addresses_copy = alloc.alloc([20]u8, result.accessed_addresses.len) catch {
            setError("Failed to allocate accessed addresses", .{});
            // Clean up previous allocations
            if (evm_result.selfdestructs_len > 0) alloc.free(evm_result.selfdestructs[0..evm_result.selfdestructs_len]);
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log| {
                    if (log.topics_len > 0) alloc.free(log.topics[0..log.topics_len]);
                    if (log.data_len > 0) alloc.free(log.data[0..log.data_len]);
                }
                alloc.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
            alloc.destroy(evm_result);
            return null;
        };
        
        for (result.accessed_addresses, 0..) |addr, i| {
            addresses_copy[i] = addr.bytes;
        }
        
        evm_result.accessed_addresses = addresses_copy.ptr;
        evm_result.accessed_addresses_len = addresses_copy.len;
    } else {
        evm_result.accessed_addresses = @as([*]const [20]u8, @ptrCast(&empty_buffer));
        evm_result.accessed_addresses_len = 0;
    }
    
    // Copy accessed storage if present
    if (result.accessed_storage.len > 0) {
        const storage_copy = alloc.alloc(StorageAccessRecord, result.accessed_storage.len) catch {
            setError("Failed to allocate accessed storage", .{});
            // Clean up
            if (evm_result.accessed_addresses_len > 0) alloc.free(evm_result.accessed_addresses[0..evm_result.accessed_addresses_len]);
            if (evm_result.selfdestructs_len > 0) alloc.free(evm_result.selfdestructs[0..evm_result.selfdestructs_len]);
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log| {
                    if (log.topics_len > 0) alloc.free(log.topics[0..log.topics_len]);
                    if (log.data_len > 0) alloc.free(log.data[0..log.data_len]);
                }
                alloc.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) alloc.free(evm_result.output[0..evm_result.output_len]);
            alloc.destroy(evm_result);
            return null;
        };
        
        for (result.accessed_storage, 0..) |access, i| {
            storage_copy[i].address = access.address.bytes;
            std.mem.writeInt(u256, &storage_copy[i].slot, access.slot, .big);
        }
        
        evm_result.accessed_storage = storage_copy.ptr;
        evm_result.accessed_storage_len = storage_copy.len;
    } else {
        evm_result.accessed_storage = @as([*]const StorageAccessRecord, @ptrCast(&empty_buffer));
        evm_result.accessed_storage_len = 0;
    }
    
    // Handle created address
    if (result.created_address) |addr| {
        evm_result.created_address = addr.bytes;
        evm_result.has_created_address = true;
    } else {
        evm_result.created_address = [_]u8{0} ** 20;
        evm_result.has_created_address = false;
    }
    
    // TODO: Add trace JSON support if available
    evm_result.trace_json = @as([*]const u8, @ptrCast(&empty_buffer));
    evm_result.trace_json_len = 0;
    
    return evm_result;
}

// Execute a call
export fn guillotine_call(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    
    // Convert parameters
    const value = std.mem.readInt(u256, &params.value, .big);
    const salt = std.mem.readInt(u256, &params.salt, .big);
    const input = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    
    // Determine call type
    const call_params = switch (params.call_type) {
        4 => evm.CallParams{ .create = .{ 
            .caller = primitives.Address{ .bytes = params.caller }, 
            .value = value, 
            .init_code = input, 
            .gas = params.gas 
        }},
        5 => evm.CallParams{ .create2 = .{ 
            .caller = primitives.Address{ .bytes = params.caller }, 
            .value = value, 
            .init_code = input, 
            .salt = salt, 
            .gas = params.gas 
        }},
        0 => evm.CallParams{ .call = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .value = value,
            .input = input,
            .gas = params.gas,
        }},
        1 => evm.CallParams{ .callcode = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .value = value,
            .input = input,
            .gas = params.gas,
        }},
        2 => evm.CallParams{ .delegatecall = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .input = input,
            .gas = params.gas,
        }},
        3 => evm.CallParams{ .staticcall = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .input = input,
            .gas = params.gas,
        }},
        else => {
            setError("Invalid call type: {}", .{params.call_type});
            return null;
        },
    };
    
    // Execute the call
    const result = evm_ptr.call(call_params);
    
    return convertCallResultToEvmResult(result, alloc);
}

// Execute a call with tracing
export fn guillotine_call_tracing(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    
    // Convert parameters
    const value = std.mem.readInt(u256, &params.value, .big);
    const salt = std.mem.readInt(u256, &params.salt, .big);
    const input = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    
    // Determine call type
    const call_params = switch (params.call_type) {
        4 => evm.CallParams{ .create = .{ 
            .caller = primitives.Address{ .bytes = params.caller }, 
            .value = value, 
            .init_code = input, 
            .gas = params.gas 
        }},
        5 => evm.CallParams{ .create2 = .{ 
            .caller = primitives.Address{ .bytes = params.caller }, 
            .value = value, 
            .init_code = input, 
            .salt = salt, 
            .gas = params.gas 
        }},
        0 => evm.CallParams{ .call = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .value = value,
            .input = input,
            .gas = params.gas,
        }},
        1 => evm.CallParams{ .callcode = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .value = value,
            .input = input,
            .gas = params.gas,
        }},
        2 => evm.CallParams{ .delegatecall = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .input = input,
            .gas = params.gas,
        }},
        3 => evm.CallParams{ .staticcall = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .to = primitives.Address{ .bytes = params.to },
            .input = input,
            .gas = params.gas,
        }},
        else => {
            setError("Invalid call type: {}", .{params.call_type});
            return null;
        },
    };
    
    // Execute the call
    const result = evm_ptr.call(call_params);
    
    // TODO: Include trace JSON in result
    return convertCallResultToEvmResult(result, alloc);
}

// Get balance
export fn guillotine_get_balance(handle: *EvmHandle, address: *const [20]u8, balance_out: *[32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const balance = evm_ptr.database.get_balance(address.*) catch {
        setError("Failed to get balance", .{});
        return false;
    };
    
    std.mem.writeInt(u256, balance_out, balance, .big);
    return true;
}

// Get code
export fn guillotine_get_code(handle: *EvmHandle, address: *const [20]u8, code_out: *[*]u8, len_out: *usize) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return false;
    };
    
    const account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account{ .balance = 0, .code_hash = primitives.EMPTY_CODE_HASH, .storage_root = [_]u8{0} ** 32, .nonce = 0, .delegated_address = null };
    
    if (std.mem.eql(u8, &account.code_hash, &primitives.EMPTY_CODE_HASH)) {
        code_out.* = @constCast(@ptrCast(@alignCast(&empty_buffer)));
        len_out.* = 0;
        return true;
    }
    
    const code = evm_ptr.database.get_code(account.code_hash) catch {
        setError("Failed to get code", .{});
        return false;
    };
    
    if (code.len == 0) {
        code_out.* = @constCast(@ptrCast(@alignCast(&empty_buffer)));
        len_out.* = 0;
        return true;
    }
    
    const code_copy = alloc.alloc(u8, code.len) catch {
        setError("Failed to allocate code buffer", .{});
        return false;
    };
    @memcpy(code_copy, code);
    
    code_out.* = code_copy.ptr;
    len_out.* = code_copy.len;
    return true;
}

// Free code memory
export fn guillotine_free_code(code: [*]u8, len: usize) void {
    const alloc = ffi_allocator orelse return;
    if (len > 0) {
        alloc.free(code[0..len]);
    }
}

// Set storage
export fn guillotine_set_storage(handle: *EvmHandle, address: *const [20]u8, key: *const [32]u8, value: *const [32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const key_u256 = std.mem.readInt(u256, key, .big);
    const value_u256 = std.mem.readInt(u256, value, .big);
    
    evm_ptr.database.set_storage(address.*, key_u256, value_u256) catch {
        setError("Failed to set storage", .{});
        return false;
    };
    
    return true;
}

// Get storage
export fn guillotine_get_storage(handle: *EvmHandle, address: *const [20]u8, key: *const [32]u8, value_out: *[32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const key_u256 = std.mem.readInt(u256, key, .big);
    const value = evm_ptr.database.get_storage(address.*, key_u256) catch {
        setError("Failed to get storage", .{});
        return false;
    };
    
    std.mem.writeInt(u256, value_out, value, .big);
    return true;
}

// Free output memory
export fn guillotine_free_output(output: [*]u8, len: usize) void {
    const alloc = ffi_allocator orelse return;
    alloc.free(output[0..len]);
}

// Free result structure
export fn guillotine_free_result(result: ?*EvmResult) void {
    const alloc = ffi_allocator orelse return;
    if (result) |r| {
        // Free output
        if (r.output_len > 0) {
            alloc.free(r.output[0..r.output_len]);
        }
        
        // Free logs
        if (r.logs_len > 0) {
            for (r.logs[0..r.logs_len]) |log| {
                if (log.topics_len > 0) {
                    alloc.free(log.topics[0..log.topics_len]);
                }
                if (log.data_len > 0) {
                    alloc.free(log.data[0..log.data_len]);
                }
            }
            alloc.free(r.logs[0..r.logs_len]);
        }
        
        // Free selfdestructs
        if (r.selfdestructs_len > 0) {
            alloc.free(r.selfdestructs[0..r.selfdestructs_len]);
        }
        
        // Free accessed addresses
        if (r.accessed_addresses_len > 0) {
            alloc.free(r.accessed_addresses[0..r.accessed_addresses_len]);
        }
        
        // Free accessed storage
        if (r.accessed_storage_len > 0) {
            alloc.free(r.accessed_storage[0..r.accessed_storage_len]);
        }
        
        // Free trace JSON
        if (r.trace_json_len > 0) {
            alloc.free(r.trace_json[0..r.trace_json_len]);
        }
        
        // Free the result structure itself
        alloc.destroy(r);
    }
}

// Get last error message
export fn guillotine_get_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_z);
}

// Simulate a call (same as call but doesn't modify state)
export fn guillotine_simulate(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    // For now, just call the regular call function
    // TODO: Implement proper simulation that doesn't modify state
    return guillotine_call(handle, params);
}