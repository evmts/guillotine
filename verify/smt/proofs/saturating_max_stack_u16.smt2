;; ==========================================================================
;; Theorem : saturating_max_stack_u16
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL i32 max_stack:
;;     saturatingMaxStackU16(max_stack) = min(max(max_stack, 0), 65535)   (64-bit signed arithmetic).
;;   The `@intCast` to u32 is taken only for max_stack > 0, where it is lossless.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:564 (saturatingMaxStackU16)
;;   | pub inline fn saturatingMaxStackU16(max_stack: i32) u16 {
;;   |     if (max_stack <= 0) return 0;
;;   |     const headroom: u32 = @intCast(max_stack);
;;   |     return @intCast(@min(headroom, @as(u32, std.math.maxInt(u16))));
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const max_stack (_ BitVec 32))
; verified_ops.zig saturatingMinStackU16: needed = @intCast(-@as(i64, min_stack)) as u32
(define-fun minNeeded64 ((m (_ BitVec 32))) (_ BitVec 64) (bvneg ((_ sign_extend 32) m)))
(define-fun saturatingMinStackU16 ((m (_ BitVec 32))) (_ BitVec 16)
  (ite (bvsge m #x00000000) #x0000
    (let ((needed ((_ extract 31 0) (minNeeded64 m))))
      ((_ extract 15 0) (ite (bvult needed #x0000ffff) needed #x0000ffff)))))
; verified_ops.zig saturatingMaxStackU16: headroom = @intCast(max_stack) as u32
(define-fun saturatingMaxStackU16 ((m (_ BitVec 32))) (_ BitVec 16)
  (ite (bvsle m #x00000000) #x0000
    ((_ extract 15 0) (ite (bvult m #x0000ffff) m #x0000ffff))))
; specification: clamp a 64-bit signed integer into [0, 65535]
(define-fun clampU16 ((x (_ BitVec 64))) (_ BitVec 64)
  (ite (bvslt x #x0000000000000000) #x0000000000000000 (ite (bvsgt x #x000000000000ffff) #x000000000000ffff x)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (= ((_ zero_extend 48) (saturatingMaxStackU16 max_stack))
   (clampU16 ((_ sign_extend 32) max_stack)))))
(check-sat)
(exit)
