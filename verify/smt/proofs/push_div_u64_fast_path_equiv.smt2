;; ==========================================================================
;; Theorem : push_div_u64_fast_path_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u64 dividend and ALL u256 divisor (2^320 inputs):
;;     pushDivU64(dividend, divisor) == pushDivRef(dividend, divisor)
;;   i.e. the fused PUSH+DIV fast path equals full 256-bit EVM division dividend / divisor
;;   with x / 0 = 0. The fast path returns 0 for a divisor >= 2^64 or == 0 and otherwise
;;   performs one 64-bit hardware divide. The result is < 2^64 and never exceeds the
;;   dividend. The dividend is the pushed (top) operand, as DIV computes top / second.
;; Notes   :
;;   Floor division is modeled by its Euclidean witnesses, which determine the
;;   quotient uniquely. `push_div_u64_guard` proves that the handler's bit tests select
;;   exactly these three cases and that the narrowed divisor equals the divisor.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:488 (pushDivU64)
;;   | pub inline fn pushDivU64(dividend: u64, divisor: u256) u64 {
;;   |     if ((divisor >> 64) != 0) return 0;
;;   |     const narrow: u64 = @truncate(divisor);
;;   |     if (narrow == 0 or narrow > dividend) return 0;
;;   |     return dividend / narrow;
;;   | }
;; --- src/core/verified_ops.zig:476 (pushDivRef)
;;   | pub inline fn pushDivRef(dividend: u64, divisor: u256) u256 {
;;   |     if (divisor == 0) return 0;
;;   |     return @as(u256, dividend) / divisor;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_NIA)

(declare-const dividend Int)
(declare-const divisor Int)
; pushDivRef: @as(u256, dividend) / divisor  (full-width floor division, divisor != 0)
(declare-const q_ref Int)
(declare-const r_ref Int)
; pushDivU64: dividend / narrow  (64-bit hardware divide, 0 < divisor < 2^64)
(declare-const q_fast Int)
(declare-const r_fast Int)
(define-fun ref () Int (ite (= divisor 0) 0 q_ref))
(define-fun fast () Int (ite (>= divisor 18446744073709551616) 0 (ite (= divisor 0) 0 q_fast)))

;; ---- Hypotheses
; dividend is a u64 and divisor a u256
(assert (and (<= 0 dividend) (< dividend 18446744073709551616) (<= 0 divisor) (< divisor 115792089237316195423570985008687907853269984665640564039457584007913129639936)))
; q_ref = dividend / divisor when divisor != 0
(assert (=> (not (= divisor 0)) (and (= dividend (+ (* q_ref divisor) r_ref)) (<= 0 r_ref) (< r_ref divisor) (<= 0 q_ref))))
; q_fast = dividend / divisor on the hardware-divide path
(assert (=> (and (not (= divisor 0)) (< divisor 18446744073709551616)) (and (= dividend (+ (* q_fast divisor) r_fast)) (<= 0 r_fast) (< r_fast divisor) (<= 0 q_fast))))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= fast ref)
     (<= 0 fast)
     (< fast 18446744073709551616)
     (<= fast dividend))))
(check-sat)
(exit)
