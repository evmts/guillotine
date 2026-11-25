;; ==========================================================================
;; Theorem : signextend_branchless_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (ext, value): signextendFast(ext, value) = signextendRef(ext, value).
;; Notes   :
;;   All u8 arithmetic is 8-bit modular here; signextend_u8_no_overflow proves it never wraps.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:196 (signextendRef)
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
;; --- src/core/verified_ops.zig:213 (signextendFast)
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
(declare-const value Word)
; verified_ops.zig signextendRef
(define-fun signextendRef ((ext Word) (value Word)) Word
  (ite (bvuge ext #x000000000000000000000000000000000000000000000000000000000000001f) value
  (let ((byte_index ((_ extract 7 0) ext)))
  (let ((bit_index (bvadd (bvmul byte_index #x08) #x07)))
  (let ((sign_bit_mask (bvshl #x0000000000000000000000000000000000000000000000000000000000000001 ((_ zero_extend 248) bit_index))))
  (let ((is_negative (not (= (bvand value sign_bit_mask) #x0000000000000000000000000000000000000000000000000000000000000000))))
  (let ((value_mask (bvsub sign_bit_mask #x0000000000000000000000000000000000000000000000000000000000000001)))
    (ite is_negative (bvor value (bvnot value_mask)) (bvand value value_mask)))))))))
; verified_ops.zig signextendFast
(define-fun signextendFast ((ext Word) (value Word)) Word
  (ite (bvuge ext #x000000000000000000000000000000000000000000000000000000000000001f) value
  (let ((byte_index ((_ extract 7 0) ext)))
  (let ((shift ((_ zero_extend 248) (bvsub #xf8 (bvshl byte_index #x03)))))
    (bvashr (bvshl value shift) shift)))))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (= (signextendFast ext value) (signextendRef ext value))))
(check-sat)
(exit)
