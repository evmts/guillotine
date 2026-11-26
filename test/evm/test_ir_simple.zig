const std = @import("std");

// Minimal test to check IR builder behavior
pub fn main() !void {
    // Test 1: CODECOPY stops the IR builder
    {
        std.debug.print("\n=== Test 1: CODECOPY (0x39) ===\n", .{});
        // PUSH1 0x10, PUSH1 0x00, PUSH1 0x20, CODECOPY, STOP
        const bytecode = [_]u8{ 0x60, 0x10, 0x60, 0x00, 0x60, 0x20, 0x39, 0x00 };
        
        var count: usize = 0;
        for (bytecode, 0..) |op, i| {
            std.debug.print("  [{d}] opcode=0x{x:0>2}", .{i, op});
            
            switch (op) {
                0x60 => std.debug.print(" PUSH1\n", .{}),
                0x39 => {
                    std.debug.print(" CODECOPY - IR builder would STOP here!\n", .{});
                    break; // This is what ir_builder.zig does
                },
                0x00 => std.debug.print(" STOP\n", .{}),
                else => std.debug.print(" ?\n", .{}),
            }
            count += 1;
        }
        std.debug.print("  Processed {d} of {d} opcodes\n", .{count, bytecode.len});
    }
    
    // Test 2: ADD stops the IR builder
    {
        std.debug.print("\n=== Test 2: ADD (0x01) ===\n", .{});
        // PUSH1 0x02, PUSH1 0x03, ADD, STOP
        const bytecode = [_]u8{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x00 };
        
        var count: usize = 0;
        for (bytecode, 0..) |op, i| {
            std.debug.print("  [{d}] opcode=0x{x:0>2}", .{i, op});
            
            switch (op) {
                0x60 => std.debug.print(" PUSH1\n", .{}),
                0x01 => {
                    std.debug.print(" ADD - IR builder would STOP here!\n", .{});
                    break; // This is what ir_builder.zig does
                },
                0x00 => std.debug.print(" STOP\n", .{}),
                else => std.debug.print(" ?\n", .{}),
            }
            count += 1;
        }
        std.debug.print("  Processed {d} of {d} opcodes\n", .{count, bytecode.len});
    }
    
    // Test 3: DUP1 stops the IR builder  
    {
        std.debug.print("\n=== Test 3: Solidity init pattern ===\n", .{});
        // PUSH1 0x0a, DUP1, PUSH1 0x10, PUSH1 0x00, CODECOPY, PUSH1 0x00, RETURN
        const bytecode = [_]u8{ 0x60, 0x0a, 0x80, 0x60, 0x10, 0x60, 0x00, 0x39, 0x60, 0x00, 0xf3 };
        
        var count: usize = 0;
        for (bytecode, 0..) |op, i| {
            std.debug.print("  [{d}] opcode=0x{x:0>2}", .{i, op});
            
            switch (op) {
                0x60 => std.debug.print(" PUSH1\n", .{}),
                0x80 => {
                    std.debug.print(" DUP1 - IR builder would STOP here!\n", .{});
                    break; // This is what ir_builder.zig does
                },
                0x39 => std.debug.print(" CODECOPY\n", .{}),
                0xf3 => std.debug.print(" RETURN\n", .{}),
                0x00 => std.debug.print(" STOP\n", .{}),
                else => std.debug.print(" ?\n", .{}),
            }
            count += 1;
        }
        std.debug.print("  Processed {d} of {d} opcodes\n", .{count, bytecode.len});
    }
    
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("The IR builder stops at ANY opcode it doesn't recognize.\n", .{});
    std.debug.print("It only supports: PUSH, MSTORE, MSTORE8, MLOAD, JUMPDEST, RETURN, REVERT, STOP\n", .{});
    std.debug.print("Solidity init code needs: CODECOPY, DUP, ADD, and many more!\n", .{});
}