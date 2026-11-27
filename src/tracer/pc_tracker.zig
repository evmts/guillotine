/// PC tracking mechanism for validating EVM execution flow
///
/// Tracks program counter independently of the tailcall-based execution
/// to validate that opcodes are executing in the expected order.
const std = @import("std");
const log = @import("../log.zig");
const opcodes = @import("../opcodes/opcode_data.zig");
const Opcode = opcodes.Opcode;

/// Independent PC tracker that validates execution flow
pub const PcTracker = struct {
    /// Current program counter
    pc: u32,
    /// The bytecode being executed
    bytecode: []const u8,
    /// Track if we're in a valid state
    valid: bool,
    /// Track last opcode for validation
    last_opcode: ?u8,

    /// Initialize a new PC tracker
    pub fn init(bytecode: []const u8) PcTracker {
        return .{
            .pc = 0,
            .bytecode = bytecode,
            .valid = true,
            .last_opcode = null,
        };
    }

    /// Reset the tracker for new execution
    pub fn reset(self: *PcTracker, bytecode: []const u8) void {
        self.pc = 0;
        self.bytecode = bytecode;
        self.valid = true;
        self.last_opcode = null;
    }

    /// Execute PC tracking for the current instruction
    /// Called from before_instruction in the tracer
    pub fn execute(self: *PcTracker, frame: anytype, opcode: u8) void {
        // Skip if we're already in an invalid state
        if (!self.valid) {
            return;
        }

        // Validate we're within bytecode bounds
        if (self.pc >= self.bytecode.len) {
            log.err("PcTracker: PC out of bounds: pc={} len={}", .{ self.pc, self.bytecode.len });
            self.valid = false;
            return;
        }

        // Get expected opcode at current PC
        const expected_opcode = self.bytecode[self.pc];

        // Validate opcode matches
        if (expected_opcode != opcode) {
            log.err("PcTracker: Opcode mismatch at PC {}: expected 0x{x:0>2} ({s}), got 0x{x:0>2} ({s})", .{
                self.pc,
                expected_opcode,
                getOpcodeName(expected_opcode),
                opcode,
                getOpcodeName(opcode),
            });
            self.valid = false;
            return;
        }

        log.debug("PcTracker: PC={} opcode=0x{x:0>2} ({s})", .{
            self.pc,
            opcode,
            getOpcodeName(opcode),
        });

        // Handle PC advancement based on opcode
        self.advancePc(frame, opcode);

        // Store last opcode
        self.last_opcode = opcode;
    }

    fn jumpToDestination(self: *PcTracker, dest: u256, comptime label: []const u8) void {
        if (dest > std.math.maxInt(u32)) {
            log.err("PcTracker: {s} destination out of range: 0x{x}", .{ label, dest });
            self.valid = false;
            return;
        }
        const dest_pc = @as(u32, @intCast(dest));
        if (dest_pc >= self.bytecode.len or self.bytecode[dest_pc] != 0x5b) {
            log.err("PcTracker: {s} to invalid destination PC={} (not JUMPDEST)", .{ label, dest_pc });
            self.valid = false;
            return;
        }
        log.debug("PcTracker: {s} from PC={} to PC={}", .{ label, self.pc, dest_pc });
        self.pc = dest_pc;
    }

    fn advancePush(self: *PcTracker, opcode: u8) void {
        const push_size = opcode - 0x5f;
        const new_pc = self.pc + 1 + push_size;
        if (new_pc > self.bytecode.len) {
            log.err("PcTracker: PUSH{} at PC={} exceeds bytecode length", .{ push_size, self.pc });
            self.valid = false;
            return;
        }
        if (new_pc < self.bytecode.len) {
            const next_opcode = self.bytecode[new_pc];
            if (next_opcode == 0x56 or next_opcode == 0x57) {
                const push_data = self.bytecode[self.pc + 1 .. self.pc + 1 + push_size];
                var dest: u256 = 0;
                for (push_data) |byte| dest = (dest << 8) | byte;
                if (dest <= std.math.maxInt(u32)) {
                    const dest_pc = @as(u32, @intCast(dest));
                    if (dest_pc < self.bytecode.len and self.bytecode[dest_pc] == 0x5b) {
                        log.debug(
                            "PcTracker: Detected static jump to PC={} after PUSH{}",
                            .{ dest_pc, push_size },
                        );
                    } else {
                        log.warn(
                            "PcTracker: Static jump to invalid destination PC={} after PUSH{}",
                            .{ dest_pc, push_size },
                        );
                    }
                }
            }
        }
        self.pc = new_pc;
    }

    /// Advance PC based on the current opcode
    fn advancePc(self: *PcTracker, frame: anytype, opcode: u8) void {
        switch (opcode) {
            0x56 => {
                const stack_size = frame.stack.size();
                if (stack_size == 0) {
                    log.err("PcTracker: JUMP with empty stack", .{});
                    self.valid = false;
                    return;
                }
                self.jumpToDestination(frame.stack.get_slice()[stack_size - 1], "JUMP");
            },
            0x57 => {
                const stack_size = frame.stack.size();
                if (stack_size < 2) {
                    log.err("PcTracker: JUMPI with insufficient stack", .{});
                    self.valid = false;
                    return;
                }
                const stack = frame.stack.get_slice();
                if (stack[stack_size - 2] != 0) {
                    self.jumpToDestination(stack[stack_size - 1], "JUMPI taken");
                } else {
                    log.debug("PcTracker: JUMPI not taken at PC={}", .{self.pc});
                    self.pc += 1;
                }
            },
            0x60...0x7f => self.advancePush(opcode),
            0x00, 0xf3, 0xfd, 0xff => {
                log.debug("PcTracker: Execution terminating at PC={} with {s}", .{ self.pc, getOpcodeName(opcode) });
            },
            0xfe => {
                log.err("PcTracker: INVALID opcode at PC={}", .{self.pc});
                self.valid = false;
            },
            else => self.pc += 1,
        }
    }

    /// Get current PC
    pub fn getPc(self: *const PcTracker) u32 {
        return self.pc;
    }

    /// Check if tracker is in valid state
    pub fn isValid(self: *const PcTracker) bool {
        return self.valid;
    }

    /// Validate a known static jump (for compile-time known jumps)
    pub fn validateStaticJump(self: *PcTracker, from_pc: u32, to_pc: u32) bool {
        if (self.pc != from_pc) {
            log.err("PcTracker: Static jump validation failed - current PC {} != expected {}", .{ self.pc, from_pc });
            return false;
        }

        if (to_pc >= self.bytecode.len) {
            log.err("PcTracker: Static jump destination {} out of bounds", .{to_pc});
            return false;
        }

        if (self.bytecode[to_pc] != 0x5b) {
            log.err("PcTracker: Static jump destination {} is not JUMPDEST", .{to_pc});
            return false;
        }

        log.debug("PcTracker: Validated static jump from {} to {}", .{ from_pc, to_pc });
        return true;
    }
};

const opcode_names: [256][]const u8 = blk: {
    var table: [256][]const u8 = @splat("UNKNOWN");
    for (@typeInfo(Opcode).@"enum".fields) |field| {
        table[field.value] = field.name;
    }
    break :blk table;
};

/// Get opcode name for debugging
fn getOpcodeName(opcode: u8) []const u8 {
    return opcode_names[opcode];
}

// Tests
const testing = std.testing;

test "PcTracker basic initialization" {
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP
    const tracker = PcTracker.init(&bytecode);

    try testing.expectEqual(@as(u32, 0), tracker.pc);
    try testing.expectEqual(true, tracker.valid);
    try testing.expectEqual(@as(?u8, null), tracker.last_opcode);
}

test "PcTracker simple execution" {
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x02, 0x01, 0x00 }; // PUSH1 1, PUSH1 2, ADD, STOP
    var tracker = PcTracker.init(&bytecode);

    // Mock frame with minimal stack implementation
    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = @as([10]u256, @splat(0)),
            len: usize = 0,

            pub fn size(self: *const @This()) usize {
                return self.len;
            }

            pub fn get_slice(self: *const @This()) []const u256 {
                return self.data[0..self.len];
            }
        } = .{},
    };

    var frame = MockFrame{};

    // Execute PUSH1 1
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc); // PC should advance by 2 (opcode + 1 byte)

    // Execute PUSH1 2
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 4), tracker.pc); // PC should advance by 2 more

    // Execute ADD
    tracker.execute(&frame, 0x01);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // PC should advance by 1

    // Execute STOP
    tracker.execute(&frame, 0x00);
    try testing.expectEqual(@as(u32, 5), tracker.pc); // PC should not advance (execution stops)

    try testing.expectEqual(true, tracker.valid);
}

test "PcTracker opcode mismatch detection" {
    const bytecode = [_]u8{ 0x60, 0x01, 0x02 }; // PUSH1 1, MUL
    var tracker = PcTracker.init(&bytecode);

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

    // Execute PUSH1 - correct
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(true, tracker.valid);

    // Execute with wrong opcode (0x01 ADD instead of 0x02 MUL)
    tracker.execute(&frame, 0x01);
    try testing.expectEqual(false, tracker.valid); // Should detect mismatch
}

test "PcTracker JUMP handling" {
    // PUSH1 5, JUMP, STOP, STOP, JUMPDEST
    const bytecode = [_]u8{ 0x60, 0x05, 0x56, 0x00, 0x00, 0x5b };
    var tracker = PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = @as([10]u256, @splat(0)),
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

    // Execute PUSH1 5
    frame.stack.push(5);
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // Execute JUMP - should jump to PC=5
    tracker.execute(&frame, 0x56);
    try testing.expectEqual(@as(u32, 5), tracker.pc);

    // Execute JUMPDEST
    tracker.execute(&frame, 0x5b);
    try testing.expectEqual(@as(u32, 6), tracker.pc);

    try testing.expectEqual(true, tracker.valid);
}

test "PcTracker JUMPI conditional" {
    // PUSH1 1, PUSH1 6, JUMPI, STOP, STOP, JUMPDEST
    const bytecode = [_]u8{ 0x60, 0x01, 0x60, 0x06, 0x57, 0x00, 0x5b };
    var tracker = PcTracker.init(&bytecode);

    const MockFrame = struct {
        stack: struct {
            data: [10]u256 = @as([10]u256, @splat(0)),
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

    // Test jump taken
    frame.stack.push(1); // condition (true)
    tracker.execute(&frame, 0x60); // PUSH1 1
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    frame.stack.push(6); // destination
    tracker.execute(&frame, 0x60); // PUSH1 6
    try testing.expectEqual(@as(u32, 4), tracker.pc);

    tracker.execute(&frame, 0x57); // JUMPI - should jump
    try testing.expectEqual(@as(u32, 6), tracker.pc);

    // Reset for jump not taken test
    tracker.reset(&bytecode);
    frame = MockFrame{};

    frame.stack.push(0); // condition (false)
    tracker.execute(&frame, 0x60); // PUSH1 0

    frame.stack.push(6); // destination
    tracker.execute(&frame, 0x60); // PUSH1 6

    tracker.execute(&frame, 0x57); // JUMPI - should not jump
    try testing.expectEqual(@as(u32, 5), tracker.pc); // Should continue to next instruction
}

test "PcTracker static jump detection" {
    // PUSH1 4, JUMP, STOP, JUMPDEST
    const bytecode = [_]u8{ 0x60, 0x04, 0x56, 0x00, 0x5b };
    var tracker = PcTracker.init(&bytecode);

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

    // Execute PUSH1 4 - should detect static jump pattern
    tracker.execute(&frame, 0x60);
    try testing.expectEqual(@as(u32, 2), tracker.pc);

    // Validate static jump
    try testing.expectEqual(true, tracker.validateStaticJump(2, 4));
}
