;; ==========================================================================
;; Theorem : checked_blob_gas_cost
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u64 blob_gas and ALL u256 fee_per_blob_gas, checkedBlobGasCost:
;;     (1) returns a value  iff  blob_gas * fee_per_blob_gas < 2^256 (exact 320-bit product),
;;     (2) the value is exactly that product (never clamped to 2^256 - 1),
;;     (3) blob_gas = 0 or fee = 0 always yields 0, and blob_gas = 1 yields the fee.
;;   An overflowing EIP-4844 blob fee is rejected, not saturated.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:429 (checkedBlobGasCost)
;;   | pub inline fn checkedBlobGasCost(blob_gas: u64, fee_per_blob_gas: u256) ?u256 {
;;   |     const product = @mulWithOverflow(@as(u256, blob_gas), fee_per_blob_gas);
;;   |     if (product[1] != 0) return null;
;;   |     return product[0];
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const blob_gas (_ BitVec 64))
(declare-const fee Word)
; verified_ops.zig checkedBlobGasCost: @mulWithOverflow(@as(u256, blob_gas), fee)
; LLVM umul.with.overflow.i256: low 256 bits, and a flag set iff the 512-bit product has a high half.
(define-fun wide512 () (_ BitVec 512)
  (bvmul ((_ zero_extend 448) blob_gas) ((_ zero_extend 256) fee)))
(define-fun blobSome () Bool (= ((_ extract 511 256) wide512) #x0000000000000000000000000000000000000000000000000000000000000000))
(define-fun blobValue () Word (bvmul ((_ zero_extend 192) blob_gas) fee))
; exact product: a u64 times a u256 is below 2^320
(define-fun exact320 () (_ BitVec 320)
  (bvmul ((_ zero_extend 256) blob_gas) ((_ zero_extend 64) fee)))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and (= blobSome (= ((_ extract 319 256) exact320) #x0000000000000000))
     (=> blobSome (= ((_ zero_extend 64) blobValue) exact320))
     (=> (or (= blob_gas #x0000000000000000) (= fee #x0000000000000000000000000000000000000000000000000000000000000000)) (and blobSome (= blobValue #x0000000000000000000000000000000000000000000000000000000000000000)))
     (=> (= blob_gas #x0000000000000001) (and blobSome (= blobValue fee))))))
(check-sat)
(exit)
