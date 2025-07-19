const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const primitives = @import("primitives");

pub fn op_sha3(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const vm = @as(*Vm, @ptrCast(@alignCast(interpreter)));

    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    // Check bounds before anything else
    if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
        return ExecutionError.Error.OutOfOffset;
    }

    if (size == 0) {
        // Even with size 0, we need to validate the offset is reasonable
        if (offset > 0) {
            // Check if offset is beyond reasonable memory limits
            const offset_usize = @as(usize, @intCast(offset));
            const memory_limits = @import("../constants/memory_limits.zig");
            if (offset_usize > memory_limits.MAX_MEMORY_SIZE) {
                return ExecutionError.Error.OutOfOffset;
            }
        }
        // Hash of empty data = keccak256("")
        const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try frame.stack.append(empty_hash);
        return Operation.ExecutionResult{};
    }

    const offset_usize = @as(usize, @intCast(offset));
    const size_usize = @as(usize, @intCast(size));

    // Check if offset + size would overflow
    const end = std.math.add(usize, offset_usize, size_usize) catch {
        return ExecutionError.Error.OutOfOffset;
    };

    // Check if the end position exceeds reasonable memory limits
    const memory_limits = @import("../constants/memory_limits.zig");
    if (end > memory_limits.MAX_MEMORY_SIZE) {
        return ExecutionError.Error.OutOfOffset;
    }

    // Dynamic gas cost for hashing
    const word_size = (size_usize + 31) / 32;
    const gas_cost = 6 * word_size;
    _ = vm;
    try frame.consume_gas(gas_cost);

    // Ensure memory is available
    _ = try frame.memory.ensure_context_capacity(offset_usize + size_usize);

    // Get data and hash
    const data = try frame.memory.get_slice(offset_usize, size_usize);

    // Calculate keccak256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(data, &hash, .{});

    // Hash calculated successfully

    // Convert hash to u256 using std.mem for efficiency
    const result = std.mem.readInt(u256, &hash, .big);

    try frame.stack.append(result);

    return Operation.ExecutionResult{};
}

// Alias for backwards compatibility
pub const op_keccak256 = op_sha3;

// Fuzz testing functions for crypto operations
pub fn fuzz_crypto_operations(allocator: std.mem.Allocator, operations: []const FuzzCryptoOperation) !void {
    const Memory = @import("../memory/memory.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    _ = primitives.Address;
    
    for (operations) |op| {
        var memory = try Memory.init_default(allocator);
        defer memory.deinit();
        
        var db = MemoryDatabase.init(allocator);
        defer db.deinit();
        
        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();
        
        var contract = try Contract.init(allocator, &[_]u8{0x01}, .{});
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();
        
        // Set up memory with test data
        if (op.data.len > 0) {
            try frame.memory.set_data(op.offset, op.data);
        }
        
        // Push offset and size onto stack
        try frame.stack.append(op.offset);
        try frame.stack.append(op.size);
        
        // Execute SHA3/KECCAK256 operation
        const result = op_sha3(0, @ptrCast(&vm), @ptrCast(&frame));
        
        // Verify the result
        try validate_crypto_result(&frame, op, result);
    }
}

const FuzzCryptoOperation = struct {
    offset: usize,
    size: usize,
    data: []const u8,
};

fn validate_crypto_result(frame: *const Frame, op: FuzzCryptoOperation, result: anyerror!Operation.ExecutionResult) !void {
    const testing = std.testing;
    const memory_limits = @import("../constants/memory_limits.zig");
    
    // Check if operation should have failed
    if (op.offset > std.math.maxInt(usize) or 
        op.size > std.math.maxInt(usize) or
        op.offset > memory_limits.MAX_MEMORY_SIZE or
        (op.size > 0 and op.offset + op.size > memory_limits.MAX_MEMORY_SIZE)) {
        try testing.expectError(ExecutionError.Error.OutOfOffset, result);
        return;
    }
    
    // Operation should have succeeded
    try result;
    
    // Stack should have exactly one result (the hash)
    try testing.expectEqual(@as(usize, 1), frame.stack.size);
    
    const hash = frame.stack.data[0];
    
    if (op.size == 0) {
        // Empty data hash should be the keccak256 of empty string
        const expected_empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        try testing.expectEqual(expected_empty_hash, hash);
    } else if (op.size <= op.data.len) {
        // Verify hash is correct for the data
        const actual_data = op.data[0..op.size];
        var expected_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(actual_data, &expected_hash, .{});
        const expected_hash_u256 = std.mem.readInt(u256, &expected_hash, .big);
        try testing.expectEqual(expected_hash_u256, hash);
    } else {
        // Hash with zero padding - need to create the padded data
        var padded_data = std.ArrayList(u8).init(testing.allocator);
        defer padded_data.deinit();
        
        try padded_data.appendSlice(op.data);
        const padding_needed = op.size - op.data.len;
        try padded_data.appendNTimes(0, padding_needed);
        
        var expected_hash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(padded_data.items, &expected_hash, .{});
        const expected_hash_u256 = std.mem.readInt(u256, &expected_hash, .big);
        try testing.expectEqual(expected_hash_u256, hash);
    }
}

test "fuzz_crypto_basic_operations" {
    const allocator = std.testing.allocator;
    const test_data = "Hello, World!";
    
    const operations = [_]FuzzCryptoOperation{
        .{ .offset = 0, .size = 0, .data = "" },
        .{ .offset = 0, .size = test_data.len, .data = test_data },
        .{ .offset = 0, .size = 32, .data = "Short" },
        .{ .offset = 10, .size = 5, .data = "Hello, World!" },
    };
    
    try fuzz_crypto_operations(allocator, &operations);
}

test "fuzz_crypto_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzCryptoOperation{
        .{ .offset = 0, .size = 0, .data = "" },
        .{ .offset = 0, .size = 1, .data = "a" },
        .{ .offset = 0, .size = 32, .data = "0123456789abcdef0123456789abcdef" },
        .{ .offset = std.math.maxInt(usize) - 100, .size = 10, .data = "test" },
        .{ .offset = 0, .size = std.math.maxInt(usize), .data = "test" },
    };
    
    try fuzz_crypto_operations(allocator, &operations);
}

test "fuzz_crypto_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzCryptoOperation).init(allocator);
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
        const data_len = random.intRangeAtMost(usize, 0, 100);
        const data = try allocator.alloc(u8, data_len);
        random.bytes(data);
        try test_data_storage.append(data);
        
        const offset = random.intRangeAtMost(usize, 0, 1000);
        const size = random.intRangeAtMost(usize, 0, 200);
        
        try operations.append(.{ .offset = offset, .size = size, .data = data });
    }
    
    try fuzz_crypto_operations(allocator, operations.items);
}

test "fuzz_crypto_known_vectors" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzCryptoOperation{
        .{ .offset = 0, .size = 0, .data = "" },
        .{ .offset = 0, .size = 3, .data = "abc" },
        .{ .offset = 0, .size = 56, .data = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq" },
        .{ .offset = 0, .size = 4, .data = "test" },
        .{ .offset = 0, .size = 11, .data = "hello world" },
    };
    
    try fuzz_crypto_operations(allocator, &operations);
}

test "fuzz_crypto_memory_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzCryptoOperation{
        .{ .offset = 0, .size = 0, .data = "" },
        .{ .offset = 1000, .size = 0, .data = "" },
        .{ .offset = 0, .size = 1000, .data = "small" },
        .{ .offset = 500, .size = 100, .data = "test data for memory operations" },
    };
    
    try fuzz_crypto_operations(allocator, &operations);
}

test "fuzz_crypto_alignment_patterns" {
    const allocator = std.testing.allocator;
    
    var operations = std.ArrayList(FuzzCryptoOperation).init(allocator);
    defer operations.deinit();
    
    const test_data = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    
    // Test various alignment patterns
    const alignments = [_]usize{ 1, 2, 4, 8, 16, 32 };
    
    for (alignments) |alignment| {
        try operations.append(.{ .offset = alignment, .size = 32, .data = test_data });
        try operations.append(.{ .offset = 0, .size = alignment, .data = test_data });
    }
    
    try fuzz_crypto_operations(allocator, operations.items);
}
