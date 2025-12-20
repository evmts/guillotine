/// Stack manipulation opcode handlers for the EVM
const std = @import("std");
const primitives = @import("primitives");
const GasConstants = primitives.GasConstants;

/// Handlers struct - provides stack operation handlers for a Frame type
/// The FrameType must have methods: consumeGas, popStack, pushStack
/// and fields: pc (program counter), stack, bytecode
pub fn Handlers(FrameType: type) type {
    return struct {
        /// POP opcode (0x50) - Remove top item from stack
        pub fn pop(frame: *FrameType) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasQuickStep);
            _ = try frame.popStack();
            frame.pc += 1;
        }

        /// PUSH0-PUSH32 opcodes (0x5f-0x7f) - Push immediate value onto stack
        /// Opcode determines number of bytes to read from bytecode
        /// PUSH0 (0x5f) costs 2 gas, PUSH1-PUSH32 (0x60-0x7f) cost 3 gas
        pub fn push(frame: *FrameType, opcode: u8) FrameType.EvmError!void {
            const push_size = opcode - 0x5f;

            // EIP-3855: PUSH0 was introduced in Shanghai hardfork
            if (push_size == 0) {
                const evm = frame.getEvm();
                if (evm.hardfork.isBefore(.SHANGHAI)) {
                    return error.InvalidOpcode;
                }
                try frame.consumeGas(GasConstants.GasQuickStep);
            } else {
                try frame.consumeGas(GasConstants.GasFastestStep);
            }

            // Use the bytecode module's readImmediate method
            const value = frame.readImmediate(push_size) orelse return error.InvalidPush;

            try frame.pushStack(value);
            frame.pc += 1 + push_size;
        }

        /// DUP1-DUP16 opcodes (0x80-0x8f) - Duplicate stack item at position n
        /// DUP1 duplicates top item, DUP2 duplicates second item, etc.
        pub fn dup(frame: *FrameType, opcode: u8) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const n = opcode - 0x7f;
            if (frame.stack.items.len < n) {
                return error.StackUnderflow;
            }
            const value = frame.stack.items[frame.stack.items.len - n];
            try frame.pushStack(value);
            frame.pc += 1;
        }

        /// SWAP1-SWAP16 opcodes (0x90-0x9f) - Swap top stack item with item at position n+1
        /// SWAP1 swaps top with second, SWAP2 swaps top with third, etc.
        pub fn swap(frame: *FrameType, opcode: u8) FrameType.EvmError!void {
            try frame.consumeGas(GasConstants.GasFastestStep);
            const n = opcode - 0x8f;
            if (frame.stack.items.len <= n) {
                return error.StackUnderflow;
            }
            const top_idx = frame.stack.items.len - 1;
            const swap_idx = frame.stack.items.len - 1 - n;
            const temp = frame.stack.items[top_idx];
            frame.stack.items[top_idx] = frame.stack.items[swap_idx];
            frame.stack.items[swap_idx] = temp;
            frame.pc += 1;
        }
    };
}
