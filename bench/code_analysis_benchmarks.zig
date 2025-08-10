const std = @import("std");
const Allocator = std.mem.Allocator;
const timing = @import("timing.zig");
const BenchmarkSuite = timing.BenchmarkSuite;
const BenchmarkConfig = timing.BenchmarkConfig;

// Import EVM components
const primitives = @import("primitives");
const Address = primitives.Address;
const CodeAnalysis = @import("evm").CodeAnalysis;
const BitVec = @import("evm").BitVec;

/// Code analysis and JUMPDEST validation benchmarks
pub const CodeAnalysisBenchmarks = struct {
    allocator: Allocator,
    small_bytecode: []const u8,
    medium_bytecode: []const u8,
    large_bytecode: []const u8,
    jumpdest_heavy_bytecode: []const u8,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        // Small contract (< 1KB)
        const small = [_]u8{
            0x60, 0x80, 0x60, 0x40, 0x52, 0x34, 0x80, 0x15,
            0x61, 0x00, 0x10, 0x57, 0x60, 0x00, 0x80, 0xfd,
            0x5b, 0x50, 0x60, 0x04, 0x36, 0x10, 0x61, 0x00,
            0x49, 0x57, 0x60, 0x00, 0x35, 0x60, 0xe0, 0x1c,
            0x80, 0x63, 0xa9, 0x05, 0x9c, 0xbb, 0x14, 0x61,
            0x00, 0x4e, 0x57, 0x80, 0x63, 0xdd, 0x62, 0xed,
            0x3e, 0x14, 0x61, 0x00, 0x86, 0x57, 0x5b, 0x60,
            0x00, 0x80, 0xfd, 0x5b, 0x34, 0x80, 0x15, 0x61,
        };

        // Medium contract (~5KB) - simulate complex DeFi contract
        const medium = try allocator.alloc(u8, 5000);
        for (medium, 0..) |*byte, idx| {
            // Pattern that includes JUMPDESTs and actual opcodes
            if (idx % 50 == 0) {
                byte.* = 0x5b; // JUMPDEST
            } else if (idx % 10 == 0) {
                byte.* = 0x60; // PUSH1
            } else if (idx % 15 == 0) {
                byte.* = 0x56; // JUMP
            } else {
                byte.* = @as(u8, @intCast(idx % 256));
            }
        }

        // Large contract (~20KB) - simulate very complex contract
        const large = try allocator.alloc(u8, 20000);
        for (large, 0..) |*byte, idx| {
            if (idx % 100 == 0) {
                byte.* = 0x5b; // JUMPDEST
            } else if (idx % 20 == 0) {
                byte.* = 0x60; // PUSH1
            } else if (idx % 30 == 0) {
                byte.* = 0x56; // JUMP
            } else {
                byte.* = @as(u8, @intCast(idx % 256));
            }
        }

        // JUMPDEST-heavy contract for worst-case analysis
        const jumpdest_heavy = try allocator.alloc(u8, 2000);
        for (jumpdest_heavy, 0..) |*byte, idx| {
            if (idx % 5 == 0) {
                byte.* = 0x5b; // JUMPDEST - every 5th byte
            } else if (idx % 3 == 0) {
                byte.* = 0x60; // PUSH1
            } else {
                byte.* = 0x01; // ADD
            }
        }

        return Self{
            .allocator = allocator,
            .small_bytecode = try allocator.dupe(u8, &small),
            .medium_bytecode = medium,
            .large_bytecode = large,
            .jumpdest_heavy_bytecode = jumpdest_heavy,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.small_bytecode);
        self.allocator.free(self.medium_bytecode);
        self.allocator.free(self.large_bytecode);
        self.allocator.free(self.jumpdest_heavy_bytecode);
    }

    /// Benchmark small contract analysis
    pub fn analyzeSmallContract(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.small_bytecode);
        defer analysis.deinit(self.allocator);
    }

    /// Benchmark medium contract analysis
    pub fn analyzeMediumContract(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.medium_bytecode);
        defer analysis.deinit(self.allocator);
    }

    /// Benchmark large contract analysis
    pub fn analyzeLargeContract(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.large_bytecode);
        defer analysis.deinit(self.allocator);
    }

    /// Benchmark JUMPDEST-heavy contract analysis
    pub fn analyzeJumpdestHeavyContract(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.jumpdest_heavy_bytecode);
        defer analysis.deinit(self.allocator);
    }

    /// Benchmark JUMPDEST validation on small contract
    pub fn validateJumpdestsSmall(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.small_bytecode);
        defer analysis.deinit(self.allocator);

        // Test multiple JUMPDEST validations
        var i: usize = 0;
        while (i < self.small_bytecode.len) : (i += 1) {
            _ = analysis.isValidJumpdest(i);
        }
    }

    /// Benchmark JUMPDEST validation on large contract
    pub fn validateJumpdestsLarge(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.large_bytecode);
        defer analysis.deinit(self.allocator);

        // Test validation at various positions
        var i: usize = 0;
        while (i < 1000) : (i += 20) { // Sample positions
            _ = analysis.isValidJumpdest(i);
        }
    }

    /// Benchmark bitvec operations for code analysis
    pub fn bitvecOperations(self: *Self) !void {
        var bitvec = try BitVec.init(self.allocator, self.medium_bytecode.len);
        defer bitvec.deinit(self.allocator);

        // Set bits for valid code positions
        var i: usize = 0;
        while (i < self.medium_bytecode.len) : (i += 1) {
            if (self.medium_bytecode[i] == 0x5b) { // JUMPDEST
                try bitvec.set(i);
            }
        }

        // Query bits
        i = 0;
        while (i < self.medium_bytecode.len) : (i += 10) {
            _ = try bitvec.is_set(i);
        }
    }

    /// Benchmark code bitmap creation
    pub fn createCodeBitmap(self: *Self) !void {
        const bitmap = try BitVec.code_bitmap(self.allocator, self.medium_bytecode);
        defer bitmap.deinit(self.allocator);
    }

    /// Benchmark repeated analysis (testing cache efficiency)
    pub fn repeatedAnalysis(self: *Self) !void {
        // Analyze the same bytecode multiple times
        var i: u32 = 0;
        while (i < 10) : (i += 1) {
            const analysis = try CodeAnalysis.analyze(self.allocator, self.small_bytecode);
            defer analysis.deinit(self.allocator);
        }
    }

    /// Benchmark worst-case JUMPDEST scenario
    pub fn worstCaseJumpdests(self: *Self) !void {
        const analysis = try CodeAnalysis.analyze(self.allocator, self.jumpdest_heavy_bytecode);
        defer analysis.deinit(self.allocator);

        // Validate every position (worst case)
        var i: usize = 0;
        while (i < self.jumpdest_heavy_bytecode.len) : (i += 1) {
            _ = analysis.isValidJumpdest(i);
        }
    }

    /// Benchmark analysis memory usage patterns
    pub fn analysisMemoryPattern(self: *Self) !void {
        var analyses: [5]CodeAnalysis = undefined;

        // Create multiple analyses
        var i: usize = 0;
        while (i < analyses.len) : (i += 1) {
            analyses[i] = try CodeAnalysis.analyze(self.allocator, self.medium_bytecode);
        }

        // Use them
        for (&analyses) |*analysis| {
            _ = analysis.isValidJumpdest(100);
        }

        // Cleanup
        for (&analyses) |*analysis| {
            analysis.deinit(self.allocator);
        }
    }
};

/// Run all code analysis benchmarks
pub fn runCodeAnalysisBenchmarks(allocator: Allocator) !void {
    var suite = BenchmarkSuite.init(allocator);
    defer suite.deinit();

    var benchmarks = try CodeAnalysisBenchmarks.init(allocator);
    defer benchmarks.deinit();

    std.debug.print("\n=== Code Analysis Benchmarks ===\n", .{});

    // Basic analysis benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "analyze_small_contract",
        .iterations = 1000,
        .warmup_iterations = 100,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.analyzeSmallContract();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "analyze_medium_contract",
        .iterations = 200,
        .warmup_iterations = 20,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.analyzeMediumContract();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "analyze_large_contract",
        .iterations = 50,
        .warmup_iterations = 5,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.analyzeLargeContract();
        }
    }{ .bench = &benchmarks });

    // JUMPDEST validation benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "validate_jumpdests_small",
        .iterations = 500,
        .warmup_iterations = 50,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.validateJumpdestsSmall();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "validate_jumpdests_large",
        .iterations = 100,
        .warmup_iterations = 10,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.validateJumpdestsLarge();
        }
    }{ .bench = &benchmarks });

    // BitVec operations benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "bitvec_operations",
        .iterations = 200,
        .warmup_iterations = 20,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.bitvecOperations();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "create_code_bitmap",
        .iterations = 200,
        .warmup_iterations = 20,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.createCodeBitmap();
        }
    }{ .bench = &benchmarks });

    // Cache and memory pattern benchmarks
    try suite.benchmark(BenchmarkConfig{
        .name = "repeated_analysis",
        .iterations = 100,
        .warmup_iterations = 10,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.repeatedAnalysis();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "worst_case_jumpdests",
        .iterations = 50,
        .warmup_iterations = 5,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.worstCaseJumpdests();
        }
    }{ .bench = &benchmarks });

    try suite.benchmark(BenchmarkConfig{
        .name = "analysis_memory_pattern",
        .iterations = 100,
        .warmup_iterations = 10,
    }, struct {
        bench: *CodeAnalysisBenchmarks,
        fn run(self: @This()) !void {
            try self.bench.analysisMemoryPattern();
        }
    }{ .bench = &benchmarks });

    std.debug.print("=== Code Analysis Benchmarks Complete ===\n\n", .{});
}
