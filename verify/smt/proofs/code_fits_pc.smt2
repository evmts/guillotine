;; ==========================================================================
;; Theorem : code_fits_pc
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u64 code_len and ALL u64 pc_max:
;;     codeFitsPc(code_len, pc_max)  iff  code_len + 33 <= pc_max   (65-bit integer arithmetic).
;;   The subtraction pc_max - 33 is taken only when pc_max >= 33, so it never wraps, and the
;;   check never computes code_len + 33 (which wraps for lengths near 2^64).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:455 (codeFitsPc)
;;   | pub inline fn codeFitsPc(code_len: u64, pc_max: u64) bool {
;;   |     if (pc_max < pc_headroom) return false;
;;   |     return code_len <= pc_max - pc_headroom;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const code_len (_ BitVec 64))
(declare-const pc_max (_ BitVec 64))
; verified_ops.zig codeFitsPc
(define-fun codeFitsPc ((n (_ BitVec 64)) (m (_ BitVec 64))) Bool
  (ite (bvult m #x0000000000000021) false (bvule n (bvsub m #x0000000000000021))))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= (codeFitsPc code_len pc_max)
        (bvule (bvadd ((_ zero_extend 1) code_len) #b00000000000000000000000000000000000000000000000000000000000100001) ((_ zero_extend 1) pc_max)))
     (=> (not (bvult pc_max #x0000000000000021))
         (= ((_ zero_extend 1) (bvsub pc_max #x0000000000000021)) (bvsub ((_ zero_extend 1) pc_max) #b00000000000000000000000000000000000000000000000000000000000100001))))))
(check-sat)
(exit)
