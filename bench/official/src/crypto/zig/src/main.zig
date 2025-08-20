const std = @import("std");
const crypto = @import("crypto");
const bn254 = crypto.bn254;
const FpMont = bn254.FpMont;
const Fp2Mont = bn254.Fp2Mont;
const Fp6Mont = bn254.Fp6Mont;
const Fp12Mont = bn254.Fp12Mont;
const Fr = bn254.Fr;
const G1 = bn254.G1;
const G2 = bn254.G2;
const pairing = bn254.pairing;

const print = std.debug.print;

pub const std_options: std.Options = .{
    .log_level = .err,
};

fn nextRandom() u256 {
    return std.crypto.random.int(u256);
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

fn benchmarkOperation(allocator: std.mem.Allocator, operation: []const u8, internal_runs: usize) !f64 {
    if (std.mem.eql(u8, operation, "FpMont.add")) {
        var inputs_a = try allocator.alloc(FpMont, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(FpMont, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomFpMont();
            inputs_b[i] = randomFpMont();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].add(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "FpMont.mul")) {
        var inputs_a = try allocator.alloc(FpMont, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(FpMont, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomFpMont();
            inputs_b[i] = randomFpMont();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].mul(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "Fp2Mont.mul")) {
        var inputs_a = try allocator.alloc(Fp2Mont, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(Fp2Mont, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomFp2Mont();
            inputs_b[i] = randomFp2Mont();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].mul(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "Fp6Mont.mul")) {
        var inputs_a = try allocator.alloc(Fp6Mont, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(Fp6Mont, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomFp6Mont();
            inputs_b[i] = randomFp6Mont();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].mul(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "Fp12Mont.mul")) {
        var inputs_a = try allocator.alloc(Fp12Mont, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(Fp12Mont, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomFp12Mont();
            inputs_b[i] = randomFp12Mont();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].mul(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "G1.add")) {
        var inputs_a = try allocator.alloc(G1, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(G1, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomG1();
            inputs_b[i] = randomG1();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].add(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "G1.mul")) {
        var inputs = try allocator.alloc(G1, internal_runs);
        defer allocator.free(inputs);
        var scalars = try allocator.alloc(Fr, internal_runs);
        defer allocator.free(scalars);

        for (0..internal_runs) |i| {
            inputs[i] = randomG1();
            scalars[i] = randomFr();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs[i].mul(&scalars[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "G2.add")) {
        var inputs_a = try allocator.alloc(G2, internal_runs);
        defer allocator.free(inputs_a);
        var inputs_b = try allocator.alloc(G2, internal_runs);
        defer allocator.free(inputs_b);

        for (0..internal_runs) |i| {
            inputs_a[i] = randomG2();
            inputs_b[i] = randomG2();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs_a[i].add(&inputs_b[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "G2.mul")) {
        var inputs = try allocator.alloc(G2, internal_runs);
        defer allocator.free(inputs);
        var scalars = try allocator.alloc(Fr, internal_runs);
        defer allocator.free(scalars);

        for (0..internal_runs) |i| {
            inputs[i] = randomG2();
            scalars[i] = randomFr();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = inputs[i].mul(&scalars[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else if (std.mem.eql(u8, operation, "Pairing")) {
        var g1_inputs = try allocator.alloc(G1, internal_runs);
        defer allocator.free(g1_inputs);
        var g2_inputs = try allocator.alloc(G2, internal_runs);
        defer allocator.free(g2_inputs);

        for (0..internal_runs) |i| {
            g1_inputs[i] = randomG1();
            g2_inputs[i] = randomG2();
        }

        const start = std.time.nanoTimestamp();
        for (0..internal_runs) |i| {
            const result = pairing(&g1_inputs[i], &g2_inputs[i]);
            std.mem.doNotOptimizeAway(result);
        }
        const end = std.time.nanoTimestamp();

        const duration_ns = @as(u64, @intCast(end - start));
        return @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
    } else {
        std.debug.print("Error: Unknown operation '{s}'\n", .{operation});
        std.process.exit(1);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 5) {
        std.debug.print("Usage: {s} --operation <operation> --num-runs <runs>\n", .{args[0]});
        std.debug.print("Available operations: FpMont.add, FpMont.mul, Fp2Mont.mul, Fp6Mont.mul, Fp12Mont.mul, G1.add, G1.mul, G2.add, G2.mul, Pairing\n", .{});
        std.process.exit(1);
    }

    var operation: ?[]const u8 = null;
    var num_runs: u32 = 1;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--operation")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --operation requires a value\n", .{});
                std.process.exit(1);
            }
            operation = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--num-runs")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --num-runs requires a value\n", .{});
                std.process.exit(1);
            }
            num_runs = std.fmt.parseInt(u32, args[i + 1], 10) catch {
                std.debug.print("Error: --num-runs must be a number\n", .{});
                std.process.exit(1);
            };
            i += 1;
        } else {
            std.debug.print("Error: Unknown argument {s}\n", .{args[i]});
            std.process.exit(1);
        }
    }

    if (operation == null) {
        std.debug.print("Error: --operation is required\n", .{});
        std.process.exit(1);
    }

    // Internal runs scaled based on operation complexity for consistent ~10ms timing
    const internal_runs: usize = if (std.mem.eql(u8, operation.?, "FpMont.add"))
        100000
    else if (std.mem.eql(u8, operation.?, "FpMont.mul"))
        50000
    else if (std.mem.eql(u8, operation.?, "Fp2Mont.mul"))
        25000
    else if (std.mem.eql(u8, operation.?, "Fp6Mont.mul"))
        5000
    else if (std.mem.eql(u8, operation.?, "Fp12Mont.mul"))
        2500
    else if (std.mem.eql(u8, operation.?, "G1.add"))
        10000
    else if (std.mem.eql(u8, operation.?, "G1.mul"))
        500
    else if (std.mem.eql(u8, operation.?, "G2.add"))
        5000
    else if (std.mem.eql(u8, operation.?, "G2.mul"))
        200
    else if (std.mem.eql(u8, operation.?, "Pairing"))
        50
    else
        1000;

    // Run benchmark num_runs times, outputting timing in milliseconds for each run
    for (0..num_runs) |_| {
        const elapsed_ms = try benchmarkOperation(allocator, operation.?, internal_runs);
        print("{d:.6}\n", .{elapsed_ms});
    }
}