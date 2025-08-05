const std = @import("std");
const primitives = @import("primitives");
const Contract = @import("./contract.zig");
const ExecutionError = @import("../execution/execution_error.zig");
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const Context = @import("../access_list/context.zig");
const constants = @import("../memory/constants.zig");
const CodeAnalysis = @import("code_analysis.zig");

/// EVM execution frame representing a single call context with all state inlined.
///
/// This "fat struct" design consolidates all execution state (Stack, Memory, ReturnData, 
/// Contract fields, and Context) directly into the Frame structure for improved cache 
/// locality and reduced indirection.
///
/// ## Performance Benefits
/// - Better cache locality with all data in one struct
/// - Reduced pointer chasing
/// - Direct field access without method calls
/// - Simplified memory management with single allocation
///
/// ## Frame Hierarchy
/// Frames form a call stack during execution:
/// - External transactions create the root frame
/// - CALL/CREATE operations create child frames
/// - Frames are limited by maximum call depth (1024)
///
/// ## Execution Model
/// The frame tracks:
/// - Computational state (stack, memory, PC)
/// - Gas consumption and limits
/// - Input/output data
/// - Static call restrictions
/// - Contract context and code
/// - Block and transaction context
const Frame = @This();

// ============================================================================
// EXISTING FRAME FIELDS
// ============================================================================

// Hot fields (frequently accessed)
gas_remaining: u64 = 0,
pc: usize = 0,
allocator: std.mem.Allocator,

// Control flow fields
stop: bool = false,
is_static: bool = false,
depth: u32 = 0,
cost: u64 = 0,
err: ?ExecutionError.Error = null,

// Data fields
input: []const u8 = &[_]u8{},
output: []const u8 = &[_]u8{},
op: []const u8 = &.{},

// ============================================================================
// FIELDS FROM CONTRACT
// ============================================================================

// Identity and Context
address: primitives.Address.Address,
caller: primitives.Address.Address,
value: u256,

// Code and Analysis
code: []const u8,
code_hash: [32]u8,
code_size: u64,
analysis: ?*const CodeAnalysis,

// Gas Tracking (gas_refund only, gas merged with gas_remaining)
gas_refund: u64,

// Execution Flags
is_deployment: bool,
is_system_call: bool,

// Storage Access Tracking (EIP-2929)
storage_access: ?*std.AutoHashMap(u256, bool),
original_storage: ?*std.AutoHashMap(u256, u256),
is_cold: bool,

// Optimization Fields
has_jumpdests: bool,
is_empty: bool,

// ============================================================================
// FIELDS FROM STACK
// ============================================================================

stack_data: [1024]u256 align(@alignOf(u256)) = undefined,
stack_size: usize = 0,

// ============================================================================
// FIELDS FROM MEMORY
// ============================================================================

memory_checkpoint: usize,
memory_limit: u64,
memory_shared_buffer_ref: *std.ArrayList(u8),
memory_owns_buffer: bool,
memory_cached_expansion: struct {
    last_size: u64,
    last_cost: u64,
} = .{ .last_size = 0, .last_cost = 0 },

// ============================================================================
// FIELDS FROM RETURN DATA
// ============================================================================

return_data_buffer: std.ArrayList(u8),

// ============================================================================
// NEW CONTEXT FIELDS (IMMUTABLE)
// ============================================================================

// Block context - set once at frame creation, never modified
block_context: Context,

// Transaction context - simplified as part of Context
// The Context structure already contains tx_origin and gas_price

// ============================================================================
// INITIALIZATION
// ============================================================================

/// Create a new execution frame with all state inlined.
///
/// This is the primary initialization function that creates a frame with
/// all execution state consolidated into a single structure.
///
/// @param allocator Memory allocator for dynamic allocations
/// @param vm Virtual machine instance for state access
/// @param gas_limit Initial gas available for execution
/// @param contract Contract to execute (contains code, address, etc.)
/// @param caller Address of the calling account
/// @param input Call data for the execution
/// @param context Block and transaction context
/// @return New frame instance configured for execution
/// @throws OutOfMemory if memory initialization fails
pub fn init(
    allocator: std.mem.Allocator,
    vm: *Vm,
    gas_limit: u64,
    contract: *Contract,
    caller: primitives.Address.Address,
    input: []const u8,
    context: Context,
) !Frame {
    _ = vm; // Will be used for state access
    
    // Initialize memory buffer
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();
    try shared_buffer.ensureTotalCapacity(constants.INITIAL_CAPACITY);
    
    return Frame{
        // Frame fields
        .gas_remaining = gas_limit,
        .pc = 0,
        .allocator = allocator,
        .stop = false,
        .is_static = contract.is_static,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = input,
        .output = &[_]u8{},
        .op = &.{},
        
        // Contract fields
        .address = contract.address,
        .caller = caller,
        .value = contract.value,
        .code = contract.code,
        .code_hash = contract.code_hash,
        .code_size = contract.code_size,
        .analysis = contract.analysis,
        .gas_refund = contract.gas_refund,
        .is_deployment = contract.is_deployment,
        .is_system_call = contract.is_system_call,
        .storage_access = contract.storage_access,
        .original_storage = contract.original_storage,
        .is_cold = contract.is_cold,
        .has_jumpdests = contract.has_jumpdests,
        .is_empty = contract.is_empty,
        
        // Stack fields
        .stack_data = undefined,
        .stack_size = 0,
        
        // Memory fields
        .memory_checkpoint = 0,
        .memory_limit = constants.DEFAULT_MEMORY_LIMIT,
        .memory_shared_buffer_ref = shared_buffer,
        .memory_owns_buffer = true,
        
        // Return data fields
        .return_data_buffer = std.ArrayList(u8).init(allocator),
        
        // Context fields
        .block_context = context,
    };
}

/// Clean up frame resources.
///
/// Releases memory allocated by the frame. Must be called when
/// the frame is no longer needed to prevent memory leaks.
/// 
/// This version assumes no pool was used (most common case).
/// Use deinit_with_pool() if a storage pool was used.
pub fn deinit(self: *Frame) void {
    self.deinit_with_pool(null);
}

/// Clean up frame resources with optional storage pool.
///
/// Releases memory allocated by the frame. Must be called when
/// the frame is no longer needed to prevent memory leaks.
pub fn deinit_with_pool(self: *Frame, pool: ?*@import("storage_pool.zig")) void {
    // Clean up memory
    if (self.memory_owns_buffer) {
        self.memory_shared_buffer_ref.deinit();
        self.allocator.destroy(self.memory_shared_buffer_ref);
    }
    
    // Clean up return data
    self.return_data_buffer.deinit();
    
    // Clean up storage maps - they may be owned by this frame if no pool was used
    if (pool) |p| {
        if (self.storage_access) |map| {
            p.return_access_map(map);
        }
        if (self.original_storage) |map| {
            p.return_storage_map(map);
        }
    } else {
        if (self.storage_access) |map| {
            map.deinit();
            self.allocator.destroy(map);
        }
        if (self.original_storage) |map| {
            map.deinit();
            self.allocator.destroy(map);
        }
    }
}

// ============================================================================
// GAS OPERATIONS
// ============================================================================

/// Error type for gas consumption operations.
pub const ConsumeGasError = error{
    OutOfGas,
};

/// Consume gas from the frame's remaining gas.
///
/// Deducts the specified amount from gas_remaining. If insufficient
/// gas is available, returns OutOfGas error and execution should halt.
pub inline fn consume_gas(self: *Frame, amount: u64) ConsumeGasError!void {
    if (amount > self.gas_remaining) {
        @branchHint(.cold);
        return ConsumeGasError.OutOfGas;
    }
    self.gas_remaining -= amount;
}

// ============================================================================
// STACK OPERATIONS (to be implemented in stack_ops.zig)
// ============================================================================

// Stack method signatures - actual implementations will be in stack_ops.zig
pub usingnamespace @import("stack_ops.zig");

// ============================================================================
// MEMORY OPERATIONS (to be implemented in memory_ops.zig)
// ============================================================================

// Memory method signatures - actual implementations will be in memory_ops.zig
pub usingnamespace @import("memory_ops.zig");

// ============================================================================
// RETURN DATA OPERATIONS (to be implemented in return_data_ops.zig)
// ============================================================================

// Return data method signatures - actual implementations will be in return_data_ops.zig
pub usingnamespace @import("return_data_ops.zig");

// ============================================================================
// CONTRACT OPERATIONS (to be implemented in contract_ops.zig)
// ============================================================================

// Contract method signatures - actual implementations will be in contract_ops.zig
pub usingnamespace @import("contract_ops.zig");