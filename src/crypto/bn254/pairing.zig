const g1_mod = @import("g1.zig");
const g2_mod = @import("g2.zig");
const fr_mod = @import("Fr.zig");
const Fp_mod = @import("Fp.zig");
const Fp2_mod = @import("Fp2.zig");
const Fp6_mod = @import("Fp6.zig");
const Fp12_mod = @import("Fp12.zig");
const std = @import("std");

const Fp = Fp_mod.Fp;
const Fp2 = Fp2_mod.Fp2;
const Fp6 = Fp6_mod.Fp6;
const Fp12 = Fp12_mod.Fp12;
const G1 = g1_mod.G1;
const G2 = g2_mod.G2;
const Fr = fr_mod.Fr;

const FR_MOD = fr_mod.FR_MOD;

const miller_loop_constant_signed = &[_]i2{ 0, 0, 0, 1, 0, 1, 0, -1, 0, 0, -1, 0, 0, 0, 1, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, -1, 0, 0, 0, 0, -1, 0, 0, 1, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, -1, 0, 1, 0, -1, 0, 0, 0, -1, 0, -1, 0, 0, 0, 1, 0, 1, 1 };
//slightly better
const miller_loop_constant_signed2 = &[_]i2{ 0, 0, 0, 1, 0, 1, 0, -1, 0, 0, 1, -1, 0, 0, 1, 0, 0, 1, 1, 0, -1, 0, 0, 1, 0, -1, 0, 0, 0, 0, 1, 1, 1, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 1, 0, 0, -1, 0, 0, 0, 1, 1, 0, -1, 0, 0, 1, 0, 1, 1 };

const miller_loop_constant = 29793968203157093288;
const miller_loop_iterations = 64;
const final_exponentiation_constant = 552484233613224096312617126783173147097382103762957654188882734314196910839907541213974502761540629817009608548654680343627701153829446747810907373256841551006201639677726139946029199968412598804882391702273019083653272047566316584365559776493027495458238373902875937659943504873220554161550525926302303331747463515644711876653177129578303191095900909191624817826566688241804408081892785725967931714097716709526092261278071952560171111444072049229123565057483750161460024353346284167282452756217662335528813519139808291170539072125381230815729071544861602750936964829313608137325426383735122175229541155376346436093930287402089517426973178917569713384748081827255472576937471496195752727188261435633271238710131736096299798168852925540549342330775279877006784354801422249722573783561685179618816480037695005515426162362431072245638324744480;
const final_exponentiation_constant_hard_part = 10486551571378427818905133077457505975217533156541166536005452068033223782873764572151541189142778783267711471998854717549389605644966361077867290379973073897271417449614939788000730910148473503528371060814157528868116901618729649;

pub const point_line = struct {
    point: G2,
    line: Fp12,
};

pub fn pairing(g1: *const G1, g2: *const G2) Fp12 {
    const f = miller_loop(g1, g2);
    return final_exponentiation(&f);
}

pub fn miller_loop(p: *const G1, q: *const G2) Fp12 {
    var result = Fp12.ONE;
    if (p.isInfinity() or q.isInfinity()) {
        return result;
    }
    const p_affine = p.toAffine();
    const q_affine = q.toAffine();
    var t = q_affine;
    for (1..miller_loop_iterations + 1) |j| {
        const i = miller_loop_iterations - j;
        const signed_bit = miller_loop_constant_signed2[i];
        const double_point_line = point_double_line_evaluation(&p_affine, &t);
        t = double_point_line.point;
        const double_line: Fp12 = double_point_line.line;
        result = result.square().mul(&double_line);

        if (signed_bit == 1) {
            const add_point_line = point_add_line_evaluation(&p_affine, &q_affine, &t);
            t = add_point_line.point;
            const add_line: Fp12 = add_point_line.line;
            result.mulAssign(&add_line);
        } else if (signed_bit == -1) {
            const add_point_line = point_add_line_evaluation(&p_affine, &q_affine.neg(), &t);
            t = add_point_line.point;
            const add_line: Fp12 = add_point_line.line;
            result.mulAssign(&add_line);
        }
    }

    const q1 = q_affine.frobenius();
    const q1_point_line = point_add_line_evaluation(&p_affine, &q1, &t);
    t = q1_point_line.point;
    const q1_line: Fp12 = q1_point_line.line;
    result.mulAssign(&q1_line);

    const q2 = q1.frobenius().neg();
    const q2_point_line = point_add_line_evaluation(&p_affine, &q2, &t);
    //t = q2_point_line.point;
    const q2_line: Fp12 = q2_point_line.line;
    result.mulAssign(&q2_line);
    return result;
}

pub fn final_exponentiation(f: *const Fp12) Fp12 {
    const easy_part = final_exponentiation_easy_part(f);
    return final_exponentiation_hard_part(&easy_part);
}

pub fn final_exponentiation_easy_part(f: *const Fp12) Fp12 {
    var result = f.*;
    for (0..6) |_| {
        result.frobeniusMapAssign();
    }
    result.mulAssign(&f.inv());
    result.mulAssign(&result.frobeniusMap().frobeniusMap());
    return result;
}

pub fn final_exponentiation_hard_part(f: *const Fp12) Fp12 {
    var result = Fp12.ONE;
    var base = f.*;
    var exp: u780 = final_exponentiation_constant_hard_part;
    while (exp > 0) {
        if (exp & 1 == 1) {
            result.mulAssign(&base);
        }
        base.mulAssign(&base);
        exp >>= 1;
    }
    return result;
}

// p needs to be in affine form
pub fn point_double_line_evaluation(p: *const G1, q: *const G2) point_line {
    var t0 = q.x.mul(&q.x);
    const t1 = q.y.mul(&q.y);
    const t2 = t1.mul(&t1);
    var t3 = t1.add(&q.x);
    t3.mulAssign(&t3);
    t3.subAssign(&t0.add(&t2));
    t3.addAssign(&t3);

    const t4 = t0.scalarMul(&Fp.init(3));
    var t6 = q.x.add(&t4);
    const t5 = t4.mul(&t4);

    const result_x = t5.sub(&t3.scalarMul(&Fp.init(2)));
    const result_y = t3.sub(&result_x)
        .mul(&t4)
        .sub(&t2.scalarMul(&Fp.init(8)));

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

    const a0 = Fp6{
        .v0 = t0,
        .v1 = Fp2.ZERO,
        .v2 = Fp2.ZERO,
    };

    const a1 = Fp6{
        .v0 = t3,
        .v1 = t6,
        .v2 = Fp2.ZERO,
    };

    const line = Fp12{
        .w0 = a0,
        .w1 = a1,
    };

    const point = G2{
        .x = result_x,
        .y = result_y,
        .z = result_z,
    };

    return point_line{ .point = point, .line = line };
}

pub fn point_add_line_evaluation(p: *const G1, q: *const G2, r: *const G2) point_line {
    var t0 = q.x.mul(&r.z.square());
    var t1 = q.y.add(&r.z).square();
    t1.subAssign(&q.y.square());
    t1.subAssign(&r.z.square());
    t1.mulAssign(&r.z.square());

    const t2 = t0.sub(&r.x);
    const t3 = t2.square();
    const t4 = t3.mulBySmallInt(4);
    const t5 = t4.mul(&t2);
    var t6 = t1.sub(&r.y.mulBySmallInt(2));
    var t9 = t6.mul(&q.x);
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
        .sub(&q.y.square())
        .sub(&result_z.square());

    t9 = t9.mulBySmallInt(2).sub(&t10);

    t10 = result_z.scalarMul(&p.y.mulBySmallInt(2));
    t6.negAssign();
    t1 = t6.scalarMul(&p.x.mulBySmallInt(2));

    const a0 = Fp6{
        .v0 = t10,
        .v1 = Fp2.ZERO,
        .v2 = Fp2.ZERO,
    };

    const a1 = Fp6{
        .v0 = t1,
        .v1 = t9,
        .v2 = Fp2.ZERO,
    };

    const line = Fp12{
        .w0 = a0,
        .w1 = a1,
    };

    const point = G2{
        .x = result_x,
        .y = result_y,
        .z = result_z,
    };

    return point_line{ .point = point, .line = line };
}

test "final_exponentiation" {
    const test_values = [_]Fp12{
        Fp12.init_from_int(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12),
        Fp12.init_from_int(123, 456, 789, 1011, 1213, 1415, 1617, 1819, 2021, 2223, 2425, 2627),
        Fp12.init_from_int(999, 888, 777, 666, 555, 444, 333, 222, 111, 100, 99, 88),
        Fp12.init_from_int(17, 23, 31, 47, 53, 61, 67, 71, 73, 79, 83, 89),
        Fp12.init_from_int(2023, 2024, 2025, 2026, 2027, 2028, 2029, 2030, 2031, 2032, 2033, 2034),
        Fp12.init_from_int(7, 6, 5, 4, 3, 2, 1, 0, 9, 8, 7, 6),
        Fp12.init_from_int(13, 37, 73, 97, 137, 173, 197, 233, 277, 313, 337, 373),
    };

    for (test_values) |f| {
        const f_pow_r = f.pow(FR_MOD);
        const result = final_exponentiation(&f_pow_r);
        try std.testing.expect(result.equal(&Fp12.ONE));
    }
}

test "point_double_line_evaluation" {
    const p = G1.GENERATOR.mul_by_int(2987697);
    const q = G2.GENERATOR.mul_by_int(759765972);
    const q_times_2 = q.add(&q);
    const result = point_double_line_evaluation(&p, &q);
    try std.testing.expect(result.point.equal(&q_times_2));
}

test "point_add_line_evaluation" {
    const p = G1.GENERATOR.mul_by_int(1234567890);
    const q = G2.GENERATOR.mul_by_int(28769675);
    const q_times_2 = q.add(&q);
    // const q_times_3 = q_times_2.add(&q);
    const result = point_add_line_evaluation(&p, &q.neg().toAffine(), &q_times_2);
    try std.testing.expect(result.point.equal(&q));
}

test "pairing bilinearity and infinity" {
    const test_cases = [_]struct { p1: u256, p2: u256, q1: u256, q2: u256, scalar: u256 }{
        .{ .p1 = 123, .p2 = 456, .q1 = 321, .q2 = 654, .scalar = 3 },
        .{ .p1 = 789, .p2 = 1011, .q1 = 987, .q2 = 1213, .scalar = 5 },
        .{ .p1 = 1337, .p2 = 2023, .q1 = 1729, .q2 = 2024, .scalar = 7 },
    };
    var i: u256 = 0;
    for (test_cases) |test_case| {
        i += 1;
        const p1 = G1.GENERATOR.mul_by_int(test_case.p1);
        const p2 = G1.GENERATOR.mul_by_int(test_case.p2);
        const q1 = G2.GENERATOR.mul_by_int(test_case.q1);
        const q2 = G2.GENERATOR.mul_by_int(test_case.q2);

        // Test bilinearity in first argument: e(P1 + P2, Q) = e(P1, Q) * e(P2, Q)
        const p1_plus_p2 = p1.add(&p2);
        const left_side_1 = pairing(&p1_plus_p2, &q1);
        const e_p1_q1 = pairing(&p1, &q1);
        const e_p2_q1 = pairing(&p2, &q1);
        const right_side_1 = e_p1_q1.mul(&e_p2_q1);
        try std.testing.expect(left_side_1.equal(&right_side_1));

        // Test bilinearity in second argument: e(P, Q1 + Q2) = e(P, Q1) * e(P, Q2)
        const q1_plus_q2 = q1.add(&q2);
        const left_side_2 = pairing(&p1, &q1_plus_q2);
        const e_p1_q2 = pairing(&p1, &q2);
        const right_side_2 = e_p1_q1.mul(&e_p1_q2);
        try std.testing.expect(left_side_2.equal(&right_side_2));

        // Test scalar multiplication
        const scalar_times_p1 = p1.mul_by_int(test_case.scalar);
        const left_side_3 = pairing(&scalar_times_p1, &q1);
        const right_side_3 = e_p1_q1.pow(test_case.scalar);
        try std.testing.expect(left_side_3.equal(&right_side_3));
    }

    //Test infinity properties
    const result_inf_gen = pairing(&G1.INFINITY, &G2.GENERATOR);
    try std.testing.expect(result_inf_gen.equal(&Fp12.ONE));

    const result_gen_inf = pairing(&G1.GENERATOR, &G2.INFINITY);
    try std.testing.expect(result_gen_inf.equal(&Fp12.ONE));

    const result_both_inf = pairing(&G1.INFINITY, &G2.INFINITY);
    try std.testing.expect(result_both_inf.equal(&Fp12.ONE));
}
