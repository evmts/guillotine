const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();
    
    if (builtin.mode != .ReleaseFast) {
        try stdout.print("Warning: Run with -O ReleaseFast for accurate benchmarks\n", .{});
    }
    
    try stdout.print("\n=== Frame Cache Performance Benchmark ===\n\n", .{});
    
    // Benchmark hot field access patterns
    try benchmarkHotFieldAccess(allocator);
    
    // Benchmark mixed field access patterns
    try benchmarkMixedFieldAccess(allocator);
    
    // Benchmark cache miss patterns
    try benchmarkCacheMissPattern(allocator);
}

// Simulated Frame struct (before optimization)
const OldFrame = struct {
    // Poor layout - hot fields scattered
    gas_remaining: u64,
    pc: usize,
    contract: *Contract,
    allocator: std.mem.Allocator,
    stop: bool,
    is_static: bool,
    depth: u32,
    cost: u64,
    err: ?u32,
    input: []const u8,
    output: []const u8,
    op: []const u8,
    memory: Memory,
    stack: Stack,
    return_data: ReturnData,
};

// Optimized Frame struct (after optimization)
const NewFrame = struct {
    // Hot fields in first cache line
    pc: usize,
    gas_remaining: u64,
    stack: Stack,
    memory: Memory,
    contract: *Contract,
    
    // Warm fields in second cache line
    depth: u32,
    is_static: bool,
    stop: bool,
    _padding: [2]u8,
    allocator: std.mem.Allocator,
    cost: u64,
    err: ?u32,
    
    // Cold fields
    input: []const u8,
    output: []const u8,
    op: []const u8,
    return_data: ReturnData,
};

// Simplified versions of dependent types
const Contract = struct {
    code: []const u8,
    address: [20]u8,
    gas: u64,
};

const Memory = struct {
    data: []u8,
    size: usize,
    capacity: usize,
};

const Stack = struct {
    items: [1024]Word,
    size: u32,
};

const ReturnData = struct {
    data: []u8,
};

const Word = u128; // Simplified for benchmark

// Benchmark hot field access (pc, gas, stack operations)
fn benchmarkHotFieldAccess(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Hot Field Access Pattern (simulating opcode execution):\n", .{});
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = try allocator.alloc(u8, 1024);
    defer allocator.free(memory_data);
    
    var old_frame = OldFrame{
        .gas_remaining = 1000000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .memory = Memory{ .data = memory_data, .size = 0, .capacity = 1024 },
        .stack = Stack{ .items = undefined, .size = 0 },
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    const new_memory_data = try allocator.alloc(u8, 1024);
    defer allocator.free(new_memory_data);
    
    var new_frame = NewFrame{
        .pc = 0,
        .gas_remaining = 1000000,
        .stack = Stack{ .items = undefined, .size = 0 },
        .memory = Memory{ .data = new_memory_data, .size = 0, .capacity = 1024 },
        .contract = &contract,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = allocator,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    const iterations = 10_000_000;
    const warmup = 1_000_000;
    
    // Warmup
    for (0..warmup) |_| {
        simulateOpcodeExecution(&old_frame);
        simulateOpcodeExecution(&new_frame);
    }
    
    // Benchmark old layout
    var timer = try std.time.Timer.start();
    
    for (0..iterations) |_| {
        simulateOpcodeExecution(&old_frame);
    }
    
    const old_time = timer.read();
    
    // Benchmark new layout
    timer.reset();
    
    for (0..iterations) |_| {
        simulateOpcodeExecution(&new_frame);
    }
    
    const new_time = timer.read();
    
    // Results
    try stdout.print("  Old layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(old_time)) / 1_000_000});
    try stdout.print("  New layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(new_time)) / 1_000_000});
    try stdout.print("  Speedup: {d:.2}x\n\n", .{@as(f64, @floatFromInt(old_time)) / @as(f64, @floatFromInt(new_time))});
}

// Simulate typical opcode execution pattern
fn simulateOpcodeExecution(frame: anytype) void {
    // Typical hot path: check gas, advance PC, stack operation
    if (frame.gas_remaining > 3) {
        frame.gas_remaining -= 3;
    }
    
    frame.pc += 1;
    
    if (frame.stack.size < 1024) {
        frame.stack.items[frame.stack.size] = @as(Word, frame.pc);
        frame.stack.size += 1;
    }
    
    if (frame.pc < frame.contract.code.len) {
        const opcode = frame.contract.code[frame.pc];
        _ = opcode;
    }
}

// Benchmark mixed access pattern
fn benchmarkMixedFieldAccess(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Mixed Field Access Pattern (hot + warm fields):\n", .{});
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = try allocator.alloc(u8, 1024);
    defer allocator.free(memory_data);
    
    var old_frame = OldFrame{
        .gas_remaining = 1000000,
        .pc = 0,
        .contract = &contract,
        .allocator = allocator,
        .stop = false,
        .is_static = false,
        .depth = 0,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .memory = Memory{ .data = memory_data, .size = 0, .capacity = 1024 },
        .stack = Stack{ .items = undefined, .size = 0 },
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    const new_memory_data = try allocator.alloc(u8, 1024);
    defer allocator.free(new_memory_data);
    
    var new_frame = NewFrame{
        .pc = 0,
        .gas_remaining = 1000000,
        .stack = Stack{ .items = undefined, .size = 0 },
        .memory = Memory{ .data = new_memory_data, .size = 0, .capacity = 1024 },
        .contract = &contract,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = allocator,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    const iterations = 5_000_000;
    
    // Benchmark old layout
    var timer = try std.time.Timer.start();
    
    for (0..iterations) |i| {
        simulateMixedAccess(&old_frame, i);
    }
    
    const old_time = timer.read();
    
    // Benchmark new layout
    timer.reset();
    
    for (0..iterations) |i| {
        simulateMixedAccess(&new_frame, i);
    }
    
    const new_time = timer.read();
    
    // Results
    try stdout.print("  Old layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(old_time)) / 1_000_000});
    try stdout.print("  New layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(new_time)) / 1_000_000});
    try stdout.print("  Speedup: {d:.2}x\n\n", .{@as(f64, @floatFromInt(old_time)) / @as(f64, @floatFromInt(new_time))});
}

// Simulate mixed access pattern
fn simulateMixedAccess(frame: anytype, iteration: usize) void {
    // Hot fields
    frame.pc += 1;
    frame.gas_remaining -= 5;
    
    // Warm fields (every 10 iterations)
    if (iteration % 10 == 0) {
        frame.cost = 10;
        if (!frame.is_static) {
            frame.depth += 1;
        }
    }
    
    // Stack operations
    if (frame.stack.size < 1024) {
        frame.stack.items[frame.stack.size] = @as(Word, iteration);
        frame.stack.size += 1;
    }
}

// Benchmark cache miss pattern
fn benchmarkCacheMissPattern(allocator: std.mem.Allocator) !void {
    const stdout = std.io.getStdOut().writer();
    
    try stdout.print("Cache Miss Pattern (accessing cold fields):\n", .{});
    
    // Create many frames to ensure cache misses
    const frame_count = 1000;
    
    var old_frames = try allocator.alloc(OldFrame, frame_count);
    defer allocator.free(old_frames);
    
    var new_frames = try allocator.alloc(NewFrame, frame_count);
    defer allocator.free(new_frames);
    
    // Initialize frames
    for (0..frame_count) |i| {
        var contract = Contract{
            .code = &[_]u8{0x60},
            .address = [_]u8{@intCast(i)} ** 20,
            .gas = 1000000,
        };
        
        old_frames[i] = OldFrame{
            .gas_remaining = 1000000,
            .pc = i,
            .contract = &contract,
            .allocator = allocator,
            .stop = false,
            .is_static = false,
            .depth = @intCast(i),
            .cost = 0,
            .err = null,
            .input = &[_]u8{},
            .output = &[_]u8{},
            .op = &[_]u8{},
            .memory = Memory{ .data = &[_]u8{}, .size = 0, .capacity = 0 },
            .stack = Stack{ .items = undefined, .size = 0 },
            .return_data = ReturnData{ .data = &[_]u8{} },
        };
        
        new_frames[i] = NewFrame{
            .pc = i,
            .gas_remaining = 1000000,
            .stack = Stack{ .items = undefined, .size = 0 },
            .memory = Memory{ .data = &[_]u8{}, .size = 0, .capacity = 0 },
            .contract = &contract,
            .depth = @intCast(i),
            .is_static = false,
            .stop = false,
            ._padding = .{ 0, 0 },
            .allocator = allocator,
            .cost = 0,
            .err = null,
            .input = &[_]u8{},
            .output = &[_]u8{},
            .op = &[_]u8{},
            .return_data = ReturnData{ .data = &[_]u8{} },
        };
    }
    
    const iterations = 100_000;
    
    // Benchmark old layout
    var timer = try std.time.Timer.start();
    var sum: u64 = 0;
    
    for (0..iterations) |i| {
        const idx = i % frame_count;
        sum += accessAllFields(&old_frames[idx]);
    }
    
    const old_time = timer.read();
    
    // Benchmark new layout
    timer.reset();
    sum = 0;
    
    for (0..iterations) |i| {
        const idx = i % frame_count;
        sum += accessAllFields(&new_frames[idx]);
    }
    
    const new_time = timer.read();
    
    // Results
    try stdout.print("  Old layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(old_time)) / 1_000_000});
    try stdout.print("  New layout: {d:.2} ms\n", .{@as(f64, @floatFromInt(new_time)) / 1_000_000});
    try stdout.print("  Speedup: {d:.2}x\n\n", .{@as(f64, @floatFromInt(old_time)) / @as(f64, @floatFromInt(new_time))});
    
    // Prevent optimization
    std.debug.assert(sum > 0);
}

// Access all fields to measure cache behavior
fn accessAllFields(frame: anytype) u64 {
    var sum: u64 = 0;
    
    // Hot fields
    sum += frame.pc;
    sum += frame.gas_remaining;
    sum += frame.stack.size;
    
    // Warm fields
    sum += frame.depth;
    sum += if (frame.is_static) 1 else 0;
    sum += frame.cost;
    
    // Cold fields
    sum += frame.input.len;
    sum += frame.output.len;
    
    return sum;
}

test "Frame cache benchmark" {
    try main();
}