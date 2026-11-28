;; ==========================================================================
;; Theorem : charge_gas_checked_i32
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL i32 gas_remaining and ALL u64 cost, chargeGasChecked(i32, gas, cost):
;;     (1) returns a value  iff  gas >= 0 and cost <= gas as mathematical integers,
;;     (2) when it returns a value, `@intCast(cost)` to i32 is lossless (cost <= maxInt(i32)),
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

(declare-const gas (_ BitVec 32))
(declare-const cost (_ BitVec 64))
; verified_ops.zig chargeGasChecked(i32, gas, cost): null unless gas >= 0 and cost <= gas
(define-fun chargeSome32 ((gas (_ BitVec 32)) (cost (_ BitVec 64))) Bool
  (and (not (bvslt gas #x00000000))
       (not (bvugt cost ((_ zero_extend 32) gas)))))
; the narrowing `@as(i32, @intCast(cost))` keeps the low 32 bits
(define-fun chargeNarrow32 ((cost (_ BitVec 64))) (_ BitVec 32) ((_ extract 31 0) cost))
(define-fun chargeValue32 ((gas (_ BitVec 32)) (cost (_ BitVec 64))) (_ BitVec 32)
  (bvsub gas (chargeNarrow32 cost)))
; mathematical integers in 128-bit two's complement
(define-fun gasInt () (_ BitVec 128) ((_ sign_extend 96) gas))
(define-fun costInt () (_ BitVec 128) ((_ zero_extend 64) cost))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((some (chargeSome32 gas cost)) (value (chargeValue32 gas cost)))
  (and (= some (and (bvsge gasInt #x00000000000000000000000000000000) (bvsle costInt gasInt)))
       (=> some (bvule cost #x000000007fffffff))
       (=> some (= ((_ sign_extend 96) (chargeNarrow32 cost)) costInt))
       (=> some (= ((_ sign_extend 96) value) (bvsub gasInt costInt)))
       (=> some (and (bvsge value #x00000000) (bvsle value gas)))))))
(check-sat)
(exit)
