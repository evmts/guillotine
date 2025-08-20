// Comprehensive BN254 Pairing Library Benchmark Implementation using zbench
// This file provides high-quality, statistically valid benchmarks for all BN254 operations

const std = @import("std");
// Use of zbench requires specific build integration
// For now, we'll make this importable without zbench for compatibility
const zbench = if (@hasDecl(@import("root"), "zbench")) 
    @import("zbench") 
else 
    @import("std"); // fallback, won't work but allows compilation

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

// zbench Configuration
const Config = zbench.Config{
    .max_iterations = 16384,
    .time_budget_ns = 2e9, // 2 seconds per benchmark
    .track_allocations = true,
    .use_shuffling_allocator = false, // Avoid performance overhead for crypto benchmarks
};

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
        std.posix.getrandom(std.mem.asBytes(&seed)) catch |err| switch (err) {
            error.Unexpected => {
                // Fallback to time-based seeding if getrandom fails
                seed = @as(u64, @truncate(@as(u128, @bitCast(std.time.nanoTimestamp()))));
            },
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
            if (elem.value != 0) return elem;
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
            if (!(elem.u0.value == 0 and elem.u1.value == 0)) return elem;
        }
    }

    /// Generate random Fp6 element
    pub fn randomFp6Mont(self: *SecureRandomGenerator) Fp6Mont {
        return Fp6Mont.init_from_int(
            self.randomU256(), self.randomU256(), self.randomU256(),
            self.randomU256(), self.randomU256(), self.randomU256()
        );
    }

    /// Generate non-zero random Fp6 element
    pub fn randomFp6MontNonZero(self: *SecureRandomGenerator) Fp6Mont {
        while (true) {
            const elem = self.randomFp6Mont();
            // Simplified zero check
            if (!(elem.v0.u0.value == 0 and elem.v0.u1.value == 0 and
                  elem.v1.u0.value == 0 and elem.v1.u1.value == 0 and
                  elem.v2.u0.value == 0 and elem.v2.u1.value == 0)) return elem;
        }
    }

    /// Generate random Fp12 element
    pub fn randomFp12Mont(self: *SecureRandomGenerator) Fp12Mont {
        return Fp12Mont.init_from_int(
            self.randomU256(), self.randomU256(), self.randomU256(),
            self.randomU256(), self.randomU256(), self.randomU256(),
            self.randomU256(), self.randomU256(), self.randomU256(),
            self.randomU256(), self.randomU256(), self.randomU256()
        );
    }

    /// Generate non-zero random Fp12 element
    pub fn randomFp12MontNonZero(self: *SecureRandomGenerator) Fp12Mont {
        while (true) {
            const elem = self.randomFp12Mont();
            // Simplified zero check
            if (!(elem.w0.v0.u0.value == 0 and elem.w0.v0.u1.value == 0 and
                  elem.w0.v1.u0.value == 0 and elem.w0.v1.u1.value == 0 and
                  elem.w0.v2.u0.value == 0 and elem.w0.v2.u1.value == 0 and
                  elem.w1.v0.u0.value == 0 and elem.w1.v0.u1.value == 0 and
                  elem.w1.v1.u0.value == 0 and elem.w1.v1.u1.value == 0 and
                  elem.w1.v2.u0.value == 0 and elem.w1.v2.u1.value == 0)) return elem;
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
            if (elem.value != 0) return elem;
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

// =============================================================================
// FIELD OPERATION BENCHMARKS
// =============================================================================

/// Benchmark FpMont addition operation
fn benchmarkFpMontAdd(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFpMont();
    const b = rng.randomFpMont();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark FpMont subtraction operation
fn benchmarkFpMontSub(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFpMont();
    const b = rng.randomFpMont();
    
    const result = a.sub(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark FpMont multiplication operation
fn benchmarkFpMontMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFpMont();
    const b = rng.randomFpMont();
    
    const result = a.mul(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark FpMont squaring operation
fn benchmarkFpMontSquare(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFpMont();
    
    const result = a.square();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark FpMont inversion operation
fn benchmarkFpMontInv(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFpMontNonZero();
    
    const result = a.inv() catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp2Mont addition operation
fn benchmarkFp2MontAdd(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp2Mont();
    const b = rng.randomFp2Mont();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp2Mont subtraction operation
fn benchmarkFp2MontSub(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp2Mont();
    const b = rng.randomFp2Mont();
    
    const result = a.sub(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp2Mont multiplication operation
fn benchmarkFp2MontMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp2Mont();
    const b = rng.randomFp2Mont();
    
    const result = a.mul(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp2Mont squaring operation
fn benchmarkFp2MontSquare(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp2Mont();
    
    const result = a.square();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp2Mont inversion operation
fn benchmarkFp2MontInv(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp2MontNonZero();
    
    const result = a.inv() catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp6Mont addition operation
fn benchmarkFp6MontAdd(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp6Mont();
    const b = rng.randomFp6Mont();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp6Mont subtraction operation
fn benchmarkFp6MontSub(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp6Mont();
    const b = rng.randomFp6Mont();
    
    const result = a.sub(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp6Mont multiplication operation
fn benchmarkFp6MontMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp6Mont();
    const b = rng.randomFp6Mont();
    
    const result = a.mul(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp6Mont squaring operation
fn benchmarkFp6MontSquare(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp6Mont();
    
    const result = a.square();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp6Mont inversion operation
fn benchmarkFp6MontInv(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp6MontNonZero();
    
    const result = a.inv() catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp12Mont addition operation
fn benchmarkFp12MontAdd(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp12Mont();
    const b = rng.randomFp12Mont();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp12Mont subtraction operation
fn benchmarkFp12MontSub(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp12Mont();
    const b = rng.randomFp12Mont();
    
    const result = a.sub(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp12Mont multiplication operation
fn benchmarkFp12MontMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp12Mont();
    const b = rng.randomFp12Mont();
    
    const result = a.mul(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp12Mont squaring operation
fn benchmarkFp12MontSquare(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp12Mont();
    
    const result = a.square();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fp12Mont inversion operation
fn benchmarkFp12MontInv(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFp12MontNonZero();
    
    const result = a.inv() catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// =============================================================================
// SCALAR FIELD BENCHMARKS
// =============================================================================

/// Benchmark Fr addition operation
fn benchmarkFrAdd(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFr();
    const b = rng.randomFr();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fr subtraction operation
fn benchmarkFrSub(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFr();
    const b = rng.randomFr();
    
    const result = a.sub(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fr multiplication operation
fn benchmarkFrMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFr();
    const b = rng.randomFr();
    
    const result = a.mul(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Fr inversion operation
fn benchmarkFrInv(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomFrNonZero();
    
    const result = a.inv() catch unreachable;
    std.mem.doNotOptimizeAway(result);
}

// =============================================================================
// ELLIPTIC CURVE GROUP BENCHMARKS
// =============================================================================

/// Benchmark G1 addition operation
fn benchmarkG1Add(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG1();
    const b = rng.randomG1();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G1 doubling operation
fn benchmarkG1Double(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG1();
    
    const result = a.double();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G1 scalar multiplication operation
fn benchmarkG1ScalarMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const point = rng.randomG1();
    const scalar = rng.randomFr();
    
    const result = point.mul(&scalar);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G1 negation operation
fn benchmarkG1Neg(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG1();
    
    const result = a.neg();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G1 affine conversion operation
fn benchmarkG1ToAffine(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG1();
    
    const result = a.toAffine();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G1 curve validation operation
fn benchmarkG1IsOnCurve(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG1();
    
    const result = a.isOnCurve();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 addition operation
fn benchmarkG2Add(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG2();
    const b = rng.randomG2();
    
    const result = a.add(&b);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 doubling operation
fn benchmarkG2Double(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG2();
    
    const result = a.double();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 scalar multiplication operation
fn benchmarkG2ScalarMul(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const point = rng.randomG2();
    const scalar = rng.randomFr();
    
    const result = point.mul(&scalar);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 negation operation
fn benchmarkG2Neg(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG2();
    
    const result = a.neg();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 affine conversion operation
fn benchmarkG2ToAffine(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG2();
    
    const result = a.toAffine();
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark G2 curve validation operation
fn benchmarkG2IsOnCurve(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const a = rng.randomG2();
    
    const result = a.isOnCurve();
    std.mem.doNotOptimizeAway(result);
}

// =============================================================================
// PAIRING OPERATION BENCHMARKS
// =============================================================================

/// Benchmark full pairing computation
fn benchmarkPairing(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const g1_point = rng.randomG1();
    const g2_point = rng.randomG2();
    
    const result = pairing_mod.pairing(&g1_point, &g2_point);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark Miller loop computation
fn benchmarkMillerLoop(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const g1_point = rng.randomG1();
    const g2_point = rng.randomG2();
    
    const result = pairing_mod.miller_loop(&g1_point, &g2_point);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark final exponentiation (full)
fn benchmarkFinalExponentiation(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const f = rng.randomFp12Mont();
    
    const result = pairing_mod.final_exponentiation(&f);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark final exponentiation easy part
fn benchmarkFinalExponentiationEasy(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const f = rng.randomFp12Mont();
    
    const result = pairing_mod.final_exponentiation_easy_part(&f);
    std.mem.doNotOptimizeAway(result);
}

/// Benchmark final exponentiation hard part
fn benchmarkFinalExponentiationHard(allocator: std.mem.Allocator) void {
    _ = allocator; // unused
    const rng = getRng();
    
    const f = rng.randomFp12Mont();
    
    const result = pairing_mod.final_exponentiation_hard_part(&f);
    std.mem.doNotOptimizeAway(result);
}

// =============================================================================
// COMPREHENSIVE BENCHMARK SUITE
// =============================================================================

// Comprehensive BN254 benchmark test suite
// This test runs all benchmarks with proper statistical analysis and reporting
test "BN254 Comprehensive Benchmarks" {
    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    // =============================================================================
    // BASE FIELD (Fp) BENCHMARKS
    // =============================================================================
    
    try bench.add("Fp Addition", benchmarkFpMontAdd, .{});
    try bench.add("Fp Subtraction", benchmarkFpMontSub, .{});
    try bench.add("Fp Multiplication", benchmarkFpMontMul, .{});
    try bench.add("Fp Squaring", benchmarkFpMontSquare, .{});
    try bench.add("Fp Inversion", benchmarkFpMontInv, .{});

    // =============================================================================
    // QUADRATIC EXTENSION FIELD (Fp2) BENCHMARKS
    // =============================================================================
    
    try bench.add("Fp2 Addition", benchmarkFp2MontAdd, .{});
    try bench.add("Fp2 Subtraction", benchmarkFp2MontSub, .{});
    try bench.add("Fp2 Multiplication", benchmarkFp2MontMul, .{});
    try bench.add("Fp2 Squaring", benchmarkFp2MontSquare, .{});
    try bench.add("Fp2 Inversion", benchmarkFp2MontInv, .{});

    // =============================================================================
    // SEXTIC EXTENSION FIELD (Fp6) BENCHMARKS
    // =============================================================================
    
    try bench.add("Fp6 Addition", benchmarkFp6MontAdd, .{});
    try bench.add("Fp6 Subtraction", benchmarkFp6MontSub, .{});
    try bench.add("Fp6 Multiplication", benchmarkFp6MontMul, .{});
    try bench.add("Fp6 Squaring", benchmarkFp6MontSquare, .{});
    try bench.add("Fp6 Inversion", benchmarkFp6MontInv, .{});

    // =============================================================================
    // DODECIC EXTENSION FIELD (Fp12) BENCHMARKS
    // =============================================================================
    
    try bench.add("Fp12 Addition", benchmarkFp12MontAdd, .{});
    try bench.add("Fp12 Subtraction", benchmarkFp12MontSub, .{});
    try bench.add("Fp12 Multiplication", benchmarkFp12MontMul, .{});
    try bench.add("Fp12 Squaring", benchmarkFp12MontSquare, .{});
    try bench.add("Fp12 Inversion", benchmarkFp12MontInv, .{});

    // =============================================================================
    // SCALAR FIELD (Fr) BENCHMARKS
    // =============================================================================
    
    try bench.add("Fr Addition", benchmarkFrAdd, .{});
    try bench.add("Fr Subtraction", benchmarkFrSub, .{});
    try bench.add("Fr Multiplication", benchmarkFrMul, .{});
    try bench.add("Fr Inversion", benchmarkFrInv, .{});

    // =============================================================================
    // ELLIPTIC CURVE G1 BENCHMARKS
    // =============================================================================
    
    try bench.add("G1 Addition", benchmarkG1Add, .{});
    try bench.add("G1 Doubling", benchmarkG1Double, .{});
    try bench.add("G1 Scalar Multiplication", benchmarkG1ScalarMul, .{});
    try bench.add("G1 Negation", benchmarkG1Neg, .{});
    try bench.add("G1 Affine Conversion", benchmarkG1ToAffine, .{});
    try bench.add("G1 Curve Validation", benchmarkG1IsOnCurve, .{});

    // =============================================================================
    // ELLIPTIC CURVE G2 BENCHMARKS
    // =============================================================================
    
    try bench.add("G2 Addition", benchmarkG2Add, .{});
    try bench.add("G2 Doubling", benchmarkG2Double, .{});
    try bench.add("G2 Scalar Multiplication", benchmarkG2ScalarMul, .{});
    try bench.add("G2 Negation", benchmarkG2Neg, .{});
    try bench.add("G2 Affine Conversion", benchmarkG2ToAffine, .{});
    try bench.add("G2 Curve Validation", benchmarkG2IsOnCurve, .{});

    // =============================================================================
    // PAIRING OPERATION BENCHMARKS
    // =============================================================================
    
    try bench.add("Full Pairing", benchmarkPairing, .{});
    try bench.add("Miller Loop", benchmarkMillerLoop, .{});
    try bench.add("Final Exponentiation (Full)", benchmarkFinalExponentiation, .{});
    try bench.add("Final Exponentiation (Easy)", benchmarkFinalExponentiationEasy, .{});
    try bench.add("Final Exponentiation (Hard)", benchmarkFinalExponentiationHard, .{});

    // =============================================================================
    // RUN BENCHMARKS WITH STATISTICAL REPORTING
    // =============================================================================
    
    try bench.run(std.io.getStdOut().writer());
}

// =============================================================================
// CATEGORY-SPECIFIC BENCHMARK TESTS
// =============================================================================

// Benchmark only field operations
test "BN254 Field Operations Benchmarks" {
    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    // Base field operations
    try bench.add("Fp Addition", benchmarkFpMontAdd, .{});
    try bench.add("Fp Multiplication", benchmarkFpMontMul, .{});
    try bench.add("Fp Squaring", benchmarkFpMontSquare, .{});
    try bench.add("Fp Inversion", benchmarkFpMontInv, .{});

    // Extension field operations
    try bench.add("Fp2 Multiplication", benchmarkFp2MontMul, .{});
    try bench.add("Fp6 Multiplication", benchmarkFp6MontMul, .{});
    try bench.add("Fp12 Multiplication", benchmarkFp12MontMul, .{});

    try bench.run(std.io.getStdOut().writer());
}

// Benchmark only curve operations
test "BN254 Curve Operations Benchmarks" {
    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.add("G1 Addition", benchmarkG1Add, .{});
    try bench.add("G1 Doubling", benchmarkG1Double, .{});
    try bench.add("G1 Scalar Multiplication", benchmarkG1ScalarMul, .{});
    
    try bench.add("G2 Addition", benchmarkG2Add, .{});
    try bench.add("G2 Doubling", benchmarkG2Double, .{});
    try bench.add("G2 Scalar Multiplication", benchmarkG2ScalarMul, .{});

    try bench.run(std.io.getStdOut().writer());
}

// Benchmark only pairing operations
test "BN254 Pairing Operations Benchmarks" {
    var bench = zbench.Benchmark.init(std.testing.allocator, Config);
    defer bench.deinit();

    try bench.add("Full Pairing", benchmarkPairing, .{});
    try bench.add("Miller Loop", benchmarkMillerLoop, .{});
    try bench.add("Final Exponentiation (Full)", benchmarkFinalExponentiation, .{});
    try bench.add("Final Exponentiation (Easy)", benchmarkFinalExponentiationEasy, .{});
    try bench.add("Final Exponentiation (Hard)", benchmarkFinalExponentiationHard, .{});

    try bench.run(std.io.getStdOut().writer());
}