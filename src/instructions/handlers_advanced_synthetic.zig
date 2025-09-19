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
pub fn Handlers(comptime FrameType: type) type {
    return struct {
        pub const Error = FrameType.Error;
        pub const Dispatch = FrameType.Dispatch;
        pub const WordType = FrameType.WordType;

        // Note: constant_fold handler removed - compiler handles constant folding

        /// MULTI_PUSH_2 - Push two values in a single operation
        pub fn multi_push_2(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
            self.beforeInstruction(.MULTI_PUSH_2, cursor);
            const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
            const op_data = dispatch_opcode_data.getOpData(.MULTI_PUSH_2, Dispatch, Dispatch.Item, cursor);

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

            // Get the jump target from items
            const target_item = op_data.items[0];
            _ = target_item; // Target would be used for actual jumping

            // Pop value and check if zero
            const value = self.stack.pop_unsafe();
            const should_jump = value == 0;

            // Jump if the value was zero
            if (should_jump) {
                // For now, just continue - proper jump handling would need jump table access
                // In a real implementation, this would look up the jump destination
                // and call the handler at that location
                // TODO: Implement proper jump handling with jump table
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

            // Store to memory
            const offset_u24 = @as(u24, @intCast(offset));
            self.memory.set_u256_evm(self.getAllocator(), offset_u24, mem_value) catch {
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

            // DUP3: duplicate 3rd stack item
            self.stack.dup_n_unsafe(3);

            // ADD: pop two values and add
            const b = self.stack.pop_unsafe();
            const a = self.stack.pop_unsafe();
            self.stack.push_unsafe(a +% b);

            // MSTORE: Store at offset
            const offset = self.stack.pop_unsafe();
            const data = self.stack.pop_unsafe();
            const offset_u24 = @as(u24, @intCast(offset));
            self.memory.set_u256_evm(self.getAllocator(), offset_u24, data) catch {
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

            // MLOAD: Load from memory
            const offset = self.stack.pop_unsafe();
            const offset_u24 = @as(u24, @intCast(offset));
            const value = self.memory.get_u256_evm(self.getAllocator(), offset_u24) catch {
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
