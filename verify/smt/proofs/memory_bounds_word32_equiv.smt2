;; ==========================================================================
;; Theorem : memory_bounds_word32_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u256 offsets and size = 32 (MLOAD / MSTORE), with memory_limit L = 0xFFFFFF:
;;   checkMemoryBoundsFast(offset, size, L) = checkMemoryBoundsRef(offset, size, L).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:156 (checkMemoryBoundsRef)
;;   | pub inline fn checkMemoryBoundsRef(offset: u256, size: u64, comptime memory_limit: u64) bool {
;;   |     const max_usize: u256 = std.math.maxInt(u64);
;;   |     if (offset > max_usize) return false;
;;   |     const off_u: u64 = @intCast(offset);
;;   |     const res = @addWithOverflow(off_u, size);
;;   |     if (res[1] != 0) return false;
;;   |     return res[0] <= memory_limit;
;;   | }
;; --- src/core/verified_ops.zig:169 (checkMemoryBoundsFast)
;;   | pub inline fn checkMemoryBoundsFast(offset: u256, size: u64, comptime memory_limit: u64) bool {
;;   |     if (size > memory_limit) return false;
;;   |     return offset <= @as(u256, memory_limit - size);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const offset Word)
; verified_ops.zig checkMemoryBoundsRef
(define-fun checkMemoryBoundsRef ((offset Word) (size (_ BitVec 64)) (L (_ BitVec 64))) Bool
  (ite (bvugt offset ((_ zero_extend 192) #xffffffffffffffff)) false
  (let ((off_u ((_ extract 63 0) offset)))
  (let ((sum65 (bvadd ((_ zero_extend 1) off_u) ((_ zero_extend 1) size))))
  (ite (= ((_ extract 64 64) sum65) #b1) false
    (bvule ((_ extract 63 0) sum65) L))))))
; verified_ops.zig checkMemoryBoundsFast
(define-fun checkMemoryBoundsFast ((offset Word) (size (_ BitVec 64)) (L (_ BitVec 64))) Bool
  (ite (bvugt size L) false
    (bvule offset ((_ zero_extend 192) (bvsub L size)))))
(define-fun L () (_ BitVec 64) #x0000000000ffffff)

;; ---- Negated claim (a model would be a counterexample)
(assert (not (= (checkMemoryBoundsFast offset #x0000000000000020 L) (checkMemoryBoundsRef offset #x0000000000000020 L))))
(check-sat)
(exit)
