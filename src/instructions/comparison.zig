/// Shared comparison instruction implementations
/// Phase 1.4 - Generic over FrameType, no gas charging, no PC manipulation
///
/// Source of truth: guillotine-mini/src/instructions/handlers_comparison.zig
/// These implementations are pure stack operations - caller must handle gas and PC

const std = @import("std");

/// LT opcode (0x10) - Less than comparison (unsigned)
pub fn LtInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop(); // Top of stack
            const b = try frame.stack.pop(); // Second from top
            try frame.stack.push(if (a < b) 1 else 0); // Compare a < b
        }
    };
}

/// GT opcode (0x11) - Greater than comparison (unsigned)
pub fn GtInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop(); // Top of stack
            const b = try frame.stack.pop(); // Second from top
            try frame.stack.push(if (a > b) 1 else 0); // Compare a > b
        }
    };
}

/// SLT opcode (0x12) - Signed less than comparison
pub fn SltInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop(); // Top of stack
            const b = try frame.stack.pop(); // Second from top
            const a_signed = @as(i256, @bitCast(a));
            const b_signed = @as(i256, @bitCast(b));
            try frame.stack.push(if (a_signed < b_signed) 1 else 0); // Compare a < b (signed)
        }
    };
}

/// SGT opcode (0x13) - Signed greater than comparison
pub fn SgtInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop(); // Top of stack
            const b = try frame.stack.pop(); // Second from top
            const a_signed = @as(i256, @bitCast(a));
            const b_signed = @as(i256, @bitCast(b));
            try frame.stack.push(if (a_signed > b_signed) 1 else 0); // Compare a > b (signed)
        }
    };
}

/// EQ opcode (0x14) - Equality comparison
pub fn EqInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const top = try frame.stack.pop();
            const second = try frame.stack.pop();
            try frame.stack.push(if (top == second) 1 else 0); // EQ is symmetric
        }
    };
}

/// ISZERO opcode (0x15) - Check if value is zero
pub fn IszeroInstruction(comptime FrameType: type) type {
    return struct {
        pub fn run(frame: *FrameType) FrameType.Error!void {
            const a = try frame.stack.pop();
            try frame.stack.push(if (a == 0) 1 else 0);
        }
    };
}
