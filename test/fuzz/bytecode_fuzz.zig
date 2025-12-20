//! Bytecode Analysis Fuzz Testing
//!
//! Fuzz tests for bytecode analysis components including:
//! - Jump destination analysis
//! - Opcode fusion detection
//! - Bytecode validation
//! - Edge cases in PUSH instruction handling

const std = @import("std");
const evm = @import("evm");
const Bytecode = evm.Bytecode(.{});
const Opcode = evm.Opcode;
const primitives = @import("voltaire");
const U256 = primitives.U256.U256;

test "fuzz bytecode analysis with random bytecode" {
    try std.testing.fuzz({}, fuzzBytecodeAnalysis, .{ .corpus = &.{} });
}

fn fuzzBytecodeAnalysis(context: void, input: []const u8) !void {
    _ = context;
    if (input.len == 0) return;
    
    const allocator = std.testing.allocator;
    
    // Limit bytecode size to prevent OOM
    const max_bytecode_size = 64 * 1024; // 64KB max
    const bytecode = input[0..@min(input.len, max_bytecode_size)];
    
    // Analyze bytecode - all errors are acceptable outcomes
    var analyzer = Bytecode.init(allocator, bytecode) catch {
        // Expected errors from malformed bytecode
        return;
    };
    defer analyzer.deinit();
}

test "fuzz bytecode5 jump destination analysis" {
    try std.testing.fuzz({}, fuzzJumpDestAnalysis, .{ .corpus = &.{} });
}

fn fuzzJumpDestAnalysis(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 10) return; // Need some minimum bytecode
    
    const allocator = std.testing.allocator;
    
    // Create bytecode with forced JUMPDEST opcodes (up to 1024 bytes)
    var bytecode_buf: [1024]u8 = undefined;
    var bytecode_len: usize = 0;
    
    // Add some JUMPDEST instructions at random positions
    var i: usize = 0;
    while (i < input.len and bytecode_len < bytecode_buf.len - 1) : (i += 1) {
        if (input[i] % 4 == 0) {
            bytecode_buf[bytecode_len] = @intFromEnum(Opcode.JUMPDEST);
        } else {
            bytecode_buf[bytecode_len] = input[i];
        }
        bytecode_len += 1;
    }
    
    const bytecode = bytecode_buf[0..bytecode_len];
    
    // Analyze bytecode
    var analyzer = Bytecode.init(allocator, bytecode) catch {
        // All errors acceptable
        return;
    };
    defer analyzer.deinit();
    
    // Verify jump destinations are valid (they're built during init)
    for (analyzer.jumpdests) |pc| {
        if (pc >= bytecode.len) {
            // This shouldn't happen - would indicate a bug
            std.debug.panic("Invalid jump destination PC: {}", .{pc});
        }
    }
}

test "fuzz bytecode5 PUSH instruction handling" {
    try std.testing.fuzz({}, fuzzPushInstructions, .{ .corpus = &.{} });
}

fn fuzzPushInstructions(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 33) return; // Need space for PUSH32
    
    const allocator = std.testing.allocator;
    
    // Create bytecode with various PUSH instructions (up to 1024 bytes)
    var bytecode_buf: [1024]u8 = undefined;
    var bytecode_len: usize = 0;
    
    var i: usize = 0;
    while (i < input.len - 33 and bytecode_len < bytecode_buf.len - 33) {
        const push_size = (input[i] % 32) + 1; // PUSH1 to PUSH32
        const opcode = @intFromEnum(Opcode.PUSH1) + push_size - 1;
        
        bytecode_buf[bytecode_len] = @intCast(opcode);
        bytecode_len += 1;
        
        // Add push data (may be truncated)
        const data_available = input.len - i - 1;
        const data_to_add = @min(push_size, @min(data_available, bytecode_buf.len - bytecode_len));
        @memcpy(bytecode_buf[bytecode_len..bytecode_len + data_to_add], input[i + 1..i + 1 + data_to_add]);
        bytecode_len += data_to_add;
        
        i += 1 + data_to_add;
    }
    
    const bytecode = bytecode_buf[0..bytecode_len];
    
    // Analyze bytecode
    _ = Bytecode.init(allocator, bytecode) catch {
        // Expected for truncated PUSH instructions
        return;
    };
}

test "fuzz bytecode5 fusion pattern detection" {
    try std.testing.fuzz({}, fuzzFusionPatterns, .{ .corpus = &.{} });
}

fn fuzzFusionPatterns(context: void, input: []const u8) !void {
    _ = context;
    if (input.len < 10) return;
    
    const allocator = std.testing.allocator;
    
    // Create bytecode that might contain fusion patterns (up to 1024 bytes)
    var bytecode_buf: [1024]u8 = undefined;
    var bytecode_len: usize = 0;
    
    var i: usize = 0;
    while (i < input.len and bytecode_len < bytecode_buf.len - 10) : (i += 1) {
        const choice = input[i] % 10;
        
        switch (choice) {
            // PUSH-ADD pattern
            0 => {
                if (bytecode_len + 3 <= bytecode_buf.len) {
                    bytecode_buf[bytecode_len] = @intFromEnum(Opcode.PUSH1);
                    bytecode_buf[bytecode_len + 1] = if (i + 1 < input.len) input[i + 1] else 1;
                    bytecode_buf[bytecode_len + 2] = @intFromEnum(Opcode.ADD);
                    bytecode_len += 3;
                    i += 1;
                }
            },
            // ISZERO-JUMPI pattern
            1 => {
                if (bytecode_len + 2 <= bytecode_buf.len) {
                    bytecode_buf[bytecode_len] = @intFromEnum(Opcode.ISZERO);
                    bytecode_buf[bytecode_len + 1] = @intFromEnum(Opcode.JUMPI);
                    bytecode_len += 2;
                }
            },
            // Multi-PUSH pattern
            2 => {
                if (bytecode_len + 4 <= bytecode_buf.len) {
                    bytecode_buf[bytecode_len] = @intFromEnum(Opcode.PUSH1);
                    bytecode_buf[bytecode_len + 1] = if (i + 1 < input.len) input[i + 1] else 1;
                    bytecode_buf[bytecode_len + 2] = @intFromEnum(Opcode.PUSH1);
                    bytecode_buf[bytecode_len + 3] = if (i + 2 < input.len) input[i + 2] else 2;
                    bytecode_len += 4;
                    i += 2;
                }
            },
            // DUP2-MSTORE-PUSH pattern
            3 => {
                if (bytecode_len + 4 <= bytecode_buf.len) {
                    bytecode_buf[bytecode_len] = @intFromEnum(Opcode.DUP2);
                    bytecode_buf[bytecode_len + 1] = @intFromEnum(Opcode.MSTORE);
                    bytecode_buf[bytecode_len + 2] = @intFromEnum(Opcode.PUSH1);
                    bytecode_buf[bytecode_len + 3] = 32;
                    bytecode_len += 4;
                }
            },
            // Random opcode
            else => {
                bytecode_buf[bytecode_len] = input[i];
                bytecode_len += 1;
            },
        }
    }
    
    const bytecode = bytecode_buf[0..bytecode_len];
    
    // Analyze bytecode
    var analyzer = Bytecode.init(allocator, bytecode) catch {
        // All errors acceptable
        return;
    };
    defer analyzer.deinit();
    
    // Check that fusion detection didn't cause crashes
    if (analyzer.advanced_fusions.count() > 0) {
        var iter = analyzer.advanced_fusions.iterator();
        while (iter.next()) |entry| {
            const pc = entry.key_ptr.*;
            const fusion = entry.value_ptr.*;
            
            // Verify fusion PC is within bounds
            if (pc + fusion.original_length > bytecode.len) {
                std.debug.panic("Fusion extends beyond bytecode bounds", .{});
            }
        }
    }
}

test "fuzz bytecode5 malformed bytecode handling" {
    try std.testing.fuzz({}, fuzzMalformedBytecode, .{ .corpus = &.{} });
}

fn fuzzMalformedBytecode(context: void, input: []const u8) !void {
    _ = context;
    
    const allocator = std.testing.allocator;
    
    // Test with completely random bytecode
    _ = Bytecode.init(allocator, input) catch {
        // All errors are acceptable
        return;
    };
}

test "fuzz bytecode5 edge cases" {
    try std.testing.fuzz({}, fuzzEdgeCases, .{ .corpus = &.{} });
}

fn fuzzEdgeCases(context: void, input: []const u8) !void {
    _ = context;
    
    const allocator = std.testing.allocator;
    // Test empty bytecode
    _ = Bytecode.init(allocator, &[_]u8{}) catch {
        return;
    };
    
    // Test single byte
    if (input.len > 0) {
        _ = Bytecode.init(allocator, input[0..1]) catch {
            return;
        };
    }
    
    // Test bytecode ending with incomplete PUSH
    if (input.len > 2) {
        var bytecode = [_]u8{ @intFromEnum(Opcode.PUSH32), input[0] };
        _ = Bytecode.init(allocator, &bytecode) catch {
            // Expected error for truncated PUSH32
            return;
        };
    }
}