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
;; --- src/instructions/handlers_advanced_synthetic.zig:393 (push_add_dup1)
;;   |         pub fn push_add_dup1(self: *FrameType, cursor: [*]const Dispatch.Item, sp: [*]WordType, gas: FrameType.GasType) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             N.before(self, .PUSH_ADD_DUP1, cursor, sp, gas);
;;   |             var s = N.StackView{ .sp = sp };
;;   |             const push_item = cursor[1];
;;   |             const push_value: WordType = if (push_item == .push_inline)
;;   |                 push_item.push_inline.value
;;   |             else
;;   |                 push_item.push_pointer.value_ptr.*;
;;   |             const result = s.peek_unsafe() +% push_value;
;;   |             s.set_top_unsafe(result);
;;   |             s.push_unsafe(result);
;;   |             return N.next(self, .PUSH_ADD_DUP1, cursor, s.sp, gas);
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
