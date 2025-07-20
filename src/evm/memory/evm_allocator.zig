const std = @import("std");
const builtin = @import("builtin");

/// Page size for memory allocation (4KB)
const PAGE_SIZE: usize = 4096;

/// Initial allocation size (1MB = 256 pages)
const INITIAL_SIZE: usize = 1024 * 1024;

/// Maximum alignment we support (some data structures may require up to 64-byte alignment)
const MAX_ALIGNMENT: usize = 64;

/// EVM-specific memory allocator that provides page-aligned allocations
/// with efficient growth patterns for EVM workloads.
pub const EvmMemoryAllocator = struct {
    const Self = @This();

    /// Underlying allocator (can be GPA, WASM allocator, etc.)
    parent_allocator: std.mem.Allocator,
    
    /// Current allocated memory buffer (page-aligned)
    memory: []align(PAGE_SIZE) u8,
    
    /// Current allocated size in bytes
    allocated_size: usize,
    
    /// Whether to use doubling strategy for growth
    use_doubling_strategy: bool,

    /// Initialize the EVM memory allocator with initial capacity
    pub fn init(parent_allocator: std.mem.Allocator) !Self {
        // Allocate initial memory with page alignment
        const initial_memory = try parent_allocator.alignedAlloc(u8, PAGE_SIZE, INITIAL_SIZE);
        
        return Self{
            .parent_allocator = parent_allocator,
            .memory = initial_memory,
            .allocated_size = 0,
            .use_doubling_strategy = true,
        };
    }

    /// Deinitialize the allocator and free all memory
    pub fn deinit(self: *Self) void {
        self.parent_allocator.free(self.memory);
    }

    /// Reset the allocator without deallocating memory
    /// This is useful for reusing the allocator between contract executions
    pub fn reset(self: *Self) void {
        // Clear the memory to avoid data leakage between contracts
        if (self.allocated_size > 0) {
            @memset(self.memory[0..self.allocated_size], 0);
        }
        self.allocated_size = 0;
    }

    /// Get a slice of the currently allocated memory
    pub fn getMemory(self: *const Self) []u8 {
        return self.memory[0..self.allocated_size];
    }

    /// Get the total capacity
    pub fn getCapacity(self: *const Self) usize {
        return self.memory.len;
    }

    /// Grow the memory to at least the requested size
    /// Returns error if growth fails or exceeds limits
    pub fn grow(self: *Self, new_size: usize) !void {
        if (new_size <= self.memory.len) {
            self.allocated_size = new_size;
            return;
        }

        // Calculate new capacity using growth strategy
        var new_capacity = self.memory.len;
        if (self.use_doubling_strategy) {
            // Double until we reach the required size
            while (new_capacity < new_size) {
                new_capacity *= 2;
            }
        } else {
            // Grow by pages
            const pages_needed = (new_size + PAGE_SIZE - 1) / PAGE_SIZE;
            new_capacity = pages_needed * PAGE_SIZE;
        }

        // Allocate new memory with page alignment
        const new_memory = try self.parent_allocator.alignedAlloc(u8, PAGE_SIZE, new_capacity);
        
        // Copy existing data
        @memcpy(new_memory[0..self.allocated_size], self.memory[0..self.allocated_size]);
        
        // Free old memory and update
        self.parent_allocator.free(self.memory);
        self.memory = new_memory;
        self.allocated_size = new_size;
    }

    /// Ensure capacity for at least the requested size
    pub fn ensureCapacity(self: *Self, size: usize) !void {
        if (size > self.memory.len) {
            try self.grow(size);
        }
    }

    /// Get the allocator interface
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
                .remap = remap,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        // Get alignment value from enum - std.mem.Alignment uses log2(alignment)
        // The enum value is the log2 of the actual alignment requirement
        const raw_align = @intFromEnum(ptr_align);
        
        // Defensive: Zig's Alignment enum should never exceed 29 (2^29 = 512MB alignment)
        // If we get a value >= 30, it's likely corrupted or uninitialized memory
        if (raw_align >= 30) {
            // This is clearly invalid, default to no alignment
            if (self.allocated_size + len > self.memory.len) {
                self.grow(self.allocated_size + len) catch return null;
            }
            const result_ptr = self.memory.ptr + self.allocated_size;
            self.allocated_size += len;
            return result_ptr;
        }
        
        const alignment = @as(usize, 1) << @intCast(raw_align);
        
        // Calculate aligned offset within our memory buffer
        const current_addr = @intFromPtr(self.memory.ptr) + self.allocated_size;
        const aligned_addr = std.mem.alignForward(usize, current_addr, alignment);
        const padding = aligned_addr - current_addr;
        
        // Check if we need more space
        const total_size = self.allocated_size + padding + len;
        if (total_size > self.memory.len) {
            self.grow(total_size) catch {
                std.log.err("EvmMemoryAllocator: Failed to grow memory to {} bytes", .{total_size});
                return null;
            };
        }
        
        // Return pointer to aligned memory
        const result_ptr = self.memory.ptr + self.allocated_size + padding;
        self.allocated_size = total_size;
        
        return result_ptr;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf_align;
        _ = ret_addr;
        
        // Simple resize: only support shrinking in place
        if (new_len <= buf.len) {
            return true;
        }
        
        return false;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // No-op: arena allocator doesn't free individual allocations
    }

    fn remap(ctx: *anyopaque, old_mem: []u8, old_align: std.mem.Alignment, new_size: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = old_mem;
        _ = old_align;
        _ = new_size;
        _ = ret_addr;
        // Arena allocator doesn't support remapping
        return null;
    }
};

test "EvmMemoryAllocator basic initialization" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    try std.testing.expectEqual(INITIAL_SIZE, evm_allocator.memory.len);
    try std.testing.expectEqual(@as(usize, 0), evm_allocator.allocated_size);
}

test "EvmMemoryAllocator growth with doubling strategy" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    // Request growth beyond initial capacity
    const request_size = INITIAL_SIZE + 1;
    try evm_allocator.grow(request_size);
    
    // Should double the capacity
    try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.memory.len);
    try std.testing.expectEqual(request_size, evm_allocator.allocated_size);
}

test "EvmMemoryAllocator reset functionality" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    // Allocate some memory
    try evm_allocator.grow(1024);
    const old_allocated = evm_allocator.allocated_size;
    
    // Write some data
    const memory = evm_allocator.getMemory();
    @memset(memory, 0xFF);
    
    // Reset
    evm_allocator.reset();
    
    // Verify reset
    try std.testing.expectEqual(@as(usize, 0), evm_allocator.allocated_size);
    try std.testing.expectEqual(INITIAL_SIZE, evm_allocator.memory.len);
    
    // Verify memory was cleared (only the previously allocated portion)
    for (evm_allocator.memory[0..old_allocated]) |byte| {
        try std.testing.expectEqual(@as(u8, 0), byte);
    }
}

test "EvmMemoryAllocator as std.mem.Allocator" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    // Allocate some memory
    const slice1 = try evm_alloc.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), slice1.len);
    
    // Allocate more memory
    const slice2 = try evm_alloc.alloc(u8, 200);
    try std.testing.expectEqual(@as(usize, 200), slice2.len);
    
    // Verify non-overlapping
    const slice1_end = @intFromPtr(slice1.ptr) + slice1.len;
    const slice2_start = @intFromPtr(slice2.ptr);
    try std.testing.expect(slice1_end <= slice2_start);
}

test "EvmMemoryAllocator page alignment" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    // Verify initial allocation is page-aligned
    const addr = @intFromPtr(evm_allocator.memory.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % PAGE_SIZE);
    
    // Verify growth maintains page alignment
    try evm_allocator.grow(INITIAL_SIZE * 3);
    const new_addr = @intFromPtr(evm_allocator.memory.ptr);
    try std.testing.expectEqual(@as(usize, 0), new_addr % PAGE_SIZE);
}

test "EvmMemoryAllocator growth strategies" {
    const allocator = std.testing.allocator;
    
    // Test doubling strategy
    {
        var evm_allocator = try EvmMemoryAllocator.init(allocator);
        defer evm_allocator.deinit();
        
        evm_allocator.use_doubling_strategy = true;
        try evm_allocator.grow(INITIAL_SIZE + 1);
        try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.memory.len);
    }
    
    // Test page-based growth
    {
        var evm_allocator = try EvmMemoryAllocator.init(allocator);
        defer evm_allocator.deinit();
        
        evm_allocator.use_doubling_strategy = false;
        const new_size = INITIAL_SIZE + PAGE_SIZE + 1;
        try evm_allocator.grow(new_size);
        
        const expected_pages = (new_size + PAGE_SIZE - 1) / PAGE_SIZE;
        const expected_capacity = expected_pages * PAGE_SIZE;
        try std.testing.expectEqual(expected_capacity, evm_allocator.memory.len);
    }
}

test "EvmMemoryAllocator ARM64 alignment" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    // Test 16-byte alignment (ARM64 requirement for some operations)
    const aligned_16 = try evm_alloc.alignedAlloc(u128, 16, 10);
    defer evm_alloc.free(aligned_16);
    
    const addr_16 = @intFromPtr(aligned_16.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr_16 % 16);
    
    // Test 8-byte alignment
    const aligned_8 = try evm_alloc.alignedAlloc(u64, 8, 10);
    defer evm_alloc.free(aligned_8);
    
    const addr_8 = @intFromPtr(aligned_8.ptr);
    try std.testing.expectEqual(@as(usize, 0), addr_8 % 8);
    
    // Test that allocations don't overlap
    const end_16 = addr_16 + @sizeOf(u128) * 10;
    try std.testing.expect(addr_8 >= end_16);
}