const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame_fat.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

// Stack buffer sizes for common hash operations
const SMALL_BUFFER_SIZE = 64;   // Most common (addresses, small data)
const MEDIUM_BUFFER_SIZE = 256; // Common for event data
const LARGE_BUFFER_SIZE = 1024; // Reasonable max for stack allocation

/// Optimized hash function using tiered stack buffers for small inputs.
/// Falls back to memory system for larger inputs.
inline fn hash_with_stack_buffer(data: []const u8) [32]u8 {
    var hash: [32]u8 = undefined;
    
    if (data.len <= SMALL_BUFFER_SIZE) {
        @branchHint(.likely); // Most common case - addresses and small data
        var buffer: [SMALL_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else if (data.len <= MEDIUM_BUFFER_SIZE) {
        @branchHint(.likely); // Common case - event data and medium-sized inputs
        var buffer: [MEDIUM_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else if (data.len <= LARGE_BUFFER_SIZE) {
        @branchHint(.unlikely); // Less common but still reasonable for stack
        var buffer: [LARGE_BUFFER_SIZE]u8 = undefined;
        @memcpy(buffer[0..data.len], data);
        std.crypto.hash.sha3.Keccak256.hash(buffer[0..data.len], &hash, .{});
    } else {
        @branchHint(.cold); // Very large data - hash directly from memory
        std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});
    }
    
    return hash;
}

pub fn op_sha3(vm: Operation.Interpreter, frame: Operation.State) ExecutionError.Error!Operation.ExecutionResult {

    const offset = try frame.stack_pop();
    const size = try frame.stack_pop();

    // Check bounds before anything else
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    if (size == 0) {
        @branchHint(.unlikely);
        // Even with size 0, we need to validate the offset is reasonable
        if (offset > 0) {
            // Check if offset is beyond reasonable memory limits
            const offset_usize = @as(usize, @intCast(offset));
            const memory_limits = @import("../constants/memory_limits.zig");
            if (offset_usize > memory_limits.MAX_MEMORY_SIZE) {
                @branchHint(.unlikely);
                return ExecutionError.Error.OutOfOffset;
            }
        }
        // Hash of empty data = keccak256("")
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try frame.stack_push(empty_hash);
        return Operation.ExecutionResult{};
    }

    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));

    // Check if offset + size would overflow
    const end = std.math.add(usize, offset_usize, size_usize) catch {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    };

    // Check if the end position exceeds reasonable memory limits
    const memory_limits = @import("../constants/memory_limits.zig");
    if (end > memory_limits.MAX_MEMORY_SIZE) {
        @branchHint(.unlikely);
        return ExecutionError.Error.OutOfOffset;
    }

    // Dynamic gas cost for hashing
    const word_size = (size_usize + 31) / 32;
    const gas_cost = 6 * word_size;
    _ = vm;
    try frame.consume_gas(gas_cost);

    // Ensure memory is available
    frame.memory_ensure_capacity(end) catch |err| switch (err) {
        error.OutOfGas => return error.OutOfGas,
        error.AllocationError => return error.OutOfMemory,
        error.Overflow => return error.OutOfMemory,
        error.OutOfMemory => return error.OutOfMemory,
    };

    // Get data and hash using optimized stack buffer approach
    const data = frame.memory_get_slice(@intCast(offset_usize), @intCast(size_usize));

    // Calculate keccak256 hash using optimized tiered stack buffers
    const hash = hash_with_stack_buffer(data);

    // Convert hash to u256 using std.mem for efficiency
    const result = std.mem.readInt(u256, &hash, .big);

    try frame.stack_push(result);

    return Operation.ExecutionResult{};
}

// Alias for backwards compatibility
pub const op_keccak256 = op_sha3;


test "crypto_stack_buffer_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    const allocator = std.testing.allocator;
    
    // Setup test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    const iterations = 10000; // Reduced for crypto operations due to complexity
    
    // Benchmark 1: Small data (address-sized, 20-32 bytes) - should use SMALL_BUFFER
    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x20}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();
        
        // Set up 32 bytes of data in memory (typical address + padding)
        const test_data = [_]u8{0x42} ** 32;
        frame.memory_set_data(0, &test_data);
        
        // Push offset=0, size=32 for KECCAK256
        try frame.stack_push(0);
        try frame.stack_push(32);
        
        _ = try op_sha3(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const small_buffer_ns = timer.read();
    
    // Benchmark 2: Medium data (128 bytes) - should use MEDIUM_BUFFER
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x20}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();
        
        // Set up 128 bytes of data in memory (event data size)
        const test_data = [_]u8{0x37} ** 128;
        frame.memory_set_data(0, &test_data);
        
        // Push offset=0, size=128 for KECCAK256
        try frame.stack_push(0);
        try frame.stack_push(128);
        
        _ = try op_sha3(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const medium_buffer_ns = timer.read();
    
    // Benchmark 3: Large data (512 bytes) - should use LARGE_BUFFER
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x20}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();
        
        // Set up 512 bytes of data in memory
        const test_data = [_]u8{0x73} ** 512;
        frame.memory_set_data(0, &test_data);
        
        // Push offset=0, size=512 for KECCAK256
        try frame.stack_push(0);
        try frame.stack_push(512);
        
        _ = try op_sha3(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const large_buffer_ns = timer.read();
    
    // Benchmark 4: Very large data (2048 bytes) - should hash directly from memory
    timer.reset();
    i = 0;
    while (i < iterations / 10) : (i += 1) { // Fewer iterations for large data
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x20}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();
        
        // Set up 2048 bytes of data in memory
        const test_data = [_]u8{0x99} ** 2048;
        frame.memory_set_data(0, &test_data);
        
        // Push offset=0, size=2048 for KECCAK256
        try frame.stack_push(0);
        try frame.stack_push(2048);
        
        _ = try op_sha3(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const very_large_ns = timer.read();
    
    // Benchmark 5: Direct hash function comparison
    const direct_test_data = [_]u8{0x42} ** 64;
    
    // Using optimized stack buffer
    timer.reset();
    i = 0;
    while (i < iterations * 10) : (i += 1) {
        _ = hash_with_stack_buffer(&direct_test_data);
    }
    const optimized_direct_ns = timer.read();
    
    // Using standard library directly (for comparison)
    timer.reset();
    i = 0;
    while (i < iterations * 10) : (i += 1) {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&direct_test_data, &hash, .{});
    }
    const standard_direct_ns = timer.read();
    
    // Benchmark 6: Common Ethereum use cases
    timer.reset();
    
    // Address hashing (20 bytes) - very common
    const address_data = [_]u8{0x12} ** 20;
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = hash_with_stack_buffer(&address_data);
    }
    const address_hash_ns = timer.read();
    
    // Function signature hashing (4 bytes) - extremely common
    timer.reset();
    const sig_data = [_]u8{0xab, 0xcd, 0xef, 0x12};
    i = 0;
    while (i < iterations) : (i += 1) {
        _ = hash_with_stack_buffer(&sig_data);
    }
    const signature_hash_ns = timer.read();
    
    // Print benchmark results
    std.log.debug("Crypto Stack Buffer Benchmarks:", .{});
    std.log.debug("  Small buffer (32 bytes, {} ops): {} ns", .{ iterations, small_buffer_ns });
    std.log.debug("  Medium buffer (128 bytes, {} ops): {} ns", .{ iterations, medium_buffer_ns });
    std.log.debug("  Large buffer (512 bytes, {} ops): {} ns", .{ iterations, large_buffer_ns });
    std.log.debug("  Very large (2048 bytes, {} ops): {} ns", .{ iterations / 10, very_large_ns });
    
    std.log.debug("  Direct function comparison ({} ops):", .{ iterations * 10 });
    std.log.debug("    Optimized stack buffer: {} ns", .{optimized_direct_ns});
    std.log.debug("    Standard library: {} ns", .{standard_direct_ns});
    
    std.log.debug("  Common Ethereum use cases:");
    std.log.debug("    Address hashing (20 bytes): {} ns", .{address_hash_ns});
    std.log.debug("    Function signature (4 bytes): {} ns", .{signature_hash_ns});
    
    // Performance analysis
    const avg_small_ns = small_buffer_ns / iterations;
    const avg_medium_ns = medium_buffer_ns / iterations;
    const avg_large_ns = large_buffer_ns / iterations;
    const avg_very_large_ns = (very_large_ns * 10) / iterations; // Adjust for fewer iterations
    
    std.log.debug("  Average timings:");
    std.log.debug("    Small (32B): {} ns/op", .{avg_small_ns});
    std.log.debug("    Medium (128B): {} ns/op", .{avg_medium_ns});
    std.log.debug("    Large (512B): {} ns/op", .{avg_large_ns});
    std.log.debug("    Very Large (2048B): {} ns/op", .{avg_very_large_ns});
    
    const avg_optimized_direct = optimized_direct_ns / (iterations * 10);
    const avg_standard_direct = standard_direct_ns / (iterations * 10);
    
    std.log.debug("    Optimized direct: {} ns/op", .{avg_optimized_direct});
    std.log.debug("    Standard direct: {} ns/op", .{avg_standard_direct});
    
    // Verify optimization effectiveness for small data
    if (avg_optimized_direct <= avg_standard_direct) {
        std.log.debug("✓ Stack buffer optimization shows expected performance benefit");
    }
    
    // Verify tiered approach effectiveness
    if (avg_small_ns <= avg_medium_ns and avg_medium_ns <= avg_large_ns) {
        std.log.debug("✓ Tiered stack buffer approach showing expected scaling");
    }
}
