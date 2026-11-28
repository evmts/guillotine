const std = @import("std");
const builtin = @import("builtin");
const opcode_mod = @import("../opcodes/opcode.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("../bytecode/bytecode.zig");
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_jump_table = @import("dispatch_jump_table.zig");
const dispatch_opcode_data = @import("dispatch_opcode_data.zig");
const dispatch_pretty_print = @import("dispatch_pretty_print.zig");
const handler_abi = @import("handler_abi.zig");

pub fn Preprocessor(FrameType: type) type {
    return struct {
        const Self = @This();

        /// Returns the appropriate tail call modifier based on the target architecture
        /// and compiler backend.
        /// WebAssembly doesn't support tail calls by default, so we use .auto for wasm targets.
        /// Zig's self-hosted x86_64 backend cannot lower guaranteed tail calls either; it gets
        /// .auto so the handlers still compile there (each instruction then consumes native
        /// stack, so that backend is for tests and debugging, not long-running execution).
        /// Production builds force the LLVM backend, which always gets .always_tail.
        pub inline fn getTailCallModifier() std.builtin.CallModifier {
            return if (comptime builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64)
                .auto
            else if (comptime builtin.zig_backend == .stage2_x86_64)
                .auto
            else
                .always_tail;
        }

        const Metadata = dispatch_metadata.DispatchMetadata(FrameType);

        const OpcodeHandler = *const fn (frame: *FrameType, cursor: [*]const Item, sp: [*]FrameType.WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode;

        /// True when a schedule item carries a runtime tag naming what it holds.
        ///
        /// Debug and ReleaseSafe builds, and builds with the tracer compiled in, keep the
        /// tag so the schedule can be validated item by item (`validateOpcodeHandler`,
        /// `DispatchSchedule.validate`, the tracer). Every other build drops it: the
        /// item is then eight bytes and a handler reads its metadata without a check. That
        /// is sound because a handler's metadata layout is fixed by the handler itself,
        /// which the schedule builder alone chooses.
        pub const item_tagged = handler_abi.hooksEnabled(FrameType);

        /// One slot of the dispatch schedule: a handler pointer or one word of the
        /// preceding handler's metadata.
        pub const Item = if (item_tagged) union(enum) {
            opcode_handler: OpcodeHandler,
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            jump_static: Metadata.JumpStaticMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        } else extern union {
            opcode_handler: OpcodeHandler,
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            jump_static: Metadata.JumpStaticMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        };

        comptime {
            if (!item_tagged and @sizeOf(Item) != 8) {
                @compileError(std.fmt.comptimePrint("untagged dispatch Item must be 8 bytes, found {d}", .{@sizeOf(Item)}));
            }
        }

        /// Number of 64-bit limbs the schedule stores for a PUSH with `size` immediate
        /// bytes: one for PUSH1-8, two for PUSH9-16, three for PUSH17-24, four for PUSH25-32.
        pub fn pushLimbCount(size: u8) u8 {
            return (size + 7) / 8;
        }

        /// Append a PUSH handler followed by its value as `pushLimbCount(size)` inline
        /// 64-bit limbs, least significant first. The handler rebuilds the word from the
        /// schedule itself, so no PUSH reads through a pointer.
        fn processPushOpcode(
            schedule_items: anytype,
            schedule_allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1;

            try schedule_items.append(schedule_allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });

            const value: u256 = data.value;
            const limbs = pushLimbCount(data.size);
            var limb: u8 = 0;
            while (limb < limbs) : (limb += 1) {
                const shift: u8 = @intCast(@as(u16, limb) * 64);
                try schedule_items.append(schedule_allocator, .{ .push_inline = .{ .value = @truncate(value >> shift) } });
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

        /// Validate that the cursor points to the expected handler and metadata for the given opcode.
        /// This includes validating:
        /// - Handler pointer matches expected opcode handler
        /// - Metadata type matches expected format for the opcode
        /// - Stack requirements are met (min/max stack sizes)
        /// Only runs in Debug and ReleaseSafe modes.
        pub inline fn validateOpcodeHandler(
            self: Self,
            comptime opcode: UnifiedOpcode,
            frame: *FrameType,
        ) void {
            if (comptime (builtin.mode != .debug and builtin.mode != .safe)) return;

            // Helper function for conditional tracing assertions
            const tracerAssert = struct {
                fn call(f: *FrameType, condition: bool, comptime message: []const u8) void {
                    (&f.getEvm().tracer).assert(condition, message);
                }
            }.call;

            // Validate handler pointer matches expected opcode handler
            const expected_handler = if (opcode.isRegular())
                FrameType.opcode_handlers[@backingInt(opcode.toOpcode())]
            else blk: {
                const frame_handlers = @import("../frame/frame_handlers.zig");
                break :blk frame_handlers.getSyntheticHandler(FrameType, opcode.toSynthetic());
            };

            tracerAssert(frame, self.cursor[0].opcode_handler == expected_handler, "Opcode handler mismatch");

            // Validate metadata type and stack requirements based on opcode
            switch (opcode) {
                // Opcodes with PC metadata
                .PC => {
                    tracerAssert(frame, self.cursor[1] == .pc, "PC opcode: expected .pc metadata");
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // Ensure space for push
                },

                // Opcodes with inline push metadata (PUSH1-PUSH8)
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8 => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "PUSH opcode: expected .push_inline metadata");
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // Ensure space for push
                },

                // Opcodes with multi-limb inline push metadata (PUSH9-PUSH32)
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                    const limbs = comptime pushLimbCount(@intCast(@backingInt(opcode) - @backingInt(UnifiedOpcode.PUSH1) + 1));
                    inline for (1..@as(usize, limbs) + 1) |limb| {
                        tracerAssert(frame, self.cursor[limb] == .push_inline, "PUSH opcode: expected .push_inline limb metadata");
                    }
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // Ensure space for push
                },

                // JUMPDEST with gas and stack validation metadata
                .JUMPDEST => {
                    tracerAssert(frame, self.cursor[1] == .jump_dest, "JUMPDEST: expected .jump_dest metadata");
                    // Stack validation is done within JUMPDEST handler using metadata
                },

                // Jump operations
                .JUMP => {
                    // Stack validation moved to handler to return proper error instead of asserting
                },
                .JUMPI => {
                    // Stack validation moved to handler to return proper error instead of asserting
                },

                // Static jump operations with jump_static metadata
                .JUMP_TO_STATIC_LOCATION, .JUMPI_TO_STATIC_LOCATION => {
                    tracerAssert(frame, self.cursor[1] == .jump_static, "Static jump: expected .jump_static metadata");
                    tracerAssert(frame, self.cursor[2] == .jump_dest, "Static jump: expected the target block's .jump_dest metadata");
                    if (opcode == .JUMPI_TO_STATIC_LOCATION) {
                        tracerAssert(frame, self.cursor[3] == .jump_dest, "JUMPI_TO_STATIC: expected the fall-through block's .jump_dest metadata");
                        tracerAssert(frame, frame.stack.size() >= 1, "JUMPI_TO_STATIC: stack underflow, requires condition");
                    }
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

                // Synthetic arithmetic opcodes with inline metadata
                // PUSH_ADD_INLINE can work with empty stack (just pushes), others require 1 item
                .PUSH_ADD_INLINE => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "Invalid metadata for synthetic opcode: expected push_inline");
                    // PUSH_ADD_INLINE handles empty stack case internally
                },
                .PUSH_MUL_INLINE, .PUSH_DIV_INLINE, .PUSH_SUB_INLINE, .PUSH_AND_INLINE, .PUSH_OR_INLINE, .PUSH_XOR_INLINE => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "Invalid metadata for synthetic opcode: expected push_inline");
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic opcode: requires 1 item");
                },

                // Synthetic memory load with inline metadata (no stack requirement)
                .PUSH_MLOAD_INLINE => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "Invalid metadata for PUSH_MLOAD_INLINE: expected push_inline");
                    // PUSH_MLOAD doesn't require anything on stack - it pushes offset then loads
                },

                // Synthetic memory store with inline metadata (require 1 stack item for value)
                .PUSH_MSTORE_INLINE, .PUSH_MSTORE8_INLINE => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "Invalid metadata for synthetic store opcode: expected push_inline");
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic store opcode: requires 1 item");
                },

                // Synthetic arithmetic opcodes with pointer metadata
                // PUSH_ADD_POINTER can work with empty stack (just pushes), others require 1 item
                .PUSH_ADD_POINTER => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "Invalid metadata for synthetic opcode: expected push_pointer");
                    // PUSH_ADD_POINTER handles empty stack case internally
                },
                .PUSH_MUL_POINTER, .PUSH_DIV_POINTER, .PUSH_SUB_POINTER, .PUSH_AND_POINTER, .PUSH_OR_POINTER, .PUSH_XOR_POINTER => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "Invalid metadata for synthetic opcode: expected push_pointer");
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic opcode: requires 1 item");
                },

                // Synthetic memory load with pointer metadata (no stack requirement)
                .PUSH_MLOAD_POINTER => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "Invalid metadata for PUSH_MLOAD_POINTER: expected push_pointer");
                    // PUSH_MLOAD doesn't require anything on stack - it pushes offset then loads
                },

                // Synthetic memory store with pointer metadata (require 1 stack item for value)
                .PUSH_MSTORE_POINTER, .PUSH_MSTORE8_POINTER => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "Invalid metadata for synthetic store opcode: expected push_pointer");
                    tracerAssert(frame, frame.stack.size() >= 1, "Stack underflow for synthetic store opcode: requires 1 item");
                },

                // Three-opcode fusions
                .ISZERO_JUMPI => {
                    tracerAssert(frame, self.cursor[1] == .jump_static, "ISZERO_JUMPI: expected .jump_static metadata");
                    tracerAssert(frame, self.cursor[2] == .jump_dest, "ISZERO_JUMPI: expected the target block's .jump_dest metadata");
                    tracerAssert(frame, self.cursor[3] == .jump_dest, "ISZERO_JUMPI: expected the fall-through block's .jump_dest metadata");
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires value to check
                },
                .PUSH_ADD_DUP1_INLINE => {
                    tracerAssert(frame, self.cursor[1] == .push_inline, "PUSH_ADD_DUP1_INLINE: expected .push_inline metadata");
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires 1 for ADD
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // DUP1 needs space
                },
                .PUSH_ADD_DUP1_POINTER => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "PUSH_ADD_DUP1_POINTER: expected .push_pointer metadata");
                    tracerAssert(frame, frame.stack.size() >= 1, "Dispatch validation failed"); // Requires 1 for ADD
                    tracerAssert(frame, frame.stack.size() < @TypeOf(frame.stack).stack_capacity, "Dispatch validation failed"); // DUP1 needs space
                },
                .BLOCK_BEGIN => {
                    tracerAssert(frame, self.cursor[1] == .jump_dest, "BLOCK_BEGIN: expected .jump_dest metadata");
                },
                // Terminal: raises InvalidJump, reads no metadata or stack.
                .INVALID_JUMP_TARGET => {},

                // Opcodes that don't require special validation
                .STOP, .INVALID, .AUTH, .AUTHCALL => {},
            }
        }

        fn GetOpDataReturnType(comptime opcode: UnifiedOpcode) type {
            return dispatch_opcode_data.GetOpDataReturnType(opcode, OpcodeHandler, Self, Item);
        }

        pub inline fn getOpData(self: Self, comptime opcode: UnifiedOpcode) GetOpDataReturnType(opcode) {
            return dispatch_opcode_data.getOpData(opcode, Self, Item, self.cursor);
        }

        pub fn calculateFirstBlockGas(bytecode: anytype) u64 {
            const info = calculateFirstBlockInfo(bytecode);
            return info.gas;
        }

        /// Calculate gas and stack requirements for the first basic block
        /// Returns metadata suitable for FirstBlockMetadata
        pub fn calculateFirstBlockInfo(bytecode: anytype) FirstBlockMetadata {
            // Metadata must describe the original instruction stream, so scan raw
            // bytecode rather than the (possibly fused) iterator output.
            const iter = bytecode.createIterator();
            const info = @TypeOf(iter).calculateBlockInfo(iter.bytecode, 0, 0);
            return .{ .gas = info.gas, .min_stack = info.min_stack, .max_stack = info.max_stack };
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

        /// True when the schedule holds a BLOCK_BEGIN after the item that covers the raw
        /// bytecode range [instr_pc, next_pc): the item's last instruction ends its basic
        /// block by falling through, more code follows, and that code does not start with
        /// a JUMPDEST (which charges its own block).
        pub fn blockBeginFollows(bytecode: anytype, instr_pc: usize, next_pc: usize) error{FusionSpansBasicBlocks}!bool {
            const last_opcode = try lastOpcodeInRange(bytecode, instr_pc, next_pc) orelse return false;
            return @TypeOf(bytecode.*).Iterator.endsBlockWithFallthrough(last_opcode) and
                next_pc < bytecode.len() and
                bytecode.get_unsafe(@intCast(next_pc)) != @backingInt(Opcode.JUMPDEST);
        }

        /// A static jump whose target is resolved once the whole schedule exists.
        const UnresolvedJump = struct {
            /// Index of the jump's `jump_static` item. The target block's
            /// `jump_dest` metadata is the item after it.
            schedule_index: usize,
            /// PC of the jump destination; null when the pushed value exceeds PcType.
            target_pc: ?FrameType.PcType,
        };

        /// A JUMPDEST found while building: its PC and its handler's schedule index.
        const JumpDestEntry = struct {
            pc: FrameType.PcType,
            schedule_index: usize,
        };

        /// How the item for one iterator step ends its basic block.
        const BlockEnd = enum {
            /// The block continues, or ends without falling through.
            none,
            /// A gas-observing instruction or a dynamic JUMPI: the next block is
            /// entered by falling through and gets a BLOCK_BEGIN.
            fallthrough,
            /// A static JUMPI or ISZERO_JUMPI: the handler enters the fall-through
            /// block itself, from metadata stored with the jump.
            folded,
        };

        /// How the schedule item built from `op_data` ends its block. The item's last
        /// bytecode instruction decides, and the iterator already knows it, so the
        /// code is not scanned again (`blockBeginFollows` does that scan for
        /// consumers that have only PCs). No fused item holds a block-ending
        /// instruction before its last one: every fusion is PUSH, ISZERO or ADD
        /// followed by one final instruction.
        fn blockEndOf(comptime Iterator: type, op_data: anytype) BlockEnd {
            return switch (op_data) {
                .regular => |data| if (Iterator.endsBlockWithFallthrough(data.opcode)) .fallthrough else .none,
                .jumpi => .fallthrough,
                .push_jumpi_fusion, .iszero_jumpi => .folded,
                else => .none,
            };
        }

        const zero_block: Metadata.JumpDestMetadata = .{ .gas = 0, .min_stack = 0, .max_stack = 0 };

        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            tracer: anytype,
        ) !DispatchSchedule {
            const log = @import("../log.zig");
            log.debug("Dispatch.init: Starting bytecode analysis", .{});

            if (tracer) |t| t.onScheduleBuildStart(bytecode.len());

            // Arena for the values of fused PUSH+op handlers whose operand is wider than
            // 64 bits. Plain PUSH9-32 store their value inline and never touch it.
            var push_values_arena = std.heap.ArenaAllocator.init(allocator);
            errdefer push_values_arena.deinit();
            const arena_allocator = push_values_arena.allocator();

            const ScheduleList = ArrayList(Self.Item, null);
            var schedule_items = ScheduleList.empty;
            errdefer schedule_items.deinit(allocator);

            var jumpdest_entries = ArrayList(JumpDestEntry, null).empty;
            defer jumpdest_entries.deinit(allocator);

            var unresolved_jumps = ArrayList(UnresolvedJump, null).empty;
            defer unresolved_jumps.deinit(allocator);

            // Bytecode validation counted the instructions and JUMPDESTs, so the lists
            // start at their final size instead of growing from nothing. Most
            // instructions take one or two items; the lists still grow when needed.
            const BytecodeType = switch (@typeInfo(@TypeOf(bytecode))) {
                .pointer => |pointer| pointer.child,
                else => @TypeOf(bytecode),
            };
            if (comptime @hasField(BytecodeType, "opcode_count") and @hasField(BytecodeType, "jumpdest_count")) {
                try schedule_items.ensureTotalCapacity(allocator, bytecode.opcode_count * 2 + 8);
                try jumpdest_entries.ensureTotalCapacityPrecise(allocator, bytecode.jumpdest_count);
            }

            var iter = bytecode.createIterator();
            const Iterator = @TypeOf(iter);

            const first_block_info = calculateFirstBlockInfo(bytecode);

            // Add first block metadata if there's any gas cost OR stack requirements
            const has_first_block = first_block_info.gas > 0 or first_block_info.min_stack > 0 or first_block_info.max_stack > 0;
            if (has_first_block) {
                try schedule_items.append(allocator, .{ .first_block_gas = first_block_info });
            }

            // Every iteration consumes at least one byte of code, so the loop ends after
            // at most `bytecode.len()` steps.
            while (true) {
                const instr_pc = iter.pc;
                const op_data = try iter.next() orelse break;

                switch (op_data) {
                    .regular => |data| {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[data.opcode] });
                    },
                    .pc => |data| {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.PC)] });
                        try schedule_items.append(allocator, .{ .pc = .{ .value = data.value } });
                    },
                    .jump => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.JUMP)] });
                    },
                    .jumpi => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.JUMPI)] });
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        // The iterator walks the code forward, so JUMPDESTs arrive in
                        // strictly increasing PC order and need no sorting.
                        if (jumpdest_entries.items.len > 0) {
                            const previous = jumpdest_entries.items[jumpdest_entries.items.len - 1].pc;
                            if (instr_pc <= previous) return error.JumpDestsNotMonotonic;
                        }
                        try jumpdest_entries.append(allocator, .{
                            .pc = @intCast(instr_pc),
                            .schedule_index = schedule_items.items.len,
                        });

                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{
                            .gas = data.gas_cost,
                            .min_stack = data.min_stack,
                            .max_stack = data.max_stack,
                        } });
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
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, allocator, data.value, .JUMP_TO_STATIC_LOCATION, tracer, @intCast(instr_pc));
                    },
                    .push_jumpi_fusion => |data| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_jumpi", 3);
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, allocator, data.value, .JUMPI_TO_STATIC_LOCATION, tracer, @intCast(instr_pc));
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
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.STOP)] });
                    },
                    .invalid => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.INVALID)] });
                    },
                    .iszero_jumpi => |ij| {
                        // The target is a constant, so it resolves at build time exactly
                        // like PUSH+JUMPI.
                        try Self.handleStaticJumpFusion(&schedule_items, &unresolved_jumps, allocator, ij.target, .ISZERO_JUMPI, tracer, @intCast(instr_pc));
                    },
                    .push_add_dup1 => |pad| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_add_dup1", 3);
                        try Self.handleFusionOperation(&schedule_items, allocator, arena_allocator, pad.value, .push_add_dup1);
                    },
                }

                // A non-taken JUMPI, or a gas-observing instruction (GAS, CALL*, CREATE*,
                // SSTORE), falls through into a new basic block that no JUMPDEST heads.
                // That block's static gas must be charged and its stack bounds validated,
                // exactly as a JUMPDEST would. A JUMPDEST that directly follows does this
                // itself, and code that ends here has no next block.
                const block_end = blockEndOf(Iterator, op_data);
                if (block_end == .none) continue;
                const next_pc: usize = iter.pc;
                const headless = next_pc < bytecode.len() and
                    iter.bytecode.get_unsafe(@intCast(next_pc)) != @backingInt(Opcode.JUMPDEST);
                const block: Metadata.JumpDestMetadata = if (headless) info: {
                    const block_info = Iterator.calculateBlockInfo(iter.bytecode, @intCast(next_pc), 0);
                    break :info .{ .gas = block_info.gas, .min_stack = block_info.min_stack, .max_stack = block_info.max_stack };
                } else zero_block;
                switch (block_end) {
                    .none => {},
                    // The static jump enters the fall-through block itself: its item ends
                    // with that block's metadata and no BLOCK_BEGIN is dispatched. When a
                    // JUMPDEST follows, or the code ends, the metadata charges nothing.
                    .folded => try schedule_items.append(allocator, .{ .jump_dest = block }),
                    .fallthrough => if (headless) {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, .BLOCK_BEGIN);
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        try schedule_items.append(allocator, .{ .jump_dest = block });
                    },
                }
            }

            // Code that runs off its end executes an implicit STOP.
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.STOP)] });

            // Static jumps whose target is not a JUMPDEST resolve to this item. Invalid
            // targets in unreachable code are legal bytecode, so the error is raised only
            // when such a jump is actually taken at runtime. The STOP above keeps
            // fall-through away from it; the two STOPs below keep the schedule invariant
            // that it ends with two STOP handlers.
            const invalid_jump_index = schedule_items.items.len;
            {
                const frame_handlers = @import("../frame/frame_handlers.zig");
                try schedule_items.append(allocator, .{ .opcode_handler = frame_handlers.getSyntheticHandler(FrameType, .INVALID_JUMP_TARGET) });
            }

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@backingInt(Opcode.STOP)] });

            const final_schedule = try schedule_items.toOwnedSlice(allocator);
            errdefer allocator.free(final_schedule);

            // The one record of the code's JUMPDESTs: dynamic jumps look targets up in
            // it at run time, and static jumps are resolved from it here.
            var jump_table = try JumpTable.create(allocator, jumpdest_entries.items.len, final_schedule.ptr);
            errdefer jump_table.deinit(allocator);
            for (jumpdest_entries.items) |entry| try jump_table.insert(entry.pc, entry.schedule_index);

            resolveStaticJumps(final_schedule, unresolved_jumps.items, jump_table, invalid_jump_index, tracer);

            if (tracer) |t| {
                t.onScheduleBuildComplete(final_schedule.len, 0); // No longer tracking u256 count
                t.onJumpTableCreated(jump_table.count());
            }

            return DispatchSchedule{
                .items = final_schedule,
                .has_first_block = has_first_block,
                .jump_table = jump_table,
                .allocator = allocator,
                .push_values_arena = push_values_arena,
            };
        }

        fn handleFusionOperation(
            schedule_items: anytype,
            schedule_allocator: std.mem.Allocator,
            arena_allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: ValueFusionType,
        ) !void {
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            try schedule_items.append(schedule_allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(schedule_allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                // Allocate u256 value from arena (single deallocation at schedule deinit)
                const value_ptr = try arena_allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(schedule_allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
            }
        }

        fn handleMemoryFusion(
            schedule_items: anytype,
            schedule_allocator: std.mem.Allocator,
            arena_allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: ValueFusionType,
        ) !void {
            // Always emit the fused handler (never silently drop consumed opcodes when
            // `value` is near maxInt(usize); the runtime handler checks memory bounds
            // and returns Error.OutOfBounds).
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);

            try schedule_items.append(schedule_allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(schedule_allocator, .{
                    .push_inline = .{
                        .value = inline_val,
                    },
                });
            } else {
                // Allocate u256 value from arena (single deallocation at schedule deinit)
                const value_ptr = try arena_allocator.create(FrameType.WordType);
                value_ptr.* = value;
                try schedule_items.append(schedule_allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
            }
        }

        /// Append a static jump: its handler, the `jump_static` cursor and the target
        /// block's `jump_dest` metadata. Both metadata items are placeholders until
        /// `resolveStaticJumps` runs. The conditional forms get one more item, the
        /// fall-through block's metadata, which `init` appends.
        fn handleStaticJumpFusion(
            schedule_items: anytype,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            comptime static_opcode: OpcodeSynthetic,
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
            const static_handler = frame_handlers.getSyntheticHandler(FrameType, static_opcode);
            try schedule_items.append(allocator, .{ .opcode_handler = static_handler });

            const meta_index = schedule_items.items.len;
            const placeholder: *const anyopaque = @as(*const anyopaque, @ptrFromInt(1));
            try schedule_items.append(allocator, .{ .jump_static = .{ .dispatch = placeholder } });
            try schedule_items.append(allocator, .{ .jump_dest = zero_block });
            try unresolved_jumps.append(allocator, .{ .schedule_index = meta_index, .target_pc = dest_pc });
        }

        /// Number of schedule items between a JUMPDEST's handler and the first
        /// instruction of its block: the handler and its `jump_dest` metadata.
        pub const jumpdest_items = 2;

        /// Point every static jump at its target.
        ///
        /// A jump to a JUMPDEST gets a copy of that JUMPDEST's block metadata and the
        /// cursor of the instruction after it. The jump handler charges and validates
        /// the block itself and continues there, so a taken static jump dispatches
        /// once, not twice. A jump to anything else gets the invalid-jump item and
        /// metadata that charges nothing.
        fn resolveStaticJumps(
            schedule: []Item,
            unresolved_jumps: []const UnresolvedJump,
            jump_table: JumpTable,
            invalid_jump_index: usize,
            tracer: anytype,
        ) void {
            for (unresolved_jumps) |unresolved| {
                const resolved: ?u32 = if (unresolved.target_pc) |target_pc| jump_table.findOffset(target_pc) else null;
                const jumpdest_index = resolved orelse {
                    @branchHint(.cold);
                    if (unresolved.target_pc) |target_pc| {
                        if (tracer) |t| t.onInvalidStaticJump(0, target_pc);
                    }
                    schedule[unresolved.schedule_index] = .{ .jump_static = .{
                        .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + invalid_jump_index)),
                    } };
                    schedule[unresolved.schedule_index + 1] = .{ .jump_dest = zero_block };
                    continue;
                };
                schedule[unresolved.schedule_index] = .{ .jump_static = .{
                    .dispatch = @as(*const anyopaque, @ptrCast(schedule.ptr + jumpdest_index + jumpdest_items)),
                } };
                schedule[unresolved.schedule_index + 1] = .{ .jump_dest = schedule[jumpdest_index + 1].jump_dest };
                if (tracer) |t| t.onStaticJumpResolved(0, unresolved.target_pc.?);
            }
        }

        const ValueFusionType = enum {
            push_add,
            push_mul,
            push_sub,
            push_div,
            push_and,
            push_or,
            push_xor,
            push_add_dup1,
            push_mload,
            push_mstore,
            push_mstore8,
        };

        fn getSyntheticOpcode(fusion_type: ValueFusionType, is_inline: bool) OpcodeSynthetic {
            return switch (fusion_type) {
                .push_add => if (is_inline) .PUSH_ADD_INLINE else .PUSH_ADD_POINTER,
                .push_mul => if (is_inline) .PUSH_MUL_INLINE else .PUSH_MUL_POINTER,
                .push_sub => if (is_inline) .PUSH_SUB_INLINE else .PUSH_SUB_POINTER,
                .push_div => if (is_inline) .PUSH_DIV_INLINE else .PUSH_DIV_POINTER,
                .push_and => if (is_inline) .PUSH_AND_INLINE else .PUSH_AND_POINTER,
                .push_or => if (is_inline) .PUSH_OR_INLINE else .PUSH_OR_POINTER,
                .push_xor => if (is_inline) .PUSH_XOR_INLINE else .PUSH_XOR_POINTER,
                .push_add_dup1 => if (is_inline) .PUSH_ADD_DUP1_INLINE else .PUSH_ADD_DUP1_POINTER,
                .push_mload => if (is_inline) .PUSH_MLOAD_INLINE else .PUSH_MLOAD_POINTER,
                .push_mstore => if (is_inline) .PUSH_MSTORE_INLINE else .PUSH_MSTORE_POINTER,
                .push_mstore8 => if (is_inline) .PUSH_MSTORE8_INLINE else .PUSH_MSTORE8_POINTER,
            };
        }

        pub const DispatchSchedule = struct {
            items: []Item,
            /// True when `items[0]` is the first block's gas and stack metadata, false
            /// when the first item is already a handler (the first block charges nothing
            /// and has no stack requirements).
            has_first_block: bool,
            /// Every JUMPDEST in the code with the schedule index of its handler: the
            /// table dynamic jumps look their target up in. It is the only record of
            /// the JUMPDESTs the schedule keeps, and it points into `items`.
            jump_table: JumpTable,
            allocator: std.mem.Allocator,
            /// Arena holding the operands of fused PUSH+op handlers that are wider than
            /// 64 bits. Freed in one operation when the schedule is destroyed.
            push_values_arena: std.heap.ArenaAllocator,

            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler, tracer: anytype) !DispatchSchedule {
                return try Self.init(allocator, bytecode, opcode_handlers, tracer);
            }

            pub fn deinit(self: *DispatchSchedule) void {
                self.push_values_arena.deinit();
                self.jump_table.deinit(self.allocator);
                self.allocator.free(self.items);
            }

            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return Self{
                    .cursor = self.items.ptr,
                };
            }

            /// True when the schedule ends with the two STOP handlers every schedule
            /// must end with. Constant time; needs no item tags.
            pub fn endsWithStops(self: *const DispatchSchedule) bool {
                if (self.items.len < 2) return false;
                const stop_handler = FrameType.opcode_handlers[@backingInt(Opcode.STOP)];
                if (comptime item_tagged) {
                    if (self.items[self.items.len - 1] != .opcode_handler) return false;
                    if (self.items[self.items.len - 2] != .opcode_handler) return false;
                }
                return self.items[self.items.len - 1].opcode_handler == stop_handler and
                    self.items[self.items.len - 2].opcode_handler == stop_handler;
            }

            /// Validates the dispatch schedule structure for correctness.
            /// Ensures:
            /// 1. Schedule ends with two STOP handlers
            /// 2. `has_first_block` agrees with the first item
            /// 3. No orphaned metadata items (metadata without preceding handler)
            ///
            /// Checks 2 and 3 read item tags and walk the whole schedule, so they run
            /// only in builds that keep the tags (`item_tagged`). Untagged builds check
            /// the terminator alone.
            pub fn validate(self: *const DispatchSchedule) bool {
                if (!self.endsWithStops()) return false;
                if (comptime !item_tagged) return true;

                if ((self.items[0] == .first_block_gas) != self.has_first_block) return false;

                var idx: usize = if (self.has_first_block) 1 else 0;
                const end = self.items.len - 2; // The last two STOP handlers are already validated.
                while (idx < end) {
                    switch (self.items[idx]) {
                        .opcode_handler => {
                            idx += 1;
                            if (idx >= end) break;
                            // Skip the metadata that belongs to this handler: one item,
                            // or up to four inline limbs of a PUSH value.
                            switch (self.items[idx]) {
                                .jump_dest, .push_pointer, .pc => idx += 1,
                                // A static jump: its target cursor, the target block's
                                // metadata and, for the conditional forms, the
                                // fall-through block's metadata.
                                .jump_static => {
                                    idx += 1;
                                    var blocks: usize = 0;
                                    while (idx < end and blocks < 2 and self.items[idx] == .jump_dest) : (blocks += 1) {
                                        idx += 1;
                                    }
                                    if (blocks == 0) return false;
                                },
                                .push_inline => {
                                    var limbs: usize = 0;
                                    while (idx < end and limbs < 4 and self.items[idx] == .push_inline) : (limbs += 1) {
                                        idx += 1;
                                    }
                                },
                                .opcode_handler, .first_block_gas => {},
                            }
                        },
                        // Metadata without a preceding handler.
                        .jump_dest, .push_inline, .push_pointer, .pc, .jump_static => return false,
                        // Only valid as the first item.
                        .first_block_gas => return false,
                    }
                }

                return true;
            }
        };

        pub fn pretty_print(allocator: std.mem.Allocator, schedule: []const Item, bytecode: anytype) ![]u8 {
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
