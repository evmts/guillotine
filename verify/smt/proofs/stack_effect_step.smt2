;; ==========================================================================
;; Theorem : stack_effect_step
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL i32 height and ALL u8 inputs, outputs, stackEffectStep(height, inputs, outputs):
;;     low  = clamp_i32(height - inputs)
;;     high = clamp_i32(low + outputs)
;;   in 64-bit signed integer arithmetic, where clamp_i32 saturates into [minInt(i32), maxInt(i32)].
;;   No step can overflow i32, however long the block is. When neither saturates,
;;   high = height - inputs + outputs exactly.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:480 (stackEffectStep)
;;   | pub inline fn stackEffectStep(height: i32, inputs: u8, outputs: u8) struct { low: i32, high: i32 }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const height (_ BitVec 32))
(declare-const inputs (_ BitVec 8))
(declare-const outputs (_ BitVec 8))
; verified_ops.zig stackEffectStep: low = height -| inputs (LLVM ssub.sat), high = low +| outputs (sadd.sat).
; Both operands are non-negative, so the subtraction can only underflow and the addition only overflow.
(define-fun stepLow ((h (_ BitVec 32)) (i (_ BitVec 8))) (_ BitVec 32)
  (let ((d (bvsub h ((_ zero_extend 24) i))))
    (ite (and (bvslt h #x00000000) (bvsge d #x00000000)) #x80000000 d)))
(define-fun stepHigh ((l (_ BitVec 32)) (o (_ BitVec 8))) (_ BitVec 32)
  (let ((s (bvadd l ((_ zero_extend 24) o))))
    (ite (and (bvsge l #x00000000) (bvslt s #x00000000)) #x7fffffff s)))
(define-fun clampI32 ((x (_ BitVec 64))) (_ BitVec 64)
  (ite (bvslt x #xffffffff80000000) #xffffffff80000000
  (ite (bvsgt x #x000000007fffffff) #x000000007fffffff x)))
(define-fun low () (_ BitVec 32) (stepLow height inputs))
(define-fun high () (_ BitVec 32) (stepHigh low outputs))
(define-fun exactLow () (_ BitVec 64) (bvsub ((_ sign_extend 32) height) ((_ zero_extend 56) inputs)))
(define-fun exactHigh () (_ BitVec 64) (bvadd exactLow ((_ zero_extend 56) outputs)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= ((_ sign_extend 32) low) (clampI32 exactLow))
     (= ((_ sign_extend 32) high) (clampI32 (bvadd ((_ sign_extend 32) low) ((_ zero_extend 56) outputs))))
     (=> (and (= (clampI32 exactLow) exactLow) (= (clampI32 exactHigh) exactHigh))
         (= ((_ sign_extend 32) high) exactHigh)))))
(check-sat)
(exit)
