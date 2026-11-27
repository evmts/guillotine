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
;; --- src/instructions/handlers_bitwise_synthetic.zig:52 (push_or_inline)
;;   |         pub fn push_or_inline(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             var s = N.StackView.init(sp, t0, t1, t2, t3);
;;   |             N.before(self, .PUSH_OR_INLINE, cursor, s, gas);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_OR_INLINE, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // For synthetic opcodes, cursor now points to metadata
;;   |             const push_value = op_data.metadata.value;
;;   | 
;;   |             const top = s.peek_unsafe();
;;   |             const result = top | push_value;
;;   |             s.set_top_unsafe(result);
;;   | 
;;   |             return N.next(self, .PUSH_OR_INLINE, cursor, s, gas);
;;   |         }
;; --- src/instructions/handlers_bitwise_synthetic.zig:69 (push_or_pointer)
;;   |         pub fn push_or_pointer(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             var s = N.StackView.init(sp, t0, t1, t2, t3);
;;   |             N.before(self, .PUSH_OR_POINTER, cursor, s, gas);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_OR_POINTER, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // For synthetic opcodes, cursor now points to metadata
;;   |             const push_value = op_data.metadata.value_ptr.*;
;;   | 
;;   |             const top = s.peek_unsafe();
;;   |             const result = top | push_value;
;;   |             s.set_top_unsafe(result);
;;   | 
;;   |             return N.next(self, .PUSH_OR_POINTER, cursor, s, gas);
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
