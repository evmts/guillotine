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

// Simple inline logging that compiles out for freestanding WASM
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
    // Logging disabled for WASM to avoid Thread dependencies
}
const Database = evm_root.Database;
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

pub const GuillotineExecutionResult = extern struct {
    success: bool,
    gas_used: u64,
    output: [*]u8,
    output_len: usize,
    error_message: ?[*:0]const u8,
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

    // NOTE: set_balance disabled - requires integration with new database interface
    _ = state;
    _ = addr;
    _ = value;
    return false;
}

export fn guillotine_set_code(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, code: ?[*]const u8, code_len: usize) bool {
    if (vm == null or address == null) return false;

    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = Address{ .bytes = address.?.bytes };

    const code_slice = if (code) |c| c[0..code_len] else &[_]u8{};
    // NOTE: set_code disabled - requires integration with new database interface
    _ = state;
    _ = addr;
    _ = code_slice;
    return false;
}

// Execution - using the new API that accepts frames directly
export fn guillotine_vm_execute(
    vm: ?*GuillotineVm,
    from: ?*const GuillotineAddress,
    to: ?*const GuillotineAddress,
    value: ?*const GuillotineU256,
    input: ?[*]const u8,
    input_len: usize,
    gas_limit: u64,
) GuillotineExecutionResult {
    var result = GuillotineExecutionResult{
        .success = false,
        .gas_used = 0,
        .output = undefined,
        .output_len = 0,
        .error_message = null,
    };

    if (vm == null or from == null) return result;

    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const from_addr = Address{ .bytes = from.?.bytes };
    const to_addr = if (to) |t| Address{ .bytes = t.bytes } else primitives.Address.ZERO_ADDRESS;
    const value_u256 = if (value) |v| u256_from_bytes(&v.bytes) else 0;
    const input_slice = if (input) |i| i[0..input_len] else &[_]u8{};
    _ = from_addr;
    _ = to_addr;
    _ = value_u256;
    _ = input_slice;
    _ = gas_limit;

    // NOTE: Contract execution disabled - APIs have changed, requires integration work
    // Note: using warn level since debug function may not work in all contexts

    // Return placeholder result for now
    const exec_result = struct {
        status: enum { Success, Failure } = .Failure,
        gas_used: u64 = 0,
        output: ?[]const u8 = null,
    }{};

    result.success = exec_result.status == .Success;
    result.gas_used = exec_result.gas_used;

    // Copy output if any
    if (exec_result.output) |output| {
        if (output.len > 0) {
            const output_copy = state.allocator.alloc(u8, output.len) catch return result;
            @memcpy(output_copy, output);
            result.output = output_copy.ptr;
            result.output_len = output_copy.len;
        }
    }

    return result;
}

// Helper functions
fn u256_from_bytes(bytes: *const [32]u8) u256 {
    // Convert from little-endian bytes to u256
    var result: u256 = 0;
    for (bytes, 0..) |byte, i| {
        result |= @as(u256, byte) << @intCast(i * 8);
    }
    return result;
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
