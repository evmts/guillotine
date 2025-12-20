/// Keccak256 (SHA3) opcode handler for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Helper function to calculate word count (needed for gas calculation)
inline fn wordCount(bytes: u64) u64 {
    return (bytes + 31) / 32;
}

/// Helper function to calculate word-aligned memory size
inline fn wordAlignedSize(bytes: u64) u32 {
    const words = wordCount(bytes);
    return @intCast(words * 32);
}

/// Helper function for safe u32 addition
inline fn add_u32(a: u32, b: u32) error{OutOfBounds}!u32 {
    return std.math.add(u32, a, b) catch return error.OutOfBounds;
}

/// Calculate KECCAK256 gas cost
fn keccak256GasCost(data_size: u32) u64 {
    const words = wordCount(@as(u64, data_size));
    return GasConstants.Keccak256Gas + words * GasConstants.Keccak256WordGas;
}

/// Handlers struct - provides keccak256 operation handler for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack, readMemory, memoryExpansionCost
/// and fields: pc, memory_size, allocator
pub fn Handlers(FrameType: type) type {
    return struct {
        /// SHA3/KECCAK256 opcode (0x20) - Compute Keccak-256 hash
        pub fn sha3(frame: *FrameType) FrameType.EvmError!void {
            const offset = try frame.popStack();
            const size = try frame.popStack();

            // Use centralized gas calculation
            const size_u32 = std.math.cast(u32, size) orelse return error.OutOfBounds;
            const gas_cost = keccak256GasCost(size_u32);
            try frame.consumeGas(gas_cost);

            // Handle empty data case
            if (size == 0) {
                // Keccak-256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
                const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                try frame.pushStack(empty_hash);
                frame.pc += 1;
            } else {
                const offset_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Charge memory expansion to cover [offset, offset+size)
                const end_addr = @as(u64, offset_u32) + @as(u64, size_u32);
                const mem_cost = frame.memoryExpansionCost(end_addr);
                try frame.consumeGas(mem_cost);
                const aligned_size = wordAlignedSize(end_addr);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;

                // Read data from memory
                var data = try frame.allocator.alloc(u8, size_u32);
                // No defer free needed with arena allocator

                var i: u32 = 0;
                while (i < size_u32) : (i += 1) {
                    const addr = try add_u32(offset_u32, i);
                    data[i] = frame.readMemory(addr);
                }

                // Compute Keccak-256 hash using std library
                var hash_bytes: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(data, &hash_bytes, .{});

                // Convert hash bytes to u256 (big-endian)
                const hash_u256 = std.mem.readInt(u256, &hash_bytes, .big);
                try frame.pushStack(hash_u256);
                frame.pc += 1;
            }
        }
    };
}
