;; ==========================================================================
;; Theorem : saturating_min_stack_u16
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL i32 min_stack, minInt(i32) included:
;;     saturatingMinStackU16(min_stack) = min(max(-min_stack, 0), 65535)   (64-bit signed arithmetic),
;;   and on the negative branch -@as(i64, min_stack) lies in [1, 2^31], so its `@intCast` to u32
;;   is lossless and cannot trap. 10,923 LOG4 opcodes (min_stack = -65538) give 65535, not a panic.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:556 (saturatingMinStackU16)
;;   | pub inline fn saturatingMinStackU16(min_stack: i32) u16 {
;;   |     if (min_stack >= 0) return 0;
;;   |     const needed: u32 = @intCast(-@as(i64, min_stack));
;;   |     return @intCast(@min(needed, @as(u32, std.math.maxInt(u16))));
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const min_stack (_ BitVec 32))
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
(assert (not (and (= ((_ zero_extend 48) (saturatingMinStackU16 min_stack))
        (clampU16 (bvneg ((_ sign_extend 32) min_stack))))
     (=> (bvslt min_stack #x00000000)
         (and (bvsge (minNeeded64 min_stack) #x0000000000000001)
              (bvsle (minNeeded64 min_stack) #x0000000080000000)
              (= ((_ zero_extend 32) ((_ extract 31 0) (minNeeded64 min_stack))) (minNeeded64 min_stack))))
     (= (saturatingMinStackU16 #xfffefffe) #xffff)
     (= (saturatingMinStackU16 #x80000000) #xffff))))
(check-sat)
(exit)
