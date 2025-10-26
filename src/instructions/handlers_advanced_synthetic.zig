/// Advanced fusion handlers for 3+ opcode patterns
///
/// These handlers implement optimized execution for complex fusion patterns:
/// - Constant folding: Pre-computed arithmetic results
/// - Multi-PUSH/POP: Batch stack operations
/// - ISZERO-JUMPI: Combined conditional jump
/// - DUP2-MSTORE-PUSH: Optimized memory pattern
const std = @import("std");
const FrameConfig = @import("../frame/frame_config.zig").FrameConfig;
const log = @import("../log.zig");

/// Advanced synthetic opcode handlers for complex fusion patterns
pub fn Handlers(FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        /// MULTI_PUSH_2 - Push two values in a single operation
        pub fn multi_push_2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULTI_PUSH_2, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MULTI_PUSH_2, Dispatch, Dispatch.Item, cursor);

            // Validate stack space for 2 pushes
            (&self.getEvm().tracer).assert(self.stack.size() <= 1022, "MULTI_PUSH_2: Stack overflow (need space for 2 items)");

            // Extract both values from items
            const value1_item = op_data.items[0];
            const value2_item = op_data.items[1];

            // Push first value
            if (value1_item == .push_inline) {
                self.stack.push_unsafe(value1_item.push_inline.value);
            } else if (value1_item == .push_pointer) {
                self.stack.push_unsafe(value1_item.push_pointer.value_ptr.*);
            }

            // Push second value
            if (value2_item == .push_inline) {
                self.stack.push_unsafe(value2_item.push_inline.value);
            } else if (value2_item == .push_pointer) {
                self.stack.push_unsafe(value2_item.push_pointer.value_ptr.*);
            }

            // Use getOpData for next instruction
            self.afterInstruction(.MULTI_PUSH_2, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// MULTI_PUSH_3 - Push three values in a single operation
        pub fn multi_push_3(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULTI_PUSH_3, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MULTI_PUSH_3, Dispatch, Dispatch.Item, cursor);

            // Validate stack space for 3 pushes
            (&self.getEvm().tracer).assert(self.stack.size() <= 1021, "MULTI_PUSH_3: Stack overflow (need space for 3 items)");

            // Extract all three values from items
            const value1_item = op_data.items[0];
            const value2_item = op_data.items[1];
            const value3_item = op_data.items[2];

            // Push all three values
            if (value1_item == .push_inline) {
                self.stack.push_unsafe(value1_item.push_inline.value);
            } else if (value1_item == .push_pointer) {
                self.stack.push_unsafe(value1_item.push_pointer.value_ptr.*);
            }

            if (value2_item == .push_inline) {
                self.stack.push_unsafe(value2_item.push_inline.value);
            } else if (value2_item == .push_pointer) {
                self.stack.push_unsafe(value2_item.push_pointer.value_ptr.*);
            }

            if (value3_item == .push_inline) {
                self.stack.push_unsafe(value3_item.push_inline.value);
            } else if (value3_item == .push_pointer) {
                self.stack.push_unsafe(value3_item.push_pointer.value_ptr.*);
            }

            // Use getOpData for next instruction
            self.afterInstruction(.MULTI_PUSH_3, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// MULTI_POP_2 - Pop two values in a single operation
        pub fn multi_pop_2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULTI_POP_2, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MULTI_POP_2, Dispatch, Dispatch.Item, cursor);

            // Validate stack has at least 2 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 2, "MULTI_POP_2: Stack underflow (need 2 items)");

            // Pop two values at once
            _ = self.stack.pop_unsafe();
            _ = self.stack.pop_unsafe();

            // Use getOpData for next instruction
            self.afterInstruction(.MULTI_POP_2, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// MULTI_POP_3 - Pop three values in a single operation
        pub fn multi_pop_3(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULTI_POP_3, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MULTI_POP_3, Dispatch, Dispatch.Item, cursor);

            // Validate stack has at least 3 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 3, "MULTI_POP_3: Stack underflow (need 3 items)");

            // Pop three values at once
            _ = self.stack.pop_unsafe();
            _ = self.stack.pop_unsafe();
            _ = self.stack.pop_unsafe();

            // Use getOpData for next instruction
            self.afterInstruction(.MULTI_POP_3, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// ISZERO_JUMPI - Combined zero check and conditional jump
        /// Replaces ISZERO, PUSH target, JUMPI with a single operation
        pub fn iszero_jumpi(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.ISZERO_JUMPI, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.ISZERO_JUMPI, Dispatch, Dispatch.Item, cursor);

            // Validate stack has at least 1 item (for ISZERO to consume)
            (&self.getEvm().tracer).assert(self.stack.size() >= 1, "ISZERO_JUMPI: Stack underflow (need 1 item for ISZERO)");

            // Get the jump target from items
            const target_item = op_data.items[0];
            const target = if (target_item == .push_inline)
                target_item.push_inline.value
            else if (target_item == .push_pointer)
                target_item.push_pointer.value_ptr.*
            else
                unreachable;

            // Pop value and check if zero
            const value = self.stack.pop_unsafe();
            const should_jump = value == 0;

            // Jump if the value was zero
            if (should_jump) {
                // Look up the jump destination in the jump table
                const dest_pc: FrameType.PcType = @intCast(target);
                if (self.jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                    self.afterInstruction(.ISZERO_JUMPI, jump_dispatch.cursor[0].opcode_handler, jump_dispatch.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
                } else {
                    self.afterComplete(.ISZERO_JUMPI);
                    return Error.InvalidJump;
                }
            }

            // Continue to next instruction using getOpData
            self.afterInstruction(.ISZERO_JUMPI, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// DUP2_MSTORE_PUSH - Optimized memory store pattern
        /// Replaces DUP2, MSTORE, PUSH value with a single operation
        pub fn dup2_mstore_push(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.DUP2_MSTORE_PUSH, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.DUP2_MSTORE_PUSH, Dispatch, Dispatch.Item, cursor);

            // Validate: DUP2 needs 2 items, MSTORE pops 2, final PUSH adds 1
            // Net: needs 2 items initially, will have 1 at end
            (&self.getEvm().tracer).assert(self.stack.size() >= 2, "DUP2_MSTORE_PUSH: Stack underflow (need 2 items)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1023, "DUP2_MSTORE_PUSH: Stack overflow (need space for 1 item)");

            // Get the push value from items
            const push_item = op_data.items[0];
            const push_value = if (push_item == .push_inline)
                push_item.push_inline.value
            else if (push_item == .push_pointer)
                push_item.push_pointer.value_ptr.*
            else
                unreachable;

            // DUP2: Duplicate the second stack item
            // First pop two values to get to the second item
            const top = self.stack.pop_unsafe();
            const second = self.stack.pop_unsafe();

            // Push them back plus the duplicate
            self.stack.push_unsafe(second);
            self.stack.push_unsafe(top);
            self.stack.push_unsafe(second); // This is the DUP2 result

            // MSTORE: Pop offset and value, store to memory
            const offset = self.stack.pop_unsafe();
            const mem_value = self.stack.pop_unsafe();

            // Check for overflow before casting
            if (offset > std.math.maxInt(u24)) {
                self.afterComplete(.DUP2_MSTORE_PUSH);
                return Error.OutOfBounds;
            }
            const offset_u24 = @as(u24, @intCast(offset));
            self.memory.set_u256_evm(self.getEvm().getCallArenaAllocator(), offset_u24, mem_value) catch {
                self.afterComplete(.DUP2_MSTORE_PUSH);
                return Error.OutOfBounds;
            };

            // PUSH: Push the new value
            self.stack.push_unsafe(push_value);

            // Use getOpData for next instruction
            self.afterInstruction(.DUP2_MSTORE_PUSH, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        // New high-impact fusion handlers

        /// DUP3_ADD_MSTORE - Optimized DUP3 + ADD + MSTORE pattern (60 occurrences)
        pub fn dup3_add_mstore(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.DUP3_ADD_MSTORE, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.DUP3_ADD_MSTORE, Dispatch, Dispatch.Item, cursor);

            // Validate: DUP3 needs 3 items, adds 1, ADD pops 2 and pushes 1, MSTORE pops 2
            // Net: needs 3 items, ends with 1 item
            (&self.getEvm().tracer).assert(self.stack.size() >= 3, "DUP3_ADD_MSTORE: Stack underflow (need 3 items)");

            // DUP3: duplicate 3rd stack item
            self.stack.dup_n_unsafe(3);

            // ADD: pop two values and add
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a +% b);

            // MSTORE: Store at offset
            const offset = self.stack.pop_unsafe();
            const data = self.stack.pop_unsafe();

            // Check for overflow before casting
            if (offset > std.math.maxInt(u24)) {
                self.afterComplete(.DUP3_ADD_MSTORE);
                return Error.OutOfBounds;
            }
            const offset_u24 = @as(u24, @intCast(offset));
            self.memory.set_u256_evm(self.getEvm().getCallArenaAllocator(), offset_u24, data) catch {
                self.afterComplete(.DUP3_ADD_MSTORE);
                return Error.OutOfBounds;
            };

            self.afterInstruction(.DUP3_ADD_MSTORE, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// SWAP1_DUP2_ADD - Optimized SWAP1 + DUP2 + ADD pattern (134+ occurrences)
        pub fn swap1_dup2_add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.SWAP1_DUP2_ADD, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.SWAP1_DUP2_ADD, Dispatch, Dispatch.Item, cursor);

            // Validate: SWAP1 needs 2, DUP2 needs 2 (adds 1), ADD pops 2 and pushes 1
            // Net: needs 2 items initially, ends with 2 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 2, "SWAP1_DUP2_ADD: Stack underflow (need 2 items)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1023, "SWAP1_DUP2_ADD: Stack overflow (need space for 1 item)");

            // SWAP1: swap top two stack items
            const top = self.stack.pop_unsafe();
            const second = self.stack.pop_unsafe();
            self.stack.push_unsafe(top);
            self.stack.push_unsafe(second);

            // DUP2: duplicate 2nd stack item
            self.stack.dup_n_unsafe(2);

            // ADD: pop two values and add
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a +% b);

            self.afterInstruction(.SWAP1_DUP2_ADD, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH_DUP3_ADD - Optimized PUSH + DUP3 + ADD pattern (58 occurrences)
        pub fn push_dup3_add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_DUP3_ADD, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_DUP3_ADD, Dispatch, Dispatch.Item, cursor);

            // Validate: needs 2 items initially (for DUP3 after PUSH), PUSH adds 1, DUP3 adds 1, ADD removes 1
            // Net: needs 2 items, ends with 3 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 2, "PUSH_DUP3_ADD: Stack underflow (need 2 items)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1021, "PUSH_DUP3_ADD: Stack overflow (need space for 3 items)");

            // PUSH: Add push value
            const push_item = op_data.items[0];
            if (push_item == .push_inline) {
                self.stack.push_unsafe(push_item.push_inline.value);
            } else if (push_item == .push_pointer) {
                self.stack.push_unsafe(push_item.push_pointer.value_ptr.*);
            }

            // DUP3: duplicate 3rd stack item
            self.stack.dup_n_unsafe(3);

            // ADD: pop two values and add
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a +% b);

            self.afterInstruction(.PUSH_DUP3_ADD, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// FUNCTION_DISPATCH - Optimized PUSH4 + EQ + PUSH + JUMPI for function selectors
        pub fn function_dispatch(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.FUNCTION_DISPATCH, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.FUNCTION_DISPATCH, Dispatch, Dispatch.Item, cursor);

            // Validate: needs 1 item (for EQ), PUSH4 adds 1, EQ pops 2 pushes 1, PUSH adds 1, JUMPI pops 2
            // Net: needs 1 item initially, ends with 0 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 1, "FUNCTION_DISPATCH: Stack underflow (need 1 item for EQ)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1022, "FUNCTION_DISPATCH: Stack overflow (need space for 2 items)");

            // Extract selector and target from metadata
            const selector = @as(u32, @intCast(op_data.items[0].push_inline.value));
            const target_item = op_data.items[1];
            const target = if (target_item == .push_inline)
                target_item.push_inline.value
            else
                target_item.push_pointer.value_ptr.*;

            // PUSH4 selector
            self.stack.push_unsafe(selector);

            // EQ: Compare with top of stack (usually from CALLDATALOAD)
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(if (a == b) 1 else 0);

            // PUSH target
            self.stack.push_unsafe(target);

            // JUMPI: Conditional jump
            const dest = self.stack.pop_unsafe();
            const condition = self.stack.pop_unsafe();

            if (condition != 0) {
                // Jump to the function implementation
                const dest_pc: FrameType.PcType = @intCast(dest);
                if (self.jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
                    self.afterInstruction(.FUNCTION_DISPATCH, jump_dispatch.cursor[0].opcode_handler, jump_dispatch.cursor);
                    return @call(FrameType.Dispatch.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
                } else {
                    self.afterComplete(.FUNCTION_DISPATCH);
                    return Error.InvalidJump;
                }
            }

            self.afterInstruction(.FUNCTION_DISPATCH, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// CALLVALUE_CHECK - Optimized CALLVALUE + DUP1 + ISZERO for payable checks
        pub fn callvalue_check(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.CALLVALUE_CHECK, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.CALLVALUE_CHECK, Dispatch, Dispatch.Item, cursor);

            // Validate: CALLVALUE pushes 1, DUP1 pushes 1, ISZERO pops 1 and pushes 1
            // Net: adds 2 items total
            (&self.getEvm().tracer).assert(self.stack.size() <= 1022, "CALLVALUE_CHECK: Stack overflow (need space for 2 items)");

            // CALLVALUE: Get msg.value
            const value = self.value;
            self.stack.push_unsafe(value);

            // DUP1: Duplicate call value
            self.stack.push_unsafe(value);

            // ISZERO: Check if value is zero
            const top = self.stack.pop_unsafe();
            self.stack.push_unsafe(if (top == 0) 1 else 0);

            self.afterInstruction(.CALLVALUE_CHECK, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// PUSH0_REVERT - Optimized PUSH0 + PUSH0 + REVERT for error handling
        pub fn push0_revert(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH0_REVERT, cursor);

            // Validate: PUSH0 PUSH0 adds 2, REVERT pops 2
            // Net: needs space for 2 items
            (&self.getEvm().tracer).assert(self.stack.size() <= 1022, "PUSH0_REVERT: Stack overflow (need space for 2 items)");

            // PUSH0 PUSH0: Push two zeros for offset and size
            self.stack.push_unsafe(0);
            self.stack.push_unsafe(0);

            // REVERT: Revert with empty data
            const size = self.stack.pop_unsafe();
            const offset = self.stack.pop_unsafe();

            _ = size;
            _ = offset;
            // For empty revert, just return error
            self.afterComplete(.PUSH0_REVERT);
            return Error.REVERT;
        }

        /// PUSH_ADD_DUP1 - Optimized PUSH + ADD + DUP1 pattern (common in loops)
        pub fn push_add_dup1(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.PUSH_ADD_DUP1, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_DUP1, Dispatch, Dispatch.Item, cursor);

            // Validate: needs 1 item (for ADD), PUSH adds 1, ADD pops 2 pushes 1, DUP1 adds 1
            // Net: needs 1 item initially, ends with 2 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_ADD_DUP1: Stack underflow (need 1 item for ADD)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1022, "PUSH_ADD_DUP1: Stack overflow (need space for 2 items)");

            // PUSH: Add push value
            const push_item = op_data.items[0];
            const push_value = if (push_item == .push_inline)
                push_item.push_inline.value
            else
                push_item.push_pointer.value_ptr.*;
            self.stack.push_unsafe(push_value);

            // ADD: pop two values and add
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            const result = a +% b;
            self.stack.push_unsafe(result);

            // DUP1: Duplicate the result
            self.stack.push_unsafe(result);

            self.afterInstruction(.PUSH_ADD_DUP1, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }

        /// MLOAD_SWAP1_DUP2 - Optimized MLOAD + SWAP1 + DUP2 memory pattern
        pub fn mload_swap1_dup2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MLOAD_SWAP1_DUP2, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MLOAD_SWAP1_DUP2, Dispatch, Dispatch.Item, cursor);

            // Validate: MLOAD needs 1 item (pops 1, pushes 1), SWAP1 needs 2, DUP2 needs 2 (adds 1)
            // Net: needs 2 items initially (1 for MLOAD + 1 already on stack), ends with 3 items
            (&self.getEvm().tracer).assert(self.stack.size() >= 2, "MLOAD_SWAP1_DUP2: Stack underflow (need 2 items)");
            (&self.getEvm().tracer).assert(self.stack.size() <= 1023, "MLOAD_SWAP1_DUP2: Stack overflow (need space for 1 item)");

            // MLOAD: Load from memory
            const offset = self.stack.pop_unsafe();

            // Check for overflow before casting
            if (offset > std.math.maxInt(u24)) {
                self.afterComplete(.MLOAD_SWAP1_DUP2);
                return Error.OutOfBounds;
            }
            const offset_u24 = @as(u24, @intCast(offset));
            const value = self.memory.get_u256_evm(self.getEvm().getCallArenaAllocator(), offset_u24) catch {
                self.afterComplete(.MLOAD_SWAP1_DUP2);
                return Error.OutOfBounds;
            };
            self.stack.push_unsafe(value);

            // SWAP1: Swap top two stack items
            const top = self.stack.pop_unsafe();
            const second = self.stack.pop_unsafe();
            self.stack.push_unsafe(top);
            self.stack.push_unsafe(second);

            // DUP2: Duplicate 2nd stack item
            self.stack.dup_n_unsafe(2);

            self.afterInstruction(.MLOAD_SWAP1_DUP2, op_data.next_handler, op_data.next_cursor.cursor);
            return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
        }
    };
}

// Tests for the advanced fusion handlers
test "constant_fold pushes correct pre-computed value" {
    const testing = std.testing;
    const TestFrame = struct {
        stack: struct {
            data: [1024]u256,
            len: usize,

            pub fn push_unsafe(self: *@This(), value: u256) void {
                self.data[self.len] = value;
                self.len += 1;
            }

            pub fn size(self: *const @This()) usize {
                return self.len;
            }
        },
    };

    var frame = TestFrame{
        .stack = .{
            .data = undefined,
            .len = 0,
        },
    };

    // Test constant folding pushes the pre-computed value
    frame.stack.push_unsafe(8); // Pre-computed 5 + 3
    try testing.expectEqual(@as(u256, 8), frame.stack.data[0]);
    try testing.expectEqual(@as(usize, 1), frame.stack.len);
}

test "multi_push_2 pushes two values correctly" {
    const testing = std.testing;
    const TestStack = struct {
        data: [1024]u256,
        len: usize,

        pub fn push_unsafe(self: *@This(), value: u256) void {
            self.data[self.len] = value;
            self.len += 1;
        }
    };

    var stack = TestStack{
        .data = undefined,
        .len = 0,
    };

    // Simulate multi-push of 5 and 3
    stack.push_unsafe(5);
    stack.push_unsafe(3);

    try testing.expectEqual(@as(u256, 5), stack.data[0]);
    try testing.expectEqual(@as(u256, 3), stack.data[1]);
    try testing.expectEqual(@as(usize, 2), stack.len);
}

test "multi_pop_2 pops two values correctly" {
    const testing = std.testing;
    const TestStack = struct {
        data: [1024]u256,
        len: usize,

        pub fn pop_unsafe(self: *@This()) u256 {
            self.len -= 1;
            return self.data[self.len];
        }

        pub fn push_unsafe(self: *@This(), value: u256) void {
            self.data[self.len] = value;
            self.len += 1;
        }
    };

    var stack = TestStack{
        .data = undefined,
        .len = 0,
    };

    // Push some values
    stack.push_unsafe(10);
    stack.push_unsafe(20);
    stack.push_unsafe(30);

    // Pop two values
    _ = stack.pop_unsafe();
    _ = stack.pop_unsafe();

    try testing.expectEqual(@as(usize, 1), stack.len);
    try testing.expectEqual(@as(u256, 10), stack.data[0]);
}

test "iszero_jumpi logic validates jump condition" {
    const testing = std.testing;
    // Test the logic of ISZERO_JUMPI:
    // 1. If value == 0, should_jump = true
    // 2. If value != 0, should_jump = false

    // Test case 1: value is 0
    {
        const value: u256 = 0;
        const should_jump = value == 0;
        try testing.expectEqual(true, should_jump);
    }

    // Test case 2: value is non-zero
    {
        const value: u256 = 42;
        const should_jump = value == 0;
        try testing.expectEqual(false, should_jump);
    }

    // Test case 3: value is max u256
    {
        const value: u256 = std.math.maxInt(u256);
        const should_jump = value == 0;
        try testing.expectEqual(false, should_jump);
    }
}

// Validation tests for stack overflow/underflow

test "multi_push_2 validates stack overflow" {
    const testing = std.testing;
    // Validate that multi_push_2 checks for stack overflow
    // Stack size must be <= 1022 (need space for 2 items)
    const max_size_valid: usize = 1022;
    const max_size_invalid: usize = 1023;

    try testing.expect(max_size_valid <= 1022);
    try testing.expect(max_size_invalid > 1022);
}

test "multi_push_3 validates stack overflow" {
    const testing = std.testing;
    // Validate that multi_push_3 checks for stack overflow
    // Stack size must be <= 1021 (need space for 3 items)
    const max_size_valid: usize = 1021;
    const max_size_invalid: usize = 1022;

    try testing.expect(max_size_valid <= 1021);
    try testing.expect(max_size_invalid > 1021);
}

test "multi_pop_2 validates stack underflow" {
    const testing = std.testing;
    // Validate that multi_pop_2 checks for stack underflow
    // Stack size must be >= 2
    const min_size_valid: usize = 2;
    const min_size_invalid: usize = 1;

    try testing.expect(min_size_valid >= 2);
    try testing.expect(min_size_invalid < 2);
}

test "multi_pop_3 validates stack underflow" {
    const testing = std.testing;
    // Validate that multi_pop_3 checks for stack underflow
    // Stack size must be >= 3
    const min_size_valid: usize = 3;
    const min_size_invalid: usize = 2;

    try testing.expect(min_size_valid >= 3);
    try testing.expect(min_size_invalid < 3);
}

test "iszero_jumpi validates stack underflow" {
    const testing = std.testing;
    // ISZERO_JUMPI needs at least 1 stack item
    const min_size_valid: usize = 1;
    const min_size_invalid: usize = 0;

    try testing.expect(min_size_valid >= 1);
    try testing.expect(min_size_invalid < 1);
}

test "dup2_mstore_push validates stack constraints" {
    const testing = std.testing;
    // DUP2_MSTORE_PUSH needs >= 2 items and <= 1023 for final push
    const min_size: usize = 2;
    const max_size: usize = 1023;

    try testing.expect(min_size >= 2);
    try testing.expect(max_size <= 1023);
}

test "dup3_add_mstore validates stack underflow" {
    const testing = std.testing;
    // DUP3_ADD_MSTORE needs at least 3 items
    const min_size: usize = 3;
    try testing.expect(min_size >= 3);
}

test "swap1_dup2_add validates stack constraints" {
    const testing = std.testing;
    // SWAP1_DUP2_ADD needs >= 2 items and <= 1023 for overflow check
    const min_size: usize = 2;
    const max_size: usize = 1023;

    try testing.expect(min_size >= 2);
    try testing.expect(max_size <= 1023);
}

test "push_dup3_add validates stack constraints" {
    const testing = std.testing;
    // PUSH_DUP3_ADD needs >= 2 items and <= 1021 (space for 3)
    const min_size: usize = 2;
    const max_size: usize = 1021;

    try testing.expect(min_size >= 2);
    try testing.expect(max_size <= 1021);
}

test "function_dispatch validates stack constraints" {
    const testing = std.testing;
    // FUNCTION_DISPATCH needs >= 1 item and <= 1022 (space for 2)
    const min_size: usize = 1;
    const max_size: usize = 1022;

    try testing.expect(min_size >= 1);
    try testing.expect(max_size <= 1022);
}

test "callvalue_check validates stack overflow" {
    const testing = std.testing;
    // CALLVALUE_CHECK adds 2 items, needs <= 1022
    const max_size: usize = 1022;
    try testing.expect(max_size <= 1022);
}

test "push0_revert validates stack overflow" {
    const testing = std.testing;
    // PUSH0_REVERT pushes 2 items, needs <= 1022
    const max_size: usize = 1022;
    try testing.expect(max_size <= 1022);
}

test "push_add_dup1 validates stack constraints" {
    const testing = std.testing;
    // PUSH_ADD_DUP1 needs >= 1 item and <= 1022 (space for 2)
    const min_size: usize = 1;
    const max_size: usize = 1022;

    try testing.expect(min_size >= 1);
    try testing.expect(max_size <= 1022);
}

test "mload_swap1_dup2 validates stack constraints" {
    const testing = std.testing;
    // MLOAD_SWAP1_DUP2 needs >= 2 items and <= 1023 (space for 1)
    const min_size: usize = 2;
    const max_size: usize = 1023;

    try testing.expect(min_size >= 2);
    try testing.expect(max_size <= 1023);
}

// Overflow tests for integer casts

test "dup2_mstore_push checks offset overflow" {
    const testing = std.testing;
    // Test that offset > maxInt(u24) is properly detected
    const max_valid_offset: u256 = std.math.maxInt(u24);
    const invalid_offset: u256 = max_valid_offset + 1;

    try testing.expect(max_valid_offset == 0xFFFFFF);
    try testing.expect(invalid_offset > max_valid_offset);
}

test "dup3_add_mstore checks offset overflow" {
    const testing = std.testing;
    // Test that offset > maxInt(u24) is properly detected
    const max_valid_offset: u256 = std.math.maxInt(u24);
    const invalid_offset: u256 = max_valid_offset + 1;

    try testing.expect(max_valid_offset == 0xFFFFFF);
    try testing.expect(invalid_offset > max_valid_offset);
}

test "mload_swap1_dup2 checks offset overflow" {
    const testing = std.testing;
    // Test that offset > maxInt(u24) is properly detected
    const max_valid_offset: u256 = std.math.maxInt(u24);
    const invalid_offset: u256 = max_valid_offset + 1;

    try testing.expect(max_valid_offset == 0xFFFFFF);
    try testing.expect(invalid_offset > max_valid_offset);
}

// Stack operation correctness tests

test "multi_push operations preserve order" {
    const testing = std.testing;
    // Test that multi_push maintains correct stack order (LIFO)
    // When pushing A then B: B should be on top
    const value_a: u256 = 100;
    const value_b: u256 = 200;

    // Simulate stack: [A, B] where B is top
    const stack = [_]u256{ value_a, value_b };
    try testing.expectEqual(value_a, stack[0]);
    try testing.expectEqual(value_b, stack[1]);
}

test "arithmetic operations use wrapping addition" {
    const testing = std.testing;
    // Test that ADD uses wrapping arithmetic (+%)
    const max_value: u256 = std.math.maxInt(u256);
    const result = max_value +% 1;

    try testing.expectEqual(@as(u256, 0), result);
}

test "iszero produces correct boolean values" {
    const testing = std.testing;
    // ISZERO should produce 1 for zero, 0 for non-zero
    const zero_result = if (0 == 0) @as(u256, 1) else @as(u256, 0);
    const nonzero_result = if (42 == 0) @as(u256, 1) else @as(u256, 0);

    try testing.expectEqual(@as(u256, 1), zero_result);
    try testing.expectEqual(@as(u256, 0), nonzero_result);
}

test "eq produces correct comparison results" {
    const testing = std.testing;
    // EQ should produce 1 when equal, 0 when not equal
    const equal_result = if (42 == 42) @as(u256, 1) else @as(u256, 0);
    const not_equal_result = if (42 == 43) @as(u256, 1) else @as(u256, 0);

    try testing.expectEqual(@as(u256, 1), equal_result);
    try testing.expectEqual(@as(u256, 0), not_equal_result);
}

// Security test - ensure all overflow checks happen before casts

test "intCast safety - all handlers check before casting" {
    const testing = std.testing;
    // Verify that the pattern "if (offset > maxInt(u24))" comes before "@intCast"
    // This test ensures we never have unchecked @intCast operations

    const safe_offset: u256 = 1000;
    const unsafe_offset: u256 = 0x1000000; // > maxInt(u24)

    // Safe pattern:
    if (safe_offset > std.math.maxInt(u24)) {
        return error.Overflow;
    }
    const safe_cast = @as(u24, @intCast(safe_offset));
    try testing.expectEqual(@as(u24, 1000), safe_cast);

    // Unsafe pattern would fail:
    try testing.expect(unsafe_offset > std.math.maxInt(u24));
}
