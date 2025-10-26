// ============================================================================
// MEMORY C API - FFI interface for EVM memory operations
// ============================================================================

const std = @import("std");
const evm = @import("evm");
const MemoryConfig = evm.MemoryConfig;
const Memory = evm.Memory;
const MemoryError = evm.MemoryError;

const allocator = std.heap.c_allocator;

// Default memory configuration
const DefaultMemoryConfig = MemoryConfig{
    .initial_capacity = 4096,     // 4KB initial
    .memory_limit = 16 * 1024 * 1024,   // 16MB max
};

// ============================================================================
// ERROR CODES
// ============================================================================

const EVM_MEMORY_SUCCESS = 0;
const EVM_MEMORY_ERROR_NULL_POINTER = -1;
const EVM_MEMORY_ERROR_OUT_OF_MEMORY = -2;
const EVM_MEMORY_ERROR_LIMIT_EXCEEDED = -3;
const EVM_MEMORY_ERROR_INVALID_OFFSET = -4;
const EVM_MEMORY_ERROR_EXPANSION_FAILED = -5;

// ============================================================================
// OPAQUE HANDLE
// ============================================================================

const MemoryHandle = struct {
    memory: Memory(DefaultMemoryConfig),
    config: MemoryConfig,
};

// ============================================================================
// LIFECYCLE FUNCTIONS
// ============================================================================

/// Create a new EVM memory instance
/// @param initial_size Initial memory size (will be rounded up to word boundary)
/// @return Opaque memory handle, or NULL on failure
pub export fn evm_memory_create(initial_size: usize) ?*MemoryHandle {
    const handle = allocator.create(MemoryHandle) catch return null;
    errdefer allocator.destroy(handle);
    
    handle.* = MemoryHandle{
        .memory = Memory(DefaultMemoryConfig).init(allocator) catch {
            allocator.destroy(handle);
            return null;
        },
        .config = DefaultMemoryConfig,
    };
    
    // Expand to initial size if requested
    if (initial_size > 0) {
        handle.memory.ensure_capacity(allocator, @intCast(initial_size)) catch {
            handle.memory.deinit(allocator);
            allocator.destroy(handle);
            return null;
        };
    }
    
    return handle;
}

/// Destroy memory instance and free all resources
/// @param handle Memory handle
pub export fn evm_memory_destroy(handle: ?*MemoryHandle) void {
    const h = handle orelse return;
    h.memory.deinit(allocator);
    allocator.destroy(h);
}

/// Reset memory to initial state
/// @param handle Memory handle
/// @return Error code
pub export fn evm_memory_reset(handle: ?*MemoryHandle) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    
    h.memory.clear();
    return EVM_MEMORY_SUCCESS;
}

// ============================================================================
// READ OPERATIONS
// ============================================================================

/// Read a single byte from memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param value_out Pointer to store byte value
/// @return Error code
pub export fn evm_memory_read_byte(handle: ?*const MemoryHandle, offset: u32, value_out: ?*u8) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    const out = value_out orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    
    out.* = h.memory.get_byte(@intCast(offset)) catch return EVM_MEMORY_ERROR_INVALID_OFFSET;
    return EVM_MEMORY_SUCCESS;
}

/// Read 32 bytes (u256) from memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param value_out Pointer to 32-byte buffer
/// @return Error code
pub export fn evm_memory_read_u256(handle: ?*const MemoryHandle, offset: u32, value_out: ?*[32]u8) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    const out = value_out orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    
    // get_u256_evm requires a mutable reference but we have const
    // Use get_u256 instead which takes const self
    const value = h.memory.get_u256(@intCast(offset)) catch return EVM_MEMORY_ERROR_INVALID_OFFSET;
    std.mem.writeInt(u256, out, value, .big);
    
    return EVM_MEMORY_SUCCESS;
}

/// Read arbitrary slice from memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param data_out Buffer to write data
/// @param len Number of bytes to read
/// @return Error code
pub export fn evm_memory_read_slice(handle: ?*const MemoryHandle, offset: u32, data_out: [*]u8, len: u32) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    
    const slice = h.memory.get_slice(@intCast(offset), @intCast(len)) catch return EVM_MEMORY_ERROR_INVALID_OFFSET;
    @memcpy(data_out[0..len], slice);
    
    return EVM_MEMORY_SUCCESS;
}

// ============================================================================
// WRITE OPERATIONS
// ============================================================================

/// Write a single byte to memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param value Byte value to write
/// @return Error code
pub export fn evm_memory_write_byte(handle: ?*MemoryHandle, offset: u32, value: u8) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;

    h.memory.set_byte_evm(allocator, @intCast(offset), value) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    return EVM_MEMORY_SUCCESS;
}

/// Write 32 bytes (u256) to memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param value_in Pointer to 32-byte value (big-endian)
/// @return Error code
pub export fn evm_memory_write_u256(handle: ?*MemoryHandle, offset: u32, value_in: ?*const [32]u8) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    const value_ptr = value_in orelse return EVM_MEMORY_ERROR_NULL_POINTER;

    const value = std.mem.readInt(u256, value_ptr, .big);

    h.memory.set_u256_evm(allocator, @intCast(offset), value) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    return EVM_MEMORY_SUCCESS;
}

/// Write arbitrary data to memory
/// @param handle Memory handle
/// @param offset Memory offset
/// @param data_in Data to write
/// @param len Number of bytes to write
/// @return Error code
pub export fn evm_memory_write_slice(handle: ?*MemoryHandle, offset: u32, data_in: [*]const u8, len: u32) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;

    h.memory.set_data_evm(allocator, @intCast(offset), data_in[0..len]) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    return EVM_MEMORY_SUCCESS;
}

// ============================================================================
// MEMORY MANAGEMENT
// ============================================================================

/// Get current memory size
/// @param handle Memory handle
/// @return Current memory size in bytes
pub export fn evm_memory_get_size(handle: ?*const MemoryHandle) u32 {
    const h = handle orelse return 0;
    return @intCast(h.memory.size());
}

/// Get memory capacity (allocated size)
/// @param handle Memory handle
/// @return Memory capacity in bytes
pub export fn evm_memory_get_capacity(handle: ?*const MemoryHandle) u32 {
    const h = handle orelse return 0;
    // For now, return the same as size since we don't expose internal capacity
    return @intCast(h.memory.size());
}

/// Ensure memory has at least the specified capacity
/// @param handle Memory handle
/// @param new_capacity Required capacity
/// @return Error code
pub export fn evm_memory_ensure_capacity(handle: ?*MemoryHandle, new_capacity: u32) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;

    h.memory.ensure_capacity(allocator, @intCast(new_capacity)) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    return EVM_MEMORY_SUCCESS;
}

/// Get gas cost for memory expansion
/// @param handle Memory handle
/// @param offset Memory offset
/// @param size Size of operation
/// @return Gas cost, or negative error code
pub export fn evm_memory_get_expansion_cost(handle: ?*const MemoryHandle, offset: u32, size: u32) i64 {
    const h = handle orelse return -1;

    // Calculate EVM memory expansion cost using quadratic formula
    // Gas cost = words * 3 + (words^2 / 512) where words = (size + 31) / 32
    const new_size = @as(u64, offset) + @as(u64, size);
    const current_size = @as(u64, h.memory.size());

    if (new_size <= current_size) {
        return 0; // No expansion needed
    }

    // Calculate word count (round up to 32-byte boundaries)
    const new_words = (new_size + 31) / 32;
    const current_words = (current_size + 31) / 32;

    // Calculate gas cost using EVM formula: cost = 3 * words + words^2 / 512
    const new_cost = 3 * new_words + (new_words * new_words) / 512;
    const current_cost = 3 * current_words + (current_words * current_words) / 512;

    const expansion_cost = new_cost - current_cost;
    return @intCast(expansion_cost);
}

// ============================================================================
// UTILITY FUNCTIONS
// ============================================================================

/// Copy memory within the same instance (MCOPY)
/// @param handle Memory handle
/// @param dest Destination offset
/// @param src Source offset
/// @param len Number of bytes to copy
/// @return Error code
pub export fn evm_memory_copy(handle: ?*MemoryHandle, dest: u32, src: u32, len: u32) c_int {
    const h = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;

    // Copy memory within the same instance
    const src_data = h.memory.get_slice(@intCast(src), @intCast(len)) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    // Make a copy since we can't use the slice directly (it might overlap)
    const temp = allocator.alloc(u8, len) catch return EVM_MEMORY_ERROR_OUT_OF_MEMORY;
    defer allocator.free(temp);
    @memcpy(temp, src_data);

    h.memory.set_data_evm(allocator, @intCast(dest), temp) catch |err| {
        return switch (err) {
            MemoryError.MemoryOverflow => EVM_MEMORY_ERROR_LIMIT_EXCEEDED,
            MemoryError.OutOfMemory => EVM_MEMORY_ERROR_OUT_OF_MEMORY,
            else => EVM_MEMORY_ERROR_EXPANSION_FAILED,
        };
    };

    return EVM_MEMORY_SUCCESS;
}

/// Fill memory region with zeros
/// @param handle Memory handle
/// @param offset Start offset
/// @param len Number of bytes to zero
/// @return Error code
pub export fn evm_memory_zero(handle: ?*MemoryHandle, offset: u32, len: u32) c_int {
    _ = handle orelse return EVM_MEMORY_ERROR_NULL_POINTER;
    
    const zeros = allocator.alloc(u8, len) catch return EVM_MEMORY_ERROR_OUT_OF_MEMORY;
    defer allocator.free(zeros);
    @memset(zeros, 0);
    
    return evm_memory_write_slice(handle, offset, zeros.ptr, len);
}

// ============================================================================
// TESTING FUNCTIONS
// ============================================================================

// ============================================================================
// FFI BOUNDARY TESTS
// ============================================================================

test "FFI boundary: write_byte with allocator" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Test writing byte at various offsets
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 0, 0x42));
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 100, 0xFF));
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 1000, 0xAA));

    // Verify reads
    var byte: u8 = 0;
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_byte(handle, 0, &byte));
    try std.testing.expectEqual(@as(u8, 0x42), byte);

    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_byte(handle, 100, &byte));
    try std.testing.expectEqual(@as(u8, 0xFF), byte);

    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_byte(handle, 1000, &byte));
    try std.testing.expectEqual(@as(u8, 0xAA), byte);
}

test "FFI boundary: write_u256 with allocator" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Create test values
    var test_value: [32]u8 = undefined;
    @memset(&test_value, 0xFF);
    test_value[0] = 0x12;
    test_value[31] = 0x34;

    // Write u256 at offset 0
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_u256(handle, 0, &test_value));

    // Read back and verify
    var read_value: [32]u8 = undefined;
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_u256(handle, 0, &read_value));
    try std.testing.expectEqualSlices(u8, &test_value, &read_value);

    // Write at different offset
    var test_value2: [32]u8 = undefined;
    @memset(&test_value2, 0xAA);
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_u256(handle, 64, &test_value2));

    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_u256(handle, 64, &read_value));
    try std.testing.expectEqualSlices(u8, &test_value2, &read_value);
}

test "FFI boundary: write_slice with allocator" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Test various slice sizes
    const small_data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_slice(handle, 0, &small_data, 4));

    var read_buffer: [100]u8 = undefined;
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_slice(handle, 0, &read_buffer, 4));
    try std.testing.expectEqualSlices(u8, &small_data, read_buffer[0..4]);

    // Test larger slice
    var large_data: [256]u8 = undefined;
    for (&large_data, 0..) |*b, i| b.* = @truncate(i);

    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_slice(handle, 100, &large_data, 256));
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_slice(handle, 100, &read_buffer, 100));
    try std.testing.expectEqualSlices(u8, large_data[0..100], read_buffer[0..100]);
}

test "FFI boundary: ensure_capacity with allocator" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Initial size should be 0
    try std.testing.expectEqual(@as(u32, 0), evm_memory_get_size(handle));

    // Ensure capacity to 64 bytes
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_ensure_capacity(handle, 64));
    const size1 = evm_memory_get_size(handle);
    try std.testing.expect(size1 >= 64);

    // Ensure larger capacity
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_ensure_capacity(handle, 1024));
    const size2 = evm_memory_get_size(handle);
    try std.testing.expect(size2 >= 1024);

    // Ensure same capacity should succeed
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_ensure_capacity(handle, 1024));
}

test "FFI boundary: copy with allocator" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Write source data
    const src_data = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_slice(handle, 0, &src_data, 8));

    // Copy data to different location
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_copy(handle, 100, 0, 8));

    // Verify copy
    var read_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_slice(handle, 100, &read_buffer, 8));
    try std.testing.expectEqualSlices(u8, &src_data, &read_buffer);

    // Test overlapping copy (forward)
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_copy(handle, 4, 0, 4));
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_slice(handle, 4, &read_buffer, 4));
    try std.testing.expectEqualSlices(u8, src_data[0..4], read_buffer[0..4]);
}

test "FFI boundary: null pointer handling" {
    // Test all functions with null pointers
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_write_byte(null, 0, 0));
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_write_u256(null, 0, null));
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_ensure_capacity(null, 100));
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_copy(null, 0, 0, 10));

    // Test with valid handle but null data pointer
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_write_u256(handle, 0, null));
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_read_byte(handle, 0, null));
    try std.testing.expectEqual(EVM_MEMORY_ERROR_NULL_POINTER, evm_memory_read_u256(handle, 0, null));
}

test "FFI boundary: memory expansion on write" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Initial size is 0
    try std.testing.expectEqual(@as(u32, 0), evm_memory_get_size(handle));

    // Write should expand memory with word alignment
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 100, 0x42));

    const size = evm_memory_get_size(handle);
    // Size should be at least 101 and word-aligned (multiple of 32)
    try std.testing.expect(size >= 101);
    try std.testing.expectEqual(@as(u32, 0), size % 32);
}

test "FFI boundary: zero initialization" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Write at offset 100 to expand memory
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 100, 0xFF));

    // Read bytes before written offset - should all be zero
    var byte: u8 = 0xFF;
    for (0..100) |i| {
        byte = 0xFF;
        try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_byte(handle, @intCast(i), &byte));
        try std.testing.expectEqual(@as(u8, 0), byte);
    }

    // Verify written byte
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_read_byte(handle, 100, &byte));
    try std.testing.expectEqual(@as(u8, 0xFF), byte);
}

test "FFI boundary: memory limits" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Try to exceed memory limit (16MB per DefaultMemoryConfig)
    const result = evm_memory_ensure_capacity(handle, 17 * 1024 * 1024);
    try std.testing.expectEqual(EVM_MEMORY_ERROR_LIMIT_EXCEEDED, result);
}

test "FFI boundary: reset clears memory" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Write some data
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_byte(handle, 100, 0x42));
    try std.testing.expect(evm_memory_get_size(handle) > 0);

    // Reset memory
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_reset(handle));
    try std.testing.expectEqual(@as(u32, 0), evm_memory_get_size(handle));
}

test "FFI boundary: copy with zero length" {
    const handle = evm_memory_create(100) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    // Copy zero bytes should succeed
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_copy(handle, 10, 0, 0));
}

test "FFI boundary: write_slice with zero length" {
    const handle = evm_memory_create(0) orelse return error.FailedToCreate;
    defer evm_memory_destroy(handle);

    const empty_data = [_]u8{};
    try std.testing.expectEqual(EVM_MEMORY_SUCCESS, evm_memory_write_slice(handle, 0, &empty_data, 0));
}

/// Test basic memory operations
pub export fn evm_memory_test_basic() c_int {
    const handle = evm_memory_create(0) orelse return -1;
    defer evm_memory_destroy(handle);
    
    // Test byte write/read
    if (evm_memory_write_byte(handle, 100, 0x42) != EVM_MEMORY_SUCCESS) return -2;
    
    var byte: u8 = 0;
    if (evm_memory_read_byte(handle, 100, &byte) != EVM_MEMORY_SUCCESS) return -3;
    if (byte != 0x42) return -4;
    
    // Test u256 write/read
    const test_value = [_]u8{0xFF} ** 32;
    if (evm_memory_write_u256(handle, 200, &test_value) != EVM_MEMORY_SUCCESS) return -5;
    
    var read_value: [32]u8 = undefined;
    if (evm_memory_read_u256(handle, 200, &read_value) != EVM_MEMORY_SUCCESS) return -6;
    if (!std.mem.eql(u8, &test_value, &read_value)) return -7;
    
    // Check size
    const size = evm_memory_get_size(handle);
    if (size < 232) return -8; // Should be at least 232 bytes
    
    return 0;
}

/// Test memory expansion and limits
pub export fn evm_memory_test_expansion() c_int {
    const handle = evm_memory_create(0) orelse return -1;
    defer evm_memory_destroy(handle);
    
    // Get initial size
    const initial_size = evm_memory_get_size(handle);
    if (initial_size != 0) return -2;
    
    // Write at offset causing expansion
    if (evm_memory_write_byte(handle, 1000, 0x55) != EVM_MEMORY_SUCCESS) return -3;
    
    // Check new size (should be word-aligned)
    const new_size = evm_memory_get_size(handle);
    if (new_size < 1001 or new_size % 32 != 0) return -4;
    
    // Test gas cost calculation
    const gas_cost = evm_memory_get_expansion_cost(handle, 2000, 100);
    if (gas_cost < 0) return -5;
    
    return 0;
}
