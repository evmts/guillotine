;; ==========================================================================
;; Theorem : push_div_u64_guard
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u256 divisor: pushDivU64's tests partition the input as the integer
;;   model of `push_div_u64_fast_path_equiv` assumes:
;;     (divisor >> 64) != 0            iff  divisor >= 2^64,
;;     and when divisor < 2^64 the truncated `narrow` equals divisor, so
;;     narrow == 0                     iff  divisor == 0.
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
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const divisor Word)
(define-fun wide () Bool (not (= (bvlshr divisor #x0000000000000000000000000000000000000000000000000000000000000040) #x0000000000000000000000000000000000000000000000000000000000000000)))
(define-fun narrow () (_ BitVec 64) ((_ extract 63 0) divisor))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= wide (bvuge divisor #x0000000000000000000000000000000000000000000000010000000000000000))
     (=> (not wide) (= ((_ zero_extend 192) narrow) divisor))
     (=> (not wide) (= (= narrow #x0000000000000000) (= divisor #x0000000000000000000000000000000000000000000000000000000000000000))))))
(check-sat)
(exit)
