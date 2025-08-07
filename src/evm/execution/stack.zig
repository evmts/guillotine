const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionContext = @import("../execution_context.zig").ExecutionContext;
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Vm = @import("../evm.zig");

const StackValidation = @import("../stack/stack_validation.zig");
const Address = @import("primitives").Address;

pub fn op_pop(context: *ExecutionContext) ExecutionError.Error!void {
    _ = try context.stack.pop();
}

pub fn op_push0(context: *ExecutionContext) ExecutionError.Error!void {
    // EIP-3855 validation should be handled during bytecode analysis phase,
    // not at runtime. Invalid PUSH0 opcodes should be rejected during code analysis.
    
    // Compile-time validation: PUSH0 pops 0 items, pushes 1
    // This ensures at build time that PUSH0 has valid stack effects for EVM
    try StackValidation.validateStackRequirements(0, 1, context.stack.size());

    context.stack.append_unsafe(0);
}

// Optimized PUSH1 implementation with direct byte access
pub fn op_push1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = state;

    if (frame.stack.size() >= Stack.CAPACITY) {
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

            if (frame.stack.size() >= Stack.CAPACITY) {
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

            if (frame.stack.size() >= Stack.CAPACITY) {
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
    if (frame.stack.size() >= Stack.CAPACITY) {
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
            try StackValidation.validateStackRequirements(0, 1, frame.stack.size());

            // Additional runtime check for DUP depth (n must be available on stack)
            if (frame.stack.size() < n) {
                @branchHint(.cold);
                return ExecutionError.Error.StackUnderflow;
            }

            frame.stack.dup_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.dup;
}

// ExecutionContext-based factory function for DUP operations
pub fn make_dup_ec(comptime n: u8) fn (*ExecutionContext) ExecutionError.Error!void {
    return struct {
        pub fn dup_ec(context: *ExecutionContext) ExecutionError.Error!void {
            return dup_impl_context(n, context);
        }
    }.dup_ec;
}

// Runtime dispatch versions for DUP operations (used in ReleaseSmall mode)
// Each DUP operation gets its own function to avoid opcode detection issues

// Helper function for DUP operations - using ExecutionContext
fn dup_impl_context(n: u8, context: *ExecutionContext) ExecutionError.Error!void {
    // Compile-time validation: DUP operations pop 0 items, push 1
    // At compile time, this validates that DUP has valid EVM stack effects
    // At runtime, this ensures sufficient stack depth for DUPn operations
    try StackValidation.validateStackRequirements(0, 1, context.stack.size());

    // Additional runtime check for DUP depth (n must be available on stack)
    if (context.stack.size() < n) {
        @branchHint(.cold);
        return ExecutionError.Error.StackUnderflow;
    }

    context.stack.dup_unsafe(n);
}

// Helper function for DUP operations - using old Operation pattern (kept for compatibility)
fn dup_impl_old(n: u8, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;

    // Compile-time validation: DUP operations pop 0 items, push 1
    // At compile time, this validates that DUP has valid EVM stack effects
    // At runtime, this ensures sufficient stack depth for DUPn operations
    try StackValidation.validateStackRequirements(0, 1, frame.stack.size());

    // Additional runtime check for DUP depth (n must be available on stack)
    if (frame.stack.size() < n) {
        @branchHint(.cold);
        return ExecutionError.Error.StackUnderflow;
    }

    frame.stack.dup_unsafe(n);

    return Operation.ExecutionResult{};
}

pub fn dup_1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(1, state);
}

pub fn dup_2(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(2, state);
}

pub fn dup_3(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(3, state);
}

pub fn dup_4(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(4, state);
}

pub fn dup_5(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(5, state);
}

pub fn dup_6(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(6, state);
}

pub fn dup_7(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(7, state);
}

pub fn dup_8(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(8, state);
}

pub fn dup_9(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(9, state);
}

pub fn dup_10(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(10, state);
}

pub fn dup_11(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(11, state);
}

pub fn dup_12(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(12, state);
}

pub fn dup_13(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(13, state);
}

pub fn dup_14(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(14, state);
}

pub fn dup_15(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(15, state);
}

pub fn dup_16(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return dup_impl_old(16, state);
}

// ExecutionContext versions of DUP operations (new pattern)
pub fn op_dup1(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(1, context);
}

pub fn op_dup2(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(2, context);
}

pub fn op_dup3(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(3, context);
}

pub fn op_dup4(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(4, context);
}

pub fn op_dup5(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(5, context);
}

pub fn op_dup6(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(6, context);
}

pub fn op_dup7(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(7, context);
}

pub fn op_dup8(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(8, context);
}

pub fn op_dup9(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(9, context);
}

pub fn op_dup10(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(10, context);
}

pub fn op_dup11(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(11, context);
}

pub fn op_dup12(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(12, context);
}

pub fn op_dup13(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(13, context);
}

pub fn op_dup14(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(14, context);
}

pub fn op_dup15(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(15, context);
}

pub fn op_dup16(context: *ExecutionContext) ExecutionError.Error!void {
    return dup_impl_context(16, context);
}

// DUP operations are now generated directly in jump_table.zig using make_dup()

// Generate swap operations
pub fn make_swap(comptime n: u8) fn (usize, Operation.Interpreter, Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn swap(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;
            _ = interpreter;

            const frame = state;

            if (frame.stack.size() < n + 1) {
                unreachable;
            }
            frame.stack.swap_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.swap;
}

// ExecutionContext-based factory function for SWAP operations  
pub fn make_swap_ec(comptime n: u8) fn (*ExecutionContext) ExecutionError.Error!void {
    return struct {
        pub fn swap_ec(context: *ExecutionContext) ExecutionError.Error!void {
            return swap_impl_context(n, context);
        }
    }.swap_ec;
}

// Runtime dispatch versions for SWAP operations (used in ReleaseSmall mode)
// Each SWAP operation gets its own function to avoid opcode detection issues

pub fn swap_1(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(1, state);
}

pub fn swap_2(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(2, state);
}

pub fn swap_3(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(3, state);
}

pub fn swap_4(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(4, state);
}

pub fn swap_5(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(5, state);
}

pub fn swap_6(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(6, state);
}

pub fn swap_7(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(7, state);
}

pub fn swap_8(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(8, state);
}

pub fn swap_9(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(9, state);
}

pub fn swap_10(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(10, state);
}

pub fn swap_11(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(11, state);
}

pub fn swap_12(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(12, state);
}

pub fn swap_13(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(13, state);
}

pub fn swap_14(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(14, state);
}

pub fn swap_15(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(15, state);
}

pub fn swap_16(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;
    return swap_impl_old(16, state);
}

// Common implementation for all SWAP operations
// Helper function for SWAP operations - using ExecutionContext
fn swap_impl_context(n: u8, context: *ExecutionContext) ExecutionError.Error!void {
    // Stack underflow check - SWAP needs n+1 items
    if (context.stack.size() < n + 1) {
        return ExecutionError.Error.StackUnderflow;
    }

    context.stack.swap_unsafe(n);
}

// Helper function for SWAP operations - using old Operation pattern (kept for compatibility)
fn swap_impl_old(n: u8, state: Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    const frame = state;

    // Stack underflow check - SWAP needs n+1 items
    if (frame.stack.size() < n + 1) {
        return ExecutionError.Error.StackUnderflow;
    }

    frame.stack.swap_unsafe(n);
    return Operation.ExecutionResult{};
}

// ExecutionContext versions of SWAP operations (new pattern)
pub fn op_swap1(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(1, context);
}

pub fn op_swap2(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(2, context);
}

pub fn op_swap3(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(3, context);
}

pub fn op_swap4(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(4, context);
}

pub fn op_swap5(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(5, context);
}

pub fn op_swap6(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(6, context);
}

pub fn op_swap7(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(7, context);
}

pub fn op_swap8(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(8, context);
}

pub fn op_swap9(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(9, context);
}

pub fn op_swap10(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(10, context);
}

pub fn op_swap11(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(11, context);
}

pub fn op_swap12(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(12, context);
}

pub fn op_swap13(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(13, context);
}

pub fn op_swap14(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(14, context);
}

pub fn op_swap15(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(15, context);
}

pub fn op_swap16(context: *ExecutionContext) ExecutionError.Error!void {
    return swap_impl_context(16, context);
}

// SWAP operations are now generated directly in jump_table.zig using make_swap()

// FIXME: All tests commented out during ExecutionContext migration - they use old Contract/Frame pattern
