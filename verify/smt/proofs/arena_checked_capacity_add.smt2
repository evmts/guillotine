;; ==========================================================================
;; Theorem : arena_checked_capacity_add
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 64-bit used, len, limit, checkedCapacityAdd(used, len, limit):
;;     (1) is some  iff  used + len <= limit over the integers (65-bit sum): a sum that
;;         does not fit 64 bits is refused, never wrapped,
;;     (2) when some, equals the exact integer sum, is at least `used` and at least
;;         `len`, and is at most `limit`.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:601 (checkedCapacityAdd)
;;   | pub inline fn checkedCapacityAdd(used: usize, len: usize, limit: usize) ?usize {
;;   |     const sum = @addWithOverflow(used, len);
;;   |     if (sum[1] != 0) return null;
;;   |     if (sum[0] > limit) return null;
;;   |     return sum[0];
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const used (_ BitVec 64))
(declare-const len (_ BitVec 64))
(declare-const limit (_ BitVec 64))
; @addWithOverflow(used, len): wrapped sum and carry
(define-fun sum () (_ BitVec 64) (bvadd used len))
(define-fun carry () Bool (bvult sum used))
; verified_ops.zig checkedCapacityAdd
(define-fun addSome () Bool (and (not carry) (not (bvugt sum limit))))
(define-fun exactSum () (_ BitVec 65) (bvadd ((_ zero_extend 1) used) ((_ zero_extend 1) len)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
  (= carry (= ((_ extract 64 64) exactSum) #b1))
  (= addSome (bvule exactSum ((_ zero_extend 1) limit)))
  (=> addSome (and (= ((_ zero_extend 1) sum) exactSum)
                   (bvuge sum used)
                   (bvuge sum len)
                   (bvule sum limit))))))
(check-sat)
(exit)
