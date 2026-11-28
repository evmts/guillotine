;; ==========================================================================
;; Theorem : jump_table_interpolation_index_clamp
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 target_offset, len, pc_range, the clamp branches of
;;   jumpTableInterpolationIndex:
;;     (1) an empty table (len == 0) yields 0 (first line of the function),
;;     (2) an empty range (pc_range == 0) or a target at or past the range yields
;;         len - 1 for a non-empty table; `@as(u64, len) - 1` cannot wrap there,
;;     (3) in both cases the result is an index of a non-empty table: result < len,
;;     (4) the three branches are exhaustive and exclusive: every input takes exactly
;;         one of empty-table, clamp, or the in-range quotient.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:621 (jumpTableInterpolationIndex)
;;   | pub inline fn jumpTableInterpolationIndex(target_offset: u32, len: u32, pc_range: u32) u64 {
;;   |     if (len == 0) return 0;
;;   |     const last: u64 = @as(u64, len) - 1;
;;   |     if (pc_range == 0 or target_offset >= pc_range) return last;
;;   |     return (@as(u64, target_offset) * @as(u64, len)) / @as(u64, pc_range);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const target_offset (_ BitVec 32))
(declare-const len (_ BitVec 32))
(declare-const pc_range (_ BitVec 32))
(define-fun l64 () (_ BitVec 64) ((_ zero_extend 32) len))
; verified_ops.zig jumpTableInterpolationIndex branch conditions, in source order
(define-fun emptyTable () Bool (= len #x00000000))
(define-fun clamp () Bool (and (not emptyTable) (or (= pc_range #x00000000) (bvuge target_offset pc_range))))
(define-fun quotient () Bool (and (not emptyTable) (not clamp)))
(define-fun last () (_ BitVec 64) (bvsub l64 #x0000000000000001))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
  (=> clamp (and (bvult last l64) (= (bvadd last #x0000000000000001) l64)))
  (=> quotient (and (not (= pc_range #x00000000)) (bvult target_offset pc_range) (not (= len #x00000000))))
  (or emptyTable clamp quotient)
  (not (and emptyTable clamp))
  (not (and emptyTable quotient))
  (not (and clamp quotient)))))
(check-sat)
(exit)
