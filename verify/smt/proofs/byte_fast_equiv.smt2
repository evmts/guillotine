;; ==========================================================================
;; Theorem : byte_fast_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (index, value): byteFast(index, value) = byteRef(index, value).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:241 (byteRef)
;;   | pub inline fn byteRef(index: u256, value: u256) u256 {
;;   |     if (index >= 32) return 0;
;;   |     const byte_index: u8 = @intCast(index);
;;   |     const shift_bits: u8 = (31 - byte_index) * 8;
;;   |     return (value >> shift_bits) & 0xFF;
;;   | }
;; --- src/core/verified_ops.zig:249 (byteFast)
;;   | pub inline fn byteFast(index: u256, value: u256) u256 {
;;   |     if (index >= 32) return 0;
;;   |     const byte_index: u8 = @truncate(index);
;;   |     const shift_bits: u8 = (31 - byte_index) << 3;
;;   |     return (value >> shift_bits) & 0xFF;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const index Word)
(declare-const value Word)
; verified_ops.zig byteRef
(define-fun byteRef ((index Word) (value Word)) Word
  (ite (bvuge index #x0000000000000000000000000000000000000000000000000000000000000020) #x0000000000000000000000000000000000000000000000000000000000000000
  (let ((shift_bits (bvmul (bvsub #x1f ((_ extract 7 0) index)) #x08)))
    (bvand (bvlshr value ((_ zero_extend 248) shift_bits)) #x00000000000000000000000000000000000000000000000000000000000000ff))))
; verified_ops.zig byteFast
(define-fun byteFast ((index Word) (value Word)) Word
  (ite (bvuge index #x0000000000000000000000000000000000000000000000000000000000000020) #x0000000000000000000000000000000000000000000000000000000000000000
  (let ((shift_bits (bvshl (bvsub #x1f ((_ extract 7 0) index)) #x03)))
    (bvand (bvlshr value ((_ zero_extend 248) shift_bits)) #x00000000000000000000000000000000000000000000000000000000000000ff))))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (= (byteFast index value) (byteRef index value))))
(check-sat)
(exit)
