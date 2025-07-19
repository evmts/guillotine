const std = @import("std");
const opcodes = @import("../src/evm/opcodes/opcode.zig");
const opcode_properties = @import("../src/evm/opcodes/opcode_properties.zig");

/// Comprehensive benchmark suite for opcode property lookups
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    
    std.debug.print("\n=== Opcode Properties Performance Benchmark ===\n\n", .{});
    
    // Generate test data - all possible opcodes
    var all_opcodes: [256]u8 = undefined;
    for (0..256) |i| {
        all_opcodes[i] = @intCast(i);
    }
    
    // Also test with realistic opcode distribution
    const realistic_opcodes = generateRealisticOpcodes();
    
    try benchmarkIsPush(&all_opcodes, &realistic_opcodes);
    try benchmarkGetPushSize(&all_opcodes, &realistic_opcodes);
    try benchmarkIsTerminating(&all_opcodes, &realistic_opcodes);
    try benchmarkIsDup(&all_opcodes, &realistic_opcodes);
    try benchmarkIsSwap(&all_opcodes, &realistic_opcodes);
    try benchmarkIsLog(&all_opcodes, &realistic_opcodes);
    try benchmarkModifiesState(&all_opcodes, &realistic_opcodes);
    try benchmarkMixedOperations(&all_opcodes, &realistic_opcodes);
    
    std.debug.print("\n=== Memory Footprint ===\n", .{});
    std.debug.print("Total lookup table size: {} bytes\n", .{calculateMemoryFootprint()});
    std.debug.print("L1 cache utilization: {d:.2}%\n", .{calculateCacheUtilization()});
}

fn generateRealisticOpcodes() [1024]u8 {
    // Generate bytecode with realistic opcode distribution
    var opcodes: [1024]u8 = undefined;
    var i: usize = 0;
    
    // Common patterns in smart contracts
    while (i < 1024) {
        // Stack operations (very common)
        if (i % 10 < 3) {
            opcodes[i] = 0x60 + @as(u8, @intCast(i % 32)); // PUSH ops
            i += 1;
        } else if (i % 10 < 5) {
            opcodes[i] = 0x80 + @as(u8, @intCast(i % 16)); // DUP ops
            i += 1;
        } else if (i % 10 < 6) {
            opcodes[i] = 0x90 + @as(u8, @intCast(i % 16)); // SWAP ops
            i += 1;
        } else if (i % 10 < 8) {
            // Arithmetic operations
            opcodes[i] = @as(u8, @intCast(i % 0x20));
            i += 1;
        } else {
            // Control flow and other
            const control_ops = [_]u8{ 0x56, 0x57, 0x5B, 0xF3, 0xFD, 0x00 };
            opcodes[i] = control_ops[i % control_ops.len];
            i += 1;
        }
    }
    
    return opcodes;
}

fn benchmarkIsPush(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("is_push benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.is_push(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} PUSH opcodes found)\n", .{ ns_per_op, count / iterations });
    }
    
    // Benchmark with realistic distribution
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (realistic_opcodes) |op| {
                if (opcodes.is_push(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 1024);
        std.debug.print("  Realistic: {} ns/op\n", .{ns_per_op});
    }
}

fn benchmarkGetPushSize(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nget_push_size benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var total: u64 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                total += opcodes.get_push_size(op);
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op (checksum: {})\n", .{ ns_per_op, total });
    }
    
    // Benchmark with realistic distribution
    {
        const start = timer.read();
        var total: u64 = 0;
        for (0..iterations) |_| {
            for (realistic_opcodes) |op| {
                total += opcodes.get_push_size(op);
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 1024);
        std.debug.print("  Realistic: {} ns/op\n", .{ns_per_op});
    }
}

fn benchmarkIsTerminating(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nis_terminating benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.is_terminating(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} terminating opcodes)\n", .{ ns_per_op, count / iterations });
    }
    
    // Benchmark with realistic distribution
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (realistic_opcodes) |op| {
                if (opcodes.is_terminating(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 1024);
        std.debug.print("  Realistic: {} ns/op\n", .{ns_per_op});
    }
}

fn benchmarkIsDup(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nis_dup benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.is_dup(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} DUP opcodes)\n", .{ ns_per_op, count / iterations });
    }
}

fn benchmarkIsSwap(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nis_swap benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.is_swap(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} SWAP opcodes)\n", .{ ns_per_op, count / iterations });
    }
}

fn benchmarkIsLog(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nis_log benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.is_log(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} LOG opcodes)\n", .{ ns_per_op, count / iterations });
    }
}

fn benchmarkModifiesState(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 1_000_000;
    
    std.debug.print("\nmodifies_state benchmark:\n", .{});
    
    // Benchmark with all opcodes
    {
        const start = timer.read();
        var count: u32 = 0;
        for (0..iterations) |_| {
            for (all_opcodes) |op| {
                if (opcodes.modifies_state(op)) count += 1;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 256);
        std.debug.print("  All opcodes: {} ns/op ({} state-modifying opcodes)\n", .{ ns_per_op, count / iterations });
    }
}

fn benchmarkMixedOperations(all_opcodes: *const [256]u8, realistic_opcodes: *const [1024]u8) !void {
    const timer = try std.time.Timer.start();
    const iterations = 100_000;
    
    std.debug.print("\nMixed operations benchmark (simulating real EVM execution):\n", .{});
    
    // Simulate realistic EVM execution with mixed operations
    {
        const start = timer.read();
        var checksum: u64 = 0;
        for (0..iterations) |_| {
            for (realistic_opcodes) |op| {
                // Simulate common EVM operations during execution
                if (opcodes.is_push(op)) {
                    const size = opcodes.get_push_size(op);
                    checksum += size;
                } else if (opcodes.is_dup(op)) {
                    const pos = opcodes.get_dup_position(op);
                    checksum += pos;
                } else if (opcodes.is_swap(op)) {
                    const pos = opcodes.get_swap_position(op);
                    checksum += pos;
                } else if (opcodes.is_log(op)) {
                    const topics = opcodes.get_log_topic_count(op);
                    checksum += topics;
                }
                
                // Always check termination and state modification
                if (opcodes.is_terminating(op)) checksum += 100;
                if (opcodes.modifies_state(op)) checksum += 200;
            }
        }
        const elapsed = timer.read() - start;
        const ns_per_op = elapsed / (iterations * 1024);
        std.debug.print("  Realistic workload: {} ns/op (checksum: {})\n", .{ ns_per_op, checksum });
    }
}

fn calculateMemoryFootprint() usize {
    // Each lookup table is 256 entries
    const bool_tables = 7; // IS_TERMINATING, MODIFIES_MEMORY, MODIFIES_STATE, IS_JUMP, CAN_FAIL, IS_CALL, IS_CREATE
    const u8_tables = 5; // IMMEDIATE_SIZE, DUP_POSITION, SWAP_POSITION, LOG_TOPIC_COUNT, READS_MEMORY
    
    return (bool_tables * 256) + (u8_tables * 256);
}

fn calculateCacheUtilization() f64 {
    const table_size = calculateMemoryFootprint();
    const l1_cache_size = 192 * 1024; // Typical L1d cache size (192KB for modern CPUs)
    
    return (@as(f64, @floatFromInt(table_size)) / @as(f64, @floatFromInt(l1_cache_size))) * 100.0;
}