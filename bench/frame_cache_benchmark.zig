const std = @import("std");
const root = @import("root.zig");
const Allocator = std.mem.Allocator;

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

// Simulate cache miss pattern
fn simulateCacheMissPattern(frame: anytype, iteration: usize) void {
    // Force cache misses by accessing cold fields
    if (iteration % 100 == 0) {
        frame.input = &[_]u8{};
        frame.output = &[_]u8{};
        frame.return_data.data = &[_]u8{};
    }
    
    // Also access hot fields to make pattern realistic
    frame.pc += 1;
    frame.gas_remaining -= 3;
}

/// Benchmark hot field access with old frame layout
pub fn zbench_hot_field_old_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var old_frame = OldFrame{
        .gas_remaining = 1000000,
        .pc = 0,
        .contract = &contract,
        .allocator = gpa_allocator,
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
    
    // Run iterations
    for (0..1000) |_| {
        simulateOpcodeExecution(&old_frame);
    }
}

/// Benchmark hot field access with new frame layout
pub fn zbench_hot_field_new_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var new_frame = NewFrame{
        .pc = 0,
        .gas_remaining = 1000000,
        .stack = Stack{ .items = undefined, .size = 0 },
        .memory = Memory{ .data = memory_data, .size = 0, .capacity = 1024 },
        .contract = &contract,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = gpa_allocator,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    // Run iterations
    for (0..1000) |_| {
        simulateOpcodeExecution(&new_frame);
    }
}

/// Benchmark mixed field access with old frame layout
pub fn zbench_mixed_field_old_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var old_frame = OldFrame{
        .gas_remaining = 1000000,
        .pc = 0,
        .contract = &contract,
        .allocator = gpa_allocator,
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
    
    // Run iterations
    for (0..1000) |i| {
        simulateMixedAccess(&old_frame, i);
    }
}

/// Benchmark mixed field access with new frame layout
pub fn zbench_mixed_field_new_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var new_frame = NewFrame{
        .pc = 0,
        .gas_remaining = 1000000,
        .stack = Stack{ .items = undefined, .size = 0 },
        .memory = Memory{ .data = memory_data, .size = 0, .capacity = 1024 },
        .contract = &contract,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = gpa_allocator,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    // Run iterations
    for (0..1000) |i| {
        simulateMixedAccess(&new_frame, i);
    }
}

/// Benchmark cache miss pattern with old frame layout
pub fn zbench_cache_miss_old_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var old_frame = OldFrame{
        .gas_remaining = 1000000,
        .pc = 0,
        .contract = &contract,
        .allocator = gpa_allocator,
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
    
    // Run iterations
    for (0..1000) |i| {
        simulateCacheMissPattern(&old_frame, i);
    }
}

/// Benchmark cache miss pattern with new frame layout
pub fn zbench_cache_miss_new_layout(allocator: Allocator) void {
    // Use GPA for the benchmark
    var gpa = std.heap.GeneralPurposeAllocator(.{}){}; 
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();
    
    // Setup
    var contract = Contract{
        .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01},
        .address = [_]u8{0} ** 20,
        .gas = 1000000,
    };
    
    const memory_data = gpa_allocator.alloc(u8, 1024) catch return;
    defer gpa_allocator.free(memory_data);
    
    var new_frame = NewFrame{
        .pc = 0,
        .gas_remaining = 1000000,
        .stack = Stack{ .items = undefined, .size = 0 },
        .memory = Memory{ .data = memory_data, .size = 0, .capacity = 1024 },
        .contract = &contract,
        .depth = 0,
        .is_static = false,
        .stop = false,
        ._padding = .{ 0, 0 },
        .allocator = gpa_allocator,
        .cost = 0,
        .err = null,
        .input = &[_]u8{},
        .output = &[_]u8{},
        .op = &[_]u8{},
        .return_data = ReturnData{ .data = &[_]u8{} },
    };
    
    // Run iterations
    for (0..1000) |i| {
        simulateCacheMissPattern(&new_frame, i);
    }
}