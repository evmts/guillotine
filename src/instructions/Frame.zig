/// Minimal Frame implementation for shared instruction implementations
/// Phase 1.1 - Foundation for instruction merge
/// Phase 2.1 - Extended with context fields and memory
/// This Frame provides a minimal interface that instruction implementations can use
const std = @import("std");
const Stack = @import("Stack.zig");
const primitives = @import("primitives");
const Address = primitives.Address.Address;
const Hardfork = primitives.Hardfork;

const Self = @This();

/// Error set that includes all possible instruction errors
pub const Error = error{
    // Stack errors
    StackOverflow,
    StackUnderflow,
    AllocationError,
    // Bytecode errors
    InvalidPush,
    // Memory errors
    OutOfBounds,
    OutOfGas,
    // Phase 2+ errors
    InvalidOpcode,
    ReturnDataOutOfBounds,
};

/// The EVM stack
stack: Stack,

/// Bytecode (for PUSH operations and CODESIZE/CODECOPY)
/// Can be empty slice for frames that don't need bytecode access
bytecode: []const u8,

/// Program counter (for PUSH operations)
/// Instructions should NOT modify this - only used for reading immediate values
pc: u32,

/// Memory (sparse, byte-addressable)
/// Using AutoHashMap for simplicity - uninitialized bytes read as 0
memory: std.AutoHashMap(u32, u8),

/// Current memory size (word-aligned, in bytes)
memory_size: u32,

/// Execution context fields (Phase 2)
caller: Address,
address: Address,
value: u256,
calldata: []const u8,
return_data: []const u8,

/// Gas tracking (for dynamic gas calculations)
gas_remaining: i64,

/// Hardfork (for gas cost calculations)
hardfork: Hardfork,

/// Allocator (for memory operations)
allocator: std.mem.Allocator,

/// Stub: EVM state access (for BALANCE, EXTCODESIZE, etc.)
/// In real implementation, this would be *EvmType
evm_ptr: ?*anyopaque,

/// Initialize a minimal frame with an empty stack (Phase 1 compatibility)
pub fn init(allocator: std.mem.Allocator) Error!Self {
    const stack = try Stack.init(allocator);
    var memory = std.AutoHashMap(u32, u8).init(allocator);
    errdefer memory.deinit();

    return Self{
        .stack = stack,
        .bytecode = &[_]u8{},
        .pc = 0,
        .memory = memory,
        .memory_size = 0,
        .caller = Address.zero(),
        .address = Address.zero(),
        .value = 0,
        .calldata = &[_]u8{},
        .return_data = &[_]u8{},
        .gas_remaining = 0,
        .hardfork = .CANCUN,
        .allocator = allocator,
        .evm_ptr = null,
    };
}

/// Initialize a frame with bytecode (for PUSH operations)
pub fn initWithBytecode(allocator: std.mem.Allocator, bytecode: []const u8, pc: u32) Error!Self {
    const stack = try Stack.init(allocator);
    var memory = std.AutoHashMap(u32, u8).init(allocator);
    errdefer memory.deinit();

    return Self{
        .stack = stack,
        .bytecode = bytecode,
        .pc = pc,
        .memory = memory,
        .memory_size = 0,
        .caller = Address.zero(),
        .address = Address.zero(),
        .value = 0,
        .calldata = &[_]u8{},
        .return_data = &[_]u8{},
        .gas_remaining = 0,
        .hardfork = .CANCUN,
        .allocator = allocator,
        .evm_ptr = null,
    };
}

/// Initialize a full frame with all context (Phase 2+)
pub fn initFull(
    allocator: std.mem.Allocator,
    bytecode: []const u8,
    gas: i64,
    caller: Address,
    address: Address,
    value: u256,
    calldata: []const u8,
    hardfork: Hardfork,
) Error!Self {
    const stack = try Stack.init(allocator);
    var memory = std.AutoHashMap(u32, u8).init(allocator);
    errdefer memory.deinit();

    return Self{
        .stack = stack,
        .bytecode = bytecode,
        .pc = 0,
        .memory = memory,
        .memory_size = 0,
        .caller = caller,
        .address = address,
        .value = value,
        .calldata = calldata,
        .return_data = &[_]u8{},
        .gas_remaining = gas,
        .hardfork = hardfork,
        .allocator = allocator,
        .evm_ptr = null,
    };
}

/// Clean up frame resources
pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
    self.stack.deinit(allocator);
    self.memory.deinit();
}

/// Read immediate data for PUSH operations
/// Returns null if not enough bytes available
pub fn readImmediate(self: *const Self, size: u8) ?u256 {
    if (size == 0) return 0; // PUSH0
    const start = self.pc + 1; // Skip opcode byte
    const end = start + size;
    if (end > self.bytecode.len) return null; // Not enough bytes

    var value: u256 = 0;
    var i: usize = 0;
    while (i < size) : (i += 1) {
        value = (value << 8) | @as(u256, self.bytecode[start + i]);
    }
    return value;
}

/// -------------------------------- MEMORY OPERATIONS (Phase 2) --------------------------------

/// Helper: Calculate number of 32-byte words needed for size bytes
inline fn wordCount(bytes: u64) u64 {
    return (bytes + 31) / 32;
}

/// Helper: Calculate word-aligned memory size for EVM compliance
pub inline fn wordAlignedSize(bytes: u64) u32 {
    const words = wordCount(bytes);
    return @intCast(words * 32);
}

/// Helper: Safe add for u32 indices
inline fn add_u32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch return Error.OutOfBounds;
}

/// Read byte from memory (uninitialized bytes return 0)
pub fn readMemory(self: *Self, offset: u32) u8 {
    return self.memory.get(offset) orelse 0;
}

/// Write byte to memory (expands memory size if needed)
pub fn writeMemory(self: *Self, offset: u32, value: u8) Error!void {
    try self.memory.put(offset, value);
    // EVM memory expands to word-aligned (32-byte) boundaries
    const end_offset: u64 = @as(u64, offset) + 1;
    const word_aligned_size = wordAlignedSize(end_offset);
    if (word_aligned_size > self.memory_size) self.memory_size = word_aligned_size;
}

/// Calculate memory expansion cost
/// The total memory cost for n words is: 3n + n²/512, where a word is 32 bytes.
/// Returns the ADDITIONAL cost to expand from current size to end_bytes
pub fn memoryExpansionCost(self: *const Self, end_bytes: u64) u64 {
    const primitives_mod = @import("primitives");
    const GasConstants = primitives_mod.GasConstants;

    const current_size = @as(u64, self.memory_size);

    if (end_bytes <= current_size) return 0;

    // Cap memory size to prevent gas calculation overflow
    // Max reasonable memory is 16MB (0x1000000 bytes) which is ~500k words
    // At that size, gas cost would be ~125 billion, far exceeding any reasonable gas limit
    const max_memory: u64 = 0x1000000;
    // Return a large value that won't overflow when added to other gas costs
    // but will still trigger OutOfGas
    if (end_bytes > max_memory) return std.math.maxInt(u64);

    const current_words = wordCount(current_size);
    const new_words = wordCount(end_bytes);

    // Check for overflow in word * word calculation using saturating multiplication
    // If overflow would occur, return max gas to trigger OutOfGas
    const current_words_squared = std.math.mul(u64, current_words, current_words) catch return std.math.maxInt(u64);
    const new_words_squared = std.math.mul(u64, new_words, new_words) catch return std.math.maxInt(u64);

    // Calculate cost for each size with overflow protection
    const current_linear = std.math.mul(u64, GasConstants.MemoryGas, current_words) catch return std.math.maxInt(u64);
    const current_quadratic = current_words_squared / GasConstants.QuadCoeffDiv;
    const current_cost = std.math.add(u64, current_linear, current_quadratic) catch return std.math.maxInt(u64);

    const new_linear = std.math.mul(u64, GasConstants.MemoryGas, new_words) catch return std.math.maxInt(u64);
    const new_quadratic = new_words_squared / GasConstants.QuadCoeffDiv;
    const new_cost = std.math.add(u64, new_linear, new_quadratic) catch return std.math.maxInt(u64);

    return std.math.sub(u64, new_cost, current_cost) catch return std.math.maxInt(u64);
}

/// Consume gas (for dynamic gas in instructions)
pub fn consumeGas(self: *Self, amount: u64) Error!void {
    // Check if amount is too large to fit in i64 or exceeds remaining gas
    if (amount > std.math.maxInt(i64) or self.gas_remaining < @as(i64, @intCast(amount))) {
        self.gas_remaining = 0;
        return error.OutOfGas;
    }
    self.gas_remaining -= @intCast(amount);
}
