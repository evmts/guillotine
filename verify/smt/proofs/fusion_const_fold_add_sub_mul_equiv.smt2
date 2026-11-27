;; ==========================================================================
;; Theorem : fusion_const_fold_add_sub_mul_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL PUSH1 immediates (value1, value2) and ALL 2-word stacks:
;;   `PUSH1 value1; PUSH1 value2; OP` (Yellow Paper) leaves exactly the stack produced by
;;   pushing bytecode_analyze.zig's folded_value, for OP in {ADD, SUB, MUL}.
;; Notes   :
;;   Folder transcription: ADD -> value1 +% value2; SUB -> value2 -% value1;
;;   MUL -> value1 *% value2 (bytecode_analyze.zig checkConstantFoldingPatternWithFusion).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/bytecode/bytecode_analyze.zig:22 (check)
;;   |         fn check(bytecode: []const u8, position: PcType) ?FusionInfo {
;;   |             if (position + 4 >= bytecode.len) return null;
;;   | 
;;   |             if (bytecode[position] != @backingInt(Opcode.PUSH1)) return null;
;;   |             const value1 = bytecode[position + 1];
;;   | 
;;   |             if (bytecode[position + 2] != @backingInt(Opcode.PUSH1)) return null;
;;   |             const value2 = bytecode[position + 3];
;;   | 
;;   |             const arith_op = bytecode[position + 4];
;;   |             var folded_value: u256 = undefined;
;;   |             var sequence_length: PcType = 5;
;;   | 
;;   |             switch (arith_op) {
;;   |                 @backingInt(Opcode.ADD) => {
;;   |                     folded_value = @as(u256, value1) +% @as(u256, value2);
;;   |                 },
;;   |                 @backingInt(Opcode.SUB) => {
;;   |                     // EVM SUB computes top - second. For `PUSH1 value1; PUSH1 value2; SUB`,
;;   |                     // value2 is on top, so the result is value2 - value1 (not value1 - value2).
;;   |                     folded_value = @as(u256, value2) -% @as(u256, value1);
;;   |                 },
;;   |                 @backingInt(Opcode.MUL) => {
;;   |                     folded_value = @as(u256, value1) *% @as(u256, value2);
;;   |                 },
;;   |                 @backingInt(Opcode.PUSH1) => {
;;   |                     // PUSH1 value1; PUSH1 value2; PUSH1 shift; SHL; SUB
;;   |                     // Stack before SHL: [value1, value2, shift (top)]. SHL computes value2 << shift.
;;   |                     // Stack before SUB: [value1, shifted (top)]. EVM SUB computes top - second = shifted - value1.
;;   |                     if (position + 7 < bytecode.len and
;;   |                         bytecode[position + 6] == @backingInt(Opcode.SHL) and
;;   |                         bytecode[position + 7] == @backingInt(Opcode.SUB))
;;   |                     {
;;   |                         const shift_amount = bytecode[position + 5];
;;   |                         const shifted: u256 = @as(u256, value2) << shift_amount;
;;   |                         folded_value = shifted -% @as(u256, value1);
;;   |                         sequence_length = 8;
;;   |                     } else {
;;   |                         return null;
;;   |                     }
;;   |                 },
;;   |                 else => return null,
;;   |             }
;;   | 
;;   |             return FusionInfo{
;;   |                 .fusion_type = .constant_fold,
;;   |                 .original_length = sequence_length,
;;   |                 .folded_value = folded_value,
;;   |             };
;;   |         }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const value1 (_ BitVec 8))
(declare-const value2 (_ BitVec 8))
(define-fun v1 () Word ((_ zero_extend 248) value1))
(define-fun v2 () Word ((_ zero_extend 248) value2))
(declare-const s0 Word)
(declare-const s1 Word)

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
    (and
    (= s0 s0)
    (= s1 s1)
    (= (bvadd v2 v1) (bvadd v1 v2)))
    (and
    (= s0 s0)
    (= s1 s1)
    (= (bvsub v2 v1) (bvsub v2 v1)))
    (and
    (= s0 s0)
    (= s1 s1)
    (= (bvmul v2 v1) (bvmul v1 v2))))))
(check-sat)
(exit)
