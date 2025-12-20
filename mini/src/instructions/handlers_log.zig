/// Log opcode handlers for the EVM (LOG0-LOG4)
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;
const call_result = @import("../call_result.zig");

/// Calculate LOG operation gas cost
inline fn logGasCost(topic_count: u8, data_size: u32) u64 {
    const base_cost = GasConstants.LogGas;
    const topic_cost = @as(u64, topic_count) * GasConstants.LogTopicGas;
    const data_cost = @as(u64, data_size) * GasConstants.LogDataGas;
    return base_cost + topic_cost + data_cost;
}

/// Calculate word count (32-byte words)
inline fn wordCount(bytes: u64) u64 {
    return (bytes + 31) / 32;
}

/// Calculate word-aligned memory size for EVM compliance
inline fn wordAlignedSize(bytes: u64) u32 {
    const words = wordCount(bytes);
    return @intCast(words * 32);
}

/// Handlers struct - provides log operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, memoryExpansionCost
/// and fields: pc, memory_size, is_static
pub fn Handlers(FrameType: type) type {
    return struct {
        /// LOG0-LOG4 opcodes (0xa0-0xa4) - Emit log entries with 0-4 indexed topics
        /// Takes opcode as parameter to determine topic count (0xa0=LOG0, 0xa1=LOG1, etc.)
        pub fn log(frame: *FrameType, opcode: u8) FrameType.EvmError!void {
            // EIP-214: LOG opcodes cannot be executed in static call context
            if (frame.is_static) return error.StaticCallViolation;

            const topic_count = opcode - 0xa0;
            const offset = try frame.popStack();
            const length = try frame.popStack();

            // Gas cost + memory expansion for log data
            const off_u32 = std.math.cast(u32, offset) orelse return error.OutOfBounds;
            const length_u32 = std.math.cast(u32, length) orelse return error.OutOfBounds;
            const log_cost = logGasCost(topic_count, length_u32);
            try frame.consumeGas(log_cost);
            if (length_u32 > 0) {
                const end_bytes: u64 = @as(u64, off_u32) + @as(u64, length_u32);
                const mem_cost = frame.memoryExpansionCost(end_bytes);
                try frame.consumeGas(mem_cost);
                const aligned = wordAlignedSize(end_bytes);
                if (aligned > frame.memory_size) frame.memory_size = aligned;
            }

            const evm = frame.getEvm();

            // Read topics (store them so we can add to log)
            const topics_len: usize = topic_count;
            var topics_tmp: [4]u256 = undefined; // max 4 topics
            var ti: usize = 0;
            while (ti < topics_len) : (ti += 1) {
                topics_tmp[ti] = try frame.popStack();
            }

            // Read data from memory
            var data_slice: []u8 = &[_]u8{};
            if (length_u32 > 0) {
                const alloc = evm.arena.allocator();
                const buf = try alloc.alloc(u8, length_u32);
                var idx: u32 = 0;
                while (idx < length_u32) : (idx += 1) {
                    buf[idx] = frame.readMemory(off_u32 + idx);
                }
                data_slice = buf;
            }

            // Allocate topics in arena and copy (reverse order if needed)
            var topics_slice: []u256 = &[_]u256{};
            if (topics_len > 0) {
                const alloc = evm.arena.allocator();
                const topics_buf = try alloc.alloc(u256, topics_len);
                var k: usize = 0;
                while (k < topics_len) : (k += 1) {
                    topics_buf[k] = topics_tmp[k];
                }
                topics_slice = topics_buf;
            }

            // Append log to EVM logs buffer
            const log_entry = call_result.Log{
                .address = frame.address,
                .topics = topics_slice,
                .data = data_slice,
            };
            try evm.logs.append(evm.arena.allocator(), log_entry);

            frame.pc += 1;
        }
    };
}
