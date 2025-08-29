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
        handle.memory.ensure_capacity(allocator, initial_size) catch {
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
    
    h.memory.set_byte_evm(@intCast(offset), value) catch |err| {
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
    
    h.memory.set_u256_evm(@intCast(offset), value) catch |err| {
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
    
    h.memory.set_data_evm(@intCast(offset), data_in[0..len]) catch |err| {
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
    
    h.memory.ensure_capacity(@intCast(new_capacity)) catch |err| {
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
    
    // Calculate memory expansion cost
    const new_size = offset + size;
    // Since get_expansion_cost is not available in const context, return a fixed value
    // TODO: Implement proper gas calculation
    const cost: u64 = if (new_size > h.memory.size()) 3 * (new_size - h.memory.size()) else 0;
    return @intCast(cost);
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
    
    h.memory.set_data_evm(@intCast(dest), temp) catch |err| {
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
