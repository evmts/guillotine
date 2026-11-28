;; ==========================================================================
;; Theorem : eip7685_request_types_strictly_ascending
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL request type bytes a, b, c, requestTypeFollows (the order test of
;;   EIP-7685 computeRequestsHash) is a strict order:
;;     (1) irreflexive: a type never follows itself, so a duplicate is refused,
;;     (2) asymmetric: b following a excludes a following b, so an inversion is refused,
;;     (3) transitive: accepted neighbours a < b < c give a < c, so in any accepted
;;         list EVERY pair of request types is distinct and ascending, not only
;;         adjacent ones,
;;     (4) total on distinct types: of two different types exactly one order is
;;         accepted, so every set of types has an accepted arrangement.
;; Notes   :
;;   Regression model: the earlier test refused only `current < previous`, which
;;   accepts current == previous, i.e. two requests of one type.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:611 (requestTypeFollows)
;;   | pub inline fn requestTypeFollows(previous: u8, current: u8) bool {
;;   |     return previous < current;
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status unsat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const a (_ BitVec 8))
(declare-const b (_ BitVec 8))
(declare-const c (_ BitVec 8))
; verified_ops.zig requestTypeFollows: previous < current
(define-fun follows ((previous (_ BitVec 8)) (current (_ BitVec 8))) Bool (bvult previous current))

;; ---- Negated claim (a model would be a counterexample)
(assert (not (and
  (not (follows a a))
  (=> (follows a b) (not (follows b a)))
  (=> (and (follows a b) (follows b c)) (and (follows a c) (not (= a c))))
  (=> (not (= a b)) (xor (follows a b) (follows b a))))))
(check-sat)
(exit)
