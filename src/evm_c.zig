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

const Evm = evm_root.Evm;
const MemoryDatabase = evm_root.MemoryDatabase;
const Address = primitives.Address.Address;

// Global allocator for WASM environment
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else gpa.allocator();

// Global VM instance
var vm_instance: ?*Evm = null;

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

    const vm = allocator.create(Evm) catch {
        log(.err, .evm_c, "Failed to allocate memory for VM", .{});
        return @intFromEnum(EvmError.EVM_ERROR_MEMORY);
    };

    var builder = evm_root.EvmBuilder.init(allocator, db_interface);
    vm.* = try builder.build() catch |err| {
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
    const caller_address: primitives.Address.Address = caller_bytes.*;

    // Create contract for execution
    const target_address = primitives.Address.ZERO_ADDRESS; // Use zero address for contract execution
    var contract = evm_root.Contract.init_at_address(caller_address, target_address, @as(u256, value), gas_limit, bytecode, &[_]u8{}, // empty input for now
        false // not static
    );
    defer contract.deinit(allocator, null);

    // Set bytecode in state
    vm.state.set_code(target_address, bytecode) catch |err| {
        log(.err, .evm_c, "Failed to set bytecode: {}", .{err});
        result_ptr.success = 0;
        result_ptr.error_code = @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
        return @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
    };

    // Execute bytecode
    const run_result = vm.interpret(&contract, &[_]u8{}) catch |err| {
        log(.err, .evm_c, "Execution failed: {}", .{err});
        result_ptr.success = 0;
        result_ptr.error_code = @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
        return @intFromEnum(EvmError.EVM_ERROR_EXECUTION_FAILED);
    };

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
    result_ptr.error_code = @intFromEnum(EvmError.EVM_OK);

    log(.info, .evm_c, "Execution completed: status={}, gas_used={}", .{ run_result.status, run_result.gas_used });
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