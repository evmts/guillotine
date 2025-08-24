const std = @import("std");
const builtin = @import("builtin");

const evm_root = @import("evm");
const primitives = @import("primitives");

// Simple inline logging that compiles out for freestanding WASM
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
        switch (level) {
            .err => std.log.err("[evm_c] " ++ format, args),
            .warn => std.log.warn("[evm_c] " ++ format, args),
            .info => std.log.info("[evm_c] " ++ format, args),
            .debug => std.log.debug("[evm_c] " ++ format, args),
        }
    }
}

const DefaultEvm = evm_root.DefaultEvm;
const MemoryDatabase = evm_root.MemoryDatabase;
const CallParams = evm_root.CallParams;
const CallResult = evm_root.CallResult;
const Address = primitives.Address.Address;

// Use page allocator for WASM (no libc dependency)
const allocator = if (builtin.target.cpu.arch == .wasm32 and builtin.target.os.tag == .freestanding)
    std.heap.page_allocator
else
    std.heap.c_allocator;

// Global VM instance
var vm_instance: ?*DefaultEvm = null;

// C-compatible error codes
const EvmError = enum(c_int) {
    EVM_OK = 0,
    EVM_ERROR_MEMORY = 1,
    EVM_ERROR_INVALID_PARAM = 2,
    EVM_ERROR_VM_NOT_INITIALIZED = 3,
    EVM_ERROR_EXECUTION_FAILED = 4,
    EVM_ERROR_INVALID_ADDRESS = 5,
    EVM_ERROR_INVALID_BYTECODE = 6,
};

// C-compatible execution result
const CExecutionResult = extern struct {
    success: c_int,
    gas_used: c_ulonglong,
    return_data_ptr: [*]const u8,
    return_data_len: usize,
    error_code: c_int,
};

/// Initialize the EVM
/// @return Error code (0 = success)
export fn evm_init() c_int {
    log(.info, .evm_c, "Initializing EVM", .{});

    if (vm_instance != null) {
        log(.warn, .evm_c, "VM already initialized", .{});
        return @intFromEnum(EvmError.EVM_OK);
    }

    var memory_db = MemoryDatabase.init(allocator);
    const db_interface = memory_db.to_database_interface();

    const vm = allocator.create(DefaultEvm) catch {
        log(.err, .evm_c, "Failed to allocate memory for VM", .{});
        return @intFromEnum(EvmError.EVM_ERROR_MEMORY);
    };

    // Initialize with default configuration
    const block_info = evm_root.BlockInfo.init();
    const tx_context = evm_root.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = evm_root.Hardfork.CANCUN;
    
    vm.* = DefaultEvm.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork) catch |err| {
        log(.err, .evm_c, "Failed to initialize VM: {}", .{err});
        allocator.destroy(vm);
        return @intFromEnum(EvmError.EVM_ERROR_MEMORY);
    };

    vm_instance = vm;
    log(.info, .evm_c, "EVM initialized successfully", .{});
    return @intFromEnum(EvmError.EVM_OK);
}

/// Cleanup and destroy the EVM
export fn evm_deinit() void {
    log(.info, .evm_c, "Destroying EVM", .{});

    if (vm_instance) |vm| {
        vm.deinit();
        allocator.destroy(vm);
        vm_instance = null;
    }
}

/// Execute bytecode on the EVM
/// @param bytecode_ptr Pointer to bytecode
/// @param bytecode_len Length of bytecode
/// @param caller_ptr Pointer to caller address (20 bytes)
/// @param value Value to transfer (as bytes, little endian)
/// @param gas_limit Gas limit for execution
/// @param result_ptr Pointer to result structure to fill
/// @return Error code (0 = success)
export fn evm_execute(
    bytecode_ptr: [*]const u8,
    bytecode_len: usize,
    caller_ptr: [*]const u8,
    value: c_ulonglong,
    gas_limit: c_ulonglong,
    result_ptr: *CExecutionResult,
) c_int {
    log(.info, .evm_c, "Executing bytecode: {} bytes, gas_limit: {}", .{ bytecode_len, gas_limit });

    const vm = vm_instance orelse {
        log(.err, .evm_c, "VM not initialized", .{});
        return @intFromEnum(EvmError.EVM_ERROR_VM_NOT_INITIALIZED);
    };

    // Validate inputs
    if (bytecode_len == 0) {
        log(.err, .evm_c, "Invalid bytecode", .{});
        return @intFromEnum(EvmError.EVM_ERROR_INVALID_BYTECODE);
    }

    // Convert inputs
    const bytecode = bytecode_ptr[0..bytecode_len];
    const caller_bytes = caller_ptr[0..20];
    const caller_address = caller_bytes.*;

    // Create a temporary address for the code execution
    const target_address = primitives.ZERO_ADDRESS; // Use zero address for contract execution

    // Set bytecode in state
    const code_hash = vm.database.set_code(bytecode) catch |err| {
        log(.err, .evm_c, "Failed to set bytecode: {}", .{err});
        result_ptr.success = 0;
        result_ptr.error_code = @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
        return @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
    };
    
    // Create account with the code
    var account = evm_root.Account.zero();
    account.code_hash = code_hash;
    vm.database.set_account(target_address, account) catch |err| {
        log(.err, .evm_c, "Failed to set account: {}", .{err});
        result_ptr.success = 0;
        result_ptr.error_code = @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
        return @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
    };

    // Create call parameters
    const call_params = CallParams{
        .call = .{
            .caller = caller_address,
            .to = target_address,
            .value = @as(u256, value),
            .input = &[_]u8{},
            .gas = gas_limit,
        },
    };

    // Execute call
    const run_result = vm.call(call_params) catch |err| {
        log(.err, .evm_c, "Execution failed: {}", .{err});
        result_ptr.success = 0;
        result_ptr.error_code = @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
        return @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
    };

    // Fill result structure
    result_ptr.success = if (run_result.success) 1 else 0;
    result_ptr.gas_used = @intCast(gas_limit - run_result.gas_left);
    if (run_result.output.len > 0) {
        result_ptr.return_data_ptr = run_result.output.ptr;
        result_ptr.return_data_len = run_result.output.len;
    } else {
        const empty: []const u8 = &[_]u8{};
        result_ptr.return_data_ptr = empty.ptr;
        result_ptr.return_data_len = 0;
    }
    result_ptr.error_code = @intFromEnum(EvmError.EVM_OK);

    log(.info, .evm_c, "Execution completed: success={}, gas_used={}", .{ run_result.success, gas_limit - run_result.gas_left });
    return @intFromEnum(EvmError.EVM_OK);
}

/// Get the current VM state (for debugging)
/// @return 1 if VM is initialized, 0 otherwise
export fn evm_is_initialized() c_int {
    return if (vm_instance != null) 1 else 0;
}

/// Get version string
/// @return Pointer to null-terminated version string
export fn evm_version() [*:0]const u8 {
    return "1.0.0";
}

// Test to ensure this compiles
test "C interface compilation" {
    std.testing.refAllDecls(@This());
}

// Additional FFI types and functions for Rust benchmarking

// Opaque types for C
pub const GuillotineVm = opaque {};
pub const GuillotineDatabase = opaque {};

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
    vm: *DefaultEvm,
    memory_db: *MemoryDatabase,
    allocator: std.mem.Allocator,
};

// VM creation and destruction
export fn guillotine_vm_create() ?*GuillotineVm {
    
    const state = allocator.create(VmState) catch return null;
    
    state.allocator = allocator;
    state.memory_db = allocator.create(MemoryDatabase) catch {
        allocator.destroy(state);
        return null;
    };
    state.memory_db.* = MemoryDatabase.init(allocator);
    
    const db_interface = state.memory_db.to_database_interface();
    state.vm = allocator.create(DefaultEvm) catch {
        state.memory_db.deinit();
        allocator.destroy(state.memory_db);
        allocator.destroy(state);
        return null;
    };
    
    // Initialize with default configuration
    const block_info = evm_root.BlockInfo.init();
    const tx_context = evm_root.TransactionContext{
        .gas_limit = 30_000_000,
        .coinbase = primitives.ZERO_ADDRESS,
        .chain_id = 1,
    };
    const gas_price = 0;
    const origin = primitives.ZERO_ADDRESS;
    const hardfork = evm_root.Hardfork.CANCUN;
    
    state.vm.* = DefaultEvm.init(allocator, db_interface, block_info, tx_context, gas_price, origin, hardfork) catch {
        state.memory_db.deinit();
        allocator.destroy(state.memory_db);
        allocator.destroy(state.vm);
        allocator.destroy(state);
        return null;
    };
    
    return @ptrCast(state);
}

export fn guillotine_vm_destroy(vm: ?*GuillotineVm) void {
    if (vm) |v| {
        const state: *VmState = @ptrCast(@alignCast(v));
        state.vm.deinit();
        state.allocator.destroy(state.vm);
        state.memory_db.deinit();
        state.allocator.destroy(state.memory_db);
        state.allocator.destroy(state);
    }
}

// State management
export fn guillotine_set_balance(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, balance: ?*const GuillotineU256) bool {
    if (vm == null or address == null or balance == null) return false;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = address.?.bytes;
    const value = u256_from_bytes(&balance.?.bytes);
    
    // Get current account or create new one
    var account = state.vm.database.get_account(addr) catch return false;
    if (account == null) {
        account = evm_root.Account.zero();
    }
    account.?.balance = value;
    state.vm.database.set_account(addr, account.?) catch return false;
    return true;
}

export fn guillotine_set_code(vm: ?*GuillotineVm, address: ?*const GuillotineAddress, code: ?[*]const u8, code_len: usize) bool {
    if (vm == null or address == null) return false;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const addr = address.?.bytes;
    
    const code_slice = if (code) |c| c[0..code_len] else &[_]u8{};
    // Set code and update account
    const code_hash = state.vm.database.set_code(code_slice) catch return false;
    
    // Get current account or create new one
    var account = state.vm.database.get_account(addr) catch return false;
    if (account == null) {
        account = evm_root.Account.zero();
    }
    account.?.code_hash = code_hash;
    state.vm.database.set_account(addr, account.?) catch return false;
    return true;
}

// Execution
export fn guillotine_execute(
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
        .output = &[_]u8{},
        .output_len = 0,
        .error_message = null,
    };
    
    if (vm == null or from == null) return result;
    
    const state: *VmState = @ptrCast(@alignCast(vm.?));
    const from_addr = from.?.bytes;
    const value_u256 = if (value) |v| u256_from_bytes(&v.bytes) else 0;
    const input_slice = if (input) |i| i[0..input_len] else &[_]u8{};
    
    // Create call parameters
    const to_addr = if (to) |t| t.bytes else primitives.ZERO_ADDRESS;
    const call_params = CallParams{
        .call = .{
            .caller = from_addr,
            .to = to_addr,
            .value = value_u256,
            .input = input_slice,
            .gas = gas_limit,
        },
    };
    
    // Execute
    const exec_result = state.vm.call(call_params) catch |err| {
        const err_msg = @errorName(err);
        const err_c_str = state.allocator.dupeZ(u8, err_msg) catch return result;
        result.error_message = err_c_str.ptr;
        return result;
    };
    
    result.success = exec_result.success;
    result.gas_used = gas_limit - exec_result.gas_left;
    
    // Copy output if any
    if (exec_result.output.len > 0) {
        const output_copy = state.allocator.alloc(u8, exec_result.output.len) catch return result;
        @memcpy(output_copy, exec_result.output);
        result.output = output_copy.ptr;
        result.output_len = output_copy.len;
    }
    
    return result;
}

// Utility functions
export fn guillotine_u256_from_u64(value: u64, out_u256: ?*GuillotineU256) void {
    if (out_u256 == null) return;
    
    // Clear the bytes first
    @memset(&out_u256.?.bytes, 0);
    
    // Set the lower 8 bytes (little-endian)
    const value_bytes = std.mem.asBytes(&value);
    @memcpy(out_u256.?.bytes[0..8], value_bytes);
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