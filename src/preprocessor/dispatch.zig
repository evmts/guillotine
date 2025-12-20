const std = @import("std");
const opcode_mod = @import("../opcodes/opcode.zig");
const Opcode = @import("../opcodes/opcode_data.zig").Opcode;
const OpcodeSynthetic = @import("../opcodes/opcode_synthetic.zig").OpcodeSynthetic;
const bytecode_mod = @import("../bytecode/bytecode.zig");
const ArrayList = std.ArrayListAligned;
const dispatch_metadata = @import("dispatch_metadata.zig");
const dispatch_item = @import("dispatch_item.zig");
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
            const builtin = @import("builtin");
            return if (comptime builtin.target.cpu.arch == .wasm32 or builtin.target.cpu.arch == .wasm64)
                .auto
            else
                .always_tail;
        }

        const Metadata = dispatch_metadata.DispatchMetadata(FrameType);

        const OpcodeHandler = *const fn (frame: *FrameType, cursor: [*]const Item) FrameType.Error!noreturn;

        pub const Item = union(enum) {
            opcode_handler: OpcodeHandler,
            jump_dest: Metadata.JumpDestMetadata,
            push_inline: Metadata.PushInlineMetadata,
            push_pointer: Metadata.PushPointerMetadata,
            pc: Metadata.PcMetadata,
            jump_static: Metadata.JumpStaticMetadata,
            first_block_gas: Metadata.FirstBlockMetadata,
        };

        fn processPushOpcode(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            opcode_handlers: *const [256]OpcodeHandler,
            data: anytype,
        ) !void {
            const push_opcode = 0x60 + data.size - 1;

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[push_opcode] });

            if (data.size <= 8 and data.value <= std.math.maxInt(u64)) {
                const inline_value: u64 = @intCast(data.value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_value } });
            } else {
                // Allocate individual u256 value on heap
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = data.value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
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
            const builtin_mode = @import("builtin").mode;
            if (comptime (builtin_mode != .Debug and builtin_mode != .ReleaseSafe)) return;

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

                // Opcodes with pointer push metadata (PUSH9-PUSH32)
                .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => {
                    tracerAssert(frame, self.cursor[1] == .push_pointer, "PUSH opcode: expected .push_pointer metadata");
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
                    if (opcode == .JUMPI_TO_STATIC_LOCATION) {
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
                .NOT => {
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

                // Opcodes that don't require special validation
                .STOP, .INVALID, .AUTH, .AUTHCALL => {},
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
            var gas: u64 = 0;
            var stack_effect: i32 = 0;
            var min_stack: i32 = 0;
            var max_stack: i32 = 0;

            const actual_bytecode = if (@typeInfo(@TypeOf(bytecode)) == .error_union)
                bytecode catch return .{ .gas = 0, .min_stack = 0, .max_stack = 0 }
            else
                bytecode;
            var iter = actual_bytecode.createIterator();
            const opcode_info = @import("../opcodes/opcode_data.zig").OPCODE_INFO;

            var op_count: u32 = 0;
            var loop_counter = FrameType.config.createLoopSafetyCounter().init(FrameType.config.loop_quota orelse 0);

            while (true) {
                loop_counter.inc();
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                op_count += 1;

                switch (op_data) {
                    .regular => |data| {
                        const gas_to_add = @as(u64, opcode_info[data.opcode].gas_cost);
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;

                        // Update stack effect for this opcode
                        if (data.opcode < opcode_info.len) {
                            // Special handling for DUP and SWAP operations
                            // DUP1-DUP16 (0x80-0x8f) require N items on stack but don't consume them
                            if (data.opcode >= 0x80 and data.opcode <= 0x8f) {
                                const dup_n = @as(i32, data.opcode - 0x80 + 1);
                                // DUP needs N items: we need stack_effect + N >= N, so stack_effect >= 0
                                // If stack_effect < 0, we need abs(stack_effect) + N items minimum
                                const min_required = stack_effect - dup_n;
                                if (min_required < min_stack) {
                                    min_stack = min_required;
                                }
                                stack_effect += 1; // DUP pushes 1 item
                                if (stack_effect > max_stack) max_stack = stack_effect;
                            }
                            // SWAP1-SWAP16 (0x90-0x9f) require N+1 items on stack but don't change count
                            else if (data.opcode >= 0x90 and data.opcode <= 0x9f) {
                                const swap_n = @as(i32, data.opcode - 0x90 + 2); // SWAP1 needs 2 items, SWAP2 needs 3, etc.
                                // SWAP needs N+1 items: similar calculation
                                const min_required = stack_effect - swap_n;
                                if (min_required < min_stack) {
                                    min_stack = min_required;
                                }
                                // SWAP doesn't change stack size
                            }
                            // Regular opcodes
                            else {
                                stack_effect -= opcode_info[data.opcode].stack_inputs;
                                if (stack_effect < min_stack) min_stack = stack_effect;
                                stack_effect += opcode_info[data.opcode].stack_outputs;
                                if (stack_effect > max_stack) max_stack = stack_effect;
                            }
                        }

                        switch (data.opcode) {
                            0x56, 0x57, 0x00, 0xf3, 0xfd, 0xfe, 0xff => {
                                if (data.opcode == 0x57) {}
                                return .{
                                    .gas = @intCast(gas),
                                    .min_stack = @intCast(@abs(min_stack)),
                                    .max_stack = @intCast(@max(0, max_stack)),
                                };
                            },
                            else => {},
                        }
                    },
                    .push => |data| {
                        const push_opcode = 0x60 + data.size - 1;
                        const gas_to_add = @as(u64, opcode_info[push_opcode].gas_cost);
                        const new_gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        gas = new_gas;

                        // PUSH operations: 0 inputs, 1 output
                        // stack_effect -= 0; (no inputs)
                        stack_effect += 1; // 1 output
                        if (stack_effect > max_stack) max_stack = stack_effect;
                    },
                    .jumpdest => {
                        return .{
                            .gas = @intCast(gas),
                            .min_stack = @intCast(@abs(min_stack)),
                            .max_stack = @intCast(@max(0, max_stack)),
                        };
                    },
                    .stop, .invalid => {
                        const gas_to_add = @as(u64, opcode_info[0x00].gas_cost);
                        gas = std.math.add(u64, gas, gas_to_add) catch gas;
                        return .{
                            .gas = @intCast(gas),
                            .min_stack = @intCast(@abs(min_stack)),
                            .max_stack = @intCast(@max(0, max_stack)),
                        };
                    },
                    else => {
                        const new_gas = std.math.add(u64, gas, 6) catch gas;
                        gas = new_gas;
                        // For other instructions, assume minimal stack effect
                        // This is conservative - real implementation would need detailed analysis
                    },
                }
            }

            return .{
                .gas = @intCast(gas),
                .min_stack = @intCast(@abs(min_stack)),
                .max_stack = @intCast(@max(0, max_stack)),
            };
        }

        const UnresolvedJump = struct {
            schedule_index: usize, // Index in schedule where jump_static metadata is
            target_pc: FrameType.PcType, // PC of the jump destination
        };

        const JumpDestEntry = struct {
            pc: FrameType.PcType,
            schedule_index: usize,

            fn lessThan(context: void, a: JumpDestEntry, b: JumpDestEntry) bool {
                _ = context;
                return a.pc < b.pc;
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            bytecode: anytype,
            opcode_handlers: *const [256]OpcodeHandler,
            tracer: anytype,
        ) !DispatchSchedule {
            const log = @import("../log.zig");
            log.debug("Dispatch.init: Starting bytecode analysis", .{});

            if (tracer) |t| t.onScheduleBuildStart(bytecode.len());

            const ScheduleList = ArrayList(Self.Item, null);
            var schedule_items = ScheduleList{};
            errdefer schedule_items.deinit(allocator);

            var jumpdest_entries = ArrayList(JumpDestEntry, null){};
            defer jumpdest_entries.deinit(allocator);

            var unresolved_jumps = ArrayList(UnresolvedJump, null){};
            defer unresolved_jumps.deinit(allocator);

            var iter = bytecode.createIterator();

            const first_block_info = calculateFirstBlockInfo(bytecode);

            // Add first block metadata if there's any gas cost OR stack requirements
            if (first_block_info.gas > 0 or first_block_info.min_stack > 0 or first_block_info.max_stack > 0) {
                try schedule_items.append(allocator, .{ .first_block_gas = first_block_info });
            }

            var opcode_count: usize = 0;
            var loop_counter = FrameType.config.createLoopSafetyCounter().init(FrameType.config.loop_quota orelse 0);
            while (true) {
                loop_counter.inc();
                const instr_pc = iter.pc;
                const maybe = iter.next();
                if (maybe == null) break;
                const op_data = maybe.?;
                opcode_count += 1;

                switch (op_data) {
                    .regular => |data| {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[data.opcode] });
                    },
                    .pc => |data| {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.PC)] });
                        try schedule_items.append(allocator, .{ .pc = .{ .value = data.value } });
                    },
                    .jump => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMP)] });
                    },
                    .jumpi => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPI)] });
                    },
                    .push => |data| {
                        try processPushOpcode(&schedule_items, allocator, opcode_handlers, data);
                    },
                    .jumpdest => |data| {
                        // Record this JUMPDEST's location in schedule for single-pass resolution
                        // We store the index where the JUMPDEST handler will be placed
                        const jumpdest_schedule_idx = schedule_items.items.len;

                        try jumpdest_entries.append(allocator, .{
                            .pc = @intCast(instr_pc),
                            .schedule_index = jumpdest_schedule_idx,
                        });

                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.JUMPDEST)] });
                        try schedule_items.append(allocator, .{ .jump_dest = .{
                            .gas = data.gas_cost,
                            .min_stack = data.min_stack,
                            .max_stack = data.max_stack,
                        } });
                    },
                    .push_add_fusion => |data| {
                        if (tracer) |t| t.onFusionDetected(@intCast(instr_pc), "push_add", 2);
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_add);
                    },
                    .push_mul_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_mul);
                    },
                    .push_sub_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_sub);
                    },
                    .push_div_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_div);
                    },
                    .push_and_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_and);
                    },
                    .push_or_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_or);
                    },
                    .push_xor_fusion => |data| {
                        try Self.handleFusionOperation(&schedule_items, allocator, data.value, .push_xor);
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
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mload);
                    },
                    .push_mstore_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mstore);
                    },
                    .push_mstore8_fusion => |data| {
                        try Self.handleMemoryFusion(&schedule_items, allocator, data.value, .push_mstore8);
                    },
                    .stop => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
                    },
                    .invalid => {
                        try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.INVALID)] });
                    },
                    .multi_push => |mp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_PUSH_3));

                        try schedule_items.append(allocator, .{ .opcode_handler = handler });

                        var i: u8 = 0;
                        while (i < mp.count) : (i += 1) {
                            const value = mp.values[i];
                            if (value <= std.math.maxInt(u64)) {
                                try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(value) } });
                            } else {
                                // Allocate individual u256 value on heap
                                const value_ptr = try allocator.create(FrameType.WordType);
                                errdefer allocator.destroy(value_ptr);
                                value_ptr.* = value;
                                try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                            }
                        }
                    },
                    .multi_pop => |mp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = if (mp.count == 2)
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_2))
                        else
                            frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MULTI_POP_3));

                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .iszero_jumpi => |ij| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.ISZERO_JUMPI));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                        if (ij.target <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(ij.target) } });
                        } else {
                            // Allocate individual u256 value on heap
                            const value_ptr = try allocator.create(FrameType.WordType);
                            errdefer allocator.destroy(value_ptr);
                            value_ptr.* = ij.target;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                        }
                    },
                    .dup2_mstore_push => |dmp| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP2_MSTORE_PUSH));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });

                        if (dmp.push_value <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(dmp.push_value) } });
                        } else {
                            // Allocate individual u256 value on heap
                            const value_ptr = try allocator.create(FrameType.WordType);
                            errdefer allocator.destroy(value_ptr);
                            value_ptr.* = dmp.push_value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                        }
                    },
                    .dup3_add_mstore => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.DUP3_ADD_MSTORE));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .swap1_dup2_add => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.SWAP1_DUP2_ADD));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .push_dup3_add => |pda| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH_DUP3_ADD));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });

                        if (pda.value <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(pda.value) } });
                        } else {
                            // Allocate individual u256 value on heap
                            const value_ptr = try allocator.create(FrameType.WordType);
                            errdefer allocator.destroy(value_ptr);
                            value_ptr.* = pda.value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                        }
                    },
                    .function_dispatch => |fd| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.FUNCTION_DISPATCH));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });

                        try schedule_items.append(allocator, .{ .push_inline = .{ .value = @as(u64, fd.selector) } });

                        if (fd.target <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(fd.target) } });
                        } else {
                            // Allocate individual u256 value on heap
                            const value_ptr = try allocator.create(FrameType.WordType);
                            errdefer allocator.destroy(value_ptr);
                            value_ptr.* = fd.target;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                        }
                    },
                    .callvalue_check => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.CALLVALUE_CHECK));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .push0_revert => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH0_REVERT));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                    .push_add_dup1 => |pad| {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.PUSH_ADD_DUP1));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });

                        // Add push value as metadata
                        if (pad.value <= std.math.maxInt(u64)) {
                            try schedule_items.append(allocator, .{ .push_inline = .{ .value = @intCast(pad.value) } });
                        } else {
                            // Allocate individual u256 value on heap
                            const value_ptr = try allocator.create(FrameType.WordType);
                            errdefer allocator.destroy(value_ptr);
                            value_ptr.* = pad.value;
                            try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
                        }
                    },
                    .mload_swap1_dup2 => {
                        const frame_handlers = @import("../frame/frame_handlers.zig");
                        const handler = frame_handlers.getSyntheticHandler(FrameType, @intFromEnum(OpcodeSynthetic.MLOAD_SWAP1_DUP2));
                        try schedule_items.append(allocator, .{ .opcode_handler = handler });
                    },
                }
            }

            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });
            try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers.*[@intFromEnum(Opcode.STOP)] });

            const final_schedule = try schedule_items.toOwnedSlice(allocator);

            const jumpdest_array = try jumpdest_entries.toOwnedSlice(allocator);
            defer allocator.free(jumpdest_array);
            std.sort.block(JumpDestEntry, jumpdest_array, {}, JumpDestEntry.lessThan);

            try resolveStaticJumpsWithArray(final_schedule, &unresolved_jumps, jumpdest_array, tracer);

            if (tracer) |t| {
                t.onScheduleBuildComplete(final_schedule.len, 0); // No longer tracking u256 count
                t.onJumpTableCreated(jumpdest_array.len);
            }

            return DispatchSchedule{
                .items = final_schedule,
                .allocator = allocator,
            };
        }

        fn handleFusionOperation(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);
            try schedule_items.append(allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{ .push_inline = .{ .value = inline_val } });
            } else {
                // Allocate individual u256 value on heap
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
            }
        }

        fn handleMemoryFusion(
            schedule_items: anytype,
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
        ) !void {
            // Import gas constants for static calculation
            const GasConstants = @import("voltaire").GasConstants;

            // Calculate static gas cost since we know the offset at compile time
            var static_gas_cost: u64 = GasConstants.GasFastestStep;

            // For memory operations with known offsets, we can calculate expansion cost statically
            if (value <= std.math.maxInt(usize)) {
                const offset_usize = @as(usize, @intCast(value));
                // Check for overflow before addition
                const add_amount: usize = switch (fusion_type) {
                    .push_mload, .push_mstore => 32,
                    .push_mstore8 => 1,
                    else => unreachable,
                };
                if (offset_usize > std.math.maxInt(usize) - add_amount) {
                    // Overflow would occur, skip fusion optimization
                    return;
                }
                const size_needed = offset_usize + add_amount;

                // Calculate memory expansion cost statically
                // Memory cost = 3 * words + words^2 / 512
                const new_words = (size_needed + 31) / 32;

                // Compile-time safety check: Verify that u64 max is much larger than the configured
                // block gas limit. This allows us to safely use saturating arithmetic - any memory
                // access large enough to overflow u64 would cost far more gas than any block could provide.
                comptime {
                    if (std.math.maxInt(u64) <= FrameType.config.block_gas_limit) {
                        @compileError("u64 max must be greater than block_gas_limit for saturating arithmetic to work correctly. " ++
                            "u64 max: " ++ std.fmt.comptimePrint("{}", .{std.math.maxInt(u64)}) ++
                            ", block_gas_limit: " ++ std.fmt.comptimePrint("{}", .{FrameType.config.block_gas_limit}) ++
                            ". The saturating arithmetic assumption requires that any overflow results in costs exceeding block limits.");
                    }
                }

                // Use saturating arithmetic to prevent overflow on large memory operations
                // If this saturates, the gas cost will be astronomical (>18 quintillion),
                // which will fail gas checks long before execution
                const words_squared = @as(u64, new_words) *| @as(u64, new_words);
                const memory_cost = 3 *| new_words +| (words_squared / 512);
                static_gas_cost +|= memory_cost;
            }

            const synthetic_opcode = getSyntheticOpcode(fusion_type, value <= std.math.maxInt(u64));
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const synthetic_handler = frame_handlers.getSyntheticHandler(FrameType, synthetic_opcode);

            try schedule_items.append(allocator, .{ .opcode_handler = synthetic_handler });

            if (value <= std.math.maxInt(u64)) {
                const inline_val: u64 = @intCast(value);
                try schedule_items.append(allocator, .{
                    .push_inline = .{
                        .value = inline_val,
                        // Store gas cost for use in jumpdest validation
                        // This will be added to jumpdest gas during preprocessing
                    },
                });
            } else {
                // Allocate individual u256 value on heap
                const value_ptr = try allocator.create(FrameType.WordType);
                errdefer allocator.destroy(value_ptr);
                value_ptr.* = value;
                try schedule_items.append(allocator, .{ .push_pointer = .{ .value_ptr = value_ptr } });
            }
        }

        fn handleStaticJumpFusion(
            schedule_items: anytype,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            allocator: std.mem.Allocator,
            value: FrameType.WordType,
            fusion_type: FusionType,
            tracer: anytype,
            jump_pc: u32,
        ) !void {
            if (value > std.math.maxInt(FrameType.PcType)) {
                if (tracer) |t| t.onInvalidStaticJump(jump_pc, @intCast(value & 0xFFFFFFFF));
                const opcode_handlers = @import("../frame/frame_handlers.zig").getOpcodeHandlers(FrameType, &.{});
                try schedule_items.append(allocator, .{ .opcode_handler = opcode_handlers[@intFromEnum(@import("../opcodes/opcode.zig").Opcode.INVALID)] });
                return;
            }
            const dest_pc: FrameType.PcType = @intCast(value);

            const frame_handlers = @import("../frame/frame_handlers.zig");
            const static_opcode: u8 = switch (fusion_type) {
                .push_jump => @intFromEnum(OpcodeSynthetic.JUMP_TO_STATIC_LOCATION),
                .push_jumpi => @intFromEnum(OpcodeSynthetic.JUMPI_TO_STATIC_LOCATION),
                else => unreachable,
            };
            const static_handler = frame_handlers.getSyntheticHandler(FrameType, static_opcode);
            try schedule_items.append(allocator, .{ .opcode_handler = static_handler });

            const meta_index = schedule_items.items.len;
            const placeholder: *const anyopaque = @as(*const anyopaque, @ptrFromInt(1));
            try schedule_items.append(allocator, .{ .jump_static = .{ .dispatch = placeholder } });
            try unresolved_jumps.append(allocator, .{ .schedule_index = meta_index, .target_pc = dest_pc });
        }

        fn resolveStaticJumpsWithArray(
            schedule: []Item,
            unresolved_jumps: *ArrayList(UnresolvedJump, null),
            jumpdest_array: []const JumpDestEntry,
            tracer: anytype,
        ) !void {
            for (unresolved_jumps.items) |unresolved| {
                var left: usize = 0;
                var right: usize = jumpdest_array.len;

                var found: ?usize = null;
                while (left < right) {
                    const mid = left + (right - left) / 2;
                    const mid_pc = jumpdest_array[mid].pc;

                    if (mid_pc == unresolved.target_pc) {
                        found = mid;
                        break;
                    } else if (mid_pc < unresolved.target_pc) {
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
                        t.onStaticJumpResolved(0, unresolved.target_pc);
                    }
                } else {
                    @branchHint(.cold);
                    if (tracer) |t| t.onInvalidStaticJump(0, unresolved.target_pc);
                    return error.InvalidStaticJump;
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

        pub fn createJumpTable(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            bytecode: anytype,
        ) !JumpTable {
            const log = @import("../log.zig");

            // We need the bytecode to find JUMPDEST PCs
            const actual_bytecode = if (@typeInfo(@TypeOf(bytecode)) == .error_union)
                try bytecode
            else
                bytecode;

            var jumpdest_entries = ArrayList(JumpDestEntry, null){};
            defer jumpdest_entries.deinit(allocator);

            // Create a mapping of JUMPDEST PCs to their schedule indices
            // by walking through the schedule and bytecode in parallel

            var bytecode_iter = actual_bytecode.createIterator();
            var schedule_index: usize = 0;

            // Skip first_block_gas if present
            if (schedule.len > 0 and schedule[0] == .first_block_gas) {
                schedule_index = 1;
            }

            // Get JUMPDEST handler for comparison
            const frame_handlers = @import("../frame/frame_handlers.zig");
            const jumpdest_handler = frame_handlers.getOpcodeHandlers(FrameType, &.{})[@intFromEnum(Opcode.JUMPDEST)];

            // Walk through schedule and find all JUMPDEST handlers
            var jumpdest_pcs = ArrayList(FrameType.PcType, null){};
            defer jumpdest_pcs.deinit(allocator);

            // First, collect all JUMPDEST PCs from bytecode
            while (bytecode_iter.next()) |op_data| {
                // The PC is already at the start of the next instruction, so we need to go back
                const instr_len = switch (op_data) {
                    .regular => 1,
                    .jumpdest => 1,
                    .push => |data| 1 + data.size,
                    .jump, .jumpi => 1,
                    .pc => 1,
                    .stop, .invalid => 1,
                    else => 1, // For other cases, assume 1 byte
                };
                const pc = bytecode_iter.pc - instr_len;
                if (op_data == .jumpdest) {
                    // Cast to FrameType.PcType for storage
                    const jumpdest_pc: FrameType.PcType = @intCast(pc);
                    try jumpdest_pcs.append(allocator, jumpdest_pc);
                }
            }

            // Now find each JUMPDEST in the schedule
            var jumpdest_idx: usize = 0;
            for (schedule, 0..) |item, index| {
                if (item == .opcode_handler and item.opcode_handler == jumpdest_handler) {
                    // This is a JUMPDEST handler
                    if (jumpdest_idx < jumpdest_pcs.items.len) {
                        const pc = jumpdest_pcs.items[jumpdest_idx];
                        try jumpdest_entries.append(allocator, .{
                            .pc = pc,
                            .schedule_index = index,
                        });

                        if (pc == 0x304) {
                            log.warn("Found PC=0x304 JUMPDEST at schedule[{}] (fixed approach)", .{index});
                        }

                        jumpdest_idx += 1;
                    }
                }
            }

            const jumpdest_array = try jumpdest_entries.toOwnedSlice(allocator);
            defer allocator.free(jumpdest_array);
            std.sort.block(JumpDestEntry, jumpdest_array, {}, JumpDestEntry.lessThan);

            return try createJumpTableFromArray(allocator, schedule, jumpdest_array);
        }

        fn createJumpTableFromArray(
            allocator: std.mem.Allocator,
            schedule: []const Item,
            jumpdest_array: []const JumpDestEntry,
        ) !JumpTable {
            const log = @import("../log.zig");
            const entries = try allocator.alloc(JumpTable.JumpTableEntry, jumpdest_array.len);
            errdefer allocator.free(entries);

            // Debug logging for jump table construction
            log.debug("=== Jump Table Construction ===", .{});
            log.debug("Total JUMPDESTs: {}", .{jumpdest_array.len});

            for (jumpdest_array, 0..) |jumpdest, i| {
                entries[i] = .{
                    .pc = jumpdest.pc,
                    .dispatch = Self{
                        .cursor = schedule.ptr + jumpdest.schedule_index,
                    },
                };

                // Debug log each jump table entry
                if (jumpdest.pc == 0x304) {
                    log.warn("Jump table entry: PC=0x304 -> schedule[{}]", .{jumpdest.schedule_index});
                    if (jumpdest.schedule_index < schedule.len) {
                        log.warn("  Schedule item at [{}]: {s}", .{ jumpdest.schedule_index, @tagName(schedule[jumpdest.schedule_index]) });
                    }
                }
            }

            if (std.debug.runtime_safety and entries.len > 1) {
                for (entries[0..entries.len -| 1], entries[1..]) |current, next| {
                    if (current.pc >= next.pc) {
                        std.debug.panic("JumpTable not properly sorted: PC {} >= {}", .{ current.pc, next.pc });
                    }
                }
            }

            return JumpTable{ .entries = entries };
        }

        pub const DispatchSchedule = struct {
            items: []Item,
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator, bytecode: anytype, opcode_handlers: *const [256]OpcodeHandler, tracer: anytype) !DispatchSchedule {
                return try Self.init(allocator, bytecode, opcode_handlers, tracer);
            }

            pub fn deinit(self: *DispatchSchedule) void {
                // Free individually allocated u256 values
                for (self.items) |item| {
                    switch (item) {
                        .push_pointer => |push_data| {
                            self.allocator.destroy(push_data.value_ptr);
                        },
                        else => {},
                    }
                }
                self.allocator.free(self.items);
            }

            pub fn getDispatch(self: *const DispatchSchedule) Self {
                return Self{
                    .cursor = self.items.ptr,
                };
            }

            /// Validates the dispatch schedule structure for correctness.
            /// Ensures:
            /// 1. Schedule has at least minimal structure
            /// 2. Schedule ends with two STOP handlers
            /// 3. No orphaned metadata items (metadata without preceding handler)
            pub fn validate(self: *const DispatchSchedule) bool {
                if (self.items.len == 0) return false;

                // Validate schedule ends with two STOP handlers
                if (self.items.len < 2) return false;
                const stop_handler = FrameType.opcode_handlers[@intFromEnum(Opcode.STOP)];
                if (self.items[self.items.len - 1] != .opcode_handler or
                    self.items[self.items.len - 1].opcode_handler != stop_handler) return false;
                if (self.items[self.items.len - 2] != .opcode_handler or
                    self.items[self.items.len - 2].opcode_handler != stop_handler) return false;

                // Validate no orphaned metadata items
                var idx: usize = 0;

                // Skip first_block_gas if present (it's allowed at the beginning)
                if (self.items[0] == .first_block_gas) {
                    idx = 1;
                }

                while (idx < self.items.len - 2) { // -2 because we already validated the last two STOP handlers
                    const item = self.items[idx];
                    switch (item) {
                        .opcode_handler => {
                            // Handler is valid, check if it has metadata
                            idx += 1;
                            if (idx < self.items.len) {
                                // Skip any following metadata (it belongs to this handler)
                                switch (self.items[idx]) {
                                    .jump_dest, .push_inline, .push_pointer, .pc, .jump_static => {
                                        idx += 1;
                                    },
                                    else => {},
                                }
                            }
                        },
                        // These should never appear without a preceding handler
                        .jump_dest, .push_inline, .push_pointer, .pc, .jump_static => {
                            return false; // Orphaned metadata
                        },
                        .first_block_gas => {
                            // Should only appear at the beginning
                            return false;
                        },
                    }
                }

                return true;
            }
        };

        pub const ScheduleIterator = struct {
            schedule: []const Item,
            bytecode: *const anyopaque,
            pc: FrameType.PcType = 0,
            schedule_index: usize = 0,

            pub const Entry = struct {
                pc: FrameType.PcType,
                schedule_index: usize,
                op_data: enum { regular, push, jumpdest, stop, invalid, fusion },
            };

            pub fn init(schedule: []const Item, bytecode: anytype) ScheduleIterator {
                return .{
                    .schedule = schedule,
                    .bytecode = bytecode,
                    .pc = 0,
                    .schedule_index = 0,
                };
            }

            pub fn next(self: *ScheduleIterator) ?Entry {
                if (self.schedule_index >= self.schedule.len) return null;

                if (self.schedule_index == 0) {
                    const first_block_gas = calculateFirstBlockGas(self.bytecode);
                    if (first_block_gas > 0) {
                        self.schedule_index = 1;
                        if (self.schedule_index >= self.schedule.len) return null;
                    }
                }

                const current_pc = self.pc;
                const current_index = self.schedule_index;

                const item = self.schedule[self.schedule_index];
                const op_type: Entry.op_data = switch (item) {
                    .opcode_handler => blk: {
                        break :blk .regular;
                    },
                    .jump_dest => .jumpdest,
                    .push_inline, .push_pointer => .push,
                    else => .regular,
                };

                self.schedule_index += 1;

                if (self.schedule_index < self.schedule.len) {
                    switch (self.schedule[self.schedule_index]) {
                        .jump_dest, .push_inline, .push_pointer, .pc => {
                            self.schedule_index += 1;
                        },
                        else => {},
                    }
                }

                self.pc += 1;

                return Entry{
                    .pc = current_pc,
                    .schedule_index = current_index,
                    .op_data = op_type,
                };
            }
        };

        pub const JumpTableBuilder = dispatch_jump_table_builder.JumpTableBuilder(FrameType, Self);

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
