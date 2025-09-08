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

// Simple inline logging that compiles out for freestanding WASM
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = level;
    _ = scope;
    _ = format;
    _ = args;
    // Logging disabled for WASM to avoid Thread dependencies
}

const DefaultEvm = evm_root.DefaultEvm;
const MemoryDatabase = evm_root.MemoryDatabase;
const CallParams = evm_root.CallParams;
const CallResult = evm_root.CallResult;
const Address = primitives.Address.Address;
const Frame = evm_root.Frame;
const FrameConfig = evm_root.FrameConfig;
const NoOpTracer = evm_root.NoOpTracer;

// Define a specific Frame type for C API use
const DefaultFrameConfig = FrameConfig{
    .stack_size = 1024,
    .has_database = false,
    .TracerType = NoOpTracer,
};
const DefaultFrame = Frame(DefaultFrameConfig);

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

// Frame API exports for direct frame manipulation
// These are separate from the main EVM API and allow low-level frame control


// Frame handle type
const FrameHandle = struct {
    frame: *DefaultFrame,
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    initial_gas: u64,
};

// Error codes for frame operations
const FrameError = enum(c_int) {
    FRAME_OK = 0,
    FRAME_ERROR_MEMORY = 1,
    FRAME_ERROR_INVALID_PARAM = 2,
    FRAME_ERROR_EXECUTION_FAILED = 3,
    FRAME_ERROR_STACK_OVERFLOW = 4,
    FRAME_ERROR_STACK_UNDERFLOW = 5,
    FRAME_ERROR_OUT_OF_GAS = 6,
};

/// Create a new frame for execution
/// @param bytecode_ptr Pointer to bytecode
/// @param bytecode_len Length of bytecode
/// @param initial_gas Initial gas amount
/// @return Pointer to frame handle or null on error
export fn evm_frame_create(bytecode_ptr: [*]const u8, bytecode_len: usize, initial_gas: u64) ?*anyopaque {
    if (bytecode_len == 0) return null;
    
    const bytecode = bytecode_ptr[0..bytecode_len];
    
    const handle = allocator.create(FrameHandle) catch return null;
    
    // Allocate and copy bytecode
    handle.bytecode = allocator.alloc(u8, bytecode_len) catch {
        allocator.destroy(handle);
        return null;
    };
    @memcpy(@constCast(handle.bytecode), bytecode);
    
    handle.initial_gas = initial_gas;
    
    // Create frame
    handle.frame = allocator.create(DefaultFrame) catch {
        allocator.free(handle.bytecode);
        allocator.destroy(handle);
        return null;
    };
    
    // Initialize frame (Frame doesn't have database when has_database = false)
    handle.frame.* = DefaultFrame.init(
        allocator,
        handle.bytecode,
        @intCast(initial_gas),
        {}, // void when has_database = false
        null // No host  
    ) catch {
        allocator.destroy(handle.frame);
        allocator.free(handle.bytecode);
        allocator.destroy(handle);
        return null;
    };
    
    handle.allocator = allocator;
    return @ptrCast(handle);
}

/// Destroy a frame
/// @param frame_ptr Pointer to frame handle
export fn evm_frame_destroy(frame_ptr: ?*anyopaque) void {
    if (frame_ptr) |ptr| {
        const handle: *FrameHandle = @ptrCast(@alignCast(ptr));
        
        // Deinit and destroy frame
        handle.frame.deinit(handle.allocator);
        handle.allocator.destroy(handle.frame);
        handle.allocator.free(handle.bytecode);
        handle.allocator.destroy(handle);
    }
}

/// Execute the frame until completion or error
/// @param frame_ptr Pointer to frame handle
/// @return Error code (0 = success)
export fn evm_frame_execute(frame_ptr: ?*anyopaque) c_int {
    if (frame_ptr == null) return @intFromEnum(FrameError.FRAME_ERROR_INVALID_PARAM);
    
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    // The Frame doesn't have a direct execute method in the new architecture
    // We would need to use a Planner and Plan to execute
    // For now, return error indicating execution is not implemented
    _ = frame;
    return @intFromEnum(FrameError.FRAME_ERROR_EXECUTION_FAILED);
}

/// Get remaining gas in the frame
/// @param frame_ptr Pointer to frame handle
/// @return Remaining gas amount
export fn evm_frame_get_gas_remaining(frame_ptr: ?*anyopaque) u64 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    return @intCast(@max(0, frame.gas_remaining));
}

/// Get used gas in the frame
/// @param frame_ptr Pointer to frame handle
/// @return Used gas amount
export fn evm_frame_get_gas_used(frame_ptr: ?*anyopaque) u64 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    // Calculate used gas from initial gas and remaining gas
    const remaining = @max(0, frame.gas_remaining);
    return handle.initial_gas - @as(u64, @intCast(remaining));
}

/// Get current program counter
/// @param frame_ptr Pointer to frame handle
/// @return Current PC value
export fn evm_frame_get_pc(frame_ptr: ?*anyopaque) u32 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    // Frame doesn't store PC in the new architecture
    // PC is managed by the Plan/Planner
    _ = handle;
    return 0; // TODO: Need to integrate with Plan for PC tracking
}

/// Get stack size
/// @param frame_ptr Pointer to frame handle
/// @return Number of items on the stack
export fn evm_frame_stack_size(frame_ptr: ?*anyopaque) u32 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    return @intCast(frame.stack.size());
}

/// Check if frame execution has stopped
/// @param frame_ptr Pointer to frame handle
/// @return 1 if stopped, 0 if running
export fn evm_frame_is_stopped(frame_ptr: ?*anyopaque) c_int {
    if (frame_ptr == null) return 1;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    // Frame doesn't have is_stopped field
    // Would need to track execution state separately
    _ = handle;
    return 0; // TODO: Track execution state
}

/// Get memory size
/// @param frame_ptr Pointer to frame handle
/// @return Current memory size in bytes
export fn evm_frame_get_memory_size(frame_ptr: ?*anyopaque) usize {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    return frame.memory.size();
}

/// Get bytecode length
/// @param frame_ptr Pointer to frame handle
/// @return Bytecode length
export fn evm_frame_get_bytecode_len(frame_ptr: ?*anyopaque) u32 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    return @intCast(handle.bytecode.len);
}

/// Get current opcode at PC
/// @param frame_ptr Pointer to frame handle  
/// @return Current opcode or 0 if invalid
export fn evm_frame_get_current_opcode(frame_ptr: ?*anyopaque) u8 {
    if (frame_ptr == null) return 0;
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    // Frame doesn't track PC, would need Plan integration
    _ = frame;
    return 0; // TODO: Integrate with Plan for opcode access
}

/// Reset frame with new gas
/// @param frame_ptr Pointer to frame handle
/// @param new_gas New gas amount
/// @return Error code (0 = success)
export fn evm_frame_reset(frame_ptr: ?*anyopaque, new_gas: u64) c_int {
    if (frame_ptr == null) return @intFromEnum(FrameError.FRAME_ERROR_INVALID_PARAM);
    
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    // Reset frame state
    // Reset stack by resetting the pointer to the base
    frame.stack.stack_ptr = frame.stack.stack_base;
    frame.memory.clear();
    frame.gas_remaining = @as(DefaultFrame.GasType, @intCast(new_gas));
    
    return @intFromEnum(FrameError.FRAME_OK);
}

/// Push a u64 value onto the stack
/// @param frame_ptr Pointer to frame handle
/// @param value Value to push
/// @return Error code (0 = success)
export fn evm_frame_push_u64(frame_ptr: ?*anyopaque, value: u64) c_int {
    if (frame_ptr == null) return @intFromEnum(FrameError.FRAME_ERROR_INVALID_PARAM);
    
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    frame.stack.push(@intCast(value)) catch {
        return @intFromEnum(FrameError.FRAME_ERROR_STACK_OVERFLOW);
    };
    
    return @intFromEnum(FrameError.FRAME_OK);
}

/// Pop a u64 value from the stack
/// @param frame_ptr Pointer to frame handle
/// @param value_out Pointer to store the popped value
/// @return Error code (0 = success)
export fn evm_frame_pop_u64(frame_ptr: ?*anyopaque, value_out: ?*u64) c_int {
    if (frame_ptr == null or value_out == null) return @intFromEnum(FrameError.FRAME_ERROR_INVALID_PARAM);
    
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    const value = frame.stack.pop() catch {
        return @intFromEnum(FrameError.FRAME_ERROR_STACK_UNDERFLOW);
    };
    
    value_out.?.* = @intCast(value);
    return @intFromEnum(FrameError.FRAME_OK);
}

/// Get memory data
/// @param frame_ptr Pointer to frame handle
/// @param offset Offset in memory
/// @param length Number of bytes to read
/// @param data_out Buffer to write data to
/// @return Error code (0 = success)
export fn evm_frame_get_memory(frame_ptr: ?*anyopaque, offset: u32, length: u32, data_out: ?[*]u8) c_int {
    if (frame_ptr == null or data_out == null) return @intFromEnum(FrameError.FRAME_ERROR_INVALID_PARAM);
    
    const handle: *FrameHandle = @ptrCast(@alignCast(frame_ptr.?));
    const frame = handle.frame;
    
    const slice = frame.memory.get_slice(@intCast(offset), @intCast(length)) catch {
        return @intFromEnum(FrameError.FRAME_ERROR_EXECUTION_FAILED);
    };
    
    const data_out_slice = data_out.?[0..length];
    @memcpy(data_out_slice, slice);
    return @intFromEnum(FrameError.FRAME_OK);
}

/// Create a debug frame with tracing enabled
/// @param bytecode_ptr Pointer to bytecode
/// @param bytecode_len Length of bytecode  
/// @param initial_gas Initial gas amount
/// @return Pointer to frame handle or null on error
export fn evm_debug_frame_create(bytecode_ptr: [*]const u8, bytecode_len: usize, initial_gas: u64) ?*anyopaque {
    // For now, just create a regular frame
    // TODO: Add debug/tracing support
    return evm_frame_create(bytecode_ptr, bytecode_len, initial_gas);
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