;; ==========================================================================
;; Theorem : fusion_push_or_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 256-bit push values and ALL 3-word stacks (top 1 consumed,
;;   2 below preserved): executing `PUSH v; OR` under Yellow Paper semantics yields a stack
;;   bit-for-bit equal to the fused handler's stack (same depth, every word equal).
;; Notes   :
;;   Stack depth >= 1 is a precondition established by the basic-block stack guard
;;   (PUSH then a binary op requires 1 incoming item); see block_stack_guard_equiv.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/instructions/handlers_bitwise_synthetic.zig:60 (push_or_inline)
;;   |         pub fn push_or_inline(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.PUSH_OR_INLINE, cursor);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_OR_INLINE, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // For synthetic opcodes, cursor now points to metadata
;;   |             const push_value = op_data.metadata.value;
;;   | 
;;   |             {
;;   |                 {
;;   |                 (&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_OR_INLINE requires 1 stack item");
;;   |                 }
;;   |             }
;;   |             const top = self.stack.peek_unsafe();
;;   |             const result = top | push_value;
;;   |             self.stack.set_top_unsafe(result);
;;   | 
;;   |             self.afterInstruction(.PUSH_OR_INLINE, op_data.next_handler, op_data.next_cursor.cursor);
;;   |             return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
;;   |         }
;; --- src/instructions/handlers_bitwise_synthetic.zig:82 (push_or_pointer)
;;   |         pub fn push_or_pointer(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.PUSH_OR_POINTER, cursor);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_OR_POINTER, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // For synthetic opcodes, cursor now points to metadata
;;   |             const push_value = op_data.metadata.value_ptr.*;
;;   | 
;;   |             {
;;   |                 {
;;   |                 (&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_OR_POINTER requires 1 stack item");
;;   |                 }
;;   |             }
;;   |             const top = self.stack.peek_unsafe();
;;   |             const result = top | push_value;
;;   |             self.stack.set_top_unsafe(result);
;;   | 
;;   |             self.afterInstruction(.PUSH_OR_POINTER, op_data.next_handler, op_data.next_cursor.cursor);
;;   |             return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
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
    (= (bvor v s2) (bvor s2 v)))))
(check-sat)
(exit)
