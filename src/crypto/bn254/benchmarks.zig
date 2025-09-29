// Comprehensive BN254 Pairing Library Benchmark Suite
// High-quality benchmarking without external dependencies
// Provides statistical analysis, performance tracking, and comparison capabilities

const std = @import("std");

// BN254 Implementation imports
const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const Fp12Mont = @import("Fp12Mont.zig");
const Fr = @import("Fr.zig").Fr;
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");
const pairing_mod = @import("pairing.zig");
const curve_parameters = @import("curve_parameters.zig");

// =============================================================================
// BENCHMARK CONFIGURATION
// =============================================================================

const BenchmarkConfig = struct {
    const fast_time_budget_ns: u64 = 1_000_000_000; // 1 second for fast operations
    const slow_time_budget_ns: u64 = 5_000_000_000; // 5 seconds for slow operations (pairings)
    const warmup_iterations: usize = 100;
    const min_iterations: usize = 1000;
    const statistical_confidence: f64 = 0.95;
};

// Operation sample size configuration for fast operations that need loops
const OperationSampleSizes = struct {
    // Field operations - very fast, use large sample sizes
    fp_add: usize = 1000,
    fp_sub: usize = 1000,
    fp_mul: usize = 100,
    fp_square: usize = 100,
    fp_inv: usize = 1,

    // Fp2 operations
    fp2_add: usize = 500,
    fp2_sub: usize = 500,
    fp2_mul: usize = 50,
    fp2_square: usize = 50,
    fp2_inv: usize = 1,

    // Fp6 operations
    fp6_add: usize = 100,
    fp6_sub: usize = 100,
    fp6_mul: usize = 10,
    fp6_square: usize = 10,
    fp6_inv: usize = 1,

    // Fp12 operations
    fp12_add: usize = 50,
    fp12_sub: usize = 50,
    fp12_mul: usize = 5,
    fp12_square: usize = 5,
    fp12_inv: usize = 1,

    // Group operations
    g1_add: usize = 10,
    g1_double: usize = 10,
    g1_scalar_mul: usize = 1,

    g2_add: usize = 5,
    g2_double: usize = 5,
    g2_is_in_subgroup: usize = 5,
    g2_scalar_mul: usize = 1,

    // Pairing operations - always single
    pairing: usize = 1,
    miller_loop: usize = 1,
    final_exp: usize = 1,
};

const operation_sample_sizes = OperationSampleSizes{};

// =============================================================================
// SECURE RANDOM INPUT GENERATION
// =============================================================================

pub const SecureRandomGenerator = struct {
    rng: std.Random.DefaultPrng,

    pub fn init() SecureRandomGenerator {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch {
            seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
        };

        return SecureRandomGenerator{
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn randomU256(self: *SecureRandomGenerator) u256 {
        const random = self.rng.random();
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);
        return std.mem.readInt(u256, &bytes, .big);
    }

    pub fn randomFpMont(self: *SecureRandomGenerator) FpMont {
        return FpMont.init(self.randomU256());
    }

    pub fn randomFpMontNonZero(self: *SecureRandomGenerator) FpMont {
        while (true) {
            const elem = self.randomFpMont();
            if (elem.value != 0) return elem;
        }
    }

    pub fn randomFp2Mont(self: *SecureRandomGenerator) Fp2Mont {
        return Fp2Mont.init_from_int(self.randomU256(), self.randomU256());
    }

    pub fn randomFp2MontNonZero(self: *SecureRandomGenerator) Fp2Mont {
        while (true) {
            const elem = self.randomFp2Mont();
            if (!(elem.u0.value == 0 and elem.u1.value == 0)) return elem;
        }
    }

    pub fn randomFp6Mont(self: *SecureRandomGenerator) Fp6Mont {
        return Fp6Mont.init_from_int(self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256());
    }

    pub fn randomFp6MontNonZero(self: *SecureRandomGenerator) Fp6Mont {
        while (true) {
            const elem = self.randomFp6Mont();
            if (!(elem.v0.u0.value == 0 and elem.v0.u1.value == 0 and
                elem.v1.u0.value == 0 and elem.v1.u1.value == 0 and
                elem.v2.u0.value == 0 and elem.v2.u1.value == 0)) return elem;
        }
    }

    pub fn randomFp12Mont(self: *SecureRandomGenerator) Fp12Mont {
        return Fp12Mont.init_from_int(self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256());
    }

    pub fn randomFp12MontNonZero(self: *SecureRandomGenerator) Fp12Mont {
        while (true) {
            const elem = self.randomFp12Mont();
            if (!(elem.w0.v0.u0.value == 0 and elem.w0.v0.u1.value == 0 and
                elem.w0.v1.u0.value == 0 and elem.w0.v1.u1.value == 0 and
                elem.w0.v2.u0.value == 0 and elem.w0.v2.u1.value == 0 and
                elem.w1.v0.u0.value == 0 and elem.w1.v0.u1.value == 0 and
                elem.w1.v1.u0.value == 0 and elem.w1.v1.u1.value == 0 and
                elem.w1.v2.u0.value == 0 and elem.w1.v2.u1.value == 0)) return elem;
        }
    }

    pub fn randomFr(self: *SecureRandomGenerator) Fr {
        return Fr.init(self.randomU256());
    }

    pub fn randomFrNonZero(self: *SecureRandomGenerator) Fr {
        while (true) {
            const elem = self.randomFr();
            if (elem.value != 0) return elem;
        }
    }

    pub fn randomG1(self: *SecureRandomGenerator) G1 {
        const scalar = self.randomFr();
        return G1.GENERATOR.mul(&scalar);
    }

    pub fn randomG2(self: *SecureRandomGenerator) G2 {
        const scalar = self.randomFr();
        return G2.GENERATOR.mul(&scalar);
    }
};

// =============================================================================
// STATISTICAL ANALYSIS UTILITIES
// =============================================================================

pub const BenchmarkStats = struct {
    name: []const u8,
    samples: usize,
    mean_ns: f64,
    median_ns: f64,
    min_ns: u64,
    max_ns: u64,
    std_dev_ns: f64,
    p99_ns: f64,
    ops_per_sec: f64,
    total_time_ns: u64,
    confidence_interval_lower: f64,
    confidence_interval_upper: f64,

    fn formatTime(value_ns: f64) struct { value: f64, unit: []const u8 } {
        if (value_ns >= 1_000_000_000.0) {
            return .{ .value = value_ns / 1_000_000_000.0, .unit = "s" };
        } else if (value_ns >= 1_000_000.0) {
            return .{ .value = value_ns / 1_000_000.0, .unit = "ms" };
        } else if (value_ns >= 1_000.0) {
            return .{ .value = value_ns / 1_000.0, .unit = "μs" };
        } else {
            return .{ .value = value_ns, .unit = "ns" };
        }
    }

    pub fn format(self: BenchmarkStats) void {
        const mean_time = formatTime(self.mean_ns);
        const std_dev_time = formatTime(self.std_dev_ns);
        const p99_time = formatTime(self.p99_ns);
        const max_time = formatTime(@as(f64, @floatFromInt(self.max_ns)));

        // Format operations per second without scientific notation
        var ops_display: []const u8 = undefined;
        var ops_buffer: [32]u8 = undefined;

        if (self.ops_per_sec >= 1_000_000.0) {
            const ops_val = self.ops_per_sec / 1_000_000.0;
            ops_display = std.fmt.bufPrint(&ops_buffer, "{d:.1} M/s", .{ops_val}) catch "error";
        } else if (self.ops_per_sec >= 1_000.0) {
            const ops_val = self.ops_per_sec / 1_000.0;
            ops_display = std.fmt.bufPrint(&ops_buffer, "{d:.1} K/s", .{ops_val}) catch "error";
        } else {
            ops_display = std.fmt.bufPrint(&ops_buffer, "{d:.0} /s", .{self.ops_per_sec}) catch "error";
        }

        // Format time values avoiding scientific notation by using bufPrint
        var mean_buf: [16]u8 = undefined;
        var std_buf: [16]u8 = undefined;
        var p99_buf: [16]u8 = undefined;
        var max_buf: [16]u8 = undefined;

        const mean_str = if (mean_time.value >= 1000.0)
            std.fmt.bufPrint(&mean_buf, "{d} {s}", .{ @as(u32, @intFromFloat(@round(mean_time.value))), mean_time.unit }) catch "err"
        else if (mean_time.value >= 10.0)
            std.fmt.bufPrint(&mean_buf, "{d:.1} {s}", .{ mean_time.value, mean_time.unit }) catch "err"
        else
            std.fmt.bufPrint(&mean_buf, "{d:.2} {s}", .{ mean_time.value, mean_time.unit }) catch "err";

        const std_str = if (std_dev_time.value >= 1000.0)
            std.fmt.bufPrint(&std_buf, "{d} {s}", .{ @as(u32, @intFromFloat(@round(std_dev_time.value))), std_dev_time.unit }) catch "err"
        else if (std_dev_time.value >= 10.0)
            std.fmt.bufPrint(&std_buf, "{d:.1} {s}", .{ std_dev_time.value, std_dev_time.unit }) catch "err"
        else
            std.fmt.bufPrint(&std_buf, "{d:.2} {s}", .{ std_dev_time.value, std_dev_time.unit }) catch "err";

        const p99_str = if (p99_time.value >= 1000.0)
            std.fmt.bufPrint(&p99_buf, "{d} {s}", .{ @as(u32, @intFromFloat(@round(p99_time.value))), p99_time.unit }) catch "err"
        else if (p99_time.value >= 10.0)
            std.fmt.bufPrint(&p99_buf, "{d:.1} {s}", .{ p99_time.value, p99_time.unit }) catch "err"
        else
            std.fmt.bufPrint(&p99_buf, "{d:.2} {s}", .{ p99_time.value, p99_time.unit }) catch "err";

        const max_str = if (max_time.value >= 1000.0)
            std.fmt.bufPrint(&max_buf, "{d} {s}", .{ @as(u32, @intFromFloat(@round(max_time.value))), max_time.unit }) catch "err"
        else if (max_time.value >= 10.0)
            std.fmt.bufPrint(&max_buf, "{d:.1} {s}", .{ max_time.value, max_time.unit }) catch "err"
        else
            std.fmt.bufPrint(&max_buf, "{d:.2} {s}", .{ max_time.value, max_time.unit }) catch "err";

        // Color-code operation names by type
        const name_colored = if (std.mem.startsWith(u8, self.name, "Fp "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[92m{s}\x1b[0m", .{self.name}) catch self.name
        else if (std.mem.startsWith(u8, self.name, "Fp2 "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[94m{s}\x1b[0m", .{self.name}) catch self.name
        else if (std.mem.startsWith(u8, self.name, "Fp6 "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[96m{s}\x1b[0m", .{self.name}) catch self.name
        else if (std.mem.startsWith(u8, self.name, "Fp12 "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[95m{s}\x1b[0m", .{self.name}) catch self.name
        else if (std.mem.startsWith(u8, self.name, "G1 "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[93m{s}\x1b[0m", .{self.name}) catch self.name
        else if (std.mem.startsWith(u8, self.name, "G2 "))
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[91m{s}\x1b[0m", .{self.name}) catch self.name
        else
            std.fmt.allocPrint(std.heap.page_allocator, "\x1b[1;97m{s}\x1b[0m", .{self.name}) catch self.name;

        std.debug.print("\x1b[90m│\x1b[0m {s:<47} \x1b[90m│\x1b[0m \x1b[97m{s:>8}\x1b[0m \x1b[90m│\x1b[0m \x1b[90m{s:>8}\x1b[0m \x1b[90m│\x1b[0m \x1b[93m{s:>8}\x1b[0m \x1b[90m│\x1b[0m \x1b[91m{s:>8}\x1b[0m \x1b[90m│\x1b[0m \x1b[92m{s:>9}\x1b[0m \x1b[90m│\x1b[0m \x1b[96m{d:>6}\x1b[0m \x1b[90m│\x1b[0m\n", .{ name_colored, mean_str, std_str, p99_str, max_str, ops_display, self.samples });
    }
};

fn calculateStats(allocator: std.mem.Allocator, name: []const u8, measurements: []u64) !BenchmarkStats {
    std.mem.sort(u64, measurements, {}, std.sort.asc(u64));

    const n = @as(f64, @floatFromInt(measurements.len));

    // Remove extreme outliers using IQR method for more stable statistics
    const q1_index = measurements.len / 4;
    const q3_index = (3 * measurements.len) / 4;
    const q1 = @as(f64, @floatFromInt(measurements[q1_index]));
    const q3 = @as(f64, @floatFromInt(measurements[q3_index]));
    const iqr = q3 - q1;
    const outlier_threshold = q3 + 1.5 * iqr; // Standard 1.5*IQR

    // Filter outliers for statistics calculation
    var filtered_measurements: std.ArrayList(u64) = .empty;
    defer filtered_measurements.deinit(allocator);

    for (measurements) |measurement| {
        const val = @as(f64, @floatFromInt(measurement));
        if (val <= outlier_threshold) {
            try filtered_measurements.append(allocator, measurement);
        }
    }

    // Use filtered data for most statistics, but keep original for min/max
    const filtered_data = filtered_measurements.items;
    const filtered_n = @as(f64, @floatFromInt(filtered_data.len));

    const min_ns = measurements[0];
    const max_ns = measurements[measurements.len - 1];

    // Calculate mean from filtered data
    var sum: u64 = 0;
    for (filtered_data) |measurement| {
        sum += measurement;
    }
    const mean_ns = @as(f64, @floatFromInt(sum)) / filtered_n;

    // Calculate median from original data
    const median_ns = @as(f64, @floatFromInt(measurements[measurements.len / 2]));

    // Calculate standard deviation from filtered data
    var variance_sum: f64 = 0.0;
    for (filtered_data) |measurement| {
        const diff = @as(f64, @floatFromInt(measurement)) - mean_ns;
        variance_sum += diff * diff;
    }
    const variance = if (filtered_n > 1.0) variance_sum / (filtered_n - 1.0) else 0.0;
    const std_dev_ns = @sqrt(variance);

    // Calculate percentiles from original data
    const p99_index = @min(measurements.len - 1, @as(usize, @intFromFloat(0.99 * n)));
    const p99_ns = @as(f64, @floatFromInt(measurements[p99_index]));

    // Calculate confidence interval (95% using t-distribution approximation)
    const t_critical = 1.96; // For large sample sizes and 95% confidence
    const standard_error = std_dev_ns / @sqrt(filtered_n);
    const margin_of_error = t_critical * standard_error;

    const ops_per_sec = 1_000_000_000.0 / mean_ns;

    return BenchmarkStats{
        .name = name,
        .samples = measurements.len, // Report original sample count
        .mean_ns = mean_ns,
        .median_ns = median_ns,
        .min_ns = min_ns,
        .max_ns = max_ns,
        .std_dev_ns = std_dev_ns,
        .p99_ns = p99_ns,
        .ops_per_sec = ops_per_sec,
        .total_time_ns = sum,
        .confidence_interval_lower = mean_ns - margin_of_error,
        .confidence_interval_upper = mean_ns + margin_of_error,
    };
}

// =============================================================================
// BENCHMARKING ENGINE
// =============================================================================

pub const BenchmarkFunction = *const fn () void;
pub const BenchmarkFunctionWithSamples = *const fn (usize) void;

// Pre-generated test inputs to avoid including RNG in benchmarks
const PreGeneratedInputs = struct {
    fp_a: [1000]FpMont = undefined,
    fp_b: [1000]FpMont = undefined,
    fp_nonzero: [1000]FpMont = undefined,
    fp2_a: [1000]Fp2Mont = undefined,
    fp2_b: [1000]Fp2Mont = undefined,
    fp2_nonzero: [1000]Fp2Mont = undefined,
    fp6_a: [1000]Fp6Mont = undefined,
    fp6_b: [1000]Fp6Mont = undefined,
    fp6_nonzero: [1000]Fp6Mont = undefined,
    fp12_a: [1000]Fp12Mont = undefined,
    fp12_b: [1000]Fp12Mont = undefined,
    fp12_nonzero: [1000]Fp12Mont = undefined,
    fr_a: [1000]Fr = undefined,
    fr_b: [1000]Fr = undefined,
    fr_nonzero: [1000]Fr = undefined,
    g1_points: [1000]G1 = undefined,
    g2_points: [1000]G2 = undefined,

    fn init(allocator: std.mem.Allocator) !PreGeneratedInputs {
        _ = allocator;
        var self = PreGeneratedInputs{};
        var rng = SecureRandomGenerator.init();

        // Generate field elements
        for (0..1000) |i| {
            self.fp_a[i] = rng.randomFpMont();
            self.fp_b[i] = rng.randomFpMont();
            self.fp_nonzero[i] = rng.randomFpMontNonZero();

            self.fp2_a[i] = rng.randomFp2Mont();
            self.fp2_b[i] = rng.randomFp2Mont();
            self.fp2_nonzero[i] = rng.randomFp2MontNonZero();

            self.fp6_a[i] = rng.randomFp6Mont();
            self.fp6_b[i] = rng.randomFp6Mont();
            self.fp6_nonzero[i] = rng.randomFp6MontNonZero();

            self.fp12_a[i] = rng.randomFp12Mont();
            self.fp12_b[i] = rng.randomFp12Mont();
            self.fp12_nonzero[i] = rng.randomFp12MontNonZero();

            self.fr_a[i] = rng.randomFr();
            self.fr_b[i] = rng.randomFr();
            self.fr_nonzero[i] = rng.randomFrNonZero();

            self.g1_points[i] = rng.randomG1();
            self.g2_points[i] = rng.randomG2();
        }

        return self;
    }
};

var inputs: PreGeneratedInputs = undefined;
var inputs_initialized = false;
var input_index: usize = 0;

fn getInputs() *PreGeneratedInputs {
    if (!inputs_initialized) {
        inputs = PreGeneratedInputs.init(std.heap.page_allocator) catch unreachable;
        inputs_initialized = true;
    }
    return &inputs;
}

fn nextInputIndex() usize {
    input_index = (input_index + 1) % 1000;
    return input_index;
}

pub fn benchmark(allocator: std.mem.Allocator, name: []const u8, benchmark_fn: BenchmarkFunction, time_budget_ns: u64) !BenchmarkStats {
    var measurements: std.ArrayList(u64) = .empty;
    defer measurements.deinit(allocator);

    // Extended warmup phase to stabilize caches and CPU frequency
    for (0..BenchmarkConfig.warmup_iterations * 10) |_| {
        benchmark_fn();
    }

    // Determine batch size based on estimated operation time
    // For very fast operations, measure batches to reduce timer overhead
    var batch_size: usize = 1;

    // Quick calibration to determine optimal batch size
    const calibration_start = std.time.nanoTimestamp();
    for (0..1000) |_| {
        benchmark_fn();
    }
    const calibration_end = std.time.nanoTimestamp();
    const calibration_time = @as(u64, @intCast(calibration_end - calibration_start));
    const estimated_ns_per_op = calibration_time / 1000;

    // Use larger batch sizes for very fast operations to reduce measurement noise
    if (estimated_ns_per_op < 100) {
        batch_size = 1000; // For sub-100ns operations
    } else if (estimated_ns_per_op < 1000) {
        batch_size = 100; // For sub-1μs operations
    } else if (estimated_ns_per_op < 10000) {
        batch_size = 10; // For sub-10μs operations
    } else {
        batch_size = 1; // For slow operations, measure individually
    }

    // Time-based measurement phase with batching
    const start_time = std.time.nanoTimestamp();
    var iteration: usize = 0;

    while (true) {
        const iter_start = std.time.nanoTimestamp();

        // Execute batch
        for (0..batch_size) |_| {
            benchmark_fn();
        }

        const iter_end = std.time.nanoTimestamp();

        const batch_time = @as(u64, @intCast(iter_end - iter_start));
        const per_op_time = batch_time / batch_size;

        // Only record reasonable measurements (filter obvious outliers)
        if (per_op_time > 0 and per_op_time < estimated_ns_per_op * 100) {
            try measurements.append(allocator, per_op_time);
        }

        iteration += batch_size;

        // Check if we should stop
        const elapsed = @as(u64, @intCast(iter_end - start_time));
        if (elapsed >= time_budget_ns and measurements.items.len >= BenchmarkConfig.min_iterations / batch_size) {
            break;
        }

        // Safety check to avoid infinite loops
        if (iteration >= 10000000) break;
    }

    // Ensure we have enough measurements
    if (measurements.items.len < 10) {
        // Fallback: run more iterations with smaller batches
        batch_size = 1;
        measurements.clearRetainingCapacity();

        for (0..BenchmarkConfig.min_iterations) |_| {
            const iter_start = std.time.nanoTimestamp();
            benchmark_fn();
            const iter_end = std.time.nanoTimestamp();
            const measurement = @as(u64, @intCast(iter_end - iter_start));
            if (measurement > 0 and measurement < 1_000_000_000) { // Filter absurd values > 1s
                try measurements.append(allocator, measurement);
            }
        }
    }

    return calculateStats(allocator, name, measurements.items);
}

pub fn benchmarkWithSamples(allocator: std.mem.Allocator, name: []const u8, benchmark_fn: BenchmarkFunctionWithSamples, sample_size: usize, time_budget_ns: u64) !BenchmarkStats {
    var measurements: std.ArrayList(u64) = .empty;
    defer measurements.deinit(allocator);

    // Extended warmup phase to stabilize caches and CPU frequency
    for (0..BenchmarkConfig.warmup_iterations * 10) |_| {
        benchmark_fn(sample_size);
    }

    // Time-based measurement phase
    const start_time = std.time.nanoTimestamp();
    var iteration: usize = 0;

    while (true) {
        const iter_start = std.time.nanoTimestamp();

        // Execute the benchmark function with the specified sample size
        benchmark_fn(sample_size);

        const iter_end = std.time.nanoTimestamp();

        const total_time = @as(u64, @intCast(iter_end - iter_start));
        const per_op_time = total_time / sample_size; // Divide by sample size for per-operation timing

        // Only record reasonable measurements
        if (per_op_time > 0 and total_time < 10_000_000_000) { // Filter absurd values > 10s
            try measurements.append(allocator, per_op_time);
        }

        iteration += 1;

        // Check if we should stop
        const elapsed = @as(u64, @intCast(iter_end - start_time));
        if (elapsed >= time_budget_ns and measurements.items.len >= BenchmarkConfig.min_iterations / 100) {
            break;
        }

        // Safety check to avoid infinite loops
        if (iteration >= 1000000) break;
    }

    // Ensure we have enough measurements
    if (measurements.items.len < 10) {
        // Fallback: run more iterations
        measurements.clearRetainingCapacity();

        for (0..@max(100, BenchmarkConfig.min_iterations / 100)) |_| {
            const iter_start = std.time.nanoTimestamp();
            benchmark_fn(sample_size);
            const iter_end = std.time.nanoTimestamp();
            const total_time = @as(u64, @intCast(iter_end - iter_start));
            const per_op_time = total_time / sample_size;
            if (per_op_time > 0 and total_time < 10_000_000_000) {
                try measurements.append(allocator, per_op_time);
            }
        }
    }

    return calculateStats(allocator, name, measurements.items);
}

// =============================================================================
// FIELD OPERATION BENCHMARKS
// =============================================================================

pub fn benchFpAdd(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].add(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn benchFpSub(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].sub(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn benchFpMul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].mul(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFpSquare(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFpInv(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp2Add(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].add(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp2Sub(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].sub(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn benchFp2Mul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].mul(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp2Square(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp2Inv(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp2_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp6Add(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].add(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp6Sub(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].sub(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp6Mul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].mul(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp6Square(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp6Inv(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp6_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp12Add(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].add(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp12Sub(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].sub(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp12Mul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].mul(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp12Square(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFp12Inv(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.fp12_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }
}

pub fn benchG1Add(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g1_points[(i + j) % 1000].add(&test_inputs.g1_points[(i + j + 1) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG1Double(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g1_points[(i + j) % 1000].double();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG1ScalarMul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g1_points[(i + j) % 1000].mul(&test_inputs.fr_a[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG2Add(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g2_points[(i + j) % 1000].add(&test_inputs.g2_points[(i + j + 1) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG2Double(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g2_points[(i + j) % 1000].double();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG2IsInSubgroup(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g2_points[(i + j) % 1000].isInSubgroup();
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchG2ScalarMul(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = test_inputs.g2_points[(i + j) % 1000].mul(&test_inputs.fr_a[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchPairing(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = pairing_mod.pairing(&test_inputs.g1_points[(i + j) % 1000], &test_inputs.g2_points[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchMillerLoop(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = pairing_mod.miller_loop(&test_inputs.g1_points[(i + j) % 1000], &test_inputs.g2_points[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

fn benchFinalExponentiation(sample_size: usize) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..sample_size) |j| {
        const result = pairing_mod.final_exponentiation(&test_inputs.fp12_a[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }
}

// =============================================================================
// COMPREHENSIVE BENCHMARK SUITE
// =============================================================================

pub fn runComprehensiveBenchmarks(allocator: std.mem.Allocator) !void {
    // Initialize pre-generated inputs
    _ = getInputs();

    std.debug.print("\n", .{});
    std.debug.print("\x1b[36m╔══════════════════════════════════════════════════════════════════════════════╗\x1b[0m\n", .{});
    std.debug.print("\x1b[36m║\x1b[0m\x1b[1;97m                   BN254 Pairing Library Performance Benchmarks              \x1b[0m\x1b[36m║\x1b[0m\n", .{});
    std.debug.print("\x1b[36m╚══════════════════════════════════════════════════════════════════════════════╝\x1b[0m\n", .{});
    std.debug.print("\n", .{});

    std.debug.print("Configuration:\n", .{});
    std.debug.print("  • Input Generation: Pre-generated secure random inputs (1000 samples)\n", .{});
    std.debug.print("  • Warmup Iterations: {}\n", .{BenchmarkConfig.warmup_iterations});
    std.debug.print("  • Time Budget: 1s for fast ops, 5s for slow ops\n", .{});
    std.debug.print("  • Statistical Confidence: {}%\n", .{@as(u32, @intFromFloat(BenchmarkConfig.statistical_confidence * 100))});
    std.debug.print("\n", .{});

    const benchmarks = [_]struct { name: []const u8, func: BenchmarkFunctionWithSamples, sample_size: usize, is_slow: bool }{
        // Field operations (fast)
        .{ .name = "Fp Addition", .func = benchFpAdd, .sample_size = operation_sample_sizes.fp_add, .is_slow = false },
        .{ .name = "Fp Subtraction", .func = benchFpSub, .sample_size = operation_sample_sizes.fp_sub, .is_slow = false },
        .{ .name = "Fp Multiplication", .func = benchFpMul, .sample_size = operation_sample_sizes.fp_mul, .is_slow = false },
        .{ .name = "Fp Squaring", .func = benchFpSquare, .sample_size = operation_sample_sizes.fp_square, .is_slow = false },
        .{ .name = "Fp Inversion", .func = benchFpInv, .sample_size = operation_sample_sizes.fp_inv, .is_slow = false },

        .{ .name = "Fp2 Addition", .func = benchFp2Add, .sample_size = operation_sample_sizes.fp2_add, .is_slow = false },
        .{ .name = "Fp2 Subtraction", .func = benchFp2Sub, .sample_size = operation_sample_sizes.fp2_sub, .is_slow = false },
        .{ .name = "Fp2 Multiplication", .func = benchFp2Mul, .sample_size = operation_sample_sizes.fp2_mul, .is_slow = false },
        .{ .name = "Fp2 Squaring", .func = benchFp2Square, .sample_size = operation_sample_sizes.fp2_square, .is_slow = false },
        .{ .name = "Fp2 Inversion", .func = benchFp2Inv, .sample_size = operation_sample_sizes.fp2_inv, .is_slow = false },

        .{ .name = "Fp6 Addition", .func = benchFp6Add, .sample_size = operation_sample_sizes.fp6_add, .is_slow = false },
        .{ .name = "Fp6 Subtraction", .func = benchFp6Sub, .sample_size = operation_sample_sizes.fp6_sub, .is_slow = false },
        .{ .name = "Fp6 Multiplication", .func = benchFp6Mul, .sample_size = operation_sample_sizes.fp6_mul, .is_slow = false },
        .{ .name = "Fp6 Squaring", .func = benchFp6Square, .sample_size = operation_sample_sizes.fp6_square, .is_slow = false },
        .{ .name = "Fp6 Inversion", .func = benchFp6Inv, .sample_size = operation_sample_sizes.fp6_inv, .is_slow = false },

        .{ .name = "Fp12 Addition", .func = benchFp12Add, .sample_size = operation_sample_sizes.fp12_add, .is_slow = false },
        .{ .name = "Fp12 Subtraction", .func = benchFp12Sub, .sample_size = operation_sample_sizes.fp12_sub, .is_slow = false },
        .{ .name = "Fp12 Multiplication", .func = benchFp12Mul, .sample_size = operation_sample_sizes.fp12_mul, .is_slow = false },
        .{ .name = "Fp12 Squaring", .func = benchFp12Square, .sample_size = operation_sample_sizes.fp12_square, .is_slow = false },
        .{ .name = "Fp12 Inversion", .func = benchFp12Inv, .sample_size = operation_sample_sizes.fp12_inv, .is_slow = false },

        // Curve operations (some slow)
        .{ .name = "G1 Addition", .func = benchG1Add, .sample_size = operation_sample_sizes.g1_add, .is_slow = false },
        .{ .name = "G1 Doubling", .func = benchG1Double, .sample_size = operation_sample_sizes.g1_double, .is_slow = false },
        .{ .name = "G1 Scalar Multiplication", .func = benchG1ScalarMul, .sample_size = operation_sample_sizes.g1_scalar_mul, .is_slow = true },

        .{ .name = "G2 Addition", .func = benchG2Add, .sample_size = operation_sample_sizes.g2_add, .is_slow = false },
        .{ .name = "G2 Doubling", .func = benchG2Double, .sample_size = operation_sample_sizes.g2_double, .is_slow = false },
        .{ .name = "G2 Subgroup Check", .func = benchG2IsInSubgroup, .sample_size = operation_sample_sizes.g2_is_in_subgroup, .is_slow = true },
        .{ .name = "G2 Scalar Multiplication", .func = benchG2ScalarMul, .sample_size = operation_sample_sizes.g2_scalar_mul, .is_slow = true },

        // Pairing operations (slow)
        .{ .name = "Full Pairing", .func = benchPairing, .sample_size = operation_sample_sizes.pairing, .is_slow = true },
        .{ .name = "Miller Loop", .func = benchMillerLoop, .sample_size = operation_sample_sizes.miller_loop, .is_slow = true },
        .{ .name = "Final Exponentiation", .func = benchFinalExponentiation, .sample_size = operation_sample_sizes.final_exp, .is_slow = true },
    };

    std.debug.print("\x1b[90m┌────────────────────────────────────────┬──────────┬──────────┬──────────┬──────────┬───────────┬────────┐\x1b[0m\n", .{});
    std.debug.print("\x1b[90m│\x1b[0m \x1b[1;17mOperation\x1b[0m                              \x1b[90m│\x1b[0m   \x1b[1;33mMean\x1b[0m   \x1b[90m│\x1b[0m  \x1b[1;33mStdDev\x1b[0m  \x1b[90m│\x1b[0m    \x1b[1;33mP99\x1b[0m   \x1b[90m│\x1b[0m    \x1b[1;33mMax\x1b[0m   \x1b[90m│\x1b[0m   \x1b[1;33mOps/s\x1b[0m   \x1b[90m│\x1b[0m \x1b[1;33mSamples\x1b[0m\x1b[90m│\x1b[0m\n", .{});
    std.debug.print("\x1b[90m├────────────────────────────────────────┼──────────┼──────────┼──────────┼──────────┼───────────┼────────┤\x1b[0m\n", .{});

    var all_stats: std.ArrayList(BenchmarkStats) = .empty;
    defer all_stats.deinit(allocator);

    for (benchmarks) |bench_spec| {
        const time_budget = if (bench_spec.is_slow) BenchmarkConfig.slow_time_budget_ns else BenchmarkConfig.fast_time_budget_ns;
        const stats = try benchmarkWithSamples(allocator, bench_spec.name, bench_spec.func, bench_spec.sample_size, time_budget);
        try all_stats.append(allocator, stats);
        stats.format();
    }

    std.debug.print("\x1b[90m├────────────────────────────────────────┼──────────┴──────────┴──────────┴──────────┴───────────┴────────┘\x1b[0m\n", .{});

    // Performance summary
    std.debug.print("\n", .{});
    std.debug.print("\x1b[1;36mPerformance Summary:\x1b[0m\n", .{});
    std.debug.print("\x1b[36m==================================================\x1b[0m\n", .{});

    // Find key benchmarks for summary
    for (all_stats.items) |stats| {
        if (std.mem.eql(u8, stats.name, "Fp Multiplication")) {
            std.debug.print("\x1b[92m•\x1b[0m Base field multiplication: \x1b[97m{d:.1} ns/op\x1b[0m\n", .{stats.mean_ns});
        } else if (std.mem.eql(u8, stats.name, "Fp12 Multiplication")) {
            std.debug.print("\x1b[95m•\x1b[0m Extension field (Fp12) mult: \x1b[97m{d:.1} μs/op\x1b[0m\n", .{stats.mean_ns / 1000.0});
        } else if (std.mem.eql(u8, stats.name, "G1 Scalar Multiplication")) {
            std.debug.print("\x1b[93m•\x1b[0m G1 scalar multiplication: \x1b[97m{d:.1} μs/op\x1b[0m\n", .{stats.mean_ns / 1000.0});
        } else if (std.mem.eql(u8, stats.name, "G2 Scalar Multiplication")) {
            std.debug.print("\x1b[91m•\x1b[0m G2 scalar multiplication: \x1b[97m{d:.1} ms/op\x1b[0m\n", .{stats.mean_ns / 1_000_000.0});
        } else if (std.mem.eql(u8, stats.name, "Full Pairing")) {
            std.debug.print("\x1b[1;97m•\x1b[0m Complete pairing operation: \x1b[1;97m{d:.1} ms/op\x1b[0m\n", .{stats.mean_ns / 1_000_000.0});
        }
    }

    std.debug.print("\n", .{});
    std.debug.print("Benchmark completed successfully!\n", .{});
    std.debug.print("Results include 95% confidence intervals and comprehensive statistics.\n", .{});
}

// =============================================================================
// TEST INTEGRATION
// =============================================================================

test "BN254 Comprehensive Performance Benchmarks" {
    try runComprehensiveBenchmarks(std.testing.allocator);
}

test "BN254 Quick Performance Check" {
    // Initialize pre-generated inputs
    _ = getInputs();

    const quick_benchmarks = [_]struct { name: []const u8, func: BenchmarkFunctionWithSamples, sample_size: usize }{
        .{ .name = "Fp Multiplication", .func = benchFpMul, .sample_size = operation_sample_sizes.fp_mul },
        .{ .name = "G1 Addition", .func = benchG1Add, .sample_size = operation_sample_sizes.g1_add },
        .{ .name = "Full Pairing", .func = benchPairing, .sample_size = operation_sample_sizes.pairing },
    };

    std.debug.print("\nQuick Performance Check:\n", .{});
    std.debug.print("========================\n", .{});

    const quick_time_budget = 100000000; // 100ms for quick check
    for (quick_benchmarks) |bench_spec| {
        const stats = try benchmarkWithSamples(std.testing.allocator, bench_spec.name, bench_spec.func, bench_spec.sample_size, quick_time_budget);
        const time_unit = if (stats.mean_ns < 1000) "ns" else if (stats.mean_ns < 1000000) "μs" else "ms";
        const divisor: f64 = if (stats.mean_ns < 1000) 1.0 else if (stats.mean_ns < 1000000) 1000.0 else 1000000.0;
        std.debug.print("{s}: {d:.1} {s}/op\n", .{ stats.name, stats.mean_ns / divisor, time_unit });
    }
}

// =============================================================================
// USAGE INSTRUCTIONS
// =============================================================================

// To run these benchmarks:
//
// 1. For comprehensive benchmarks:
//    zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "BN254 Comprehensive Performance Benchmarks"
//
// 2. For quick performance check:
//    zig test src/crypto/bn254/comprehensive_benchmarks.zig --test-filter "BN254 Quick Performance Check"
//
// 3. To integrate in your application:
//    const bn254_bench = @import("path/to/comprehensive_benchmarks.zig");
//    try bn254_bench.runComprehensiveBenchmarks(allocator);
