const std = @import("std");
const builtin = @import("builtin");
const opcode_mod = @import("../opcodes/opcode.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_jump_table = @import("dispatch_jump_table.zig");
const dispatch_jump_table_builder = @import("dispatch_jump_table_builder.zig");
const dispatch_opcode_data = @import("dispatch_opcode_data.zig");
const dispatch_pretty_print = @import("dispatch_pretty_print.zig");

pub fn Preprocessor(FrameType: type) type {
    return struct {
        const Self = @This();

        /// Returns the appropriate tail call modifier based on the target architecture.
        /// WebAssembly doesn't support tail calls by default, so we use .auto for wasm targets.
        pub inline fn getTailCallModifier() std.builtin.CallModifier {
            return if (comptime builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64)
                .auto
            else
                .always_tail;
        }

        const Metadata = dispatch_metadata.DispatchMetadata(FrameType);

        const OpcodeHandler = *const fn (frame: *FrameType, cursor: [*]const Item) FrameType.Error!noreturn;

        /// Untagged union. In ReleaseFast/ReleaseSmall it is exactly 8 bytes (no tag),
        /// halving schedule footprint. In Debug/ReleaseSafe Zig adds a hidden safety tag
        /// that traps inactive-field reads, and `item_kinds` mirrors the layout for validate().
        /// (An `extern union` is impossible: handlers use the Zig calling convention.)
        pub const Item = union {
            opcode_handler: OpcodeHandler,
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            jump_static: Metadata.JumpStaticMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        };

        comptime {
            if ((builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall) and @sizeOf(Item) != 8)
                @compileError("Dispatch.Item must be exactly 8 bytes in release builds");
        }

        pub const ItemKind = enum(u8) {
            opcode_handler,
            jump_dest,
            push_inline,
            push_pointer,
            pc,
            jump_static,
            first_block_gas,
        };

        pub const terminal_item_count = 4;
        const track_item_kinds = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
        const ScheduleBuffer = struct {
            items: std.ArrayList(Item) = .empty,
            kinds: if (track_item_kinds) std.ArrayList(ItemKind) else void =
                if (track_item_kinds) .empty else {},

            fn append(
                self: *ScheduleBuffer,
                allocator: std.mem.Allocator,
                comptime kind: ItemKind,
                value: @FieldType(Item, @tagName(kind)),
            ) !void {
                try self.items.append(allocator, @unionInit(Item, @tagName(kind), value));
                if (comptime track_item_kinds) try self.kinds.append(allocator, kind);
            }

            fn len(self: *const ScheduleBuffer) usize {
                return self.items.items.len;
            }

            fn deinit(self: *ScheduleBuffer, allocator: std.mem.Allocator) void {
                self.items.deinit(allocator);
                if (comptime track_item_kinds) self.kinds.deinit(allocator);
            }
        };

        fn processPushOpcode(
            schedule_items: *ScheduleBuffer,
            schedule_allocator: std.mem.Allocator,
            arena_allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1;

            try schedule_items.append(schedule_allocator, .opcode_handler, opcode_handlers.*[push_opcode]);

            if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                const inline_value: u64 = @intCast(data.value);
                try schedule_items.append(schedule_allocator, .push_inline, .{ .value = inline_value });
            } else {
                // Allocate u256 value from arena (single deallocation at schedule deinit)
                const value_ptr = try arena_allocator.create(FrameType.WordType);
                value_ptr.* = data.value;
                try schedule_items.append(schedule_allocator, .push_pointer, .{ .value_ptr = value_ptr });
            }
        }

        cursor: [*]const Item,

        pub const JumpDestMetadata = Metadata.JumpDestMetadata;
        pub const FirstBlockMetadata = Metadata.FirstBlockMetadata;
        pub const PushInlineMetadata = Metadata.PushInlineMetadata;
        pub const PushPointerMetadata = Metadata.PushPointerMetadata;
        pub const PcMetadata = Metadata.PcMetadata;
        pub const JumpStaticMetadata = Metadata.JumpStaticMetadata;

        pub const JumpTable = dispatch_jump_table.JumpTable(FrameType, Self);

        pub const UnifiedOpcode = opcode_mod.UnifiedOpcode;

        /// Validate the handler pointer and opcode-specific stack requirements.
        /// Only runs in Debug and ReleaseSafe modes.
        pub inline fn validateOpcodeHandler(
            self: Self,
            comptime opcode: UnifiedOpcode,
            frame: *FrameType,
        ) void {
            if (comptime !track_item_kinds) return;

            // Helper function for conditional tracing assertions
            const tracerAssert = struct {
                fn call(f: *FrameType, condition: bool, comptime message: []const u8) void {
                    (&f.getEvm().tracer).assert(condition, message);
                }
            }.call;

            // Validate handler pointer matches expected opcode handler
            const expected_handler = if (opcode.isRegular())
                FrameType.opcode_handlers[@intFromEnum(opcode.toOpcode())]
            else blk: {
                const frame_handlers = @import("../frame/frame_handlers.zig");
                break :blk frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(opcode.toSynthetic()));
            };

            tracerAssert(frame, self.cursor[0].opcode_handler == expected_handler, "Opcode handler mismatch");

            // Validate stack requirements based on opcode
            switch (opcode) {
                .PC, .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8,
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16,
                .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24,
                .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },

                // Jump operations
                .JUMP => {
                    // Stack validation moved to handler to return proper error instead of asserting
                },
                .JUMPI => {
                    // Stack validation moved to handler to return proper error instead of asserting
                },

                .JUMPI_TO_STATIC_LOCATION => {
                    tracerAssert(frame, frame.stack.size() >= 1, "JUMPI_TO_STATIC: stack underflow, requires condition");
                },

                // Arithmetic operations requiring 2 stack items
                .ADD, .MUL, .SUB, .DIV, .SDIV, .MOD, .SMOD => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },

                // ADDMOD and MULMOD require 3 stack items
                .ADDMOD, .MULMOD => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Ternary op: stack underflow, requires 3 items");
                },

                // EXP and SIGNEXTEND require 2 stack items
                .EXP, .SIGNEXTEND => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },

                // Comparison operations requiring 2 stack items (except ISZERO)
                .LT, .GT, .SLT, .SGT, .EQ => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .ISZERO => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },

                // Bitwise operations
                .AND, .OR, .XOR => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .NOT, .CLZ => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .BYTE, .SHL, .SHR, .SAR => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },

                // Memory operations
                .MLOAD => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .MSTORE => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .MSTORE8 => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .MSIZE => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },
                .MCOPY => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Ternary op: stack underflow, requires 3 items");
                },

                // Storage operations
                .SLOAD, .TLOAD => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .SSTORE, .TSTORE => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },

                // Stack operations
                .POP => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .PUSH0 => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },

                // DUP operations
                .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => {
                    // Stack validation is handled in the handler itself to return proper errors
                    // The handler checks stack.size() >= n and returns Error.StackUnderflow
                    // We don't assert here to avoid crashes on invalid bytecode
                },

                // SWAP operations
                .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => {
                    // Stack validation is handled in the handler itself to return proper errors
                    // The handler checks stack.size() >= n and returns Error.StackUnderflow
                    // We don't assert here to avoid crashes on invalid bytecode
                },

                // LOG operations
                .LOG0 => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Dispatch validation failed"); // offset, length
                },
                .LOG1 => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Dispatch validation failed"); // offset, length, topic1
                },
                .LOG2 => {
                    tracerAssert(frame, frame.stack.size() >= 4, "Dispatch validation failed"); // offset, length, topic1, topic2
                },
                .LOG3 => {
                    tracerAssert(frame, frame.stack.size() >= 5, "Dispatch validation failed"); // offset, length, topic1, topic2, topic3
                },
                .LOG4 => {
                    tracerAssert(frame, frame.stack.size() >= 6, "Dispatch validation failed"); // offset, length, topic1, topic2, topic3, topic4
                },

                // Keccak256
                .KECCAK256 => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },

                // Context operations that push values
                .ADDRESS, .ORIGIN, .CALLER, .CALLVALUE, .CALLDATASIZE, .CODESIZE, .GASPRICE, .RETURNDATASIZE, .COINBASE, .TIMESTAMP, .NUMBER, .PREVRANDAO, .GASLIMIT, .CHAINID, .SELFBALANCE, .BASEFEE, .BLOBBASEFEE, .GAS => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },

                // Context operations that require stack items
                .BALANCE, .EXTCODESIZE, .EXTCODEHASH, .BLOCKHASH, .BLOBHASH => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .CALLDATALOAD => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },
                .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Ternary op: stack underflow, requires 3 items");
                },
                .EXTCODECOPY => {
                    tracerAssert(frame, frame.stack.size() >= 4, "Dispatch validation failed");
                },

                // System operations
                .CREATE => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Ternary op: stack underflow, requires 3 items");
                },
                .CREATE2 => {
                    tracerAssert(frame, frame.stack.size() >= 4, "Dispatch validation failed");
                },
                .CALL, .CALLCODE => {
                    tracerAssert(frame, frame.stack.size() >= 7, "Dispatch validation failed");
                },
                .DELEGATECALL, .STATICCALL => {
                    tracerAssert(frame, frame.stack.size() >= 6, "Dispatch validation failed");
                },
                .RETURN, .REVERT => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .SELFDESTRUCT => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Unary op: stack underflow, requires 1 item");
                },

                .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic opcode: requires 1 item");
                },

                // Synthetic memory store with inline metadata (require 1 stack item for value)
                .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic store opcode: requires 1 item");
                },

                .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic opcode: requires 1 item");
                },

                // Synthetic memory store with pointer metadata (require 1 stack item for value)
                .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic store opcode: requires 1 item");
                },

                // Advanced synthetic opcodes
                .MULTI_PUSH_2 => {
                    tracerAssert(frame, frame.stack.size() + 2 <= @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },
                .MULTI_PUSH_3 => {
                    tracerAssert(frame, frame.stack.size() + 3 <= @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed");
                },
                .MULTI_POP_2 => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Binary op: stack underflow, requires 2 items");
                },
                .MULTI_POP_3 => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Ternary op: stack underflow, requires 3 items");
                },
                .ISZERO_JUMPI => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires value to check
                },
                .DUP2_MSTORE_PUSH => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Dispatch validation failed"); // DUP2 requires 2, MSTORE consumes 2, PUSH adds 1
                },
                .DUP3_ADD_MSTORE => {
                    tracerAssert(frame, frame.stack.size() >= 3, "Dispatch validation failed"); // DUP3 requires 3
                },
                .SWAP1_DUP2_ADD => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Dispatch validation failed"); // SWAP1 requires 2
                },
                .PUSH_DUP3_ADD => {
                    tracerAssert(frame, frame.stack.size() >= 2, "Dispatch validation failed"); // DUP3 in fusion requires 2 existing + pushed = 3
                },
                .FUNCTION_DISPATCH => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires calldata to check
                },
                .CALLVALUE_CHECK => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // Pushes callvalue
                },
                .PUSH0_REVERT => {
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // PUSH0 needs space
                },
                .PUSH_ADD_DUP1 => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires 1 for ADD
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // DUP1 needs space
                },
                .MLOAD_SWAP1_DUP2 => {
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // MLOAD requires offset
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // DUP2 needs space
                },
                // Terminal: raises InvalidJump, reads no metadata or stack.
                .INVALID_JUMP_TARGET => {},
                .BACKWARD_LOOP_JUMPI => {
                    // Backward loop requires at least one stack item (the condition)
                    tracerAssert(frame, frame.stack.size() >= 1, "BACKWARD_LOOP_JUMPI: stack underflow, requires condition");
                },

                // Opcodes that don't require special validation
                .STOP, .INVALID, .AUTH, .AUTHCALL, .JUMPDEST, .BLOCK_BEGIN,
                .JUMP_TO_STATIC_LOCATION, .PUSH_ADD_INLINE, .PUSH_ADD_POINTER,
                .PUSH_MLOAD_INLINE, .PUSH_MLOAD_POINTER => {},
            }
        }

        fn GetOpDataReturnType(comptime opcode: UnifiedOpcode) type {
            return dispatch_opcode_data.GetOpDataReturnType(
                opcode,
                @TypeOf(@as(Item, undefined).opcode_handler),
                Self,
                Item,
                PcMetadata,
                PushInlineMetadata,
                PushPointerMetadata,
                JumpDestMetadata,
                JumpStaticMetadata,
            );
        }

        pub inline fn getOpData(self: Self, comptime opcode: UnifiedOpcode) GetOpDataReturnType(opcode) {
            return dispatch_opcode_data.getOpData(opcode, Self, Item, self.cursor);
        }

        pub fn getFirstBlockGas(self: Self) @TypeOf(@as(Self.Item, undefined).first_block_gas) {
            return self.cursor[0].first_block_gas;
        }

        pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
            const info = calculateFirstBlockInfo(bytecode);
            return info.gas;
        }

        /// Calculate gas and stack requirements for the first basic block
        /// Returns metadata suitable for FirstBlockMetadata
        pub fn calculateFirstBlockInfo(bytecode: anytype) FirstBlockMetadata {
            const actual_bytecode = if (@typeInfo(@TypeOf(bytecode)) == .error_union)
                bytecode catch return .{ .gas = 0, .min_stack = 0, .max_stack = 0 }
            else
                bytecode;
            // Metadata must describe the original instruction stream, so scan raw
            // bytecode rather than the (possibly fused) iterator output.
            const iter = actual_bytecode.createIterator();
            const info = @TypeOf(iter).calculateBlockInfo(iter.bytecode, 0, 0);
            return .{ .gas = info.gas, .min_stack = info.min_stack, .max_stack = info.max_stack };
        }

        fn firstBlockHasMetadata(info: FirstBlockMetadata) bool {
            return info.gas > 0 or info.min_stack > 0 or info.max_stack > 0;
        }

        fn startsFallthroughBlock(iter: anytype, instr_pc: usize) !bool {
            const last_opcode = try lastOpcodeInRange(iter.bytecode, instr_pc, iter.pc) orelse return false;
            return @TypeOf(iter).endsBlockWithFallthrough(last_opcode) and
                iter.pc < iter.bytecode.len() and
                iter.bytecode.get_unsafe(iter.pc) != @intFromEnum(Opcode.JUMPDEST);
        }

        /// Opcode of the last instruction in the raw bytecode range [start_pc, end_pc).
        /// A schedule item (plain or fused) covers exactly such a range. A fused item must
        /// never contain a block-ending instruction before its last one: the block after it
        /// would never be charged, so that is rejected as a schedule-building error.
        fn lastOpcodeInRange(bytecode: anytype, start_pc: usize, end_pc: usize) error{FusionSpansBasicBlocks}!?u8 {
            var pc = start_pc;
            var last: ?u8 = null;
            while (pc < end_pc and pc < bytecode.len()) {
                const opcode = bytecode.get_unsafe(@intCast(pc));
                if (last) |previous| {
                    if (@TypeOf(bytecode.*).Iterator.endsBlockWithFallthrough(previous)) return error.FusionSpansBasicBlocks;
                }
                last = opcode;
                pc += if (opcode >= 0x60 and opcode <= 0x7F) @as(usize, opcode - 0x5F) + 1 else 1;
            }
            return last;
        }

        const UnresolvedJump = struct {
            schedule_index: usize, // Index in schedule where jump_static metadata is
            target_pc: ?FrameType.PcType, // PC of the jump destination; null when the pushed value exceeds PcType
        };

        const JumpDestEntry = struct {
            pc: FrameType.PcType,
            schedule_index: usize,
        };

        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            tracer: anytype,
        ) !DispatchSchedule {
            const result = try buildSchedule(allocator, bytecode, opcode_handlers, tracer, false);
            return result.schedule;
        }

        /// Builds both objects from the same schedule emission pass.
        /// Deinitialize the returned jump table with the supplied allocator.
        /// Its cursors are valid for the lifetime of the returned schedule.
        pub fn initWithJumpTable(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            tracer: anytype,
        ) !ScheduleWithJumpTable {
            return buildSchedule(allocator, bytecode, opcode_handlers, tracer, true);
        }

        const ScheduleWithJumpTable = struct {
            schedule: DispatchSchedule,
            jump_table: JumpTable,
        };

        fn buildSchedule(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            tracer: anytype,
            comptime with_jump_table: bool,
        ) !ScheduleWithJumpTable {
            const log = @import("../log.zig");
            log.debug("Dispatch.init: Starting bytecode analysis", .{});

            if (tracer) |t| t.onScheduleBuildStart(bytecode.len());

            // Create arena allocator for push pointer values (PUSH9-32)
            // This reduces allocation pressure by batching all u256 allocations
            var push_values_arena = std.heap.ArenaAllocator.init(allocator);
            errdefer push_values_arena.deinit();
            const arena_allocator = push_values_arena.allocator();

            var schedule_items: ScheduleBuffer = .{};
            errdefer schedule_items.deinit(allocator);
            const code_len: usize = @intCast(bytecode.len());
            const capacity = try std.math.add(usize, try std.math.mul(usize, code_len, 2), terminal_item_count);
            try schedule_items.items.ensureTotalCapacity(allocator, capacity);
            if (comptime track_item_kinds) try schedule_items.kinds.ensureTotalCapacity(allocator, capacity);

            var jumpdest_entries = ArrayList(JumpDestEntry, null){};
            defer jumpdest_entries.deinit(allocator);

            var unresolved_jumps = ArrayList(UnresolvedJump, null){};
            defer unresolved_jumps.deinit(allocator);

            var iter = bytecode.createIterator();

            const first_block_info = calculateFirstBlockInfo(bytecode);

            const has_first_block_gas = firstBlockHasMetadata(first_block_info);
            if (has_first_block_gas) {
                try schedule_items.append(allocator, .first_block_gas, first_block_info);
            }

            var loop_counter = FrameType.config.createLoopSafetyCounter().init(FrameType.config.loop_quota orelse 0);
            while (true) {
                loop_counter.inc();
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;

                switch (op_data) {
                    .regular => |data| {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[data.opcode]);
                    },
                    .pc => |data| {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.PC)]);
                        try schedule_items.append(allocator, .pc, .{ .value = data.value });
                    },
                    .jump => {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.JUMP)]);
                    },
                    .jumpi => {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.JUMPI)]);
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, arena_allocator, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        // Record this JUMPDEST's location in schedule for single-pass resolution
                        // We store the index where the JUMPDEST handler will be placed
                        const jumpdest_schedule_idx = schedule_items.len();

                        try jumpdest_entries.append(allocator, .{
                            .pc = @intCast(instr_pc),
                            .schedule_index = jumpdest_schedule_idx,
                        });

                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)]);
                        try schedule_items.append(allocator, .jump_dest, .{
                            .gas = data.gas_cost,
                            .min_stack = data.min_stack,
                            .max_stack = data.max_stack,
                        });
                    },
                    .push_add_fusion => |data| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_add", 2);
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_add);
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_mul);
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_sub);
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_div);
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_and);
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_or);
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, data.value, .push_xor);
                    },
                    .push_jump_fusion => |data| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_jump", 2);
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, allocator, data.value, .push_jump, tracer, @intCast(instr_pc));
                    },
                    .push_jumpi_fusion => |data| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_jumpi", 3);
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, allocator, data.value, .push_jumpi, tracer, @intCast(instr_pc));
                    },
                    .push_mload_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, arena_allocator, data.value, .push_mload);
                    },
                    .push_mstore_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, arena_allocator, data.value, .push_mstore);
                    },
                    .push_mstore8_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, arena_allocator, data.value, .push_mstore8);
                    },
                    .stop => {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.STOP)]);
                    },
                    .invalid => {
                        try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.INVALID)]);
                    },
                    .multi_push => |mp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_3));

                        try schedule_items.append(allocator, .opcode_handler, handler);

                        var i: u8 = 0;
                        while (i < mp.count) : (i += 1) {
                            const value = mp.values[i];
                            // Untagged Item: advanced fusion handlers always read push_pointer.
                                const value_ptr = try arena_allocator.create(FrameType.WordType);
                                value_ptr.* = value;
                                try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                        }
                    },
                    .multi_pop => |mp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_3));

                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                    .iszero_jumpi => |ij| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.ISZERO_JUMPI));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                        // Untagged Item: advanced fusion handlers always read push_pointer.
                            const value_ptr = try arena_allocator.create(FrameType.WordType);
                            value_ptr.* = ij.target;
                            try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                    },
                    .dup2_mstore_push => |dmp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP2_MSTORE_PUSH));
                        try schedule_items.append(allocator, .opcode_handler, handler);

                        // Untagged Item: advanced fusion handlers always read push_pointer.
                            const value_ptr = try arena_allocator.create(FrameType.WordType);
                            value_ptr.* = dmp.push_value;
                            try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                    },
                    .dup3_add_mstore => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP3_ADD_MSTORE));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                    .swap1_dup2_add => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.SWAP1_DUP2_ADD));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                    .push_dup3_add => |pda| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH_DUP3_ADD));
                        try schedule_items.append(allocator, .opcode_handler, handler);

                        // Untagged Item: advanced fusion handlers always read push_pointer.
                            const value_ptr = try arena_allocator.create(FrameType.WordType);
                            value_ptr.* = pda.value;
                            try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                    },
                    .function_dispatch => |fd| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.FUNCTION_DISPATCH));
                        try schedule_items.append(allocator, .opcode_handler, handler);

                        try schedule_items.append(allocator, .push_inline, .{ .value = @as(u64, fd.selector) });

                        // Untagged Item: advanced fusion handlers always read push_pointer.
                            const value_ptr = try arena_allocator.create(FrameType.WordType);
                            value_ptr.* = fd.target;
                            try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                    },
                    .callvalue_check => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.CALLVALUE_CHECK));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                    .push0_revert => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH0_REVERT));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                    .push_add_dup1 => |pad| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH_ADD_DUP1));
                        try schedule_items.append(allocator, .opcode_handler, handler);

                        // Add push value as metadata
                        // Untagged Item: advanced fusion handlers always read push_pointer.
                            const value_ptr = try arena_allocator.create(FrameType.WordType);
                            value_ptr.* = pad.value;
                            try schedule_items.append(allocator, .push_pointer, .{ .value_ptr = value_ptr });
                    },
                    .mload_swap1_dup2 => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MLOAD_SWAP1_DUP2));
                        try schedule_items.append(allocator, .opcode_handler, handler);
                    },
                }

                // A non-taken JUMPI, or a gas-observing instruction (GAS, CALL*, CREATE*,
                // SSTORE), falls through into a new basic block that no JUMPDEST heads.
                // Insert BLOCK_BEGIN so that block's static gas is charged and its stack
                // bounds are validated, exactly as a JUMPDEST would. A JUMPDEST that
                // directly follows already does this itself.
                const next_pc: usize = iter.pc;
                if (try startsFallthroughBlock(iter, instr_pc)) {
                    const block_info = @TypeOf(iter).calculateBlockInfo(iter.bytecode, @intCast(next_pc), 0);
                    const frame_handlers = @import("../frame/frame_handlers.zig");
                    const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.BLOCK_BEGIN));
                    try schedule_items.append(allocator, .opcode_handler, handler);
                    try schedule_items.append(allocator, .jump_dest, .{
                        .gas = block_info.gas,
                        .min_stack = block_info.min_stack,
                        .max_stack = block_info.max_stack,
                    });
                }
            }

            // Code that runs off its end executes an implicit STOP.
            try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.STOP)]);

            // Static jumps whose target is not a JUMPDEST resolve to this item. Invalid
            // targets in unreachable code are legal bytecode, so the error is raised only
            // when such a jump is actually taken at runtime. The STOP above keeps
            // fall-through away from it; the two STOPs below keep the schedule invariant
            // that it ends with two STOP handlers.
            const invalid_jump_index = schedule_items.len();
            {
                const frame_handlers = @import("../frame/frame_handlers.zig");
                try schedule_items.append(allocator, .opcode_handler, frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.INVALID_JUMP_TARGET)));
            }

            try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.STOP)]);
            try schedule_items.append(allocator, .opcode_handler, opcode_handlers.*[@intFromEnum(Opcode.STOP)]);

            const final_schedule = try schedule_items.items.toOwnedSlice(allocator);
            errdefer allocator.free(final_schedule);
            const item_kinds: []const ItemKind = if (comptime track_item_kinds)
                try schedule_items.kinds.toOwnedSlice(allocator)
            else
                &.{};
            errdefer if (track_item_kinds) allocator.free(item_kinds);

            // The bytecode iterator visits JUMPDESTs in ascending PC order.
            const jumpdest_array = jumpdest_entries.items;
            resolveStaticJumpsWithArray(final_schedule, &unresolved_jumps, jumpdest_array, invalid_jump_index, tracer);

            const jump_table = if (with_jump_table)
                try createJumpTableFromArray(allocator, final_schedule, jumpdest_array, true)
            else
                JumpTable{};

            if (tracer) |t| {
                t.onScheduleBuildComplete(final_schedule.len, 0); // No longer tracking u256 count
                t.onJumpTableCreated(jumpdest_array.len);
            }

            return .{
                .schedule = .{
                    .items = final_schedule,
                    .has_first_block_gas = has_first_block_gas,
                    .item_kinds = item_kinds,
                    .allocator = allocator,
                    .push_values_arena = push_values_arena,
                },
                .jump_table = jump_table,
            };
        }

        fn handleFusionOperation(
            schedule_items: *ScheduleBuffer,
            schedule_allocator: std.mem.Allocator,
            arena_allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            try schedule_items.append(schedule_allocator, .opcode_handler, synthetic_handler);

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(schedule_allocator, .push_inline, .{ .value = inline_val });
            } else {
                // Allocate u256 value from arena (single deallocation at schedule deinit)
                const value_ptr = try arena_allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(schedule_allocator, .push_pointer, .{ .value_ptr = value_ptr });
            }
        }

        fn handleMemoryFusion(
            schedule_items: *ScheduleBuffer,
            schedule_allocator: std.mem.Allocator,
            arena_allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Always emit the fused handler (never silently drop consumed opcodes when
            // `value` is near maxInt(usize); the runtime handler checks memory bounds
            // and returns Error.OutOfBounds).
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);

            try schedule_items.append(schedule_allocator, .opcode_handler, synthetic_handler);

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(schedule_allocator, .push_inline, .{
                        .value = inline_val,
                    });
            } else {
                // Allocate u256 value from arena (single deallocation at schedule deinit)
                const value_ptr = try arena_allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(schedule_allocator, .push_pointer, .{ .value_ptr = value_ptr });
            }
        }

        fn handleStaticJumpFusion(
            schedule_items: *ScheduleBuffer,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
            tracer: anytype,
            jump_pc: u32,
        ) !void {
            // A target beyond PcType can never be a JUMPDEST. It still gets a static jump
            // item so JUMPI falls through on a zero condition; resolution points it at the
            // invalid-jump item.
            const dest_pc: ?FrameType.PcType = if (value > std.math.maxInt(FrameType.PcType)) blk: {
                if (tracer) |t| t.onInvalidStaticJump(jump_pc, @intCast(value & 0xFFFFFFFF));
                break :blk null;
            } else @intCast(value);

            const frame_handlers = @import("../frame/frame_handlers.zig");
            const static_opcode: u8 = switch (fusion_type) {
                .push_jump => @intFromEnum(OpcodeSynthetic.JUMP_TO_STATIC_LOCATION),
                .push_jumpi => @intFromEnum(OpcodeSynthetic.JUMPI_TO_STATIC_LOCATION),
                else => unreachable,
            };
            const static_handler = frame_handlers.getSyntheticHandler(FrameType, static_opcode);
            try schedule_items.append(allocator, .opcode_handler, static_handler);

            const meta_index = schedule_items.len();
            const sentinel = struct {
                const byte: u8 = 0;
            };
            const placeholder: *const anyopaque = @ptrCast(&sentinel.byte);
            try schedule_items.append(allocator, .jump_static, .{ .dispatch = placeholder });
            try unresolved_jumps.append(allocator, .{ .schedule_index = meta_index, .target_pc = dest_pc });
        }

        fn resolveStaticJumpsWithArray(
            schedule: []Item,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            jumpdest_array: []const JumpDestEntry,
            invalid_jump_index: usize,
            tracer: anytype,
        ) void {
            for (unresolved_jumps.items) |unresolved| {
                const target_pc = unresolved.target_pc orelse {
                    schedule[unresolved.schedule_index].jump_static = .{
                        .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + invalid_jump_index)),
                    };
                    continue;
                };
                var left: usize = 0;
                var right: usize = jumpdest_array.len;

                var found: ?usize = null;
                while (left < right) {
                    const mid = left + ((right - left) >> 1);
                    const mid_pc = jumpdest_array[mid].pc;

                    if (mid_pc == target_pc) {
                        found = mid;
                        break;
                    } else if (mid_pc < target_pc) {
                        left = mid + 1;
                    } else {
                        right = mid;
                    }
                }

                if (found) |idx| {
                    const target_schedule_idx = jumpdest_array[idx].schedule_index;
                    schedule[unresolved.schedule_index].jump_static = .{
                        .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + target_schedule_idx)),
                    };
                    if (tracer) |t| {
                        t.onStaticJumpResolved(0, target_pc);
                    }
                } else {
                    @branchHint(.cold);
                    if (tracer) |t| t.onInvalidStaticJump(0, target_pc);
                    schedule[unresolved.schedule_index].jump_static = .{
                        .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + invalid_jump_index)),
                    };
                }
            }
        }

        const FusionType = enum {
            push_add,
            push_mul,
            push_sub,
            push_div,
            push_and,
            push_or,
            push_xor,
            push_jump,
            push_jumpi,
            push_mload,
            push_mstore,
            push_mstore8,
        };

        fn getSyntheticOpcode(fusion_type: FusionType, is_inline: bool) u8 {
            return switch (fusion_type) {
                .push_add => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_ADD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_ADD_POINTER),
                .push_mul => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MUL_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MUL_POINTER),
                .push_sub => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_SUB_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_SUB_POINTER),
                .push_div => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_DIV_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_DIV_POINTER),
                .push_and => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_AND_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_AND_POINTER),
                .push_or => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_OR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_OR_POINTER),
                .push_xor => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_XOR_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_XOR_POINTER),
                .push_jump => unreachable,
                .push_jumpi => unreachable,
                .push_mload => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MLOAD_POINTER),
                .push_mstore => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE_POINTER),
                .push_mstore8 => if (is_inline) @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_INLINE) else @intFromEnum(OpcodeSynthetic.PUSH_MSTORE8_POINTER),
            };
        }

        /// Builds an entries-only table for callers that free entries directly.
        pub fn createJumpTable(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
        ) !JumpTable {
            return createJumpTableFromSchedule(allocator, schedule, bytecode, false);
        }

        /// Builds a jump table with dense lookup when the PC range fits.
        pub fn createDenseJumpTable(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
        ) !JumpTable {
            return createJumpTableFromSchedule(allocator, schedule, bytecode, true);
        }

        fn createJumpTableFromSchedule(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
            comptime dense: bool,
        ) !JumpTable {
            const actual_bytecode = if (@typeInfo(@TypeOf(bytecode)) == .error_union)
                try bytecode
            else
                bytecode;

            var jumpdest_entries = ArrayList(JumpDestEntry, null){};
            defer jumpdest_entries.deinit(allocator);

            var iter = scheduleIterator(actual_bytecode);
            while (try iter.next()) |entry| {
                if (entry.op != .jumpdest) continue;
                // The bytecode iterator identifies JUMPDEST instructions and skips
                // PUSH immediates. The layout iterator skips their schedule metadata.
                if (entry.schedule_index + 1 >= schedule.len) return error.InvalidDispatchSchedule;
                try jumpdest_entries.append(allocator, .{
                    .pc = @intCast(entry.pc),
                    .schedule_index = entry.schedule_index,
                });
            }

            if (iter.schedule_index + terminal_item_count != schedule.len) return error.InvalidDispatchSchedule;
            return createJumpTableFromArray(allocator, schedule, jumpdest_entries.items, dense);
        }

        fn createJumpTableFromArray(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            jumpdest_array: []const JumpDestEntry,
            comptime dense: bool,
        ) !JumpTable {
            if (jumpdest_array.len == 0) return .{};

            const entries = try allocator.alloc(JumpTable.JumpTableEntry, jumpdest_array.len);
            errdefer allocator.free(entries);

            const max_pc: usize = @intCast(jumpdest_array[jumpdest_array.len - 1].pc);
            const indices: []u32 = if (dense and max_pc < 65536 and schedule.len < std.math.maxInt(u32)) blk: {
                const indices = try allocator.alloc(u32, max_pc + 1);
                @memset(indices, 0);
                break :blk indices;
            } else &.{};
            errdefer allocator.free(indices);

            for (jumpdest_array, entries) |jumpdest, *entry| {
                entry.* = .{
                    .pc = jumpdest.pc,
                    .dispatch = .{ .cursor = schedule.ptr + jumpdest.schedule_index },
                };
                if (indices.len != 0) {
                    indices[@intCast(jumpdest.pc)] = @intCast(jumpdest.schedule_index + 1);
                }
            }

            return .{
                .entries = entries,
                .dense_indices = indices,
                .schedule_base = if (indices.len != 0) schedule.ptr else null,
            };
        }

        pub const DispatchSchedule = struct {
            items: []Item,
            has_first_block_gas: bool = false,
            item_kinds: []const ItemKind = &.{},
            allocator: std.mem.Allocator,
            /// Arena allocator for push pointer values (PUSH9-32)
            /// Uses a single allocation for all u256 values instead of individual heap allocations
            push_values_arena: std.heap.ArenaAllocator,

            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler, tracer: anytype) !DispatchSchedule {
                return try Self.init(allocator, bytecode, opcode_handlers, tracer);
            }

            pub fn initWithJumpTable(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler, tracer: anytype) !ScheduleWithJumpTable {
                return Self.initWithJumpTable(allocator, bytecode, opcode_handlers, tracer);
            }

            pub fn deinit(self: *DispatchSchedule) void {
                // Free all u256 values in one operation via arena
                self.push_values_arena.deinit();
                // Free the schedule items array
                self.allocator.free(self.items);
                if (comptime track_item_kinds) self.allocator.free(self.item_kinds);
            }

            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return Self{
                    .cursor = self.items.ptr,
                };
            }

            /// Validates the first-block metadata, metadata placement, and STOP padding.
            pub fn validate(self: *const DispatchSchedule) bool {
                const kinds = self.item_kinds;
                if (kinds.len == 0) return !track_item_kinds;
                if (kinds.len != self.items.len or kinds.len < 2) return false;
                if ((kinds[0] == .first_block_gas) != self.has_first_block_gas) return false;

                const stop_handler = FrameType.opcode_handlers[@intFromEnum(Opcode.STOP)];
                const stop_index = kinds.len - 2;
                for (kinds[stop_index..], self.items[stop_index..]) |kind, item| {
                    if (kind != .opcode_handler or item.opcode_handler != stop_handler) return false;
                }

                var idx: usize = @intFromBool(self.has_first_block_gas);
                while (idx < stop_index) {
                    if (kinds[idx] != .opcode_handler) return false;
                    idx += 1;
                    if (idx == stop_index) break;
                    switch (kinds[idx]) {
                        .jump_dest, .pc, .jump_static => idx += 1,
                        .push_inline, .push_pointer => {
                            // Fused opcodes can carry up to three PUSH operands.
                            var count: usize = 0;
                            while (idx < stop_index and isPushKind(kinds[idx])) : (idx += 1) {
                                count += 1;
                                if (count > 3) return false;
                            }
                        },
                        .opcode_handler => {},
                        .first_block_gas => return false,
                    }
                }
                return true;
            }
        };

        fn isPushKind(kind: ItemKind) bool {
            return kind == .push_inline or kind == .push_pointer;
        }

        fn pushKind(value: u256) ItemKind {
            return if (value <= std.math.maxInt(u64)) .push_inline else .push_pointer;
        }

        fn metadataKinds(op: anytype) [3]?ItemKind {
            return switch (op) {
                .regular, .jump, .jumpi, .stop, .invalid, .multi_pop, .dup3_add_mstore,
                .swap1_dup2_add, .callvalue_check, .push0_revert, .mload_swap1_dup2 => .{ null, null, null },
                .pc => .{ .pc, null, null },
                .jumpdest => .{ .jump_dest, null, null },
                .push => |data| .{ if (data.size <= 8) pushKind(data.value) else .push_pointer, null, null },
                .push_jump_fusion, .push_jumpi_fusion => .{ .jump_static, null, null },
                inline .push_add_fusion, .push_mul_fusion, .push_sub_fusion, .push_div_fusion,
                .push_and_fusion, .push_or_fusion, .push_xor_fusion, .push_mload_fusion,
                .push_mstore_fusion, .push_mstore8_fusion
                => |data| .{ pushKind(data.value), null, null },
                .push_dup3_add, .push_add_dup1 => .{ .push_pointer, null, null },
                .iszero_jumpi => .{ .push_pointer, null, null },
                .dup2_mstore_push => .{ .push_pointer, null, null },
                .function_dispatch => .{ .push_inline, .push_pointer, null },
                .multi_push => |data| .{ .push_pointer, .push_pointer, if (data.count == 3) .push_pointer else null },
            };
        }

        /// Replay the layout of a schedule built from the same analyzed bytecode.
        /// Used by diagnostics and callers that only have the raw item slice.
        pub fn scheduleIterator(bytecode: anytype) ScheduleIterator(@TypeOf(bytecode.createIterator())) {
            const has_first_block_gas = firstBlockHasMetadata(calculateFirstBlockInfo(bytecode));
            return .{
                .bytecode_iter = bytecode.createIterator(),
                .has_first_block_gas = has_first_block_gas,
                .schedule_index = @intFromBool(has_first_block_gas),
            };
        }

        fn ScheduleIterator(comptime Iterator: type) type {
            return struct {
                const Layout = @This();
                const Op = @typeInfo(@typeInfo(@TypeOf(Iterator.next)).@"fn".return_type.?).optional.child;

                bytecode_iter: Iterator,
                has_first_block_gas: bool,
                schedule_index: usize,

                pub const Entry = struct {
                    pc: usize,
                    schedule_index: usize,
                    op: Op,
                    metadata: [3]?ItemKind,
                    has_fallthrough_block: bool,
                };

                pub fn next(self: *Layout) !?Entry {
                    const pc = self.bytecode_iter.pc;
                    const op = self.bytecode_iter.next() orelse return null;
                    const metadata = metadataKinds(op);
                    const has_fallthrough_block = try startsFallthroughBlock(self.bytecode_iter, pc);
                    const index = self.schedule_index;
                    self.schedule_index += 1;
                    for (metadata) |kind| {
                        if (kind == null) break;
                        self.schedule_index += 1;
                    }
                    if (has_fallthrough_block) self.schedule_index += 2;

                    return .{
                        .pc = pc,
                        .schedule_index = index,
                        .op = op,
                        .metadata = metadata,
                        .has_fallthrough_block = has_fallthrough_block,
                    };
                }
            };
        }

        pub const JumpTableBuilder = dispatch_jump_table_builder.JumpTableBuilder(FrameType, Self);

        pub fn pretty_print(allocator: std.mem.Allocator, schedule: anytype, bytecode: anytype) ![]u8 {
            return dispatch_pretty_print.pretty_print(allocator, schedule, bytecode, FrameType, Item);
        }
    };
}

// Compatibility alias for existing code
pub const Dispatch = Preprocessor;

pub fn ScheduleElement(comptime FrameType: type) type {
    const DispatchType = Preprocessor(FrameType);
    return DispatchType.Item;
}
