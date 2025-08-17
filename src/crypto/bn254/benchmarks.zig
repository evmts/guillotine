const std = @import("std");
const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const Fp12Mont = @import("Fp12Mont.zig");
const Fr = @import("Fr.zig").Fr;
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");
const pairing_mod = @import("pairing.zig");
const curve_parameters = @import("curve_parameters.zig");

// Constants
const FP_MOD = curve_parameters.FP_MOD;
const FR_MOD = curve_parameters.FR_MOD;

// Time formatting function to use appropriate scale
fn formatTime(ns: u64) struct { value: f64, unit: []const u8 } {
    if (ns < 1000) {
        return .{ .value = @as(f64, @floatFromInt(ns)), .unit = "ns" };
    } else if (ns < 1000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1000.0, .unit = "μs" };
    } else if (ns < 1000_000_000) {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1000_000.0, .unit = "ms" };
    } else {
        return .{ .value = @as(f64, @floatFromInt(ns)) / 1000_000_000.0, .unit = "s" };
    }
}

// Random element generators - using simple PRNG approach
var random_state: u64 = 12345;

fn nextRandom() u256 {
    random_state = random_state *% 1103515245 +% 12345;
    const high = @as(u256, random_state) << 192;
    random_state = random_state *% 1103515245 +% 12345;
    const mid_high = @as(u256, random_state) << 128;
    random_state = random_state *% 1103515245 +% 12345;
    const mid_low = @as(u256, random_state) << 64;
    random_state = random_state *% 1103515245 +% 12345;
    const low = @as(u256, random_state);
    return high | mid_high | mid_low | low;
}

fn randomFpMont() FpMont {
    return FpMont.init(nextRandom());
}

fn randomFp2Mont() Fp2Mont {
    return Fp2Mont.init_from_int(nextRandom(), nextRandom());
}

fn randomFp6Mont() Fp6Mont {
    return Fp6Mont.init_from_int(nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom());
}

fn randomFp12Mont() Fp12Mont {
    return Fp12Mont.init_from_int(nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom());
}

fn randomFr() Fr {
    return Fr.init(nextRandom());
}

fn randomG1() G1 {
    const scalar = randomFr();
    return G1.GENERATOR.mul(&scalar);
}

fn randomG2() G2 {
    const scalar = randomFr();
    return G2.GENERATOR.mul(&scalar);
}

// =============================================================================
// BASE FIELD OPERATIONS (FpMont)
// =============================================================================

test "benchmark FpMont.add" {
    const n = 500000;

    var inputs_a = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFpMont();
        inputs_b[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark FpMont.sub" {
    const n = 500000;

    var inputs_a = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFpMont();
        inputs_b[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.sub n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark FpMont.mul" {
    const n = 500000;

    var inputs_a = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFpMont();
        inputs_b[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark FpMont.square" {
    const n = 500000;

    var inputs = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.square n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark FpMont.pow" {
    const n = 5000;

    var inputs = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs);
    var exponents = try std.testing.allocator.alloc(u256, n);
    defer std.testing.allocator.free(exponents);

    for (0..n) |i| {
        inputs[i] = randomFpMont();
        exponents[i] = nextRandom();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.pow n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark FpMont.inv" {
    const n = 5000;

    var inputs = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFpMont();
        if (inputs[i].value == 0) inputs[i] = FpMont.ONE;
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("FpMont.inv n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// QUADRATIC EXTENSION FIELD OPERATIONS (Fp2Mont)
// =============================================================================

test "benchmark Fp2Mont.add" {
    const n = 100000;

    var inputs_a = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp2Mont();
        inputs_b[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.sub" {
    const n = 100000;
    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp2Mont();
        inputs_b[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.sub n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.mul" {
    const n = 100000;

    var inputs_a = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp2Mont();
        inputs_b[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.square" {
    const n = 100000;

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.square n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.pow" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);
    var exponents = try std.testing.allocator.alloc(u256, n);
    defer std.testing.allocator.free(exponents);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
        exponents[i] = nextRandom();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.pow n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.inv" {
    const n = 100000;

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
        if (inputs[i].u0.value == 0 and inputs[i].u1.value == 0) {
            inputs[i] = Fp2Mont.ONE;
        }
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.inv n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.neg" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.norm" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].norm();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].norm();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.norm n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.conj" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].conj();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].conj();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.conj n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.scalarMul" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(scalars);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
        scalars[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].scalarMul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].scalarMul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.scalarMul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp2Mont.frobeniusMap" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp2Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp2Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].frobeniusMap();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].frobeniusMap();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp2Mont.frobeniusMap n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// SEXTIC EXTENSION FIELD OPERATIONS (Fp6Mont)
// =============================================================================

test "benchmark Fp6Mont.add" {
    const n = 100000;

    var inputs_a = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp6Mont();
        inputs_b[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.sub" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp6Mont();
        inputs_b[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.sub n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.mul" {
    const n = 100000;

    var inputs_a = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp6Mont();
        inputs_b[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.square" {
    const n = 100000;

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.square n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.pow" {
    const n = 5000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);
    var exponents = try std.testing.allocator.alloc(u256, n);
    defer std.testing.allocator.free(exponents);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
        exponents[i] = nextRandom();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.pow n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.inv" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
        // Ensure non-zero
        if (inputs[i].v0.u0.value == 0 and inputs[i].v0.u1.value == 0 and
            inputs[i].v1.u0.value == 0 and inputs[i].v1.u1.value == 0 and
            inputs[i].v2.u0.value == 0 and inputs[i].v2.u1.value == 0)
        {
            inputs[i] = Fp6Mont.ONE;
        }
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.inv n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.neg" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.norm" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].norm();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].norm();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.norm n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp6Mont.scalarMul" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp6Mont, n);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(FpMont, n);
    defer std.testing.allocator.free(scalars);

    for (0..n) |i| {
        inputs[i] = randomFp6Mont();
        scalars[i] = randomFpMont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].scalarMul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].scalarMul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp6Mont.scalarMul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// DODECIC EXTENSION FIELD OPERATIONS (Fp12Mont)
// =============================================================================

test "benchmark Fp12Mont.add" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp12Mont();
        inputs_b[i] = randomFp12Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.sub" {
    const n = 100000;

    var inputs_a = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp12Mont();
        inputs_b[i] = randomFp12Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.sub n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.mul" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFp12Mont();
        inputs_b[i] = randomFp12Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.square" {
    const n = 10000;

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].square();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.square n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.pow" {
    const n = 500;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);
    var exponents = try std.testing.allocator.alloc(u256, n);
    defer std.testing.allocator.free(exponents);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
        exponents[i] = nextRandom();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.pow n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.inv" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
        // Ensure non-zero (simplified check)
        if (inputs[i].w0.v0.u0.value == 0 and inputs[i].w0.v0.u1.value == 0 and
            inputs[i].w0.v1.u0.value == 0 and inputs[i].w0.v1.u1.value == 0 and
            inputs[i].w0.v2.u0.value == 0 and inputs[i].w0.v2.u1.value == 0 and
            inputs[i].w1.v0.u0.value == 0 and inputs[i].w1.v0.u1.value == 0 and
            inputs[i].w1.v1.u0.value == 0 and inputs[i].w1.v1.u1.value == 0 and
            inputs[i].w1.v2.u0.value == 0 and inputs[i].w1.v2.u1.value == 0)
        {
            inputs[i] = Fp12Mont.ONE;
        }
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.inv n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fp12Mont.neg" {
    const n = 100000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fp12Mont.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// SCALAR FIELD OPERATIONS (Fr)
// =============================================================================

test "benchmark Fr.add" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFr();
        inputs_b[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fr.sub" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFr();
        inputs_b[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].sub(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.sub n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fr.mul" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomFr();
        inputs_b[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fr.pow" {
    const n = 1000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs);
    var exponents = try std.testing.allocator.alloc(u256, n);
    defer std.testing.allocator.free(exponents);

    for (0..n) |i| {
        inputs[i] = randomFr();
        exponents[i] = nextRandom();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].pow(exponents[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.pow n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fr.inv" {
    const n = 1000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFr();
        // Ensure non-zero
        if (inputs[i].value == 0) inputs[i] = Fr.ONE;
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].inv();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.inv n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark Fr.neg" {
    const n = 10000;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("Fr.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// GROUP OPERATIONS (G1)
// =============================================================================

test "benchmark G1.add" {
    const n = 200;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomG1();
        inputs_b[i] = randomG1();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G1.double" {
    const n = 200;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG1();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].double();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].double();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.double n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G1.mul" {
    const n = 250;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(scalars);

    for (0..n) |i| {
        inputs[i] = randomG1();
        scalars[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G1.neg" {
    const n = 500;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG1();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G1.toAffine" {
    const n = 200;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG1();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].toAffine();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].toAffine();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.toAffine n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G1.isOnCurve" {
    const n = 300;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG1();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].isOnCurve();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].isOnCurve();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G1.isOnCurve n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// GROUP OPERATIONS (G2)
// =============================================================================

test "benchmark G2.add" {
    const n = 100;

    // Random number generation
    // Using deterministic PRNG

    var inputs_a = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs_b);

    for (0..n) |i| {
        inputs_a[i] = randomG2();
        inputs_b[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.add n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G2.double" {
    const n = 100;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].double();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].double();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.double n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G2.mul" {
    const n = 50;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(Fr, n);
    defer std.testing.allocator.free(scalars);

    for (0..n) |i| {
        inputs[i] = randomG2();
        scalars[i] = randomFr();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.mul n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G2.neg" {
    const n = 200;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].neg();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.neg n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G2.toAffine" {
    const n = 100;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].toAffine();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].toAffine();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.toAffine n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark G2.isOnCurve" {
    const n = 100;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = inputs[i].isOnCurve();
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = inputs[i].isOnCurve();
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("G2.isOnCurve n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

// =============================================================================
// PAIRING OPERATIONS
// =============================================================================

test "benchmark pairing.pairing" {
    const n = 100;

    // Random number generation
    // Using deterministic PRNG

    var g1_inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(g1_inputs);
    var g2_inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(g2_inputs);

    for (0..n) |i| {
        g1_inputs[i] = randomG1();
        g2_inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = pairing_mod.pairing(&g1_inputs[i], &g2_inputs[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = pairing_mod.pairing(&g1_inputs[i], &g2_inputs[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("pairing.pairing n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark pairing.miller_loop" {
    const n = 25;

    // Random number generation
    // Using deterministic PRNG

    var g1_inputs = try std.testing.allocator.alloc(G1, n);
    defer std.testing.allocator.free(g1_inputs);
    var g2_inputs = try std.testing.allocator.alloc(G2, n);
    defer std.testing.allocator.free(g2_inputs);

    for (0..n) |i| {
        g1_inputs[i] = randomG1();
        g2_inputs[i] = randomG2();
    }

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const result = pairing_mod.miller_loop(&g1_inputs[i], &g2_inputs[i]);
        std.mem.doNotOptimizeAway(result);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        const result = pairing_mod.miller_loop(&g1_inputs[i], &g2_inputs[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("pairing.miller_loop n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark pairing.final_exponentiation" {
    const n = 10;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
    }

    var results = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(results);

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const tmp = pairing_mod.final_exponentiation(&inputs[i]);
        std.mem.doNotOptimizeAway(tmp);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        results[i] = pairing_mod.final_exponentiation(&inputs[i]);
        std.mem.doNotOptimizeAway(results[i]);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("pairing.final_exponentiation n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark pairing.final_exponentiation_hard_part" {
    const n = 10;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
    }

    var results = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(results);

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const tmp = pairing_mod.final_exponentiation_hard_part(&inputs[i]);
        std.mem.doNotOptimizeAway(tmp);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        results[i] = pairing_mod.final_exponentiation_hard_part(&inputs[i]);
        std.mem.doNotOptimizeAway(results[i]);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("pairing.final_exponentiation_hard_part n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}

test "benchmark pairing.final_exponentiation_easy_part" {
    const n = 10;

    // Random number generation
    // Using deterministic PRNG

    var inputs = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(inputs);

    for (0..n) |i| {
        inputs[i] = randomFp12Mont();
    }

    var results = try std.testing.allocator.alloc(Fp12Mont, n);
    defer std.testing.allocator.free(results);

    // dry run
    const dry = if (n < 10000) n else 10000;
    for (0..dry) |i| {
        const tmp = pairing_mod.final_exponentiation_easy_part(&inputs[i]);
        std.mem.doNotOptimizeAway(tmp);
    }

    const start = std.time.nanoTimestamp();
    for (0..n) |i| {
        results[i] = pairing_mod.final_exponentiation_easy_part(&inputs[i]);
        std.mem.doNotOptimizeAway(results[i]);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / n;
    // ops_per_sec calculation removed

    const time = formatTime(avg_ns);
    std.debug.print("pairing.final_exponentiation_easy_part n={}: {d:.2} {s}/op\n", .{ n, time.value, time.unit });
}
