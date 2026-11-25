/-
  GuillotineSpec.Rlp

  Recursive Length Prefix reference encoder and decoder (Yellow Paper Appendix B).

  The decoder accepts exactly the canonical encodings and reports the first
  violation it meets, with the same error taxonomy and recursion limit as the
  Voltaire implementation Guillotine uses (`lib/voltaire/src/primitives/rlp.zig`).
-/
import GuillotineSpec.Hex

namespace GuillotineSpec
namespace Rlp

/-- An RLP item: a byte string or a list of items. -/
inductive Item where
  | str (b : Bytes)
  | list (items : List Item)

inductive DecodeError where
  | inputTooShort
  | leadingZeros
  | nonCanonicalSize
  | invalidRemainder
  | recursionDepthExceeded
  deriving Repr, BEq, DecidableEq

def DecodeError.name : DecodeError → String
  | .inputTooShort => "InputTooShort"
  | .leadingZeros => "LeadingZeros"
  | .nonCanonicalSize => "NonCanonicalSize"
  | .invalidRemainder => "InvalidRemainder"
  | .recursionDepthExceeded => "RecursionDepthExceeded"

/-- Nesting limit of the decoder: an item at depth 32 or deeper is rejected. -/
def maxDepth : Nat := 32

/-! ### Encoding -/

/-- Length prefix: `base + len` for payloads under 56 bytes, otherwise
    `base + 55 + (byte length of len)` followed by `len` big-endian. -/
def encodeLength (len base : Nat) : Bytes :=
  if len < 56 then ByteArray.empty.push (UInt8.ofNat (base + len))
  else
    let lenBytes := Bytes.ofNatMinimal len
    (ByteArray.empty.push (UInt8.ofNat (base + 55 + lenBytes.size))) ++ lenBytes

/-- Encode a byte string. A single byte below `0x80` is its own encoding. -/
def encodeBytes (b : Bytes) : Bytes :=
  if b.size = 1 ∧ Bytes.getZ b 0 < 0x80 then b else encodeLength b.size 0x80 ++ b

mutual
  /-- Encode an item. -/
  def encode : Item → Bytes
    | .str b => encodeBytes b
    | .list items =>
      let payload := encodeItems items
      encodeLength payload.size 0xc0 ++ payload

  /-- Concatenated encodings of a list of items. -/
  def encodeItems : List Item → Bytes
    | [] => ByteArray.empty
    | x :: xs => encode x ++ encodeItems xs
end

/-- Encode a natural number as its minimal big-endian byte string (`0` is the empty string). -/
def encodeNat (n : Nat) : Bytes := encodeBytes (Bytes.ofNatMinimal n)

/-! ### Decoding -/

mutual
  /-- Decoder for one item starting at offset `pos` of `input`, confined to `[pos, stop)`.
      Returns the item and the offset just past it. Every call consumes fuel; each
      consumes at least one input byte or ends a list, so `2 * input.size + 4` suffices. -/
  private def decodeAt (input : Bytes) : Nat → Nat → Nat → Nat → Except DecodeError (Item × Nat)
    | 0, _, _, _ => .error .inputTooShort
    | fuel + 1, pos, stop, depth =>
      if pos ≥ stop then .error .inputTooShort
      else if depth ≥ maxDepth then .error .recursionDepthExceeded
      else
        let prefixByte := Bytes.getZ input pos
        let avail := stop - pos - 1
        if prefixByte ≤ 0x7f then .ok (.str (input.extract pos (pos + 1)), pos + 1)
        else if prefixByte ≤ 0xb7 then
          let len := prefixByte - 0x80
          if avail < len then .error .inputTooShort
          else if len = 1 ∧ Bytes.getZ input (pos + 1) < 0x80 then .error .nonCanonicalSize
          else .ok (.str (input.extract (pos + 1) (pos + 1 + len)), pos + 1 + len)
        else if prefixByte ≤ 0xbf then
          let lenOfLen := prefixByte - 0xb7
          if avail < lenOfLen then .error .inputTooShort
          else if Bytes.getZ input (pos + 1) = 0 then .error .leadingZeros
          else
            let len := Bytes.toNat (input.extract (pos + 1) (pos + 1 + lenOfLen))
            if len < 56 then .error .nonCanonicalSize
            else if avail - lenOfLen < len then .error .inputTooShort
            else
              let start := pos + 1 + lenOfLen
              .ok (.str (input.extract start (start + len)), start + len)
        else if prefixByte ≤ 0xf7 then
          let len := prefixByte - 0xc0
          if avail < len then .error .inputTooShort
          else
            match decodeItems input fuel (pos + 1) (pos + 1 + len) depth [] with
            | .error e => .error e
            | .ok xs => .ok (.list xs, pos + 1 + len)
        else
          let lenOfLen := prefixByte - 0xf7
          if avail < lenOfLen then .error .inputTooShort
          else if Bytes.getZ input (pos + 1) = 0 then .error .leadingZeros
          else
            let len := Bytes.toNat (input.extract (pos + 1) (pos + 1 + lenOfLen))
            if len < 56 then .error .nonCanonicalSize
            else if avail - lenOfLen < len then .error .inputTooShort
            else
              let start := pos + 1 + lenOfLen
              match decodeItems input fuel start (start + len) depth [] with
              | .error e => .error e
              | .ok xs => .ok (.list xs, start + len)

  /-- Decode the items of a list payload `[cur, stop)` whose list sits at `depth`. -/
  private def decodeItems (input : Bytes) : Nat → Nat → Nat → Nat → List Item → Except DecodeError (List Item)
    | 0, _, _, _, _ => .error .inputTooShort
    | fuel + 1, cur, stop, depth, acc =>
      if cur ≥ stop then .ok acc.reverse
      else
        match decodeAt input fuel cur stop (depth + 1) with
        | .error e => .error e
        | .ok (item, next) => decodeItems input fuel next stop depth (item :: acc)
end

/-- Decode exactly one item. Trailing bytes are an error unless `stream` is set, in which
    case the unread remainder is returned. Empty input decodes to the empty string. -/
def decode (input : Bytes) (stream : Bool := false) : Except DecodeError (Item × Bytes) :=
  if input.size = 0 then .ok (.str ByteArray.empty, ByteArray.empty)
  else
    match decodeAt input (2 * input.size + 4) 0 input.size 0 with
    | .error e => .error e
    | .ok (item, next) =>
      if !stream ∧ next < input.size then .error .invalidRemainder
      else .ok (item, input.extract next input.size)

end Rlp
end GuillotineSpec
