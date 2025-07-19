const std = @import("std");
const opcodes = @import("../src/evm/opcodes/opcode.zig");

/// Simple benchmark to validate performance improvements from lookup tables
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const timer = try std.time.Timer.start();
    
    const iterations = 10_000_000;
    
    // Test data - mix of different opcodes
    const test_opcodes = [_]u8{
        0x00, // STOP
        0x01, // ADD
        0x60, // PUSH1
        0x61, // PUSH2
        0x7F, // PUSH32
        0x80, // DUP1
        0x8F, // DUP16
        0x90, // SWAP1
        0x9F, // SWAP16
        0xF3, // RETURN
        0xFD, // REVERT
        0xFF, // SELFDESTRUCT
    };
    
    // Benchmark 1: is_push detection
    {
        var start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (test_opcodes) |op| {
                if (opcodes.is_push(op)) {
                    count += 1;
                }
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * test_opcodes.len);
        std.debug.print("is_push: {} ns/op ({} matches)\n", .{ ns_per_op, count });
    }
    
    // Benchmark 2: get_push_size
    {
        var start = timer.read();
        var total_size: u64 = 0;
        for (0..iterations) |_| {
            for (test_opcodes) |op| {
                total_size += opcodes.get_push_size(op);
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * test_opcodes.len);
        std.debug.print("get_push_size: {} ns/op (total size: {})\n", .{ ns_per_op, total_size });
    }
    
    // Benchmark 3: is_terminating
    {
        var start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (test_opcodes) |op| {
                if (opcodes.is_terminating(op)) {
                    count += 1;
                }
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * test_opcodes.len);
        std.debug.print("is_terminating: {} ns/op ({} matches)\n", .{ ns_per_op, count });
    }
    
    // Benchmark 4: Mixed operations
    {
        var start = timer.read();
        var results: u64 = 0;
        for (0..iterations) |_| {
            for (test_opcodes) |op| {
                if (opcodes.is_push(op)) results += 1;
                if (opcodes.is_dup(op)) results += 2;
                if (opcodes.is_swap(op)) results += 3;
                if (opcodes.is_terminating(op)) results += 4;
                results += opcodes.get_push_size(op);
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * test_opcodes.len * 5); // 5 operations per iteration
        std.debug.print("mixed operations: {} ns/op (checksum: {})\n", .{ ns_per_op, results });
    }
}