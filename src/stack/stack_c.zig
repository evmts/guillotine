// ============================================================================
// STACK C API - FFI interface for EVM stack operations
// ============================================================================

const std = @import("std");
const evm = @import("evm");
const StackConfig = evm.StackConfig;
const Stack = evm.Stack;

const allocator = std.heap.c_allocator;

// Default stack configuration (EVM standard)
const DefaultStackConfig = StackConfig{
    .stack_size = 1024,
    .WordType = u256,
};

// ============================================================================
// ERROR CODES
// ============================================================================

const EVM_STACK_SUCCESS = 0;
const EVM_STACK_ERROR_NULL_POINTER = -1;
const EVM_STACK_ERROR_OVERFLOW = -2;
const EVM_STACK_ERROR_UNDERFLOW = -3;
const EVM_STACK_ERROR_OUT_OF_MEMORY = -4;
const EVM_STACK_ERROR_INVALID_INDEX = -5;

// ============================================================================
// OPAQUE HANDLE
// ============================================================================

const StackHandle = struct {
    stack: Stack(DefaultStackConfig),
};

// ============================================================================
// LIFECYCLE FUNCTIONS
// ============================================================================

/// Create a new EVM stack instance
/// @return Opaque stack handle, or NULL on failure
pub export fn evm_stack_create() ?*StackHandle {
    const handle = allocator.create(StackHandle) catch return null;
    errdefer allocator.destroy(handle);
    
    handle.* = StackHandle{
        .stack = Stack(DefaultStackConfig).init(allocator, null) catch {
            allocator.destroy(handle);
            return null;
        },
    };
    
    return handle;
}

/// Destroy stack instance and free memory
/// @param handle Stack handle
pub export fn evm_stack_destroy(handle: ?*StackHandle) void {
    const h = handle orelse return;
    h.stack.deinit(allocator);
    allocator.destroy(h);
}

/// Reset stack to empty state
/// @param handle Stack handle
/// @return Error code
pub export fn evm_stack_reset(handle: ?*StackHandle) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    // Reset stack by moving pointer to empty position (buf_ptr + capacity)
    // This is the safe way to reset: stack_ptr = buf_ptr + stack_capacity
    h.stack.stack_ptr = h.stack.buf_ptr + DefaultStackConfig.stack_size;
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// PUSH OPERATIONS
// ============================================================================

/// Push a 64-bit value onto the stack (zero-extended to 256 bits)
/// @param handle Stack handle
/// @param value Value to push
/// @return Error code
pub export fn evm_stack_push_u64(handle: ?*StackHandle, value: u64) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    h.stack.push(@as(u256, value)) catch |err| {
        return switch (err) {
            error.StackOverflow => EVM_STACK_ERROR_OVERFLOW,
            else => EVM_STACK_ERROR_OUT_OF_MEMORY,
        };
    };
    
    return EVM_STACK_SUCCESS;
}

/// Push a 256-bit value from bytes (big-endian)
/// @param handle Stack handle
/// @param bytes Pointer to 32-byte array (big-endian)
/// @return Error code
pub export fn evm_stack_push_bytes(handle: ?*StackHandle, bytes: ?*const [32]u8) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const b = bytes orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const value = std.mem.readInt(u256, b, .big);
    
    h.stack.push(value) catch |err| {
        return switch (err) {
            error.StackOverflow => EVM_STACK_ERROR_OVERFLOW,
            else => EVM_STACK_ERROR_OUT_OF_MEMORY,
        };
    };
    
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// POP OPERATIONS
// ============================================================================

/// Pop value from stack as 64-bit (truncated if larger)
/// @param handle Stack handle
/// @param value_out Pointer to store popped value
/// @return Error code
pub export fn evm_stack_pop_u64(handle: ?*StackHandle, value_out: ?*u64) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = value_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const value = h.stack.pop() catch |err| {
        return switch (err) {
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_UNDERFLOW,
        };
    };
    
    out.* = @truncate(value);
    return EVM_STACK_SUCCESS;
}

/// Pop value from stack as 256-bit bytes (big-endian)
/// @param handle Stack handle
/// @param bytes_out Pointer to 32-byte buffer
/// @return Error code
pub export fn evm_stack_pop_bytes(handle: ?*StackHandle, bytes_out: ?*[32]u8) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = bytes_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const value = h.stack.pop() catch |err| {
        return switch (err) {
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_UNDERFLOW,
        };
    };
    
    std.mem.writeInt(u256, out, value, .big);
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// PEEK/INSPECTION OPERATIONS
// ============================================================================

/// Peek at top of stack without removing (as 64-bit)
/// @param handle Stack handle
/// @param value_out Pointer to store peeked value
/// @return Error code
pub export fn evm_stack_peek_u64(handle: ?*StackHandle, value_out: ?*u64) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = value_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const value = h.stack.peek() catch |err| {
        return switch (err) {
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_UNDERFLOW,
        };
    };
    
    out.* = @truncate(value);
    return EVM_STACK_SUCCESS;
}

/// Peek at top of stack without removing (as 256-bit bytes)
/// @param handle Stack handle
/// @param bytes_out Pointer to 32-byte buffer
/// @return Error code
pub export fn evm_stack_peek_bytes(handle: ?*StackHandle, bytes_out: ?*[32]u8) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = bytes_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const value = h.stack.peek() catch |err| {
        return switch (err) {
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_UNDERFLOW,
        };
    };
    
    std.mem.writeInt(u256, out, value, .big);
    return EVM_STACK_SUCCESS;
}

/// Peek at specific depth (0 = top, 1 = second from top, etc.)
/// @param handle Stack handle
/// @param depth Stack depth to peek at
/// @param bytes_out Pointer to 32-byte buffer
/// @return Error code
pub export fn evm_stack_peek_at(handle: ?*StackHandle, depth: u32, bytes_out: ?*[32]u8) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = bytes_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    // Use get_slice to access stack elements
    const stack_slice = h.stack.get_slice();
    if (depth >= stack_slice.len) {
        return EVM_STACK_ERROR_UNDERFLOW;
    }
    
    const value = stack_slice[depth];
    std.mem.writeInt(u256, out, value, .big);
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// STACK OPERATIONS
// ============================================================================

/// Duplicate item at depth (DUP operation)
/// @param handle Stack handle
/// @param depth Item to duplicate (0 = top)
/// @return Error code
pub export fn evm_stack_dup(handle: ?*StackHandle, depth: u32) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    // Stack dup_n expects 1-based index (DUP1 duplicates top item)
    h.stack.dup_n(@intCast(depth + 1)) catch |err| {
        return switch (err) {
            error.StackOverflow => EVM_STACK_ERROR_OVERFLOW,
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_OUT_OF_MEMORY,
        };
    };
    
    return EVM_STACK_SUCCESS;
}

/// Swap top item with item at depth (SWAP operation)
/// @param handle Stack handle
/// @param depth Item to swap with top (1 = second from top)
/// @return Error code
pub export fn evm_stack_swap(handle: ?*StackHandle, depth: u32) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    h.stack.swap_n(@intCast(depth)) catch |err| {
        return switch (err) {
            error.StackUnderflow => EVM_STACK_ERROR_UNDERFLOW,
            else => EVM_STACK_ERROR_UNDERFLOW,
        };
    };
    
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// STACK INFORMATION
// ============================================================================

/// Get current stack depth
/// @param handle Stack handle
/// @return Stack depth (number of items), or 0 on error
pub export fn evm_stack_size(handle: ?*const StackHandle) u32 {
    const h = handle orelse return 0;
    return @intCast(h.stack.size());
}

/// Check if stack is empty
/// @param handle Stack handle
/// @return 1 if empty, 0 if not empty or on error
pub export fn evm_stack_is_empty(handle: ?*const StackHandle) c_int {
    const h = handle orelse return 0;
    return if (h.stack.size() == 0) 1 else 0;
}

/// Check if stack is full
/// @param handle Stack handle
/// @return 1 if full, 0 if not full or on error
pub export fn evm_stack_is_full(handle: ?*const StackHandle) c_int {
    const h = handle orelse return 0;
    return if (h.stack.size() >= DefaultStackConfig.stack_size) 1 else 0;
}

/// Get maximum stack capacity
/// @param handle Stack handle
/// @return Maximum capacity (1024 for EVM)
pub export fn evm_stack_capacity(handle: ?*const StackHandle) u32 {
    _ = handle;
    return DefaultStackConfig.stack_size;
}

// ============================================================================
// BULK OPERATIONS
// ============================================================================

/// Get entire stack contents
/// @param handle Stack handle
/// @param buffer Buffer to write stack items (32 bytes each)
/// @param max_items Maximum items to write
/// @param count_out Actual items written
/// @return Error code
pub export fn evm_stack_get_contents(handle: ?*const StackHandle, buffer: [*]u8, max_items: u32, count_out: ?*u32) c_int {
    const h = handle orelse return EVM_STACK_ERROR_NULL_POINTER;
    const out = count_out orelse return EVM_STACK_ERROR_NULL_POINTER;
    
    const depth = h.stack.size();
    const copy_count = @min(depth, max_items);
    
    // Get stack slice and copy items
    const stack_slice = h.stack.get_slice();
    var i: usize = 0;
    while (i < copy_count) : (i += 1) {
        const value = stack_slice[i];
        std.mem.writeInt(u256, buffer[i * 32 ..][0..32], value, .big);
    }
    
    out.* = @intCast(copy_count);
    return EVM_STACK_SUCCESS;
}

// ============================================================================
// TESTING FUNCTIONS
// ============================================================================

/// Test basic stack operations
pub export fn evm_stack_test_basic() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);
    
    // Test push/pop u64
    if (evm_stack_push_u64(handle, 42) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_push_u64(handle, 100) != EVM_STACK_SUCCESS) return -3;
    
    if (evm_stack_size(handle) != 2) return -4;
    
    var value: u64 = 0;
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) return -5;
    if (value != 100) return -6;
    
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) return -7;
    if (value != 42) return -8;
    
    if (evm_stack_is_empty(handle) != 1) return -9;
    
    return 0;
}

/// Test stack operations (DUP, SWAP, etc.)
pub export fn evm_stack_test_operations() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);
    
    // Push some values
    if (evm_stack_push_u64(handle, 1) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_push_u64(handle, 2) != EVM_STACK_SUCCESS) return -3;
    if (evm_stack_push_u64(handle, 3) != EVM_STACK_SUCCESS) return -4;
    
    // Test DUP1 (duplicate top)
    if (evm_stack_dup(handle, 0) != EVM_STACK_SUCCESS) return -5;
    if (evm_stack_size(handle) != 4) return -6;
    
    var value: u64 = 0;
    if (evm_stack_peek_u64(handle, &value) != EVM_STACK_SUCCESS) return -7;
    if (value != 3) return -8;
    
    // Test SWAP1 (swap top two)
    if (evm_stack_swap(handle, 1) != EVM_STACK_SUCCESS) return -9;
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) return -10;
    if (value != 2) return -11;
    
    return 0;
}

/// Test 256-bit operations
pub export fn evm_stack_test_u256() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Test with max u256 value
    const max_value = [_]u8{0xFF} ** 32;
    if (evm_stack_push_bytes(handle, &max_value) != EVM_STACK_SUCCESS) return -2;

    var out_value: [32]u8 = undefined;
    if (evm_stack_peek_bytes(handle, &out_value) != EVM_STACK_SUCCESS) return -3;

    if (!std.mem.eql(u8, &max_value, &out_value)) return -4;

    return 0;
}

/// Test reset on empty stack
pub export fn evm_stack_test_reset_empty() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Reset empty stack should succeed
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -2;

    // Stack should still be empty
    if (evm_stack_is_empty(handle) != 1) return -3;
    if (evm_stack_size(handle) != 0) return -4;

    return 0;
}

/// Test reset on non-empty stack
pub export fn evm_stack_test_reset_nonempty() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Push several values
    if (evm_stack_push_u64(handle, 1) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_push_u64(handle, 2) != EVM_STACK_SUCCESS) return -3;
    if (evm_stack_push_u64(handle, 3) != EVM_STACK_SUCCESS) return -4;

    // Verify stack has items
    if (evm_stack_size(handle) != 3) return -5;

    // Reset should clear the stack
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -6;

    // Stack should be empty
    if (evm_stack_is_empty(handle) != 1) return -7;
    if (evm_stack_size(handle) != 0) return -8;

    return 0;
}

/// Test operations after reset
pub export fn evm_stack_test_reset_operations() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Push and reset
    if (evm_stack_push_u64(handle, 42) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -3;

    // Pop should fail (underflow)
    var value: u64 = 0;
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_ERROR_UNDERFLOW) return -4;

    // Push should work after reset
    if (evm_stack_push_u64(handle, 100) != EVM_STACK_SUCCESS) return -5;
    if (evm_stack_size(handle) != 1) return -6;

    // Pop should get the new value
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) return -7;
    if (value != 100) return -8;

    return 0;
}

/// Test multiple reset operations
pub export fn evm_stack_test_multiple_resets() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Reset multiple times
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -3;
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -4;

    // Stack should still be empty and usable
    if (evm_stack_is_empty(handle) != 1) return -5;
    if (evm_stack_push_u64(handle, 123) != EVM_STACK_SUCCESS) return -6;
    if (evm_stack_size(handle) != 1) return -7;

    return 0;
}

/// Test error conditions
pub export fn evm_stack_test_errors() c_int {
    // Test with null handle
    if (evm_stack_reset(null) != EVM_STACK_ERROR_NULL_POINTER) return -1;
    if (evm_stack_push_u64(null, 42) != EVM_STACK_ERROR_NULL_POINTER) return -2;

    var value: u64 = 0;
    if (evm_stack_pop_u64(null, &value) != EVM_STACK_ERROR_NULL_POINTER) return -3;
    if (evm_stack_peek_u64(null, &value) != EVM_STACK_ERROR_NULL_POINTER) return -4;

    // Test underflow
    const handle = evm_stack_create() orelse return -5;
    defer evm_stack_destroy(handle);

    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_ERROR_UNDERFLOW) return -6;
    if (evm_stack_peek_u64(handle, &value) != EVM_STACK_ERROR_UNDERFLOW) return -7;

    return 0;
}

/// Test bulk operations
pub export fn evm_stack_test_bulk_operations() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Push multiple values
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        if (evm_stack_push_u64(handle, i) != EVM_STACK_SUCCESS) return -2;
    }

    if (evm_stack_size(handle) != 10) return -3;

    // Get contents
    var buffer: [32 * 10]u8 = undefined;
    var count: u32 = 0;
    if (evm_stack_get_contents(handle, &buffer, 10, &count) != EVM_STACK_SUCCESS) return -4;
    if (count != 10) return -5;

    return 0;
}

/// Test edge case: empty stack operations
pub export fn evm_stack_test_empty_stack() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Verify empty
    if (evm_stack_is_empty(handle) != 1) return -2;
    if (evm_stack_size(handle) != 0) return -3;
    if (evm_stack_is_full(handle) != 0) return -4;

    // Operations should fail
    var value: u64 = 0;
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_ERROR_UNDERFLOW) return -5;
    if (evm_stack_peek_u64(handle, &value) != EVM_STACK_ERROR_UNDERFLOW) return -6;

    // Bulk get on empty stack
    var buffer: [32]u8 = undefined;
    var count: u32 = 0;
    if (evm_stack_get_contents(handle, &buffer, 1, &count) != EVM_STACK_SUCCESS) return -7;
    if (count != 0) return -8;

    return 0;
}

/// Test edge case: full stack operations
pub export fn evm_stack_test_full_stack() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Fill stack to capacity (1024 items)
    var i: u32 = 0;
    while (i < DefaultStackConfig.stack_size) : (i += 1) {
        if (evm_stack_push_u64(handle, @intCast(i)) != EVM_STACK_SUCCESS) return -2;
    }

    // Should be full
    if (evm_stack_is_full(handle) != 1) return -3;
    if (evm_stack_size(handle) != DefaultStackConfig.stack_size) return -4;

    // Next push should overflow
    if (evm_stack_push_u64(handle, 9999) != EVM_STACK_ERROR_OVERFLOW) return -5;

    // Reset and verify empty
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -6;
    if (evm_stack_is_empty(handle) != 1) return -7;

    return 0;
}

/// Test peek operations at various depths
pub export fn evm_stack_test_peek_depth() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Push values 0-9
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        if (evm_stack_push_u64(handle, i) != EVM_STACK_SUCCESS) return -2;
    }

    // Peek at various depths (stack is LIFO: top=9, depth1=8, etc.)
    var bytes: [32]u8 = undefined;

    // Peek at top (should be 9)
    if (evm_stack_peek_at(handle, 0, &bytes) != EVM_STACK_SUCCESS) return -3;
    const top_val = std.mem.readInt(u256, &bytes, .big);
    if (top_val != 9) return -4;

    // Peek at depth 5 (should be 4)
    if (evm_stack_peek_at(handle, 5, &bytes) != EVM_STACK_SUCCESS) return -5;
    const depth5_val = std.mem.readInt(u256, &bytes, .big);
    if (depth5_val != 4) return -6;

    // Peek at invalid depth should fail
    if (evm_stack_peek_at(handle, 100, &bytes) != EVM_STACK_ERROR_UNDERFLOW) return -7;

    return 0;
}

/// Test stack lifecycle
pub export fn evm_stack_test_lifecycle() c_int {
    // Create and destroy multiple times
    var iteration: u32 = 0;
    while (iteration < 5) : (iteration += 1) {
        const handle = evm_stack_create() orelse return -1;

        if (evm_stack_push_u64(handle, 42) != EVM_STACK_SUCCESS) {
            evm_stack_destroy(handle);
            return -2;
        }

        var value: u64 = 0;
        if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) {
            evm_stack_destroy(handle);
            return -3;
        }

        if (value != 42) {
            evm_stack_destroy(handle);
            return -4;
        }

        evm_stack_destroy(handle);
    }

    return 0;
}

/// Test large value operations (full 256-bit)
pub export fn evm_stack_test_large_values() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Test with various large values
    const test_values = [_][32]u8{
        [_]u8{0xFF} ** 32,  // Max value
        [_]u8{0x00} ** 32,  // Zero
        [_]u8{0x01} ++ ([_]u8{0x00} ** 31),  // Large number
        [_]u8{0x00} ** 31 ++ [_]u8{0xFF},  // Small number
    };

    for (test_values) |test_val| {
        if (evm_stack_push_bytes(handle, &test_val) != EVM_STACK_SUCCESS) return -2;

        var out_val: [32]u8 = undefined;
        if (evm_stack_pop_bytes(handle, &out_val) != EVM_STACK_SUCCESS) return -3;

        if (!std.mem.eql(u8, &test_val, &out_val)) return -4;
    }

    return 0;
}

/// Test mixed operations (push, pop, dup, swap, reset)
pub export fn evm_stack_test_mixed_operations() c_int {
    const handle = evm_stack_create() orelse return -1;
    defer evm_stack_destroy(handle);

    // Push some values
    if (evm_stack_push_u64(handle, 10) != EVM_STACK_SUCCESS) return -2;
    if (evm_stack_push_u64(handle, 20) != EVM_STACK_SUCCESS) return -3;
    if (evm_stack_push_u64(handle, 30) != EVM_STACK_SUCCESS) return -4;

    // DUP top (30)
    if (evm_stack_dup(handle, 0) != EVM_STACK_SUCCESS) return -5;
    if (evm_stack_size(handle) != 4) return -6;

    // SWAP (swap 30 and 30, no effect but tests operation)
    if (evm_stack_swap(handle, 1) != EVM_STACK_SUCCESS) return -7;

    // Pop and verify
    var value: u64 = 0;
    if (evm_stack_pop_u64(handle, &value) != EVM_STACK_SUCCESS) return -8;
    if (value != 30) return -9;

    // Reset
    if (evm_stack_reset(handle) != EVM_STACK_SUCCESS) return -10;
    if (evm_stack_is_empty(handle) != 1) return -11;

    // Push after reset
    if (evm_stack_push_u64(handle, 99) != EVM_STACK_SUCCESS) return -12;
    if (evm_stack_size(handle) != 1) return -13;

    return 0;
}

// ============================================================================
// ZIG UNIT TESTS
// ============================================================================

test "C API: reset on empty stack" {
    const result = evm_stack_test_reset_empty();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: reset on non-empty stack" {
    const result = evm_stack_test_reset_nonempty();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: operations after reset" {
    const result = evm_stack_test_reset_operations();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: multiple resets" {
    const result = evm_stack_test_multiple_resets();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: error conditions" {
    const result = evm_stack_test_errors();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: bulk operations" {
    const result = evm_stack_test_bulk_operations();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: empty stack operations" {
    const result = evm_stack_test_empty_stack();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: full stack operations" {
    const result = evm_stack_test_full_stack();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: peek at various depths" {
    const result = evm_stack_test_peek_depth();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: stack lifecycle" {
    const result = evm_stack_test_lifecycle();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: large value operations" {
    const result = evm_stack_test_large_values();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: mixed operations" {
    const result = evm_stack_test_mixed_operations();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: basic operations" {
    const result = evm_stack_test_basic();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: stack operations (DUP/SWAP)" {
    const result = evm_stack_test_operations();
    try std.testing.expectEqual(@as(c_int, 0), result);
}

test "C API: 256-bit operations" {
    const result = evm_stack_test_u256();
    try std.testing.expectEqual(@as(c_int, 0), result);
}
