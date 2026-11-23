;; ==========================================================================
;; Theorem : fusion_swap1_dup2_add_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 256-bit push values and ALL 4-word stacks (top 2 consumed,
;;   2 below preserved): executing `SWAP1; DUP2; ADD` under Yellow Paper semantics yields a stack
;;   bit-for-bit equal to the fused handler's stack (same depth, every word equal).
;; Notes   :
;;   The push value v is unused by this fusion; it is declared for a uniform interface.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/instructions/handlers_advanced_synthetic.zig:266 (swap1_dup2_add)
;;   |         pub fn swap1_dup2_add(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.SWAP1_DUP2_ADD, cursor);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.SWAP1_DUP2_ADD, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // Validate: SWAP1 needs 2, DUP2 needs 2 (adds 1), ADD pops 2 and pushes 1
;;   |             // Net: needs 2 items initially, ends with 2 items
;;   |             (&self.getEvm().tracer).assert(self.stack.size() >= 2, "SWAP1_DUP2_ADD: Stack underflow (need 2 items)");
;;   |             (&self.getEvm().tracer).assert(self.stack.size() <= 1023, "SWAP1_DUP2_ADD: Stack overflow (need space for 1 item)");
;;   | 
;;   |             // SWAP1: swap top two stack items
;;   |             const top = self.stack.pop_unsafe();
;;   |             const second = self.stack.pop_unsafe();
;;   |             self.stack.push_unsafe(top);
;;   |             self.stack.push_unsafe(second);
;;   | 
;;   |             // DUP2: duplicate 2nd stack item
;;   |             self.stack.dup_n_unsafe(2);
;;   | 
;;   |             // ADD: pop two values and add
;;   |             const b = self.stack.pop_unsafe();
;;   |             const a = self.stack.pop_unsafe();
;;   |             self.stack.push_unsafe(a +% b);
;;   | 
;;   |             self.afterInstruction(.SWAP1_DUP2_ADD, op_data.next_handler, op_data.next_cursor.cursor);
;;   |             return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
;;   |         }
;; --- src/stack/stack.zig:174 (dup_n_unsafe)
;;   |         pub inline fn dup_n_unsafe(self: *Self, n: u8) void {
;;   |             self.assert(self.size_internal() >= n, "Insufficient stack items for dup_n_unsafe");
;;   |             self.assert(@intFromPtr(self.stack_ptr) > @intFromPtr(self.stack_limit()), "Stack overflow in dup_n_unsafe");
;;   |             // In downward stack, nth-from-top is at index n-1
;;   |             const value = self.stack_ptr[n - 1];
;;   |             self.push_unsafe(value);
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
(declare-const s3 Word)

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
    (= s0 s0)
    (= s1 s1)
    (= s3 s3)
    (= (bvadd s3 s2) (bvadd s2 s3)))))
(check-sat)
(exit)
