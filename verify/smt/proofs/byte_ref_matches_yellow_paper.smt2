;; ==========================================================================
;; Theorem : byte_ref_matches_yellow_paper
;; Suite   : verify/smt/run_smt_suite.py (generated; do not edit by hand)
;; Claim   :
;;   For ALL 2^512 (index, value): byteRef equals the Yellow Paper BYTE, which
;;   selects big-endian byte `index` (byte 0 = bits 255..248) and returns 0 for index >= 32.
;; Method  : assert hypotheses and NOT(claim). Expected `unsat`: no
;;           counterexample exists over the whole input space.
;; Modeled Zig source:
;; --- src/verified_ops.zig:241 (byteRef)
;;   | pub inline fn byteRef(index: u256, value: u256) u256 {
;;   |     if (index >= 32) return 0;
;;   |     const byte_index: u8 = @intCast(index);
;;   |     const shift_bits: u8 = (31 - byte_index) * 8;
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
(assert (not (= (byteRef index value) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000000) ((_ zero_extend 248) ((_ extract 255 248) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000001) ((_ zero_extend 248) ((_ extract 247 240) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000002) ((_ zero_extend 248) ((_ extract 239 232) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000003) ((_ zero_extend 248) ((_ extract 231 224) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000004) ((_ zero_extend 248) ((_ extract 223 216) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000005) ((_ zero_extend 248) ((_ extract 215 208) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000006) ((_ zero_extend 248) ((_ extract 207 200) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000007) ((_ zero_extend 248) ((_ extract 199 192) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000008) ((_ zero_extend 248) ((_ extract 191 184) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000009) ((_ zero_extend 248) ((_ extract 183 176) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000a) ((_ zero_extend 248) ((_ extract 175 168) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000b) ((_ zero_extend 248) ((_ extract 167 160) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000c) ((_ zero_extend 248) ((_ extract 159 152) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000d) ((_ zero_extend 248) ((_ extract 151 144) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000e) ((_ zero_extend 248) ((_ extract 143 136) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000000f) ((_ zero_extend 248) ((_ extract 135 128) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000010) ((_ zero_extend 248) ((_ extract 127 120) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000011) ((_ zero_extend 248) ((_ extract 119 112) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000012) ((_ zero_extend 248) ((_ extract 111 104) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000013) ((_ zero_extend 248) ((_ extract 103 96) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000014) ((_ zero_extend 248) ((_ extract 95 88) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000015) ((_ zero_extend 248) ((_ extract 87 80) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000016) ((_ zero_extend 248) ((_ extract 79 72) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000017) ((_ zero_extend 248) ((_ extract 71 64) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000018) ((_ zero_extend 248) ((_ extract 63 56) value)) (ite (= index #x0000000000000000000000000000000000000000000000000000000000000019) ((_ zero_extend 248) ((_ extract 55 48) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001a) ((_ zero_extend 248) ((_ extract 47 40) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001b) ((_ zero_extend 248) ((_ extract 39 32) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001c) ((_ zero_extend 248) ((_ extract 31 24) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001d) ((_ zero_extend 248) ((_ extract 23 16) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001e) ((_ zero_extend 248) ((_ extract 15 8) value)) (ite (= index #x000000000000000000000000000000000000000000000000000000000000001f) ((_ zero_extend 248) ((_ extract 7 0) value)) #x0000000000000000000000000000000000000000000000000000000000000000)))))))))))))))))))))))))))))))))))
(check-sat)
(exit)
