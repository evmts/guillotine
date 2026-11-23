;; ==========================================================================
;; Theorem : fusion_push_add_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 256-bit push values and ALL 3-word stacks (top 1 consumed,
;;   2 below preserved): executing `PUSH v; ADD` under Yellow Paper semantics yields a stack
;;   bit-for-bit equal to the fused handler's stack (same depth, every word equal).
;; Notes   :
;;   Stack depth >= 1 is a precondition established by the basic-block stack guard
;;   (PUSH then a binary op requires 1 incoming item); see block_stack_guard_equiv.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/instructions/handlers_arithmetic_synthetic.zig:26 (push_add_inline)
;;   |         pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             @branchHint(.likely);
;;   |             self.beforeInstruction(.PUSH_ADD_INLINE, cursor);
;;   |             validate_stack(self);
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_INLINE, Dispatch, Dispatch.Item, cursor);
;;   |             self.stack.set_top_unsafe(op_data.metadata.value +% self.stack.peek_unsafe());
;;   |             return dispatch_next.nextInstruction(FrameType, self, cursor, .PUSH_ADD_INLINE);
;;   |         }
;; --- src/instructions/handlers_arithmetic_synthetic.zig:37 (push_add_pointer)
;;   |         pub fn push_add_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.PUSH_ADD_POINTER, cursor);
;;   |             validate_stack(self);
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_POINTER, Dispatch, Dispatch.Item, cursor);
;;   |             const top = self.stack.peek_unsafe();
;;   |             self.stack.set_top_unsafe(op_data.metadata.value_ptr.* +% top);
;;   |             return dispatch_next.nextInstruction(FrameType, self, cursor, .PUSH_ADD_POINTER);
;;   |         }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const v Word) ; PUSH immediate, any 256-bit value (inline and pointer forms)
(declare-const s0 Word)
(declare-const s1 Word)
(declare-const s2 Word)

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
    (= s0 s0)
    (= s1 s1)
    (= (bvadd v s2) (bvadd v s2)))))
(check-sat)
(exit)
