const std = @import("std");
const bn254 = @import("../../../../src/crypto/bn254.zig");
const FpMont = bn254.FpMont;
const Fp2Mont = bn254.Fp2Mont;
const Fp6Mont = bn254.Fp6Mont;
const Fp12Mont = bn254.Fp12Mont;
const Fr = bn254.Fr;
const G1 = bn254.G1;
const G2 = bn254.G2;
const pairing = bn254.pairing;

const print = std.debug.print;

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

fn benchmarkFpMontAdd(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(FpMont, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(FpMont, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomFpMont();
        inputs_b[i] = randomFpMont();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("FpMont.add: {}ns/op\n", .{avg_ns});
}

fn benchmarkFpMontMul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(FpMont, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(FpMont, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomFpMont();
        inputs_b[i] = randomFpMont();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("FpMont.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkFp2MontMul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(Fp2Mont, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp2Mont, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomFp2Mont();
        inputs_b[i] = randomFp2Mont();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("Fp2Mont.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkFp6MontMul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(Fp6Mont, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp6Mont, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomFp6Mont();
        inputs_b[i] = randomFp6Mont();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("Fp6Mont.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkFp12MontMul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(Fp12Mont, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(Fp12Mont, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomFp12Mont();
        inputs_b[i] = randomFp12Mont();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].mul(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("Fp12Mont.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkG1Add(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(G1, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(G1, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomG1();
        inputs_b[i] = randomG1();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("G1.add: {}ns/op\n", .{avg_ns});
}

fn benchmarkG1Mul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs = try std.testing.allocator.alloc(G1, num_runs);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(Fr, num_runs);
    defer std.testing.allocator.free(scalars);

    for (0..num_runs) |i| {
        inputs[i] = randomG1();
        scalars[i] = randomFr();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("G1.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkG2Add(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs_a = try std.testing.allocator.alloc(G2, num_runs);
    defer std.testing.allocator.free(inputs_a);
    var inputs_b = try std.testing.allocator.alloc(G2, num_runs);
    defer std.testing.allocator.free(inputs_b);

    for (0..num_runs) |i| {
        inputs_a[i] = randomG2();
        inputs_b[i] = randomG2();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs_a[i].add(&inputs_b[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("G2.add: {}ns/op\n", .{avg_ns});
}

fn benchmarkG2Mul(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var inputs = try std.testing.allocator.alloc(G2, num_runs);
    defer std.testing.allocator.free(inputs);
    var scalars = try std.testing.allocator.alloc(Fr, num_runs);
    defer std.testing.allocator.free(scalars);

    for (0..num_runs) |i| {
        inputs[i] = randomG2();
        scalars[i] = randomFr();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = inputs[i].mul(&scalars[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("G2.mul: {}ns/op\n", .{avg_ns});
}

fn benchmarkPairing(allocator: std.mem.Allocator, num_runs: usize) !void {
    _ = allocator;
    
    var g1_inputs = try std.testing.allocator.alloc(G1, num_runs);
    defer std.testing.allocator.free(g1_inputs);
    var g2_inputs = try std.testing.allocator.alloc(G2, num_runs);
    defer std.testing.allocator.free(g2_inputs);

    for (0..num_runs) |i| {
        g1_inputs[i] = randomG1();
        g2_inputs[i] = randomG2();
    }

    const start = std.time.nanoTimestamp();
    for (0..num_runs) |i| {
        const result = pairing(&g1_inputs[i], &g2_inputs[i]);
        std.mem.doNotOptimizeAway(result);
    }
    const end = std.time.nanoTimestamp();

    const duration_ns = @as(u64, @intCast(end - start));
    const avg_ns = duration_ns / num_runs;
    print("Pairing: {}ns/op\n", .{avg_ns});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        print("Usage: {} <num_runs> [internal|external]\n", .{args[0]});
        return;
    }

    const num_runs = try std.fmt.parseInt(usize, args[1], 10);
    const is_external = if (args.len > 2) std.mem.eql(u8, args[2], "external") else false;

    if (is_external) {
        try benchmarkFpMontAdd(allocator, num_runs);
        try benchmarkFpMontMul(allocator, num_runs);
        try benchmarkFp2MontMul(allocator, num_runs);
        try benchmarkFp6MontMul(allocator, num_runs);
        try benchmarkFp12MontMul(allocator, num_runs);
        try benchmarkG1Add(allocator, num_runs);
        try benchmarkG1Mul(allocator, num_runs);
        try benchmarkG2Add(allocator, num_runs);
        try benchmarkG2Mul(allocator, num_runs);
        try benchmarkPairing(allocator, num_runs);
    } else {
        for (0..num_runs) |_| {
            try benchmarkFpMontAdd(allocator, 1000);
            try benchmarkFpMontMul(allocator, 1000);
            try benchmarkFp2MontMul(allocator, 500);
            try benchmarkFp6MontMul(allocator, 100);
            try benchmarkFp12MontMul(allocator, 50);
            try benchmarkG1Add(allocator, 200);
            try benchmarkG1Mul(allocator, 50);
            try benchmarkG2Add(allocator, 100);
            try benchmarkG2Mul(allocator, 25);
            try benchmarkPairing(allocator, 10);
        }
    }
}