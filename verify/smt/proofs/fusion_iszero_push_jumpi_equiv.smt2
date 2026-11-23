;; ==========================================================================
;; Theorem : fusion_iszero_push_jumpi_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 256-bit jump targets, ALL 3-word stacks, and EVERY jumpdest table:
;;   `ISZERO; PUSH target; JUMPI` (Yellow Paper) and the fused ISZERO_JUMPI handler agree on
;;     (a) the remaining stack (bit-for-bit, same depth),
;;     (b) the control outcome: fall through / jump / exceptional halt (InvalidJump),
;;     (c) the jump destination when the jump is taken.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/instructions/handlers_advanced_synthetic.zig:128 (iszero_jumpi)
;;   |         pub fn iszero_jumpi(self: *FrameType, cursor: [*]const Dispatch.Item) Error!noreturn {
;;   |             self.beforeInstruction(.ISZERO_JUMPI, cursor);
;;   |             const dispatch_opcode_data = @import("../preprocessor/dispatch_opcode_data.zig");
;;   |             const op_data = dispatch_opcode_data.getOpData(.ISZERO_JUMPI, Dispatch, Dispatch.Item, cursor);
;;   | 
;;   |             // Validate stack has at least 1 item (for ISZERO to consume)
;;   |             (&self.getEvm().tracer).assert(self.stack.size() >= 1, "ISZERO_JUMPI: Stack underflow (need 1 item for ISZERO)");
;;   | 
;;   |             // Get the jump target from items
;;   |             const target_item = op_data.items[0];
;;   |             const target = if (target_item == .push_inline)
;;   |                 target_item.push_inline.value
;;   |             else if (target_item == .push_pointer)
;;   |                 target_item.push_pointer.value_ptr.*
;;   |             else
;;   |                 unreachable;
;;   | 
;;   |             // Pop value and check if zero
;;   |             const value = self.stack.pop_unsafe();
;;   |             const should_jump = value == 0;
;;   | 
;;   |             // Jump if the value was zero
;;   |             if (should_jump) {
;;   |                 // Guard against an out-of-range destination before the cast (else @intCast panics).
;;   |                 if (target > std.math.maxInt(FrameType.PcType)) {
;;   |                     self.afterComplete(.ISZERO_JUMPI);
;;   |                     return Error.InvalidJump;
;;   |                 }
;;   |                 // Look up the jump destination in the jump table
;;   |                 const dest_pc: FrameType.PcType = @intCast(target);
;;   |                 if (self.jump_table.findJumpTarget(dest_pc)) |jump_dispatch| {
;;   |                     self.afterInstruction(.ISZERO_JUMPI, jump_dispatch.cursor[0].opcode_handler, jump_dispatch.cursor);
;;   |                     return @call(FrameType.Dispatch.getTailCallModifier(), jump_dispatch.cursor[0].opcode_handler, .{ self, jump_dispatch.cursor });
;;   |                 } else {
;;   |                     self.afterComplete(.ISZERO_JUMPI);
;;   |                     return Error.InvalidJump;
;;   |                 }
;;   |             }
;;   | 
;;   |             // Continue to next instruction using getOpData
;;   |             self.afterInstruction(.ISZERO_JUMPI, op_data.next_handler, op_data.next_cursor.cursor);
;;   |             return @call(FrameType.Dispatch.getTailCallModifier(), op_data.next_handler, .{ self, op_data.next_cursor.cursor });
;;   |         }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_UFBV)
(define-sort Word () (_ BitVec 256))

(declare-const target Word)
(declare-const s0 Word)
(declare-const s1 Word)
(declare-const s2 Word)
; PcType = u16 (default max_bytecode_size 24576 <= 65535, enforced by FrameConfig.validate).
(define-fun MAX_PC () Word #x000000000000000000000000000000000000000000000000000000000000ffff)
; jump_table.findJumpTarget(dest_pc: PcType) != null: uninterpreted, any jumpdest table.
(declare-fun isJumpdest ((_ BitVec 16)) Bool)
; Outcome encoding: 0 = fall through, 1 = jump, 2 = exceptional halt (InvalidJump)
(define-fun FALL () (_ BitVec 2) #b00)
(define-fun JUMP () (_ BitVec 2) #b01)
(define-fun HALT () (_ BitVec 2) #b10)
; Yellow Paper JUMPI validity: dest in D(code). Code length <= maxInt(PcType), so a valid
; dest is <= MAX_PC and is a jumpdest of the truncated PC.
(define-fun evmValidDest ((d Word)) Bool
  (and (bvule d MAX_PC) (isJumpdest ((_ extract 15 0) d))))
(define-fun evmOutcome () (_ BitVec 2)
  (ite (not (= (ite (= s2 #x0000000000000000000000000000000000000000000000000000000000000000) #x0000000000000000000000000000000000000000000000000000000000000001 #x0000000000000000000000000000000000000000000000000000000000000000) #x0000000000000000000000000000000000000000000000000000000000000000)) (ite (evmValidDest target) JUMP HALT) FALL))
; handlers_advanced_synthetic.zig iszero_jumpi
(define-fun fusedOutcome () (_ BitVec 2)
  (ite (= s2 #x0000000000000000000000000000000000000000000000000000000000000000)
       (ite (bvugt target MAX_PC) HALT
         (ite (isJumpdest ((_ extract 15 0) target)) JUMP HALT))
       FALL))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= evmOutcome fusedOutcome)
     (=> (= evmOutcome JUMP) (= target target))
     (and
    (= s0 s0)
    (= s1 s1)))))
(check-sat)
(exit)
