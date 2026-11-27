;; ==========================================================================
;; Theorem : charge_gas_checked_i64
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL i64 gas_remaining and ALL u64 cost, chargeGasChecked(i64, gas, cost):
;;     (1) returns a value  iff  gas >= 0 and cost <= gas as mathematical integers,
;;     (2) when it returns a value, `@intCast(cost)` to i64 is lossless (cost <= maxInt(i64)),
;;         so the narrowing can neither trap (Debug/ReleaseSafe) nor wrap (ReleaseFast),
;;     (3) the value is exactly gas - cost (128-bit integer arithmetic),
;;     (4) the value lies in [0, gas].
;;   A cost wider than the gas type (maxInt(u64), 2^31 against i32) is always refused.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
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

(declare-const gas (_ BitVec 64))
(declare-const cost (_ BitVec 64))
; verified_ops.zig chargeGasChecked(i64, gas, cost): null unless gas >= 0 and cost <= gas
(define-fun chargeSome64 ((gas (_ BitVec 64)) (cost (_ BitVec 64))) Bool
  (and (not (bvslt gas #x0000000000000000))
       (not (bvugt cost gas))))
; the narrowing `@as(i64, @intCast(cost))` keeps the low 64 bits
(define-fun chargeNarrow64 ((cost (_ BitVec 64))) (_ BitVec 64) cost)
(define-fun chargeValue64 ((gas (_ BitVec 64)) (cost (_ BitVec 64))) (_ BitVec 64)
  (bvsub gas (chargeNarrow64 cost)))
; mathematical integers in 128-bit two's complement
(define-fun gasInt () (_ BitVec 128) ((_ sign_extend 64) gas))
(define-fun costInt () (_ BitVec 128) ((_ zero_extend 64) cost))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((some (chargeSome64 gas cost)) (value (chargeValue64 gas cost)))
  (and (= some (and (bvsge gasInt #x00000000000000000000000000000000) (bvsle costInt gasInt)))
       (=> some (bvule cost #x7fffffffffffffff))
       (=> some (= ((_ sign_extend 64) (chargeNarrow64 cost)) costInt))
       (=> some (= ((_ sign_extend 64) value) (bvsub gasInt costInt)))
       (=> some (and (bvsge value #x0000000000000000) (bvsle value gas)))))))
(check-sat)
(exit)
