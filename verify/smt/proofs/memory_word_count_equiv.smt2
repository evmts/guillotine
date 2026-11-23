;; ==========================================================================
;; Theorem : memory_word_count_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 byte sizes: memoryWordCountFast(b) = memoryWordCountRef(b) = ceil(b/32)
;;   (u64 arithmetic; the reference holds on the full u32 domain, not only b <= 0xFFFFFF).
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:160 (memoryWordCountRef)
;;   | pub inline fn memoryWordCountRef(byte_size: u32) u64 {
;;   |     const b: u64 = byte_size;
;;   |     return if (b == 0) 0 else ((b - 1) / 32) + 1;
;;   | }
;; --- src/verified_ops.zig:166 (memoryWordCountFast)
;;   | pub inline fn memoryWordCountFast(byte_size: u32) u64 {
;;   |     return (@as(u64, byte_size) + 31) >> 5;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const byte_size (_ BitVec 32))
; verified_ops.zig memoryWordCountRef
(define-fun memoryWordCountRef ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (let ((b ((_ zero_extend 32) byte_size)))
    (ite (= b #x0000000000000000) #x0000000000000000
      (bvadd (bvudiv (bvsub b #x0000000000000001) #x0000000000000020) #x0000000000000001))))
; verified_ops.zig memoryWordCountFast
(define-fun memoryWordCountFast ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (bvlshr (bvadd ((_ zero_extend 32) byte_size) #x000000000000001f) #x0000000000000005))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((wc (memoryWordCountFast byte_size)) (b ((_ zero_extend 32) byte_size)))
  (and (= wc (memoryWordCountRef byte_size))
       (bvuge (bvmul wc #x0000000000000020) b)
       (bvult (bvsub (bvmul wc #x0000000000000020) b) #x0000000000000020)))))
(check-sat)
(exit)
