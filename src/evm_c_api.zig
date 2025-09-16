//! C ABI wrapper for Guillotine EVM
//! Provides FFI-compatible exports for Bun and other language bindings

const std = @import("std");
const evm = @import("evm");
const primitives = @import("primitives");
const bytecode_c = @import("bytecode/bytecode_c.zig");
const log = std.log.scoped(.c_api);

// Import types from evm module
const DefaultEvm = evm.DefaultEvm;
// Tracer is now part of EVM struct, not a config option
const TracerEvm = DefaultEvm;
const Database = evm.Database;
const BlockInfo = evm.BlockInfo;
const TransactionContext = evm.TransactionContext;
const Hardfork = evm.Hardfork;
const Account = evm.Account;

// ============================================================================
// EVM C API
// ============================================================================

// Opaque handle for EVM instance
pub const EvmHandle = opaque {};

// Log entry for FFI
pub const LogEntry = extern struct {
    address: [20]u8,
    topics: [*]const [32]u8,  // Array of 32-byte topics
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
    slot: [32]u8,  // u256 as bytes
};

// Result structure for FFI
pub const EvmResult = extern struct {
    success: bool,
    gas_left: u64,
    output: [*]const u8,
    output_len: usize,
    error_message: [*:0]const u8,
    // Additional fields from CallResult
    logs: [*]const LogEntry,
    logs_len: usize,
    selfdestructs: [*]const SelfDestructRecord,
    selfdestructs_len: usize,
    accessed_addresses: [*]const [20]u8,  // Array of addresses
    accessed_addresses_len: usize,
    accessed_storage: [*]const StorageAccessRecord,
    accessed_storage_len: usize,
    created_address: [20]u8,  // For CREATE/CREATE2, zero if not applicable
    has_created_address: bool,
    // JSON-RPC trace (if available)
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

// Block info for FFI
pub const BlockInfoFFI = extern struct {
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    coinbase: [20]u8,
    base_fee: u64,
    chain_id: u64,
    difficulty: u64,
    prev_randao: [32]u8,
};

// Thread-local allocator for FFI
threadlocal var ffi_allocator: ?std.mem.Allocator = null;
threadlocal var last_error: [256]u8 = undefined;
threadlocal var last_error_z: [257]u8 = undefined;
const empty_error: [1]u8 = .{0};
const empty_buffer: [0]u8 = .{};

// Instance pooling for performance
const EvmInstance = struct {
    evm: *DefaultEvm,
    database: *Database,
    block_info: BlockInfoFFI,
    in_use: bool,
    needs_reset: bool,
};

const TracingEvmInstance = struct {
    evm: *TracerEvm,
    database: *Database,
    block_info: BlockInfoFFI,
    in_use: bool,
    needs_reset: bool,
};

// Instance pools - maintain reusable EVM instances
var instance_pool: ?std.ArrayList(*EvmInstance) = null;
var tracing_instance_pool: ?std.ArrayList(*TracingEvmInstance) = null;
var pool_mutex = std.Thread.Mutex{};

// Map handles to instances
var handle_map: ?std.AutoHashMap(*EvmHandle, *EvmInstance) = null;
var tracing_handle_map: ?std.AutoHashMap(*EvmHandle, *TracingEvmInstance) = null;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(&last_error, fmt, args) catch "Unknown error";
    @memcpy(last_error_z[0..slice.len], slice);
    last_error_z[slice.len] = 0;
}

// Initialize FFI allocator and instance pools
export fn guillotine_init() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    if (ffi_allocator == null) {
        ffi_allocator = std.heap.c_allocator;
    }
    
    const allocator = ffi_allocator.?;
    
    if (instance_pool == null) {
        instance_pool = std.ArrayList(*EvmInstance).initCapacity(allocator, 4) catch return;
        tracing_instance_pool = std.ArrayList(*TracingEvmInstance).initCapacity(allocator, 4) catch return;
        handle_map = std.AutoHashMap(*EvmHandle, *EvmInstance).init(allocator);
        tracing_handle_map = std.AutoHashMap(*EvmHandle, *TracingEvmInstance).init(allocator);
    }
}

// Cleanup FFI allocator and instance pools
export fn guillotine_cleanup() void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    if (ffi_allocator) |allocator| {
        // Clean up instance pools
        if (instance_pool) |*pool| {
            for (pool.items) |instance| {
                instance.evm.deinit();
                instance.database.deinit();
                allocator.destroy(instance.database);
                allocator.destroy(instance.evm);
                allocator.destroy(instance);
            }
            pool.deinit(allocator);
            instance_pool = null;
        }
        
        if (tracing_instance_pool) |*pool| {
            for (pool.items) |instance| {
                instance.evm.deinit();
                instance.database.deinit();
                allocator.destroy(instance.database);
                allocator.destroy(instance.evm);
                allocator.destroy(instance);
            }
            pool.deinit(allocator);
            tracing_instance_pool = null;
        }
        
        if (handle_map) |*map| {
            map.deinit();
            handle_map = null;
        }
        
        if (tracing_handle_map) |*map| {
            map.deinit();
            tracing_handle_map = null;
        }
    }
    
    ffi_allocator = null;
}

// Create a new EVM instance (or reuse from pool)
export fn guillotine_evm_create(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };
    
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    // Try to find a free instance in the pool
    if (instance_pool) |*pool| {
        for (pool.items) |instance| {
            if (!instance.in_use) {
                // Found a free instance - reset and reuse it
                if (instance.needs_reset) {
                    // Reset the database by reinitializing it
                    instance.database.deinit();
                    instance.database.* = Database.init(allocator);
                    instance.needs_reset = false;
                }
                
                // Update block info
                instance.block_info = block_info_ptr.*;
                const block_info = BlockInfo{
                    .number = block_info_ptr.number,
                    .timestamp = block_info_ptr.timestamp,
                    .gas_limit = block_info_ptr.gas_limit,
                    .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
                    .base_fee = block_info_ptr.base_fee,
                    .difficulty = block_info_ptr.difficulty,
                    .prev_randao = block_info_ptr.prev_randao,
                    .chain_id = @intCast(block_info_ptr.chain_id),
                    .blob_base_fee = 0,
                    .blob_versioned_hashes = &.{},
                };
                instance.evm.block_info = block_info;
                instance.in_use = true;
                
                // Create handle and register it
                const handle = @as(*EvmHandle, @ptrCast(instance.evm));
                handle_map.?.put(handle, instance) catch {
                    instance.in_use = false;
                    setError("Failed to register handle", .{});
                    return null;
                };
                
                return handle;
            }
        }
    }
    
    // No free instance found, create a new one
    const instance = allocator.create(EvmInstance) catch {
        setError("Failed to allocate instance", .{});
        return null;
    };
    
    // Create database
    const db = allocator.create(Database) catch {
        setError("Failed to allocate database", .{});
        allocator.destroy(instance);
        return null;
    };
    db.* = Database.init(allocator);

    // Convert FFI block info to internal format
    const block_info = BlockInfo{
        .number = block_info_ptr.number,
        .timestamp = block_info_ptr.timestamp,
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .base_fee = block_info_ptr.base_fee,
        .difficulty = block_info_ptr.difficulty,
        .prev_randao = block_info_ptr.prev_randao,
        .chain_id = @intCast(block_info_ptr.chain_id),
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .chain_id = @intCast(block_info_ptr.chain_id),
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    // Create EVM instance (default, no tracing)
    const evm_ptr = allocator.create(DefaultEvm) catch {
        setError("Failed to allocate EVM", .{});
        db.deinit();
        allocator.destroy(db);
        allocator.destroy(instance);
        return null;
    };

    evm_ptr.* = DefaultEvm.init(
        allocator,
        db,
        block_info,
        tx_context,
        0, // gas_price
        primitives.Address.ZERO_ADDRESS, // origin
        .CANCUN, // Latest hardfork
    ) catch {
        setError("Failed to initialize EVM", .{});
        db.deinit();
        allocator.destroy(db);
        allocator.destroy(evm_ptr);
        allocator.destroy(instance);
        return null;
    };
    
    // Initialize instance struct
    instance.* = .{
        .evm = evm_ptr,
        .database = db,
        .block_info = block_info_ptr.*,
        .in_use = true,
        .needs_reset = false,
    };
    
    // Add to pool
    instance_pool.?.append(allocator, instance) catch {
        setError("Failed to add to pool", .{});
        evm_ptr.deinit();
        db.deinit();
        allocator.destroy(db);
        allocator.destroy(evm_ptr);
        allocator.destroy(instance);
        return null;
    };
    
    // Create handle and register it
    const handle = @as(*EvmHandle, @ptrCast(evm_ptr));
    handle_map.?.put(handle, instance) catch {
        setError("Failed to register handle", .{});
        return null;
    };

    return handle;
}

// Create a new EVM instance with JSON-RPC tracing enabled
export fn guillotine_evm_create_tracing(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };

    const db = allocator.create(Database) catch {
        setError("Failed to allocate database", .{});
        return null;
    };
    db.* = Database.init(allocator);

    const block_info = BlockInfo{
        .number = block_info_ptr.number,
        .timestamp = block_info_ptr.timestamp,
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .base_fee = block_info_ptr.base_fee,
        .difficulty = block_info_ptr.difficulty,
        .prev_randao = block_info_ptr.prev_randao,
        .chain_id = @intCast(block_info_ptr.chain_id),
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = TransactionContext{
        .gas_limit = block_info_ptr.gas_limit,
        .coinbase = primitives.Address{ .bytes = block_info_ptr.coinbase },
        .chain_id = @intCast(block_info_ptr.chain_id),
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    const evm_ptr = allocator.create(TracerEvm) catch {
        setError("Failed to allocate TracerEvm", .{});
        db.deinit();
        allocator.destroy(db);
        return null;
    };

    evm_ptr.* = TracerEvm.init(
        allocator,
        db,
        block_info,
        tx_context,
        0,
        primitives.Address.ZERO_ADDRESS,
        .CANCUN,
    ) catch {
        setError("Failed to initialize TracerEvm", .{});
        db.deinit();
        allocator.destroy(db);
        allocator.destroy(evm_ptr);
        return null;
    };

    return @ptrCast(evm_ptr);
}

// Destroy an EVM instance (actually returns it to the pool)
export fn guillotine_evm_destroy(handle: *EvmHandle) void {
    pool_mutex.lock();
    defer pool_mutex.unlock();
    
    // Find the instance in the handle map
    if (handle_map) |*map| {
        if (map.fetchRemove(handle)) |entry| {
            const instance = entry.value;
            // Mark as not in use and needs reset
            instance.in_use = false;
            instance.needs_reset = true;
            // Instance stays in the pool for reuse
        }
    }
}

// Destroy a tracing EVM instance
export fn guillotine_evm_destroy_tracing(handle: *EvmHandle) void {
    const allocator = ffi_allocator orelse return;
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));

    const db = evm_ptr.database;
    evm_ptr.deinit();
    db.deinit();
    allocator.destroy(db);
    allocator.destroy(evm_ptr);
}

// Set account balance
export fn guillotine_set_balance(handle: *EvmHandle, address: *const [20]u8, balance: *const [32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    // Convert balance bytes to u256
    const balance_value = std.mem.readInt(u256, balance, .big);
    
    // Get or create account
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account.zero();
    
    account.balance = balance_value;
    
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to set account balance", .{});
        return false;
    };
    
    return true;
}

// Set account balance (tracing)
export fn guillotine_set_balance_tracing(handle: *EvmHandle, address: *const [20]u8, balance: *const [32]u8) bool {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const balance_value = std.mem.readInt(u256, balance, .big);
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account.zero();
    account.balance = balance_value;
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to set account balance", .{});
        return false;
    };
    return true;
}

// Set contract code
export fn guillotine_set_code(handle: *EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const code_slice = code[0..code_len];
    
    // Store code in database
    const code_hash = evm_ptr.database.set_code(code_slice) catch {
        setError("Failed to store code", .{});
        return false;
    };
    
    // Get or create account
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account.zero();
    
    account.code_hash = code_hash;
    
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to update account code hash", .{});
        return false;
    };
    
    return true;
}

// Set contract code (tracing)
export fn guillotine_set_code_tracing(handle: *EvmHandle, address: *const [20]u8, code: [*]const u8, code_len: usize) bool {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const code_slice = code[0..code_len];
    const code_hash = evm_ptr.database.set_code(code_slice) catch {
        setError("Failed to store code", .{});
        return false;
    };
    var account = evm_ptr.database.get_account(address.*) catch {
        setError("Failed to get account", .{});
        return false;
    } orelse Account.zero();
    account.code_hash = code_hash;
    evm_ptr.database.set_account(address.*, account) catch {
        setError("Failed to update account code hash", .{});
        return false;
    };
    return true;
}

// Helper function to convert CallResult to EvmResult
fn convertCallResultToEvmResult(result: anytype, allocator: std.mem.Allocator) ?*EvmResult {
    // Allocate result structure on heap
    const evm_result = allocator.create(EvmResult) catch {
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
        const output_copy = allocator.alloc(u8, result.output.len) catch {
            setError("Failed to allocate output buffer", .{});
            allocator.destroy(evm_result);
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
        const logs_copy = allocator.alloc(LogEntry, result.logs.len) catch {
            setError("Failed to allocate logs", .{});
            if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
            allocator.destroy(evm_result);
            return null;
        };
        
        for (result.logs, 0..) |log_item, i| {
            logs_copy[i].address = log_item.address.bytes;
            
            // Copy topics
            if (log_item.topics.len > 0) {
                const topics_copy = allocator.alloc([32]u8, log_item.topics.len) catch {
                    setError("Failed to allocate topics", .{});
                    // Clean up already allocated
                    for (logs_copy[0..i]) |prev_log| {
                        if (prev_log.topics_len > 0) allocator.free(prev_log.topics[0..prev_log.topics_len]);
                        if (prev_log.data_len > 0) allocator.free(prev_log.data[0..prev_log.data_len]);
                    }
                    allocator.free(logs_copy);
                    if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
                    allocator.destroy(evm_result);
                    return null;
                };
                for (log_item.topics, 0..) |topic, j| {
                    std.mem.writeInt(u256, &topics_copy[j], topic, .big);
                }
                logs_copy[i].topics = topics_copy.ptr;
                logs_copy[i].topics_len = topics_copy.len;
            } else {
                logs_copy[i].topics = @as([*]const [32]u8, @ptrCast(&empty_buffer));
                logs_copy[i].topics_len = 0;
            }
            
            // Copy data
            if (log_item.data.len > 0) {
                const data_copy = allocator.alloc(u8, log_item.data.len) catch {
                    setError("Failed to allocate log data", .{});
                    // Clean up
                    if (logs_copy[i].topics_len > 0) allocator.free(logs_copy[i].topics[0..logs_copy[i].topics_len]);
                    for (logs_copy[0..i]) |prev_log| {
                        if (prev_log.topics_len > 0) allocator.free(prev_log.topics[0..prev_log.topics_len]);
                        if (prev_log.data_len > 0) allocator.free(prev_log.data[0..prev_log.data_len]);
                    }
                    allocator.free(logs_copy);
                    if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
                    allocator.destroy(evm_result);
                    return null;
                };
                @memcpy(data_copy, log_item.data);
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
        const selfdestructs_copy = allocator.alloc(SelfDestructRecord, result.selfdestructs.len) catch {
            setError("Failed to allocate selfdestructs", .{});
            // Clean up logs
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log_item| {
                    if (log_item.topics_len > 0) allocator.free(log_item.topics[0..log_item.topics_len]);
                    if (log_item.data_len > 0) allocator.free(log_item.data[0..log_item.data_len]);
                }
                allocator.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
            allocator.destroy(evm_result);
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
        const addresses_copy = allocator.alloc([20]u8, result.accessed_addresses.len) catch {
            setError("Failed to allocate accessed addresses", .{});
            // Clean up previous allocations
            if (evm_result.selfdestructs_len > 0) allocator.free(evm_result.selfdestructs[0..evm_result.selfdestructs_len]);
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log_item| {
                    if (log_item.topics_len > 0) allocator.free(log_item.topics[0..log_item.topics_len]);
                    if (log_item.data_len > 0) allocator.free(log_item.data[0..log_item.data_len]);
                }
                allocator.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
            allocator.destroy(evm_result);
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
        const storage_copy = allocator.alloc(StorageAccessRecord, result.accessed_storage.len) catch {
            setError("Failed to allocate accessed storage", .{});
            // Clean up previous allocations
            if (evm_result.accessed_addresses_len > 0) allocator.free(evm_result.accessed_addresses[0..evm_result.accessed_addresses_len]);
            if (evm_result.selfdestructs_len > 0) allocator.free(evm_result.selfdestructs[0..evm_result.selfdestructs_len]);
            if (evm_result.logs_len > 0) {
                for (evm_result.logs[0..evm_result.logs_len]) |log_item| {
                    if (log_item.topics_len > 0) allocator.free(log_item.topics[0..log_item.topics_len]);
                    if (log_item.data_len > 0) allocator.free(log_item.data[0..log_item.data_len]);
                }
                allocator.free(evm_result.logs[0..evm_result.logs_len]);
            }
            if (evm_result.output_len > 0) allocator.free(evm_result.output[0..evm_result.output_len]);
            allocator.destroy(evm_result);
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
    
    // Set created address if present
    if (result.created_address) |addr| {
        evm_result.created_address = addr.bytes;
        evm_result.has_created_address = true;
    } else {
        evm_result.created_address = primitives.Address.ZERO_ADDRESS.bytes;
        evm_result.has_created_address = false;
    }

    // If we have an execution trace, serialize to JSON-RPC format into a buffer
    evm_result.trace_json = @as([*]const u8, @ptrCast(&empty_error));
    evm_result.trace_json_len = 0;
    if (result.trace) |*trace| {
        // Serialize to JSON: {"structLogs": [...]} using the tracer JSON format
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();
        w.writeAll("{\"structLogs\":[") catch {
            allocator.destroy(evm_result);
            setError("Failed to write trace json", .{});
            return null;
        };
        for (trace.steps, 0..) |step, i| {
            if (i > 0) w.writeAll(",") catch {};
            w.writeAll("{") catch {};
            w.print("\"pc\":{d},", .{step.pc}) catch {};
            w.print("\"op\":\"{s}\",", .{step.opcode_name}) catch {};
            w.print("\"gas\":{d},", .{step.gas}) catch {};
            w.print("\"gasCost\":{d},", .{step.gas_cost}) catch {};
            w.print("\"depth\":{d},", .{step.depth}) catch {};
            w.writeAll("\"stack\":[") catch {};
            for (step.stack, 0..) |val, j| {
                if (j > 0) w.writeAll(",") catch {};
                w.print("\"0x{x}\"", .{val}) catch {};
            }
            w.writeAll("]") catch {};
            w.print(",\"memSize\":{d}", .{step.mem_size}) catch {};
            w.writeAll("}") catch {};
        }
        w.writeAll("]}") catch {};
        // Duplicate into a stable allocation and then free the buffer
        const bytes = allocator.dupe(u8, buf.items) catch {
            setError("Failed to finalize trace json", .{});
            allocator.destroy(evm_result);
            return null;
        };
        evm_result.trace_json = bytes.ptr;
        evm_result.trace_json_len = bytes.len;
    }
    
    return evm_result;
}

// Execute a call
export fn guillotine_call(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    
    // Convert input slice
    const input_slice = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    
    // Convert value from bytes to u256
    const value = std.mem.readInt(u256, &params.value, .big);
    
    // Create appropriate call params based on type
    const call_params = switch (params.call_type) {
        0 => DefaultEvm.CallParams{ // CALL
            .call = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .to = primitives.Address{ .bytes = params.to },
                .value = value,
                .input = input_slice,
                .gas = params.gas,
            },
        },
        1 => DefaultEvm.CallParams{ // CALLCODE
            .callcode = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .to = primitives.Address{ .bytes = params.to },
                .value = value,
                .input = input_slice,
                .gas = params.gas,
            },
        },
        2 => DefaultEvm.CallParams{ // DELEGATECALL
            .delegatecall = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .to = primitives.Address{ .bytes = params.to },
                .input = input_slice,
                .gas = params.gas,
            },
        },
        3 => DefaultEvm.CallParams{ // STATICCALL
            .staticcall = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .to = primitives.Address{ .bytes = params.to },
                .input = input_slice,
                .gas = params.gas,
            },
        },
        4 => DefaultEvm.CallParams{ // CREATE
            .create = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .value = value,
                .init_code = input_slice,
                .gas = params.gas,
            },
        },
        5 => DefaultEvm.CallParams{ // CREATE2
            .create2 = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .value = value,
                .init_code = input_slice,
                .salt = std.mem.readInt(u256, &params.salt, .big),
                .gas = params.gas,
            },
        },
        else => {
            setError("Invalid call type: {}", .{params.call_type});
            return null;
        },
    };
    
    // Execute the call
    const result = evm_ptr.call(call_params);
    
    // Convert result to FFI format
    return convertCallResultToEvmResult(result, allocator);
}

// Execute a call (tracing)
export fn guillotine_call_tracing(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *TracerEvm = @ptrCast(@alignCast(handle));
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    const input_slice = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    const value = std.mem.readInt(u256, &params.value, .big);
    const call_params = switch (params.call_type) {
        0 => TracerEvm.CallParams{ .call = .{ .caller = primitives.Address{ .bytes = params.caller }, .to = primitives.Address{ .bytes = params.to }, .value = value, .input = input_slice, .gas = params.gas } },
        1 => TracerEvm.CallParams{ .callcode = .{ .caller = primitives.Address{ .bytes = params.caller }, .to = primitives.Address{ .bytes = params.to }, .value = value, .input = input_slice, .gas = params.gas } },
        2 => TracerEvm.CallParams{ .delegatecall = .{ .caller = primitives.Address{ .bytes = params.caller }, .to = primitives.Address{ .bytes = params.to }, .input = input_slice, .gas = params.gas } },
        3 => TracerEvm.CallParams{ .staticcall = .{ .caller = primitives.Address{ .bytes = params.caller }, .to = primitives.Address{ .bytes = params.to }, .input = input_slice, .gas = params.gas } },
        4 => TracerEvm.CallParams{ .create = .{ .caller = primitives.Address{ .bytes = params.caller }, .value = value, .init_code = input_slice, .gas = params.gas } },
        5 => TracerEvm.CallParams{ .create2 = .{ .caller = primitives.Address{ .bytes = params.caller }, .value = value, .init_code = input_slice, .salt = std.mem.readInt(u256, &params.salt, .big), .gas = params.gas } },
        else => {
            setError("Invalid call type: {}", .{params.call_type});
            return null;
        },
    };
    const result = evm_ptr.call(call_params);
    return convertCallResultToEvmResult(result, allocator);
}

// Get account balance
export fn guillotine_get_balance(handle: *EvmHandle, address: *const [20]u8, balance_out: *[32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const balance = evm_ptr.database.get_balance(address.*) catch {
        setError("Failed to get balance", .{});
        return false;
    };
    
    std.mem.writeInt(u256, balance_out, balance, .big);
    return true;
}

// Get contract code - returns code bytes and length, caller must free with guillotine_free_code
export fn guillotine_get_code(handle: *EvmHandle, address: *const [20]u8, code_out: *[*]u8, len_out: *usize) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return false;
    };
    
    const code = evm_ptr.database.get_code_by_address(address.*) catch |err| {
        if (err == Database.Error.AccountNotFound) {
            // For non-existent accounts, return empty code (success with len=0)
            code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_error)));
            len_out.* = 0;
            return true;
        } else if (err == Database.Error.CodeNotFound) {
            // For accounts with no code, return empty code (success with len=0)
            code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_error)));
            len_out.* = 0;
            return true;
        } else {
            setError("Failed to get code", .{});
            return false;
        }
    };
    
    // Copy code if present
    if (code.len > 0) {
        const code_copy = allocator.alloc(u8, code.len) catch {
            setError("Failed to allocate code buffer", .{});
            return false;
        };
        @memcpy(code_copy, code);
        code_out.* = code_copy.ptr;
        len_out.* = code_copy.len;
    } else {
        code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_error)));
        len_out.* = 0;
    }
    
    return true;
}

// Free contract code buffer
export fn guillotine_free_code(code: [*]u8, len: usize) void {
    const allocator = ffi_allocator orelse return;
    if (len > 0) {
        allocator.free(code[0..len]);
    }
}

// Set storage value
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

// Get storage value
export fn guillotine_get_storage(handle: *EvmHandle, address: *const [20]u8, key: *const [32]u8, value_out: *[32]u8) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    
    const key_u256 = std.mem.readInt(u256, key, .big);
    const storage_value = evm_ptr.database.get_storage(address.*, key_u256) catch {
        setError("Failed to get storage", .{});
        return false;
    };
    
    std.mem.writeInt(u256, value_out, storage_value, .big);
    return true;
}

// Free output buffer
export fn guillotine_free_output(output: [*]u8, len: usize) void {
    const allocator = ffi_allocator orelse return;
    allocator.free(output[0..len]);
}

// Free result structure
export fn guillotine_free_result(result: ?*EvmResult) void {
    const allocator = ffi_allocator orelse return;
    if (result) |r| {
        // Free output
        if (r.output_len > 0) {
            allocator.free(r.output[0..r.output_len]);
        }
        
        // Free logs
        if (r.logs_len > 0) {
            for (r.logs[0..r.logs_len]) |log_item| {
                if (log_item.topics_len > 0) {
                    allocator.free(log_item.topics[0..log_item.topics_len]);
                }
                if (log_item.data_len > 0) {
                    allocator.free(log_item.data[0..log_item.data_len]);
                }
            }
            allocator.free(r.logs[0..r.logs_len]);
        }
        
        // Free selfdestructs
        if (r.selfdestructs_len > 0) {
            allocator.free(r.selfdestructs[0..r.selfdestructs_len]);
        }
        
        // Free accessed addresses
        if (r.accessed_addresses_len > 0) {
            allocator.free(r.accessed_addresses[0..r.accessed_addresses_len]);
        }
        
        // Free accessed storage
        if (r.accessed_storage_len > 0) {
            allocator.free(r.accessed_storage[0..r.accessed_storage_len]);
        }
        
        // Free trace json buffer
        if (r.trace_json_len > 0) {
            allocator.free(r.trace_json[0..r.trace_json_len]);
        }
        
        // Finally free the result structure itself
        allocator.destroy(r);
    }
}

// Get last error message
export fn guillotine_get_last_error() [*:0]const u8 {
    return @ptrCast(&last_error_z);
}

// ============================================================================
// BYTECODE API
// ============================================================================

// Re-export bytecode error codes
pub const EVM_BYTECODE_SUCCESS = bytecode_c.EVM_BYTECODE_SUCCESS;
pub const EVM_BYTECODE_ERROR_NULL_POINTER = bytecode_c.EVM_BYTECODE_ERROR_NULL_POINTER;
pub const EVM_BYTECODE_ERROR_INVALID_BYTECODE = bytecode_c.EVM_BYTECODE_ERROR_INVALID_BYTECODE;
pub const EVM_BYTECODE_ERROR_OUT_OF_MEMORY = bytecode_c.EVM_BYTECODE_ERROR_OUT_OF_MEMORY;
pub const EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE = bytecode_c.EVM_BYTECODE_ERROR_BYTECODE_TOO_LARGE;
pub const EVM_BYTECODE_ERROR_INVALID_OPCODE = bytecode_c.EVM_BYTECODE_ERROR_INVALID_OPCODE;
pub const EVM_BYTECODE_ERROR_OUT_OF_BOUNDS = bytecode_c.EVM_BYTECODE_ERROR_OUT_OF_BOUNDS;

const BytecodeHandle = bytecode_c.CBytecodeHandle;

export fn evm_bytecode_create(data: [*]const u8, data_len: usize) ?*BytecodeHandle {
    const allocator = ffi_allocator orelse std.heap.c_allocator;
    return bytecode_c.evm_bytecode_create_with_allocator(allocator, data, data_len);
}

export fn evm_bytecode_destroy(handle: ?*BytecodeHandle) void {
    bytecode_c.evm_bytecode_destroy(handle);
}

export fn evm_bytecode_get_length(handle: ?*const BytecodeHandle) usize {
    return bytecode_c.evm_bytecode_get_length(handle);
}

export fn evm_bytecode_get_runtime_data(handle: ?*const BytecodeHandle, buffer: [*]u8, buffer_len: usize) usize {
    return bytecode_c.evm_bytecode_get_runtime_data(handle, buffer, buffer_len);
}

export fn evm_bytecode_get_opcode_at(handle: ?*const BytecodeHandle, position: usize) u8 {
    return bytecode_c.evm_bytecode_get_opcode_at(handle, position);
}

pub const CBasicBlock = bytecode_c.CBasicBlock;
pub const CFusionInfo = bytecode_c.CFusionInfo;
pub const CFusionType = bytecode_c.CFusionType;
pub const CJumpFusion = bytecode_c.CJumpFusion;
pub const CAdvancedFusion = bytecode_c.CAdvancedFusion;
pub const CBytecodeAnalysis = bytecode_c.CBytecodeAnalysis;

export fn evm_bytecode_analyze(handle: ?*const BytecodeHandle, analysis_out: *CBytecodeAnalysis) c_int {
    const allocator = ffi_allocator orelse std.heap.c_allocator;
    return bytecode_c.evm_bytecode_analyze_with_allocator(allocator, handle, analysis_out);
}

export fn evm_bytecode_free_analysis(analysis: *CBytecodeAnalysis) void {
    const allocator = ffi_allocator orelse std.heap.c_allocator;
    bytecode_c.evm_bytecode_free_analysis_with_allocator(allocator, analysis);
}

export fn evm_bytecode_opcode_name(opcode_value: u8) [*:0]const u8 {
    return bytecode_c.evm_bytecode_opcode_name(opcode_value);
}

pub const COpcodeInfo = bytecode_c.COpcodeInfo;

export fn evm_bytecode_opcode_info(opcode_value: u8) COpcodeInfo {
    return bytecode_c.evm_bytecode_opcode_info(opcode_value);
}

export fn evm_bytecode_is_valid_opcode(opcode_value: u8) c_int {
    return bytecode_c.evm_bytecode_is_valid_opcode(opcode_value);
}

export fn evm_bytecode_error_string(error_code: c_int) [*:0]const u8 {
    return bytecode_c.evm_bytecode_error_string(error_code);
}

// Pretty print bytecode
export fn evm_bytecode_pretty_print(data: [*]const u8, data_len: usize, buffer: [*]u8, buffer_len: usize) usize {
    const allocator = ffi_allocator orelse std.heap.c_allocator;
    return bytecode_c.evm_bytecode_pretty_print_with_allocator(allocator, data, data_len, buffer, buffer_len);
}

// Pretty print dispatch schedule with comprehensive debug information
export fn evm_dispatch_pretty_print(data: [*]const u8, data_len: usize, buffer: [*]u8, buffer_len: usize) usize {
    const allocator = ffi_allocator orelse std.heap.c_allocator;
    
    if (data_len == 0) {
        const err_msg = "Error: No bytecode provided\n";
        if (buffer_len == 0) return err_msg.len + 1;
        const copy_len = @min(err_msg.len, buffer_len - 1);
        @memcpy(buffer[0..copy_len], err_msg[0..copy_len]);
        buffer[copy_len] = 0;
        return copy_len + 1;
    }
    
    const bytecode_slice = data[0..data_len];
    
    // Create bytecode instance
    const BytecodeType = evm.Bytecode(evm.BytecodeConfig{});
    var bytecode = BytecodeType.init(allocator, bytecode_slice) catch {
        const err_msg = "Error: Failed to analyze bytecode\n";
        if (buffer_len == 0) return err_msg.len + 1;
        const copy_len = @min(err_msg.len, buffer_len - 1);
        @memcpy(buffer[0..copy_len], err_msg[0..copy_len]);
        buffer[copy_len] = 0;
        return copy_len + 1;
    };
    defer bytecode.deinit();
    
    // Create Frame and Dispatch
    const MemoryDatabase = @import("evm").MemoryDatabase;
    const FrameType = evm.Frame(evm.FrameConfig{
        .DatabaseType = MemoryDatabase,
    });
    const DispatchType = FrameType.Dispatch;
    const handlers = &FrameType.opcode_handlers;
    
    // Create dispatch schedule
    var schedule = DispatchType.DispatchSchedule.init(allocator, &bytecode, handlers, null) catch |err| {
        const err_msg = "Error: Failed to create dispatch schedule\n";
        log.err("Failed to create dispatch schedule: {}", .{err});
        if (buffer_len == 0) return err_msg.len + 1;
        const copy_len = @min(err_msg.len, buffer_len - 1);
        @memcpy(buffer[0..copy_len], err_msg[0..copy_len]);
        buffer[copy_len] = 0;
        return copy_len + 1;
    };
    defer schedule.deinit();
    
    // Import the pretty print module through evm
    const dispatch_pretty_print = evm.dispatch_pretty_print;
    const output = dispatch_pretty_print.pretty_print(
        allocator,
        schedule.items,
        &bytecode,
        FrameType,
        DispatchType.Item,
    ) catch {
        const err_msg = "Error: Failed to generate pretty print output\n";
        if (buffer_len == 0) return err_msg.len + 1;
        const copy_len = @min(err_msg.len, buffer_len - 1);
        @memcpy(buffer[0..copy_len], err_msg[0..copy_len]);
        buffer[copy_len] = 0;
        return copy_len + 1;
    };
    defer allocator.free(output);
    
    // Copy to buffer
    if (buffer_len == 0) {
        return output.len + 1;
    }
    
    const copy_len = @min(output.len, buffer_len - 1);
    @memcpy(buffer[0..copy_len], output[0..copy_len]);
    buffer[copy_len] = 0;
    return copy_len + 1;
}

// ============================================================================
// TESTS
// ============================================================================

// Simulate a call (doesn't commit state)
export fn guillotine_simulate(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const allocator = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    
    // Convert input slice
    const input_slice = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    
    // Convert value from bytes to u256
    const value = std.mem.readInt(u256, &params.value, .big);
    
    // Create appropriate call params based on type
    const call_params = switch (params.call_type) {
        0 => DefaultEvm.CallParams{ // CALL
            .call = .{
                .caller = primitives.Address{ .bytes = params.caller },
                .to = primitives.Address{ .bytes = params.to },
                .value = value,
                .input = input_slice,
                .gas = params.gas,
            },
        },
        else => {
            setError("Simulate only supports CALL type", .{});
            return null;
        },
    };
    
    // Simulate the call
    const result = evm_ptr.simulate(call_params);
    
    // Convert result to FFI format
    return convertCallResultToEvmResult(result, allocator);
}

