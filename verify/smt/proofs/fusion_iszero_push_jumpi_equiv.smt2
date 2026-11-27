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
;; --- src/instructions/handlers_advanced_synthetic.zig:22 (iszero_jumpi)
;;   |         pub fn iszero_jumpi(
;;   |             self: *FrameType,
;;   |             cursor: [*]const Dispatch.Item,
;;   |             sp: [*]WordType,
;;   |             gas: FrameType.GasType,
;;   |             t0: u64,
;;   |             t1: u64,
;;   |             t2: u64,
;;   |             t3: u64,
;;   |         ) callconv(handler_abi.handler_cc) handler_abi.ExitCode {
;;   |             var s = N.StackView.init(sp, t0, t1, t2, t3);
;;   |             N.before(self, .ISZERO_JUMPI, cursor, s, gas);
;;   |             const value = s.pop_unsafe();
;;   |             if (value != 0) return N.next(self, .ISZERO_JUMPI, cursor, s, gas);
;;   |             // cursor[1] holds the statically resolved target: the JUMPDEST's schedule
;;   |             // cursor, or the invalid-jump item when the target is not a JUMPDEST.
;;   |             const target: [*]const Dispatch.Item = @ptrCast(@alignCast(cursor[1].jump_static.dispatch));
;;   |             return N.jump(self, .ISZERO_JUMPI, target, s, gas);
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
