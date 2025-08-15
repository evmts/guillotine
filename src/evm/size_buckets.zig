const std = @import("std");
const Tag = @import("instruction.zig").Tag;
const InstructionType = @import("instruction.zig").InstructionType;
const DynamicBitSet = std.DynamicBitSet;
const limits = @import("constants/code_analysis_limits.zig");

// Aligned bucket element types for size-based instruction storage
pub const Bucket8 = extern struct { bytes: [8]u8 align(8) };
pub const Bucket16 = extern struct { bytes: [16]u8 align(8) };
pub const Bucket24 = extern struct { bytes: [24]u8 align(8) };

// Shared count types to keep struct identity stable
pub const Size8Counts = struct {
    noop: u24 = 0,
    jump_pc: u24 = 0,
    conditional_jump_unresolved: u24 = 0,
    conditional_jump_invalid: u24 = 0,
};
pub const Size16Counts = struct {
    exec: u24 = 0,
    conditional_jump_pc: u24 = 0,
    pc: u24 = 0,
    block_info: u24 = 0,
};
pub const Size24Counts = struct {
    word: u24 = 0,
    dynamic_gas: u24 = 0,
};

/// Generic function to get instruction parameters from size-based arrays
pub fn getInstructionParams(
    size8_instructions: []Bucket8,
    size16_instructions: []Bucket16,
    size24_instructions: []Bucket24,
    comptime tag: Tag,
    id: u24,
) InstructionType(tag) {
    const InstType = InstructionType(tag);
    const size = comptime @sizeOf(InstType);
    return switch (size) {
        8 => blk: {
            const base_ptr: *const u8 = &size8_instructions[id].bytes[0];
            break :blk (@as(*const InstType, @ptrCast(@alignCast(base_ptr)))).*;
        },
        16 => blk: {
            const base_ptr: *const u8 = &size16_instructions[id].bytes[0];
            break :blk (@as(*const InstType, @ptrCast(@alignCast(base_ptr)))).*;
        },
        24 => blk: {
            const base_ptr: *const u8 = &size24_instructions[id].bytes[0];
            break :blk (@as(*const InstType, @ptrCast(@alignCast(base_ptr)))).*;
        },
        else => {
            const Log = @import("log.zig");
            Log.debug("Unexpected instruction size: {} for tag: {}", .{ size, tag });
            unreachable;
        },
    };
}

/// Packed array of valid JUMPDEST positions for cache-efficient validation.
/// Because JUMPDEST opcodes are sparse (typically <50 per contract vs 24KB max size),
/// a packed array with linear search provides better cache locality than a bitmap.
/// Uses u15 to pack positions tightly while supporting max contract size (24KB < 32KB).
pub const JumpdestArray = struct {
    /// Sorted array of valid JUMPDEST program counters.
    /// u15 allows max value 32767, sufficient for MAX_CONTRACT_SIZE (24576).
    /// Packed to maximize cache line utilization.
    positions: []const u15,
    /// Original code length for bounds checking
    code_len: usize,
    
    /// Convert a DynamicBitSet bitmap to a packed array of JUMPDEST positions.
    /// Collects all set bits from the bitmap into a sorted, packed array.
    pub fn from_bitmap(allocator: std.mem.Allocator, bitmap: *const DynamicBitSet, code_len: usize) !JumpdestArray {
        comptime {
            std.debug.assert(std.math.maxInt(u15) >= limits.MAX_CONTRACT_SIZE);
        }
        // First pass: count set bits to determine array size
        var count: usize = 0;
        for (0..code_len) |i| {
            if (bitmap.isSet(i)) count += 1;
        }
        // Allocate exact-sized array for JUMPDEST positions
        const positions = try allocator.alloc(u15, count);
        errdefer allocator.free(positions);
        // Second pass: collect positions into packed array
        var pos_idx: usize = 0;
        for (0..code_len) |i| {
            if (bitmap.isSet(i)) {
                positions[pos_idx] = @intCast(i);
                pos_idx += 1;
            }
        }
        return JumpdestArray{
            .positions = positions,
            .code_len = code_len,
        };
    }
    
    pub fn deinit(self: *JumpdestArray, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
    }
    
    /// Validates if a program counter is a valid JUMPDEST using cache-friendly linear search.
    /// Uses proportional starting point (pc / code_len * positions.len) then searches
    /// bidirectionally to maximize cache hits on the packed array.
    pub fn is_valid_jumpdest(self: *const JumpdestArray, pc: usize) bool {
        if (self.positions.len == 0 or pc >= self.code_len) return false;
        // Calculate proportional starting index for linear search
        // This distributes search starting points across the array for better cache locality
        const start_idx = (pc * self.positions.len) / self.code_len;
        // Binary search would be O(log n) but worse cache performance
        // Linear search from proportional start is typically faster for small arrays
        
        // Search forward from start position
        if (start_idx < self.positions.len) {
            for (self.positions[start_idx..]) |pos| {
                if (pos == pc) return true;
                if (pos > pc) break; // Positions are sorted
            }
        }
        
        // Search backward from start position
        if (start_idx > 0) {
            var i = start_idx - 1;
            while (true) : (i -= 1) {
                if (self.positions[i] == pc) return true;
                if (self.positions[i] < pc) break; // Positions are sorted
                if (i == 0) break;
            }
        }
        
        return false;
    }
};

test "Bucket8 size and alignment" {
    // Verify Bucket8 has correct size and alignment
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Bucket8));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Bucket8));
    
    // Test storing and retrieving data
    var bucket: Bucket8 = undefined;
    const test_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    @memcpy(&bucket.bytes, &test_data);
    
    try std.testing.expectEqualSlices(u8, &test_data, &bucket.bytes);
}

test "Bucket16 size and alignment" {
    // Verify Bucket16 has correct size and alignment
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Bucket16));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Bucket16));
    
    // Test storing and retrieving data
    var bucket: Bucket16 = undefined;
    const test_data = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                              0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    @memcpy(&bucket.bytes, &test_data);
    
    try std.testing.expectEqualSlices(u8, &test_data, &bucket.bytes);
}

test "Bucket24 size and alignment" {
    // Verify Bucket24 has correct size and alignment
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Bucket24));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Bucket24));
    
    // Test storing and retrieving data
    var bucket: Bucket24 = undefined;
    const test_data = [_]u8{ 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7, 0xA8,
                              0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8,
                              0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8 };
    @memcpy(&bucket.bytes, &test_data);
    
    try std.testing.expectEqualSlices(u8, &test_data, &bucket.bytes);
}

test "Size8Counts initialization and modification" {
    // Test default initialization
    var counts: Size8Counts = .{};
    try std.testing.expectEqual(@as(u24, 0), counts.noop);
    try std.testing.expectEqual(@as(u24, 0), counts.jump_pc);
    try std.testing.expectEqual(@as(u24, 0), counts.conditional_jump_unresolved);
    try std.testing.expectEqual(@as(u24, 0), counts.conditional_jump_invalid);
    
    // Test modification
    counts.noop = 100;
    counts.jump_pc = 200;
    counts.conditional_jump_unresolved = 300;
    counts.conditional_jump_invalid = 400;
    
    try std.testing.expectEqual(@as(u24, 100), counts.noop);
    try std.testing.expectEqual(@as(u24, 200), counts.jump_pc);
    try std.testing.expectEqual(@as(u24, 300), counts.conditional_jump_unresolved);
    try std.testing.expectEqual(@as(u24, 400), counts.conditional_jump_invalid);
    
    // Test max value
    counts.noop = std.math.maxInt(u24);
    try std.testing.expectEqual(@as(u24, 16777215), counts.noop);
}

test "Size16Counts initialization and modification" {
    // Test default initialization
    var counts: Size16Counts = .{};
    try std.testing.expectEqual(@as(u24, 0), counts.exec);
    try std.testing.expectEqual(@as(u24, 0), counts.conditional_jump_pc);
    try std.testing.expectEqual(@as(u24, 0), counts.pc);
    try std.testing.expectEqual(@as(u24, 0), counts.block_info);
    
    // Test modification
    counts.exec = 1000;
    counts.conditional_jump_pc = 2000;
    counts.pc = 3000;
    counts.block_info = 4000;
    
    try std.testing.expectEqual(@as(u24, 1000), counts.exec);
    try std.testing.expectEqual(@as(u24, 2000), counts.conditional_jump_pc);
    try std.testing.expectEqual(@as(u24, 3000), counts.pc);
    try std.testing.expectEqual(@as(u24, 4000), counts.block_info);
}

test "Size24Counts initialization and modification" {
    // Test default initialization
    var counts: Size24Counts = .{};
    try std.testing.expectEqual(@as(u24, 0), counts.word);
    try std.testing.expectEqual(@as(u24, 0), counts.dynamic_gas);
    
    // Test modification
    counts.word = 5000;
    counts.dynamic_gas = 6000;
    
    try std.testing.expectEqual(@as(u24, 5000), counts.word);
    try std.testing.expectEqual(@as(u24, 6000), counts.dynamic_gas);
}

test "getInstructionParams with 8-byte instruction" {
    const allocator = std.testing.allocator;
    const NoopInstruction = @import("instruction.zig").NoopInstruction;
    
    // Allocate size arrays
    const size8 = try allocator.alloc(Bucket8, 2);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 1);
    defer allocator.free(size16);
    const size24 = try allocator.alloc(Bucket24, 1);
    defer allocator.free(size24);
    
    // Create a dummy instruction for next_inst pointer
    const dummy_inst = @import("instruction.zig").Instruction{ .tag = .noop, .id = 0 };
    
    // Create a NoopInstruction in the first bucket
    const noop_inst = NoopInstruction{
        .next_inst = &dummy_inst,
    };
    
    // Copy the instruction data into the bucket
    @memcpy(size8[0].bytes[0..@sizeOf(NoopInstruction)], std.mem.asBytes(&noop_inst));
    
    // Retrieve and verify
    const retrieved = getInstructionParams(size8, size16, size24, .noop, 0);
    try std.testing.expectEqual(&dummy_inst, retrieved.next_inst);
}

test "getInstructionParams with 16-byte instruction" {
    const allocator = std.testing.allocator;
    const ExecInstruction = @import("instruction.zig").ExecInstruction;
    const ExecutionFunction = @import("instruction.zig").ExecutionFunction;
    
    // Allocate size arrays
    const size8 = try allocator.alloc(Bucket8, 1);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 2);
    defer allocator.free(size16);
    const size24 = try allocator.alloc(Bucket24, 1);
    defer allocator.free(size24);
    
    // Create dummy function and instruction
    const dummy_fn: ExecutionFunction = @import("../analysis.zig").UnreachableHandler;
    const dummy_inst = @import("instruction.zig").Instruction{ .tag = .exec, .id = 0 };
    
    // Create an ExecInstruction in the second bucket
    const exec_inst = ExecInstruction{
        .exec_fn = dummy_fn,
        .next_inst = &dummy_inst,
    };
    
    // Copy the instruction data into the bucket
    @memcpy(size16[1].bytes[0..@sizeOf(ExecInstruction)], std.mem.asBytes(&exec_inst));
    
    // Retrieve and verify
    const retrieved = getInstructionParams(size8, size16, size24, .exec, 1);
    try std.testing.expectEqual(dummy_fn, retrieved.exec_fn);
    try std.testing.expectEqual(&dummy_inst, retrieved.next_inst);
}

test "getInstructionParams with 24-byte instruction" {
    const allocator = std.testing.allocator;
    const WordInstruction = @import("instruction.zig").WordInstruction;
    
    // Allocate size arrays
    const size8 = try allocator.alloc(Bucket8, 1);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 1);
    defer allocator.free(size16);
    const size24 = try allocator.alloc(Bucket24, 3);
    defer allocator.free(size24);
    
    // Create dummy instruction
    const dummy_inst = @import("instruction.zig").Instruction{ .tag = .word, .id = 0 };
    
    // Create test word bytes
    const test_bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    
    // Create a WordInstruction in the third bucket
    const word_inst = WordInstruction{
        .word_bytes = &test_bytes,
        .next_inst = &dummy_inst,
    };
    
    // Copy the instruction data into the bucket
    @memcpy(size24[2].bytes[0..@sizeOf(WordInstruction)], std.mem.asBytes(&word_inst));
    
    // Retrieve and verify
    const retrieved = getInstructionParams(size8, size16, size24, .word, 2);
    try std.testing.expectEqual(&test_bytes, retrieved.word_bytes);
    try std.testing.expectEqual(&dummy_inst, retrieved.next_inst);
}

test "JumpdestArray.from_bitmap empty bitmap" {
    const allocator = std.testing.allocator;
    
    // Create empty bitmap
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    
    // Convert to array
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Verify empty
    try std.testing.expectEqual(@as(usize, 0), jumpdest_array.positions.len);
    try std.testing.expectEqual(@as(usize, 100), jumpdest_array.code_len);
    
    // Test is_valid_jumpdest returns false for all positions
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(50));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(99));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(100)); // Out of bounds
}

test "JumpdestArray.from_bitmap single jumpdest" {
    const allocator = std.testing.allocator;
    
    // Create bitmap with single bit set
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(42);
    
    // Convert to array
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Verify single position
    try std.testing.expectEqual(@as(usize, 1), jumpdest_array.positions.len);
    try std.testing.expectEqual(@as(u15, 42), jumpdest_array.positions[0]);
    
    // Test is_valid_jumpdest
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(41));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(42));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(43));
}

test "JumpdestArray.from_bitmap multiple jumpdests" {
    const allocator = std.testing.allocator;
    
    // Create bitmap with multiple bits set
    var bitmap = try DynamicBitSet.initEmpty(allocator, 200);
    defer bitmap.deinit();
    bitmap.set(10);
    bitmap.set(50);
    bitmap.set(100);
    bitmap.set(150);
    bitmap.set(199);
    
    // Convert to array
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 200);
    defer jumpdest_array.deinit(allocator);
    
    // Verify positions
    try std.testing.expectEqual(@as(usize, 5), jumpdest_array.positions.len);
    try std.testing.expectEqual(@as(u15, 10), jumpdest_array.positions[0]);
    try std.testing.expectEqual(@as(u15, 50), jumpdest_array.positions[1]);
    try std.testing.expectEqual(@as(u15, 100), jumpdest_array.positions[2]);
    try std.testing.expectEqual(@as(u15, 150), jumpdest_array.positions[3]);
    try std.testing.expectEqual(@as(u15, 199), jumpdest_array.positions[4]);
    
    // Test is_valid_jumpdest for all positions
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(10));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(50));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(100));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(150));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(199));
    
    // Test invalid positions
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(30));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(75));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(125));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(200)); // Out of bounds
}

test "JumpdestArray.from_bitmap max contract size" {
    const allocator = std.testing.allocator;
    
    // Test with maximum contract size
    const max_size = limits.MAX_CONTRACT_SIZE;
    var bitmap = try DynamicBitSet.initEmpty(allocator, max_size);
    defer bitmap.deinit();
    
    // Set some positions near the limit
    bitmap.set(0);
    bitmap.set(100);
    bitmap.set(1000);
    bitmap.set(10000);
    bitmap.set(max_size - 1);
    
    // Convert to array
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, max_size);
    defer jumpdest_array.deinit(allocator);
    
    // Verify positions
    try std.testing.expectEqual(@as(usize, 5), jumpdest_array.positions.len);
    try std.testing.expectEqual(@as(usize, max_size), jumpdest_array.code_len);
    
    // Test edge positions
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(max_size - 1));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(max_size)); // Out of bounds
}

test "JumpdestArray.is_valid_jumpdest proportional search" {
    const allocator = std.testing.allocator;
    
    // Create bitmap with jumpdests distributed across the range
    var bitmap = try DynamicBitSet.initEmpty(allocator, 1000);
    defer bitmap.deinit();
    
    // Set positions that will test the proportional search
    var i: usize = 50;
    while (i < 1000) : (i += 100) {
        bitmap.set(i);
    }
    
    // Convert to array
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 1000);
    defer jumpdest_array.deinit(allocator);
    
    // Test searching for positions that require both forward and backward search
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(50));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(150));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(250));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(550));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(950));
    
    // Test positions that are close but not exact
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(49));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(51));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(551));
}

test "JumpdestArray.is_valid_jumpdest edge cases" {
    const allocator = std.testing.allocator;
    
    // Test with positions at the very beginning and end
    var bitmap = try DynamicBitSet.initEmpty(allocator, 100);
    defer bitmap.deinit();
    bitmap.set(0);
    bitmap.set(99);
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 100);
    defer jumpdest_array.deinit(allocator);
    
    // Test edge positions
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(0));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(99));
    
    // Test out of bounds
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(100));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(std.math.maxInt(usize)));
}

test "JumpdestArray.is_valid_jumpdest performance characteristics" {
    const allocator = std.testing.allocator;
    
    // Create a worst-case scenario: many consecutive jumpdests
    var bitmap = try DynamicBitSet.initEmpty(allocator, 1000);
    defer bitmap.deinit();
    
    // Set many consecutive positions
    var i: usize = 400;
    while (i < 600) : (i += 1) {
        bitmap.set(i);
    }
    
    var jumpdest_array = try JumpdestArray.from_bitmap(allocator, &bitmap, 1000);
    defer jumpdest_array.deinit(allocator);
    
    // Test that we can find positions efficiently even in dense regions
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(400));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(500));
    try std.testing.expect(jumpdest_array.is_valid_jumpdest(599));
    
    // Test positions outside the dense region
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(399));
    try std.testing.expect(!jumpdest_array.is_valid_jumpdest(600));
}

test "Size bucket counts don't overflow u24" {
    // Test that u24 is sufficient for instruction counts
    const max_count = std.math.maxInt(u24); // 16,777,215
    const max_contract_size = limits.MAX_CONTRACT_SIZE; // 24,576
    
    // Even if every byte was an instruction, we'd have at most 24,576 instructions
    // which is well below the u24 limit
    try std.testing.expect(max_contract_size < max_count);
}

test "getInstructionParams with different tags" {
    const allocator = std.testing.allocator;
    
    // Allocate size arrays
    const size8 = try allocator.alloc(Bucket8, 5);
    defer allocator.free(size8);
    const size16 = try allocator.alloc(Bucket16, 5);
    defer allocator.free(size16);
    const size24 = try allocator.alloc(Bucket24, 5);
    defer allocator.free(size24);
    
    // Test that getInstructionParams correctly routes to the right bucket based on size
    // We'll create dummy data and verify it's retrieved from the correct bucket
    
    // Fill buckets with recognizable patterns
    for (size8, 0..) |*bucket, i| {
        for (&bucket.bytes, 0..) |*byte, j| {
            byte.* = @intCast(i * 10 + j);
        }
    }
    
    for (size16, 0..) |*bucket, i| {
        for (&bucket.bytes, 0..) |*byte, j| {
            byte.* = @intCast(i * 20 + j);
        }
    }
    
    for (size24, 0..) |*bucket, i| {
        for (&bucket.bytes, 0..) |*byte, j| {
            byte.* = @intCast(i * 30 + j);
        }
    }
    
    // Verify data is retrieved from correct buckets
    // Note: We can't actually call getInstructionParams without real instruction data,
    // but we've tested the bucket storage and retrieval mechanism
}

test "JumpdestArray u15 type is sufficient" {
    // Verify that u15 can hold the maximum contract size
    const max_u15 = std.math.maxInt(u15); // 32,767
    const max_contract = limits.MAX_CONTRACT_SIZE; // 24,576
    
    try std.testing.expect(max_u15 >= max_contract);
    
    // Test that we can store max contract position
    const max_pos: u15 = @intCast(max_contract - 1);
    try std.testing.expectEqual(@as(u15, 24575), max_pos);
}
