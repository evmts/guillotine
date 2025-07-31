const std = @import("std");
const EvmMemoryAllocator = @import("evm_allocator.zig").EvmMemoryAllocator;

/// Example of using EvmMemoryAllocator with EVM components
pub fn example() !void {
    // Initialize with either GPA or WASM allocator
    const parent_allocator = if (@import("builtin").target.cpu.arch == .wasm32) 
        std.heap.wasm_allocator 
    else 
        std.heap.page_allocator;

    // Create EVM memory allocator
    var evm_allocator = try EvmMemoryAllocator.init(parent_allocator);
    defer evm_allocator.deinit();

    // Get allocator interface
    const allocator = evm_allocator.allocator();

    // Use with EVM Memory component
    const Memory = @import("memory.zig");
    var memory = try Memory.init(allocator, Memory.INITIAL_CAPACITY, Memory.DEFAULT_MEMORY_LIMIT);
    defer memory.deinit(allocator);

    // Execute contract...
    
    // Reset for next contract execution
    evm_allocator.reset();
    
    // Ready for next contract without reallocating
}

test "example usage" {
    try example();
}