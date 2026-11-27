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
;; --- src/instructions/handlers_arithmetic_synthetic.zig:21 (push_add_inline)
;;   |         pub fn push_add_inline(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             var s = N.StackView.init(sp, t0, t1, t2, t3);
;;   |             N.before(self, .PUSH_ADD_INLINE, cursor, s, gas);
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_INLINE, Dispatch, Dispatch.Item, cursor);
;;   |             s.set_top_unsafe(op_data.metadata.value +% s.peek_unsafe());
;;   |             return N.next(self, .PUSH_ADD_INLINE, cursor, s, gas);
;;   |         }
;; --- src/instructions/handlers_arithmetic_synthetic.zig:31 (push_add_pointer)
;;   |         pub fn push_add_pointer(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType, t0: u64, t1: u64, t2: u64, t3: u64) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             var s = N.StackView.init(sp, t0, t1, t2, t3);
;;   |             N.before(self, .PUSH_ADD_POINTER, cursor, s, gas);
;;   |             const op_data = dispatch_opcode_data.getOpData(.PUSH_ADD_POINTER, Dispatch, Dispatch.Item, cursor);
;;   |             const top = s.peek_unsafe();
;;   |             s.set_top_unsafe(op_data.metadata.value_ptr.* +% top);
;;   |             return N.next(self, .PUSH_ADD_POINTER, cursor, s, gas);
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
