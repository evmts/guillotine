const std = @import("std");
const primitives = @import("primitives");
const ExecutionError = @import("../execution/execution_error.zig");
const Log = @import("../log.zig");
const Vm = @import("../evm.zig");
const Contract = @import("./contract.zig");
const Context = @import("../access_list/context.zig");

/// Fat frame structure with consolidated execution state for improved cache locality.
///
/// This structure combines Stack, Memory, ReturnData, and Contract fields directly
/// into the Frame to reduce pointer indirection and improve cache performance.
/// All frequently accessed fields are placed together for optimal memory layout.
///
/// ## Design Rationale
/// - Eliminates pointer chasing by embedding data structures
/// - Groups hot fields together for better cache utilization
/// - Maintains compatibility with existing operation interfaces
/// - Reduces memory allocations by consolidating buffers
///
/// ## Memory Layout
/// Fields are ordered by access frequency:
/// 1. Hot fields: gas, pc, stack operations
/// 2. Medium fields: memory operations, flags
/// 3. Cold fields: context, large buffers
pub const FrameFat = @This();

// Constants from original implementations
pub const STACK_CAPACITY: usize = 1024;
pub const INITIAL_MEMORY_CAPACITY: usize = 4096;
pub const DEFAULT_MEMORY_LIMIT: u64 = 0xFFFFFFFF;

// ===== Hot Fields (Most frequently accessed) =====

/// Remaining gas for execution
gas_remaining: u64,

/// Program counter (current position in bytecode)
pc: usize,

/// Stack size (number of elements currently on stack)
stack_size: usize,

/// Stack data buffer (inline array for zero indirection)
stack_data: [STACK_CAPACITY]u256 align(@alignOf(u256)) = undefined,

// ===== Medium Hot Fields =====

/// Memory size in bytes (for MSIZE opcode)
memory_size: usize,

/// Memory checkpoint for isolation
memory_checkpoint: usize,

/// Execution flags
stop: bool = false,
is_static: bool = false,
err: ?ExecutionError.Error = null,

/// Current operation cost
cost: u64 = 0,

/// Call depth
depth: u32 = 0,

// ===== Contract Fields (embedded) =====

/// Contract address
address: primitives.Address.Address,

/// Contract caller
caller: primitives.Address.Address,

/// Contract code
code: []const u8,

/// Code hash
code_hash: [32]u8,

/// Contract value
value: u256,

// ===== Context Fields (immutable during execution) =====

/// Block context (immutable during execution)
block_context: Context,

/// Transaction context
tx_origin: primitives.Address.Address,
gas_price: u256,

// ===== Input/Output Fields =====

/// Input data (calldata)
input: []const u8 = &[_]u8{},

/// Output buffer
output: []const u8 = &[_]u8{},

/// Current opcode (for debugging)
op: []const u8 = &.{},

// ===== Large Buffers (placed last) =====

/// Memory allocator
allocator: std.mem.Allocator,

/// Shared memory buffer reference
memory_buffer: *std.ArrayList(u8),

/// Return data buffer
return_data: std.ArrayList(u8),

/// Whether this frame owns the memory buffer
owns_memory: bool,

/// Initialize a new fat frame with all necessary state.
///
/// Creates a frame with consolidated execution state, ready for EVM execution.
/// This is the primary initialization method that sets up all embedded fields.
///
/// @param allocator Memory allocator for dynamic allocations
/// @param vm Virtual machine instance
/// @param gas_limit Initial gas for execution
/// @param contract Contract to execute
/// @param caller Calling address
/// @param input Call data
/// @return Initialized frame ready for execution
pub fn init(
    allocator: std.mem.Allocator,
    vm: *Vm,
    gas_limit: u64,
    contract: *Contract,
    caller: primitives.Address.Address,
    input: []const u8,
) !FrameFat {
    // Create memory buffer
    const memory_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(memory_buffer);
    
    memory_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer memory_buffer.deinit();
    try memory_buffer.ensureTotalCapacity(INITIAL_MEMORY_CAPACITY);

    return FrameFat{
        // Hot fields
        .gas_remaining = gas_limit,
        .pc = 0,
        .stack_size = 0,
        
        // Medium fields
        .memory_size = 0,
        .memory_checkpoint = 0,
        .depth = @intCast(vm.depth),
        
        // Contract fields
        .address = contract.address,
        .caller = caller,
        .code = contract.code,
        .code_hash = contract.code_hash,
        .value = contract.value,
        
        // Context fields
        .block_context = vm.context,
        .tx_origin = vm.context.tx_origin,
        .gas_price = vm.context.gas_price,
        
        // I/O fields
        .input = input,
        
        // Buffers
        .allocator = allocator,
        .memory_buffer = memory_buffer,
        .return_data = std.ArrayList(u8).init(allocator),
        .owns_memory = true,
    };
}

/// Create a child frame that shares the parent's memory buffer.
///
/// Used for CALL/DELEGATECALL operations to create nested execution contexts
/// that share memory allocation but have isolated views.
pub fn init_child(
    parent: *FrameFat,
    gas_limit: u64,
    contract: *Contract,
    caller: primitives.Address.Address,
    input: []const u8,
) !FrameFat {
    return FrameFat{
        // Hot fields
        .gas_remaining = gas_limit,
        .pc = 0,
        .stack_size = 0,
        
        // Medium fields
        .memory_size = 0,
        .memory_checkpoint = parent.memory_buffer.items.len,
        .depth = parent.depth + 1,
        
        // Contract fields
        .address = contract.address,
        .caller = caller,
        .code = contract.code,
        .code_hash = contract.code_hash,
        .value = contract.value,
        
        // Context fields (inherited from parent)
        .block_context = parent.block_context,
        .tx_origin = parent.tx_origin,
        .gas_price = parent.gas_price,
        
        // I/O fields
        .input = input,
        
        // Buffers (shared with parent)
        .allocator = parent.allocator,
        .memory_buffer = parent.memory_buffer,
        .return_data = std.ArrayList(u8).init(parent.allocator),
        .owns_memory = false,
    };
}

/// Clean up frame resources.
pub fn deinit(self: *FrameFat) void {
    self.return_data.deinit();
    
    if (self.owns_memory) {
        self.memory_buffer.deinit();
        self.allocator.destroy(self.memory_buffer);
    }
}

// ===== Tests =====

test "FrameFat initialization" {
    const allocator = std.testing.allocator;
    
    // Mock VM context
    const context = Context{
        .tx_origin = primitives.Address.ZERO_ADDRESS,
        .gas_price = 1000,
        .block_number = 100,
    };
    
    // Create minimal mock VM
    var vm = struct {
        depth: u16 = 0,
        context: Context,
    }{
        .context = context,
    };
    
    // Create test contract
    const code = [_]u8{ 0x60, 0x00, 0x60, 0x00 }; // PUSH1 0 PUSH1 0
    var contract = Contract{
        .address = primitives.Address.ZERO_ADDRESS,
        .code = &code,
        .code_hash = [_]u8{0} ** 32,
        .value = 0,
        .caller = primitives.Address.ZERO_ADDRESS,
        .call_type = .Call,
        .allocator = allocator,
        .accessed_storage_slots = null,
        .storage_pool = null,
        .gas_remaining = 0,
        .gas_refund_counter = 0,
        .last_opcode = 0,
        .is_static = false,
        .is_deployment = false,
    };
    
    var frame = try FrameFat.init(
        allocator,
        &vm,
        100000,
        &contract,
        primitives.Address.ZERO_ADDRESS,
        &[_]u8{},
    );
    defer frame.deinit();
    
    // Verify initialization
    try std.testing.expectEqual(@as(u64, 100000), frame.gas_remaining);
    try std.testing.expectEqual(@as(usize, 0), frame.pc);
    try std.testing.expectEqual(@as(usize, 0), frame.stack_size);
    try std.testing.expectEqual(@as(usize, 0), frame.memory_size);
    try std.testing.expectEqual(@as(u32, 0), frame.depth);
    try std.testing.expectEqual(false, frame.stop);
    try std.testing.expectEqual(false, frame.is_static);
}

test "FrameFat child frame initialization" {
    const allocator = std.testing.allocator;
    
    // Setup parent frame
    const context = Context{
        .tx_origin = primitives.Address.ZERO_ADDRESS,
        .gas_price = 1000,
        .block_number = 100,
    };
    
    var vm = struct {
        depth: u16 = 0,
        context: Context,
    }{
        .context = context,
    };
    
    const code = [_]u8{ 0x60, 0x00 };
    var contract = Contract{
        .address = primitives.Address.ZERO_ADDRESS,
        .code = &code,
        .code_hash = [_]u8{0} ** 32,
        .value = 0,
        .caller = primitives.Address.ZERO_ADDRESS,
        .call_type = .Call,
        .allocator = allocator,
        .accessed_storage_slots = null,
        .storage_pool = null,
        .gas_remaining = 0,
        .gas_refund_counter = 0,
        .last_opcode = 0,
        .is_static = false,
        .is_deployment = false,
    };
    
    var parent = try FrameFat.init(
        allocator,
        &vm,
        100000,
        &contract,
        primitives.Address.ZERO_ADDRESS,
        &[_]u8{},
    );
    defer parent.deinit();
    
    // Expand parent memory to test checkpoint
    try parent.memory_buffer.resize(1000);
    
    // Create child frame
    var child = try FrameFat.init_child(
        &parent,
        50000,
        &contract,
        primitives.Address.ZERO_ADDRESS,
        &[_]u8{},
    );
    defer child.deinit();
    
    // Verify child initialization
    try std.testing.expectEqual(@as(u64, 50000), child.gas_remaining);
    try std.testing.expectEqual(@as(u32, 1), child.depth);
    try std.testing.expectEqual(@as(usize, 1000), child.memory_checkpoint);
    try std.testing.expectEqual(parent.memory_buffer, child.memory_buffer);
    try std.testing.expectEqual(false, child.owns_memory);
}