const std = @import("std");
const zbench = @import("zbench");

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
// SECURE RANDOM INPUT GENERATION UTILITIES
// =============================================================================

/// SecureRandomGenerator provides cryptographically secure random number generation
/// for benchmark inputs, ensuring diverse and representative test data
pub const SecureRandomGenerator = struct {
    rng: std.Random.DefaultPrng,

    /// Initialize with secure seeding
    pub fn init() SecureRandomGenerator {
        var seed: u64 = undefined;
        std.posix.getrandom(std.mem.asBytes(&seed)) catch |err| {
            std.debug.print("getrandom failed: {}\n", .{err});
            @panic("getrandom failed");
        };

        return SecureRandomGenerator{
            .rng = std.Random.DefaultPrng.init(seed),
        };
    }

    /// Generate random 256-bit value
    pub fn randomU256(self: *SecureRandomGenerator) u256 {
        const random = self.rng.random();
        var bytes: [32]u8 = undefined;
        random.bytes(&bytes);
        return std.mem.readInt(u256, &bytes, .big);
    }

    /// Generate non-zero random 256-bit value
    pub fn randomU256NonZero(self: *SecureRandomGenerator) u256 {
        while (true) {
            const val = self.randomU256();
            if (val != 0) return val;
        }
    }

    /// Generate random field element (FpMont)
    pub fn randomFpMont(self: *SecureRandomGenerator) FpMont {
        return FpMont.init(self.randomU256());
    }

    /// Generate non-zero random field element
    pub fn randomFpMontNonZero(self: *SecureRandomGenerator) FpMont {
        while (true) {
            const elem = self.randomFpMont();
            if (!elem.equal(&FpMont.ZERO)) return elem;
        }
    }

    /// Generate random Fp2 element
    pub fn randomFp2Mont(self: *SecureRandomGenerator) Fp2Mont {
        return Fp2Mont.init_from_int(self.randomU256(), self.randomU256());
    }

    /// Generate non-zero random Fp2 element
    pub fn randomFp2MontNonZero(self: *SecureRandomGenerator) Fp2Mont {
        while (true) {
            const elem = self.randomFp2Mont();
            if (!elem.equal(&Fp2Mont.ZERO)) return elem;
        }
    }

    /// Generate random Fp6 element
    pub fn randomFp6Mont(self: *SecureRandomGenerator) Fp6Mont {
        return Fp6Mont.init_from_int(self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256());
    }

    /// Generate non-zero random Fp6 element
    pub fn randomFp6MontNonZero(self: *SecureRandomGenerator) Fp6Mont {
        while (true) {
            const elem = self.randomFp6Mont();
            if (!elem.equal(&Fp6Mont.ZERO)) return elem;
        }
    }

    /// Generate random Fp12 element
    pub fn randomFp12Mont(self: *SecureRandomGenerator) Fp12Mont {
        return Fp12Mont.init_from_int(self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256(), self.randomU256());
    }

    /// Generate non-zero random Fp12 element
    pub fn randomFp12MontNonZero(self: *SecureRandomGenerator) Fp12Mont {
        while (true) {
            const elem = self.randomFp12Mont();
            if (!elem.equal(&Fp12Mont.ZERO)) return elem;
        }
    }

    /// Generate random scalar field element
    pub fn randomFr(self: *SecureRandomGenerator) Fr {
        return Fr.init(self.randomU256());
    }

    /// Generate non-zero random scalar field element
    pub fn randomFrNonZero(self: *SecureRandomGenerator) Fr {
        while (true) {
            const elem = self.randomFr();
            if (!elem.equal(&Fr.ZERO)) return elem;
        }
    }

    /// Generate random G1 point by scalar multiplication
    pub fn randomG1(self: *SecureRandomGenerator) G1 {
        const scalar = self.randomFr();
        return G1.GENERATOR.mul(&scalar);
    }

    /// Generate random G2 point by scalar multiplication
    pub fn randomG2(self: *SecureRandomGenerator) G2 {
        const scalar = self.randomFr();
        return G2.GENERATOR.mul(&scalar);
    }
};

// Global random generator instance
var global_rng: SecureRandomGenerator = undefined;
var global_rng_initialized: bool = false;

fn getRng() *SecureRandomGenerator {
    if (!global_rng_initialized) {
        global_rng = SecureRandomGenerator.init();
        global_rng_initialized = true;
    }
    return &global_rng;
}

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

// =============================================================================
// BENCHMARK FUNCTION IMPLEMENTATIONS
// =============================================================================

test "field benchmarks" {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = std.testing.allocator;
    // 500ms time budget for field benchmarks
    var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 5e8 });
    defer bench.deinit();

    //we need to run the benchmarks 1000 times otherwise the clock resolution is too low to measure the time accurately

    // Base field operations
    try bench.add("Fp Addition (1000)", benchmarkFpMontAdd, .{});
    try bench.add("Fp Subtraction (1000)", benchmarkFpMontSub, .{});
    try bench.add("Fp Multiplication (1000)", benchmarkFpMontMul, .{});
    try bench.add("Fp Squaring (1000)", benchmarkFpMontSquare, .{});
    try bench.add("Fp Inversion (1000)", benchmarkFpMontInv, .{});

    // Extension field operations
    try bench.add("Fp2 Addition (1000)", benchmarkFp2MontAdd, .{});
    try bench.add("Fp2 Subtraction (1000)", benchmarkFp2MontSub, .{});
    try bench.add("Fp2 Multiplication (1000)", benchmarkFp2MontMul, .{});
    try bench.add("Fp2 Squaring (1000)", benchmarkFp2MontSquare, .{});
    try bench.add("Fp2 Inversion (1000)", benchmarkFp2MontInv, .{});

    try bench.add("Fp6 Addition (1000)", benchmarkFp6MontAdd, .{});
    try bench.add("Fp6 Subtraction (1000)", benchmarkFp6MontSub, .{});
    try bench.add("Fp6 Multiplication (1000)", benchmarkFp6MontMul, .{});
    try bench.add("Fp6 Squaring (1000)", benchmarkFp6MontSquare, .{});
    try bench.add("Fp6 Inversion (1000)", benchmarkFp6MontInv, .{});

    try bench.add("Fp12 Addition (1000)", benchmarkFp12MontAdd, .{});
    try bench.add("Fp12 Subtraction (1000)", benchmarkFp12MontSub, .{});
    try bench.add("Fp12 Multiplication (1000)", benchmarkFp12MontMul, .{});
    try bench.add("Fp12 Squaring (1000)", benchmarkFp12MontSquare, .{});
    try bench.add("Fp12 Inversion (1000)", benchmarkFp12MontInv, .{});

    try bench.add("Fr Addition (1000)", benchmarkFrAdd, .{});
    try bench.add("Fr Subtraction (1000)", benchmarkFrSub, .{});
    try bench.add("Fr Multiplication (1000)", benchmarkFrMul, .{});
    try bench.add("Fr Inversion (1000)", benchmarkFrInv, .{});

    try stdout.writeAll("\n");
    try bench.run(stdout);
    try stdout.flush();
}

test "curve benchmarks" {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = std.testing.allocator;
    // 1 second time budget for curve benchmarks
    var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 1e9 });
    defer bench.deinit();

    try bench.add("G1 Addition", benchmarkG1Add, .{});
    try bench.add("G1 Doubling", benchmarkG1Double, .{});
    try bench.add("G1 Scalar Multiplication", benchmarkG1ScalarMul, .{});
    try bench.add("G1 Negation", benchmarkG1Neg, .{});
    try bench.add("G1 Affine Conversion", benchmarkG1ToAffine, .{});
    try bench.add("G1 Curve Validation", benchmarkG1IsOnCurve, .{});

    try bench.add("G2 Addition", benchmarkG2Add, .{});
    try bench.add("G2 Doubling", benchmarkG2Double, .{});
    try bench.add("G2 Scalar Multiplication", benchmarkG2ScalarMul, .{});
    try bench.add("G2 Negation", benchmarkG2Neg, .{});
    try bench.add("G2 Affine Conversion", benchmarkG2ToAffine, .{});
    try bench.add("G2 Curve Validation", benchmarkG2IsOnCurve, .{});

    try stdout.writeAll("\n");
    try bench.run(stdout);
    try stdout.flush();
}

test "pairing benchmarks" {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = std.testing.allocator;
    // 2 seconds time budget for pairing benchmarks
    var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 2e9 });
    defer bench.deinit();

    try bench.add("Full Pairing", benchmarkPairing, .{});
    try bench.add("Miller Loop", benchmarkMillerLoop, .{});
    try bench.add("Final Exponentiation (Full)", benchmarkFinalExponentiation, .{});
    try bench.add("Final Exponentiation (Easy)", benchmarkFinalExponentiationEasy, .{});
    try bench.add("Final Exponentiation (Hard)", benchmarkFinalExponentiationHard, .{});

    try stdout.writeAll("\n");
    try bench.run(stdout);
    try stdout.flush();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&buf);
    const out = &bw.interface;

    {
        var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 5e8 });
        defer bench.deinit();
        try bench.add("Fp Addition (1000)", benchmarkFpMontAdd, .{});
        try bench.add("Fp Subtraction (1000)", benchmarkFpMontSub, .{});
        try bench.add("Fp Multiplication (1000)", benchmarkFpMontMul, .{});
        try bench.add("Fp Squaring (1000)", benchmarkFpMontSquare, .{});
        try bench.add("Fp Inversion (1000)", benchmarkFpMontInv, .{});
        try bench.add("Fp2 Addition (1000)", benchmarkFp2MontAdd, .{});
        try bench.add("Fp2 Subtraction (1000)", benchmarkFp2MontSub, .{});
        try bench.add("Fp2 Multiplication (1000)", benchmarkFp2MontMul, .{});
        try bench.add("Fp2 Squaring (1000)", benchmarkFp2MontSquare, .{});
        try bench.add("Fp2 Inversion (1000)", benchmarkFp2MontInv, .{});
        try bench.add("Fp6 Addition (1000)", benchmarkFp6MontAdd, .{});
        try bench.add("Fp6 Subtraction (1000)", benchmarkFp6MontSub, .{});
        try bench.add("Fp6 Multiplication (1000)", benchmarkFp6MontMul, .{});
        try bench.add("Fp6 Squaring (1000)", benchmarkFp6MontSquare, .{});
        try bench.add("Fp6 Inversion (1000)", benchmarkFp6MontInv, .{});
        try bench.add("Fp12 Addition (1000)", benchmarkFp12MontAdd, .{});
        try bench.add("Fp12 Subtraction (1000)", benchmarkFp12MontSub, .{});
        try bench.add("Fp12 Multiplication (1000)", benchmarkFp12MontMul, .{});
        try bench.add("Fp12 Squaring (1000)", benchmarkFp12MontSquare, .{});
        try bench.add("Fp12 Inversion (1000)", benchmarkFp12MontInv, .{});
        try bench.add("Fr Addition (1000)", benchmarkFrAdd, .{});
        try bench.add("Fr Subtraction (1000)", benchmarkFrSub, .{});
        try bench.add("Fr Multiplication (1000)", benchmarkFrMul, .{});
        try bench.add("Fr Inversion (1000)", benchmarkFrInv, .{});
        try out.writeAll("\n");
        try bench.run(out);
        try out.flush();
    }

    {
        var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 1e9 });
        defer bench.deinit();
        try bench.add("G1 Addition", benchmarkG1Add, .{});
        try bench.add("G1 Doubling", benchmarkG1Double, .{});
        try bench.add("G1 Scalar Multiplication", benchmarkG1ScalarMul, .{});
        try bench.add("G1 Negation", benchmarkG1Neg, .{});
        try bench.add("G1 Affine Conversion", benchmarkG1ToAffine, .{});
        try bench.add("G1 Curve Validation", benchmarkG1IsOnCurve, .{});
        try bench.add("G2 Addition", benchmarkG2Add, .{});
        try bench.add("G2 Doubling", benchmarkG2Double, .{});
        try bench.add("G2 Scalar Multiplication", benchmarkG2ScalarMul, .{});
        try bench.add("G2 Negation", benchmarkG2Neg, .{});
        try bench.add("G2 Affine Conversion", benchmarkG2ToAffine, .{});
        try bench.add("G2 Curve Validation", benchmarkG2IsOnCurve, .{});
        try out.writeAll("\n");
        try bench.run(out);
        try out.flush();
    }

    {
        var bench = zbench.Benchmark.init(allocator, .{ .time_budget_ns = 2e9 });
        defer bench.deinit();
        try bench.add("Full Pairing", benchmarkPairing, .{});
        try bench.add("Miller Loop", benchmarkMillerLoop, .{});
        try bench.add("Final Exponentiation (Full)", benchmarkFinalExponentiation, .{});
        try bench.add("Final Exponentiation (Easy)", benchmarkFinalExponentiationEasy, .{});
        try bench.add("Final Exponentiation (Hard)", benchmarkFinalExponentiationHard, .{});
        try out.writeAll("\n");
        try bench.run(out);
        try out.flush();
    }
}

// pub fn runAllBenchmarks(allocator: std.mem.Allocator) !void {
//     std.debug.print("\n=== BN254 Field Operations ===\n");
//     try runFieldBenchmarks(allocator);

//     std.debug.print("\n=== BN254 Curve Operations ===\n");
//     try runCurveBenchmarks(allocator);

//     std.debug.print("\n=== BN254 Pairing Operations ===\n");
//     try runPairingBenchmarks(allocator);
// }

// =============================================================================
// INDIVIDUAL BENCHMARK FUNCTIONS
// =============================================================================

fn benchmarkFpMontAdd(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].add(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFpMontSub(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].sub(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFpMontMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].mul(&test_inputs.fp_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFpMontSquare(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFpMontInv(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp2MontAdd(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].add(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp2MontSub(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].sub(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp2MontMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].mul(&test_inputs.fp2_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp2MontSquare(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp2_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp2MontInv(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp2_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp6MontAdd(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].add(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp6MontSub(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].sub(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp6MontMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].mul(&test_inputs.fp6_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp6MontSquare(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp6_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp6MontInv(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp6_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp12MontAdd(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].add(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp12MontSub(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].sub(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp12MontMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].mul(&test_inputs.fp12_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp12MontSquare(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp12_a[(i + j) % 1000].square();
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFp12MontInv(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fp12_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFrAdd(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fr_a[(i + j) % 1000].add(&test_inputs.fr_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFrSub(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fr_a[(i + j) % 1000].sub(&test_inputs.fr_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFrMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fr_a[(i + j) % 1000].mul(&test_inputs.fr_b[(i + j) % 1000]);
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkFrInv(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    for (0..1000) |j| {
        const result = test_inputs.fr_nonzero[(i + j) % 1000].inv() catch unreachable;
        std.mem.doNotOptimizeAway(result);
    }

    _ = allocator;
}

fn benchmarkG1Add(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].add(&test_inputs.g1_points[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG1Double(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].double();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG1ScalarMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].mul(&test_inputs.fr_nonzero[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG1Neg(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].neg();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG1ToAffine(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].toAffine();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG1IsOnCurve(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g1_points[i].isOnCurve();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2Add(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].add(&test_inputs.g2_points[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2Double(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].double();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2ScalarMul(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].mul(&test_inputs.fr_nonzero[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2Neg(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].neg();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2ToAffine(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].toAffine();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkG2IsOnCurve(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = test_inputs.g2_points[i].isOnCurve();
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkPairing(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = pairing_mod.pairing(&test_inputs.g1_points[i], &test_inputs.g2_points[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkMillerLoop(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = pairing_mod.miller_loop(&test_inputs.g1_points[i], &test_inputs.g2_points[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkFinalExponentiation(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = pairing_mod.final_exponentiation(&test_inputs.fp12_nonzero[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkFinalExponentiationEasy(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = pairing_mod.final_exponentiation_easy_part(&test_inputs.fp12_nonzero[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

fn benchmarkFinalExponentiationHard(allocator: std.mem.Allocator) void {
    const test_inputs = getInputs();
    const i = nextInputIndex();
    const result = pairing_mod.final_exponentiation_hard_part(&test_inputs.fp12_nonzero[i]);
    std.mem.doNotOptimizeAway(result);

    _ = allocator;
}

// =============================================================================
// PERFORMANCE ANALYSIS AND REPORTING
// =============================================================================

// pub const BenchmarkResults = struct {
//     operation: []const u8,
//     avg_ns: u64,
//     min_ns: u64,
//     max_ns: u64,
//     iterations: u32,
//     ops_per_sec: f64,
// };

// pub fn generatePerformanceReport(allocator: std.mem.Allocator) !void {
//     std.debug.print("=".repeat(80));
//     std.debug.print("\n BN254 Pairing Library Performance Report\n");
//     std.debug.print("=".repeat(80));
//     std.debug.print("\n\n");

//     std.debug.print("Configuration:\n");
//     std.debug.print("- Max Iterations: {}\n", .{Config.max_iterations});
//     std.debug.print("- Time Budget: {d:.1}s per benchmark\n", .{@as(f64, @floatFromInt(Config.time_budget_ns)) / 1e9});
//     std.debug.print("- Memory Tracking: {}\n", .{Config.track_allocations});
//     std.debug.print("- Random Generation: Cryptographically secure (ChaCha20)\n\n");

//     std.debug.print("Field Operations Performance:\n");
//     std.debug.print("-".repeat(40));
//     std.debug.print("\n");
//     try runFieldBenchmarks(allocator);

//     std.debug.print("\n\nElliptic Curve Operations Performance:\n");
//     std.debug.print("-".repeat(40));
//     std.debug.print("\n");
//     try runCurveBenchmarks(allocator);

//     std.debug.print("\n\nPairing Operations Performance:\n");
//     std.debug.print("-".repeat(40));
//     std.debug.print("\n");
//     try runPairingBenchmarks(allocator);
// }

// =============================================================================
// USAGE EXAMPLES AND INTEGRATION INSTRUCTIONS
// =============================================================================

// Example integration in your main function or test:
//
// pub fn main() !void {
//     var gpa = std.heap.GeneralPurposeAllocator(.{}){};
//     defer _ = gpa.deinit();
//     const allocator = gpa.allocator();
//
//     const bn254_benchmarks = @import("path/to/zbench_benchmarks.zig");
//
//     std.debug.print("Running BN254 benchmarks...\n");
//     try bn254_benchmarks.runAllBenchmarks(allocator);
//
//     std.debug.print("\nGenerating performance report...\n");
//     try bn254_benchmarks.generatePerformanceReport(allocator);
// }

// Build system integration example for build.zig:
//
// const bn254_bench = b.addExecutable(.{
//     .name = "bn254-bench",
//     .root_source_file = b.path("src/crypto/bn254/zbench_benchmarks.zig"),
//     .target = target,
//     .optimize = .ReleaseFast, // Use ReleaseFast for meaningful benchmarks
// });
//
// const zbench = b.dependency("zbench", .{});
// bn254_bench.root_module.addImport("zbench", zbench.module("zbench"));
//
// const bench_step = b.step("bench-bn254", "Run BN254 benchmarks");
// bench_step.dependOn(&b.addRunArtifact(bn254_bench).step);
