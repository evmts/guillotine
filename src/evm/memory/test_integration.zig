const std = @import("std");
const EvmMemoryAllocator = @import("evm_allocator.zig").EvmMemoryAllocator;

test "basic HashMap with EVM allocator" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    // Try to create a HashMap like the failing test
    var map = std.hash_map.HashMap(u32, u32, std.hash_map.AutoContext(u32), 80).init(evm_alloc);
    defer map.deinit();
    
    // Try some basic operations
    try map.put(1, 100);
    try map.put(2, 200);
    try map.put(3, 300);
    
    try std.testing.expectEqual(@as(?u32, 100), map.get(1));
    try std.testing.expectEqual(@as(?u32, 200), map.get(2));
    try std.testing.expectEqual(@as(?u32, 300), map.get(3));
}

test "ArrayList with EVM allocator" {
    const allocator = std.testing.allocator;
    
    var evm_allocator = try EvmMemoryAllocator.init(allocator);
    defer evm_allocator.deinit();
    
    const evm_alloc = evm_allocator.allocator();
    
    var list = std.ArrayList(u8).init(evm_alloc);
    defer list.deinit();
    
    try list.append(1);
    try list.append(2);
    try list.append(3);
    
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}