const Fr = @import("Fr.zig");
const G1 = @import("G1.zig");
const G2 = @import("G2.zig");
const FpMont = @import("FpMont.zig");
const Fp2Mont = @import("Fp2Mont.zig");
const Fp6Mont = @import("Fp6Mont.zig");
const Fp12Mont = @import("Fp12Mont.zig");
const std = @import("std");
const curve_parameters = @import("curve_parameters.zig");

const FR_MOD = Fr.FR_MOD;
const miller_loop_constant_signed = curve_parameters.miller_loop_constant_signed;
const miller_loop_iterations = curve_parameters.miller_loop_iterations;
pub const CURVE_PARAM_T = curve_parameters.CURVE_PARAM_T;

pub const MontgomeryPointLine = struct {
    point: G2,
    line: Fp12Mont,
};

pub fn pairing(g1: *const G1, g2: *const G2) !Fp12Mont {
    const f = try millerLoop(g1, g2);
    return try finalExponentiation(&f);
}

/// One (G1, G2) input to a product of pairings.
pub const Pair = struct {
    g1: G1,
    g2: G2,
};

/// Pairs evaluated per shared Miller loop. Working state lives on the stack;
/// longer inputs run one shared loop per chunk and multiply the results.
pub const MULTI_MILLER_CHUNK: usize = 16;

/// Returns true when prod_i e(P_i, Q_i) == 1.
/// Runs one shared Miller loop per chunk of `MULTI_MILLER_CHUNK` pairs and a
/// single final exponentiation. Pairs with an infinity operand contribute 1.
pub fn multiPairing(pairs: []const Pair) !bool {
    var active: usize = 0;
    for (pairs) |pair| {
        if (!pair.g1.isInfinity() and !pair.g2.isInfinity()) active += 1;
    }
    if (active == 0) return true;
    const f = try multiMillerLoop(pairs);
    const result = try finalExponentiation(&f);
    return result.equal(&Fp12Mont.ONE);
}

/// Product of the Miller loops of all pairs, before final exponentiation.
/// Equals prod_i millerLoop(P_i, Q_i) but squares the accumulator once per
/// loop bit per chunk instead of once per bit per pair.
pub fn multiMillerLoop(pairs: []const Pair) !Fp12Mont {
    var result = Fp12Mont.ONE;
    var start: usize = 0;
    while (start < pairs.len) {
        const end = @min(start + MULTI_MILLER_CHUNK, pairs.len);
        const chunk = try multiMillerLoopChunk(pairs[start..end]);
        result.mulAssign(&chunk);
        start = end;
    }
    return result;
}

fn multiMillerLoopChunk(pairs: []const Pair) !Fp12Mont {
    if (pairs.len > MULTI_MILLER_CHUNK) return error.TooManyPairs;

    var p_affine: [MULTI_MILLER_CHUNK]G1 = undefined;
    var q_affine: [MULTI_MILLER_CHUNK]G2 = undefined;
    var q_negated: [MULTI_MILLER_CHUNK]G2 = undefined;
    var t: [MULTI_MILLER_CHUNK]G2 = undefined;
    var n: usize = 0;
    for (pairs) |pair| {
        if (pair.g1.isInfinity() or pair.g2.isInfinity()) continue;
        p_affine[n] = try pair.g1.toAffine();
        q_affine[n] = pair.g2.toAffine();
        q_negated[n] = q_affine[n].neg();
        t[n] = q_affine[n];
        n += 1;
    }

    var f = Fp12Mont.ONE;
    if (n == 0) return f;

    for (1..miller_loop_iterations + 1) |j| {
        const i = miller_loop_iterations - j;
        const signed_bit = miller_loop_constant_signed[i];
        f.squareAssign();
        for (0..n) |k| {
            const double_point_line = pointDoubleLineEvaluation(&p_affine[k], &t[k]);
            t[k] = double_point_line.point;
            f.mulAssign(&double_point_line.line);

            if (signed_bit == 1) {
                const add_point_line = pointAddLineEvaluation(&p_affine[k], &q_affine[k], &t[k]);
                t[k] = add_point_line.point;
                f.mulAssign(&add_point_line.line);
            } else if (signed_bit == -1) {
                const add_point_line = pointAddLineEvaluation(&p_affine[k], &q_negated[k], &t[k]);
                t[k] = add_point_line.point;
                f.mulAssign(&add_point_line.line);
            }
        }
    }

    for (0..n) |k| {
        const q1 = q_affine[k].frobenius();
        const q1_point_line = pointAddLineEvaluation(&p_affine[k], &q1, &t[k]);
        t[k] = q1_point_line.point;
        f.mulAssign(&q1_point_line.line);

        const q2 = q1.frobenius().neg();
        const q2_point_line = pointAddLineEvaluation(&p_affine[k], &q2, &t[k]);
        f.mulAssign(&q2_point_line.line);
    }
    return f;
}

pub fn millerLoop(p: *const G1, q: *const G2) !Fp12Mont {
    var result = Fp12Mont.ONE;
    if (p.isInfinity() or q.isInfinity()) {
        return result;
    }
    const p_affine = try p.toAffine();
    const q_affine = q.toAffine();
    var t = q_affine;
    for (1..miller_loop_iterations + 1) |j| {
        const i = miller_loop_iterations - j;
        const signed_bit = miller_loop_constant_signed[i];
        const double_point_line = pointDoubleLineEvaluation(&p_affine, &t);
        t = double_point_line.point;
        const double_line: Fp12Mont = double_point_line.line;
        result = result.square().mul(&double_line);

        if (signed_bit == 1) {
            const add_point_line = pointAddLineEvaluation(&p_affine, &q_affine, &t);
            t = add_point_line.point;
            const add_line: Fp12Mont = add_point_line.line;
            result.mulAssign(&add_line);
        } else if (signed_bit == -1) {
            const add_point_line = pointAddLineEvaluation(&p_affine, &q_affine.neg(), &t);
            t = add_point_line.point;
            const add_line: Fp12Mont = add_point_line.line;
            result.mulAssign(&add_line);
        }
    }

    const q1 = q_affine.frobenius();
    const q1_point_line = pointAddLineEvaluation(&p_affine, &q1, &t);
    t = q1_point_line.point;
    const q1_line: Fp12Mont = q1_point_line.line;
    result.mulAssign(&q1_line);

    const q2 = q1.frobenius().neg();
    const q2_point_line = pointAddLineEvaluation(&p_affine, &q2, &t);
    const q2_line: Fp12Mont = q2_point_line.line;
    result.mulAssign(&q2_line);
    return result;
}

pub fn finalExponentiation(f: *const Fp12Mont) !Fp12Mont {
    const easy_part = try finalExponentiationEasyPart(f);
    return finalExponentiationHardPart(&easy_part);
}

pub fn finalExponentiationEasyPart(f: *const Fp12Mont) !Fp12Mont {
    var result = f.*;
    for (0..6) |_| {
        result.frobeniusMapAssign();
    }
    // f should not be zero in a valid pairing computation
    // If inv() fails, return error instead of panicking
    const f_inv = try f.inv();
    result.mulAssign(&f_inv);
    result.mulAssign(&result.frobeniusMap().frobeniusMap());
    return result;
}

//this is algorithm 6 from this paper: https://eprint.iacr.org/2015/192.pdf
pub fn finalExponentiationHardPart(f: *const Fp12Mont) Fp12Mont {
    var t0 = f.powParamT().unaryInverse();

    t0.squareAssign();

    var t1 = t0.square();
    t1.mulAssign(&t0);

    var t2 = t1.powParamT().unaryInverse();
    var t3 = t1.unaryInverse();

    t1 = t2;
    t1.mulAssign(&t3);

    t3 = t2.square();
    var t4 = t3.powParamT().unaryInverse();

    t4.unaryInverseAssign();
    t4.mulAssign(&t1);

    t3 = t4;
    t3.mulAssign(&t0);

    t0 = t2;
    t0.mulAssign(&t4);

    t0.mulAssign(f);

    t2 = t3.frobeniusMap();

    t0.mulAssign(&t2);
    t2 = t4.frobeniusMap().frobeniusMap();

    t0.mulAssign(&t2);
    t2 = f.unaryInverse();

    t2.mulAssign(&t3);
    t2 = t2.frobeniusMap().frobeniusMap().frobeniusMap();

    t0.mulAssign(&t2);

    return t0;
}

// p needs to be in affine form
pub fn pointDoubleLineEvaluation(p: *const G1, q: *const G2) MontgomeryPointLine {
    var t0 = q.x.mul(&q.x);
    const t1 = q.y.mul(&q.y);
    const t2 = t1.mul(&t1);
    var t3 = t1.add(&q.x);
    t3.mulAssign(&t3);
    t3.subAssign(&t0.add(&t2));
    t3.addAssign(&t3);

    const t4 = t0.mulBySmallInt(3);
    var t6 = q.x.add(&t4);
    const t5 = t4.mul(&t4);

    const result_x = t5.sub(&t3.mulBySmallInt(2));
    const result_y = t3.sub(&result_x)
        .mul(&t4)
        .sub(&t2.mulBySmallInt(8));

    const result_z = q.y.add(&q.z).square()
        .sub(&t1)
        .sub(&q.z.square());

    t3 = t4.mul(&q.z.square()).mulBySmallInt(2).neg();

    t3.scalarMulAssign(&p.x);
    t6 = t6.square()
        .sub(&t0)
        .sub(&t5)
        .sub(&t1.mulBySmallInt(4));

    t0 = result_z.mul(&q.z.square()).mulBySmallInt(2);
    t0.scalarMulAssign(&p.y);

    const a0 = Fp6Mont{
        .v0 = t0,
        .v1 = Fp2Mont.ZERO,
        .v2 = Fp2Mont.ZERO,
    };

    const a1 = Fp6Mont{
        .v0 = t3,
        .v1 = t6,
        .v2 = Fp2Mont.ZERO,
    };

    const line = Fp12Mont{
        .w0 = a0,
        .w1 = a1,
    };

    const point = G2{
        .x = result_x,
        .y = result_y,
        .z = result_z,
    };

    return MontgomeryPointLine{ .point = point, .line = line };
}

pub fn pointAddLineEvaluation(p: *const G1, q: *const G2, r: *const G2) MontgomeryPointLine {
    // Miller-loop callers pass affine Q; skip the Fp2 inversion in that case.
    const q_affine = if (q.z.equal(&Fp2Mont.ONE)) q.* else q.toAffine();

    var t0 = q_affine.x.mul(&r.z.square());
    var t1 = q_affine.y.add(&r.z).square();
    t1.subAssign(&q_affine.y.square());
    t1.subAssign(&r.z.square());
    t1.mulAssign(&r.z.square());

    const t2 = t0.sub(&r.x);
    const t3 = t2.square();
    const t4 = t3.mulBySmallInt(4);
    const t5 = t4.mul(&t2);
    var t6 = t1.sub(&r.y.mulBySmallInt(2));
    var t9 = t6.mul(&q_affine.x);
    const t7 = r.x.mul(&t4);

    const result_x = t6.square().sub(&t5).sub(&t7.mulBySmallInt(2));
    const result_z = r.z.add(&t2).square()
        .sub(&r.z.square())
        .sub(&t3);

    var t10 = q.y.add(&result_z);
    const t8 = t7.sub(&result_x).mul(&t6);
    t0 = r.y.mul(&t5).mulBySmallInt(2);
    const result_y = t8.sub(&t0);

    t10 = t10.square()
        .sub(&q_affine.y.square())
        .sub(&result_z.square());

    t9 = t9.mulBySmallInt(2).sub(&t10);

    t10 = result_z.scalarMul(&p.y.mulBySmallInt(2));
    t6.negAssign();
    t1 = t6.scalarMul(&p.x.mulBySmallInt(2));

    const a0 = Fp6Mont{
        .v0 = t10,
        .v1 = Fp2Mont.ZERO,
        .v2 = Fp2Mont.ZERO,
    };

    const a1 = Fp6Mont{
        .v0 = t1,
        .v1 = t9,
        .v2 = Fp2Mont.ZERO,
    };

    const line = Fp12Mont{
        .w0 = a0,
        .w1 = a1,
    };

    const point = G2{
        .x = result_x,
        .y = result_y,
        .z = result_z,
    };

    return MontgomeryPointLine{ .point = point, .line = line };
}

test "finalExponentiation" {
    const test_values = [_]Fp12Mont{
        Fp12Mont.initFromInt(1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1),
        Fp12Mont.initFromInt(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12),
        Fp12Mont.initFromInt(123, 456, 789, 1011, 1213, 1415, 1617, 1819, 2021, 2223, 2425, 2627),
        Fp12Mont.initFromInt(999, 888, 777, 666, 555, 444, 333, 222, 111, 100, 99, 88),
        Fp12Mont.initFromInt(17, 23, 31, 47, 53, 61, 67, 71, 73, 79, 83, 89),
        Fp12Mont.initFromInt(2023, 2024, 2025, 2026, 2027, 2028, 2029, 2030, 2031, 2032, 2033, 2034),
        Fp12Mont.initFromInt(7, 6, 5, 4, 3, 2, 1, 0, 9, 8, 7, 6),
        Fp12Mont.initFromInt(13, 37, 73, 97, 137, 173, 197, 233, 277, 313, 337, 373),
    };

    for (test_values) |f| {
        const f_pow_r = f.pow(FR_MOD);
        const result = try finalExponentiation(&f_pow_r);
        try std.testing.expect(result.equal(&Fp12Mont.ONE));
    }
}

test "pairing bilinearity and infinity montgomery" {
    const test_cases = [_]struct { p1: u256, p2: u256, q1: u256, q2: u256, scalar: u256 }{
        .{ .p1 = 123, .p2 = 456, .q1 = 321, .q2 = 654, .scalar = 3 },
        .{ .p1 = 789, .p2 = 1011, .q1 = 987, .q2 = 1213, .scalar = 5 },
        .{ .p1 = 1337, .p2 = 2023, .q1 = 1729, .q2 = 2024, .scalar = 7 },
    };
    var i: u256 = 0;
    for (test_cases) |test_case| {
        i += 1;
        const p1 = try G1.GENERATOR.mulByInt(test_case.p1);
        const p2 = try G1.GENERATOR.mulByInt(test_case.p2);
        const q1 = G2.GENERATOR.mulByInt(test_case.q1);
        const q2 = G2.GENERATOR.mulByInt(test_case.q2);

        // Test bilinearity in first argument: e(P1 + P2, Q) = e(P1, Q) * e(P2, Q)
        const p1_plus_p2 = p1.add(&p2);
        const left_side_1 = try pairing(&p1_plus_p2, &q1);
        const e_p1_q1 = try pairing(&p1, &q1);
        const e_p2_q1 = try pairing(&p2, &q1);
        const right_side_1 = e_p1_q1.mul(&e_p2_q1);
        try std.testing.expect(left_side_1.equal(&right_side_1));

        // Test bilinearity in second argument: e(P, Q1 + Q2) = e(P, Q1) * e(P, Q2)
        const q1_plus_q2 = q1.add(&q2);
        const left_side_2 = try pairing(&p1, &q1_plus_q2);
        const e_p1_q2 = try pairing(&p1, &q2);
        const right_side_2 = e_p1_q1.mul(&e_p1_q2);
        try std.testing.expect(left_side_2.equal(&right_side_2));

        // Test scalar multiplication
        const scalar_times_p1 = try p1.mulByInt(test_case.scalar);
        const left_side_3 = try pairing(&scalar_times_p1, &q1);
        const right_side_3 = e_p1_q1.pow(test_case.scalar);
        try std.testing.expect(left_side_3.equal(&right_side_3));
    }

    //Test infinity properties
    const result_inf_gen = try pairing(&G1.INFINITY, &G2.GENERATOR);
    try std.testing.expect(result_inf_gen.equal(&Fp12Mont.ONE));

    const result_gen_inf = try pairing(&G1.GENERATOR, &G2.INFINITY);
    try std.testing.expect(result_gen_inf.equal(&Fp12Mont.ONE));

    const result_both_inf = try pairing(&G1.INFINITY, &G2.INFINITY);
    try std.testing.expect(result_both_inf.equal(&Fp12Mont.ONE));
}

test "multiMillerLoop equals product of single Miller loops" {
    const p1 = try G1.GENERATOR.mulByInt(3);
    const p2 = try G1.GENERATOR.mulByInt(11);
    const q1 = G2.GENERATOR.mulByInt(5);
    const q2 = G2.GENERATOR.mulByInt(7);
    const pairs = [_]Pair{
        .{ .g1 = p1, .g2 = q1 },
        .{ .g1 = G1.INFINITY, .g2 = q2 },
        .{ .g1 = p2, .g2 = q2 },
        .{ .g1 = p1, .g2 = G2.INFINITY },
    };
    const shared = try multiMillerLoop(&pairs);
    const single1 = try millerLoop(&p1, &q1);
    const single2 = try millerLoop(&p2, &q2);
    const expected = single1.mul(&single2);
    try std.testing.expect(shared.equal(&expected));
}

test "multiPairing e(P, Q) * e(-P, Q) == 1" {
    const p = try G1.GENERATOR.mulByInt(9);
    const q = G2.GENERATOR.mulByInt(4);
    const pairs = [_]Pair{
        .{ .g1 = p, .g2 = q },
        .{ .g1 = p.neg(), .g2 = q },
    };
    try std.testing.expect(try multiPairing(&pairs));
}

test "multiPairing e(2P, Q) * e(-P, 2Q) == 1" {
    const p = G1.GENERATOR;
    const q = G2.GENERATOR;
    const pairs = [_]Pair{
        .{ .g1 = p.double(), .g2 = q },
        .{ .g1 = p.neg(), .g2 = q.double() },
    };
    try std.testing.expect(try multiPairing(&pairs));
}

test "multiPairing single non-degenerate pair is not 1" {
    const pairs = [_]Pair{.{ .g1 = G1.GENERATOR, .g2 = G2.GENERATOR }};
    try std.testing.expect(!(try multiPairing(&pairs)));
}

test "multiPairing empty and all-infinity inputs are 1" {
    const empty = [_]Pair{};
    try std.testing.expect(try multiPairing(&empty));
    const pairs = [_]Pair{
        .{ .g1 = G1.INFINITY, .g2 = G2.GENERATOR },
        .{ .g1 = G1.GENERATOR, .g2 = G2.INFINITY },
    };
    try std.testing.expect(try multiPairing(&pairs));
}

test "multiPairing crosses the chunk boundary" {
    // 17 pairs with Q fixed: [G, 2G, -2G, 4G, -4G, ..., 14G, -14G, O, -G].
    // The first 16 fill one chunk; the 17th (-G) cancels pair 0 from the
    // second chunk, so the G1 scalars sum to 0 and the product is 1.
    var pairs: [MULTI_MILLER_CHUNK + 1]Pair = undefined;
    const q = G2.GENERATOR;
    pairs[0] = .{ .g1 = G1.GENERATOR, .g2 = q };
    for (1..MULTI_MILLER_CHUNK) |i| {
        const p = try G1.GENERATOR.mulByInt(@intCast(i + 1));
        pairs[i] = if (i % 2 == 1)
            .{ .g1 = p, .g2 = q }
        else
            .{ .g1 = pairs[i - 1].g1.neg(), .g2 = q };
    }
    pairs[MULTI_MILLER_CHUNK - 1] = .{ .g1 = G1.INFINITY, .g2 = q };
    pairs[MULTI_MILLER_CHUNK] = .{ .g1 = G1.GENERATOR.neg(), .g2 = q };
    try std.testing.expect(try multiPairing(&pairs));

    pairs[MULTI_MILLER_CHUNK] = .{ .g1 = G1.GENERATOR, .g2 = q };
    try std.testing.expect(!(try multiPairing(&pairs)));
}
