const std = @import("std");
const builtin = @import("builtin");

const primitives = @import("primitives");

// Export primitives types and functions for C interface
pub const Address = primitives.Address;
pub const Transaction = primitives.Transaction;
pub const Block = primitives.Block;
pub const B256 = primitives.B256;
pub const B64 = primitives.B64;
pub const U64 = primitives.U64;
pub const U256 = primitives.U256;

// Simple inline logging that compiles out for freestanding WASM
fn log(comptime level: std.log.Level, comptime scope: @TypeOf(.enum_literal), comptime format: []const u8, args: anytype) void {
    _ = scope;
    if (builtin.target.cpu.arch != .wasm32 or builtin.target.os.tag != .freestanding) {
        switch (level) {
            .err => std.log.err("[primitives_c] " ++ format, args),
            .warn => std.log.warn("[primitives_c] " ++ format, args),
            .info => std.log.info("[primitives_c] " ++ format, args),
            .debug => std.log.debug("[primitives_c] " ++ format, args),
        }
    }
}

// Global allocator for WASM environment
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = if (builtin.target.cpu.arch == .wasm32) std.heap.wasm_allocator else gpa.allocator();

// C-compatible error codes
const PrimitivesError = enum(c_int) {
    PRIMITIVES_OK = 0,
    PRIMITIVES_ERROR_MEMORY = 1,
    PRIMITIVES_ERROR_INVALID_PARAM = 2,
    PRIMITIVES_ERROR_INVALID_ADDRESS = 3,
    PRIMITIVES_ERROR_INVALID_HASH = 4,
};

/// Initialize the primitives library
/// @return Error code (0 = success)
export fn primitives_init() c_int {
    log(.info, .primitives_c, "Initializing primitives library", .{});
    return @intFromEnum(PrimitivesError.PRIMITIVES_OK);
}

/// Cleanup the primitives library
export fn primitives_deinit() void {
    log(.info, .primitives_c, "Destroying primitives library", .{});
}

/// Create an address from bytes
/// @param bytes_ptr Pointer to 20 bytes
/// @param out_ptr Pointer to output address structure
/// @return Error code (0 = success)
export fn primitives_address_from_bytes(bytes_ptr: [*]const u8, out_ptr: *primitives.Address.Address) c_int {
    const bytes = bytes_ptr[0..20];
    out_ptr.* = bytes.*;
    return @intFromEnum(PrimitivesError.PRIMITIVES_OK);
}

/// Check if an address is zero
/// @param addr_ptr Pointer to address
/// @return 1 if zero, 0 otherwise
export fn primitives_address_is_zero(addr_ptr: *const primitives.Address.Address) c_int {
    return if (std.mem.eql(u8, &addr_ptr.*, &primitives.Address.ZERO_ADDRESS)) 1 else 0;
}

/// Parse a U256 from bytes (little endian)
/// @param bytes_ptr Pointer to 32 bytes
/// @param out_ptr Pointer to output U256
/// @return Error code (0 = success)
export fn primitives_u256_from_bytes_le(bytes_ptr: [*]const u8, out_ptr: *u256) c_int {
    const bytes = bytes_ptr[0..32];
    var value: u256 = 0;
    for (bytes, 0..) |byte, i| {
        value |= @as(u256, byte) << @intCast(i * 8);
    }
    out_ptr.* = value;
    return @intFromEnum(PrimitivesError.PRIMITIVES_OK);
}

/// Convert U256 to bytes (little endian)
/// @param value_ptr Pointer to U256 value
/// @param out_ptr Pointer to output buffer (32 bytes)
/// @return Error code (0 = success)
export fn primitives_u256_to_bytes_le(value_ptr: *const u256, out_ptr: [*]u8) c_int {
    const value = value_ptr.*;
    var bytes = out_ptr[0..32];
    for (0..32) |i| {
        bytes[i] = @truncate((value >> @intCast(i * 8)) & 0xff);
    }
    return @intFromEnum(PrimitivesError.PRIMITIVES_OK);
}

/// Get version string
/// @return Pointer to null-terminated version string
export fn primitives_version() [*:0]const u8 {
    return "1.0.0";
}

// Test to ensure this compiles
test "C interface compilation" {
    std.testing.refAllDecls(@This());
}
