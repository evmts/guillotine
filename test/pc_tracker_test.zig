/// Tests for PC tracking mechanism
const std = @import("std");
const testing = std.testing;
const evm = @import("evm");
const primitives = @import("primitives");
const pc_tracker_mod = @import("../src/tracer/pc_tracker.zig");

test "PC tracker validates correct bytecode execution" {
    const allocator = testing.allocator;

    // Create simple bytecode: PUSH1 5, PUSH1 3, ADD, STOP
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x60, 0x03, // PUSH1 3
        0x01,       // ADD
        0x00,       // STOP
    };

    // Initialize PC tracker
    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    // Mock frame with stack
    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = [_]u256{0} ** 10,
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }

            pub fn push(self: *@This(), val: u256) void {
                self.data[self.len] = val;
                self.len += 1;
            }
        } = .{},
    };

    var frame = MockFrame{};

    // Simulate execution following the bytecode

    // PC=0: PUSH1 5
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc); // Advanced by 2 (opcode + data)
    frame.stack.push(5);

    // PC=2: PUSH1 3
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 4), tracker.pc); // Advanced by 2 more
    frame.stack.push(3);

    // PC=4: ADD
    tracker.execute(&frame, 0x01);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // Advanced by 1

    // PC=5: STOP
    tracker.execute(&frame, 0x00);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // No advance (execution stops)

    // Tracker should still be valid
    try testing.expectEqual(true, tracker.isValid());
}

test "PC tracker detects bytecode mismatch" {
    const allocator = testing.allocator;
    _ = allocator;

    // Create bytecode: PUSH1 5, ADD
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5
        0x01,       // ADD
    };

    // Initialize PC tracker
    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            pub fn size(self: *const @This()) usize {
                _ = self;
                return 0;
            }
            pub fn get_slice(self: *const @This()) []const u256 {
                _ = self;
                return &[_]u256{};
            }
        } = .{},
    };

    var frame = MockFrame{};

    // Try to execute wrong opcode (MUL instead of PUSH1)
    tracker.execute(&frame, 0x02); // MUL instead of expected PUSH1

    // Tracker should detect the mismatch
    try testing.expectEqual(false, tracker.isValid());
}

test "PC tracker handles JUMP correctly" {
    const allocator = testing.allocator;
    _ = allocator;

    // Create bytecode with jump: PUSH1 5, JUMP, STOP, STOP, JUMPDEST, STOP
    const bytecode = [_]u8{
        0x60, 0x05, // PUSH1 5 (jump destination)
        0x56,       // JUMP
        0x00,       // STOP (skipped)
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST (at PC=5)
        0x00,       // STOP
    };

    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = [_]u256{0} ** 10,
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }

            pub fn push(self: *@This(), val: u256) void {
                self.data[self.len] = val;
                self.len += 1;
            }

            pub fn pop(self: *@This()) u256 {
                self.len -= 1;
                return self.data[self.len];
            }
        } = .{},
    };

    var frame = MockFrame{};

    // PC=0: PUSH1 5
    frame.stack.push(5); // Prepare stack for JUMP
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // PC=2: JUMP to PC=5
    tracker.execute(&frame, 0x56);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // Should have jumped

    // PC=5: JUMPDEST
    tracker.execute(&frame, 0x5b);
    try testing.expectEqual(@as(u32, 6), tracker.pc);

    // PC=6: STOP
    tracker.execute(&frame, 0x00);

    try testing.expectEqual(true, tracker.isValid());
}

test "PC tracker handles JUMPI with condition true" {
    const allocator = testing.allocator;
    _ = allocator;

    // Bytecode: PUSH1 1, PUSH1 6, JUMPI, STOP, STOP, JUMPDEST, STOP
    const bytecode = [_]u8{
        0x60, 0x01, // PUSH1 1 (condition)
        0x60, 0x06, // PUSH1 6 (destination)
        0x57,       // JUMPI
        0x00,       // STOP (skipped)
        0x5b,       // JUMPDEST (at PC=6)
        0x00,       // STOP
    };

    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = [_]u256{0} ** 10,
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }

            pub fn push(self: *@This(), val: u256) void {
                self.data[self.len] = val;
                self.len += 1;
            }
        } = .{},
    };

    var frame = MockFrame{};

    // PC=0: PUSH1 1 (condition)
    frame.stack.push(1);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // PC=2: PUSH1 6 (destination)
    frame.stack.push(6);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 4), tracker.pc);

    // PC=4: JUMPI - condition is true, should jump
    tracker.execute(&frame, 0x57);
    try testing.expectEqual(@as(u32, 6), tracker.pc); // Jumped to PC=6

    // PC=6: JUMPDEST
    tracker.execute(&frame, 0x5b);

    try testing.expectEqual(true, tracker.isValid());
}

test "PC tracker handles JUMPI with condition false" {
    const allocator = testing.allocator;
    _ = allocator;

    // Bytecode: PUSH1 0, PUSH1 6, JUMPI, STOP, STOP, JUMPDEST
    const bytecode = [_]u8{
        0x60, 0x00, // PUSH1 0 (condition = false)
        0x60, 0x06, // PUSH1 6 (destination)
        0x57,       // JUMPI
        0x00,       // STOP (should execute this)
        0x5b,       // JUMPDEST (at PC=6, skipped)
    };

    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = [_]u256{0} ** 10,
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }

            pub fn push(self: *@This(), val: u256) void {
                self.data[self.len] = val;
                self.len += 1;
            }
        } = .{},
    };

    var frame = MockFrame{};

    // PC=0: PUSH1 0 (condition = false)
    frame.stack.push(0);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // PC=2: PUSH1 6 (destination)
    frame.stack.push(6);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 4), tracker.pc);

    // PC=4: JUMPI - condition is false, should NOT jump
    tracker.execute(&frame, 0x57);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // Continued to next instruction

    // PC=5: STOP
    tracker.execute(&frame, 0x00);

    try testing.expectEqual(true, tracker.isValid());
}

test "PC tracker detects invalid jump destination" {
    const allocator = testing.allocator;
    _ = allocator;

    // Bytecode: PUSH1 4, JUMP, STOP, STOP (no JUMPDEST at PC=4)
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4 (invalid destination)
        0x56,       // JUMP
        0x00,       // STOP
        0x00,       // STOP (not a JUMPDEST)
    };

    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = [_]u256{0} ** 10,
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }

            pub fn push(self: *@This(), val: u256) void {
                self.data[self.len] = val;
                self.len += 1;
            }
        } = .{},
    };

    var frame = MockFrame{};

    // PC=0: PUSH1 4
    frame.stack.push(4);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // PC=2: JUMP to invalid destination (PC=4 is not JUMPDEST)
    tracker.execute(&frame, 0x56);

    // Tracker should detect invalid jump
    try testing.expectEqual(false, tracker.isValid());
}

test "PC tracker validates static jump patterns" {
    const allocator = testing.allocator;
    _ = allocator;

    // Bytecode with static jump: PUSH1 4, JUMP, STOP, JUMPDEST
    const bytecode = [_]u8{
        0x60, 0x04, // PUSH1 4
        0x56,       // JUMP
        0x00,       // STOP
        0x5b,       // JUMPDEST (at PC=4)
    };

    var tracker = pc_tracker_mod.PcTracker.init(&bytecode);

    // Should be able to validate static jump from PC=2 to PC=4
    try testing.expectEqual(true, tracker.validateStaticJump(2, 4));

    // Should fail for invalid static jump
    try testing.expectEqual(false, tracker.validateStaticJump(2, 3)); // PC=3 is not JUMPDEST
}