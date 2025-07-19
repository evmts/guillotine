const std = @import("std");
const constants = @import("constants.zig");

/// Memory implementation for EVM execution contexts.
pub const Memory = @This();

// Re-export error types and constants for convenience
pub const MemoryError = @import("errors.zig").MemoryError;
pub const INITIAL_CAPACITY = constants.INITIAL_CAPACITY;
pub const DEFAULT_MEMORY_LIMIT = constants.DEFAULT_MEMORY_LIMIT;
pub const calculate_num_words = constants.calculate_num_words;

// Core memory struct fields
// Frequently accessed fields placed first for better cache performance
my_checkpoint: usize,
memory_limit: u64,
owns_buffer: bool,

// Less frequently accessed fields
shared_buffer_ref: *std.ArrayList(u8),
allocator: std.mem.Allocator,

/// Initializes the root Memory context that owns the shared buffer.
/// This is the safe API that eliminates the undefined pointer footgun.
pub fn init(
    allocator: std.mem.Allocator,
    initial_capacity: usize,
    memory_limit: u64,
) !Memory {
    const shared_buffer = try allocator.create(std.ArrayList(u8));
    errdefer allocator.destroy(shared_buffer);
    
    shared_buffer.* = std.ArrayList(u8).init(allocator);
    errdefer shared_buffer.deinit();
    try shared_buffer.ensureTotalCapacity(initial_capacity);

    return Memory{
        .my_checkpoint = 0,
        .memory_limit = memory_limit,
        .owns_buffer = true,
        .shared_buffer_ref = shared_buffer,
        .allocator = allocator,
    };
}

/// Creates a child Memory that shares the buffer with a different checkpoint.
/// Child memory has a view of the shared buffer starting from its checkpoint.
pub fn init_child_memory(self: *Memory, checkpoint: usize) !Memory {
    return Memory{
        .my_checkpoint = checkpoint,
        .memory_limit = self.memory_limit,
        .owns_buffer = false,
        .shared_buffer_ref = self.shared_buffer_ref,
        .allocator = self.allocator,
    };
}

pub fn init_default(allocator: std.mem.Allocator) !Memory {
    return try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
}

/// Deinitializes the Memory. Only root Memory instances clean up the shared buffer.
pub fn deinit(self: *Memory) void {
    if (self.owns_buffer) {
        self.shared_buffer_ref.deinit();
        self.allocator.destroy(self.shared_buffer_ref);
    }
}

// Import and re-export all method implementations
const context_ops = @import("context.zig");
const read_ops = @import("read.zig");
const write_ops = @import("write.zig");
const slice_ops = @import("slice.zig");

// Context operations
pub const context_size = context_ops.context_size;
pub const ensure_context_capacity = context_ops.ensure_context_capacity;
pub const resize_context = context_ops.resize_context;
pub const size = context_ops.size;
pub const total_size = context_ops.total_size;

// Read operations
pub const get_u256 = read_ops.get_u256;
pub const get_slice = read_ops.get_slice;
pub const get_byte = read_ops.get_byte;

// Write operations
pub const set_data = write_ops.set_data;
pub const set_data_bounded = write_ops.set_data_bounded;
pub const set_u256 = write_ops.set_u256;

// Slice operations
pub const slice = slice_ops.slice;

// Fuzz testing functions
pub fn fuzz_memory_operations(allocator: std.mem.Allocator, operations: []const FuzzMemoryOperation) !void {
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    const testing = std.testing;
    
    for (operations) |op| {
        switch (op) {
            .set_data => |data_op| {
                const result = memory.set_data(data_op.offset, data_op.data);
                
                if (data_op.offset > memory.memory_limit or 
                    data_op.data.len > memory.memory_limit or
                    data_op.offset > memory.memory_limit - data_op.data.len) {
                    try testing.expectError(MemoryError.MemoryLimitExceeded, result);
                } else {
                    try result;
                    
                    // Verify the data was written correctly
                    const read_data = try memory.get_slice(data_op.offset, data_op.data.len);
                    try testing.expectEqualSlices(u8, data_op.data, read_data);
                }
            },
            .set_u256 => |u256_op| {
                const result = memory.set_u256(u256_op.offset, u256_op.value);
                
                if (u256_op.offset > memory.memory_limit or 
                    u256_op.offset > memory.memory_limit - 32) {
                    try testing.expectError(MemoryError.MemoryLimitExceeded, result);
                } else {
                    try result;
                    
                    // Verify the u256 was written correctly
                    const read_value = try memory.get_u256(u256_op.offset);
                    try testing.expectEqual(u256_op.value, read_value);
                }
            },
            .get_data => |get_op| {
                const result = memory.get_slice(get_op.offset, get_op.length);
                
                if (get_op.offset > memory.memory_limit or 
                    get_op.length > memory.memory_limit or
                    get_op.offset > memory.memory_limit - get_op.length) {
                    try testing.expectError(MemoryError.InvalidOffset, result);
                } else {
                    _ = try result;
                }
            },
            .resize => |new_size| {
                const result = memory.resize_context(new_size);
                
                if (new_size > memory.memory_limit) {
                    try testing.expectError(MemoryError.InvalidSize, result);
                } else {
                    try result;
                    try testing.expect(memory.context_size() >= new_size);
                }
            },
        }
        
        try validate_memory_invariants(&memory);
    }
}

const FuzzMemoryOperation = union(enum) {
    set_data: struct {
        offset: usize,
        data: []const u8,
    },
    set_u256: struct {
        offset: usize,
        value: u256,
    },
    get_data: struct {
        offset: usize,
        length: usize,
    },
    resize: usize,
};

fn validate_memory_invariants(memory: *const Memory) !void {
    const testing = std.testing;
    
    // Memory size should never exceed the limit
    try testing.expect(memory.context_size() <= memory.memory_limit);
    
    // Checkpoint should be valid
    try testing.expect(memory.my_checkpoint <= memory.shared_buffer_ref.items.len);
    
    // Buffer ownership should be consistent
    try testing.expect(memory.owns_buffer or memory.my_checkpoint > 0);
}

test "fuzz_memory_basic_operations" {
    const allocator = std.testing.allocator;
    const test_data = "Hello, World!";
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = 0, .data = test_data } },
        .{ .get_data = .{ .offset = 0, .length = test_data.len } },
        .{ .set_u256 = .{ .offset = 32, .value = 0x123456789ABCDEF } },
        .{ .get_data = .{ .offset = 32, .length = 32 } },
        .{ .resize = 128 },
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_boundary_conditions" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = 0, .data = "" } }, // Empty data
        .{ .set_u256 = .{ .offset = 0, .value = 0 } }, // Zero value
        .{ .set_u256 = .{ .offset = 0, .value = std.math.maxInt(u256) } }, // Max value
        .{ .get_data = .{ .offset = 0, .length = 0 } }, // Zero length read
        .{ .resize = 0 }, // Resize to zero
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_overflow_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzMemoryOperation{
        .{ .set_data = .{ .offset = std.math.maxInt(usize) - 10, .data = "overflow" } },
        .{ .set_u256 = .{ .offset = std.math.maxInt(usize) - 10, .value = 123 } },
        .{ .get_data = .{ .offset = std.math.maxInt(usize) - 10, .length = 100 } },
        .{ .resize = std.math.maxInt(usize) },
    };
    
    try fuzz_memory_operations(allocator, &operations);
}

test "fuzz_memory_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    var test_data_storage = std.ArrayList([]u8).init(allocator);
    defer {
        for (test_data_storage.items) |data| {
            allocator.free(data);
        }
        test_data_storage.deinit();
    }
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const op_type = random.intRangeAtMost(u8, 0, 3);
        
        switch (op_type) {
            0 => {
                const data_len = random.intRangeAtMost(usize, 0, 100);
                const data = try allocator.alloc(u8, data_len);
                random.bytes(data);
                try test_data_storage.append(data);
                
                const offset = random.intRangeAtMost(usize, 0, 1000);
                try operations.append(.{ .set_data = .{ .offset = offset, .data = data } });
            },
            1 => {
                const offset = random.intRangeAtMost(usize, 0, 1000);
                const value = random.int(u256);
                try operations.append(.{ .set_u256 = .{ .offset = offset, .value = value } });
            },
            2 => {
                const offset = random.intRangeAtMost(usize, 0, 1000);
                const length = random.intRangeAtMost(usize, 0, 100);
                try operations.append(.{ .get_data = .{ .offset = offset, .length = length } });
            },
            3 => {
                const new_size = random.intRangeAtMost(usize, 0, 2000);
                try operations.append(.{ .resize = new_size });
            },
            else => unreachable,
        }
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_edge_values" {
    const allocator = std.testing.allocator;
    
    const edge_values = [_]u256{
        0,
        1,
        std.math.maxInt(u8),
        std.math.maxInt(u16),
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        1 << 128,
        1 << 255,
    };
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    for (edge_values, 0..) |value, idx| {
        try operations.append(.{ .set_u256 = .{ .offset = idx * 32, .value = value } });
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_alignment_patterns" {
    const allocator = std.testing.allocator;
    
    var operations = std.ArrayList(FuzzMemoryOperation).init(allocator);
    defer operations.deinit();
    
    // Test various alignment patterns
    const alignments = [_]usize{ 1, 2, 4, 8, 16, 32, 64, 128, 256 };
    
    for (alignments) |alignment| {
        const offset = alignment;
        try operations.append(.{ .set_u256 = .{ .offset = offset, .value = 0xDEADBEEF } });
        try operations.append(.{ .get_data = .{ .offset = offset, .length = 32 } });
    }
    
    try fuzz_memory_operations(allocator, operations.items);
}

test "fuzz_memory_bounded_operations" {
    const allocator = std.testing.allocator;
    
    var memory = try init(allocator, INITIAL_CAPACITY, DEFAULT_MEMORY_LIMIT);
    defer memory.deinit();
    
    const source_data = "Hello, World! This is a test string for bounded operations.";
    
    // Test various bounded write scenarios
    const test_cases = [_]struct {
        memory_offset: usize,
        data_offset: usize,
        length: usize,
        should_succeed: bool,
    }{
        .{ .memory_offset = 0, .data_offset = 0, .length = 10, .should_succeed = true },
        .{ .memory_offset = 0, .data_offset = 50, .length = 20, .should_succeed = true }, // Partial copy
        .{ .memory_offset = 0, .data_offset = 100, .length = 10, .should_succeed = true }, // Zero fill
        .{ .memory_offset = 0, .data_offset = 0, .length = 0, .should_succeed = true }, // Empty
    };
    
    for (test_cases) |test_case| {
        const result = memory.set_data_bounded(
            test_case.memory_offset,
            source_data,
            test_case.data_offset,
            test_case.length,
        );
        
        if (test_case.should_succeed) {
            try result;
        } else {
            try std.testing.expectError(MemoryError.InvalidSize, result);
        }
    }
}
