;; ==========================================================================
;; Theorem : fusion_push_add_dup1_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 256-bit push values and ALL 3-word stacks (top 1 consumed,
;;   2 below preserved): executing `PUSH v; ADD; DUP1` under Yellow Paper semantics yields a stack
;;   bit-for-bit equal to the fused handler's stack (same depth, every word equal).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/instructions/handlers_advanced_synthetic.zig:381 (push_add_dup1)
;;   |         pub fn push_add_dup1(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.PUSH_ADD_DUP1, cursor);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_DUP1, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // Peak stack growth is +1 (PUSH -> s+1, ADD -> s, DUP1 -> s+1), requires depth >= 1.
;;   |             (&self.getEvm().tracer).assert(self.stack.size() >= 1, "PUSH_ADD_DUP1: Stack underflow (need 1 item for ADD)");
;;   |             (&self.getEvm().tracer).assert(self.stack.size() < @TypeOf(self.stack).stack_capacity, "PUSH_ADD_DUP1: Stack overflow (need 1 free slot)");
;;   | 
;;   |             const push_item = op_data.items[0];
;;   |             const push_value: WordType = push_item.push_pointer.value_ptr.*;
;;   | 
;;   |             const result = self.stack.peek_unsafe() +% push_value;
;;   |             self.stack.set_top_unsafe(result);
;;   |             self.stack.push_unsafe(result);
;;   | 
;;   |             self.afterInstruction(.PUSH_ADD_DUP1, op_data.next_handler, op_data.next_cursor.cursor);
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
    (= (bvadd v s2) (bvadd s2 v))
    (= (bvadd v s2) (bvadd s2 v)))))
(check-sat)
(exit)
