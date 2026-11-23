;; ==========================================================================
;; Theorem : signextend_u8_no_overflow
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL ext < 31: the u8 operations in signextendRef (byte_index*8+7) and
;;   signextendFast (248 - (byte_index<<3)) never wrap, and the @intCast(ext) to u8
;;   in signextendRef is in range. So Zig safety checks never fire and modular
;;   arithmetic in the equivalence proof equals integer arithmetic.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:196 (signextendRef)
;;   | pub inline fn signextendRef(ext: u256, value: u256) u256 {
;;   |     if (ext >= 31) return value;
;;   |     const byte_index: u8 = @intCast(ext);
;;   |     const bit_index: u8 = byte_index * 8 + 7;
;;   |     const sign_bit_mask = @as(u256, 1) << bit_index;
;;   |     const is_negative = (value & sign_bit_mask) != 0;
;;   |     const value_mask = (@as(u256, 1) << bit_index) - 1;
;;   |     if (is_negative) {
;;   |         return value | ~value_mask;
;;   |     } else {
;;   |         return value & value_mask;
;;   |     }
;;   | }
;; --- src/verified_ops.zig:213 (signextendFast)
;;   | pub inline fn signextendFast(ext: u256, value: u256) u256 {
;;   |     if (ext >= 31) return value;
;;   |     const byte_index: u8 = @truncate(ext);
;;   |     const shift: u8 = 248 - (byte_index << 3);
;;   |     const signed: i256 = @bitCast(value << shift);
;;   |     return @bitCast(signed >> shift);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const ext Word)

;; ---- Hypotheses
; guarded branch: ext < 31
(assert (bvult ext #x000000000000000000000000000000000000000000000000000000000000001f))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((bi ((_ extract 7 0) ext)) (bi16 ((_ zero_extend 8) ((_ extract 7 0) ext))))
  (and (bvule ext #x00000000000000000000000000000000000000000000000000000000000000ff)
       (= ((_ zero_extend 8) (bvadd (bvmul bi #x08) #x07)) (bvadd (bvmul bi16 #x0008) #x0007))
       (= ((_ zero_extend 8) (bvshl bi #x03)) (bvshl bi16 #x0003))
       (bvule (bvshl bi #x03) #xf8)))))
(check-sat)
(exit)
