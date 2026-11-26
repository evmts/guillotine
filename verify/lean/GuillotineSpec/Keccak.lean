/-
  GuillotineSpec.Keccak

  Keccak-256 (the original Keccak padding `0x01`, as used by Ethereum; not
  NIST SHA3-256). Needed by the reference interpreter for the KECCAK256 and
  EXTCODEHASH opcodes.

  Reference: "The Keccak reference", Bertoni, Daemen, Peeters, Van Assche.
-/
import GuillotineSpec.Hex

namespace GuillotineSpec
namespace Keccak

private def roundConstants : Array UInt64 := #[
  0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
  0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
  0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
  0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
  0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
  0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]

private def rotationOffsets : Array Nat :=
  #[1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 2, 14, 27, 41, 56, 8, 25, 43, 62, 18, 39, 61, 20, 44]

private def piLanes : Array Nat :=
  #[10, 7, 11, 17, 18, 3, 5, 16, 8, 21, 24, 4, 15, 23, 19, 13, 12, 2, 20, 14, 22, 9, 6, 1]

@[inline] private def rotl (x : UInt64) (n : Nat) : UInt64 :=
  if n % 64 = 0 then x else (x <<< (UInt64.ofNat (n % 64))) ||| (x >>> (UInt64.ofNat (64 - n % 64)))

@[inline] private def lane (st : Array UInt64) (i : Nat) : UInt64 := st.getD i 0

/-- One round of Keccak-f[1600]. -/
private def round (st : Array UInt64) (rc : UInt64) : Array UInt64 := Id.run do
  let mut st := st
  -- θ
  let mut bc : Array UInt64 := Array.replicate 5 0
  for i in [0:5] do
    bc := bc.set! i (lane st i ^^^ lane st (i + 5) ^^^ lane st (i + 10) ^^^ lane st (i + 15) ^^^ lane st (i + 20))
  for i in [0:5] do
    let t := lane bc ((i + 4) % 5) ^^^ rotl (lane bc ((i + 1) % 5)) 1
    for j in [0:5] do
      st := st.set! (j * 5 + i) (lane st (j * 5 + i) ^^^ t)
  -- ρ and π
  let mut t := lane st 1
  for i in [0:24] do
    let j := piLanes.getD i 0
    let saved := lane st j
    st := st.set! j (rotl t (rotationOffsets.getD i 0))
    t := saved
  -- χ
  for j in [0:5] do
    let row := #[lane st (j * 5), lane st (j * 5 + 1), lane st (j * 5 + 2), lane st (j * 5 + 3), lane st (j * 5 + 4)]
    for i in [0:5] do
      st := st.set! (j * 5 + i) (lane row i ^^^ ((~~~ lane row ((i + 1) % 5)) &&& lane row ((i + 2) % 5)))
  -- ι
  st := st.set! 0 (lane st 0 ^^^ rc)
  return st

/-- The Keccak-f[1600] permutation on 25 little-endian 64-bit lanes. -/
private def permute (st : Array UInt64) : Array UInt64 :=
  roundConstants.foldl round st

/-- Rate of Keccak-256 in bytes. -/
private def rate : Nat := 136

/-- XOR one rate-sized block (at byte offset `off` of `data`) into the state. -/
private def absorbBlock (st : Array UInt64) (data : ByteArray) (off : Nat) : Array UInt64 := Id.run do
  let mut st := st
  for i in [0:rate / 8] do
    let mut w : UInt64 := 0
    for k in [0:8] do
      w := w ||| ((UInt64.ofNat (Bytes.getZ data (off + i * 8 + k))) <<< (UInt64.ofNat (8 * k)))
    st := st.set! i (lane st i ^^^ w)
  return st

/-- Keccak-256 digest (32 bytes). -/
def hash (input : ByteArray) : ByteArray := Id.run do
  -- pad10*1 with the Keccak domain byte 0x01
  let padLen := rate - input.size % rate
  let mut padded := input
  for i in [0:padLen] do
    let first : UInt8 := if i = 0 then 0x01 else 0x00
    let last : UInt8 := if i = padLen - 1 then 0x80 else 0x00
    padded := padded.push (first ||| last)
  let mut st : Array UInt64 := Array.replicate 25 0
  for b in [0:padded.size / rate] do
    st := permute (absorbBlock st padded (b * rate))
  let mut out := ByteArray.emptyWithCapacity 32
  for i in [0:4] do
    for k in [0:8] do
      out := out.push (UInt8.ofNat (((lane st i) >>> (UInt64.ofNat (8 * k))).toNat % 256))
  return out

/-- Keccak-256 digest as a 256-bit word. -/
def hashWord (input : ByteArray) : Nat := Bytes.toNat (hash input)

end Keccak
end GuillotineSpec
