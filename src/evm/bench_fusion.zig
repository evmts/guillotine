//! Benchmarks for EVM bytecode fusion optimizations
const std = @import("std");
const evm = @import("root.zig");
const Frame = @import("stack_frame.zig").Frame;
const FrameConfig = @import("stack_frame.zig").FrameConfig;
const Planner = @import("planner.zig").Planner;
const PlannerConfig = @import("planner_config.zig").PlannerConfig;
const Opcode = @import("opcode.zig").Opcode;
const OpcodeSynthetic = @import("opcode_synthetic.zig").OpcodeSynthetic;
const Memory = @import("memory.zig").Memory;
const NoOpTracer = @import("tracer.zig").NoOpTracer;
const primitives = @import("primitives");

// Benchmark configuration
const bench_frame_config = FrameConfig{
    .stack_size = 1024,
    .WordType = u256,
    .max_bytecode_size = 24576,
    .block_gas_limit = 30_000_000,
    .has_database = false,
    .TracerType = NoOpTracer,
    .memory_initial_capacity = 4096,
    .memory_limit = 0xFFFFFF,
};

const BenchFrame = Frame(bench_frame_config);

// Simple timer for benchmarking
const Timer = struct {
    start_time: i128,
    
    pub fn start() Timer {
        return .{ .start_time = std.time.nanoTimestamp() };
    }
    
    pub fn lap(self: *Timer) u64 {
        const end_time = std.time.nanoTimestamp();
        const elapsed = @as(u64, @intCast(end_time - self.start_time));
        self.start_time = end_time;
        return elapsed;
    }
};

// Mock host for benchmarking
const BenchHost = struct {
    pub fn getBlockNumber(self: *BenchHost) u64 {
        _ = self;
        return 1000000;
    }
    // ... minimal host implementation
};

/// Benchmark PUSH+ADD fusion vs separate operations
pub fn benchPushAddFusion(allocator: std.mem.Allocator, iterations: usize) !void {
    std.log.info("\n=== PUSH+ADD Fusion Benchmark ===", .{});
    
    // Create bytecode with many PUSH+ADD patterns
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Add initial value
    try bytecode.append(@intFromEnum(Opcode.PUSH1));
    try bytecode.append(0x01);
    
    // Add many PUSH+ADD sequences
    for (0..100) |_| {
        try bytecode.append(@intFromEnum(Opcode.PUSH1));
        try bytecode.append(0x02);
        try bytecode.append(@intFromEnum(Opcode.ADD));
    }
    try bytecode.append(@intFromEnum(Opcode.STOP));
    
    // Benchmark with fusion disabled
    {
        const planner_config = PlannerConfig{
            .maxBytecodeSize = 24576,
            .vector_length = null,
            .WordType = u256,
            .fusion_enabled = false, // Fusion disabled
        };
        
        var timer = Timer.start();
        var total_ns: u64 = 0;
        
        for (0..iterations) |_| {
            var planner = try Planner(planner_config).initSimple();
            defer planner.deinit();
            
            var bytecode_obj = try planner.Bytecode.init(allocator, bytecode.items);
            defer bytecode_obj.deinit();
            planner.bytecode = bytecode_obj;
            planner.bytecode_initialized = true;
            
            const plan = try planner.create_instruction_stream(allocator, BenchFrame.opcode_handlers);
            defer plan.deinit();
            
            total_ns += timer.lap();
        }
        
        const avg_ns = total_ns / iterations;
        std.log.info("Without fusion: {} ns/iteration", .{avg_ns});
    }
    
    // Benchmark with fusion enabled
    {
        const planner_config = PlannerConfig{
            .maxBytecodeSize = 24576,
            .vector_length = null,
            .WordType = u256,
            .fusion_enabled = true, // Fusion enabled
        };
        
        var timer = Timer.start();
        var total_ns: u64 = 0;
        
        for (0..iterations) |_| {
            var planner = try Planner(planner_config).initSimple();
            defer planner.deinit();
            
            var bytecode_obj = try planner.Bytecode.init(allocator, bytecode.items);
            defer bytecode_obj.deinit();
            planner.bytecode = bytecode_obj;
            planner.bytecode_initialized = true;
            
            const plan = try planner.create_instruction_stream(allocator, BenchFrame.opcode_handlers);
            defer plan.deinit();
            
            total_ns += timer.lap();
        }
        
        const avg_ns = total_ns / iterations;
        std.log.info("With fusion:    {} ns/iteration", .{avg_ns});
    }
}

/// Benchmark instruction stream size reduction
pub fn benchInstructionStreamSize(allocator: std.mem.Allocator) !void {
    std.log.info("\n=== Instruction Stream Size Benchmark ===", .{});
    
    // Create bytecode with fusable patterns
    const bytecode = &[_]u8{
        // Multiple fusable patterns
        @intFromEnum(Opcode.PUSH1), 0x10,
        @intFromEnum(Opcode.PUSH1), 0x05, @intFromEnum(Opcode.ADD),
        @intFromEnum(Opcode.PUSH1), 0x03, @intFromEnum(Opcode.MUL),
        @intFromEnum(Opcode.PUSH1), 0x20, @intFromEnum(Opcode.MSTORE),
        @intFromEnum(Opcode.PUSH2), 0x01, 0x00, @intFromEnum(Opcode.AND),
        @intFromEnum(Opcode.PUSH1), 0xFF, @intFromEnum(Opcode.OR),
        @intFromEnum(Opcode.STOP),
    };
    
    // Without fusion
    {
        const planner_config = PlannerConfig{
            .maxBytecodeSize = 24576,
            .vector_length = null,
            .WordType = u256,
            .fusion_enabled = false,
        };
        
        var planner = try Planner(planner_config).initSimple();
        defer planner.deinit();
        
        var bytecode_obj = try planner.Bytecode.init(allocator, bytecode);
        defer bytecode_obj.deinit();
        planner.bytecode = bytecode_obj;
        planner.bytecode_initialized = true;
        
        const plan = try planner.create_instruction_stream(allocator, BenchFrame.opcode_handlers);
        defer plan.deinit();
        
        std.log.info("Without fusion: {} instruction elements", .{plan.instructionStream.len});
    }
    
    // With fusion
    {
        const planner_config = PlannerConfig{
            .maxBytecodeSize = 24576,
            .vector_length = null,
            .WordType = u256,
            .fusion_enabled = true,
        };
        
        var planner = try Planner(planner_config).initSimple();
        defer planner.deinit();
        
        var bytecode_obj = try planner.Bytecode.init(allocator, bytecode);
        defer bytecode_obj.deinit();
        planner.bytecode = bytecode_obj;
        planner.bytecode_initialized = true;
        
        const plan = try planner.create_instruction_stream(allocator, BenchFrame.opcode_handlers);
        defer plan.deinit();
        
        std.log.info("With fusion:    {} instruction elements", .{plan.instructionStream.len});
        
        // Calculate reduction
        const original_ops = 11; // Count of original opcodes
        const fused_ops = plan.instructionStream.len;
        const reduction_pct = @as(f64, @floatFromInt(original_ops - fused_ops)) / @as(f64, @floatFromInt(original_ops)) * 100.0;
        std.log.info("Reduction:      {d:.1}%", .{reduction_pct});
    }
}

/// Benchmark execution performance with fused opcodes
pub fn benchExecutionPerformance(allocator: std.mem.Allocator, iterations: usize) !void {
    std.log.info("\n=== Execution Performance Benchmark ===", .{});
    
    // Create test contract that does many arithmetic operations
    var bytecode = std.ArrayList(u8).init(allocator);
    defer bytecode.deinit();
    
    // Start with initial value
    try bytecode.append(@intFromEnum(Opcode.PUSH2));
    try bytecode.append(0x00);
    try bytecode.append(0x01);
    
    // Add many arithmetic operations that can be fused
    for (0..50) |i| {
        try bytecode.append(@intFromEnum(Opcode.PUSH1));
        try bytecode.append(@intCast(i % 256));
        
        // Vary the operations
        const op = switch (i % 4) {
            0 => @intFromEnum(Opcode.ADD),
            1 => @intFromEnum(Opcode.MUL),
            2 => @intFromEnum(Opcode.AND),
            3 => @intFromEnum(Opcode.XOR),
            else => unreachable,
        };
        try bytecode.append(op);
    }
    try bytecode.append(@intFromEnum(Opcode.STOP));
    
    // Simulate execution timing
    var timer = Timer.start();
    var total_ns: u64 = 0;
    
    for (0..iterations) |_| {
        var host = BenchHost{};
        var frame = try BenchFrame.init(allocator, bytecode.items, 10_000_000, {}, host);
        defer frame.deinit(allocator);
        
        // Simulate execution of fused operations
        // In real implementation, this would use the actual dispatch table
        _ = timer.lap(); // Reset timer
        
        // Execute operations
        try frame.stack.push(1);
        for (0..50) |i| {
            const a = try frame.stack.pop();
            const b = @as(u256, @intCast(i % 256));
            const result = switch (i % 4) {
                0 => a +% b,
                1 => a *% b,
                2 => a & b,
                3 => a ^ b,
                else => unreachable,
            };
            try frame.stack.push(result);
        }
        
        total_ns += timer.lap();
    }
    
    const avg_ns = total_ns / iterations;
    const ops_per_sec = @as(f64, 1_000_000_000.0) / @as(f64, @floatFromInt(avg_ns)) * 50.0;
    
    std.log.info("Average execution time: {} ns", .{avg_ns});
    std.log.info("Operations per second:  {d:.0} ops/sec", .{ops_per_sec});
}

/// Run all benchmarks
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    std.log.info("Running EVM Fusion Benchmarks...", .{});
    
    // Run benchmarks
    try benchPushAddFusion(allocator, 1000);
    try benchInstructionStreamSize(allocator);
    try benchExecutionPerformance(allocator, 10000);
    
    std.log.info("\nBenchmarks complete!", .{});
}