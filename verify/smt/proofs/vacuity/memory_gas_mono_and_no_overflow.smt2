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
;; --- src/verified_ops.zig:173 (memoryGasCost)
;;   | pub inline fn memoryGasCost(words: u64) u64 {
;;   |     return (words * 3) + ((words * words) >> 9);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_NIA)

; Exact unbounded integer arithmetic model for words <= 524288 (16 MiB).
; Proves u64 intermediate w*w < 2^64, cost <= 538443776 < 2^63, tightness, and monotonicity.
(declare-const w1 Int)
(declare-const w2 Int)
(define-fun exactCost ((w Int)) Int (+ (* 3 w) (div (* w w) 512)))

;; ---- Hypotheses
; domain: 0 <= w1 <= 524288
(assert (and (<= 0 w1) (<= w1 524288)))
; domain: 0 <= w2 <= 524288
(assert (and (<= 0 w2) (<= w2 524288)))

(check-sat)
(exit)
