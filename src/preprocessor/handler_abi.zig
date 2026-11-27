//! Canonical dispatch handler ABI.
//!
//! Every opcode handler has the signature
//! `fn (frame, cursor, sp, gas, t0, t1, t2, t3) callconv(handler_cc) ExitCode` and ends by
//! tail-calling the next handler. On LLVM x86_64/aarch64 `handler_cc` is `preserve_none`,
//! so the eight arguments stay pinned in registers across the whole handler chain and no
//! handler saves or restores callee-saved registers. Other targets fall back to the C ABI.
//!
//! `sp` and `gas` are the live stack pointer and gas counter. `t0..t3` are the top stack
//! item as 64-bit limbs, least significant first (`toLimbs`, `fromLimbs`).
//!
//! Top-of-stack invariant, with `size` the number of stack items:
//!
//! ```
//!   size == (buf + stack_capacity - sp) / @sizeOf(Word)      same `sp` as `Stack.stack_ptr`
//!   size >= 1:  t0..t3 = item 0 (top);  sp[1] = item 1;  sp[2] = item 2; ...
//!               sp[0] is the top item's spill slot. Its content is stale.
//!   size == 0:  sp == buf + stack_capacity, the sentinel word (`Stack.buffer_len`).
//!               t0..t3 hold no item. Block entry validation keeps handlers from using it.
//! ```
//!
//! `sp[0]` is addressable at every depth from 0 to `stack_capacity`: at depth 0 it is the
//! sentinel word, otherwise a buffer word. So spilling the top item (`sp[0] = tos`) and
//! reloading it (`tos = sp[0]`) are branch-free at every depth. A push that the block
//! entry validated needs `size < stack_capacity`, so `sp - 1` stays inside the buffer.
//!
//! `frame.stack.stack_ptr`, the stack memory at `sp[0]` and `frame.gas_remaining` are
//! stale while handlers run. A handler must write them back (`flush`) before it calls
//! anything that reads the frame and before it exits.
const std = @import("std");
const builtin = @import("builtin");

const CallingConvention = std.builtin.CallingConvention;

pub const has_preserve_none: bool = blk: {
    if (builtin.zig_backend != .stage2_llvm) break :blk false;
    break :blk switch (builtin.cpu.arch) {
        .x86_64 => @hasField(CallingConvention, "x86_64_preserve_none"),
        .aarch64, .aarch64_be => @hasField(CallingConvention, "aarch64_preserve_none"),
        else => false,
    };
};

pub const handler_cc: CallingConvention = if (!has_preserve_none) .c else switch (builtin.cpu.arch) {
    .x86_64 => .{ .x86_64_preserve_none = .{} },
    .aarch64, .aarch64_be => .{ .aarch64_preserve_none = .{} },
    else => .c,
};

/// WebAssembly has no guaranteed tail calls by default and the self-hosted backends
/// cannot lower them, so those targets use ordinary calls.
pub const tail_mod: std.builtin.CallModifier =
    if (builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64 or builtin.zig_backend != .stage2_llvm)
        .auto
    else
        .always_tail;

/// Why a frame stopped executing. Returned by the handler chain instead of an error
/// union: a plain `enum(u8)` return keeps the handler signature compatible with
/// `preserve_none` guaranteed tail calls.
pub const ExitCode = enum(u8) {
    stop,
    @"return",
    revert,
    self_destruct,
    out_of_gas,
    stack_underflow,
    stack_overflow,
    invalid_jump,
    invalid_opcode,
    write_protection,
    out_of_bounds,
    allocation_error,
    gas_overflow,
    return_data_not_available,
    bytecode_too_large,
    invalid_amount,
    safety_limit_exceeded,
};

/// Map a frame error to its exit code.
pub inline fn exitFromError(comptime Error: type, err: Error) ExitCode {
    return switch (err) {
        error.Stop => .stop,
        error.Return => .@"return",
        error.REVERT => .revert,
        error.SelfDestruct => .self_destruct,
        error.OutOfGas => .out_of_gas,
        error.StackUnderflow => .stack_underflow,
        error.StackOverflow => .stack_overflow,
        error.InvalidJump => .invalid_jump,
        error.InvalidOpcode => .invalid_opcode,
        error.WriteProtection => .write_protection,
        error.OutOfBounds => .out_of_bounds,
        error.AllocationError => .allocation_error,
        error.GasOverflow => .gas_overflow,
        error.ReturnDataNotAvailable => .return_data_not_available,
        error.BytecodeTooLarge => .bytecode_too_large,
        error.InvalidAmount => .invalid_amount,
        error.SafetyLimitExceeded => .safety_limit_exceeded,
    };
}

/// Map an exit code back to the frame error the EVM host expects.
pub fn errorFromExit(comptime Error: type, code: ExitCode) Error {
    return switch (code) {
        .stop => error.Stop,
        .@"return" => error.Return,
        .revert => error.REVERT,
        .self_destruct => error.SelfDestruct,
        .out_of_gas => error.OutOfGas,
        .stack_underflow => error.StackUnderflow,
        .stack_overflow => error.StackOverflow,
        .invalid_jump => error.InvalidJump,
        .invalid_opcode => error.InvalidOpcode,
        .write_protection => error.WriteProtection,
        .out_of_bounds => error.OutOfBounds,
        .allocation_error => error.AllocationError,
        .gas_overflow => error.GasOverflow,
        .return_data_not_available => error.ReturnDataNotAvailable,
        .bytecode_too_large => error.BytecodeTooLarge,
        .invalid_amount => error.InvalidAmount,
        .safety_limit_exceeded => error.SafetyLimitExceeded,
    };
}

/// Number of 64-bit register arguments that carry the top stack item.
pub const tos_limb_count = 4;

/// Split a stack word into the register limbs, least significant first. A word narrower
/// than 256 bits is zero-extended, so its upper limbs are zero.
pub inline fn toLimbs(comptime Word: type, word: Word) [tos_limb_count]u64 {
    comptime if (@bitSizeOf(Word) > 64 * tos_limb_count) {
        @compileError("the handler ABI carries stack words of at most 256 bits");
    };
    const wide: u256 = word;
    return .{ @truncate(wide), @truncate(wide >> 64), @truncate(wide >> 128), @truncate(wide >> 192) };
}

/// Join the register limbs into a stack word. Inverse of `toLimbs`.
pub inline fn fromLimbs(comptime Word: type, t0: u64, t1: u64, t2: u64, t3: u64) Word {
    comptime if (@bitSizeOf(Word) > 64 * tos_limb_count) {
        @compileError("the handler ABI carries stack words of at most 256 bits");
    };
    const wide = @as(u256, t0) | (@as(u256, t1) << 64) | (@as(u256, t2) << 128) | (@as(u256, t3) << 192);
    return @truncate(wide);
}

/// Write the top item to a stack slot.
///
/// The item lives in four general-purpose registers. A plain `u256` store lets LLVM merge
/// the four limb stores into two vector stores, which costs four GPR-to-XMM moves and two
/// shuffles per spill. On little-endian targets the limbs are written one by one through
/// a volatile pointer instead: volatile stores are never merged, so the spill is four
/// scalar stores. The bytes written are the same either way.
pub inline fn spill(comptime Word: type, slot: *Word, value: Word) void {
    if (comptime (Word != u256 or builtin.cpu.arch.endian() != .little)) {
        slot.* = value;
        return;
    }
    const limbs: *volatile [tos_limb_count]u64 = @ptrCast(slot);
    inline for (toLimbs(Word, value), 0..) |limb, index| limbs[index] = limb;
}

/// Adapt a step function to the handler ABI.
///
/// A step function has the signature `fn (frame, cursor) Error![*]const Item`. It works
/// on `frame.stack` and `frame.gas_remaining` directly and returns the cursor of the
/// next handler. The adapter writes the register state to the frame (the top item goes
/// to its spill slot), runs the step, and tail-calls the next handler with the state
/// reloaded from the frame. It suits handlers whose cost is dominated by host work
/// (storage, calls, logs, copies). Hot handlers are written natively against the
/// register ABI instead.
pub fn wrap(comptime FrameType: type, comptime step: anytype) FrameType.OpcodeHandler {
    return &struct {
        fn handler(
            frame: *FrameType,
            cursor: [*]const FrameType.Dispatch.Item,
            sp: [*]FrameType.WordType,
            gas: FrameType.GasType,
            t0: u64,
            t1: u64,
            t2: u64,
            t3: u64,
        ) callconv(handler_cc) ExitCode {
            spill(FrameType.WordType, &sp[0], fromLimbs(FrameType.WordType, t0, t1, t2, t3));
            frame.stack.stack_ptr = sp;
            frame.gas_remaining = gas;
            const next = @call(.always_inline, step, .{ frame, cursor }) catch |err| {
                return exitFromError(FrameType.Error, err);
            };
            const next_sp = frame.stack.stack_ptr;
            const tos = toLimbs(FrameType.WordType, next_sp[0]);
            return @call(
                tail_mod,
                next[0].opcode_handler,
                .{ frame, next, next_sp, frame.gas_remaining, tos[0], tos[1], tos[2], tos[3] },
            );
        }
    }.handler;
}

/// True when instruction hooks (tracer synchronization and schedule validation) are
/// compiled in for `FrameType`: Debug and ReleaseSafe builds, and any build whose EVM has
/// the tracer enabled. The same builds keep the runtime tag on dispatch schedule items.
pub fn hooksEnabled(comptime FrameType: type) bool {
    return builtin.mode == .debug or builtin.mode == .safe or FrameType.Evm.tracing_enabled;
}

/// Helpers for handlers written natively against the register ABI.
///
/// A native handler receives the live stack pointer, gas counter and top stack item as
/// arguments, works on them as locals (`StackView`), and passes them on with `next` or
/// `jump`. It never reads `frame.stack.stack_ptr` or `frame.gas_remaining`: those are
/// stale until `flush`.
pub fn Native(comptime FrameType: type) type {
    return struct {
        const Item = FrameType.Dispatch.Item;
        const Word = FrameType.WordType;
        const Gas = FrameType.GasType;
        const UnifiedOpcode = FrameType.Dispatch.UnifiedOpcode;
        const dispatch_opcode_data = @import("dispatch_opcode_data.zig");

        /// True when instruction hooks (tracer synchronization and schedule validation)
        /// are compiled in. Matches the condition in `Frame.beforeInstruction`.
        pub const traced = hooksEnabled(FrameType);

        /// The EVM stack as seen through the handler registers. It grows downward. The
        /// top item is `tos`; `sp[0]` is its spill slot and `sp[1]` is the second item
        /// (see the invariant at the top of this file). Bounds are validated once per
        /// basic block, so these operations do not check them.
        pub const StackView = struct {
            sp: [*]Word,
            tos: Word,

            /// The view a handler builds from its `sp, t0, t1, t2, t3` arguments.
            pub inline fn init(sp: [*]Word, t0: u64, t1: u64, t2: u64, t3: u64) StackView {
                return .{ .sp = sp, .tos = fromLimbs(Word, t0, t1, t2, t3) };
            }

            /// Spill the old top item to its slot and make `value` the top item. On an
            /// empty stack the spill writes the sentinel word.
            pub inline fn push_unsafe(self: *StackView, value: Word) void {
                spill(Word, &self.sp[0], self.tos);
                self.sp -= 1;
                self.tos = value;
            }

            /// Return the top item and reload the next one. When the stack becomes
            /// empty the reload reads the sentinel word.
            pub inline fn pop_unsafe(self: *StackView) Word {
                const value = self.tos;
                self.sp += 1;
                self.tos = self.sp[0];
                return value;
            }

            pub inline fn peek_unsafe(self: *const StackView) Word {
                return self.tos;
            }

            pub inline fn set_top_unsafe(self: *StackView, value: Word) void {
                self.tos = value;
            }

            pub inline fn binary_op_unsafe(self: *StackView, comptime op: fn (a: Word, b: Word) Word) void {
                const second = self.sp[1];
                self.sp += 1;
                self.tos = op(self.tos, second);
            }

            pub inline fn dup_n_unsafe(self: *StackView, n: u8) void {
                const value = if (n == 1) self.tos else self.sp[n - 1];
                self.push_unsafe(value);
            }

            pub inline fn swap_n_unsafe(self: *StackView, n: u8) void {
                const tmp = self.sp[n];
                spill(Word, &self.sp[n], self.tos);
                self.tos = tmp;
            }

            /// Number of items on the stack.
            pub inline fn size(self: *const StackView, frame: *const FrameType) usize {
                const cap_bytes = @as(usize, FrameType.Stack.stack_capacity) * @sizeOf(Word);
                const base = @intFromPtr(frame.stack.buf_ptr) + cap_bytes;
                return (base - @intFromPtr(self.sp)) / @sizeOf(Word);
            }
        };

        /// Write the register state back to the frame. The top item goes to its spill
        /// slot, which makes the stack memory match `frame.stack` semantics. On an empty
        /// stack that write lands on the sentinel word.
        pub inline fn flush(frame: *FrameType, s: StackView, gas: Gas) void {
            spill(Word, &s.sp[0], s.tos);
            frame.stack.stack_ptr = s.sp;
            frame.gas_remaining = gas;
        }

        /// Run the pre-instruction hooks. Compiles to nothing in untraced builds.
        pub inline fn before(
            frame: *FrameType,
            comptime opcode: UnifiedOpcode,
            cursor: [*]const Item,
            s: StackView,
            gas: Gas,
        ) void {
            if (comptime !traced) return;
            flush(frame, s, gas);
            frame.beforeInstruction(opcode, cursor);
        }

        /// Continue with the handler that follows `opcode` and its metadata.
        pub inline fn next(
            frame: *FrameType,
            comptime opcode: UnifiedOpcode,
            cursor: [*]const Item,
            s: StackView,
            gas: Gas,
        ) ExitCode {
            const op_data = dispatch_opcode_data.getOpData(opcode, FrameType.Dispatch, Item, cursor);
            const target = op_data.next_cursor.cursor;
            if (comptime traced) {
                flush(frame, s, gas);
                frame.afterInstruction(opcode, op_data.next_handler, target);
            }
            const tos = toLimbs(Word, s.tos);
            return @call(
                tail_mod,
                op_data.next_handler,
                .{ frame, target, s.sp, gas, tos[0], tos[1], tos[2], tos[3] },
            );
        }

        /// Continue with the handler at `target`.
        pub inline fn jump(
            frame: *FrameType,
            comptime opcode: UnifiedOpcode,
            target: [*]const Item,
            s: StackView,
            gas: Gas,
        ) ExitCode {
            const handler = target[0].opcode_handler;
            if (comptime traced) {
                flush(frame, s, gas);
                frame.afterInstruction(opcode, handler, target);
            }
            const tos = toLimbs(Word, s.tos);
            return @call(tail_mod, handler, .{ frame, target, s.sp, gas, tos[0], tos[1], tos[2], tos[3] });
        }

        /// Return `handler` as a value the optimizer cannot trace back to a function.
        ///
        /// A hot handler tail-calls its slow-path twin through this. Called directly, the
        /// twin has one caller and LLVM inlines it whatever its size, which puts the slow
        /// path's stack frame and register spills in the hot handler's prologue. Zig's
        /// `noinline` cannot stop that: it is part of the function type, and
        /// `always_tail` requires caller and callee types to match. A volatile load does
        /// not stop it either: Zig evaluates a load from a comptime-known pointer itself.
        ///
        /// The empty assembly block passes the address through one register. It emits no
        /// instruction; the tail call becomes an indirect jump through that register.
        pub inline fn outlined(comptime handler: FrameType.OpcodeHandler) FrameType.OpcodeHandler {
            if (comptime !has_preserve_none) return handler;
            return switch (builtin.cpu.arch) {
                .x86_64 => asm (""
                    : [_] "={rax}" (-> FrameType.OpcodeHandler),
                    : [_] "{rax}" (handler),
                ),
                .aarch64, .aarch64_be => asm (""
                    : [_] "={x16}" (-> FrameType.OpcodeHandler),
                    : [_] "{x16}" (handler),
                ),
                else => @compileError("preserve_none outlined() requires x86_64 or aarch64"),
            };
        }

        /// Stop executing the frame with `code`.
        pub inline fn exit(
            frame: *FrameType,
            comptime opcode: UnifiedOpcode,
            s: StackView,
            gas: Gas,
            code: ExitCode,
        ) ExitCode {
            flush(frame, s, gas);
            frame.afterComplete(opcode);
            return code;
        }
    };
}

/// Enter the handler chain from ordinary code. This is the only place that pays for
/// saving callee-saved registers: once per frame, not once per instruction. The top item
/// is loaded from its spill slot, which for an empty stack is the sentinel word.
pub fn enter(comptime FrameType: type, frame: *FrameType, cursor: [*]const FrameType.Dispatch.Item) ExitCode {
    const sp = frame.stack.stack_ptr;
    const tos = toLimbs(FrameType.WordType, sp[0]);
    return @call(
        .never_inline,
        cursor[0].opcode_handler,
        .{ frame, cursor, sp, frame.gas_remaining, tos[0], tos[1], tos[2], tos[3] },
    );
}

test {
    // `src/root.zig` runs this file's tests, and with them the tests of every file
    // imported here. Only files whose whole import closure has passing tests can be
    // listed. `dispatch_layout_test.zig`, `../bytecode/bytecode_config.zig` and
    // `../tracer/minimal_frame.zig` are not: they import files (eips.zig, evm.zig and
    // what those import) whose own tests no longer compile. Run them with
    // `zig build test-unit -Dtest-filter='<test name>'` after adding their import here.
    _ = @import("dispatch_metadata.zig");
}

test "exit codes round-trip through frame errors" {
    const Error = error{
        StackOverflow,
        StackUnderflow,
        REVERT,
        BytecodeTooLarge,
        AllocationError,
        InvalidJump,
        InvalidOpcode,
        OutOfBounds,
        OutOfGas,
        GasOverflow,
        InvalidAmount,
        WriteProtection,
        SafetyLimitExceeded,
        ReturnDataNotAvailable,
        Stop,
        Return,
        SelfDestruct,
    };
    for (std.enums.values(ExitCode)) |code| {
        try std.testing.expectEqual(code, exitFromError(Error, errorFromExit(Error, code)));
    }
}

test "top-of-stack limbs round-trip for every word width" {
    const value: u256 = 0x0123456789abcdef_fedcba9876543210_0f1e2d3c4b5a6978_8796a5b4c3d2e1f0;
    const limbs = toLimbs(u256, value);
    try std.testing.expectEqual(@as(u64, 0x8796a5b4c3d2e1f0), limbs[0]);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), limbs[3]);
    try std.testing.expectEqual(value, fromLimbs(u256, limbs[0], limbs[1], limbs[2], limbs[3]));
    try std.testing.expectEqual(std.math.maxInt(u256), fromLimbs(u256, ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0), ~@as(u64, 0)));

    var slot: u256 = 0;
    spill(u256, &slot, value);
    try std.testing.expectEqual(value, slot);
    var narrow_slot: u64 = 0;
    spill(u64, &narrow_slot, 0xfeed);
    try std.testing.expectEqual(@as(u64, 0xfeed), narrow_slot);

    inline for (.{ u8, u32, u64, u128 }) |Word| {
        const word: Word = @truncate(value);
        const narrow = toLimbs(Word, word);
        try std.testing.expectEqual(word, fromLimbs(Word, narrow[0], narrow[1], narrow[2], narrow[3]));
        if (@bitSizeOf(Word) <= 64) try std.testing.expectEqual(@as(u64, 0), narrow[1]);
        try std.testing.expectEqual(@as(u64, 0), narrow[3]);
    }
}

test "StackView stays inside the stack buffer at depth 0 and at capacity" {
    // A stand-in with the layout `StackView.size` reads. Importing `stack/stack.zig`
    // here would add that file's tests to this build (see the `test` block above).
    const TestStack = struct {
        pub const stack_capacity = 4;
        buf_ptr: [*]u256,
        stack_ptr: [*]u256,
    };
    const TestFrame = struct {
        pub const WordType = u256;
        pub const Stack = TestStack;
        stack: TestStack,
    };
    const View = Native(TestFrame).StackView;

    // Guard words on both sides of the five-word buffer (four items and the sentinel).
    const guard: u256 = 0x6775617264;
    var words: [7]u256 = @splat(guard);
    const buf: [*]u256 = words[1..6];
    const sentinel = buf + TestStack.stack_capacity;
    sentinel[0] = 0;
    var frame = TestFrame{ .stack = .{ .buf_ptr = buf, .stack_ptr = sentinel } };

    // Depth 0: sp is the sentinel word and the registers hold no item.
    try std.testing.expectEqual(@intFromPtr(sentinel), @intFromPtr(frame.stack.stack_ptr));
    var s = View.init(frame.stack.stack_ptr, 0xdead, 0, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), s.size(&frame));

    // The first push spills the register garbage to the sentinel, not past the buffer.
    s.push_unsafe(1);
    try std.testing.expectEqual(@as(u256, 0xdead), sentinel[0]);
    try std.testing.expectEqual(@as(usize, 1), s.size(&frame));

    // Fill to capacity: sp reaches buf[0], whose spill slot is still a buffer word.
    s.push_unsafe(2);
    s.push_unsafe(3);
    s.dup_n_unsafe(1);
    try std.testing.expectEqual(@as(usize, 4), s.size(&frame));
    try std.testing.expectEqual(@intFromPtr(buf), @intFromPtr(s.sp));
    s.swap_n_unsafe(3);
    try std.testing.expectEqual(@as(u256, 1), s.peek_unsafe());
    try std.testing.expectEqual(@as(u256, 3), buf[TestStack.stack_capacity - 1]);

    // Flushing makes the stack memory match `Stack` semantics.
    frame.stack.stack_ptr = s.sp;
    spill(u256, &s.sp[0], s.tos);
    try std.testing.expectEqualSlices(u256, &.{ 1, 3, 2, 3 }, frame.stack.stack_ptr[0..4]);

    // DUP2 then binary op, then pop back to depth 0: the last reload reads the sentinel.
    _ = s.pop_unsafe();
    s.dup_n_unsafe(2);
    try std.testing.expectEqual(@as(u256, 2), s.peek_unsafe());
    s.binary_op_unsafe(struct {
        fn op(top: u256, second: u256) u256 {
            return top -% second;
        }
    }.op);
    try std.testing.expectEqual(~@as(u256, 0), s.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 2), s.pop_unsafe());
    try std.testing.expectEqual(@as(u256, 3), s.pop_unsafe());
    try std.testing.expectEqual(@as(usize, 0), s.size(&frame));
    try std.testing.expectEqual(@intFromPtr(sentinel), @intFromPtr(s.sp));
    try std.testing.expectEqual(@as(u256, 0xdead), s.peek_unsafe());

    // Nothing was written below the buffer or past the sentinel.
    try std.testing.expectEqual(guard, words[0]);
    try std.testing.expectEqual(guard, words[6]);
}
