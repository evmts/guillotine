/// Fusion handlers for three-opcode patterns.
///
/// Every handler here is emitted by the schedule builder (`dispatch.zig`):
/// - ISZERO_JUMPI: `ISZERO; PUSH target; JUMPI` with the target resolved at build time.
/// - PUSH_ADD_DUP1_INLINE / PUSH_ADD_DUP1_POINTER: `PUSH v; ADD; DUP1`.
///
/// None of them touches memory or gas: the block entry already charged the static gas
/// of the fused instructions and validated the stack bounds.
const std = @import("std");

/// Advanced synthetic opcode handlers for complex fusion patterns
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;
        const handler_abi = @import("../preprocessor/handler_abi.zig");
        const N = handler_abi.Native(FrameType);

        /// ISZERO_JUMPI - Combined zero check and conditional jump
        /// Replaces ISZERO, PUSH target, JUMPI with a single operation
        pub fn iszero_jumpi(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .ISZERO_JUMPI, cursor, s, gas);
            const value = s.pop_unsafe();
            if (value != 0) return N.next(self, .ISZERO_JUMPI, cursor, s, gas);
            // cursor[1] holds the statically resolved target: the JUMPDEST's schedule
            // cursor, or the invalid-jump item when the target is not a JUMPDEST.
            const target: [*]const Dispatch.Item = @ptrCast(@alignCast(cursor[1].jump_static.dispatch));
            return N.jump(self, .ISZERO_JUMPI, target, s, gas);
        }

        /// PUSH_ADD_DUP1_INLINE - `PUSH v; ADD; DUP1` with `v` stored inline (fits 64 bits).
        pub fn push_add_dup1_inline(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_ADD_DUP1_INLINE, cursor, s, gas);
            push_add_dup1(&s, cursor[1].push_inline.value);
            return N.next(self, .PUSH_ADD_DUP1_INLINE, cursor, s, gas);
        }

        /// PUSH_ADD_DUP1_POINTER - `PUSH v; ADD; DUP1` with `v` wider than 64 bits.
        pub fn push_add_dup1_pointer(
            self: *FrameType,
            cursor: [*]const Dispatch.Item,
            sp: [*]WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
            var s = N.StackView.init(sp, t0, t1, t2, t3);
            N.before(self, .PUSH_ADD_DUP1_POINTER, cursor, s, gas);
            push_add_dup1(&s, cursor[1].push_pointer.value_ptr.*);
            return N.next(self, .PUSH_ADD_DUP1_POINTER, cursor, s, gas);
        }

        /// The stack effect of `PUSH v; ADD; DUP1`: replace the top item with `top + v`
        /// (wrapping), then push a copy of the sum. Shared by both handlers above, which
        /// differ only in where `v` is stored.
        inline fn push_add_dup1(s: *N.StackView, push_value: WordType) void {
            const result = s.peek_unsafe() +% push_value;
            s.set_top_unsafe(result);
            s.push_unsafe(result);
        }
    };
}

test "Handlers type constructor is generic over FrameType" {
    try std.testing.expect(@typeInfo(@TypeOf(Handlers)) == .@"fn");
}
