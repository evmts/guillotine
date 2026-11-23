;; ==========================================================================
;; Theorem : sar_branchless_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (shift, value): sarFast(shift, value) = sarRef(shift, value).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:222 (sarRef)
;;   | pub inline fn sarRef(shift: u256, value: u256) u256 {
;;   |     const value_signed: i256 = @bitCast(value);
;;   |     if (shift >= 256) {
;;   |         return if (value_signed < 0) std.math.maxInt(u256) else 0;
;;   |     }
;;   |     const shift_amt: u8 = @intCast(shift);
;;   |     return @bitCast(value_signed >> shift_amt);
;;   | }
;; --- src/verified_ops.zig:234 (sarFast)
;;   | pub inline fn sarFast(shift: u256, value: u256) u256 {
;;   |     const value_signed: i256 = @bitCast(value);
;;   |     const shift_amt: u8 = if (shift >= 255) 255 else @truncate(shift);
;;   |     return @bitCast(value_signed >> shift_amt);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const shift Word)
(declare-const value Word)
; verified_ops.zig sarRef
(define-fun sarRef ((shift Word) (value Word)) Word
  (ite (bvuge shift #x0000000000000000000000000000000000000000000000000000000000000100)
       (ite (bvslt value #x0000000000000000000000000000000000000000000000000000000000000000) #xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff #x0000000000000000000000000000000000000000000000000000000000000000)
       (bvashr value ((_ zero_extend 248) ((_ extract 7 0) shift)))))
; verified_ops.zig sarFast
(define-fun sarFast ((shift Word) (value Word)) Word
  (let ((shift_amt (ite (bvuge shift #x00000000000000000000000000000000000000000000000000000000000000ff) #xff ((_ extract 7 0) shift))))
    (bvashr value ((_ zero_extend 248) shift_amt))))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (= (sarFast shift value) (sarRef shift value))))
(check-sat)
(exit)
