/// Control flow opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Handlers struct - provides control flow operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack, readMemory
/// and fields: pc (program counter), stopped, reverted, bytecode (with isValidJumpDest),
/// output, memory_size, allocator, evm_ptr
pub fn Handlers(FrameType: type) type {
    return struct {
        /// STOP opcode (0x00) - Halts execution
        pub fn stop(frame: *FrameType) FrameType.EvmError!void {
            frame.stopped = true;
            return;
        }

        /// JUMP opcode (0x56) - Unconditional jump
        pub fn jump(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasMidStep);
            const dest = try frame.popStack();
            const dest_pc = std.math.cast(u32, dest) orelse return error.OutOfBounds;

            // Validate jump destination
            if (!frame.bytecode.isValidJumpDest(dest_pc)) return error.InvalidJump;

            frame.pc = dest_pc;
        }

        /// JUMPI opcode (0x57) - Conditional jump
        pub fn jumpi(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasSlowStep);
            const dest = try frame.popStack();
            const condition = try frame.popStack();

            if (condition != 0) {
                const dest_pc = std.math.cast(u32, dest) orelse return error.OutOfBounds;

                // Validate jump destination
                if (!frame.bytecode.isValidJumpDest(dest_pc)) return error.InvalidJump;

                frame.pc = dest_pc;
            } else {
                frame.pc += 1;
            }
        }

        /// JUMPDEST opcode (0x5b) - Jump destination marker
        pub fn jumpdest(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.JumpdestGas);
            frame.pc += 1;
        }

        /// PC opcode (0x58) - Get program counter
        pub fn pc(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            try frame.pushStack(frame.pc);
            frame.pc += 1;
        }

        /// RETURN opcode (0xf3) - Halt execution and return output data
        pub fn ret(frame: *FrameType) FrameType.EvmError!void {
            const offset = try frame.popStack();
            const length = try frame.popStack();

            if (length > 0) {
                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

                // Check if off + len would overflow
                const end_offset = off +% len;
                if (end_offset < off) {
                    // Overflow occurred, return out of bounds error
                    return error.OutOfBounds;
                }

                // Charge memory expansion for the return slice
                const end_bytes = @as(u64, off) + @as(u64, len);
                const mem_cost = frame.memoryExpansionCost(end_bytes);
                try frame.consumeGas(mem_cost);
                const aligned_size = wordAlignedSize(end_bytes);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;

                frame.output = try frame.allocator.alloc(u8, len);
                var idx: u32 = 0;
                while (idx < len) : (idx += 1) {
                    const addr = try add_u32(off, idx);
                    frame.output[idx] = frame.readMemory(addr);
                }
            }

            frame.stopped = true;
            return;
        }

        /// REVERT opcode (0xfd) - Halt execution and revert state changes
        pub fn revert(frame: *FrameType) FrameType.EvmError!void {
            // EIP-140: REVERT was introduced in Byzantium hardfork
            const evm = frame.getEvm();
            if (evm.hardfork.isBefore(.BYZANTIUM)) return error.InvalidOpcode;

            const offset = try frame.popStack();
            const length = try frame.popStack();

            if (length > 0) {
                const off = std.math.cast(u32, offset) orelse return error.OutOfBounds;
                const len = std.math.cast(u32, length) orelse return error.OutOfBounds;

                // Charge memory expansion for the revert slice
                const end_bytes: u64 = @as(u64, off) + @as(u64, len);
                const mem_cost = frame.memoryExpansionCost(end_bytes);
                try frame.consumeGas(mem_cost);
                const aligned_size = wordAlignedSize(end_bytes);
                if (aligned_size > frame.memory_size) frame.memory_size = aligned_size;

                frame.output = try frame.allocator.alloc(u8, len);
                var idx: u32 = 0;
                while (idx < len) : (idx += 1) {
                    const addr = try add_u32(off, idx);
                    frame.output[idx] = frame.readMemory(addr);
                }
            }

            frame.reverted = true;
            return;
        }

        // Helper functions (inline for performance)

        /// Word count calculation for memory sizing
        inline fn wordCount(bytes: u64) u64 {
            return (bytes + 31) / 32;
        }

        /// Word-aligned size calculation
        inline fn wordAlignedSize(bytes: u64) u32 {
            const words = wordCount(bytes);
            return @intCast(words * 32);
        }

        /// Safe add helper for u32 indices
        inline fn add_u32(a: u32, b: u32) FrameType.EvmError!u32 {
            return std.math.add(u32, a, b) catch return error.OutOfBounds;
        }
    };
}
