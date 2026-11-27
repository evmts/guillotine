;; ==========================================================================
;; Theorem : saturating_gas_sum
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u64 first, second: saturatingGasSum(first, second) = min(first + second, 2^64 - 1)
;;   in 65-bit integer arithmetic (it never wraps), and whenever the exact sum reaches
;;   2^64 - 1 the result is refused by chargeGasChecked for EVERY i32 and EVERY i64
;;   gas_remaining: a saturated composite cost always ends in out-of-gas.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:423 (saturatingGasSum)
;;   | pub inline fn saturatingGasSum(first: u64, second: u64) u64 {
;;   |     return first +| second;
;;   | }
;; --- src/core/verified_ops.zig:414 (chargeGasChecked)
;;   | pub inline fn chargeGasChecked(comptime GasType: type, gas_remaining: GasType, cost: u64) ?GasType {
;;   |     if (gas_remaining < 0) return null;
;;   |     const available: u64 = @intCast(gas_remaining);
;;   |     if (cost > available) return null;
;;   |     return gas_remaining - @as(GasType, @intCast(cost));
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const first (_ BitVec 64))
(declare-const second (_ BitVec 64))
(declare-const gas32 (_ BitVec 32))
(declare-const gas64 (_ BitVec 64))
; verified_ops.zig saturatingGasSum: first +| second (LLVM uadd.sat)
(define-fun saturatingGasSum ((a (_ BitVec 64)) (b (_ BitVec 64))) (_ BitVec 64)
  (let ((s (bvadd a b))) (ite (bvult s a) #xffffffffffffffff s)))
; verified_ops.zig chargeGasChecked(i32, gas, cost): null unless gas >= 0 and cost <= gas
(define-fun chargeSome32 ((gas (_ BitVec 32)) (cost (_ BitVec 64))) Bool
  (and (not (bvslt gas #x00000000))
       (not (bvugt cost ((_ zero_extend 32) gas)))))
; the narrowing `@as(i32, @intCast(cost))` keeps the low 32 bits
(define-fun chargeNarrow32 ((cost (_ BitVec 64))) (_ BitVec 32) ((_ extract 31 0) cost))
(define-fun chargeValue32 ((gas (_ BitVec 32)) (cost (_ BitVec 64))) (_ BitVec 32)
  (bvsub gas (chargeNarrow32 cost)))
; verified_ops.zig chargeGasChecked(i64, gas, cost): null unless gas >= 0 and cost <= gas
(define-fun chargeSome64 ((gas (_ BitVec 64)) (cost (_ BitVec 64))) Bool
  (and (not (bvslt gas #x0000000000000000))
       (not (bvugt cost gas))))
; the narrowing `@as(i64, @intCast(cost))` keeps the low 64 bits
(define-fun chargeNarrow64 ((cost (_ BitVec 64))) (_ BitVec 64) cost)
(define-fun chargeValue64 ((gas (_ BitVec 64)) (cost (_ BitVec 64))) (_ BitVec 64)
  (bvsub gas (chargeNarrow64 cost)))
(define-fun exactSum () (_ BitVec 65) (bvadd ((_ zero_extend 1) first) ((_ zero_extend 1) second)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((sum (saturatingGasSum first second)))
  (and (= ((_ zero_extend 1) sum)
          (ite (bvuge exactSum #b01111111111111111111111111111111111111111111111111111111111111111) #b01111111111111111111111111111111111111111111111111111111111111111 exactSum))
       (=> (bvuge exactSum #b01111111111111111111111111111111111111111111111111111111111111111)
           (and (not (chargeSome32 gas32 sum)) (not (chargeSome64 gas64 sum))))))))
(check-sat)
(exit)
