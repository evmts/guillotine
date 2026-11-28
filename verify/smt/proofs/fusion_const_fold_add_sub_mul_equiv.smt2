;; ==========================================================================
;; Theorem : fusion_const_fold_add_sub_mul_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL PUSH1 immediates (value1, value2) and ALL 2-word stacks:
;;   `PUSH1 value1; PUSH1 value2; OP` (Yellow Paper) leaves exactly the stack produced by
;;   pushing bytecode_analyze.zig's folded_value, for OP in {ADD, SUB, MUL}.
;; Notes   :
;;   Folder transcription (value1 = `first`, value2 = `second`, the top of the stack):
;;   ADD -> first +% second; SUB -> second -% first (top minus second, LIFO order);
;;   MUL -> first *% second (bytecode_analyze.zig constantFold).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/bytecode/bytecode_analyze.zig:92 (constantFold)
;;   | fn constantFold(comptime FusionInfo: type, code: []const u8, position: usize) ?FusionInfo {
;;   |     if (code.len - position < 5) return null;
;;   |     if (code[position] != op_push1 or code[position + 2] != op_push1) return null;
;;   |     const first: u256 = code[position + 1];
;;   |     const second: u256 = code[position + 3];
;;   | 
;;   |     var length: usize = 5;
;;   |     const folded: u256 = switch (code[position + 4]) {
;;   |         op_add => first +% second,
;;   |         op_sub => second -% first,
;;   |         op_mul => first *% second,
;;   |         op_push1 => shifted: {
;;   |             // Stack before SHL: [first, second, shift (top)], so SHL yields second << shift.
;;   |             // Stack before SUB: [first, shifted (top)], so SUB yields shifted - first.
;;   |             if (code.len - position < 8) return null;
;;   |             if (code[position + 6] != op_shl or code[position + 7] != op_sub) return null;
;;   |             length = 8;
;;   |             break :shifted (second << code[position + 5]) -% first;
;;   |         },
;;   |         else => return null,
;;   |     };
;;   |     return .{ .fusion_type = .constant_fold, .original_length = @intCast(length), .folded_value = folded };
;;   | }
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
