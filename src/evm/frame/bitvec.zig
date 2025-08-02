const std = @import("std");
const opcode = @import("../opcodes/opcode.zig");
const tracy = @import("../tracy_support.zig");

// Default BitVec type using u64 for optimal performance on 64-bit systems
pub const BitVec64 = BitVec(u64);

/// Creates a generic BitVec type over any unsigned integer storage type
pub fn BitVec(comptime T: type) type {
    // Compile-time validation that T is an unsigned integer
    const info = @typeInfo(T);
    if (info != .int or info.int.signedness != .unsigned) {
        @compileError("BitVec storage type must be an unsigned integer, got: " ++ @typeName(T));
    }

    const bits_per_element = @bitSizeOf(T);

    return struct {
        const Self = @This();

        /// Bit array stored in T-sized chunks
        bits: []T,
        /// Total length in bits
        size: usize,
        /// Whether this bitvec owns its memory (and should free it)
        owned: bool,
        /// Cached raw pointer for optimized bit access
        cached_ptr: [*]T,

        /// Error types for BitVec operations
        pub const BitVecError = error{
            /// Position is out of bounds for the bit vector
            PositionOutOfBounds,
        };

        /// Error type for BitVec initialization
        pub const BitVecInitError = std.mem.Allocator.Error;

        /// Error type for code bitmap creation
        pub const CodeBitmapError = BitVecInitError;

        /// Create a new BitVec with the given size
        pub fn init(allocator: std.mem.Allocator, size: usize) BitVecInitError!Self {
            const element_count = (size + bits_per_element - 1) / bits_per_element; // Round up
            const bits = try allocator.alloc(T, element_count);
            errdefer allocator.free(bits);
            @memset(bits, 0); // Initialize all bits to 0
            return Self{
                .bits = bits,
                .size = size,
                .owned = true,
                .cached_ptr = bits.ptr,
            };
        }

        /// Create a BitVec from existing memory (not owned)
        pub fn fromMemory(bits: []T, size: usize) Self {
            return Self{
                .bits = bits,
                .size = size,
                .owned = false,
                .cached_ptr = bits.ptr,
            };
        }

        /// Free allocated memory if owned
        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            if (self.owned) {
                allocator.free(self.bits);
                self.bits = &.{};
                self.size = 0;
                self.cached_ptr = undefined;
            }
        }

        /// Set a bit at the given position
        pub fn set(self: *Self, pos: usize) BitVecError!void {
            if (pos >= self.size) return BitVecError.PositionOutOfBounds;
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            self.cached_ptr[idx] |= bit;
        }

        /// Set a bit at the given position without bounds checking
        pub fn setUnchecked(self: *Self, pos: usize) void {
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            self.cached_ptr[idx] |= bit;
        }

        /// Clear a bit at the given position
        pub fn clear(self: *Self, pos: usize) BitVecError!void {
            if (pos >= self.size) return BitVecError.PositionOutOfBounds;
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            self.cached_ptr[idx] &= ~bit;
        }

        /// Clear a bit at the given position without bounds checking
        pub fn clearUnchecked(self: *Self, pos: usize) void {
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            self.cached_ptr[idx] &= ~bit;
        }

        /// Check if a bit is set at the given position
        pub fn isSet(self: *const Self, pos: usize) BitVecError!bool {
            if (pos >= self.size) return BitVecError.PositionOutOfBounds;
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            return (self.cached_ptr[idx] & bit) != 0;
        }

        /// Check if a bit is set at the given position without bounds checking
        pub fn isSetUnchecked(self: *const Self, pos: usize) bool {
            const idx = pos / bits_per_element;
            const bit = @as(T, 1) << @intCast(pos % bits_per_element);
            return (self.cached_ptr[idx] & bit) != 0;
        }

        /// Check if the position represents a valid code segment
        pub fn codeSegment(self: *const Self, pos: usize) BitVecError!bool {
            return self.isSet(pos);
        }

        /// Check if the position represents a valid code segment without bounds checking
        pub fn codeSegmentUnchecked(self: *const Self, pos: usize) bool {
            return self.isSetUnchecked(pos);
        }

        /// Analyze bytecode to identify valid JUMPDEST locations and code segments
        pub fn codeBitmap(allocator: std.mem.Allocator, code: []const u8) CodeBitmapError!Self {
            const zone = tracy.zone(@src(), "code_bitmap\x00");
            defer zone.end();
            
            var bitmap = try Self.init(allocator, code.len);
            errdefer bitmap.deinit(allocator);

            // Mark all positions as valid code initially
            // Temporarily disable vectorized optimization to fix ARM64 issues
            // TODO: Re-enable with proper architecture detection
            for (0..code.len) |i| {
                bitmap.setUnchecked(i);
            }

            var i: usize = 0;
            while (i < code.len) {
                const op = code[i];

                // If the opcode is a PUSH, skip the pushed bytes
                if (opcode.is_push(op)) {
                    const push_bytes = opcode.get_push_size(op); // Get number of bytes to push

                    // Mark pushed bytes as data (not code)
                    var j: usize = 1;
                    while (j <= push_bytes and i + j < code.len) : (j += 1) {
                        bitmap.clearUnchecked(i + j);
                    }

                    // Skip the pushed bytes
                    if (i + push_bytes + 1 < code.len) {
                        i += push_bytes + 1;
                    } else {
                        i = code.len;
                    }
                } else {
                    i += 1;
                }
            }

            return bitmap;
        }
    };
}

/// Set a range of bits to 1 using vectorized operations
pub fn setRangeVectorized(self: *BitVec64, start: usize, end: usize) BitVec64.BitVecError!void {
    if (start >= self.size or end > self.size or start >= end) return BitVec64.BitVecError.PositionOutOfBounds;
    
    const startWord = start / 64;
    const endWord = (end - 1) / 64;
    const startBit = start % 64;
    const endBit = end % 64;
    
    // Handle single word case
    if (startWord == endWord) {
        const mask = ((~@as(u64, 0)) >> @intCast(64 - (end - start))) << @intCast(startBit);
        self.bits[startWord] |= mask;
        return;
    }
    
    // Set first partial word
    if (startBit != 0) {
        const mask = (~@as(u64, 0)) << @intCast(startBit);
        self.bits[startWord] |= mask;
    }
    
    // Process middle words - use vectorization only on x86_64
    const fullWordStart = if (startBit == 0) startWord else startWord + 1;
    const fullWordEnd = if (endBit == 0) endWord + 1 else endWord;
    
    if (fullWordStart < fullWordEnd) {
        const builtin = @import("builtin");
        if (comptime builtin.target.cpu.arch == .x86_64) {
            // Use @Vector optimization on x86_64
            const vectorSize = 8;
            const numFullWords = fullWordEnd - fullWordStart;
            const numVectors = numFullWords / vectorSize;
            
            // Process 8 words at a time
            var i: usize = 0;
            while (i < numVectors) : (i += 1) {
                const idx = fullWordStart + i * vectorSize;
                const vec: @Vector(vectorSize, u64) = @splat(~@as(u64, 0));
                const ptr: *[vectorSize]u64 = @ptrCast(self.bits[idx..idx + vectorSize]);
                const currentVec: @Vector(vectorSize, u64) = ptr.*;
                ptr.* = currentVec | vec;
            }
            
            // Process remaining words
            var j = fullWordStart + numVectors * vectorSize;
            while (j < fullWordEnd) : (j += 1) {
                self.bits[j] = ~@as(u64, 0);
            }
        } else {
            // Fallback to standard loop on other architectures
            var j = fullWordStart;
            while (j < fullWordEnd) : (j += 1) {
                self.bits[j] = ~@as(u64, 0);
            }
        }
    }
    
    // Set last partial word
    if (endBit != 0 and endWord < self.bits.len) {
        const mask = (~@as(u64, 0)) >> @intCast(64 - endBit);
        self.bits[endWord] |= mask;
    }
}

/// Count the number of set bits using vectorized operations
pub fn countSetBitsVectorized(self: *const BitVec64) usize {
    const vectorSize = 8;
    const numVectors = self.bits.len / vectorSize;
    var count: usize = 0;
    
    // Process 8 words at a time
    var i: usize = 0;
    while (i < numVectors) : (i += 1) {
        const idx = i * vectorSize;
        const ptr: *const [vectorSize]u64 = @ptrCast(self.bits[idx..idx + vectorSize]);
        const vec: @Vector(vectorSize, u64) = ptr.*;
        
        // Count bits in each element of the vector
        inline for (0..vectorSize) |j| {
            count += @popCount(vec[j]);
        }
    }
    
    // Process remaining words
    var j = numVectors * vectorSize;
    while (j < self.bits.len) : (j += 1) {
        count += @popCount(self.bits[j]);
    }
    
    return count;
}

/// Perform bitwise AND with another BitVec using vectorized operations
pub fn bitwiseAndVectorized(self: *BitVec64, other: *const BitVec64) BitVec64.BitVecError!void {
    if (self.size != other.size) return BitVec64.BitVecError.PositionOutOfBounds;
    
    const vectorSize = 8;
    const numVectors = self.bits.len / vectorSize;
    
    // Process 8 words at a time
    var i: usize = 0;
    while (i < numVectors) : (i += 1) {
        const idx = i * vectorSize;
        const selfPtr: *[vectorSize]u64 = @ptrCast(self.bits[idx..idx + vectorSize]);
        const otherPtr: *const [vectorSize]u64 = @ptrCast(other.bits[idx..idx + vectorSize]);
        const selfVec: @Vector(vectorSize, u64) = selfPtr.*;
        const otherVec: @Vector(vectorSize, u64) = otherPtr.*;
        selfPtr.* = selfVec & otherVec;
    }
    
    // Process remaining words
    var j = numVectors * vectorSize;
    while (j < self.bits.len) : (j += 1) {
        self.bits[j] &= other.bits[j];
    }
}

/// Perform bitwise OR with another BitVec using vectorized operations
pub fn bitwiseOrVectorized(self: *BitVec64, other: *const BitVec64) BitVec64.BitVecError!void {
    if (self.size != other.size) return BitVec64.BitVecError.PositionOutOfBounds;
    
    const vectorSize = 8;
    const numVectors = self.bits.len / vectorSize;
    
    // Process 8 words at a time
    var i: usize = 0;
    while (i < numVectors) : (i += 1) {
        const idx = i * vectorSize;
        const selfPtr: *[vectorSize]u64 = @ptrCast(self.bits[idx..idx + vectorSize]);
        const otherPtr: *const [vectorSize]u64 = @ptrCast(other.bits[idx..idx + vectorSize]);
        const selfVec: @Vector(vectorSize, u64) = selfPtr.*;
        const otherVec: @Vector(vectorSize, u64) = otherPtr.*;
        selfPtr.* = selfVec | otherVec;
    }
    
    // Process remaining words
    var j = numVectors * vectorSize;
    while (j < self.bits.len) : (j += 1) {
        self.bits[j] |= other.bits[j];
    }
}

/// Perform bitwise XOR with another BitVec using vectorized operations
pub fn bitwiseXorVectorized(self: *BitVec64, other: *const BitVec64) BitVec64.BitVecError!void {
    if (self.size != other.size) return BitVec64.BitVecError.PositionOutOfBounds;
    
    const vectorSize = 8;
    const numVectors = self.bits.len / vectorSize;
    
    // Process 8 words at a time
    var i: usize = 0;
    while (i < numVectors) : (i += 1) {
        const idx = i * vectorSize;
        const selfPtr: *[vectorSize]u64 = @ptrCast(self.bits[idx..idx + vectorSize]);
        const otherPtr: *const [vectorSize]u64 = @ptrCast(other.bits[idx..idx + vectorSize]);
        const selfVec: @Vector(vectorSize, u64) = selfPtr.*;
        const otherVec: @Vector(vectorSize, u64) = otherPtr.*;
        selfPtr.* = selfVec ^ otherVec;
    }
    
    // Process remaining words
    var j = numVectors * vectorSize;
    while (j < self.bits.len) : (j += 1) {
        self.bits[j] ^= other.bits[j];
    }
}

test "setRangeVectorized sets range of bits correctly" {
    const allocator = std.testing.allocator;
    
    // Test with large bit vector
    var bitvec = try BitVec64.init(allocator, 1024);
    defer bitvec.deinit(allocator);
    
    // Set range crossing multiple words
    try setRangeVectorized(&bitvec, 100, 900);
    
    // Verify bits before range are unset
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expect(!bitvec.isSetUnchecked(i));
    }
    
    // Verify bits in range are set
    i = 100;
    while (i < 900) : (i += 1) {
        try std.testing.expect(bitvec.isSetUnchecked(i));
    }
    
    // Verify bits after range are unset
    i = 900;
    while (i < 1024) : (i += 1) {
        try std.testing.expect(!bitvec.isSetUnchecked(i));
    }
}

test "setRangeVectorized handles single word case" {
    const allocator = std.testing.allocator;
    
    var bitvec = try BitVec64.init(allocator, 128);
    defer bitvec.deinit(allocator);
    
    // Set range within single word
    try setRangeVectorized(&bitvec, 10, 20);
    
    // Verify only specified bits are set
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try std.testing.expect(!bitvec.isSetUnchecked(i));
    }
    
    i = 10;
    while (i < 20) : (i += 1) {
        try std.testing.expect(bitvec.isSetUnchecked(i));
    }
    
    i = 20;
    while (i < 128) : (i += 1) {
        try std.testing.expect(!bitvec.isSetUnchecked(i));
    }
}

test "countSetBitsVectorized counts correctly" {
    const allocator = std.testing.allocator;
    
    // Test with large bit vector
    var bitvec = try BitVec64.init(allocator, 1024);
    defer bitvec.deinit(allocator);
    
    // Set specific pattern of bits
    var i: usize = 0;
    while (i < 1024) : (i += 3) {
        bitvec.setUnchecked(i);
    }
    
    const count = countSetBitsVectorized(&bitvec);
    try std.testing.expectEqual(@as(usize, 342), count); // ceil(1024/3) = 342
}

test "bitwiseAndVectorized performs AND correctly" {
    const allocator = std.testing.allocator;
    
    var bitvec1 = try BitVec64.init(allocator, 512);
    defer bitvec1.deinit(allocator);
    
    var bitvec2 = try BitVec64.init(allocator, 512);
    defer bitvec2.deinit(allocator);
    
    // Set alternating patterns
    var i: usize = 0;
    while (i < 512) : (i += 2) {
        bitvec1.setUnchecked(i);
    }
    
    i = 0;
    while (i < 512) : (i += 3) {
        bitvec2.setUnchecked(i);
    }
    
    try bitwiseAndVectorized(&bitvec1, &bitvec2);
    
    // Check result: bits should be set only where both were set
    i = 0;
    while (i < 512) : (i += 1) {
        const shouldBeSet = (i % 2 == 0) and (i % 3 == 0);
        try std.testing.expectEqual(shouldBeSet, bitvec1.isSetUnchecked(i));
    }
}

test "bitwiseOrVectorized performs OR correctly" {
    const allocator = std.testing.allocator;
    
    var bitvec1 = try BitVec64.init(allocator, 512);
    defer bitvec1.deinit(allocator);
    
    var bitvec2 = try BitVec64.init(allocator, 512);
    defer bitvec2.deinit(allocator);
    
    // Set different patterns
    var i: usize = 0;
    while (i < 512) : (i += 4) {
        bitvec1.setUnchecked(i);
    }
    
    i = 1;
    while (i < 512) : (i += 4) {
        bitvec2.setUnchecked(i);
    }
    
    try bitwiseOrVectorized(&bitvec1, &bitvec2);
    
    // Check result: bits should be set where either was set
    i = 0;
    while (i < 512) : (i += 1) {
        const shouldBeSet = (i % 4 == 0) or (i % 4 == 1);
        try std.testing.expectEqual(shouldBeSet, bitvec1.isSetUnchecked(i));
    }
}

test "bitwiseXorVectorized performs XOR correctly" {
    const allocator = std.testing.allocator;
    
    var bitvec1 = try BitVec64.init(allocator, 512);
    defer bitvec1.deinit(allocator);
    
    var bitvec2 = try BitVec64.init(allocator, 512);
    defer bitvec2.deinit(allocator);
    
    // Set overlapping patterns
    var i: usize = 0;
    while (i < 512) : (i += 2) {
        bitvec1.setUnchecked(i);
    }
    
    i = 0;
    while (i < 512) : (i += 3) {
        bitvec2.setUnchecked(i);
    }
    
    try bitwiseXorVectorized(&bitvec1, &bitvec2);
    
    // Check result: bits should be set where exactly one was set
    i = 0;
    while (i < 512) : (i += 1) {
        const was1Set = (i % 2 == 0);
        const was2Set = (i % 3 == 0);
        const shouldBeSet = was1Set != was2Set; // XOR logic
        try std.testing.expectEqual(shouldBeSet, bitvec1.isSetUnchecked(i));
    }
}

test "vectorized operations handle non-aligned sizes" {
    const allocator = std.testing.allocator;
    
    // Test with size not divisible by 8*64
    var bitvec = try BitVec64.init(allocator, 777);
    defer bitvec.deinit(allocator);
    
    try setRangeVectorized(&bitvec, 0, 777);
    
    const count = countSetBitsVectorized(&bitvec);
    try std.testing.expectEqual(@as(usize, 777), count);
}

test "vectorized operations handle edge cases" {
    const allocator = std.testing.allocator;
    
    // Small bitvec (less than vector size)
    var small = try BitVec64.init(allocator, 100);
    defer small.deinit(allocator);
    
    try setRangeVectorized(&small, 20, 80);
    
    const count = countSetBitsVectorized(&small);
    try std.testing.expectEqual(@as(usize, 60), count);
    
    // Test error cases
    try std.testing.expectError(BitVec64.BitVecError.PositionOutOfBounds, setRangeVectorized(&small, 50, 150));
    try std.testing.expectError(BitVec64.BitVecError.PositionOutOfBounds, setRangeVectorized(&small, 80, 20));
}

// Tests
test "BitVec with u8 storage" {
    const allocator = std.testing.allocator;
    const BitVec8 = BitVec(u8);
    
    var bv = try BitVec8.init(allocator, 16);
    defer bv.deinit(allocator);

    try bv.set(0);
    try bv.set(7);
    try bv.set(8);
    try bv.set(15);

    try std.testing.expect(try bv.isSet(0));
    try std.testing.expect(try bv.isSet(7));
    try std.testing.expect(try bv.isSet(8));
    try std.testing.expect(try bv.isSet(15));
    try std.testing.expect(!try bv.isSet(1));
    try std.testing.expect(!try bv.isSet(14));
}

test "BitVec with u16 storage" {
    const allocator = std.testing.allocator;
    const BitVec16 = BitVec(u16);
    
    var bv = try BitVec16.init(allocator, 32);
    defer bv.deinit(allocator);

    try bv.set(0);
    try bv.set(15);
    try bv.set(16);
    try bv.set(31);

    try std.testing.expect(try bv.isSet(0));
    try std.testing.expect(try bv.isSet(15));
    try std.testing.expect(try bv.isSet(16));
    try std.testing.expect(try bv.isSet(31));
    try std.testing.expect(!try bv.isSet(1));
    try std.testing.expect(!try bv.isSet(30));
}

test "BitVec with u32 storage" {
    const allocator = std.testing.allocator;
    const BitVec32 = BitVec(u32);
    
    var bv = try BitVec32.init(allocator, 64);
    defer bv.deinit(allocator);

    try bv.set(0);
    try bv.set(31);
    try bv.set(32);
    try bv.set(63);

    try std.testing.expect(try bv.isSet(0));
    try std.testing.expect(try bv.isSet(31));
    try std.testing.expect(try bv.isSet(32));
    try std.testing.expect(try bv.isSet(63));
    try std.testing.expect(!try bv.isSet(1));
    try std.testing.expect(!try bv.isSet(62));
}

test "BitVec with u64 storage" {
    const allocator = std.testing.allocator;
    const BitVec64Local = BitVec(u64);
    
    var bv = try BitVec64Local.init(allocator, 128);
    defer bv.deinit(allocator);

    try bv.set(0);
    try bv.set(63);
    try bv.set(64);
    try bv.set(127);

    try std.testing.expect(try bv.isSet(0));
    try std.testing.expect(try bv.isSet(63));
    try std.testing.expect(try bv.isSet(64));
    try std.testing.expect(try bv.isSet(127));
    try std.testing.expect(!try bv.isSet(1));
    try std.testing.expect(!try bv.isSet(126));
}

test "BitVec clear functionality" {
    const allocator = std.testing.allocator;
    const BitVec32 = BitVec(u32);
    
    var bv = try BitVec32.init(allocator, 64);
    defer bv.deinit(allocator);

    try bv.set(10);
    try bv.set(20);
    try bv.set(40);

    try std.testing.expect(try bv.isSet(10));
    try std.testing.expect(try bv.isSet(20));
    try std.testing.expect(try bv.isSet(40));

    try bv.clear(20);
    try std.testing.expect(try bv.isSet(10));
    try std.testing.expect(!try bv.isSet(20));
    try std.testing.expect(try bv.isSet(40));
}

test "BitVec bounds checking" {
    const allocator = std.testing.allocator;
    const BitVec16 = BitVec(u16);
    
    var bv = try BitVec16.init(allocator, 32);
    defer bv.deinit(allocator);

    // These should succeed
    try bv.set(0);
    try bv.set(31);

    // These should fail with PositionOutOfBounds
    try std.testing.expectError(BitVec16.BitVecError.PositionOutOfBounds, bv.set(32));
    try std.testing.expectError(BitVec16.BitVecError.PositionOutOfBounds, bv.clear(100));
    try std.testing.expectError(BitVec16.BitVecError.PositionOutOfBounds, bv.isSet(32));
}

test "BitVec codeBitmap with different storage types" {
    const allocator = std.testing.allocator;
    
    // Test with u32 storage
    {
        const BitVec32 = BitVec(u32);
        const code = &[_]u8{ 0x60, 0x10, 0x60, 0x20, 0x01 }; // PUSH1 0x10 PUSH1 0x20 ADD
        var bitmap = try BitVec32.codeBitmap(allocator, code);
        defer bitmap.deinit(allocator);

        try std.testing.expect(try bitmap.isSet(0)); // PUSH1
        try std.testing.expect(!try bitmap.isSet(1)); // 0x10 (data)
        try std.testing.expect(try bitmap.isSet(2)); // PUSH1
        try std.testing.expect(!try bitmap.isSet(3)); // 0x20 (data)
        try std.testing.expect(try bitmap.isSet(4)); // ADD
    }
    
    // Test with u64 storage
    {
        const code = &[_]u8{ 0x60, 0x10, 0x60, 0x20, 0x01 }; // PUSH1 0x10 PUSH1 0x20 ADD
        var bitmap = try BitVec64.codeBitmap(allocator, code);
        defer bitmap.deinit(allocator);

        try std.testing.expect(try bitmap.isSet(0)); // PUSH1
        try std.testing.expect(!try bitmap.isSet(1)); // 0x10 (data)
        try std.testing.expect(try bitmap.isSet(2)); // PUSH1
        try std.testing.expect(!try bitmap.isSet(3)); // 0x20 (data)
        try std.testing.expect(try bitmap.isSet(4)); // ADD
    }
}

test "BitVec fromMemory" {
    const BitVec32 = BitVec(u32);
    var storage = [_]u32{ 0b1010, 0b1100 };
    
    var bv = BitVec32.fromMemory(&storage, 64);
    // No defer needed since memory is not owned

    try std.testing.expect(bv.isSetUnchecked(1));
    try std.testing.expect(!bv.isSetUnchecked(0));
    try std.testing.expect(bv.isSetUnchecked(3));
    try std.testing.expect(!bv.isSetUnchecked(2));

    try std.testing.expect(bv.isSetUnchecked(34)); // bit 2 of second element
    try std.testing.expect(bv.isSetUnchecked(35)); // bit 3 of second element
}

test "BitVec compilation error for signed integers" {
    // This would cause a compile error if uncommented:
    // const BadBitVec = BitVec(i32);
}

test "BitVec compilation error for non-integer types" {
    // This would cause a compile error if uncommented:
    // const BadBitVec = BitVec(f32);
    // const BadBitVec2 = BitVec(bool);
}
