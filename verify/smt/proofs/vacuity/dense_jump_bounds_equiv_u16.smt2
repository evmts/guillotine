;; ==========================================================================
;; Theorem : dense_jump_bounds_equiv_u16  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   PcType = u16. For ALL u256 dest and ALL u32 dense_len <= maxInt(u16) + 1:
;;   denseJumpInBoundsFast(dest, dense_len) = denseJumpInBoundsRef(dest, dense_len, u16),
;;   and the @intCast(dest) to u32 in the reference is in range when reached.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:295 (denseJumpInBoundsRef)
;;   | pub inline fn denseJumpInBoundsRef(dest: u256, dense_len: u32, comptime PcType: type) bool {
;;   |     if (dest > std.math.maxInt(PcType)) return false;
;;   |     const dest_pc: u32 = @intCast(dest);
;;   |     return dest_pc < dense_len;
;;   | }
;; --- src/core/verified_ops.zig:302 (denseJumpInBoundsFast)
;;   | pub inline fn denseJumpInBoundsFast(dest: u256, dense_len: u32) bool {
;;   |     return dest < @as(u256, dense_len);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const dest Word)
(declare-const dense_len (_ BitVec 32))
(define-fun MAX_PC () Word #x000000000000000000000000000000000000000000000000000000000000ffff)
; verified_ops.zig denseJumpInBoundsRef
(define-fun denseJumpInBoundsRef ((dest Word) (dense_len (_ BitVec 32))) Bool
  (ite (bvugt dest MAX_PC) false
    (bvult ((_ extract 31 0) dest) dense_len)))
; verified_ops.zig denseJumpInBoundsFast
(define-fun denseJumpInBoundsFast ((dest Word) (dense_len (_ BitVec 32))) Bool
  (bvult dest ((_ zero_extend 224) dense_len)))

;; ---- Hypotheses
; precondition: dense_len <= maxInt(u16) + 1
(assert (bvule ((_ zero_extend 32) dense_len) #x0000000000010000))

(check-sat)
(exit)
