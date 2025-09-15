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

// Log entry for FFI - WASM32 optimized
pub const LogEntry = extern struct {
    address: [20]u8,
    _pad1: [4]u8 = .{0,0,0,0}, // Padding to align pointer
    topics: [*]const [32]u8,  // 4 bytes (32-bit pointer)
    topics_len: u32,          // 4 bytes (not usize!)
    data: [*]const u8,        // 4 bytes
    data_len: u32,            // 4 bytes
    // Total: 40 bytes
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

// Result structure for FFI - WASM32 optimized with explicit alignment
pub const EvmResult = extern struct {
    success: bool,                       // 1 byte + 3 padding for alignment
    _pad1: [3]u8 = .{0,0,0},            // Explicit padding
    gas_left: u64,                       // 8 bytes, must be 8-byte aligned
    output: [*]const u8,                 // 4 bytes (32-bit pointer)
    output_len: u32,                     // 4 bytes (use u32 not usize for FFI)
    error_message: [*:0]const u8,        // 4 bytes
    _pad2: [4]u8 = .{0,0,0,0},          // Pad to 8-byte boundary
    logs: [*]const LogEntry,             // 4 bytes
    logs_len: u32,                       // 4 bytes
    selfdestructs: [*]const SelfDestructRecord, // 4 bytes
    selfdestructs_len: u32,              // 4 bytes
    accessed_addresses: [*]const [20]u8, // 4 bytes
    accessed_addresses_len: u32,         // 4 bytes
    accessed_storage: [*]const StorageAccessRecord, // 4 bytes
    accessed_storage_len: u32,           // 4 bytes
    created_address: [20]u8,             // 20 bytes
    has_created_address: bool,           // 1 byte
    _pad3: [3]u8 = .{0,0,0},            // Padding
    trace_json: [*]const u8,             // 4 bytes
    trace_json_len: u32,                 // 4 bytes
};

// Call parameters for FFI - WASM32 optimized
pub const CallParams = extern struct {
    caller: [20]u8,         // 20 bytes
    to: [20]u8,            // 20 bytes  
    value: [32]u8,         // 32 bytes (u256 as big-endian bytes)
    input: [*]const u8,    // 4 bytes (32-bit pointer)
    input_len: u32,        // 4 bytes (not usize!)
    gas: u64,              // 8 bytes
    call_type: u8,         // 1 byte
    _pad: [3]u8 = .{0,0,0}, // Padding for alignment
    salt: [32]u8,          // 32 bytes (for CREATE2)
    // Total: Check alignment with offsetof
};

// Block info for FFI - WASM32 optimized struct layout
pub const BlockInfoFFI = extern struct {
    // Group u64 fields first to avoid padding
    number: u64,         // 8 bytes, offset 0
    timestamp: u64,      // 8 bytes, offset 8
    gas_limit: u64,      // 8 bytes, offset 16
    base_fee: u64,       // 8 bytes, offset 24
    chain_id: u64,       // 8 bytes, offset 32
    difficulty: u64,     // 8 bytes, offset 40
    // Then smaller fields
    coinbase: [20]u8,    // 20 bytes, offset 48
    _pad1: [4]u8 = .{0,0,0,0}, // Padding to align next field
    prev_randao: [32]u8, // 32 bytes, offset 72
    // Total: 104 bytes
};

// Use page allocator for WASM (no libc dependency)
const allocator = if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
    std.heap.page_allocator
else
    std.heap.c_allocator;

// Global allocator for FFI (WASM is single-threaded)
var ffi_allocator: ?std.mem.Allocator = null;
var last_error: [256]u8 = undefined;
var last_error_z: [257]u8 = undefined;
const empty_error: [1]u8 = .{0};
const empty_buffer: [0]u8 = .{};

// Instance pooling for performance (WASM-optimized, no threading)
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

// Instance pools - maintain reusable EVM instances (no mutex needed in WASM)
var instance_pool: ?std.ArrayList(*EvmInstance) = null;
var tracing_instance_pool: ?std.ArrayList(*TracingEvmInstance) = null;

// Map handles to instances
var handle_map: ?std.AutoHashMap(*EvmHandle, *EvmInstance) = null;
var tracing_handle_map: ?std.AutoHashMap(*EvmHandle, *TracingEvmInstance) = null;

fn setError(comptime fmt: []const u8, args: anytype) void {
    const slice = std.fmt.bufPrint(&last_error, fmt, args) catch "Unknown error";
    @memcpy(last_error_z[0..slice.len], slice);
    last_error_z[slice.len] = 0;
}

// Initialize FFI and instance pools
export fn guillotine_init() void {
    if (ffi_allocator == null) {
        ffi_allocator = allocator;
    }
    
    const alloc = ffi_allocator.?;
    
    if (instance_pool == null) {
        instance_pool = std.ArrayList(*EvmInstance).initCapacity(alloc, 4) catch return;
        tracing_instance_pool = std.ArrayList(*TracingEvmInstance).initCapacity(alloc, 4) catch return;
        handle_map = std.AutoHashMap(*EvmHandle, *EvmInstance).init(alloc);
        tracing_handle_map = std.AutoHashMap(*EvmHandle, *TracingEvmInstance).init(alloc);
    }
}

// Cleanup FFI and instance pools
export fn guillotine_cleanup() void {
    if (ffi_allocator) |alloc| {
        // Clean up instance pools
        if (instance_pool) |*pool| {
            for (pool.items) |instance| {
                instance.evm.deinit();
                instance.database.deinit();
                alloc.destroy(instance.database);
                alloc.destroy(instance.evm);
                alloc.destroy(instance);
            }
            pool.deinit(alloc);
            instance_pool = null;
        }
        
        if (tracing_instance_pool) |*pool| {
            for (pool.items) |instance| {
                instance.evm.deinit();
                instance.database.deinit();
                alloc.destroy(instance.database);
                alloc.destroy(instance.evm);
                alloc.destroy(instance);
            }
            pool.deinit(alloc);
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

// Create EVM instance (or reuse from pool)
export fn guillotine_evm_create(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };
    
    // Try to find a free instance in the pool
    if (instance_pool) |*pool| {
        for (pool.items) |instance| {
            if (!instance.in_use) {
                // Found a free instance - reset and reuse it
                if (instance.needs_reset) {
                    // Reset the database by reinitializing it
                    instance.database.deinit();
                    instance.database.* = Database.init(alloc);
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
                    .chain_id = block_info_ptr.chain_id,
                    .difficulty = block_info_ptr.difficulty,
                    .prev_randao = block_info_ptr.prev_randao,
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
    const instance = alloc.create(EvmInstance) catch {
        setError("Failed to allocate instance", .{});
        return null;
    };
    
    // Create database
    const db = alloc.create(Database) catch {
        setError("Failed to allocate database", .{});
        alloc.destroy(instance);
        return null;
    };
    db.* = Database.init(alloc);

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
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_info.gas_limit,
        .coinbase = block_info.coinbase,
        .chain_id = @intCast(block_info.chain_id),
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
    };

    // Create EVM instance
    const evm_ptr = alloc.create(DefaultEvm) catch {
        db.deinit();
        alloc.destroy(db);
        alloc.destroy(instance);
        setError("Failed to allocate EVM instance", .{});
        return null;
    };

    evm_ptr.* = DefaultEvm.init(
        alloc,
        db,
        block_info,
        tx_context,
        0, // gas_price
        primitives.Address.ZERO_ADDRESS, // origin
        .CANCUN, // Latest hardfork
    ) catch {
        db.deinit();
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        alloc.destroy(instance);
        setError("Failed to initialize EVM", .{});
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
    instance_pool.?.append(alloc, instance) catch {
        setError("Failed to add to pool", .{});
        evm_ptr.deinit();
        db.deinit();
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        alloc.destroy(instance);
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

// Create tracing EVM instance (with pooling support)
export fn guillotine_evm_create_tracing(block_info_ptr: *const BlockInfoFFI) ?*EvmHandle {
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized. Call guillotine_init() first", .{});
        return null;
    };
    
    // Try to find a free tracing instance in the pool
    if (tracing_instance_pool) |*pool| {
        for (pool.items) |instance| {
            if (!instance.in_use) {
                // Found a free instance - reset and reuse it
                if (instance.needs_reset) {
                    instance.database.deinit();
                    instance.database.* = Database.init(alloc);
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
                    .chain_id = block_info_ptr.chain_id,
                    .difficulty = block_info_ptr.difficulty,
                    .prev_randao = block_info_ptr.prev_randao,
                    .blob_base_fee = 0,
                    .blob_versioned_hashes = &.{},
                };
                instance.evm.block_info = block_info;
                instance.in_use = true;
                
                // Create handle and register it
                const handle = @as(*EvmHandle, @ptrCast(instance.evm));
                tracing_handle_map.?.put(handle, instance) catch {
                    instance.in_use = false;
                    setError("Failed to register handle", .{});
                    return null;
                };
                
                return handle;
            }
        }
    }
    
    // No free instance found, create a new one
    const instance = alloc.create(TracingEvmInstance) catch {
        setError("Failed to allocate tracing instance", .{});
        return null;
    };

    // Create database
    const db = alloc.create(Database) catch {
        setError("Failed to allocate database", .{});
        alloc.destroy(instance);
        return null;
    };
    db.* = Database.init(alloc);

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
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    // Create transaction context
    const tx_context = TransactionContext{
        .gas_limit = block_info.gas_limit,
        .coinbase = block_info.coinbase,
        .chain_id = @intCast(block_info.chain_id),
        .blob_versioned_hashes = &.{},
        .blob_base_fee = 0,
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
        primitives.Address.ZERO_ADDRESS, // origin
        .CANCUN, // Latest hardfork
    ) catch {
        db.deinit();
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        alloc.destroy(instance);
        setError("Failed to initialize tracing EVM", .{});
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
    tracing_instance_pool.?.append(alloc, instance) catch {
        setError("Failed to add to pool", .{});
        evm_ptr.deinit();
        db.deinit();
        alloc.destroy(db);
        alloc.destroy(evm_ptr);
        alloc.destroy(instance);
        return null;
    };
    
    // Create handle and register it
    const handle = @as(*EvmHandle, @ptrCast(evm_ptr));
    tracing_handle_map.?.put(handle, instance) catch {
        setError("Failed to register handle", .{});
        return null;
    };

    return handle;
}

// Destroy EVM instance (actually returns it to the pool)
export fn guillotine_evm_destroy(handle: *EvmHandle) void {
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

// Destroy tracing EVM instance (actually returns it to the pool)
export fn guillotine_evm_destroy_tracing(handle: *EvmHandle) void {
    // Find the instance in the tracing handle map
    if (tracing_handle_map) |*map| {
        if (map.fetchRemove(handle)) |entry| {
            const instance = entry.value;
            // Mark as not in use and needs reset
            instance.in_use = false;
            instance.needs_reset = true;
            // Instance stays in the pool for reuse
        }
    }
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
        evm_result.output_len = @intCast(output_copy.len);
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
                logs_copy[i].topics_len = @intCast(topics_copy.len);
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
                logs_copy[i].data_len = @intCast(data_copy.len);
            } else {
                logs_copy[i].data = @as([*]const u8, @ptrCast(&empty_buffer));
                logs_copy[i].data_len = 0;
            }
        }
        
        evm_result.logs = logs_copy.ptr;
        evm_result.logs_len = @intCast(logs_copy.len);
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
        evm_result.selfdestructs_len = @intCast(selfdestructs_copy.len);
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
        evm_result.accessed_addresses_len = @intCast(addresses_copy.len);
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
        evm_result.accessed_storage_len = @intCast(storage_copy.len);
    } else {
        evm_result.accessed_storage = @as([*]const StorageAccessRecord, @ptrCast(&empty_buffer));
        evm_result.accessed_storage_len = 0;
    }
    
    // Handle created address
    if (result.created_address) |addr| {
        evm_result.created_address = addr.bytes;
        evm_result.has_created_address = true;
    } else {
        evm_result.created_address = primitives.Address.ZERO_ADDRESS.bytes;
        evm_result.has_created_address = false;
    }
    
    // If we have an execution trace, serialize to JSON-RPC format
    evm_result.trace_json = @as([*]const u8, @ptrCast(&empty_buffer));
    evm_result.trace_json_len = 0;
    if (result.trace) |*trace| {
        // WASM32: Use heap allocation to avoid stack overflow
        var buf = std.array_list.AlignedManaged(u8, null).init(alloc);
        defer buf.deinit();
        
        // Build JSON with proper escaping
        buf.appendSlice("{\"structLogs\":[") catch {
            setError("Failed to start trace JSON", .{});
            alloc.destroy(evm_result);
            return null;
        };
        
        for (trace.steps, 0..) |step, i| {
            if (i > 0) buf.append(',') catch {};
            // WASM32: Be careful with stack values (u256 = 32 bytes each)
            buf.writer().print(
                "{{\"pc\":{d},\"op\":\"{s}\",\"gas\":{d},\"gasCost\":{d},\"depth\":{d},\"stack\":[",
                .{step.pc, step.opcode_name, step.gas, step.gas_cost, step.depth}
            ) catch {};
            
            for (step.stack, 0..) |val, j| {
                if (j > 0) buf.append(',') catch {};
                // WASM32: u256 values must be formatted as hex strings
                buf.writer().print("\"0x{x}\"", .{val}) catch {};
            }
            
            buf.writer().print("],\"memSize\":{d}}}", .{step.mem_size}) catch {};
        }
        
        buf.appendSlice("]}") catch {};
        
        // WASM32: Allocate final buffer with page_allocator
        const bytes = alloc.dupe(u8, buf.items) catch {
            setError("Failed to allocate trace JSON", .{});
            alloc.destroy(evm_result);
            return null;
        };
        evm_result.trace_json = bytes.ptr;
        evm_result.trace_json_len = @intCast(bytes.len);
    }
    
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
    
    // Execute the call with tracing
    const result = evm_ptr.call(call_params);
    
    // The trace is already included in result and will be serialized by convertCallResultToEvmResult
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

// Get code - returns code bytes and length, caller must free with guillotine_free_code
export fn guillotine_get_code(handle: *EvmHandle, address: *const [20]u8, code_out: *[*]u8, len_out: *u32) bool {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return false;
    };
    
    const code = evm_ptr.database.get_code_by_address(address.*) catch |err| {
        if (err == Database.Error.AccountNotFound) {
            // For non-existent accounts, return empty code (success with len=0)
            code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_buffer)));
            len_out.* = 0;
            return true;
        } else if (err == Database.Error.CodeNotFound) {
            // For accounts with no code, return empty code (success with len=0)
            code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_buffer)));
            len_out.* = 0;
            return true;
        } else {
            setError("Failed to get code: {}", .{err});
            return false;
        }
    };
    
    // Copy code if present
    if (code.len > 0) {
        const code_copy = alloc.alloc(u8, code.len) catch {
            setError("Failed to allocate code buffer", .{});
            return false;
        };
        @memcpy(code_copy, code);
        code_out.* = code_copy.ptr;
        len_out.* = @intCast(code_copy.len);
    } else {
        code_out.* = @as([*]u8, @ptrCast(@constCast(&empty_buffer)));
        len_out.* = 0;
    }
    
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

// Simulate a call (doesn't commit state)
export fn guillotine_simulate(handle: *EvmHandle, params: *const CallParams) ?*EvmResult {
    const evm_ptr: *DefaultEvm = @ptrCast(@alignCast(handle));
    const alloc = ffi_allocator orelse {
        setError("FFI not initialized", .{});
        return null;
    };
    
    // Convert parameters
    const value = std.mem.readInt(u256, &params.value, .big);
    const salt = std.mem.readInt(u256, &params.salt, .big);
    const input = if (params.input_len > 0) params.input[0..params.input_len] else &[_]u8{};
    
    // Create appropriate call params based on type
    const call_params = switch (params.call_type) {
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
        4 => evm.CallParams{ .create = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .value = value,
            .init_code = input,
            .gas = params.gas,
        }},
        5 => evm.CallParams{ .create2 = .{
            .caller = primitives.Address{ .bytes = params.caller },
            .value = value,
            .init_code = input,
            .salt = salt,
            .gas = params.gas,
        }},
        else => {
            setError("Invalid call type: {}", .{params.call_type});
            return null;
        },
    };
    
    // Simulate the call (doesn't modify state)
    const result = evm_ptr.simulate(call_params);
    
    // Convert result to FFI format
    return convertCallResultToEvmResult(result, alloc);
}