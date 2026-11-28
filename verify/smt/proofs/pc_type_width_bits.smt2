;; ==========================================================================
;; Theorem : pc_type_width_bits
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 max_code and both values of unbounded_initcode, W = pcTypeWidthBits(...):
;;     (1) W is one of 8, 12, 16, 32, and unbounded_initcode forces W = 32,
;;     (2) max_code + 33 is computed without wrapping (u64 sum = 65-bit sum),
;;     (3) W < 32 implies max_code + 33 <= 2^W - 1: every offset the analyzer addresses,
;;         including the PUSH32 lookahead and the one-past-the-end offset, fits the type,
;;     (4) W is minimal when bounded: W = 12 implies max_code + 33 > 255, W = 16 implies > 4095,
;;         W = 32 implies > 65535,
;;     (5) boundaries: 222 -> 8, 223 -> 12, 255 -> 12, 65502 -> 16, 65503 -> 32, 65535 -> 32.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:536 (pcTypeWidthBits)
;;   | pub inline fn pcTypeWidthBits(max_code: u32, unbounded_initcode: bool) u8 {
;;   |     if (unbounded_initcode) return 32;
;;   |     const needed: u64 = @as(u64, max_code) + pc_headroom;
;;   |     if (needed <= std.math.maxInt(u8)) return 8;
;;   |     if (needed <= std.math.maxInt(u12)) return 12;
;;   |     if (needed <= std.math.maxInt(u16)) return 16;
;;   |     return 32;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const max_code (_ BitVec 32))
(declare-const unbounded Bool)
; verified_ops.zig pcTypeWidthBits
(define-fun needed ((m (_ BitVec 32))) (_ BitVec 64) (bvadd ((_ zero_extend 32) m) #x0000000000000021))
(define-fun pcTypeWidthBits ((m (_ BitVec 32)) (u Bool)) (_ BitVec 8)
  (ite u #x20
  (ite (bvule (needed m) #x00000000000000ff) #x08
  (ite (bvule (needed m) #x0000000000000fff) #x0c
  (ite (bvule (needed m) #x000000000000ffff) #x10 #x20)))))
(define-fun W () (_ BitVec 8) (pcTypeWidthBits max_code unbounded))
; largest value of an unsigned W-bit integer, in 64 bits
(define-fun pcMax () (_ BitVec 64) (bvsub (bvshl #x0000000000000001 ((_ zero_extend 56) W)) #x0000000000000001))
(define-fun exactNeeded () (_ BitVec 65) (bvadd ((_ zero_extend 33) max_code) #b00000000000000000000000000000000000000000000000000000000000100001))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (or (= W #x08) (= W #x0c) (= W #x10) (= W #x20))
     (=> unbounded (= W #x20))
     (= ((_ zero_extend 1) (needed max_code)) exactNeeded)
     (=> (not (= W #x20)) (bvule exactNeeded ((_ zero_extend 1) pcMax)))
     (=> (and (not unbounded) (= W #x0c)) (bvugt exactNeeded #b00000000000000000000000000000000000000000000000000000000011111111))
     (=> (and (not unbounded) (= W #x10)) (bvugt exactNeeded #b00000000000000000000000000000000000000000000000000000111111111111))
     (=> (and (not unbounded) (= W #x20)) (bvugt exactNeeded #b00000000000000000000000000000000000000000000000001111111111111111))
     (= (pcTypeWidthBits #x000000de false) #x08)
     (= (pcTypeWidthBits #x000000df false) #x0c)
     (= (pcTypeWidthBits #x000000ff false) #x0c)
     (= (pcTypeWidthBits #x0000ffde false) #x10)
     (= (pcTypeWidthBits #x0000ffdf false) #x20)
     (= (pcTypeWidthBits #x0000ffff false) #x20))))
(check-sat)
(exit)
