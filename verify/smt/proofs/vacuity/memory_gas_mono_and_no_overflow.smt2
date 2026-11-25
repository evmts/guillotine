;; ==========================================================================
;; Theorem : memory_gas_mono_and_no_overflow  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL words w1, w2 <= 524288 (memory_limit 0xFFFFFF = 16 MiB):
;;     (1) memoryGasCost(w) = 3w + floor(w^2/512) is computed exactly in u64 (no wrap),
;;     (2) memoryGasCost(w) <= 538443776,
;;     (3) memoryGasCost(524288) = 538443776 (the bound is tight),
;;     (4) w1 <= w2 implies memoryGasCost(w1) <= memoryGasCost(w2) (monotone).
;; Notes   :
;;   538443776 = 0x20180000 = 3*2^19 + 2^29.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:173 (memoryGasCost)
;;   | pub inline fn memoryGasCost(words: u64) u64 {
;;   |     return (words * 3) + ((words * words) >> 9);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

; A u64 `words <= 524288 = 2^19` is exactly the zero extension of a 20-bit value.
(declare-const a1 (_ BitVec 20))
(declare-const a2 (_ BitVec 20))
(define-fun w1 () (_ BitVec 64) ((_ zero_extend 44) a1))
(define-fun w2 () (_ BitVec 64) ((_ zero_extend 44) a2))
; verified_ops.zig memoryGasCost (u64 wrapping model)
(define-fun memoryGasCost ((words (_ BitVec 64))) (_ BitVec 64)
  (bvadd (bvmul words #x0000000000000003) (bvlshr (bvmul words words) #x0000000000000009)))
; Exact integer cost in 128 bits
(define-fun exactCost ((words (_ BitVec 64))) (_ BitVec 128)
  (let ((x ((_ zero_extend 64) words)))
    (bvadd (bvmul x ((_ zero_extend 64) #x0000000000000003))
           (bvlshr (bvmul x x) ((_ zero_extend 64) #x0000000000000009)))))

;; ---- Hypotheses
; domain: w1 <= 524288
(assert (bvule a1 #x80000))
; domain: w2 <= 524288
(assert (bvule a2 #x80000))

(check-sat)
(exit)
