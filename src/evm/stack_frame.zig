//! Stack-based execution frame for tail-call interpreter
//!
//! This is a specialized frame for interpret2/tailcalls that owns all
//! execution state directly rather than using pointers. This improves
//! cache locality and eliminates indirection.

const std = @import("std");
const builtin = @import("builtin");
const primitives = @import("primitives");
const Stack = @import("stack/stack.zig");
const Memory = @import("memory/memory.zig");
const ExecutionError = @import("execution/execution_error.zig");
const Host = @import("root.zig").Host;
const DatabaseInterface = @import("state/database_interface.zig").DatabaseInterface;
const SimpleAnalysis = @import("evm/analysis2.zig").SimpleAnalysis;

// Maximum allowed tailcall iterations
const TAILCALL_MAX_ITERATIONS: usize = 10_000_000;

// Safety check constants
const SAFE_GAS_CHECK = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Error types for StackFrame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// StackFrame owns all execution state for the tailcall interpreter
pub const StackFrame = struct {
    // === HOT DATA - accessed every instruction ===
    gas_remaining: u64,
    stack: Stack,
    memory: Memory,
    host: Host,
    
    // === OWNED EXECUTION STATE ===
    analysis: SimpleAnalysis,  // Owned, not a pointer
    metadata: []u32,           // Owned metadata array
    ops: []*const anyopaque,   // Owned ops array
    ip: usize,                 // Instruction pointer
    
    // === DEPRECATED - TO BE MOVED TO HOST ===
    // TODO: Move to host interface - should be host.get_contract_address()
    contract_address: primitives.Address.Address,
    
    // TODO: Move to host interface - should be host.get_state()
    state: DatabaseInterface,
    
    // TODO: Don't know how to remove yet, but should find a way
    is_static: bool,
    
    // TODO: Move to host interface - should be host.get_caller()
    caller: primitives.Address.Address,
    
    // TODO: Move to host interface - should be host.get_value()
    value: u256,
    
    // TODO: Move to host interface - should be host.get_input()
    input_buffer: []const u8 = &.{},
    
    // TODO: Move to host interface - should be host.get_output()
    output_buffer: []const u8 = &.{},
    
    // Tailcall safety tracking
    tailcall_iterations: usize = 0,

    /// Initialize a StackFrame with required parameters
    pub fn init(
        gas_remaining: u64,
        static_call: bool,
        contract_address: primitives.Address.Address,
        caller: primitives.Address.Address,
        value: u256,
        analysis: SimpleAnalysis,
        metadata: []u32,
        ops: []*const anyopaque,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
    ) !StackFrame {
        return StackFrame{
            .gas_remaining = gas_remaining,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init_default(allocator),
            .analysis = analysis,
            .metadata = metadata,
            .ops = ops,
            .ip = 0,
            .is_static = static_call,
            .host = host,
            .caller = caller,
            .value = value,
            .input_buffer = &.{},
            .output_buffer = &.{},
            .contract_address = contract_address,
            .state = state,
        };
    }

    pub fn deinit(self: *StackFrame, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
        self.memory.deinit();
        
        // NOTE: analysis, metadata, and ops are managed by interpret2
        // which allocates them with its own FixedBufferAllocator and
        // frees them when it exits. We should NOT free them here.
    }

    /// Gas consumption with bounds checking
    pub fn consume_gas(self: *StackFrame, amount: u64) ExecutionError.Error!void {
        if (SAFE_GAS_CHECK) {
            if (self.gas_remaining < amount) {
                @branchHint(.cold);
                return ExecutionError.Error.OutOfGas;
            }
        }
        self.gas_remaining -= amount;
    }

    /// Check if we've exceeded maximum iterations
    pub fn check_iteration_limit(self: *StackFrame) ExecutionError.Error!void {
        self.tailcall_iterations += 1;
        if (self.tailcall_iterations > TAILCALL_MAX_ITERATIONS) {
            return ExecutionError.Error.OutOfGas; // Use OutOfGas as proxy for too many iterations
        }
    }

    /// Address access for EIP-2929
    pub fn access_address(self: *StackFrame, addr: primitives.Address.Address) ExecutionError.Error!u64 {
        return self.host.access_address(addr) catch return ExecutionError.Error.OutOfMemory;
    }

    /// Set output data for RETURN/REVERT operations
    pub fn set_output(self: *StackFrame, data: []const u8) ExecutionError.Error!void {
        self.host.set_output(data) catch {
            return ExecutionError.Error.OutOfMemory;
        };
    }

    /// Storage access operations
    pub fn get_storage(self: *const StackFrame, slot: u256) u256 {
        return self.state.get_storage(self.contract_address, slot) catch 0;
    }

    pub fn set_storage(self: *StackFrame, slot: u256, value: u256) !void {
        const original_value = self.state.get_storage(self.contract_address, slot) catch 0;
        if (original_value != value) {
            try self.host.record_storage_change(self.contract_address, slot, original_value);
        }
        try self.state.set_storage(self.contract_address, slot, value);
    }

    pub fn get_original_storage(self: *const StackFrame, slot: u256) u256 {
        if (self.host.get_original_storage(self.contract_address, slot)) |val| return val;
        return self.state.get_storage(self.contract_address, slot) catch 0;
    }

    pub fn get_transient_storage(self: *const StackFrame, slot: u256) u256 {
        return self.state.get_transient_storage(self.contract_address, slot) catch 0;
    }

    pub fn set_transient_storage(self: *StackFrame, slot: u256, value: u256) !void {
        try self.state.set_transient_storage(self.contract_address, slot, value);
    }

    /// Mark storage slot as warm and return true if it was cold
    pub fn mark_storage_slot_warm(self: *StackFrame, slot: u256) !bool {
        const gas_cost = try self.host.access_storage_slot(self.contract_address, slot);
        return gas_cost > 100;
    }

    /// Adjust gas refund for storage operations
    pub fn adjust_gas_refund(self: *StackFrame, delta: i64) void {
        const Evm = @import("evm.zig");
        const evm = @as(*Evm, @ptrCast(@alignCast(self.host.ptr)));
        evm.adjust_gas_refund(delta);
    }

    pub fn add_gas_refund(self: *StackFrame, amount: u64) void {
        self.adjust_gas_refund(@as(i64, @intCast(amount)));
    }
};

// Compile-time assertions
comptime {
    if (@sizeOf(StackFrame) >= 2048) @compileError("StackFrame grew beyond expected budget");
    if (@alignOf(StackFrame) < @alignOf(*anyopaque)) @compileError("StackFrame alignment must be at least pointer alignment");
}