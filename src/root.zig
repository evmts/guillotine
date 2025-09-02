//! Guillotine - High-Performance Ethereum Virtual Machine in Zig
//!
//! This is the main entry point for the Guillotine EVM implementation, providing
//! both a Zig API and a C-compatible interface for external integration.
//!
//! ## Architecture Overview
//!
//! Guillotine is structured into several key modules:
//!
//! ### Core EVM (`evm`)
//! - **Virtual Machine**: Complete EVM implementation with bytecode execution
//! - **Stack & Memory**: 256-bit stack and byte-addressable memory
//! - **State Management**: Account state, storage, and code management
//! - **Opcode Dispatch**: Efficient jump table for instruction execution
//! - **Gas Accounting**: Precise gas cost calculations per EVM specification
//!
//! ### Primitives (`primitives`)
//! - **Address Operations**: Ethereum address utilities and validation
//! - **Cryptographic Functions**: Hash functions, signature verification
//! - **Data Encoding**: RLP, ABI, and hex encoding/decoding
//! - **Transaction Types**: Support for all Ethereum transaction formats
//!
//! ### Provider (`provider`)
//! - **RPC Interface**: JSON-RPC client for Ethereum nodes
//! - **Network Transport**: HTTP/WebSocket communication
//! - **Blockchain Queries**: Block, transaction, and state queries
//!
//! ## Usage Examples
//!
//! ### Zig API
//! ```zig
//! const guillotine = @import("guillotine");
//!
//! // Initialize EVM
//! var vm = try guillotine.Evm.init(allocator, database, null, null);
//! defer vm.deinit();
//!
//! // Execute bytecode
//! const result = try vm.interpret(contract, input);
//! ```
//!
//! ### C API
//! ```c
//! // Initialize EVM
//! if (guillotine_init() != 0) {
//!     // Handle error
//! }
//!
//! // Execute bytecode
//! CExecutionResult result;
//! guillotine_execute(bytecode, len, caller, value, gas, &result);
//!
//! // Cleanup
//! guillotine_deinit();
//! ```
//!
//! ## Design Principles
//!
//! 1. **Correctness**: Strict adherence to Ethereum Yellow Paper specification
//! 2. **Performance**: Minimal allocations, efficient memory management
//! 3. **Safety**: Strong typing, comprehensive error handling
//! 4. **Compatibility**: Full EVM specification compliance
//! 5. **Modularity**: Clear separation of concerns and testability
//!
//! ## Memory Management
//!
//! The C API uses a global allocator suitable for WASM environments,
//! while the Zig API allows custom allocator injection for maximum flexibility.
//!
//! ## Error Handling
//!
//! The C API provides error codes compatible with external systems,
//! while the Zig API uses typed error unions for precise error handling.

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

const evm_root = @import("evm");
const primitives = @import("primitives");
const provider = @import("provider");
const logs = evm_root.logs;
const Log = evm_root.Log;

// Simple inline logging that compiles out for freestanding WASM
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
    // Logging disabled for WASM to avoid Thread dependencies
}
const Database = evm_root.Database;
const Account = evm_root.Account;
const BlockInfo = evm_root.BlockInfo;
const Address = primitives.Address;
const ZERO_ADDRESS = primitives.Address.ZERO_ADDRESS;

// Global allocator for WASM environment
const allocator = if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
    std.heap.page_allocator
else
    std.heap.c_allocator;

// Global VM instance and associated database
var vm_instance: ?*evm_root.DefaultEvm = null;
var database_instance: ?*Database = null;

// C-compatible error codes
const GuillotineError = enum(c_int) {
    GUILLOTINE_OK = 0,
    GUILLOTINE_ERROR_MEMORY = 1,
    GUILLOTINE_ERROR_INVALID_PARAM = 2,
    GUILLOTINE_ERROR_VM_NOT_INITIALIZED = 3,
    GUILLOTINE_ERROR_EXECUTION_FAILED = 4,
    GUILLOTINE_ERROR_INVALID_ADDRESS = 5,
    GUILLOTINE_ERROR_INVALID_BYTECODE = 6,
};

// C-compatible execution result
const CExecutionResult = extern struct {
    success: c_int,
    gas_used: c_ulonglong,
    return_data_ptr: [*]const u8,
    return_data_len: usize,
    error_code: c_int,
};

/// Initialize the Guillotine EVM
/// @return Error code (0 = success)
export fn guillotine_init() c_int {
    log(.info, .guillotine_c, "Initializing Guillotine EVM", .{});

    if (vm_instance != null) {
        log(.warn, .guillotine_c, "VM already initialized", .{});
        return @intFromEnum(GuillotineError.GUILLOTINE_OK);
    }

    // Create and store database instance
    const database = allocator.create(Database) catch {
        log(.err, .guillotine_c, "Failed to allocate memory for Database", .{});
        return @intFromEnum(GuillotineError.GUILLOTINE_ERROR_MEMORY);
    };
    database.* = Database.init(allocator);
    database_instance = database;

    const vm = allocator.create(evm_root.DefaultEvm) catch {
        log(.err, .guillotine_c, "Failed to allocate memory for VM", .{});
        return @intFromEnum(GuillotineError.GUILLOTINE_ERROR_MEMORY);
    };

    // Create default block info and transaction context
    const block_info = evm_root.BlockInfo{
        .chain_id = 1,
        .number = 0,
        .timestamp = 0,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm_root.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    vm.* = evm_root.DefaultEvm.init(allocator, database, block_info, tx_context, 0, // gas_price
        ZERO_ADDRESS, // origin
        .CANCUN // hardfork
    ) catch |err| {
        log(.err, .guillotine_c, "Failed to initialize VM: {}", .{err});
        // Cleanup database on VM init failure
        database.deinit();
        allocator.destroy(database);
        database_instance = null;
        allocator.destroy(vm);
        return @intFromEnum(GuillotineError.GUILLOTINE_ERROR_MEMORY);
    };

    vm_instance = vm;
    log(.info, .guillotine_c, "Guillotine EVM initialized successfully", .{});
    return @intFromEnum(GuillotineError.GUILLOTINE_OK);
}

/// Cleanup and destroy the Guillotine EVM
export fn guillotine_deinit() void {
    log(.info, .guillotine_c, "Destroying Guillotine EVM", .{});

    // Minimal cleanup - just clear references to avoid memory corruption
    vm_instance = null;
    database_instance = null;

    log(.info, .guillotine_c, "Guillotine EVM cleanup completed (minimal)", .{});
}

/// Execute bytecode on the EVM
/// @param bytecode_ptr Pointer to bytecode
/// @param bytecode_len Length of bytecode
/// @param caller_ptr Pointer to caller address (20 bytes)
/// @param value Value to transfer (as bytes, little endian)
/// @param gas_limit Gas limit for execution
/// @param result_ptr Pointer to result structure to fill
/// @return Error code (0 = success)
export fn guillotine_execute(
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    caller_ptr: [*]const u8,
    value: c_ulonglong,
    gas_limit: c_ulonglong,
    result_ptr: *CExecutionResult,
) c_int {
    log(.info, .guillotine_c, "Executing bytecode: {} bytes, gas_limit: {}", .{ bytecode_len, gas_limit });

    const vm = vm_instance orelse {
        log(.err, .guillotine_c, "VM not initialized", .{});
        return @intFromEnum(GuillotineError.GUILLOTINE_ERROR_VM_NOT_INITIALIZED);
    };

    // Validate inputs
    if (bytecode_len == 0) {
        log(.err, .guillotine_c, "Invalid bytecode", .{});
        return @intFromEnum(GuillotineError.GUILLOTINE_ERROR_INVALID_BYTECODE);
    }

    // Convert inputs
    const bytecode = bytecode_ptr[0..bytecode_len];
    const caller_bytes = caller_ptr[0..20];
    const caller_address = primitives.Address{ .bytes = caller_bytes.* };
    _ = vm;
    _ = bytecode;
    _ = caller_address;
    _ = value;

    // NOTE: Contract execution disabled - requires integration with new EVM API
    log(.warn, .guillotine_c, "Contract execution temporarily disabled due to API changes", .{});

    // Return placeholder result for now
    const run_result = struct {
        status: enum { Success, Failure } = .Failure,
        gas_used: u64 = 0,
        output: ?[]const u8 = null,
    }{};

    // Fill result structure
    result_ptr.success = if (run_result.status == .Success) 1 else 0;
    result_ptr.gas_used = run_result.gas_used;
    if (run_result.output) |output| {
        result_ptr.return_data_ptr = output.ptr;
        result_ptr.return_data_len = output.len;
    } else {
        result_ptr.return_data_ptr = &[_]u8{};
        result_ptr.return_data_len = 0;
    }
    result_ptr.error_code = @intFromEnum(GuillotineError.GUILLOTINE_OK);

    log(.info, .guillotine_c, "Execution completed: status={}, gas_used={}", .{ run_result.status, run_result.gas_used });
    return @intFromEnum(GuillotineError.GUILLOTINE_OK);
}

/// Get the current VM state (for debugging)
/// @return 1 if VM is initialized, 0 otherwise
export fn guillotine_is_initialized() c_int {
    return if (vm_instance != null) 1 else 0;
}

/// Get version string
/// @return Pointer to null-terminated version string
export fn guillotine_version() [*:0]const u8 {
    return "1.0.0";
}

// Additional FFI types and functions for Rust benchmarking

// Opaque types for C
pub const GuillotineVm = opaque {};

// C-compatible types
pub const GuillotineAddress = extern struct {
    bytes: [20]u8,
};

pub const GuillotineU256 = extern struct {
    bytes: [32]u8, // Little-endian representation
};

pub const GuillotineBytes = extern struct {
    data: ?[*]u8,
    len: usize,
};

// CallParams enum tag for differentiating call types
pub const GuillotineCallType = enum(c_int) {
    call = 0,
    callcode = 1,
    delegatecall = 2,
    staticcall = 3,
    create = 4,
    create2 = 5,
};

// Complete CallParams with all fields (union-like struct)
pub const GuillotineCallParams = extern struct {
    call_type: GuillotineCallType,
    caller: GuillotineAddress,
    to: GuillotineAddress, // Zero for CREATE/CREATE2
    value: GuillotineU256, // Zero for DELEGATECALL/STATICCALL
    input: GuillotineBytes, // init_code for CREATE/CREATE2
    gas: u64,
    salt: GuillotineU256, // Only used for CREATE2
};

// Log entry for events
pub const GuillotineLog = extern struct {
    address: GuillotineAddress,
    topics: [*]GuillotineU256,
    topics_len: usize,
    data: GuillotineBytes,
};

// Self-destruct record
pub const GuillotineSelfDestruct = extern struct {
    contract: GuillotineAddress,
    beneficiary: GuillotineAddress,
};

// Storage access record
pub const GuillotineStorageAccess = extern struct {
    address: GuillotineAddress,
    slot: GuillotineU256,
};

// Complete CallResult with all fields
pub const GuillotineCallResult = extern struct {
    success: bool,
    gas_left: u64,
    output: GuillotineBytes,
    logs: ?[*]GuillotineLog,
    logs_len: usize,
    selfdestructs: ?[*]GuillotineSelfDestruct,
    selfdestructs_len: usize,
    accessed_addresses: ?[*]GuillotineAddress,
    accessed_addresses_len: usize,
    accessed_storage: ?[*]GuillotineStorageAccess,
    accessed_storage_len: usize,
    error_info: ?[*:0]const u8, // Null-terminated string or null
};

// Internal VM structure
const VmState = struct {
    vm: *evm_root.DefaultEvm,
    database: *Database,
    allocator: std.mem.Allocator,
};

// VM creation and destruction
export fn guillotine_vm_create() ?*GuillotineVm {
    const alloc = allocator;

    const state = alloc.create(VmState) catch return null;

    state.allocator = alloc;
    state.database = alloc.create(Database) catch {
        alloc.destroy(state);
        return null;
    };
    state.database.* = Database.init(alloc);

    state.vm = alloc.create(evm_root.DefaultEvm) catch {
        state.database.deinit();
        alloc.destroy(state.database);
        alloc.destroy(state);
        return null;
    };

    // Create default block info and transaction context
    const block_info = BlockInfo{
        .chain_id = 1,
        .number = 0,
        .timestamp = 0,
        .difficulty = 0,
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .base_fee = 0,
        .prev_randao = [_]u8{0} ** 32,
        .blob_base_fee = 0,
        .blob_versioned_hashes = &.{},
    };

    const tx_context = evm_root.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = ZERO_ADDRESS,
        .chain_id = 1,
    };

    state.vm.* = evm_root.DefaultEvm.init(alloc, state.database, block_info, tx_context, 0, // gas_price
        primitives.ZERO_ADDRESS, // origin
        .CANCUN // hardfork
    ) catch {
        state.database.deinit();
        alloc.destroy(state.database);
        alloc.destroy(state.vm);
        alloc.destroy(state);
        return null;
    };

    return @ptrCast(state);
}

export fn guillotine_vm_destroy(vm: ?*GuillotineVm) void {
    if (vm) |v| {
        const state: *VmState = @ptrCast(@alignCast(v));
        state.vm.deinit();
        state.allocator.destroy(state.vm);
        state.database.deinit();
        state.allocator.destroy(state.database);
        state.allocator.destroy(state);
    }
}

// State management
export fn guillotine_set_balance(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, balance: ?*const GuillotineU256) bool {
    if (vm == null or address == null or balance == null) return false;

    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };
    const value = u256_from_bytes(&balance.?.bytes);

    // Set balance using database interface (via account)
    // First get existing account or create new one
    const existing_account = state.database.get_account(addr.bytes) catch null;
    const account = if (existing_account) |acc| 
        Account{ .balance = value, .nonce = acc.nonce, .code_hash = acc.code_hash, .storage_root = acc.storage_root }
    else 
        Account{ .balance = value, .nonce = 0, .code_hash = [_]u8{0} ** 32, .storage_root = [_]u8{0} ** 32 };
    
    state.database.set_account(addr.bytes, account) catch {
        return false;
    };
    return true;
}

export fn guillotine_get_balance(vm: ?*GuillotineVm, address: ?*const GuillotineAddress) GuillotineU256 {
    const zero_balance = GuillotineU256{ .bytes = [_]u8{0} ** 32 };
    
    if (vm == null or address == null) return zero_balance;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };
    
    // Get balance using database interface
    const balance = state.database.get_balance(addr.bytes) catch 0;
    var bytes: [32]u8 = undefined;
    u256_to_bytes(balance, &bytes);
    return GuillotineU256{ .bytes = bytes };
}

export fn guillotine_set_code(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, code: ?[*]const u8, code_len: usize) bool {
    if (vm == null or address == null) return false;

    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };

    // Copy Go-managed memory to Zig-owned memory to avoid dangling pointers
    // when Go's garbage collector runs or the memory is reused
    const code_slice = if (code) |c| blk: {
        if (code_len == 0) break :blk &[_]u8{};
        const code_copy = state.allocator.alloc(u8, code_len) catch return false;
        @memcpy(code_copy, c[0..code_len]);
        break :blk code_copy;
    } else &[_]u8{};
    
    // Set code using database interface (now with Zig-owned memory)
    const code_hash = state.database.set_code(code_slice) catch {
        return false;
    };
    
    // Update account with new code hash
    const existing_account = state.database.get_account(addr.bytes) catch null;
    const account = if (existing_account) |acc| 
        Account{ .balance = acc.balance, .nonce = acc.nonce, .code_hash = code_hash, .storage_root = acc.storage_root }
    else 
        Account{ .balance = 0, .nonce = 0, .code_hash = code_hash, .storage_root = [_]u8{0} ** 32 };
    
    state.database.set_account(addr.bytes, account) catch {
        return false;
    };
    return true;
}

export fn guillotine_get_code(vm: ?*GuillotineVm, address: ?*const GuillotineAddress) GuillotineBytes {
    const empty_code = GuillotineBytes{ .data = null, .len = 0 };
    
    if (vm == null or address == null) return empty_code;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };
    
    // Get code using database interface
    const code = state.database.get_code_by_address(addr.bytes) catch return empty_code;
    if (code.len == 0) return empty_code;
    
    // Allocate fresh memory for code copy to avoid @memcpy alias issues
    const code_copy = state.allocator.alloc(u8, code.len) catch return empty_code;
    // Use alternative to @memcpy to avoid alias issues
    for (code, 0..) |byte, i| {
        code_copy[i] = byte;
    }
    return GuillotineBytes{ .data = code_copy.ptr, .len = code_copy.len };
}

export fn guillotine_set_storage(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, key: ?*const GuillotineU256, value: ?*const GuillotineU256) c_int {
    if (vm == null or address == null or key == null or value == null) return 0;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };
    const k = u256_from_bytes(&key.?.bytes);
    const v = u256_from_bytes(&value.?.bytes);
    
    // Set storage using database interface
    state.database.set_storage(addr.bytes, k, v) catch {
        return 0;
    };
    return 1; // Return 1 for success
}

export fn guillotine_get_storage(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, key: ?*const GuillotineU256) GuillotineU256 {
    const zero_value = GuillotineU256{ .bytes = [_]u8{0} ** 32 };
    
    if (vm == null or address == null or key == null) return zero_value;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };
    const k = u256_from_bytes(&key.?.bytes);
    
    // Get storage using database interface
    const storage_value = state.database.get_storage(addr.bytes, k) catch 0;
    var bytes: [32]u8 = undefined;
    u256_to_bytes(storage_value, &bytes);
    return GuillotineU256{ .bytes = bytes };
}

// Execution with complete CallParams support
export fn guillotine_vm_execute(
    vm: ?*GuillotineVm,
    params: ?*const GuillotineCallParams,
) GuillotineCallResult {
    var result = GuillotineCallResult{
        .success = false,
        .gas_left = 0,
        .output = .{ .data = null, .len = 0 },
        .logs = null,
        .logs_len = 0,
        .selfdestructs = null,
        .selfdestructs_len = 0,
        .accessed_addresses = null,
        .accessed_addresses_len = 0,
        .accessed_storage = null,
        .accessed_storage_len = 0,
        .error_info = null,
    };

    if (vm == null or params == null) return result;

    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const p = params.?;

    // Convert GuillotineCallParams to CallParams enum
    const call_params = switch (p.call_type) {
        .call => evm_root.CallParams{ .call = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .to = Address{ .bytes = p.to.bytes },
            .value = u256_from_bytes(&p.value.bytes),
            .input = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .gas = p.gas,
        } },
        .callcode => evm_root.CallParams{ .callcode = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .to = Address{ .bytes = p.to.bytes },
            .value = u256_from_bytes(&p.value.bytes),
            .input = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .gas = p.gas,
        } },
        .delegatecall => evm_root.CallParams{ .delegatecall = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .to = Address{ .bytes = p.to.bytes },
            .input = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .gas = p.gas,
        } },
        .staticcall => evm_root.CallParams{ .staticcall = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .to = Address{ .bytes = p.to.bytes },
            .input = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .gas = p.gas,
        } },
        .create => evm_root.CallParams{ .create = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .value = u256_from_bytes(&p.value.bytes),
            .init_code = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .gas = p.gas,
        } },
        .create2 => evm_root.CallParams{ .create2 = .{
            .caller = Address{ .bytes = p.caller.bytes },
            .value = u256_from_bytes(&p.value.bytes),
            .init_code = if (p.input.data) |d| d[0..p.input.len] else &[_]u8{},
            .salt = u256_from_bytes(&p.salt.bytes),
            .gas = p.gas,
        } },
    };

    // Execute using the EVM's call method
    const exec_result = state.vm.call(call_params);

    // Convert CallResult to GuillotineCallResult
    result.success = exec_result.success;
    result.gas_left = exec_result.gas_left;

    // Copy output data
    if (exec_result.output.len > 0) {
        const output_copy = state.allocator.alloc(u8, exec_result.output.len) catch return result;
        @memcpy(output_copy, exec_result.output);
        result.output = .{ .data = output_copy.ptr, .len = output_copy.len };
    }

    // Copy logs
    if (exec_result.logs.len > 0) {
        const logs_copy = state.allocator.alloc(GuillotineLog, exec_result.logs.len) catch return result;
        for (exec_result.logs, 0..) |log_entry, i| {
            // Copy topics
            const topics_copy = state.allocator.alloc(u256, log_entry.topics.len) catch return result;
            @memcpy(topics_copy, log_entry.topics);

            // Copy data
            const data_copy = state.allocator.alloc(u8, log_entry.data.len) catch return result;
            @memcpy(data_copy, log_entry.data);

            // Convert topics to GuillotineU256
            const topics_u256 = state.allocator.alloc(GuillotineU256, log_entry.topics.len) catch return result;
            for (topics_copy, 0..) |topic, j| {
                var bytes: [32]u8 = undefined;
                u256_to_bytes(topic, &bytes);
                topics_u256[j] = GuillotineU256{ .bytes = bytes };
            }

            logs_copy[i] = GuillotineLog{
                .address = GuillotineAddress{ .bytes = log_entry.address.bytes },
                .topics = topics_u256.ptr,
                .topics_len = topics_u256.len,
                .data = .{ .data = data_copy.ptr, .len = data_copy.len },
            };
        }
        result.logs = logs_copy.ptr;
        result.logs_len = logs_copy.len;
    }

    // Copy selfdestructs
    if (exec_result.selfdestructs.len > 0) {
        const selfdestructs_copy = state.allocator.alloc(GuillotineSelfDestruct, exec_result.selfdestructs.len) catch return result;
        for (exec_result.selfdestructs, 0..) |sd, i| {
            selfdestructs_copy[i] = GuillotineSelfDestruct{
                .contract = GuillotineAddress{ .bytes = sd.contract.bytes },
                .beneficiary = GuillotineAddress{ .bytes = sd.beneficiary.bytes },
            };
        }
        result.selfdestructs = selfdestructs_copy.ptr;
        result.selfdestructs_len = selfdestructs_copy.len;
    }

    // Copy accessed addresses
    if (exec_result.accessed_addresses.len > 0) {
        const addresses_copy = state.allocator.alloc(GuillotineAddress, exec_result.accessed_addresses.len) catch return result;
        for (exec_result.accessed_addresses, 0..) |addr, i| {
            addresses_copy[i] = GuillotineAddress{ .bytes = addr.bytes };
        }
        result.accessed_addresses = addresses_copy.ptr;
        result.accessed_addresses_len = addresses_copy.len;
    }

    // Copy accessed storage
    if (exec_result.accessed_storage.len > 0) {
        const storage_copy = state.allocator.alloc(GuillotineStorageAccess, exec_result.accessed_storage.len) catch return result;
        for (exec_result.accessed_storage, 0..) |sa, i| {
            var slot_bytes: [32]u8 = undefined;
            u256_to_bytes(sa.slot, &slot_bytes);
            storage_copy[i] = GuillotineStorageAccess{
                .address = GuillotineAddress{ .bytes = sa.address.bytes },
                .slot = GuillotineU256{ .bytes = slot_bytes },
            };
        }
        result.accessed_storage = storage_copy.ptr;
        result.accessed_storage_len = storage_copy.len;
    }

    // Copy error info if present
    if (exec_result.error_info) |err_info| {
        const err_copy = state.allocator.allocSentinel(u8, err_info.len, 0) catch return result;
        @memcpy(err_copy, err_info);
        result.error_info = err_copy.ptr;
    }

    return result;
}

// Helper functions
fn u256_from_bytes(bytes: *const [32]u8) u256 {
    // Convert from little-endian bytes to u256 (Go primitives use little-endian internally)
    var result: u256 = 0;
    for (bytes, 0..) |byte, i| {
        result |= @as(u256, byte) << @intCast(i * 8);
    }
    return result;
}

fn u256_to_bytes(value: u256, bytes: *[32]u8) void {
    // Convert u256 to little-endian bytes (Go primitives expect little-endian internally)
    for (0..32) |i| {
        bytes[i] = @intCast((value >> @intCast(i * 8)) & 0xFF);
    }
}

// Test to ensure this compiles
test "C interface compilation" {
    std.testing.refAllDecls(@This());
}

// Re-export modules
pub const Evm = evm_root.Evm;
pub const DefaultEvm = evm_root.DefaultEvm;
pub const Primitives = primitives;
pub const Provider = provider;

test "Evm module" {
    std.testing.refAllDecls(DefaultEvm);
}
