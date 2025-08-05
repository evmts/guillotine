const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const StackValidation = @import("../stack/stack_validation.zig");

// Additional imports for fuzz tests
const Vm = @import("../evm.zig");
const MemoryDatabase = @import("../state/memory_database.zig");
const Contract = @import("../frame/contract.zig");
const Address = @import("primitives").Address;

pub fn op_pop(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    _ = try frame.stack.pop();

    return Operation.ExecutionResult{};
}

pub fn op_push0(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Compile-time validation: PUSH0 pops 0 items, pushes 1
    // This ensures at build time that PUSH0 has valid stack effects for EVM
    try StackValidation.validateStackRequirements(0, 1, frame.stack.size);

    frame.stack.append_unsafe(0);

    return Operation.ExecutionResult{};
}

// Optimized PUSH1 implementation with direct byte access
pub fn op_push1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = state;

    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }

    const code = frame.contract.code;
    const value: u256 = if (pc + 1 < code.len) code[pc + 1] else 0;

    frame.stack.append_unsafe(value);

    return Operation.ExecutionResult{ .bytes_consumed = 2 };
}

// Optimized PUSH2-PUSH8 implementations using u64 arithmetic
pub fn make_push_small(comptime n: u8) fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn push(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = interpreter;

            const frame = state;

            if (frame.stack.size >= Stack.CAPACITY) {
                @branchHint(.cold);
                unreachable;
            }

            const code = frame.contract.code;
            const start = pc + 1;
            
            // Optimized path using std.mem.readInt for direct big-endian reads
            const value = switch (n) {
                1 => blk: {
                    if (start < code.len) {
                        break :blk @as(u64, code[start]);
                    } else {
                        break :blk @as(u64, 0);
                    }
                },
                2 => blk: {
                    if (start + 1 < code.len) {
                        break :blk @as(u64, std.mem.readInt(u16, code[start..][0..2], .big));
                    } else if (start < code.len) {
                        break :blk @as(u64, code[start]) << 8;
                    } else {
                        break :blk @as(u64, 0);
                    }
                },
                3 => blk: {
                    if (start + 2 < code.len) {
                        var buf: [4]u8 = .{0} ** 4;
                        @memcpy(buf[1..4], code[start..start + 3]);
                        break :blk @as(u64, std.mem.readInt(u32, &buf, .big));
                    } else {
                        // Fallback to byte-by-byte for partial reads
                        var v: u64 = 0;
                        for (0..n) |i| {
                            if (start + i < code.len) {
                                v = (v << 8) | code[start + i];
                            } else {
                                v = v << 8;
                            }
                        }
                        break :blk v;
                    }
                },
                4 => blk: {
                    if (start + 3 < code.len) {
                        break :blk @as(u64, std.mem.readInt(u32, code[start..][0..4], .big));
                    } else {
                        // Fallback to byte-by-byte for partial reads
                        var v: u64 = 0;
                        for (0..n) |i| {
                            if (start + i < code.len) {
                                v = (v << 8) | code[start + i];
                            } else {
                                v = v << 8;
                            }
                        }
                        break :blk v;
                    }
                },
                5, 6, 7 => blk: {
                    if (start + n - 1 < code.len) {
                        var buf: [8]u8 = .{0} ** 8;
                        @memcpy(buf[8 - n..], code[start..start + n]);
                        break :blk std.mem.readInt(u64, &buf, .big);
                    } else {
                        // Fallback to byte-by-byte for partial reads
                        var v: u64 = 0;
                        for (0..n) |i| {
                            if (start + i < code.len) {
                                v = (v << 8) | code[start + i];
                            } else {
                                v = v << 8;
                            }
                        }
                        break :blk v;
                    }
                },
                8 => blk: {
                    if (start + 7 < code.len) {
                        break :blk std.mem.readInt(u64, code[start..][0..8], .big);
                    } else {
                        // Fallback to byte-by-byte for partial reads
                        var v: u64 = 0;
                        for (0..n) |i| {
                            if (start + i < code.len) {
                                v = (v << 8) | code[start + i];
                            } else {
                                v = v << 8;
                            }
                        }
                        break :blk v;
                    }
                },
                else => unreachable,
            };

            frame.stack.append_unsafe(@as(u256, value));

            return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
        }
    }.push;
}

// Generate push operations for PUSH1 through PUSH32
pub fn make_push(comptime n: u8) fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn push(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = interpreter;

            const frame = state;

            if (frame.stack.size >= Stack.CAPACITY) {
                unreachable;
            }
            
            const code = frame.contract.code;
            const start = pc + 1;
            
            // Optimized implementation using buffer-based loading
            var value: u256 = 0;
            
            if (start + n - 1 < code.len) {
                // Fast path: All bytes are available, use optimized loading
                if (n <= 16) {
                    // For PUSH9-PUSH16, load into two u64s
                    var high: u64 = 0;
                    var low: u64 = 0;
                    
                    if (n > 8) {
                        // Read high bytes (up to 8 bytes)
                        const high_bytes = n - 8;
                        var buf_high: [8]u8 = .{0} ** 8;
                        @memcpy(buf_high[8 - high_bytes..], code[start..start + high_bytes]);
                        high = std.mem.readInt(u64, &buf_high, .big);
                        
                        // Read low 8 bytes
                        low = std.mem.readInt(u64, code[start + high_bytes..][0..8], .big);
                    } else {
                        // n <= 8, use existing optimization from make_push_small
                        var buf: [8]u8 = .{0} ** 8;
                        @memcpy(buf[8 - n..], code[start..start + n]);
                        low = std.mem.readInt(u64, &buf, .big);
                    }
                    
                    value = (@as(u256, high) << 64) | @as(u256, low);
                } else {
                    // For PUSH17-PUSH32, use a 32-byte buffer
                    var buf: [32]u8 = .{0} ** 32;
                    @memcpy(buf[32 - n..], code[start..start + n]);
                    
                    // Read as four u64 values
                    const q1 = std.mem.readInt(u64, buf[0..8], .big);
                    const q2 = std.mem.readInt(u64, buf[8..16], .big);
                    const q3 = std.mem.readInt(u64, buf[16..24], .big);
                    const q4 = std.mem.readInt(u64, buf[24..32], .big);
                    
                    value = (@as(u256, q1) << 192) | (@as(u256, q2) << 128) | 
                            (@as(u256, q3) << 64) | @as(u256, q4);
                }
            } else {
                // Slow path: Partial read at end of code, fall back to byte-by-byte
                for (0..n) |i| {
                    if (start + i < code.len) {
                        value = (value << 8) | code[start + i];
                    } else {
                        value = value << 8;
                    }
                }
            }

            frame.stack.append_unsafe(value);

            // PUSH operations consume 1 + n bytes
            // (1 for the opcode itself, n for the immediate data)
            return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
        }
    }.push;
}

// Runtime dispatch version for PUSH operations (used in ReleaseSmall mode)
pub fn push_n(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = state;

    // Bounds check for opcode access
    if (pc >= frame.contract.code.len) {
        return ExecutionError.Error.InvalidOpcode;
    }

    const opcode = frame.contract.code[pc];

    // Validate this is actually a PUSH1-PUSH32 opcode (0x60-0x7F)
    if (opcode < 0x60 or opcode > 0x7F) {
        return ExecutionError.Error.InvalidOpcode;
    }

    const n = opcode - 0x5f; // PUSH1 is 0x60, so n = opcode - 0x5f

    // Stack overflow check
    if (frame.stack.size >= Stack.CAPACITY) {
        return ExecutionError.Error.StackOverflow;
    }

    const code = frame.contract.code;
    const start = pc + 1;
    
    // Optimized implementation using buffer-based loading
    var value: u256 = 0;
    
    if (start + n - 1 < code.len) {
        // Fast path: All bytes are available
        if (n <= 8) {
            // For PUSH1-PUSH8, use optimized u64 loading
            var buf: [8]u8 = .{0} ** 8;
            @memcpy(buf[8 - n..], code[start..start + n]);
            value = std.mem.readInt(u64, &buf, .big);
        } else if (n <= 16) {
            // For PUSH9-PUSH16, load into two u64s
            const high_bytes = n - 8;
            var buf_high: [8]u8 = .{0} ** 8;
            @memcpy(buf_high[8 - high_bytes..], code[start..start + high_bytes]);
            const high = std.mem.readInt(u64, &buf_high, .big);
            const low = std.mem.readInt(u64, code[start + high_bytes..][0..8], .big);
            value = (@as(u256, high) << 64) | @as(u256, low);
        } else {
            // For PUSH17-PUSH32, use a 32-byte buffer
            var buf: [32]u8 = .{0} ** 32;
            @memcpy(buf[32 - n..], code[start..start + n]);
            
            // Read as four u64 values
            const q1 = std.mem.readInt(u64, buf[0..8], .big);
            const q2 = std.mem.readInt(u64, buf[8..16], .big);
            const q3 = std.mem.readInt(u64, buf[16..24], .big);
            const q4 = std.mem.readInt(u64, buf[24..32], .big);
            
            value = (@as(u256, q1) << 192) | (@as(u256, q2) << 128) | 
                    (@as(u256, q3) << 64) | @as(u256, q4);
        }
    } else {
        // Slow path: Partial read at end of code
        for (0..n) |i| {
            if (start + i < code.len) {
                value = (value << 8) | code[start + i];
            } else {
                value = value << 8;
            }
        }
    }

    frame.stack.append_unsafe(value);

    return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
}

// PUSH operations are now generated directly in jump_table.zig using make_push()

// Generate dup operations
pub fn make_dup(comptime n: u8) fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn dup(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;
            _ = interpreter;

            const frame = state;

            // Compile-time validation: DUP operations pop 0 items, push 1
            // At compile time, this validates that DUP has valid EVM stack effects
            // At runtime, this ensures sufficient stack depth for DUPn operations
            try StackValidation.validateStackRequirements(0, 1, frame.stack.size);

            // Additional runtime check for DUP depth (n must be available on stack)
            if (frame.stack.size < n) {
                @branchHint(.cold);
                return ExecutionError.Error.StackUnderflow;
            }

            frame.stack.dup_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.dup;
}

// Runtime dispatch versions for DUP operations (used in ReleaseSmall mode)
// Each DUP operation gets its own function to avoid opcode detection issues

pub fn dup_1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(1, state);
}

pub fn dup_2(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(2, state);
}

pub fn dup_3(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(3, state);
}

pub fn dup_4(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(4, state);
}

pub fn dup_5(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(5, state);
}

pub fn dup_6(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(6, state);
}

pub fn dup_7(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(7, state);
}

pub fn dup_8(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(8, state);
}

pub fn dup_9(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(9, state);
}

pub fn dup_10(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(10, state);
}

pub fn dup_11(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(11, state);
}

pub fn dup_12(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(12, state);
}

pub fn dup_13(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(13, state);
}

pub fn dup_14(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(14, state);
}

pub fn dup_15(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(15, state);
}

pub fn dup_16(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl(16, state);
}

// Common implementation for all DUP operations
fn dup_impl(n: u8, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;

    // Validate stack requirements
    try StackValidation.validateStackRequirements(0, 1, frame.stack.size);

    // Additional runtime check for DUP depth (n must be available on stack)
    if (frame.stack.size < n) {
        @branchHint(.cold);
        return ExecutionError.Error.StackUnderflow;
    }

    frame.stack.dup_unsafe(n);
    return Operation.ExecutionResult{};
}

// DUP operations are now generated directly in jump_table.zig using make_dup()

// Generate swap operations
pub fn make_swap(comptime n: u8) fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn swap(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;
            _ = interpreter;

            const frame = state;

            if (frame.stack.size < n + 1) {
                unreachable;
            }
            frame.stack.swap_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.swap;
}

// Runtime dispatch versions for SWAP operations (used in ReleaseSmall mode)
// Each SWAP operation gets its own function to avoid opcode detection issues

pub fn swap_1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(1, state);
}

pub fn swap_2(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(2, state);
}

pub fn swap_3(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(3, state);
}

pub fn swap_4(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(4, state);
}

pub fn swap_5(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(5, state);
}

pub fn swap_6(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(6, state);
}

pub fn swap_7(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(7, state);
}

pub fn swap_8(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(8, state);
}

pub fn swap_9(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(9, state);
}

pub fn swap_10(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(10, state);
}

pub fn swap_11(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(11, state);
}

pub fn swap_12(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(12, state);
}

pub fn swap_13(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(13, state);
}

pub fn swap_14(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(14, state);
}

pub fn swap_15(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(15, state);
}

pub fn swap_16(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl(16, state);
}

// Common implementation for all SWAP operations
fn swap_impl(n: u8, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;

    // Stack underflow check - SWAP needs n+1 items
    if (frame.stack.size < n + 1) {
        return ExecutionError.Error.StackUnderflow;
    }

    frame.stack.swap_unsafe(n);
    return Operation.ExecutionResult{};
}

// SWAP operations are now generated directly in jump_table.zig using make_swap()

test "optimized PUSH1 handles value correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test with PUSH1 0xFF
    const code = [_]u8{ 0x60, 0xFF };
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const result = try op_push1(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_consumed);

    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), value);
}

test "optimized PUSH1 handles bytecode boundary" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test with PUSH1 at end of bytecode (no value byte)
    const code = [_]u8{0x60};
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const result = try op_push1(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_consumed);

    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), value);
}

test "optimized PUSH2-PUSH8 handle values correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test PUSH2 with 0x1234
    const code2 = [_]u8{ 0x61, 0x12, 0x34 };
    var contract2 = try Contract.init(allocator, &code2, .{ .address = primitives.Address.ZERO });
    defer contract2.deinit(allocator, null);

    var frame2 = try Frame.init(allocator, &vm, 1000000, contract2, primitives.Address.ZERO, &.{});
    defer frame2.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr2: Operation.State = @ptrCast(&frame2);

    const push2_fn = make_push_small(2);
    const result2 = try push2_fn(0, interpreter_ptr, state_ptr2);
    try std.testing.expectEqual(@as(usize, 3), result2.bytes_consumed);

    const value2 = try frame2.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x1234), value2);

    // Test PUSH8 with max u64 value
    const code8 = [_]u8{ 0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var contract8 = try Contract.init(allocator, &code8, .{ .address = primitives.Address.ZERO });
    defer contract8.deinit(allocator, null);

    var frame8 = try Frame.init(allocator, &vm, 1000000, contract8, primitives.Address.ZERO, &.{});
    defer frame8.deinit();

    const state_ptr8: Operation.State = @ptrCast(&frame8);

    const push8_fn = make_push_small(8);
    const result8 = try push8_fn(0, interpreter_ptr, state_ptr8);
    try std.testing.expectEqual(@as(usize, 9), result8.bytes_consumed);

    const value8 = try frame8.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), value8);
}

test "optimized PUSH handles partial bytecode correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test PUSH4 with only 2 bytes available
    const code = [_]u8{ 0x63, 0x12, 0x34 };
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const push4_fn = make_push_small(4);
    const result = try push4_fn(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 5), result.bytes_consumed);

    const value = try frame.stack.pop();
    // Should be 0x12340000 (padded with zeros)
    try std.testing.expectEqual(@as(u256, 0x12340000), value);
}

// ============================================================================
// POP Operation Tests
// ============================================================================

test "POP removes top stack element" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x50}; // POP opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Push some values first
    try frame.stack.append(100);
    try frame.stack.append(200);
    try frame.stack.append(300);

    try std.testing.expectEqual(@as(usize, 3), frame.stack.size);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const result = try op_pop(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_consumed);

    // Stack should have 2 elements, top value should be 200
    try std.testing.expectEqual(@as(usize, 2), frame.stack.size);
    try std.testing.expectEqual(@as(u256, 200), try frame.stack.peek());
}

test "POP discards value correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x50}; // POP opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Push a large value
    const large_value: u256 = std.math.maxInt(u256);
    try frame.stack.append(large_value);
    try frame.stack.append(42);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    _ = try op_pop(0, interpreter_ptr, state_ptr);

    // Should have popped 42, leaving large_value on top
    try std.testing.expectEqual(@as(u256, large_value), try frame.stack.peek());
}

test "multiple POP operations in sequence" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x50}; // POP opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Fill stack with known values
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        try frame.stack.append(i);
    }

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Pop 5 values
    i = 0;
    while (i < 5) : (i += 1) {
        _ = try op_pop(0, interpreter_ptr, state_ptr);
    }

    // Should have 5 elements left, top should be 4
    try std.testing.expectEqual(@as(usize, 5), frame.stack.size);
    try std.testing.expectEqual(@as(u256, 4), try frame.stack.peek());
}

// ============================================================================
// PUSH0 Operation Tests
// ============================================================================

test "PUSH0 pushes zero value" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x5f}; // PUSH0 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    try std.testing.expectEqual(@as(usize, 0), frame.stack.size);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const result = try op_push0(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_consumed);

    try std.testing.expectEqual(@as(usize, 1), frame.stack.size);
    try std.testing.expectEqual(@as(u256, 0), try frame.stack.pop());
}

test "PUSH0 multiple times" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x5f}; // PUSH0 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Push 5 zeros
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        _ = try op_push0(0, interpreter_ptr, state_ptr);
    }

    try std.testing.expectEqual(@as(usize, 5), frame.stack.size);

    // Verify all are zeros
    i = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expectEqual(@as(u256, 0), try frame.stack.pop());
    }
}

test "PUSH0 mixed with other values" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x5f}; // PUSH0 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Push non-zero value
    try frame.stack.append(42);

    // Push zero via PUSH0
    _ = try op_push0(0, interpreter_ptr, state_ptr);

    // Push another non-zero value
    try frame.stack.append(100);

    try std.testing.expectEqual(@as(usize, 3), frame.stack.size);

    // Check values in order (LIFO)
    try std.testing.expectEqual(@as(u256, 100), try frame.stack.pop());
    try std.testing.expectEqual(@as(u256, 0), try frame.stack.pop());
    try std.testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "PUSH0 performance vs manual zero push" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x5f}; // PUSH0 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const Timer = std.time.Timer;
    var timer = try Timer.start();

    // Time PUSH0 operations
    timer.reset();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try op_push0(0, interpreter_ptr, state_ptr);
        if (frame.stack.size >= 500) {
            frame.stack.size = 0;
        }
    }
    const push0_time = timer.read();

    // Time manual zero pushes for comparison
    frame.stack.clear();
    timer.reset();
    i = 0;
    while (i < 1000) : (i += 1) {
        try frame.stack.append(0);
        if (frame.stack.size >= 500) {
            frame.stack.size = 0;
        }
    }
    const manual_time = timer.read();

    // Both should complete in reasonable time
    try std.testing.expect(push0_time > 0);
    try std.testing.expect(manual_time > 0);
}

// ============================================================================
// PUSH1-PUSH32 Operation Tests
// ============================================================================

test "PUSH operations handle all sizes correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test PUSH1 through PUSH32 with incrementing values
    const test_cases = [_]struct { n: u8, expected: u256, bytes: []const u8 }{
        .{ .n = 1, .expected = 0x01, .bytes = &[_]u8{ 0x60, 0x01 } },
        .{ .n = 2, .expected = 0x0102, .bytes = &[_]u8{ 0x61, 0x01, 0x02 } },
        .{ .n = 3, .expected = 0x010203, .bytes = &[_]u8{ 0x62, 0x01, 0x02, 0x03 } },
        .{ .n = 4, .expected = 0x01020304, .bytes = &[_]u8{ 0x63, 0x01, 0x02, 0x03, 0x04 } },
        .{ .n = 8, .expected = 0x0102030405060708, .bytes = &[_]u8{ 0x67, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 } },
    };

    for (test_cases) |case| {
        var contract = try Contract.init(allocator, case.bytes, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        if (case.n <= 8) {
            const push_fn = make_push_small(case.n);
            const result = try push_fn(0, interpreter_ptr, state_ptr);
            try std.testing.expectEqual(@as(usize, 1 + case.n), result.bytes_consumed);
        } else {
            const push_fn = make_push(case.n);
            const result = try push_fn(0, interpreter_ptr, state_ptr);
            try std.testing.expectEqual(@as(usize, 1 + case.n), result.bytes_consumed);
        }

        const value = try frame.stack.pop();
        try std.testing.expectEqual(case.expected, value);
    }
}

test "PUSH32 handles maximum value" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Create bytecode for PUSH32 with all 0xFF bytes
    var code: [33]u8 = undefined;
    code[0] = 0x7f; // PUSH32 opcode
    @memset(code[1..], 0xFF);

    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const push32_fn = make_push(32);
    const result = try push32_fn(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 33), result.bytes_consumed);

    const value = try frame.stack.pop();
    try std.testing.expectEqual(std.math.maxInt(u256), value);
}

test "PUSH operations with insufficient bytecode" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test cases: PUSH operations with missing bytes
    const test_cases = [_]struct {
        opcode: u8,
        expected_size: usize,
        code: []const u8,
        expected_value: u256,
        push_n: u8,
    }{
        .{ .opcode = 0x61, .expected_size = 3, .code = &[_]u8{0x61}, .expected_value = 0, .push_n = 2 }, // PUSH2 with no data
        .{ .opcode = 0x61, .expected_size = 3, .code = &[_]u8{ 0x61, 0x12 }, .expected_value = 0x1200, .push_n = 2 }, // PUSH2 with 1 byte
        .{ .opcode = 0x64, .expected_size = 6, .code = &[_]u8{ 0x64, 0x12, 0x34 }, .expected_value = 0x123400000000, .push_n = 5 }, // PUSH5 with 2 bytes
    };

    for (test_cases) |case| {
        var contract = try Contract.init(allocator, case.code, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        if (case.push_n <= 8) {
            const push_fn = make_push_small(case.push_n);
            const result = try push_fn(0, interpreter_ptr, state_ptr);
            try std.testing.expectEqual(case.expected_size, result.bytes_consumed);
        } else {
            const push_fn = make_push(case.push_n);
            const result = try push_fn(0, interpreter_ptr, state_ptr);
            try std.testing.expectEqual(case.expected_size, result.bytes_consumed);
        }

        const value = try frame.stack.pop();
        try std.testing.expectEqual(case.expected_value, value);
    }
}

test "PUSH operations comparison small vs general" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test that small and general implementations produce same results for PUSH2-PUSH8
    const test_values = [_]struct { n: u8, bytes: []const u8, expected: u256 }{
        .{ .n = 2, .bytes = &[_]u8{ 0x61, 0x12, 0x34 }, .expected = 0x1234 },
        .{ .n = 3, .bytes = &[_]u8{ 0x62, 0xAB, 0xCD, 0xEF }, .expected = 0xABCDEF },
        .{ .n = 4, .bytes = &[_]u8{ 0x63, 0x11, 0x22, 0x33, 0x44 }, .expected = 0x11223344 },
        .{ .n = 8, .bytes = &[_]u8{ 0x67, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 }, .expected = 0x0102030405060708 },
    };

    for (test_values) |test_val| {
        // Test small implementation
        var contract_small = try Contract.init(allocator, test_val.bytes, .{ .address = primitives.Address.ZERO });
        defer contract_small.deinit(allocator, null);

        var frame_small = try Frame.init(allocator, &vm, 1000000, contract_small, primitives.Address.ZERO, &.{});
        defer frame_small.deinit();

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr_small: Operation.State = @ptrCast(&frame_small);

        const push_small_fn = make_push_small(test_val.n);
        const result_small = try push_small_fn(0, interpreter_ptr, state_ptr_small);
        const value_small = try frame_small.stack.pop();

        // Test general implementation
        var contract_general = try Contract.init(allocator, test_val.bytes, .{ .address = primitives.Address.ZERO });
        defer contract_general.deinit(allocator, null);

        var frame_general = try Frame.init(allocator, &vm, 1000000, contract_general, primitives.Address.ZERO, &.{});
        defer frame_general.deinit();

        const state_ptr_general: Operation.State = @ptrCast(&frame_general);

        const push_general_fn = make_push(test_val.n);
        const result_general = try push_general_fn(0, interpreter_ptr, state_ptr_general);
        const value_general = try frame_general.stack.pop();

        // Both should produce identical results
        try std.testing.expectEqual(result_small.bytes_consumed, result_general.bytes_consumed);
        try std.testing.expectEqual(value_small, value_general);
        try std.testing.expectEqual(test_val.expected, value_small);
        try std.testing.expectEqual(test_val.expected, value_general);
    }
}

test "PUSH extreme values and edge cases" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    // Test edge values for different PUSH sizes
    const edge_cases = [_]struct { name: []const u8, n: u8, code: []const u8, expected: u256 }{
        .{ .name = "PUSH1 max", .n = 1, .code = &[_]u8{ 0x60, 0xFF }, .expected = 0xFF },
        .{ .name = "PUSH2 max", .n = 2, .code = &[_]u8{ 0x61, 0xFF, 0xFF }, .expected = 0xFFFF },
        .{ .name = "PUSH4 max", .n = 4, .code = &[_]u8{ 0x63, 0xFF, 0xFF, 0xFF, 0xFF }, .expected = 0xFFFFFFFF },
        .{ .name = "PUSH8 max", .n = 8, .code = &[_]u8{ 0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, .expected = 0xFFFFFFFFFFFFFFFF },
        .{ .name = "PUSH16 alternating", .n = 16, .code = &[_]u8{ 0x6f, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0x00 }, .expected = 0xAABBCCDDEEFF112233445566778899000 },
    };

    for (edge_cases) |case| {
        var contract = try Contract.init(allocator, case.code, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        if (case.n <= 8) {
            const push_fn = make_push_small(case.n);
            _ = try push_fn(0, interpreter_ptr, state_ptr);
        } else {
            const push_fn = make_push(case.n);
            _ = try push_fn(0, interpreter_ptr, state_ptr);
        }

        const value = try frame.stack.pop();
        try std.testing.expectEqual(case.expected, value);
    }
}
// ============================================================================
// DUP1-DUP16 Operation Tests
// ============================================================================

test "DUP1 duplicates top stack element" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x80}; // DUP1 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Push a value to duplicate
    try frame.stack.append(42);
    try std.testing.expectEqual(@as(usize, 1), frame.stack.size);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const dup1_fn = make_dup(1);
    const result = try dup1_fn(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_consumed);

    // Should have 2 elements, both 42
    try std.testing.expectEqual(@as(usize, 2), frame.stack.size);
    try std.testing.expectEqual(@as(u256, 42), try frame.stack.pop());
    try std.testing.expectEqual(@as(u256, 42), try frame.stack.pop());
}

test "DUP operations all variants" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x80}; // DUP1 opcode (placeholder)
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Test DUP1 through DUP16
    var n: u8 = 1;
    while (n <= 16) : (n += 1) {
        frame.stack.clear();

        // Push n+5 values so we have enough to duplicate from position n
        var i: usize = 0;
        while (i < n + 5) : (i += 1) {
            try frame.stack.append(@as(u256, i + 100));
        }

        const original_size = frame.stack.size;
        const value_to_dup = try frame.stack.peek_n(n - 1);

        const dup_fn = make_dup(n);
        _ = try dup_fn(0, interpreter_ptr, state_ptr);

        // Should have one more element
        try std.testing.expectEqual(original_size + 1, frame.stack.size);

        // Top element should be the duplicated value
        const top_value = try frame.stack.pop();
        try std.testing.expectEqual(value_to_dup, top_value);
    }
}

test "DUP16 duplicates 16th element correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x8f}; // DUP16 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Push 20 values
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try frame.stack.append(@as(u256, i * 10));
    }

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // The 16th element from top (index 15 from top, which is value at index 4 from bottom)
    const expected_value: u256 = 40; // i=4, value=4*10=40

    const dup16_fn = make_dup(16);
    _ = try dup16_fn(0, interpreter_ptr, state_ptr);

    try std.testing.expectEqual(@as(usize, 21), frame.stack.size);
    try std.testing.expectEqual(expected_value, try frame.stack.pop());
}

test "DUP operations with edge values" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x80}; // DUP1 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const edge_values = [_]u256{
        0,
        1,
        std.math.maxInt(u8),
        std.math.maxInt(u16),
        std.math.maxInt(u32),
        std.math.maxInt(u64),
        std.math.maxInt(u128),
        std.math.maxInt(u256),
        1 << 128,
        (1 << 255),
    };

    for (edge_values) |value| {
        frame.stack.clear();
        try frame.stack.append(value);

        const dup1_fn = make_dup(1);
        _ = try dup1_fn(0, interpreter_ptr, state_ptr);

        try std.testing.expectEqual(@as(usize, 2), frame.stack.size);
        try std.testing.expectEqual(value, try frame.stack.pop());
        try std.testing.expectEqual(value, try frame.stack.pop());
    }
} // ============================================================================
// SWAP1-SWAP16 Operation Tests
// ============================================================================

test "SWAP1 swaps top two elements" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x90}; // SWAP1 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    try frame.stack.append(100);
    try frame.stack.append(200);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const swap1_fn = make_swap(1);
    const result = try swap1_fn(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 0), result.bytes_consumed);

    try std.testing.expectEqual(@as(u256, 100), try frame.stack.pop());
    try std.testing.expectEqual(@as(u256, 200), try frame.stack.pop());
}

test "SWAP operations all variants" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x90}; // SWAP1 opcode (placeholder)
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Test SWAP1 through SWAP16
    var n: u8 = 1;
    while (n <= 16) : (n += 1) {
        frame.stack.clear();

        // Push n+5 values so we have enough to swap with position n+1
        var i: usize = 0;
        while (i < n + 5) : (i += 1) {
            try frame.stack.append(@as(u256, i + 100));
        }

        const top_value = try frame.stack.peek_n(0);
        const target_value = try frame.stack.peek_n(n);

        const swap_fn = make_swap(n);
        _ = try swap_fn(0, interpreter_ptr, state_ptr);

        try std.testing.expectEqual(target_value, try frame.stack.peek_n(0));
        try std.testing.expectEqual(top_value, try frame.stack.peek_n(n));
    }
}

test "SWAP16 swaps correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x9f}; // SWAP16 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Push 20 values
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try frame.stack.append(@as(u256, i * 10));
    }

    const top_value = try frame.stack.peek_n(0);
    const target_value = try frame.stack.peek_n(16);

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    const swap16_fn = make_swap(16);
    _ = try swap16_fn(0, interpreter_ptr, state_ptr);

    try std.testing.expectEqual(target_value, try frame.stack.peek_n(0));
    try std.testing.expectEqual(top_value, try frame.stack.peek_n(16));
}

// ============================================================================
// Runtime Dispatch Tests (push_n, dup_n, swap_n)
// ============================================================================

test "runtime push_n handles all PUSH opcodes" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const test_cases = [_]struct { opcode: u8, n: u8, bytes: []const u8, expected: u256 }{
        .{ .opcode = 0x60, .n = 1, .bytes = &[_]u8{ 0x60, 0x42 }, .expected = 0x42 },
        .{ .opcode = 0x61, .n = 2, .bytes = &[_]u8{ 0x61, 0x12, 0x34 }, .expected = 0x1234 },
        .{ .opcode = 0x64, .n = 5, .bytes = &[_]u8{ 0x64, 0x01, 0x02, 0x03, 0x04, 0x05 }, .expected = 0x0102030405 },
    };

    for (test_cases) |case| {
        var contract = try Contract.init(allocator, case.bytes, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        const result = try push_n(0, interpreter_ptr, state_ptr);
        try std.testing.expectEqual(@as(usize, 1 + case.n), result.bytes_consumed);

        const value = try frame.stack.pop();
        try std.testing.expectEqual(case.expected, value);
    }
}

test "specific dup functions handle all DUP operations" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const test_cases = [_]struct { n: u8, func: fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult }{
        .{ .n = 1, .func = dup_1 },
        .{ .n = 2, .func = dup_2 },
        .{ .n = 16, .func = dup_16 },
    };

    for (test_cases) |case| {
        var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        // Push enough values
        var i: usize = 0;
        while (i < case.n + 5) : (i += 1) {
            try frame.stack.append(@as(u256, i + 100));
        }

        const original_size = frame.stack.size;
        const value_to_dup = try frame.stack.peek_n(case.n - 1);

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        _ = try case.func(0, interpreter_ptr, state_ptr);

        try std.testing.expectEqual(original_size + 1, frame.stack.size);
        try std.testing.expectEqual(value_to_dup, try frame.stack.pop());
    }
}

test "specific swap functions handle all SWAP operations" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const test_cases = [_]struct { n: u8, func: fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult }{
        .{ .n = 1, .func = swap_1 },
        .{ .n = 2, .func = swap_2 },
        .{ .n = 16, .func = swap_16 },
    };

    for (test_cases) |case| {
        var contract = try Contract.init(allocator, &[_]u8{}, .{ .address = primitives.Address.ZERO });
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();

        // Push enough values
        var i: usize = 0;
        while (i < case.n + 5) : (i += 1) {
            try frame.stack.append(@as(u256, i + 100));
        }

        const top_value = try frame.stack.peek_n(0);
        const target_value = try frame.stack.peek_n(case.n);

        const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
        const state_ptr: Operation.State = @ptrCast(&frame);

        _ = try case.func(0, interpreter_ptr, state_ptr);

        try std.testing.expectEqual(target_value, try frame.stack.peek_n(0));
        try std.testing.expectEqual(top_value, try frame.stack.peek_n(case.n));
    }
}

// ============================================================================
// Edge Case and Error Handling Tests
// ============================================================================

test "stack operations handle maximum capacity correctly" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{0x5f}; // PUSH0 opcode
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    // Fill stack to near capacity
    var i: usize = 0;
    while (i < Stack.CAPACITY - 1) : (i += 1) {
        try frame.stack.append(i);
    }

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Should be able to push one more
    _ = try op_push0(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(Stack.CAPACITY, frame.stack.size);

    // Now stack is full, verify operations work correctly
    // Can still pop
    _ = try op_pop(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(Stack.CAPACITY - 1, frame.stack.size);

    // Can dup when there's space
    if (frame.stack.size >= 1) {
        const dup1_fn = make_dup(1);
        _ = try dup1_fn(0, interpreter_ptr, state_ptr);
        try std.testing.expectEqual(Stack.CAPACITY, frame.stack.size);
    }
}

test "stack operations maintain consistency under stress" {
    const allocator = std.testing.allocator;
    const primitives = @import("primitives");

    var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
    defer memory_db.deinit();

    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const code = [_]u8{ 0x60, 0x42 }; // PUSH1 0x42
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);

    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();

    const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: Operation.State = @ptrCast(&frame);

    // Stress test with rapid push/pop/dup/swap operations
    var ops: usize = 0;
    while (ops < 1000) : (ops += 1) {
        const op_type = ops % 6;

        switch (op_type) {
            0 => { // PUSH
                if (frame.stack.size < Stack.CAPACITY - 50) {
                    _ = try op_push1(0, interpreter_ptr, state_ptr);
                }
            },
            1 => { // POP
                if (frame.stack.size > 0) {
                    _ = try op_pop(0, interpreter_ptr, state_ptr);
                }
            },
            2 => { // DUP1
                if (frame.stack.size >= 1 and frame.stack.size < Stack.CAPACITY) {
                    const dup1_fn = make_dup(1);
                    _ = try dup1_fn(0, interpreter_ptr, state_ptr);
                }
            },
            3 => { // SWAP1
                if (frame.stack.size >= 2) {
                    const swap1_fn = make_swap(1);
                    _ = try swap1_fn(0, interpreter_ptr, state_ptr);
                }
            },
            4 => { // DUP5
                if (frame.stack.size >= 5 and frame.stack.size < Stack.CAPACITY) {
                    const dup5_fn = make_dup(5);
                    _ = try dup5_fn(0, interpreter_ptr, state_ptr);
                }
            },
            5 => { // SWAP3
                if (frame.stack.size >= 4) {
                    const swap3_fn = make_swap(3);
                    _ = try swap3_fn(0, interpreter_ptr, state_ptr);
                }
            },
            else => unreachable,
        }

        // Verify stack integrity
        try std.testing.expect(frame.stack.size <= Stack.CAPACITY);
    }
}

test "stack_operation_benchmarks" {
    const Timer = std.time.Timer;
    var timer = try Timer.start();
    const allocator = std.testing.allocator;

    // Setup test environment
    var memory_db = @import("../state/memory_database.zig").MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    const db_interface = memory_db.to_database_interface();
    var vm = try @import("../evm.zig").Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();

    const iterations = 100000;

    // Benchmark 1: Basic PUSH operations (optimized vs general)
    timer.reset();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const test_code = [_]u8{ 0x60, 0x42 }; // PUSH1 0x42
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &test_code, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();

        _ = try op_push1(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const push1_optimized_ns = timer.read();

    // Benchmark 2: POP operations
    timer.reset();
    i = 0;
    while (i < iterations) : (i += 1) {
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x50}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();

        // Pre-populate stack
        try frame.stack.append(@intCast(i));

        _ = try op_pop(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const pop_operations_ns = timer.read();

    // Benchmark 3: DUP operations (comparing different positions)
    timer.reset();
    i = 0;
    while (i < iterations / 10) : (i += 1) { // Fewer iterations due to complexity
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x80}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();

        // Pre-populate stack with test values
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            try frame.stack.append(@intCast(j + i));
        }

        // Test DUP1 (most common)
        const dup1_fn = make_dup(1);
        _ = try dup1_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const dup_operations_ns = timer.read();

    // Benchmark 4: SWAP operations (comparing different positions)
    timer.reset();
    i = 0;
    while (i < iterations / 10) : (i += 1) {
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &[_]u8{0x90}, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();

        // Pre-populate stack
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            try frame.stack.append(@intCast(j + i));
        }

        // Test SWAP1 (most common)
        const swap1_fn = make_swap(1);
        _ = try swap1_fn(0, @ptrCast(&vm), @ptrCast(&frame));
    }
    const swap_operations_ns = timer.read();

    // Benchmark 5: Mixed operation patterns (realistic workload)
    timer.reset();
    i = 0;
    const mixed_iterations = 10000;
    while (i < mixed_iterations) : (i += 1) {
        const test_code = [_]u8{ 0x60, 0x01, 0x60, 0x02 }; // PUSH1 1, PUSH1 2
        var contract = try @import("../frame/contract.zig").Contract.init(allocator, &test_code, .{ .address = [_]u8{0} ** 20 });
        defer contract.deinit(allocator, null);
        var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
        defer frame.deinit();

        // Realistic pattern: PUSH, PUSH, DUP, SWAP, POP
        _ = try op_push1(0, @ptrCast(&vm), @ptrCast(&frame)); // PUSH 1
        _ = try op_push1(2, @ptrCast(&vm), @ptrCast(&frame)); // PUSH 2

        if (frame.stack.size >= 1 and frame.stack.size < Stack.CAPACITY) {
            const dup1_fn = make_dup(1);
            _ = try dup1_fn(0, @ptrCast(&vm), @ptrCast(&frame)); // DUP1
        }

        if (frame.stack.size >= 2) {
            const swap1_fn = make_swap(1);
            _ = try swap1_fn(0, @ptrCast(&vm), @ptrCast(&frame)); // SWAP1
        }

        if (frame.stack.size > 0) {
            _ = try op_pop(0, @ptrCast(&vm), @ptrCast(&frame)); // POP
        }
    }
    const mixed_pattern_ns = timer.read();

    // Benchmark 6: Stack depth impact on performance
    timer.reset();
    const depth_test_code = [_]u8{ 0x60, 0x01 }; // PUSH1 1
    var contract = try @import("../frame/contract.zig").Contract.init(allocator, &depth_test_code, .{ .address = [_]u8{0} ** 20 });
    defer contract.deinit(allocator, null);
    var frame = try Frame.init(allocator, &vm, 1000000, contract, [_]u8{0} ** 20, &.{});
    defer frame.deinit();

    // Test performance at different stack depths
    const depth_iterations = 1000;
    var depth_tests = [_]struct { depth: usize, ns: u64 }{
        .{ .depth = 10, .ns = 0 },
        .{ .depth = 100, .ns = 0 },
        .{ .depth = 500, .ns = 0 },
        .{ .depth = 1000, .ns = 0 },
    };

    for (depth_tests[0..], 0..) |*test_case, test_idx| {
        // Setup stack to target depth
        while (frame.stack.size < test_case.depth) {
            try frame.stack.append(@intCast(frame.stack.size));
        }

        timer.reset();
        i = 0;
        while (i < depth_iterations) : (i += 1) {
            // Test PUSH/POP at this depth
            _ = try op_push1(0, @ptrCast(&vm), @ptrCast(&frame));
            if (frame.stack.size > test_case.depth) {
                _ = try op_pop(0, @ptrCast(&vm), @ptrCast(&frame));
            }
        }
        depth_tests[test_idx].ns = timer.read();
    }

    // Print benchmark results
    std.log.debug("Stack Operation Benchmarks:", .{});
    std.log.debug("  PUSH1 optimized ({} ops): {} ns", .{ iterations, push1_optimized_ns });
    std.log.debug("  POP operations ({} ops): {} ns", .{ iterations, pop_operations_ns });
    std.log.debug("  DUP operations ({} ops): {} ns", .{ iterations / 10, dup_operations_ns });
    std.log.debug("  SWAP operations ({} ops): {} ns", .{ iterations / 10, swap_operations_ns });
    std.log.debug("  Mixed patterns ({} ops): {} ns", .{ mixed_iterations, mixed_pattern_ns });

    // Performance analysis
    const avg_push1_ns = push1_optimized_ns / iterations;
    const avg_pop_ns = pop_operations_ns / iterations;
    const avg_mixed_ns = mixed_pattern_ns / mixed_iterations;

    std.log.debug("  Average PUSH1: {} ns/op", .{avg_push1_ns});
    std.log.debug("  Average POP: {} ns/op", .{avg_pop_ns});
    std.log.debug("  Average mixed pattern: {} ns/op", .{avg_mixed_ns});

    // Stack depth impact results
    std.log.debug("  Stack depth impact on operations:");
    for (depth_tests) |test_case| {
        const avg_depth_ns = test_case.ns / depth_iterations;
        std.log.debug("    Depth {}: {} ns/op", .{ test_case.depth, avg_depth_ns });
    }

    // Optimization verification
    if (avg_push1_ns < 50) { // Expect very fast optimized PUSH1
        std.log.debug("✓ PUSH1 optimization showing expected performance");
    }
}

// ============================================================================
// Fuzz Tests for Runtime Dispatch Functions (Issue #234)
// Using proper Zig built-in fuzz testing with std.testing.fuzz()
// ============================================================================

// test "fuzz_runtime_dispatch_push_operations" {
//     const global = struct {
//         fn testRuntimePushDispatch(input: []const u8) anyerror!void {
//             if (input.len == 0) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             var contract = try Contract.init(allocator, &[_]u8{0x60, 0x42}, .{ .address = Address.ZERO });
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             // Extract opcode and data from fuzz input
//             const opcode_offset = input[0] % 32; // PUSH1 (0x60) to PUSH32 (0x7F)
//             const opcode = 0x60 + opcode_offset;
//
//             // Use remaining input as bytecode data
//             const data_len = @min(input.len - 1, 32);
//             const data = input[1..1 + data_len];
//
//             // Create malformed bytecode scenario
//             var malformed_code = std.ArrayList(u8).init(allocator);
//             defer malformed_code.deinit();
//
//             try malformed_code.append(opcode);
//             try malformed_code.appendSlice(data);
//
//             // Test runtime dispatch with potentially malformed bytecode
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             // Push operations should handle malformed input gracefully
//             const result = vm.table.execute(0, interpreter_ptr, state_ptr, opcode);
//             _ = result catch |err| switch (err) {
//                 error.StackOverflow, error.OutOfGas, error.InvalidOpcode => {}, // Expected errors
//                 else => return err,
//             };
//         }
//     };
//     try std.testing.fuzz(global.testRuntimePushDispatch, .{});
// }

// test "fuzz_runtime_dispatch_dup_operations" {
//     const global = struct {
//         fn testRuntimeDupDispatch(input: []const u8) anyerror!void {
//             if (input.len == 0) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             var contract = try Contract.init(allocator, &[_]u8{0x80}, .{ .address = Address.ZERO });
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             // Extract DUP operation from fuzz input (DUP1 = 0x80 to DUP16 = 0x8F)
//             const dup_offset = input[0] % 16; // DUP1 to DUP16
//             const opcode = 0x80 + dup_offset;
//
//             // Prepare stack with varying depths based on input
//             const stack_depth = @min((input.len % 20) + 1, 16); // 1-16 items
//             for (0..stack_depth) |i| {
//                 const value = if (input.len > i + 1) @as(u256, input[i + 1]) else @as(u256, i);
//                 try frame.stack.push(value);
//             }
//
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             // Test DUP runtime dispatch
//             const result = vm.table.execute(0, interpreter_ptr, state_ptr, opcode);
//             _ = result catch |err| switch (err) {
//                 error.StackUnderflow, error.StackOverflow, error.OutOfGas => {}, // Expected errors
//                 else => return err,
//             };
//         }
//     };
//     try std.testing.fuzz(global.testRuntimeDupDispatch, .{});
// }

// test "fuzz_runtime_dispatch_swap_operations" {
//     const global = struct {
//         fn testRuntimeSwapDispatch(input: []const u8) anyerror!void {
//             if (input.len == 0) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             var contract = try Contract.init(allocator, &[_]u8{0x90}, .{ .address = Address.ZERO });
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             // Extract SWAP operation from fuzz input (SWAP1 = 0x90 to SWAP16 = 0x9F)
//             const swap_offset = input[0] % 16; // SWAP1 to SWAP16
//             const opcode = 0x90 + swap_offset;
//
//             // Prepare stack with enough depth for swap operations
//             const required_depth = swap_offset + 2; // SWAP1 needs 2, SWAP16 needs 17
//             const stack_depth = @min(@max(required_depth, 2), 17);
//
//             for (0..stack_depth) |i| {
//                 const value = if (input.len > i + 1) @as(u256, input[i + 1]) else @as(u256, i * 0x11);
//                 try frame.stack.push(value);
//             }
//
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             // Test SWAP runtime dispatch
//             const result = vm.table.execute(0, interpreter_ptr, state_ptr, opcode);
//             _ = result catch |err| switch (err) {
//                 error.StackUnderflow, error.StackOverflow, error.OutOfGas => {}, // Expected errors
//                 else => return err,
//             };
//         }
//     };
//     try std.testing.fuzz(global.testRuntimeSwapDispatch, .{});
// }

// test "fuzz_stack_manipulation_with_varying_depths" {
//     const global = struct {
//         fn testStackManipulationDepths(input: []const u8) anyerror!void {
//             if (input.len < 4) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             var contract = try Contract.init(allocator, &[_]u8{0x01}, .{ .address = Address.ZERO });
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             // Use fuzz input to determine operation sequence
//             const push_opcode = 0x60 + (input[0] % 32); // PUSH1-PUSH32
//             const dup_opcode = 0x80 + (input[1] % 16); // DUP1-DUP16
//             const swap_opcode = 0x90 + (input[2] % 16); // SWAP1-SWAP16
//             const initial_stack_depth = @min(input[3] % 20, 16); // 0-16 items
//
//             // Build initial stack
//             for (0..initial_stack_depth) |i| {
//                 const value = if (input.len > i + 4) @as(u256, input[i + 4]) else @as(u256, i);
//                 try frame.stack.push(value);
//             }
//
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             // Test sequence of operations with varying stack depths
//             const operations = [_]u8{ push_opcode, dup_opcode, swap_opcode };
//
//             for (operations) |opcode| {
//                 const result = vm.table.execute(0, interpreter_ptr, state_ptr, opcode);
//                 _ = result catch |err| switch (err) {
//                     error.StackUnderflow, error.StackOverflow, error.OutOfGas, error.InvalidOpcode => {},
//                     else => return err,
//                 };
//             }
//         }
//     };
//     try std.testing.fuzz(global.testStackManipulationDepths, .{});
// }

// test "fuzz_push_operations_with_malformed_bytecode" {
//     const global = struct {
//         fn testMalformedBytecode(input: []const u8) anyerror!void {
//             if (input.len < 2) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             // Create potentially malformed bytecode from fuzz input
//             var malformed_code = std.ArrayList(u8).init(allocator);
//             defer malformed_code.deinit();
//
//             // Add PUSH operations with insufficient data
//             const push_size = (input[0] % 32) + 1; // PUSH1-PUSH32
//             const push_opcode = 0x5F + push_size;
//             try malformed_code.append(push_opcode);
//
//             // Add less data than required (malformed scenario)
//             const available_data = @min(input.len - 1, push_size / 2); // Intentionally insufficient
//             try malformed_code.appendSlice(input[1..1 + available_data]);
//
//             var contract = try Contract.init(allocator, malformed_code.items, .{ .address = Address.ZERO });
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             // Test with malformed bytecode - should handle gracefully
//             const result = vm.table.execute(0, interpreter_ptr, state_ptr, push_opcode);
//             _ = result catch |err| switch (err) {
//                 error.OutOfGas, error.InvalidOpcode, error.StackOverflow => {}, // Expected with malformed code
//                 else => return err,
//             };
//         }
//     };
//     try std.testing.fuzz(global.testMalformedBytecode, .{});
// }

// test "fuzz_extreme_stack_operations_boundary_conditions" {
//     const global = struct {
//         fn testExtremeBoundaryConditions(input: []const u8) anyerror!void {
//             if (input.len == 0) return;
//
//             const allocator = std.testing.allocator;
//             var memory_db = MemoryDatabase.MemoryDatabase.init(allocator);
//             defer memory_db.deinit();
//
//             const db_interface = memory_db.to_database_interface();
//             var vm = try Vm.init(allocator, db_interface, null, null);
//             defer vm.deinit();
//
//             var contract = try Contract.init(allocator, &[_]u8{0x50}, .{ .address = Address.ZERO }); // POP
//             defer contract.deinit(allocator, null);
//
//             var frame = try Frame.init(allocator, &vm, 1000000, contract, Address.ZERO, &.{});
//             defer frame.deinit();
//
//             const boundary_test = input[0] % 4;
//
//             const interpreter_ptr: Operation.Interpreter = @ptrCast(&vm);
//             const state_ptr: Operation.State = @ptrCast(&frame);
//
//             switch (boundary_test) {
//                 0 => {
//                     // Test stack underflow condition
//                     // Attempt POP on empty stack
//                     const result = vm.table.execute(0, interpreter_ptr, state_ptr, 0x50); // POP
//                     std.testing.expectError(error.StackUnderflow, result) catch |err| switch (err) {
//                         error.TestExpectedError => {}, // Different error than expected, but acceptable
//                         else => return err,
//                     };
//                 },
//                 1 => {
//                     // Test near-maximum stack depth
//                     const target_depth = @min(1020, input.len); // Near 1024 limit
//                     for (0..target_depth) |i| {
//                         const value = if (input.len > i) @as(u256, input[i]) else @as(u256, i);
//                         frame.stack.push(value) catch break; // Stop if we can't push more
//                     }
//
//                     // Test operations near stack limit
//                     _ = vm.table.execute(0, interpreter_ptr, state_ptr, 0x60) catch |err| switch (err) {
//                         error.StackOverflow, error.OutOfGas => {},
//                         else => return err,
//                     };
//                 },
//                 2 => {
//                     // Test extreme DUP operations
//                     for (0..10) |i| {
//                         try frame.stack.push(@as(u256, i * 0xFF));
//                     }
//
//                     const extreme_dup = 0x80 + 15; // DUP16
//                     _ = vm.table.execute(0, interpreter_ptr, state_ptr, extreme_dup) catch |err| switch (err) {
//                         error.StackUnderflow, error.StackOverflow => {},
//                         else => return err,
//                     };
//                 },
//                 3 => {
//                     // Test extreme SWAP operations
//                     for (0..18) |i| {
//                         try frame.stack.push(@as(u256, i));
//                     }
//
//                     const extreme_swap = 0x90 + 15; // SWAP16
//                     _ = vm.table.execute(0, interpreter_ptr, state_ptr, extreme_swap) catch |err| switch (err) {
//                         error.StackUnderflow, error.StackOverflow => {},
//                         else => return err,
//                     };
//                 },
//             }
//         }
//     };
//     try std.testing.fuzz(global.testExtremeBoundaryConditions, .{});
// }
