;; ==========================================================================
;; Theorem : sdiv_branchless_equiv  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (top, second): Guillotine's branchless SDIV
;;     sdivFromUnsignedQuotient(top, second, udiv(absTwoComp(top), absTwoComp(second)))
;;   equals the Yellow Paper SDIV:
;;     0                                  if second = 0
;;     -2^255                             if top = -2^255 and second = -1
;;     sgn(top*second) * floor(|top|/|second|)  otherwise.
;;   udiv is UNINTERPRETED; the only facts used are udiv(x,0)=0 and udiv(x,1)=x.
;;   The fast path contains no second==0 or MIN/-1 branch.
;; Notes   :
;;   Axioms are instantiated at every udiv application (QF_UFBV, no quantifiers).
;;   Dropping hypotheses only strengthens an unsat result, so the proof holds for
;;   every function satisfying the two axioms, including floor division of naturals.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:270 (sdivFromUnsignedQuotient)
;;   | pub inline fn sdivFromUnsignedQuotient(top: u256, second: u256, unsigned_quotient: u256) u256 {
;;   |     const top_sign = top >> 255;
;;   |     const second_sign = second >> 255;
;;   |     const result_sign = top_sign ^ second_sign;
;;   |     const result_mask = @as(u256, 0) -% result_sign;
;;   |     return (unsigned_quotient ^ result_mask) -% result_mask;
;;   | }
;; --- src/core/verified_ops.zig:279 (absTwoComp)
;;   | pub inline fn absTwoComp(x: u256) u256 {
;;   |     const sign = x >> 255;
;;   |     const mask = @as(u256, 0) -% sign;
;;   |     return (x ^ mask) -% mask;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_UFBV)
(define-sort Word () (_ BitVec 256))

(declare-fun udiv ((Word) (Word)) Word)
(declare-const top Word)
(declare-const second Word)
; verified_ops.zig absTwoComp: sign = x >> 255; mask = 0 -% sign; (x ^ mask) -% mask
(define-fun absTwoComp ((x Word)) Word
  (let ((mask (bvsub #x0000000000000000000000000000000000000000000000000000000000000000 (bvlshr x #x00000000000000000000000000000000000000000000000000000000000000ff))))
    (bvsub (bvxor x mask) mask)))
; Yellow Paper |x| for a two's-complement word, as an unsigned word (|MIN| = 2^255).
(define-fun specAbs ((x Word)) Word
  (ite (bvslt x #x0000000000000000000000000000000000000000000000000000000000000000) (bvneg x) x))
; verified_ops.zig sdivFromUnsignedQuotient
(define-fun sdivFast ((top Word) (second Word)) Word
  (let ((q (udiv (absTwoComp top) (absTwoComp second))))
  (let ((result_mask (bvsub #x0000000000000000000000000000000000000000000000000000000000000000 (bvxor (bvlshr top #x00000000000000000000000000000000000000000000000000000000000000ff) (bvlshr second #x00000000000000000000000000000000000000000000000000000000000000ff)))))
    (bvsub (bvxor q result_mask) result_mask))))
; Yellow Paper SDIV (explicit special cases, sign by comparison, negation by bvneg)
(define-fun sdivSpec ((a Word) (b Word)) Word
  (ite (= b #x0000000000000000000000000000000000000000000000000000000000000000) #x0000000000000000000000000000000000000000000000000000000000000000
  (ite (and (= a #x8000000000000000000000000000000000000000000000000000000000000000) (= b #xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) #x8000000000000000000000000000000000000000000000000000000000000000
  (let ((q (udiv (specAbs a) (specAbs b))))
    (ite (xor (bvslt a #x0000000000000000000000000000000000000000000000000000000000000000) (bvslt b #x0000000000000000000000000000000000000000000000000000000000000000)) (bvneg q) q)))))

;; ---- Hypotheses
; axiom udiv(x, 0) = 0  at x = (absTwoComp top)
(assert (=> (= (absTwoComp second) #x0000000000000000000000000000000000000000000000000000000000000000) (= (udiv (absTwoComp top) (absTwoComp second)) #x0000000000000000000000000000000000000000000000000000000000000000)))
; axiom udiv(x, 1) = x  at x = (absTwoComp top)
(assert (=> (= (absTwoComp second) #x0000000000000000000000000000000000000000000000000000000000000001) (= (udiv (absTwoComp top) (absTwoComp second)) (absTwoComp top))))
; axiom udiv(x, 0) = 0  at x = (specAbs top)
(assert (=> (= (specAbs second) #x0000000000000000000000000000000000000000000000000000000000000000) (= (udiv (specAbs top) (specAbs second)) #x0000000000000000000000000000000000000000000000000000000000000000)))
; axiom udiv(x, 1) = x  at x = (specAbs top)
(assert (=> (= (specAbs second) #x0000000000000000000000000000000000000000000000000000000000000001) (= (udiv (specAbs top) (specAbs second)) (specAbs top))))

(check-sat)
(exit)
