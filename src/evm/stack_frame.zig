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
    ip: u16,
    stack: Stack,
    gas_remaining: u64,
    ops: []*const fn (*StackFrame) ExecutionError.Error!noreturn,
    memory: Memory, // 32 bytes - struct with ArrayList
    host: Host, // 32 bytes - vtable pointer + context pointer
    state: DatabaseInterface, // 32 bytes - database interface
    analysis: SimpleAnalysis, // Contains all bucketed metadata arrays
    contract_address: primitives.Address.Address, // 20 bytes - only for storage ops
    is_static: bool, // Whether this frame is in STATICCALL read-only mode
    
    // Per-frame call context
    caller: primitives.Address.Address, // Address that initiated this call
    value: u256, // ETH value transferred with this call  
    input_buffer: []const u8, // Input data for this call
    output_buffer: []const u8, // Output data from this call

    /// Initialize a StackFrame with required parameters
    pub fn init(
        gas_remaining: u64,
        contract_address: primitives.Address.Address,
        analysis: SimpleAnalysis,
        ops: []*const fn (*StackFrame) ExecutionError.Error!noreturn,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
        is_static: bool,
        caller: primitives.Address.Address,
        value: u256,
        input_buffer: []const u8,
    ) !StackFrame {
        return StackFrame{
            .gas_remaining = gas_remaining,
            .stack = try Stack.init(allocator),
            .memory = try Memory.init_default(allocator),
            .analysis = analysis,
            .ops = ops,
            .ip = 0,
            .host = host,
            .contract_address = contract_address,
            .state = state,
            .is_static = is_static,
            .caller = caller,
            .value = value,
            .input_buffer = input_buffer,
            .output_buffer = &.{}, // Initially empty, set via operations
        };
    }

    pub fn deinit(self: *StackFrame, allocator: std.mem.Allocator) void {
        self.stack.deinit(allocator);
        self.memory.deinit();

        // NOTE: analysis and ops are managed by interpret2
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

    /// Address access for EIP-2929
    pub fn access_address(self: *StackFrame, addr: primitives.Address.Address) ExecutionError.Error!u64 {
        return self.host.access_address(addr) catch return ExecutionError.Error.OutOfMemory;
    }

    /// Set output data for RETURN/REVERT operations
    pub fn set_output(self: *StackFrame, data: []const u8) ExecutionError.Error!void {
        self.output_buffer = data;
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

    // Bucketed metadata access helpers
    const analysis2 = @import("evm/analysis2.zig");

    /// Get u16 metadata for current instruction
    pub fn get_u16_metadata(self: *const StackFrame) ?analysis2.U16Metadata {
        if (self.ip >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[self.ip];
        if (bucket_info.bucket == .u16_bucket and bucket_info.index < self.analysis.u16_bucket.len) {
            return self.analysis.u16_bucket[bucket_info.index];
        }
        return null;
    }

    /// Get u32 metadata for current instruction
    pub fn get_u32_metadata(self: *const StackFrame) ?analysis2.U32Metadata {
        if (self.ip >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[self.ip];
        if (bucket_info.bucket == .u32_bucket and bucket_info.index < self.analysis.u32_bucket.len) {
            return self.analysis.u32_bucket[bucket_info.index];
        }
        return null;
    }

    /// Get u64 metadata for current instruction
    pub fn get_u64_metadata(self: *const StackFrame) ?analysis2.U64Metadata {
        if (self.ip >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[self.ip];
        if (bucket_info.bucket == .u64_bucket and bucket_info.index < self.analysis.u64_bucket.len) {
            return self.analysis.u64_bucket[bucket_info.index];
        }
        return null;
    }

    /// Get u256 metadata for current instruction
    pub fn get_u256_metadata(self: *const StackFrame) ?analysis2.U256Metadata {
        if (self.ip >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[self.ip];
        if (bucket_info.bucket == .u256_bucket and bucket_info.index < self.analysis.u256_bucket.len) {
            return self.analysis.u256_bucket[bucket_info.index];
        }
        return null;
    }

    /// Get u64 metadata for specific instruction (used in fusion patterns)
    pub fn get_u64_metadata_at(self: *const StackFrame, inst_idx: u16) ?analysis2.U64Metadata {
        if (inst_idx >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[inst_idx];
        if (bucket_info.bucket == .u64_bucket and bucket_info.index < self.analysis.u64_bucket.len) {
            return self.analysis.u64_bucket[bucket_info.index];
        }
        return null;
    }

    /// Get u32 metadata for specific instruction (used in fusion patterns)
    pub fn get_u32_metadata_at(self: *const StackFrame, inst_idx: u16) ?analysis2.U32Metadata {
        if (inst_idx >= self.analysis.bucket_indices.len) return null;
        const bucket_info = self.analysis.bucket_indices[inst_idx];
        if (bucket_info.bucket == .u32_bucket and bucket_info.index < self.analysis.u32_bucket.len) {
            return self.analysis.u32_bucket[bucket_info.index];
        }
        return null;
    }
};

// Compile-time assertions
comptime {
    if (@sizeOf(StackFrame) >= 2048) @compileError("StackFrame grew beyond expected budget");
    if (@alignOf(StackFrame) < @alignOf(*anyopaque)) @compileError("StackFrame alignment must be at least pointer alignment");
}
