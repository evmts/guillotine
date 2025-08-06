const std = @import("std");
const builtin = @import("builtin");

/// Page size for memory allocation (4KB)
const PAGE_SIZE: usize = 4096;

/// Initial allocation size (64KB = 16 pages)
const INITIAL_SIZE: usize = 64 * 1024;

/// EVM-specific memory allocator that provides page-aligned allocations
/// with efficient growth patterns for EVM workloads.
pub const EvmMemoryAllocator = struct {
    const Self = @This();

    /// Underlying allocator (can be GPA, WASM allocator, etc.)
    parent_allocator: std.mem.Allocator,
    
    /// Arena allocator for actual memory management
    arena: std.heap.ArenaAllocator,
    
    /// Current allocated size in bytes
    allocated_size: usize,
    
    /// Total capacity in bytes
    capacity: usize,
    
    /// Base memory pointer (page-aligned)
    base_ptr: [*]u8,
    
    /// Whether to use doubling strategy for growth
    use_doubling_strategy: bool,

    /// Initialize the EVM memory allocator with initial capacity
    pub fn init(parent_allocator: std.mem.Allocator) !Self {
        var arena = std.heap.ArenaAllocator.init(parent_allocator);
        errdefer arena.deinit();

        // Allocate initial memory with page alignment
        const initial_memory = try arena.allocator().alignedAlloc(u8, PAGE_SIZE, INITIAL_SIZE);
        
        return Self{
            .parent_allocator = parent_allocator,
            .arena = arena,
            .allocated_size = 0,
            .capacity = INITIAL_SIZE,
            .base_ptr = initial_memory.ptr,
            .use_doubling_strategy = true,
        };
    }

    /// Deinitialize the allocator and free all memory
    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Reset the allocator without deallocating memory
    /// This is useful for reusing the allocator between contract executions
    pub fn reset(self: *Self) void {
        self.allocated_size = 0;
        // Clear the memory to avoid data leakage between contracts
        @memset(self.base_ptr[0..self.capacity], 0);
    }

    /// Get a slice of the currently allocated memory
    pub fn getMemory(self: *const Self) []u8 {
        return self.base_ptr[0..self.allocated_size];
    }

    /// Get the total capacity
    pub fn getCapacity(self: *const Self) usize {
        return self.capacity;
    }

    /// Grow the memory to at least the requested size
    /// Returns error if growth fails or exceeds limits
    pub fn grow(self: *Self, new_size: usize) !void {
        if (new_size <= self.capacity) {
            self.allocated_size = new_size;
            return;
        }

        // Calculate new capacity using growth strategy
        var new_capacity = self.capacity;
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

        // Allocate new memory
        const new_memory = try self.arena.allocator().alignedAlloc(u8, PAGE_SIZE, new_capacity);
        
        // Copy existing data
        @memcpy(new_memory[0..self.allocated_size], self.base_ptr[0..self.allocated_size]);
        
        // Update pointers and sizes
        self.base_ptr = new_memory.ptr;
        self.capacity = new_capacity;
        self.allocated_size = new_size;
    }

    /// Ensure capacity for at least the requested size
    pub fn ensureCapacity(self: *Self, size: usize) !void {
        if (size > self.capacity) {
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
        
        // ptr_align is an enum where the value is the log2 of the alignment
        // So alignment 8 is represented as 3 (because 2^3 = 8)
        const alignment_log2 = @intFromEnum(ptr_align);
        const alignment = @as(usize, 1) << alignment_log2;
        
        // No need to check if it's a power of 2 - it always is by construction
        const safe_alignment = alignment;
        
        // Calculate aligned offset (initial calculation for size)
        const current_addr = @intFromPtr(self.base_ptr) + self.allocated_size;
        const aligned_addr_initial = if (safe_alignment > 1) 
            std.mem.alignForward(usize, current_addr, safe_alignment) 
        else 
            current_addr;
        const padding = aligned_addr_initial - current_addr;
        
        const total_size = padding + len;
        const new_size = self.allocated_size + total_size;
        
        // Grow if necessary
        self.ensureCapacity(new_size) catch return null;
        
        // Recalculate aligned address after potential growth
        const final_current_addr = @intFromPtr(self.base_ptr) + self.allocated_size;
        const final_aligned_addr = if (safe_alignment > 1) 
            std.mem.alignForward(usize, final_current_addr, safe_alignment) 
        else 
            final_current_addr;
        
        // Use the final aligned address
        const result = @as([*]u8, @ptrFromInt(final_aligned_addr));
        self.allocated_size = new_size;
        
        return result;
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
    
    try std.testing.expectEqual(INITIAL_SIZE, evm_allocator.capacity);
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
    try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.capacity);
    try std.testing.expectEqual(request_size, evm_allocator.allocated_size);
}

test "EvmMemoryAllocator reset functionality" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    // Allocate some memory
    try evm_allocator.grow(1024);
    
    // Write some data
    const memory = evm_allocator.getMemory();
    @memset(memory, 0xFF);
    
    // Reset
    evm_allocator.reset();
    
    // Verify reset
    try std.testing.expectEqual(@as(usize, 0), evm_allocator.allocated_size);
    try std.testing.expectEqual(INITIAL_SIZE, evm_allocator.capacity);
    
    // Verify memory was cleared
    for (evm_allocator.base_ptr[0..1024]) |byte| {
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
    const addr = @intFromPtr(evm_allocator.base_ptr);
    try std.testing.expectEqual(@as(usize, 0), addr % PAGE_SIZE);
    
    // Verify growth maintains page alignment
    try evm_allocator.grow(INITIAL_SIZE * 3);
    const new_addr = @intFromPtr(evm_allocator.base_ptr);
    try std.testing.expectEqual(@as(usize, 0), new_addr % PAGE_SIZE);
}

test "EvmMemoryAllocator respects alignment for ArrayList" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    // This is what's failing in Memory.init - try to create an ArrayList
    const array_list_ptr = try evm_alloc.create(std.ArrayList(u8));
    defer evm_alloc.destroy(array_list_ptr);
    
    // Verify alignment
    const ptr_addr = @intFromPtr(array_list_ptr);
    const expected_align = @alignOf(std.ArrayList(u8));
    try std.testing.expectEqual(@as(usize, 0), ptr_addr % expected_align);
    
    // Initialize it to make sure it works
    array_list_ptr.* = std.ArrayList(u8).init(evm_alloc);
    defer array_list_ptr.deinit();
    
    // Try to use it
    try array_list_ptr.append(42);
    try std.testing.expectEqual(@as(u8, 42), array_list_ptr.items[0]);
}

test "EvmMemoryAllocator growth strategies" {
    const allocator = std.testing.allocator;
    
    // Test doubling strategy
    {
        var evm_allocator = try EvmMemoryAllocator.init(allocator);
        defer evm_allocator.deinit();
        
        evm_allocator.use_doubling_strategy = true;
        try evm_allocator.grow(INITIAL_SIZE + 1);
        try std.testing.expectEqual(INITIAL_SIZE * 2, evm_allocator.capacity);
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
        try std.testing.expectEqual(expected_capacity, evm_allocator.capacity);
    }
}