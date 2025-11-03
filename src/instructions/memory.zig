/// Shared memory instruction implementations
/// Phase 3 - Generic over FrameType, no static gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_memory.zig
/// These implementations access memory - caller must handle gas and PC

const std = @import("std");

/// Helper: Safe add for u32 indices
inline fn add_u32(a: u32, b: u32) error{OutOfBounds}!u32 {
    return std.math.add(u32, a, b) catch return error.OutOfBounds;
}

/// Helper: Calculate word-aligned size
fn wordAlignedSize(byte_size: u64) u64 {
    return ((byte_size + 31) / 32) * 32;
}

/// Helper: Calculate copy gas cost (3 gas per word)
fn copyGasCost(size_bytes: u32) u64 {
    const words = (size_bytes + 31) / 32;
    return @as(u64, words) * 3;
}

/// MLOAD opcode (0x51) - Load word from memory
/// Note: Caller must charge GasFastestStep + mem_expansion_cost
pub fn MloadInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const offset = try frame.stack.pop();
            const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

            // Dynamic gas: memory expansion for reading 32 bytes
            const end_bytes: u64 = @as(u64, off) + 32;
            const mem_cost = frame.memoryExpansionCost(end_bytes);
            try frame.consumeGas(mem_cost);
            const aligned_size = wordAlignedSize(end_bytes);
            const aligned_size_u32 = std.math.cast(u32, aligned_size) orelse return error.OutOfBounds;
            if (aligned_size_u32 > frame.memory_size) frame.memory_size = aligned_size_u32;

            // Read word from memory (big-endian)
            var result: u256 = 0;
            var idx: u32 = 0;
            while (idx < 32) : (idx += 1) {
                const addr = try add_u32(off, idx);
                const byte = frame.readMemory(addr);
                result = (result << 8) | byte;
            }
            try frame.stack.push(result);
        }
    };
}

/// MSTORE opcode (0x52) - Save word to memory
/// Note: Caller must charge GasFastestStep + mem_expansion_cost
pub fn MstoreInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();

            const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;

            // Dynamic gas: memory expansion for writing 32 bytes
            const end_bytes: u64 = @as(u64, off) + 32;
            const mem_cost = frame.memoryExpansionCost(end_bytes);
            try frame.consumeGas(mem_cost);

            // Write word to memory (big-endian)
            var idx: u32 = 0;
            while (idx < 32) : (idx += 1) {
                const byte = @as(u8, @truncate(value >> @intCast((31 - idx) * 8)));
                const addr = try add_u32(off, idx);
                try frame.writeMemory(addr, byte);
            }
        }
    };
}

/// MSTORE8 opcode (0x53) - Save byte to memory
/// Note: Caller must charge GasFastestStep + mem_expansion_cost
pub fn Mstore8Instruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const offset = try frame.stack.pop();
            const value = try frame.stack.pop();

            const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const end_bytes: u64 = @as(u64, off) + 1;
            const mem_cost = frame.memoryExpansionCost(end_bytes);
            try frame.consumeGas(mem_cost);
            const byte_value = @as(u8, @truncate(value));
            try frame.writeMemory(off, byte_value);
        }
    };
}

/// MSIZE opcode (0x59) - Get size of active memory in bytes
pub fn MsizeInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Memory size is already tracked as word-aligned in memory_size field
            try frame.stack.push(frame.memory_size);
        }
    };
}

/// MCOPY opcode (0x5e) - Copy memory (EIP-5656, Cancun+)
/// Note: Caller must charge GasFastestStep + mem_expansion_cost + copy_cost
/// Note: Requires hardfork check (Cancun+)
pub fn McopyInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // EIP-5656: MCOPY was introduced in Cancun hardfork
            if (frame.hardfork.isBefore(.CANCUN)) return error.InvalidOpcode;

            // Stack order (top to bottom): dest, src, len
            // Pop order: dest (first), src (second), len (third)
            const dest = try frame.stack.pop();
            const src = try frame.stack.pop();
            const len = try frame.stack.pop();

            // Calculate memory expansion cost BEFORE bounds checking
            // Per EIP-5656, if len == 0, no memory expansion occurs regardless of src/dest values
            // Otherwise, memory must be expanded to accommodate BOTH src+len and dest+len

            const mem_cost = if (len == 0)
                0 // Zero-length copies don't expand memory
            else blk: {
                // Safe conversion: if values don't fit in u64, use maxInt(u64) which will trigger
                // massive gas cost in memoryExpansionCost
                const dest_u64 = std.math.cast(u64, dest) orelse std.math.maxInt(u64);
                const src_u64 = std.math.cast(u64, src) orelse std.math.maxInt(u64);
                const len_u64 = std.math.cast(u64, len) orelse std.math.maxInt(u64);

                // Calculate end positions for both source and destination
                const end_dest: u64 = dest_u64 +| len_u64; // saturating add to prevent overflow
                const end_src: u64 = src_u64 +| len_u64;

                // Memory expansion must cover BOTH ranges - use the maximum
                const max_end = @max(end_dest, end_src);
                break :blk frame.memoryExpansionCost(max_end);
            };

            // For copy cost, we need to handle len > u32::MAX specially
            // If len doesn't fit in u32, the copy cost will be astronomical
            const copy_cost: u64 = if (len <= std.math.maxInt(u32))
                copyGasCost(@intCast(len))
            else
                std.math.maxInt(u64); // Huge value that will trigger OutOfGas

            // Use saturating arithmetic to prevent overflow when adding gas costs
            const total_gas = mem_cost +| copy_cost;
            try frame.consumeGas(total_gas);

            // Fast path: zero length - gas charged but no copy needed
            if (len == 0) {
                return;
            }

            // Now that gas is charged, do bounds checking for actual memory operations
            const dest_u32 = std.math.cast(u32, dest) orelse return error.OutOfBounds;
            const src_u32 = std.math.cast(u32, src) orelse return error.OutOfBounds;
            const len_u32 = std.math.cast(u32, len) orelse return error.OutOfBounds;

            // Expand memory to cover BOTH source and destination ranges
            // Per EIP-5656, memory expansion happens before the copy operation
            const src_end: u64 = @as(u64, src_u32) + @as(u64, len_u32);
            const dest_end: u64 = @as(u64, dest_u32) + @as(u64, len_u32);
            const max_memory_end = @max(src_end, dest_end);
            const required_size = wordAlignedSize(max_memory_end);
            const required_size_u32 = std.math.cast(u32, required_size) orelse return error.OutOfBounds;
            if (required_size_u32 > frame.memory_size) {
                frame.memory_size = required_size_u32;
            }

            // Copy via temporary buffer to handle overlapping regions
            const tmp = try frame.allocator.alloc(u8, len_u32);
            // No defer free needed with arena allocator

            var i: u32 = 0;
            while (i < len_u32) : (i += 1) {
                const s = try add_u32(src_u32, i);
                tmp[i] = frame.readMemory(s);
            }
            i = 0;
            while (i < len_u32) : (i += 1) {
                const d = try add_u32(dest_u32, i);
                try frame.writeMemory(d, tmp[i]);
            }
        }
    };
}

/// SHA3/KECCAK256 opcode (0x20) - Compute Keccak-256 hash
/// Note: Caller must charge keccak256_gas_cost + mem_expansion_cost
pub fn Keccak256Instruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const primitives = @import("primitives");
            const GasConstants = primitives.GasConstants;

            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            // Dynamic gas: base + per-word cost
            const size_u32 = std.math.cast(u32, size) orelse return error.OutOfBounds;
            const words = (size_u32 + 31) / 32;
            const gas_cost = GasConstants.Keccak256Gas + @as(u64, words) * GasConstants.Keccak256WordGas;
            try frame.consumeGas(gas_cost);

            // Handle empty data case
            if (size == 0) {
                // Keccak-256("") = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470
                const empty_hash: u256 = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
                try frame.stack.push(empty_hash);
            } else {
                const offset_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;

                // Charge memory expansion to cover [offset, offset+size)
                const end_addr = @as(u64, offset_u32) + @as(u64, size_u32);
                const mem_cost = frame.memoryExpansionCost(end_addr);
                try frame.consumeGas(mem_cost);
                const aligned_size = wordAlignedSize(end_addr);
                const aligned_size_u32 = std.math.cast(u32, aligned_size) orelse return error.OutOfBounds;
                if (aligned_size_u32 > frame.memory_size) frame.memory_size = aligned_size_u32;

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
                try frame.stack.push(hash_u256);
            }
        }
    };
}
