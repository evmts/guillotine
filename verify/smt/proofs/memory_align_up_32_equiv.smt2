;; ==========================================================================
;; Theorem : memory_align_up_32_equiv
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u32 n <= 0xFFFFFF: alignUp32(n) = (n + 31) & ~31 never overflows u32,
;;   equals 32 * memoryWordCountRef(n), is a multiple of 32, is >= n, and is < n + 32.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:155 (alignUp32)
;;   | pub inline fn alignUp32(n: u32) u32 {
;;   |     return (n + 31) & ~@as(u32, 31);
;;   | }
;; --- src/verified_ops.zig:160 (memoryWordCountRef)
;;   | pub inline fn memoryWordCountRef(byte_size: u32) u64 {
;;   |     const b: u64 = byte_size;
;;   |     return if (b == 0) 0 else ((b - 1) / 32) + 1;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const n (_ BitVec 32))
; verified_ops.zig alignUp32
(define-fun alignUp32 ((n (_ BitVec 32))) (_ BitVec 32)
  (bvand (bvadd n #x0000001f) (bvnot #x0000001f)))
(define-fun memoryWordCountRef ((byte_size (_ BitVec 32))) (_ BitVec 64)
  (let ((b ((_ zero_extend 32) byte_size)))
    (ite (= b #x0000000000000000) #x0000000000000000
      (bvadd (bvudiv (bvsub b #x0000000000000001) #x0000000000000020) #x0000000000000001))))

;; ---- Hypotheses
; domain: n <= 0xFFFFFF (memory_limit)
(assert (bvule n #x00ffffff))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (let ((a (alignUp32 n)) (n64 ((_ zero_extend 32) n)))
  (and (= ((_ zero_extend 32) (bvadd n #x0000001f)) (bvadd n64 #x000000000000001f))
       (= ((_ zero_extend 32) a) (bvmul (memoryWordCountRef n) #x0000000000000020))
       (= (bvand a #x0000001f) #x00000000)
       (bvuge a n)
       (bvult (bvsub a n) #x00000020)))))
(check-sat)
(exit)
