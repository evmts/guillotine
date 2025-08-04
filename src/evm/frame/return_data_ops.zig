const std = @import("std");
const Frame = @import("frame_fat.zig");
const Log = @import("../log.zig");

/// Error types for return data operations
pub const ReturnDataError = error{
    InvalidReturnDataAccess,
    OutOfMemory,
};

// ============================================================================
// RETURN DATA OPERATIONS
// ============================================================================

/// Set return data from call result.
///
/// Replaces current return data with new data from a call operation.
/// This is called after each CALL, DELEGATECALL, STATICCALL, or CALLCODE.
///
/// @param self The frame containing the return data
/// @param new_data New return data to store (may be empty)
/// @throws OutOfMemory if buffer allocation fails
pub fn return_data_set(self: *Frame, new_data: []const u8) ReturnDataError!void {
    // Clear existing data while retaining capacity
    self.return_data_buffer.clearRetainingCapacity();
    
    // Append new data
    self.return_data_buffer.appendSlice(new_data) catch |err| {
        return switch (err) {
            error.OutOfMemory => ReturnDataError.OutOfMemory,
        };
    };
    
    // Debug logging
    Log.debug("ReturnData.set: new size = {} bytes", .{new_data.len});
    if (new_data.len > 0 and new_data.len <= 32) {
        Log.debug("ReturnData.set: data = {x}", .{std.fmt.fmtSliceHexLower(new_data)});
    } else if (new_data.len > 32) {
        Log.debug("ReturnData.set: data (first 32 bytes) = {x}", .{std.fmt.fmtSliceHexLower(new_data[0..32])});
    }
}

/// Get current return data.
///
/// Returns a read-only view of the current return data.
/// The returned slice is valid until the next set() call.
///
/// @param self The frame containing the return data
/// @return Slice containing current return data
pub fn return_data_get(self: *const Frame) []const u8 {
    return self.return_data_buffer.items;
}

/// Get current return data size.
///
/// Returns the number of bytes in the current return data buffer.
/// This corresponds to the value returned by the RETURNDATASIZE opcode.
///
/// @param self The frame containing the return data
/// @return Size of return data in bytes
pub fn return_data_size(self: *const Frame) usize {
    return self.return_data_buffer.items.len;
}

/// Copy return data to destination buffer.
///
/// Copies a range of return data to the provided buffer.
/// Used by RETURNDATACOPY opcode implementation.
///
/// @param self The frame containing the return data
/// @param dest Destination buffer to copy to
/// @param src_offset Offset in return data to start copying from
/// @param copy_size Number of bytes to copy
/// @throws InvalidReturnDataAccess if range is out of bounds
pub fn return_data_copy_to(
    self: *const Frame,
    dest: []u8,
    src_offset: usize,
    copy_size: usize,
) ReturnDataError!void {
    const return_data = self.return_data_buffer.items;
    
    // Validate bounds
    if (src_offset + copy_size > return_data.len) {
        return ReturnDataError.InvalidReturnDataAccess;
    }
    
    if (copy_size > dest.len) {
        return ReturnDataError.InvalidReturnDataAccess;
    }
    
    // Copy data
    const source_slice = return_data[src_offset .. src_offset + copy_size];
    @memcpy(dest[0..copy_size], source_slice);
}

/// Clear return data buffer.
///
/// Removes all return data, setting size to 0.
/// This is automatically called before each new call operation.
///
/// @param self The frame containing the return data
pub fn return_data_clear(self: *Frame) void {
    self.return_data_buffer.clearRetainingCapacity();
}

/// Check if return data buffer is empty.
///
/// @param self The frame containing the return data
/// @return true if buffer contains no data
pub fn return_data_is_empty(self: *const Frame) bool {
    return self.return_data_buffer.items.len == 0;
}