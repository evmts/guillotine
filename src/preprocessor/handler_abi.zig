//! Canonical dispatch handler ABI.
//!
//! Every opcode handler has the signature
//! `fn (frame, cursor, sp, gas) callconv(handler_cc) ExitCode` and ends by tail-calling
//! the next handler. On LLVM x86_64/aarch64 `handler_cc` is `preserve_none`, so the four
//! arguments stay pinned in registers across the whole handler chain and no handler
//! saves or restores callee-saved registers. Other targets fall back to the C ABI.
//!
//! `sp` and `gas` are the live stack pointer and gas counter. `frame.stack.stack_ptr` and
//! `frame.gas_remaining` are stale while handlers run. A handler must write both back
//! (`flush`) before it calls anything that reads the frame and before it exits.
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

/// Adapt a step function to the handler ABI.
///
/// A step function has the signature `fn (frame, cursor) Error![*]const Item`. It works
/// on `frame.stack` and `frame.gas_remaining` directly and returns the cursor of the
/// next handler. The adapter writes the register state to the frame, runs the step, and
/// tail-calls the next handler with the state reloaded from the frame. It suits handlers
/// whose cost is dominated by host work (storage, calls, logs, copies). Hot handlers
/// are written natively against the register ABI instead.
pub fn wrap(comptime FrameType: type, comptime step: anytype) FrameType.OpcodeHandler {
    return &struct {
        fn handler(
            frame: *FrameType,
            cursor: [*]const FrameType.Dispatch.Item,
            sp: [*]FrameType.WordType,
            gas: FrameType.GasType,
        ) callconv(handler_cc) ExitCode {
            frame.stack.stack_ptr = sp;
            frame.gas_remaining = gas;
            const next = @call(.always_inline, step, .{ frame, cursor }) catch |err| return exitFromError(FrameType.Error, err);
            return @call(tail_mod, next[0].opcode_handler, .{ frame, next, frame.stack.stack_ptr, frame.gas_remaining });
        }
    }.handler;
}

/// Helpers for handlers written natively against the register ABI.
///
/// A native handler receives the live stack pointer and gas counter as arguments, works
/// on them as locals, and passes them on with `next` or `jump`. It never reads
/// `frame.stack.stack_ptr` or `frame.gas_remaining`: those are stale until `flush`.
pub fn Native(comptime FrameType: type) type {
    return struct {
        const Item = FrameType.Dispatch.Item;
        const Word = FrameType.WordType;
        const Gas = FrameType.GasType;
        const UnifiedOpcode = FrameType.Dispatch.UnifiedOpcode;
        const dispatch_opcode_data = @import("dispatch_opcode_data.zig");

        /// True when instruction hooks (tracer synchronization and schedule validation)
        /// are compiled in. Matches the condition in `Frame.beforeInstruction`.
        pub const traced = builtin.mode == .debug or builtin.mode == .safe or FrameType.Evm.tracing_enabled;

        /// The EVM stack as seen through the stack pointer register. It grows downward:
        /// `sp[0]` is the top item. Bounds are validated once per basic block, so these
        /// operations do not check them.
        pub const StackView = struct {
            sp: [*]Word,

            pub inline fn push_unsafe(self: *StackView, value: Word) void {
                self.sp -= 1;
                self.sp[0] = value;
            }

            pub inline fn pop_unsafe(self: *StackView) Word {
                const value = self.sp[0];
                self.sp += 1;
                return value;
            }

            pub inline fn peek_unsafe(self: *StackView) Word {
                return self.sp[0];
            }

            pub inline fn set_top_unsafe(self: *StackView, value: Word) void {
                self.sp[0] = value;
            }

            pub inline fn binary_op_unsafe(self: *StackView, comptime op: fn (a: Word, b: Word) Word) void {
                const top = self.sp[0];
                const second = self.sp[1];
                self.sp[1] = op(top, second);
                self.sp += 1;
            }

            pub inline fn dup_n_unsafe(self: *StackView, n: u8) void {
                const value = self.sp[n - 1];
                self.push_unsafe(value);
            }

            pub inline fn swap_n_unsafe(self: *StackView, n: u8) void {
                const tmp = self.sp[0];
                self.sp[0] = self.sp[n];
                self.sp[n] = tmp;
            }

            /// Number of items on the stack.
            pub inline fn size(self: *StackView, frame: *const FrameType) usize {
                const base = @intFromPtr(frame.stack.buf_ptr) + @as(usize, FrameType.Stack.stack_capacity) * @sizeOf(Word);
                return (base - @intFromPtr(self.sp)) / @sizeOf(Word);
            }
        };

        /// Write the register state back to the frame.
        pub inline fn flush(frame: *FrameType, sp: [*]Word, gas: Gas) void {
            frame.stack.stack_ptr = sp;
            frame.gas_remaining = gas;
        }

        /// Run the pre-instruction hooks. Compiles to nothing in untraced builds.
        pub inline fn before(frame: *FrameType, comptime opcode: UnifiedOpcode, cursor: [*]const Item, sp: [*]Word, gas: Gas) void {
            if (comptime !traced) return;
            flush(frame, sp, gas);
            frame.beforeInstruction(opcode, cursor);
        }

        /// Continue with the handler that follows `opcode` and its metadata.
        pub inline fn next(frame: *FrameType, comptime opcode: UnifiedOpcode, cursor: [*]const Item, sp: [*]Word, gas: Gas) ExitCode {
            const op_data = dispatch_opcode_data.getOpData(opcode, FrameType.Dispatch, Item, cursor);
            const target = op_data.next_cursor.cursor;
            if (comptime traced) {
                flush(frame, sp, gas);
                frame.afterInstruction(opcode, op_data.next_handler, target);
            }
            return @call(tail_mod, op_data.next_handler, .{ frame, target, sp, gas });
        }

        /// Continue with the handler at `target`.
        pub inline fn jump(frame: *FrameType, comptime opcode: UnifiedOpcode, target: [*]const Item, sp: [*]Word, gas: Gas) ExitCode {
            const handler = target[0].opcode_handler;
            if (comptime traced) {
                flush(frame, sp, gas);
                frame.afterInstruction(opcode, handler, target);
            }
            return @call(tail_mod, handler, .{ frame, target, sp, gas });
        }

        /// Stop executing the frame with `code`.
        pub inline fn exit(frame: *FrameType, comptime opcode: UnifiedOpcode, sp: [*]Word, gas: Gas, code: ExitCode) ExitCode {
            flush(frame, sp, gas);
            frame.afterComplete(opcode);
            return code;
        }
    };
}

/// Enter the handler chain from ordinary code. This is the only place that pays for
/// saving callee-saved registers: once per frame, not once per instruction.
pub fn enter(comptime FrameType: type, frame: *FrameType, cursor: [*]const FrameType.Dispatch.Item) ExitCode {
    return @call(.never_inline, cursor[0].opcode_handler, .{ frame, cursor, frame.stack.stack_ptr, frame.gas_remaining });
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
