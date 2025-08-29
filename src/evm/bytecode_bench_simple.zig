const std = @import("std");
const Bytecode = @import("bytecode.zig").Bytecode;
const BytecodeConfig = @import("bytecode_config.zig").BytecodeConfig;
const Opcode = @import("opcode.zig").Opcode;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.debug.print("\n🚀 Bytecode Analysis Performance Test\n", .{});
    std.debug.print("=====================================\n\n", .{});
    
    // Test 1: Simple bytecode (no jumps)
    {
        var code: [1000]u8 = undefined;
        for (0..1000) |i| {
            code[i] = switch (i % 10) {
                0 => @intFromEnum(Opcode.ADD),
                1 => @intFromEnum(Opcode.MUL),
                2 => @intFromEnum(Opcode.SUB),
                3 => @intFromEnum(Opcode.DIV),
                4 => @intFromEnum(Opcode.LT),
                5 => @intFromEnum(Opcode.GT),
                6 => @intFromEnum(Opcode.EQ),
                7 => @intFromEnum(Opcode.DUP1),
                8 => @intFromEnum(Opcode.SWAP1),
                else => @intFromEnum(Opcode.POP),
            };
        }
        
        const iterations = 1000;
        var total_time: i128 = 0;
        
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            var bytecode = try Bytecode(BytecodeConfig{}).init(allocator, &code);
            defer bytecode.deinit();
            const end = std.time.nanoTimestamp();
            total_time += end - start;
        }
        
        const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, iterations) / 1_000_000.0;
        std.debug.print("No jumps (1000 bytes): {d:.3}ms avg over {} iterations\n", .{ avg_time, iterations });
    }
    
    // Test 2: Fusion candidates
    {
        var code: [999]u8 = undefined;
        var i: usize = 0;
        while (i + 2 < code.len) : (i += 3) {
            code[i] = @intFromEnum(Opcode.PUSH1);
            code[i + 1] = @truncate(i);
            code[i + 2] = @intFromEnum(Opcode.ADD);
        }
        while (i < code.len) : (i += 1) {
            code[i] = @intFromEnum(Opcode.STOP);
        }
        
        const iterations = 1000;
        var total_time: i128 = 0;
        
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            var bytecode = try Bytecode(BytecodeConfig{}).init(allocator, &code);
            defer bytecode.deinit();
            const end = std.time.nanoTimestamp();
            total_time += end - start;
        }
        
        const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, iterations) / 1_000_000.0;
        std.debug.print("Fusion candidates (999 bytes): {d:.3}ms avg over {} iterations\n", .{ avg_time, iterations });
    }
    
    // Test 3: Load ERC20 if available
    {
        const file = std.fs.cwd().openFile("bench/cases/erc20-transfer/bytecode.txt", .{}) catch |err| {
            std.debug.print("Skipping ERC20 benchmark (file not found): {}\n", .{err});
            return;
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);
        
        // Parse hex
        const hex_start: usize = if (std.mem.startsWith(u8, content, "0x")) 2 else 0;
        const hex_content = std.mem.trim(u8, content[hex_start..], " \n\r\t");
        
        var bytecode_data = try allocator.alloc(u8, hex_content.len / 2);
        defer allocator.free(bytecode_data);
        
        var idx: usize = 0;
        while (idx < hex_content.len) : (idx += 2) {
            const byte = try std.fmt.parseInt(u8, hex_content[idx..idx + 2], 16);
            bytecode_data[idx / 2] = byte;
        }
        
        std.debug.print("\nERC20 bytecode size: {} bytes\n", .{bytecode_data.len});
        
        const iterations = 100;
        var total_time: i128 = 0;
        
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            var bytecode = Bytecode(BytecodeConfig{}).init(allocator, bytecode_data) catch |err| {
                std.debug.print("ERC20 bytecode validation failed: {}\n", .{err});
                return;
            };
            defer bytecode.deinit();
            const end = std.time.nanoTimestamp();
            total_time += end - start;
        }
        
        const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, iterations) / 1_000_000.0;
        std.debug.print("ERC20 analysis: {d:.3}ms avg over {} iterations\n", .{ avg_time, iterations });
    }
    
    // Test 4: SnailTracer
    {
        const file = std.fs.cwd().openFile("bench/cases/snailtracer/bytecode.txt", .{}) catch |err| {
            std.debug.print("Skipping SnailTracer benchmark (file not found): {}\n", .{err});
            std.debug.print("\n✅ Benchmarks completed!\n", .{});
            return;
        };
        defer file.close();
        
        const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // 10MB max
        defer allocator.free(content);
        
        // Parse hex
        const hex_start: usize = if (std.mem.startsWith(u8, content, "0x")) 2 else 0;
        const hex_content = std.mem.trim(u8, content[hex_start..], " \n\r\t");
        
        var bytecode_data = try allocator.alloc(u8, hex_content.len / 2);
        defer allocator.free(bytecode_data);
        
        var idx: usize = 0;
        while (idx < hex_content.len) : (idx += 2) {
            const byte = try std.fmt.parseInt(u8, hex_content[idx..idx + 2], 16);
            bytecode_data[idx / 2] = byte;
        }
        
        std.debug.print("\nSnailTracer bytecode size: {} bytes\n", .{bytecode_data.len});
        
        const iterations = 10; // Fewer iterations for large bytecode
        var total_time: i128 = 0;
        
        for (0..iterations) |_| {
            const start = std.time.nanoTimestamp();
            var bytecode = Bytecode(BytecodeConfig{}).init(allocator, bytecode_data) catch |err| {
                std.debug.print("SnailTracer bytecode validation failed: {}\n", .{err});
                break;
            };
            defer bytecode.deinit();
            const end = std.time.nanoTimestamp();
            total_time += end - start;
        }
        
        if (total_time > 0) {
            const avg_time = @as(f64, @floatFromInt(total_time)) / @as(f64, iterations) / 1_000_000.0;
            std.debug.print("SnailTracer analysis: {d:.3}ms avg over {} iterations\n", .{ avg_time, iterations });
        }
    }
    
    std.debug.print("\n✅ Benchmarks completed!\n", .{});
}
