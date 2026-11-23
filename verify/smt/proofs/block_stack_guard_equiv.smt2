;; ==========================================================================
;; Theorem : block_stack_guard_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 size, u16 min_stack, u16 max_stack, with stack_capacity = 1024:
;;   blockStackGuardFast = blockStackGuardRef (ok / underflow / overflow all agree), and
;;   min_u + max_u cannot wrap u32.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:102 (blockStackGuardRef)
;;   | pub inline fn blockStackGuardRef(
;;   |     size: u32,
;;   |     min_stack: u16,
;;   |     max_stack: u16,
;;   |     comptime stack_capacity: u32,
;;   | ) BlockStackResult {
;;   |     if (size < @as(u32, min_stack)) return .underflow;
;;   |     if (@as(u64, size) + @as(u64, max_stack) > @as(u64, stack_capacity)) return .overflow;
;;   |     return .ok;
;;   | }
;; --- src/verified_ops.zig:117 (blockStackGuardFast)
;;   | pub inline fn blockStackGuardFast(
;;   |     size: u32,
;;   |     min_stack: u16,
;;   |     max_stack: u16,
;;   |     comptime stack_capacity: u32,
;;   | ) BlockStackResult {
;;   |     const min_u: u32 = min_stack;
;;   |     const max_u: u32 = max_stack;
;;   |     const needed: u32 = min_u + max_u;
;;   |     if (needed <= stack_capacity) {
;;   |         if (size -% min_u <= stack_capacity - needed) {
;;   |             @branchHint(.likely);
;;   |             return .ok;
;;   |         }
;;   |     }
;;   |     return if (size < min_u) .underflow else .overflow;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const size (_ BitVec 32))
(declare-const min_stack (_ BitVec 16))
(declare-const max_stack (_ BitVec 16))
; BlockStackResult encoding: ok = 0, underflow = 1, overflow = 2
(define-fun OK () (_ BitVec 2) #b00)
(define-fun UNDERFLOW () (_ BitVec 2) #b01)
(define-fun OVERFLOW () (_ BitVec 2) #b10)
; verified_ops.zig blockStackGuardRef
(define-fun blockStackGuardRef ((size (_ BitVec 32)) (min_stack (_ BitVec 16)) (max_stack (_ BitVec 16)) (cap (_ BitVec 32))) (_ BitVec 2)
  (ite (bvult size ((_ zero_extend 16) min_stack)) UNDERFLOW
  (ite (bvugt (bvadd ((_ zero_extend 32) size) ((_ zero_extend 48) max_stack)) ((_ zero_extend 32) cap)) OVERFLOW
    OK)))
; verified_ops.zig blockStackGuardFast
(define-fun blockStackGuardFast ((size (_ BitVec 32)) (min_stack (_ BitVec 16)) (max_stack (_ BitVec 16)) (cap (_ BitVec 32))) (_ BitVec 2)
  (let ((min_u ((_ zero_extend 16) min_stack)) (max_u ((_ zero_extend 16) max_stack)))
  (let ((needed (bvadd min_u max_u)))
  (ite (and (bvule needed cap) (bvule (bvsub size min_u) (bvsub cap needed))) OK
    (ite (bvult size min_u) UNDERFLOW OVERFLOW)))))
(define-fun CAP () (_ BitVec 32) #x00000400)

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= (blockStackGuardFast size min_stack max_stack CAP) (blockStackGuardRef size min_stack max_stack CAP))
     (bvuge (bvadd ((_ zero_extend 16) min_stack) ((_ zero_extend 16) max_stack)) ((_ zero_extend 16) min_stack)))))
(check-sat)
(exit)
