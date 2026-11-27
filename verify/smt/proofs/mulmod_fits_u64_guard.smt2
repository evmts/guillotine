;; ==========================================================================
;; Theorem : mulmod_fits_u64_guard
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u256 a, b, modulus: mulmodFitsU64(a, b, modulus), computed as
;;   ((a | b | modulus) >> 64) == 0, holds exactly when a < 2^64 and b < 2^64 and
;;   modulus < 2^64, and then truncating each operand to u64 loses nothing.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:470 (mulmodFitsU64)
;;   | pub inline fn mulmodFitsU64(a: u256, b: u256, modulus: u256) bool {
;;   |     return ((a | b | modulus) >> 64) == 0;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const a Word)
(declare-const b Word)
(declare-const m Word)
; verified_ops.zig mulmodFitsU64
(define-fun fits () Bool (= (bvlshr (bvor (bvor a b) m) #x0000000000000000000000000000000000000000000000000000000000000040) #x0000000000000000000000000000000000000000000000000000000000000000))
(define-fun narrow ((x Word)) Word ((_ zero_extend 192) ((_ extract 63 0) x)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= fits (and (bvult a #x0000000000000000000000000000000000000000000000010000000000000000) (bvult b #x0000000000000000000000000000000000000000000000010000000000000000) (bvult m #x0000000000000000000000000000000000000000000000010000000000000000)))
     (=> fits (and (= (narrow a) a) (= (narrow b) b) (= (narrow m) m))))))
(check-sat)
(exit)
