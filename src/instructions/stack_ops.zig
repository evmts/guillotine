/// Shared stack operation instruction implementations
/// Phase 1.5 - Generic over FrameType, no gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_stack.zig
/// These implementations are pure stack operations - caller must handle gas and PC

const std = @import("std");

/// POP opcode (0x50) - Remove top item from stack
pub fn PopInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            _ = try frame.stack.pop();
        }
    };
}

/// PUSH0-PUSH32 opcodes (0x5f-0x7f) - Push immediate value onto stack
/// Opcode determines number of bytes to read from bytecode
/// PUSH0 (size=0) pushes 0, PUSH1-PUSH32 (size=1-32) read from bytecode
pub fn PushInstruction(comptime FrameType: type, comptime push_size: u8) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            // Use the frame's readImmediate method
            const value = frame.readImmediate(push_size) orelse return error.InvalidPush;
            try frame.stack.push(value);
        }
    };
}

/// DUP1-DUP16 opcodes (0x80-0x8f) - Duplicate stack item at position n
/// DUP1 (n=1) duplicates top item, DUP2 (n=2) duplicates second item, etc.
pub fn DupInstruction(comptime FrameType: type, comptime n: usize) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.dup_n(n);
        }
    };
}

/// SWAP1-SWAP16 opcodes (0x90-0x9f) - Swap top stack item with item at position n+1
/// SWAP1 (n=1) swaps top with second, SWAP2 (n=2) swaps top with third, etc.
pub fn SwapInstruction(comptime FrameType: type, comptime n: usize) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            try frame.stack.swap_n(n);
        }
    };
}
