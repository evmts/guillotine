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
const AllocationTier = @import("allocation_tier.zig").AllocationTier;
const tailcalls = @import("evm/tailcalls.zig");

// Maximum allowed tailcall iterations
const TAILCALL_MAX_ITERATIONS: usize = 10_000_000;

// Safety check constants
const SAFE_GAS_CHECK = builtin.mode != .ReleaseFast and builtin.mode != .ReleaseSmall;

/// Error types for StackFrame operations
pub const AccessError = error{OutOfMemory};
pub const StateError = error{OutOfMemory};

/// StackFrame owns all execution state for the tailcall interpreter
/// Fields are organized by access frequency for optimal cache usage
pub const StackFrame = struct {
    // HOT FIELDS - Cache Line 1 (64 bytes)
    // These fields are accessed on nearly every instruction
    ip: u16,                                        // 2 bytes + 2 padding
    gas_remaining: u32,                             // 4 bytes
    ops: []tailcalls.TailcallFunc,                 // 16 bytes (ptr + len)
    metadata: []u32,                                // 16 bytes (ptr + len)
    stack: Stack,                                   // 24 bytes (stack struct inline)
    // Total: ~62 bytes - fits in one cache line!
    
    // WARM FIELDS - Cache Line 2+ (less frequently accessed)
    memory: Memory,                                 // Memory operations
    analysis: SimpleAnalysis,                       // Jump validation
    
    // COLD FIELDS - Rarely accessed during normal execution
    host: Host,                                     // External calls only
    contract_address: primitives.Address.Address,   // Rarely needed
    state: DatabaseInterface,                       // Storage operations only
    allocator: std.mem.Allocator,                   // Memory expansion only
    
    // VERY COLD - Never accessed during execution
    static_buffer: []u8,                            // Setup/teardown only
    buffer_allocator: *std.heap.FixedBufferAllocator, // Setup/teardown only
    
    /// Total up-front allocation size for StackFrame
    /// This includes all the allocations needed by the frame:
    /// - Stack data: 1024 * 32 bytes = 32KB
    /// - Memory initial buffer: 4KB
    /// - SimpleAnalysis arrays: 256KB
    /// - Metadata array: 256KB
    /// - Ops array: ~512KB (assuming 8-byte pointers)
    /// Total: ~1060KB for worst case
    pub const UP_FRONT_ALLOCATION = Stack.UP_FRONT_ALLOCATION + 
                                     Memory.UP_FRONT_ALLOCATION + 
                                     @import("evm/analysis2.zig").SimpleAnalysis.UP_FRONT_ALLOCATION +
                                     @import("evm/analysis2.zig").METADATA_UP_FRONT_ALLOCATION +
                                     @import("evm/analysis2.zig").OPS_UP_FRONT_ALLOCATION;

    /// Initialize a StackFrame with required parameters (legacy method - will be deprecated)
    pub fn init(
        gas_remaining: u64,
        contract_address: primitives.Address.Address,
        analysis: SimpleAnalysis,
        metadata: []u32,
        ops: []tailcalls.TailcallFunc,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
    ) !StackFrame {
        // For compatibility, allocate a minimal buffer
        const buffer_size = 1024 * 1024; // 1MB
        const static_buffer = try allocator.alloc(u8, buffer_size);
        const fba_ptr = try allocator.create(std.heap.FixedBufferAllocator);
        fba_ptr.* = std.heap.FixedBufferAllocator.init(static_buffer);
        
        return StackFrame{
            // Hot fields first
            .ip = 0,
            .gas_remaining = @intCast(gas_remaining),
            .ops = ops,
            .metadata = metadata,
            .stack = try Stack.init(allocator),
            // Warm fields
            .memory = try Memory.init_default(allocator),
            .analysis = analysis,
            // Cold fields
            .host = host,
            .contract_address = contract_address,
            .state = state,
            .allocator = allocator,
            // Very cold fields
            .static_buffer = static_buffer,
            .buffer_allocator = fba_ptr,
        };
    }
    
    /// Initialize a StackFrame with tiered pre-allocation based on bytecode size
    pub fn init_with_bytecode_size(
        bytecode_size: usize,
        gas_remaining: u64,
        contract_address: primitives.Address.Address,
        host: Host,
        state: DatabaseInterface,
        allocator: std.mem.Allocator,
    ) !StackFrame {
        // Debug assertions for input validation
        std.debug.assert(bytecode_size > 0);
        std.debug.assert(gas_remaining <= std.math.maxInt(u32));
        
        // Select tier and allocate buffer
        const tier = AllocationTier.select_tier(bytecode_size);
        const buffer_size = tier.buffer_size();
        
        // Debug assertion: buffer size should be reasonable
        std.debug.assert(buffer_size > 0);
        std.debug.assert(buffer_size <= 2 * 1024 * 1024); // Max 2MB
        
        const static_buffer = try allocator.alloc(u8, buffer_size);
        errdefer allocator.free(static_buffer);
        
        const fba_ptr = try allocator.create(std.heap.FixedBufferAllocator);
        errdefer allocator.destroy(fba_ptr);
        fba_ptr.* = std.heap.FixedBufferAllocator.init(static_buffer);
        const fba_allocator = fba_ptr.allocator();
        
        // Pre-allocate stack from buffer
        const stack_alloc_info = Stack.calculate_allocation(bytecode_size);
        // We know stack alignment is always @alignOf(u256) = 32
        const stack_buffer = try fba_allocator.alignedAlloc(u8, @alignOf(u256), stack_alloc_info.size);
        const stack = try Stack.init_with_buffer(stack_buffer);
        
        // Memory uses heap allocator (can grow)
        const memory = try Memory.init_default(allocator);
        
        // Analysis, metadata, and ops will be filled by caller
        const empty_analysis = SimpleAnalysis{
            .inst_to_pc = &.{},
            .pc_to_inst = &.{},
            .bytecode = &.{},
        };
        
        return StackFrame{
            // Hot fields first
            .ip = 0,
            .gas_remaining = @intCast(gas_remaining),
            .ops = &.{},
            .metadata = &.{},
            .stack = stack,
            // Warm fields
            .memory = memory,
            .analysis = empty_analysis,
            // Cold fields
            .host = host,
            .contract_address = contract_address,
            .state = state,
            .allocator = allocator,
            // Very cold fields
            .static_buffer = static_buffer,
            .buffer_allocator = fba_ptr,
        };
    }

    pub fn deinit(self: *StackFrame) void {
        // Memory always uses heap allocator (can grow)
        self.memory.deinit();
        
        // Free the buffer allocator and static buffer
        if (self.static_buffer.len > 0) {
            self.allocator.destroy(self.buffer_allocator);
            self.allocator.free(self.static_buffer);
        }

        // NOTE: Stack is allocated from the static buffer when using init_with_bytecode_size,
        // so it gets freed with the buffer. For legacy init, it's freed separately.
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
        self.gas_remaining -= @intCast(amount);
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
    
    /// Get the buffer allocator for allocating analysis data
    /// This allows external code to allocate from the pre-allocated buffer
    pub fn get_buffer_allocator(self: *StackFrame) std.mem.Allocator {
        return self.buffer_allocator.allocator();
    }
};

// Compile-time assertions
comptime {
    if (@sizeOf(StackFrame) >= 2048) @compileError("StackFrame grew beyond expected budget");
    if (@alignOf(StackFrame) < @alignOf(*anyopaque)) @compileError("StackFrame alignment must be at least pointer alignment");
}
