;; ==========================================================================
;; Theorem : smod_branchless_equiv  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (top, second): Guillotine's branchless SMOD
;;     smodFromUnsignedRem(top, urem(absTwoComp(top), absTwoComp(second)))
;;   equals the Yellow Paper SMOD:
;;     0                               if second = 0
;;     0                               if top = -2^255 and second = -1
;;     sgn(top) * (|top| mod |second|)  otherwise.
;;   urem is UNINTERPRETED; the only facts used are urem(x,0)=0 and urem(x,1)=0.
;;   The fast path contains no second==0 or MIN%-1 branch.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:288 (smodFromUnsignedRem)
;;   | pub inline fn smodFromUnsignedRem(top: u256, unsigned_rem: u256) u256 {
;;   |     const top_sign = top >> 255;
;;   |     const top_mask = @as(u256, 0) -% top_sign;
;;   |     return (unsigned_rem ^ top_mask) -% top_mask;
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

(declare-fun urem ((Word) (Word)) Word)
(declare-const top Word)
(declare-const second Word)
; verified_ops.zig absTwoComp: sign = x >> 255; mask = 0 -% sign; (x ^ mask) -% mask
(define-fun absTwoComp ((x Word)) Word
  (let ((mask (bvsub #x0000000000000000000000000000000000000000000000000000000000000000 (bvlshr x #x00000000000000000000000000000000000000000000000000000000000000ff))))
    (bvsub (bvxor x mask) mask)))
; Yellow Paper |x| for a two's-complement word, as an unsigned word (|MIN| = 2^255).
(define-fun specAbs ((x Word)) Word
  (ite (bvslt x #x0000000000000000000000000000000000000000000000000000000000000000) (bvneg x) x))
; verified_ops.zig smodFromUnsignedRem
(define-fun smodFast ((top Word) (second Word)) Word
  (let ((r (urem (absTwoComp top) (absTwoComp second))))
  (let ((top_mask (bvsub #x0000000000000000000000000000000000000000000000000000000000000000 (bvlshr top #x00000000000000000000000000000000000000000000000000000000000000ff))))
    (bvsub (bvxor r top_mask) top_mask))))
; Yellow Paper SMOD
(define-fun smodSpec ((a Word) (b Word)) Word
  (ite (= b #x0000000000000000000000000000000000000000000000000000000000000000) #x0000000000000000000000000000000000000000000000000000000000000000
  (ite (and (= a #x8000000000000000000000000000000000000000000000000000000000000000) (= b #xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff)) #x0000000000000000000000000000000000000000000000000000000000000000
  (let ((r (urem (specAbs a) (specAbs b))))
    (ite (bvslt a #x0000000000000000000000000000000000000000000000000000000000000000) (bvneg r) r)))))

;; ---- Hypotheses
; axiom urem(x, 0) = 0  at x = (absTwoComp top)
(assert (=> (= (absTwoComp second) #x0000000000000000000000000000000000000000000000000000000000000000) (= (urem (absTwoComp top) (absTwoComp second)) #x0000000000000000000000000000000000000000000000000000000000000000)))
; axiom urem(x, 1) = 0  at x = (absTwoComp top)
(assert (=> (= (absTwoComp second) #x0000000000000000000000000000000000000000000000000000000000000001) (= (urem (absTwoComp top) (absTwoComp second)) #x0000000000000000000000000000000000000000000000000000000000000000)))
; axiom urem(x, 0) = 0  at x = (specAbs top)
(assert (=> (= (specAbs second) #x0000000000000000000000000000000000000000000000000000000000000000) (= (urem (specAbs top) (specAbs second)) #x0000000000000000000000000000000000000000000000000000000000000000)))
; axiom urem(x, 1) = 0  at x = (specAbs top)
(assert (=> (= (specAbs second) #x0000000000000000000000000000000000000000000000000000000000000001) (= (urem (specAbs top) (specAbs second)) #x0000000000000000000000000000000000000000000000000000000000000000)))

(check-sat)
(exit)
