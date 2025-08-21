const std = @import("std");
const builtin = @import("builtin");

pub const MemoryConfig = struct {
    const Self = @This();
    
    // The initial capacity for memory allocation
    initial_capacity: usize = 4096,
    // The maximum memory limit
    memory_limit: u64 = 0xFFFFFF,
    
    fn validate(self: Self) void {
        if (self.memory_limit > std.math.maxInt(u32)) @compileError("memory_limit cannot exceed u32 max");
        if (self.initial_capacity > self.memory_limit) @compileError("initial_capacity cannot exceed memory_limit");
    }
};

pub const MemoryError = error{
    OutOfMemory,
    MemoryOverflow,
    OutOfBounds,
};

// Factory function to create Memory type
pub fn createMemory(comptime config: MemoryConfig) type {
    config.validate();
    
    const initial_capacity = config.initial_capacity;
    const memory_limit = config.memory_limit;
    
    return struct {
        const Self = @This();
        
        // Memory configuration
        pub const INITIAL_CAPACITY = initial_capacity;
        pub const MEMORY_LIMIT = memory_limit;
        
        // Core fields
        checkpoint: usize,
        buffer_ptr: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        owns_buffer: bool,
        
        // Cache for gas calculations
        cached_expansion: struct {
            last_size: u64,
            last_words: u64,
            last_cost: u64,
        } = .{ .last_size = 0, .last_words = 0, .last_cost = 0 },
        
        pub fn init(allocator: std.mem.Allocator) !Self {
            const buffer_ptr = try allocator.create(std.ArrayList(u8));
            errdefer allocator.destroy(buffer_ptr);
            
            buffer_ptr.* = std.ArrayList(u8).init(allocator);
            errdefer buffer_ptr.deinit();
            
            try buffer_ptr.ensureTotalCapacity(INITIAL_CAPACITY);
            
            return Self{
                .checkpoint = 0,
                .buffer_ptr = buffer_ptr,
                .allocator = allocator,
                .owns_buffer = true,
            };
        }
        
        pub fn init_borrowed(allocator: std.mem.Allocator, buffer_ptr: *std.ArrayList(u8), checkpoint: usize) !Self {
            return Self{
                .checkpoint = checkpoint,
                .buffer_ptr = buffer_ptr,
                .allocator = allocator,
                .owns_buffer = false,
            };
        }
        
        pub fn deinit(self: *Self) void {
            if (self.owns_buffer) {
                self.buffer_ptr.deinit();
                self.allocator.destroy(self.buffer_ptr);
            }
        }
        
        pub fn size(self: *const Self) usize {
            const total = self.buffer_ptr.items.len;
            if (total <= self.checkpoint) return 0;
            return total - self.checkpoint;
        }
        
        pub fn ensure_capacity(self: *Self, new_size: usize) !void {
            const required_total = self.checkpoint + new_size;
            
            if (required_total > MEMORY_LIMIT) {
                return MemoryError.MemoryOverflow;
            }
            
            if (required_total > self.buffer_ptr.items.len) {
                // Expand buffer with zeros
                const old_len = self.buffer_ptr.items.len;
                try self.buffer_ptr.resize(required_total);
                // Zero initialize new memory
                @memset(self.buffer_ptr.items[old_len..], 0);
            }
        }
        
        pub fn get_slice(self: *const Self, offset: usize, len: usize) MemoryError![]const u8 {
            const end = offset + len;
            if (end > self.size()) {
                return MemoryError.OutOfBounds;
            }
            
            const start_idx = self.checkpoint + offset;
            return self.buffer_ptr.items[start_idx..start_idx + len];
        }
        
        pub fn set_data(self: *Self, offset: usize, data: []const u8) !void {
            const end = offset + data.len;
            try self.ensure_capacity(end);
            
            const start_idx = self.checkpoint + offset;
            @memcpy(self.buffer_ptr.items[start_idx..start_idx + data.len], data);
        }
        
        pub fn clear(self: *Self) void {
            if (self.owns_buffer) {
                // If we own the buffer, we can actually clear it
                self.buffer_ptr.items.len = 0;
                self.checkpoint = 0;
            } else {
                // If we don't own the buffer, reset our checkpoint
                self.checkpoint = self.buffer_ptr.items.len;
            }
            self.cached_expansion = .{ .last_size = 0, .last_words = 0, .last_cost = 0 };
        }
        
        pub fn create_child(self: *Self) !Self {
            return try Self.init_borrowed(self.allocator, self.buffer_ptr, self.buffer_ptr.items.len);
        }
        
        pub fn get_u256(self: *const Self, offset: usize) !u256 {
            const slice = try self.get_slice(offset, 32);
            var result: u256 = 0;
            for (slice) |byte| {
                result = (result << 8) | byte;
            }
            return result;
        }
        
        pub fn set_u256(self: *Self, offset: usize, value: u256) !void {
            var bytes: [32]u8 = undefined;
            var temp = value;
            var i: usize = 32;
            while (i > 0) {
                i -= 1;
                bytes[i] = @truncate(temp);
                temp >>= 8;
            }
            try self.set_data(offset, &bytes);
        }
        
        pub fn get_byte(self: *const Self, offset: usize) !u8 {
            const slice = try self.get_slice(offset, 1);
            return slice[0];
        }
        
        pub fn set_byte(self: *Self, offset: usize, value: u8) !void {
            const bytes = [_]u8{value};
            try self.set_data(offset, &bytes);
        }
        
        pub fn get_expansion_cost(self: *Self, new_size: u64) u64 {
            const current_size = @as(u64, @intCast(self.size()));
            
            if (new_size <= current_size) {
                return 0;
            }
            
            const new_words = (new_size + 31) / 32;
            const current_words = (current_size + 31) / 32;
            
            if (new_size <= self.cached_expansion.last_size) {
                return 0;
            }
            
            const new_cost = calculate_memory_cost(new_words);
            const current_cost = calculate_memory_cost(current_words);
            const expansion_cost = new_cost - current_cost;
            
            self.cached_expansion.last_size = new_size;
            self.cached_expansion.last_words = new_words;
            self.cached_expansion.last_cost = new_cost;
            
            return expansion_cost;
        }
        
        fn calculate_memory_cost(words: u64) u64 {
            return 3 * words + (words * words) / 512;
        }
        
        // Helper for accessing the buffer in tests
        pub fn get_buffer_ref(self: *Self) *std.ArrayList(u8) {
            return self.buffer_ptr;
        }
    };
}

// Tests
test "Memory owner basic operations" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Initial size should be 0
    try std.testing.expectEqual(@as(usize, 0), memory.size());
    
    // Test set_data
    const data = [_]u8{0x01, 0x02, 0x03, 0x04};
    try memory.set_data(0, &data);
    try std.testing.expectEqual(@as(usize, 4), memory.size());
    
    // Test get_slice
    const slice = try memory.get_slice(0, 4);
    try std.testing.expectEqualSlices(u8, &data, slice);
    
    // Test clear
    memory.clear();
    try std.testing.expectEqual(@as(usize, 0), memory.size());
}

test "Memory borrowed operations" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    // Create owner memory
    var owner = try Memory.init(allocator);
    defer owner.deinit();
    
    // Set some data in owner
    const data1 = [_]u8{0xAA, 0xBB, 0xCC};
    try owner.set_data(0, &data1);
    
    // Create borrowed memory with checkpoint
    var borrowed = try Memory.init_borrowed(allocator, owner.buffer_ptr, owner.buffer_ptr.items.len);
    defer borrowed.deinit();
    
    // Initially borrowed should have size 0
    try std.testing.expectEqual(@as(usize, 0), borrowed.size());
    
    // Add data to borrowed
    const data2 = [_]u8{0xDD, 0xEE, 0xFF};
    try borrowed.set_data(0, &data2);
    try std.testing.expectEqual(@as(usize, 3), borrowed.size());
    
    // Verify owner buffer has both sets of data
    try std.testing.expectEqual(@as(usize, 6), owner.buffer_ptr.items.len);
    try std.testing.expectEqualSlices(u8, &data1, owner.buffer_ptr.items[0..3]);
    try std.testing.expectEqualSlices(u8, &data2, owner.buffer_ptr.items[3..6]);
}

test "Memory capacity limits" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{ .initial_capacity = 50, .memory_limit = 100 });
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Should succeed within limit
    try memory.ensure_capacity(50);
    try std.testing.expectEqual(@as(usize, 50), memory.buffer_ptr.items.len);
    
    // Should succeed at limit
    try memory.ensure_capacity(100);
    try std.testing.expectEqual(@as(usize, 100), memory.buffer_ptr.items.len);
    
    // Should fail beyond limit
    try std.testing.expectError(MemoryError.MemoryOverflow, memory.ensure_capacity(101));
}

test "Memory child creation" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var parent = try Memory.init(allocator);
    defer parent.deinit();
    
    // Add data to parent
    const data1 = [_]u8{0x11, 0x22, 0x33};
    try parent.set_data(0, &data1);
    try std.testing.expectEqual(@as(usize, 3), parent.size());
    
    // Create child
    var child = try parent.create_child();
    defer child.deinit();
    
    // Child should start with size 0
    try std.testing.expectEqual(@as(usize, 0), child.size());
    
    // Add data to child
    const data2 = [_]u8{0x44, 0x55};
    try child.set_data(0, &data2);
    
    // Debug: check actual values
    // Parent: checkpoint=0, buffer.len=5, so size=5-0=5
    // Child: checkpoint=3, buffer.len=5, so size=5-3=2
    try std.testing.expectEqual(@as(usize, 0), parent.checkpoint);
    try std.testing.expectEqual(@as(usize, 3), child.checkpoint);
    try std.testing.expectEqual(@as(usize, 5), parent.buffer_ptr.items.len);
    
    // Parent now sees expanded size (5) because buffer grew
    try std.testing.expectEqual(@as(usize, 5), parent.size());
    
    // Child should see its own data
    try std.testing.expectEqual(@as(usize, 2), child.size());
    
    // Buffer should contain all data
    try std.testing.expectEqual(@as(usize, 5), parent.buffer_ptr.items.len);
}

test "Memory zero initialization on expansion" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Expand memory
    try memory.ensure_capacity(10);
    
    // All bytes should be zero
    const slice = try memory.get_slice(0, 10);
    for (slice) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "Memory out of bounds access" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Set some data
    const data = [_]u8{0x01, 0x02, 0x03};
    try memory.set_data(0, &data);
    
    // Valid access
    _ = try memory.get_slice(0, 3);
    
    // Out of bounds access
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(0, 4));
    try std.testing.expectError(MemoryError.OutOfBounds, memory.get_slice(2, 2));
}

test "Memory configuration validation" {
    // Valid configurations
    _ = createMemory(.{});
    _ = createMemory(.{ .initial_capacity = 1024, .memory_limit = 2048 });
    
    // These would cause compile errors if uncommented:
    // _ = createMemory(.{ .memory_limit = std.math.maxInt(u64) }); // memory_limit too large
    // _ = createMemory(.{ .initial_capacity = 2000, .memory_limit = 1000 }); // initial > limit
}

test "Memory u256 operations" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Test set and get u256
    const value1: u256 = 0x123456789ABCDEF0;
    try memory.set_u256(0, value1);
    const read1 = try memory.get_u256(0);
    try std.testing.expectEqual(value1, read1);
    
    // Test max u256
    const max_value = std.math.maxInt(u256);
    try memory.set_u256(32, max_value);
    const read2 = try memory.get_u256(32);
    try std.testing.expectEqual(max_value, read2);
    
    // Test zero
    try memory.set_u256(64, 0);
    const read3 = try memory.get_u256(64);
    try std.testing.expectEqual(@as(u256, 0), read3);
}

test "Memory byte operations" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Test set and get byte
    try memory.set_byte(0, 0xFF);
    const byte1 = try memory.get_byte(0);
    try std.testing.expectEqual(@as(u8, 0xFF), byte1);
    
    try memory.set_byte(10, 0x42);
    const byte2 = try memory.get_byte(10);
    try std.testing.expectEqual(@as(u8, 0x42), byte2);
    
    // Test zero initialization
    const byte3 = try memory.get_byte(5);
    try std.testing.expectEqual(@as(u8, 0), byte3);
}

test "Memory gas expansion cost" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Test no expansion needed
    var cost = memory.get_expansion_cost(0);
    try std.testing.expectEqual(@as(u64, 0), cost);
    
    // Test first expansion to 32 bytes (1 word)
    cost = memory.get_expansion_cost(32);
    try std.testing.expectEqual(@as(u64, 3), cost); // 3 * 1 + (1 * 1) / 512 = 3
    
    // Simulate the expansion
    try memory.ensure_capacity(32);
    
    // Test expansion from 32 to 64 bytes (2 words)
    cost = memory.get_expansion_cost(64);
    const expected = (3 * 2 + (2 * 2) / 512) - (3 * 1 + (1 * 1) / 512);
    try std.testing.expectEqual(expected, cost);
    
    // Test no cost for same size
    cost = memory.get_expansion_cost(32);
    try std.testing.expectEqual(@as(u64, 0), cost);
}

test "Memory gas expansion cost caching" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Calculate expansion to 256 bytes (8 words)
    const cost1 = memory.get_expansion_cost(256);
    const expected_cost = 3 * 8 + (8 * 8) / 512;
    try std.testing.expectEqual(expected_cost, cost1);
    
    // Subsequent call for same or smaller size should return 0
    try std.testing.expectEqual(@as(u64, 0), memory.get_expansion_cost(256));
    try std.testing.expectEqual(@as(u64, 0), memory.get_expansion_cost(128));
}

test "Memory clear resets cache" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Calculate some expansion cost
    const cost1 = memory.get_expansion_cost(256);
    try std.testing.expect(cost1 > 0);
    
    // Clear memory
    memory.clear();
    
    // After clear, expansion cost should be recalculated
    const cost2 = memory.get_expansion_cost(256);
    try std.testing.expectEqual(cost1, cost2);
}

test "Memory large data operations" {
    const allocator = std.testing.allocator;
    const Memory = createMemory(.{});
    
    var memory = try Memory.init(allocator);
    defer memory.deinit();
    
    // Create a large data buffer
    var large_data: [1024]u8 = undefined;
    for (&large_data, 0..) |*byte, i| {
        byte.* = @truncate(i);
    }
    
    // Set large data
    try memory.set_data(0, &large_data);
    try std.testing.expectEqual(@as(usize, 1024), memory.size());
    
    // Read back in chunks
    const chunk1 = try memory.get_slice(0, 256);
    const chunk2 = try memory.get_slice(256, 256);
    const chunk3 = try memory.get_slice(512, 256);
    const chunk4 = try memory.get_slice(768, 256);
    
    // Verify chunks
    try std.testing.expectEqualSlices(u8, large_data[0..256], chunk1);
    try std.testing.expectEqualSlices(u8, large_data[256..512], chunk2);
    try std.testing.expectEqualSlices(u8, large_data[512..768], chunk3);
    try std.testing.expectEqualSlices(u8, large_data[768..1024], chunk4);
}