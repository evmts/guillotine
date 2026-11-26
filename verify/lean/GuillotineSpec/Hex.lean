/-
  GuillotineSpec.Hex

  Byte-string and hexadecimal helpers shared by the executable reference
  specification and its line-oriented oracle (`GuillotineSpec/Main.lean`).

  Everything here is total: malformed input yields `none`, never a panic.
-/

namespace GuillotineSpec

/-- Byte strings are immutable `ByteArray`s throughout the specification. -/
abbrev Bytes := ByteArray

namespace Hex

/-- Value of one hexadecimal digit. -/
def digitVal (c : Char) : Option Nat :=
  if '0' ≤ c ∧ c ≤ '9' then some (c.toNat - '0'.toNat)
  else if 'a' ≤ c ∧ c ≤ 'f' then some (c.toNat - 'a'.toNat + 10)
  else if 'A' ≤ c ∧ c ≤ 'F' then some (c.toNat - 'A'.toNat + 10)
  else none

/-- Lower-case hexadecimal digit of a nibble (`n % 16`). -/
def digitChar (n : Nat) : Char :=
  let d := n % 16
  if d < 10 then Char.ofNat ('0'.toNat + d) else Char.ofNat ('a'.toNat + (d - 10))

/-- Parse an unprefixed hexadecimal natural number. The empty string is `0`. -/
def parseNat (s : String) : Option Nat :=
  s.foldl (fun acc c => do
    let a ← acc
    let d ← digitVal c
    pure (a * 16 + d)) (some 0)

/-- Parse an unprefixed decimal natural number. -/
def parseDec (s : String) : Option Nat :=
  if s.isEmpty then none
  else s.foldl (fun acc c => do
    let a ← acc
    if '0' ≤ c ∧ c ≤ '9' then pure (a * 10 + (c.toNat - '0'.toNat)) else none) (some 0)

private def parseBytesLoop : List Char → ByteArray → Option ByteArray
  | [], acc => some acc
  | [_], _ => none
  | hi :: lo :: rest, acc => do
    let h ← digitVal hi
    let l ← digitVal lo
    parseBytesLoop rest (acc.push (UInt8.ofNat (h * 16 + l)))

/-- Parse an unprefixed, even-length hexadecimal byte string. `-` denotes the empty string. -/
def parseBytes (s : String) : Option ByteArray :=
  if s == "-" then some ByteArray.empty
  else parseBytesLoop s.toList (ByteArray.emptyWithCapacity (s.length / 2))

/-- Minimal lower-case hexadecimal rendering of a natural number (`0` renders as `0`). -/
def ofNat (n : Nat) : String :=
  String.ofList (Nat.toDigits 16 n)

/-- Lower-case hexadecimal rendering of a byte string. The empty string renders as `-`. -/
def ofBytes (b : ByteArray) : String :=
  if b.size == 0 then "-"
  else
    String.ofList (b.foldl (fun acc x => digitChar x.toNat :: digitChar (x.toNat / 16) :: acc) []).reverse

end Hex

namespace Bytes

/-- Byte at `i`, or zero past the end (EVM read semantics for code and calldata). -/
@[inline] def getZ (b : ByteArray) (i : Nat) : Nat :=
  if h : i < b.size then b[i].toNat else 0

/-- `len` bytes starting at `off`, zero-padded past the end of `b`. -/
def sliceZ (b : ByteArray) (off len : Nat) : ByteArray :=
  if off + len ≤ b.size then b.extract off (off + len)
  else
    let avail := if off < b.size then b.extract off b.size else ByteArray.empty
    (List.range (len - avail.size)).foldl (fun acc _ => acc.push 0) avail

/-- Big-endian natural number held in a byte string. -/
def toNat (b : ByteArray) : Nat :=
  b.foldl (fun acc x => acc * 256 + x.toNat) 0

/-- Big-endian encoding of `n` in exactly `len` bytes (high bytes truncated). -/
def ofNatBE (n len : Nat) : ByteArray :=
  (List.range len).foldl
    (fun acc i => acc.push (UInt8.ofNat ((n >>> (8 * (len - 1 - i))) % 256)))
    (ByteArray.emptyWithCapacity len)

/-- Minimal big-endian encoding of `n` (no leading zeros; `0` is the empty string). -/
def ofNatMinimal (n : Nat) : ByteArray :=
  if n = 0 then ByteArray.empty else ofNatBE n (Nat.log2 n / 8 + 1)

/-- `n` zero bytes. -/
def zeros (n : Nat) : ByteArray :=
  (List.range n).foldl (fun acc _ => acc.push 0) (ByteArray.emptyWithCapacity n)

end Bytes

end GuillotineSpec
