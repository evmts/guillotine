;; ==========================================================================
;; Theorem : stack_checked_dup_swap_index
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL u8 n and ALL 64-bit stack heights, the checked DUPn/SWAPn domain tests:
;;     checkedDupIndex(n, height):
;;       (1) is some  iff  1 <= n <= height,
;;       (2) when some, equals n - 1 over the integers (the subtraction never wraps)
;;           and is a slot of the stack: result < height,
;;     checkedSwapIndex(n, height):
;;       (3) is some  iff  n >= 1 and n + 1 <= height over the integers (SWAPn needs
;;           n + 1 items; the test never computes n + 1),
;;       (4) when some, equals n, is at least 1 (never the top itself) and is a slot
;;           of the stack: result < height.
;; Notes   :
;;   Regression model: `n - 1` in u8 wraps for n = 0 and `n + 1` in u8 wraps for
;;   n = 255. Both helpers reject n = 0 first and compare in the 64-bit height type,
;;   so neither expression is evaluated.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:580 (checkedDupIndex)
;;   | pub inline fn checkedDupIndex(n: u8, height: usize) ?usize {
;;   |     if (n == 0) return null;
;;   |     const depth: usize = n;
;;   |     if (depth > height) return null;
;;   |     return depth - 1;
;;   | }
;; --- src/core/verified_ops.zig:591 (checkedSwapIndex)
;;   | pub inline fn checkedSwapIndex(n: u8, height: usize) ?usize {
;;   |     if (n == 0) return null;
;;   |     const depth: usize = n;
;;   |     if (depth >= height) return null;
;;   |     return depth;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const n (_ BitVec 8))
(declare-const height (_ BitVec 64))
(define-fun depth () (_ BitVec 64) ((_ zero_extend 56) n))
; verified_ops.zig checkedDupIndex
(define-fun dupSome () Bool (and (not (= n #x00)) (not (bvugt depth height))))
(define-fun dupValue () (_ BitVec 64) (bvsub depth #x0000000000000001))
; verified_ops.zig checkedSwapIndex
(define-fun swapSome () Bool (and (not (= n #x00)) (not (bvuge depth height))))
(define-fun swapValue () (_ BitVec 64) depth)
; exact integer views
(define-fun int ((x (_ BitVec 64))) (_ BitVec 72) ((_ zero_extend 8) x))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
  ; (1)
  (= dupSome (and (bvuge n #x01) (bvule (int depth) (int height))))
  ; (2)
  (=> dupSome (and (= (bvadd (int dupValue) #x000000000000000001) (int depth))
                   (bvult dupValue height)))
  ; (3)
  (= swapSome (and (bvuge n #x01) (bvule (bvadd (int depth) #x000000000000000001) (int height))))
  ; (4)
  (=> swapSome (and (= swapValue depth)
                    (bvuge swapValue #x0000000000000001)
                    (bvult swapValue height))))))
(check-sat)
(exit)
