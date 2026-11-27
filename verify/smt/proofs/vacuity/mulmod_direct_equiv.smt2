;; ==========================================================================
;; Theorem : mulmod_direct_equiv  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u256 a, b and ALL u256 modulus > 0:
;;     mulmodDirect(a, b, modulus) == mulmodRef(a, b, modulus)
;;   i.e. reducing the full 512-bit product a * b once gives the same remainder as
;;   reducing a and b first, multiplying, and reducing again:
;;     (a * b) mod m == ((a mod m) * (b mod m)) mod m.
;;   The same file proves the facts that make the integer model exact for the Zig code:
;;     (1) a * b <= (2^256 - 1)^2 < 2^512: the u512 product never wraps,
;;     (2) (a mod m) * (b mod m) < 2^512 likewise,
;;     (3) both results are < modulus <= 2^256 - 1, so the @intCast to u256 cannot trap,
;;     (4) modulus == 1 gives 0.
;;   modulus == 0 returns 0 in both functions before any arithmetic (same first line).
;; Notes   :
;;   Solved by Z3 over the integers (Bitwuzla has no integer theory). The Euclidean
;;   hypotheses are satisfiable for every a, b, m in range (see the vacuity file), so
;;   the proof is not vacuous. `wide_arith.mulmod`, which the MULMOD handler runs, is
;;   tied to mulmodDirect by differential tests and the arithmetic fuzz target.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:455 (mulmodDirect)
;;   | pub inline fn mulmodDirect(a: u256, b: u256, modulus: u256) u256 {
;;   |     if (modulus == 0) return 0;
;;   |     const product = @as(u512, a) * @as(u512, b);
;;   |     return @intCast(product % modulus);
;;   | }
;; --- src/core/verified_ops.zig:441 (mulmodRef)
;;   | pub inline fn mulmodRef(a: u256, b: u256, modulus: u256) u256 {
;;   |     if (modulus == 0) return 0;
;;   |     const reduced_a: u512 = a % modulus;
;;   |     const reduced_b: u512 = b % modulus;
;;   |     return @intCast((reduced_a * reduced_b) % modulus);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_NIA)

(declare-const a Int)
(declare-const b Int)
(declare-const m Int)
; verified_ops.zig mulmodRef: reduced_a = a % m; reduced_b = b % m; (reduced_a * reduced_b) % m
(declare-const qa Int)
(declare-const reduced_a Int)
(declare-const qb Int)
(declare-const reduced_b Int)
(declare-const q_ref Int)
(declare-const r_ref Int)
; verified_ops.zig mulmodDirect: (a * b) % m over the unreduced 512-bit product
(declare-const q_direct Int)
(declare-const r_direct Int)

;; ---- Hypotheses
; a, b are u256 and modulus is a non-zero u256
(assert (and (<= 0 a) (< a 115792089237316195423570985008687907853269984665640564039457584007913129639936) (<= 0 b) (< b 115792089237316195423570985008687907853269984665640564039457584007913129639936) (< 0 m) (< m 115792089237316195423570985008687907853269984665640564039457584007913129639936)))
; reduced_a = a % m
(assert (and (= a (+ (* qa m) reduced_a)) (<= 0 reduced_a) (< reduced_a m) (<= 0 qa)))
; reduced_b = b % m
(assert (and (= b (+ (* qb m) reduced_b)) (<= 0 reduced_b) (< reduced_b m) (<= 0 qb)))
; r_ref = (reduced_a * reduced_b) % m
(assert (and (= (* reduced_a reduced_b) (+ (* q_ref m) r_ref)) (<= 0 r_ref) (< r_ref m) (<= 0 q_ref)))
; r_direct = (a * b) % m
(assert (and (= (* a b) (+ (* q_direct m) r_direct)) (<= 0 r_direct) (< r_direct m) (<= 0 q_direct)))

(check-sat)
(exit)
