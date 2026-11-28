;; ==========================================================================
;; Theorem : jump_table_interpolation_index_bounds
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 target_offset, len, pc_range with len != 0, pc_range != 0 and
;;   target_offset < pc_range (the in-range branch of jumpTableInterpolationIndex,
;;   which returns (target_offset * len) / pc_range computed in u64):
;;     (1) the product never wraps: target_offset * len <= (2^32 - 1)^2 < 2^64,
;;     (2) the quotient is an index of the table: 0 <= index < len,
;;     (3) the quotient fits u32, so it also fits a 32-bit `usize` after the divide.
;;   Every other input takes a clamp branch, proved in
;;   `jump_table_interpolation_index_clamp`.
;; Notes   :
;;   Solved by Z3 over the integers (Bitwuzla has no integer theory). The Euclidean
;;   hypothesis is satisfiable for every in-range input (see the vacuity file).
;;   Regression model: with a 32-bit `usize`, target_offset = len = 65536 gives the
;;   product 2^32, which wraps to 0 and selects entry 0 instead of len / 2 for
;;   pc_range = 131072. Claim (1) rules that out for the u64 product.
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
(set-logic QF_NIA)

(declare-const target_offset Int)
(declare-const len Int)
(declare-const pc_range Int)
; verified_ops.zig jumpTableInterpolationIndex, in-range branch:
;   index = (target_offset * len) / pc_range, remainder `rest`
(declare-const index Int)
(declare-const rest Int)

;; ---- Hypotheses
; target_offset, len, pc_range are u32
(assert (and (<= 0 target_offset) (< target_offset 4294967296) (<= 0 len) (< len 4294967296) (<= 0 pc_range) (< pc_range 4294967296)))
; the function did not take a clamp branch
(assert (and (not (= len 0)) (not (= pc_range 0)) (< target_offset pc_range)))
; index = (target_offset * len) / pc_range
(assert (and (= (* target_offset len) (+ (* index pc_range) rest)) (<= 0 rest) (< rest pc_range) (<= 0 index)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (<= (* target_offset len) 18446744065119617025)
     (< (* target_offset len) 18446744073709551616)
     (<= 0 index)
     (< index len)
     (< index 4294967296))))
(check-sat)
(exit)
