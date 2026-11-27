;; ==========================================================================
;; Theorem : mulmod_u64_fast_path_equiv  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL a, b < 2^64 and ALL 0 < modulus < 2^64 (the operands MULMOD's one-limb
;;   path accepts): mulmodU64(a, b, modulus) == mulmodDirect(a, b, modulus), and
;;     (1) a * b < 2^128: the u128 product of the fast path never wraps,
;;     (2) the result is < 2^64, so the @intCast to u64 cannot trap.
;; Notes   :
;;   The two functions compute the same Euclidean remainder at different widths; the
;;   content of the theorem is that the narrow width is wide enough (goal 1) and that
;;   the remainder is unique. `mulmod_fits_u64_guard` proves the guard that selects
;;   this path.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:463 (mulmodU64)
;;   | pub inline fn mulmodU64(a: u64, b: u64, modulus: u64) u64 {
;;   |     if (modulus == 0) return 0;
;;   |     const product = @as(u128, a) * @as(u128, b);
;;   |     return @intCast(product % modulus);
;;   | }
;; --- src/core/verified_ops.zig:455 (mulmodDirect)
;;   | pub inline fn mulmodDirect(a: u256, b: u256, modulus: u256) u256 {
;;   |     if (modulus == 0) return 0;
;;   |     const product = @as(u512, a) * @as(u512, b);
;;   |     return @intCast(product % modulus);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_NIA)

(declare-const a Int)
(declare-const b Int)
(declare-const m Int)
; verified_ops.zig mulmodU64: (a * b) % m over the 128-bit product
(declare-const q_narrow Int)
(declare-const r_narrow Int)
; verified_ops.zig mulmodDirect: (a * b) % m over the 512-bit product
(declare-const q_direct Int)
(declare-const r_direct Int)

;; ---- Hypotheses
; a, b fit one limb and modulus is a non-zero limb
(assert (and (<= 0 a) (< a 18446744073709551616) (<= 0 b) (< b 18446744073709551616) (< 0 m) (< m 18446744073709551616)))
; r_narrow = (a * b) % m
(assert (and (= (* a b) (+ (* q_narrow m) r_narrow)) (<= 0 r_narrow) (< r_narrow m) (<= 0 q_narrow)))
; r_direct = (a * b) % m
(assert (and (= (* a b) (+ (* q_direct m) r_direct)) (<= 0 r_direct) (< r_direct m) (<= 0 q_direct)))

(check-sat)
(exit)
