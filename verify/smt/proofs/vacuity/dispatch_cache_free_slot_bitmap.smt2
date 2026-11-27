;; ==========================================================================
;; Theorem : dispatch_cache_free_slot_bitmap  [VACUITY CHECK]
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 64-bit bitmap words and ALL slot indexes (one word of DispatchCache's
;;   free-slot bitmap; bit set = slot free):
;;     (1) slotBitmapLowest(word) is null iff word == 0; otherwise it names a set bit
;;         and every lower bit is clear (the LOWEST free slot),
;;     (2) slotBitmapTake clears exactly that slot's bit and slotBitmapRelease sets
;;         exactly it: every other bit of the word is unchanged,
;;     (3) take and release are inverse on the slot's bit: release(take(w, s), s) == w
;;         when s was free and take(release(w, s), s) == w when s was in use, so the
;;         free/in-use states of a slot are in bijection and no slot is lost or doubled,
;;     (4) a slot just taken is not returned again: lowest(take(w, lowest(w))) is null
;;         or a strictly higher slot.
;; Notes   :
;;   The cache keeps one such word per 64 slots and searches the words in order, so
;;   the lowest set bit of the first non-zero word is the lowest free slot overall.
;; This file asserts ONLY the hypotheses. Expected `sat`: the hypotheses
;; are consistent, so the companion `unsat` proof is not vacuous.
;; Modeled Zig source:
;; --- src/core/verified_ops.zig:496 (slotBitmapMask)
;;   | pub inline fn slotBitmapMask(slot: usize) u64 {
;;   |     return @as(u64, 1) << @as(u6, @truncate(slot));
;;   | }
;; --- src/core/verified_ops.zig:502 (slotBitmapLowest)
;;   | pub inline fn slotBitmapLowest(word: u64) ?u6 {
;;   |     if (word == 0) return null;
;;   |     return @intCast(@ctz(word));
;;   | }
;; --- src/core/verified_ops.zig:508 (slotBitmapTake)
;;   | pub inline fn slotBitmapTake(word: u64, slot: usize) u64 {
;;   |     return word & ~slotBitmapMask(slot);
;;   | }
;; --- src/core/verified_ops.zig:513 (slotBitmapRelease)
;;   | pub inline fn slotBitmapRelease(word: u64, slot: usize) u64 {
;;   |     return word | slotBitmapMask(slot);
;;   | }
;; ==========================================================================
(set-info :smt-lib-version 2.6)
(set-info :status sat)
(set-logic QF_BV)
(define-sort Word () (_ BitVec 256))

(declare-const word (_ BitVec 64))
(declare-const slot (_ BitVec 64))
(declare-const other (_ BitVec 8))
; @ctz(word)
(define-fun ctz ((x (_ BitVec 64))) (_ BitVec 8)
    (ite (= ((_ extract 0 0) x) #b1) #x00
    (ite (= ((_ extract 1 1) x) #b1) #x01
    (ite (= ((_ extract 2 2) x) #b1) #x02
    (ite (= ((_ extract 3 3) x) #b1) #x03
    (ite (= ((_ extract 4 4) x) #b1) #x04
    (ite (= ((_ extract 5 5) x) #b1) #x05
    (ite (= ((_ extract 6 6) x) #b1) #x06
    (ite (= ((_ extract 7 7) x) #b1) #x07
    (ite (= ((_ extract 8 8) x) #b1) #x08
    (ite (= ((_ extract 9 9) x) #b1) #x09
    (ite (= ((_ extract 10 10) x) #b1) #x0a
    (ite (= ((_ extract 11 11) x) #b1) #x0b
    (ite (= ((_ extract 12 12) x) #b1) #x0c
    (ite (= ((_ extract 13 13) x) #b1) #x0d
    (ite (= ((_ extract 14 14) x) #b1) #x0e
    (ite (= ((_ extract 15 15) x) #b1) #x0f
    (ite (= ((_ extract 16 16) x) #b1) #x10
    (ite (= ((_ extract 17 17) x) #b1) #x11
    (ite (= ((_ extract 18 18) x) #b1) #x12
    (ite (= ((_ extract 19 19) x) #b1) #x13
    (ite (= ((_ extract 20 20) x) #b1) #x14
    (ite (= ((_ extract 21 21) x) #b1) #x15
    (ite (= ((_ extract 22 22) x) #b1) #x16
    (ite (= ((_ extract 23 23) x) #b1) #x17
    (ite (= ((_ extract 24 24) x) #b1) #x18
    (ite (= ((_ extract 25 25) x) #b1) #x19
    (ite (= ((_ extract 26 26) x) #b1) #x1a
    (ite (= ((_ extract 27 27) x) #b1) #x1b
    (ite (= ((_ extract 28 28) x) #b1) #x1c
    (ite (= ((_ extract 29 29) x) #b1) #x1d
    (ite (= ((_ extract 30 30) x) #b1) #x1e
    (ite (= ((_ extract 31 31) x) #b1) #x1f
    (ite (= ((_ extract 32 32) x) #b1) #x20
    (ite (= ((_ extract 33 33) x) #b1) #x21
    (ite (= ((_ extract 34 34) x) #b1) #x22
    (ite (= ((_ extract 35 35) x) #b1) #x23
    (ite (= ((_ extract 36 36) x) #b1) #x24
    (ite (= ((_ extract 37 37) x) #b1) #x25
    (ite (= ((_ extract 38 38) x) #b1) #x26
    (ite (= ((_ extract 39 39) x) #b1) #x27
    (ite (= ((_ extract 40 40) x) #b1) #x28
    (ite (= ((_ extract 41 41) x) #b1) #x29
    (ite (= ((_ extract 42 42) x) #b1) #x2a
    (ite (= ((_ extract 43 43) x) #b1) #x2b
    (ite (= ((_ extract 44 44) x) #b1) #x2c
    (ite (= ((_ extract 45 45) x) #b1) #x2d
    (ite (= ((_ extract 46 46) x) #b1) #x2e
    (ite (= ((_ extract 47 47) x) #b1) #x2f
    (ite (= ((_ extract 48 48) x) #b1) #x30
    (ite (= ((_ extract 49 49) x) #b1) #x31
    (ite (= ((_ extract 50 50) x) #b1) #x32
    (ite (= ((_ extract 51 51) x) #b1) #x33
    (ite (= ((_ extract 52 52) x) #b1) #x34
    (ite (= ((_ extract 53 53) x) #b1) #x35
    (ite (= ((_ extract 54 54) x) #b1) #x36
    (ite (= ((_ extract 55 55) x) #b1) #x37
    (ite (= ((_ extract 56 56) x) #b1) #x38
    (ite (= ((_ extract 57 57) x) #b1) #x39
    (ite (= ((_ extract 58 58) x) #b1) #x3a
    (ite (= ((_ extract 59 59) x) #b1) #x3b
    (ite (= ((_ extract 60 60) x) #b1) #x3c
    (ite (= ((_ extract 61 61) x) #b1) #x3d
    (ite (= ((_ extract 62 62) x) #b1) #x3e
    (ite (= ((_ extract 63 63) x) #b1) #x3f
    #x40)))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))))
; verified_ops.zig slotBitmapMask: 1 << @truncate(slot)  (shift amount = slot mod 64)
(define-fun mask ((s (_ BitVec 64))) (_ BitVec 64) (bvshl #x0000000000000001 (bvand s #x000000000000003f)))
; verified_ops.zig slotBitmapTake / slotBitmapRelease
(define-fun take ((x (_ BitVec 64)) (s (_ BitVec 64))) (_ BitVec 64) (bvand x (bvnot (mask s))))
(define-fun release ((x (_ BitVec 64)) (s (_ BitVec 64))) (_ BitVec 64) (bvor x (mask s)))
(define-fun bit ((x (_ BitVec 64)) (i (_ BitVec 8))) Bool
  (not (= (bvand x (bvshl #x0000000000000001 ((_ zero_extend 56) i))) #x0000000000000000)))
(define-fun lowest () (_ BitVec 64) ((_ zero_extend 56) (ctz word)))
(define-fun taken () (_ BitVec 64) (take word lowest))

;; ---- Hypotheses
; `other` is a bit index of the word
(assert (bvult other #x40))

(check-sat)
(exit)
