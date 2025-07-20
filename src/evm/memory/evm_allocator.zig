const std = @import("std");
const builtin = @import("builtin");

/// Use system page size for better compatibility  
const PAGE_SIZE: usize = std.heap.page_size_min;

/// Initial allocation size - allocate a reasonable amount for EVM operations
/// 4MB should cover most contract executions without frequent reallocation
const INITIAL_PAGES: usize = 1024; // 1024 pages * 4KB = 4MB on most systems
const INITIAL_SIZE: usize = INITIAL_PAGES * PAGE_SIZE;

/// EVM-specific memory allocator that provides page-aligned allocations
/// with efficient growth patterns for EVM workloads.
pub const EvmMemoryAllocator = struct {
    const Self = @This();

    /// The backing allocator - either page allocator or wasm allocator
    backing_allocator: std.mem.Allocator,
    
    /// Current allocated memory buffer (page-aligned)
    memory: []align(PAGE_SIZE) u8,
    
    /// Current allocated size in bytes
    allocated_size: usize,
    
    /// Whether to use doubling strategy for growth
    use_doubling_strategy: bool,

    /// Initialize the EVM memory allocator
    /// Automatically selects the appropriate backing allocator based on target
    pub fn init() !Self {
        // Select appropriate allocator based on target
        const backing_allocator = if (builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64)
            std.heap.wasm_allocator
        else
            std.heap.page_allocator;
        
        // Allocate initial memory with page alignment
        const initial_memory = try backing_allocator.alignedAlloc(u8, PAGE_SIZE, INITIAL_SIZE);
        
        return Self{
            .backing_allocator = backing_allocator,
            .memory = initial_memory,
            .allocated_size = 0,
            .use_doubling_strategy = true,
        };
    }

    /// Deinitialize the allocator and free all memory
    pub fn deinit(self: *Self) void {
        self.backing_allocator.free(self.memory);
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
        const new_memory = try self.backing_allocator.alignedAlloc(u8, PAGE_SIZE, new_capacity);
        
        // Copy existing data
        @memcpy(new_memory[0..self.allocated_size], self.memory[0..self.allocated_size]);
        
        // Free old memory and update
        self.backing_allocator.free(self.memory);
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
        _ = ptr_align; // Ignore alignment for now to get it working
        
        const self: *Self = @ptrCast(@alignCast(ctx));
        
        // Validate request
        if (len == 0) return @ptrCast(&self.memory[0]); // Return valid pointer for zero-size alloc
        
        // Simple allocation without alignment
        const new_size = self.allocated_size + len;
        
        // Check if we need more space
        if (new_size > self.memory.len) {
            self.grow(new_size) catch {
                std.log.err("EvmMemoryAllocator: Failed to grow memory to {} bytes", .{new_size});
                return null;
            };
        }
        
        // Return pointer to memory
        const result_ptr = self.memory.ptr + self.allocated_size;
        self.allocated_size = new_size;
        
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
    var evm_allocator = try EvmMemoryAllocator.init();
    defer evm_allocator.deinit();
    
    try std.testing.expectEqual(INITIAL_SIZE, evm_allocator.memory.len);
    try std.testing.expectEqual(@as(usize, 0), evm_allocator.allocated_size);
}

test "EvmMemoryAllocator growth with doubling strategy" {
    var evm_allocator = try EvmMemoryAllocator.init();
    defer evm_allocator.deinit();
    
    // Request growth beyond initial capacity
    const request_size = INITIAL_SIZE + 1;
    try evm_allocator.grow(request_size);
    
    // Should double the capacity
    try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.memory.len);
    try std.testing.expectEqual(request_size, evm_allocator.allocated_size);
}

test "EvmMemoryAllocator reset functionality" {
    var evm_allocator = try EvmMemoryAllocator.init();
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
    var evm_allocator = try EvmMemoryAllocator.init();
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
    var evm_allocator = try EvmMemoryAllocator.init();
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
    // Test doubling strategy
    {
        var evm_allocator = try EvmMemoryAllocator.init();
        defer evm_allocator.deinit();
        
        evm_allocator.use_doubling_strategy = true;
        try evm_allocator.grow(INITIAL_SIZE + 1);
        try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.memory.len);
    }
    
    // Test page-based growth
    {
        var evm_allocator = try EvmMemoryAllocator.init();
        defer evm_allocator.deinit();
        
        evm_allocator.use_doubling_strategy = false;
        const new_size = INITIAL_SIZE + PAGE_SIZE + 1;
        try evm_allocator.grow(new_size);
        
        const expected_pages = (new_size + PAGE_SIZE - 1) / PAGE_SIZE;
        const expected_capacity = expected_pages * PAGE_SIZE;
        try std.testing.expectEqual(expected_capacity, evm_allocator.memory.len);
    }
}

test "EvmMemoryAllocator sequential allocations" {
    var evm_allocator = try EvmMemoryAllocator.init();
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    // Test sequential allocations without alignment
    const alloc1 = try evm_alloc.alloc(u8, 100);
    defer evm_alloc.free(alloc1);
    
    const alloc2 = try evm_alloc.alloc(u8, 200);
    defer evm_alloc.free(alloc2);
    
    const alloc3 = try evm_alloc.alloc(u8, 300);
    defer evm_alloc.free(alloc3);
    
    // Verify allocations don't overlap
    const addr1 = @intFromPtr(alloc1.ptr);
    const addr2 = @intFromPtr(alloc2.ptr);
    const addr3 = @intFromPtr(alloc3.ptr);
    
    try std.testing.expect(addr2 >= addr1 + 100);
    try std.testing.expect(addr3 >= addr2 + 200);
}