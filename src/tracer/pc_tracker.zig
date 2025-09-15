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

    /// Advance PC based on the current opcode
    fn advancePc(self: *PcTracker, frame: anytype, opcode: u8) void {
        // Handle different opcode categories
        switch (opcode) {
            // JUMP - unconditional jump
            0x56 => {
                // Read destination from stack (top element)
                const stack_size = frame.stack.size();
                if (stack_size == 0) {
                    log.err("PcTracker: JUMP with empty stack", .{});
                    self.valid = false;
                    return;
                }

                // Get jump destination from stack
                const dest = frame.stack.get_slice()[stack_size - 1];

                // Validate destination is within bounds
                if (dest > std.math.maxInt(u32)) {
                    log.err("PcTracker: JUMP destination out of range: 0x{x}", .{dest});
                    self.valid = false;
                    return;
                }

                const dest_pc = @as(u32, @intCast(dest));

                // Validate destination is a JUMPDEST
                if (dest_pc >= self.bytecode.len or self.bytecode[dest_pc] != 0x5b) {
                    log.err("PcTracker: JUMP to invalid destination PC={} (not JUMPDEST)", .{dest_pc});
                    self.valid = false;
                    return;
                }

                log.debug("PcTracker: JUMP from PC={} to PC={}", .{ self.pc, dest_pc });
                self.pc = dest_pc;
            },

            // JUMPI - conditional jump
            0x57 => {
                // Read destination and condition from stack
                const stack_size = frame.stack.size();
                if (stack_size < 2) {
                    log.err("PcTracker: JUMPI with insufficient stack", .{});
                    self.valid = false;
                    return;
                }

                const stack = frame.stack.get_slice();
                const dest = stack[stack_size - 1];
                const condition = stack[stack_size - 2];

                if (condition != 0) {
                    // Jump taken
                    if (dest > std.math.maxInt(u32)) {
                        log.err("PcTracker: JUMPI destination out of range: 0x{x}", .{dest});
                        self.valid = false;
                        return;
                    }

                    const dest_pc = @as(u32, @intCast(dest));

                    // Validate destination is a JUMPDEST
                    if (dest_pc >= self.bytecode.len or self.bytecode[dest_pc] != 0x5b) {
                        log.err("PcTracker: JUMPI to invalid destination PC={} (not JUMPDEST)", .{dest_pc});
                        self.valid = false;
                        return;
                    }

                    log.debug("PcTracker: JUMPI taken from PC={} to PC={}", .{ self.pc, dest_pc });
                    self.pc = dest_pc;
                } else {
                    // Jump not taken - continue to next instruction
                    log.debug("PcTracker: JUMPI not taken at PC={}", .{self.pc});
                    self.pc += 1;
                }
            },

            // PUSH instructions - skip the push data
            0x60...0x7f => {
                const push_size = opcode - 0x5f;
                const new_pc = self.pc + 1 + push_size;

                // Validate we have enough bytecode for the push data
                if (new_pc > self.bytecode.len) {
                    log.err("PcTracker: PUSH{} at PC={} exceeds bytecode length", .{ push_size, self.pc });
                    self.valid = false;
                    return;
                }

                // For static jumps (PUSH followed by JUMP/JUMPI), validate the destination
                if (new_pc < self.bytecode.len) {
                    const next_opcode = self.bytecode[new_pc];
                    if (next_opcode == 0x56 or next_opcode == 0x57) {
                        // This is a static jump - validate the pushed value
                        const push_data_start = self.pc + 1;
                        const push_data = self.bytecode[push_data_start..push_data_start + push_size];

                        // Convert push data to destination
                        var dest: u256 = 0;
                        for (push_data) |byte| {
                            dest = (dest << 8) | byte;
                        }

                        // Log static jump detection
                        if (dest <= std.math.maxInt(u32)) {
                            const dest_pc = @as(u32, @intCast(dest));
                            if (dest_pc < self.bytecode.len and self.bytecode[dest_pc] == 0x5b) {
                                log.debug("PcTracker: Detected static jump to PC={} after PUSH{}", .{ dest_pc, push_size });
                            } else {
                                log.warn("PcTracker: Static jump to invalid destination PC={} after PUSH{}", .{ dest_pc, push_size });
                            }
                        }
                    }
                }

                self.pc = new_pc;
            },

            // STOP, RETURN, REVERT, SELFDESTRUCT - execution terminates
            0x00, 0xf3, 0xfd, 0xff => {
                log.debug("PcTracker: Execution terminating at PC={} with {s}", .{
                    self.pc,
                    getOpcodeName(opcode)
                });
                // Don't advance PC as execution stops
            },

            // INVALID opcode
            0xfe => {
                log.err("PcTracker: INVALID opcode at PC={}", .{self.pc});
                self.valid = false;
            },

            // All other opcodes - advance by 1
            else => {
                self.pc += 1;
            },
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

/// Get opcode name for debugging
fn getOpcodeName(opcode: u8) []const u8 {
    return switch (opcode) {
        0x00 => "STOP",
        0x01 => "ADD",
        0x02 => "MUL",
        0x03 => "SUB",
        0x04 => "DIV",
        0x05 => "SDIV",
        0x06 => "MOD",
        0x07 => "SMOD",
        0x08 => "ADDMOD",
        0x09 => "MULMOD",
        0x0a => "EXP",
        0x0b => "SIGNEXTEND",
        0x10 => "LT",
        0x11 => "GT",
        0x12 => "SLT",
        0x13 => "SGT",
        0x14 => "EQ",
        0x15 => "ISZERO",
        0x16 => "AND",
        0x17 => "OR",
        0x18 => "XOR",
        0x19 => "NOT",
        0x1a => "BYTE",
        0x1b => "SHL",
        0x1c => "SHR",
        0x1d => "SAR",
        0x20 => "KECCAK256",
        0x30 => "ADDRESS",
        0x31 => "BALANCE",
        0x32 => "ORIGIN",
        0x33 => "CALLER",
        0x34 => "CALLVALUE",
        0x35 => "CALLDATALOAD",
        0x36 => "CALLDATASIZE",
        0x37 => "CALLDATACOPY",
        0x38 => "CODESIZE",
        0x39 => "CODECOPY",
        0x3a => "GASPRICE",
        0x3b => "EXTCODESIZE",
        0x3c => "EXTCODECOPY",
        0x3d => "RETURNDATASIZE",
        0x3e => "RETURNDATACOPY",
        0x3f => "EXTCODEHASH",
        0x40 => "BLOCKHASH",
        0x41 => "COINBASE",
        0x42 => "TIMESTAMP",
        0x43 => "NUMBER",
        0x44 => "DIFFICULTY",
        0x45 => "GASLIMIT",
        0x46 => "CHAINID",
        0x47 => "SELFBALANCE",
        0x48 => "BASEFEE",
        0x49 => "BLOBHASH",
        0x4a => "BLOBBASEFEE",
        0x50 => "POP",
        0x51 => "MLOAD",
        0x52 => "MSTORE",
        0x53 => "MSTORE8",
        0x54 => "SLOAD",
        0x55 => "SSTORE",
        0x56 => "JUMP",
        0x57 => "JUMPI",
        0x58 => "PC",
        0x59 => "MSIZE",
        0x5a => "GAS",
        0x5b => "JUMPDEST",
        0x5f => "PUSH0",
        0x60 => "PUSH1",
        0x61 => "PUSH2",
        0x62 => "PUSH3",
        0x63 => "PUSH4",
        0x64 => "PUSH5",
        0x65 => "PUSH6",
        0x66 => "PUSH7",
        0x67 => "PUSH8",
        0x68 => "PUSH9",
        0x69 => "PUSH10",
        0x6a => "PUSH11",
        0x6b => "PUSH12",
        0x6c => "PUSH13",
        0x6d => "PUSH14",
        0x6e => "PUSH15",
        0x6f => "PUSH16",
        0x70 => "PUSH17",
        0x71 => "PUSH18",
        0x72 => "PUSH19",
        0x73 => "PUSH20",
        0x74 => "PUSH21",
        0x75 => "PUSH22",
        0x76 => "PUSH23",
        0x77 => "PUSH24",
        0x78 => "PUSH25",
        0x79 => "PUSH26",
        0x7a => "PUSH27",
        0x7b => "PUSH28",
        0x7c => "PUSH29",
        0x7d => "PUSH30",
        0x7e => "PUSH31",
        0x7f => "PUSH32",
        0x80 => "DUP1",
        0x81 => "DUP2",
        0x82 => "DUP3",
        0x83 => "DUP4",
        0x84 => "DUP5",
        0x85 => "DUP6",
        0x86 => "DUP7",
        0x87 => "DUP8",
        0x88 => "DUP9",
        0x89 => "DUP10",
        0x8a => "DUP11",
        0x8b => "DUP12",
        0x8c => "DUP13",
        0x8d => "DUP14",
        0x8e => "DUP15",
        0x8f => "DUP16",
        0x90 => "SWAP1",
        0x91 => "SWAP2",
        0x92 => "SWAP3",
        0x93 => "SWAP4",
        0x94 => "SWAP5",
        0x95 => "SWAP6",
        0x96 => "SWAP7",
        0x97 => "SWAP8",
        0x98 => "SWAP9",
        0x99 => "SWAP10",
        0x9a => "SWAP11",
        0x9b => "SWAP12",
        0x9c => "SWAP13",
        0x9d => "SWAP14",
        0x9e => "SWAP15",
        0x9f => "SWAP16",
        0xa0 => "LOG0",
        0xa1 => "LOG1",
        0xa2 => "LOG2",
        0xa3 => "LOG3",
        0xa4 => "LOG4",
        0xf0 => "CREATE",
        0xf1 => "CALL",
        0xf2 => "CALLCODE",
        0xf3 => "RETURN",
        0xf4 => "DELEGATECALL",
        0xf5 => "CREATE2",
        0xfa => "STATICCALL",
        0xfd => "REVERT",
        0xfe => "INVALID",
        0xff => "SELFDESTRUCT",
        else => "UNKNOWN",
    };
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
            data: [10]u256 = [_]u256{0} ** 10,
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