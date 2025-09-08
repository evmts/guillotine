package primitives

import (
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
)

// U256 represents a 256-bit unsigned integer
type U256 struct {
	bytes [32]byte // Little-endian representation
}

// NewU256 creates a new U256 from a uint64
func NewU256(value uint64) U256 {
	var u U256
	// Store in little-endian format
	for i := 0; i < 8; i++ {
		u.bytes[i] = byte(value >> (i * 8))
	}
	return u
}

// U256FromBytes creates a U256 from a byte slice (big-endian)
func U256FromBytes(b []byte) (U256, error) {
	if len(b) > 32 {
		return U256{}, fmt.Errorf("invalid U256 length: expected at most 32 bytes, got %d", len(b))
	}
	
	var u U256
	// Convert from big-endian to little-endian
	for i, j := 0, len(b)-1; j >= 0; i, j = i+1, j-1 {
		u.bytes[i] = b[j]
	}
	return u, nil
}

// U256FromHex creates a U256 from a hex string
func U256FromHex(s string) (U256, error) {
	// Remove 0x prefix if present
	s = strings.TrimPrefix(s, "0x")
	
	// Pad with leading zeros if necessary
	if len(s)%2 != 0 {
		s = "0" + s
	}
	
	if len(s) > 64 {
		return U256{}, fmt.Errorf("invalid hex U256 length: expected at most 64 characters, got %d", len(s))
	}
	
	bytes, err := hex.DecodeString(s)
	if err != nil {
		return U256{}, fmt.Errorf("invalid hex U256: %w", err)
	}
	
	return U256FromBytes(bytes)
}

// U256FromBigInt creates a U256 from a big.Int
func U256FromBigInt(b *big.Int) (U256, error) {
	if b.Sign() < 0 {
		return U256{}, fmt.Errorf("U256 cannot be negative")
	}
	
	// Check if the number fits in 256 bits
	if b.BitLen() > 256 {
		return U256{}, fmt.Errorf("number too large for U256")
	}
	
	bytes := b.Bytes() // big-endian
	return U256FromBytes(bytes)
}

// ZeroU256 returns a U256 with value 0
func ZeroU256() U256 {
	return U256{}
}

// OneU256 returns a U256 with value 1
func OneU256() U256 {
	return NewU256(1)
}

// MaxU256 returns the maximum U256 value (2^256 - 1)
func MaxU256() U256 {
	var u U256
	for i := range u.bytes {
		u.bytes[i] = 0xFF
	}
	return u
}

// Bytes returns the U256 as a byte slice (big-endian)
func (u U256) Bytes() []byte {
	result := make([]byte, 32)
	// Convert from little-endian to big-endian
	for i, j := 0, 31; i < 32; i, j = i+1, j-1 {
		result[j] = u.bytes[i]
	}
	return result
}

// Array returns the U256 as a byte array (little-endian internal representation)
func (u U256) Array() [32]byte {
	return u.bytes
}

// Hex returns the U256 as a hex string with 0x prefix
func (u U256) Hex() string {
	bytes := u.Bytes() // big-endian
	// Trim leading zeros
	start := 0
	for start < len(bytes) && bytes[start] == 0 {
		start++
	}
	
	if start == len(bytes) {
		return "0x0"
	}
	
	return "0x" + hex.EncodeToString(bytes[start:])
}

// String returns the U256 as a decimal string
func (u U256) String() string {
	return u.ToBigInt().String()
}

// ToBigInt converts the U256 to a big.Int
func (u U256) ToBigInt() *big.Int {
	bytes := u.Bytes() // big-endian
	return new(big.Int).SetBytes(bytes)
}

// Uint64 returns the U256 as a uint64 (panics if too large)
func (u U256) Uint64() uint64 {
	// Check if the value fits in uint64
	for i := 8; i < 32; i++ {
		if u.bytes[i] != 0 {
			panic("U256 value too large for uint64")
		}
	}
	
	var result uint64
	for i := 0; i < 8; i++ {
		result |= uint64(u.bytes[i]) << (i * 8)
	}
	return result
}

// TryUint64 returns the U256 as a uint64 and a boolean indicating success
func (u U256) TryUint64() (uint64, bool) {
	// Check if the value fits in uint64
	for i := 8; i < 32; i++ {
		if u.bytes[i] != 0 {
			return 0, false
		}
	}
	
	var result uint64
	for i := 0; i < 8; i++ {
		result |= uint64(u.bytes[i]) << (i * 8)
	}
	return result, true
}

// IsZero returns true if the U256 is zero
func (u U256) IsZero() bool {
	for _, b := range u.bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

// Equal returns true if two U256s are equal
func (u U256) Equal(other U256) bool {
	return u.bytes == other.bytes
}

// Less returns true if u < other
func (u U256) Less(other U256) bool {
	// Compare from most significant byte (index 31) to least significant (index 0)
	for i := 31; i >= 0; i-- {
		if u.bytes[i] < other.bytes[i] {
			return true
		}
		if u.bytes[i] > other.bytes[i] {
			return false
		}
	}
	return false // Equal
}

// Greater returns true if u > other
func (u U256) Greater(other U256) bool {
	return other.Less(u)
}

// LessOrEqual returns true if u <= other
func (u U256) LessOrEqual(other U256) bool {
	return !u.Greater(other)
}

// GreaterOrEqual returns true if u >= other
func (u U256) GreaterOrEqual(other U256) bool {
	return !u.Less(other)
}

// Add performs addition with overflow detection
func (u U256) Add(other U256) (U256, error) {
	var result U256
	var carry uint16
	
	for i := 0; i < 32; i++ {
		sum := uint16(u.bytes[i]) + uint16(other.bytes[i]) + carry
		result.bytes[i] = byte(sum)
		carry = sum >> 8
	}
	
	if carry != 0 {
		return U256{}, fmt.Errorf("addition overflow")
	}
	
	return result, nil
}

// Sub performs subtraction with underflow detection
func (u U256) Sub(other U256) (U256, error) {
	if u.Less(other) {
		return U256{}, fmt.Errorf("subtraction underflow")
	}
	
	var result U256
	var borrow uint16
	
	for i := 0; i < 32; i++ {
		diff := uint16(u.bytes[i]) - uint16(other.bytes[i]) - borrow
		if diff > 255 { // Underflow occurred
			result.bytes[i] = byte(diff + 256)
			borrow = 1
		} else {
			result.bytes[i] = byte(diff)
			borrow = 0
		}
	}
	
	return result, nil
}

// Mul performs multiplication with overflow detection
func (u U256) Mul(other U256) (U256, error) {
	// Use big.Int for multiplication to detect overflow
	a := u.ToBigInt()
	b := other.ToBigInt()
	result := new(big.Int).Mul(a, b)
	
	// Check if result fits in 256 bits
	if result.BitLen() > 256 {
		return U256{}, fmt.Errorf("multiplication overflow")
	}
	
	return U256FromBigInt(result)
}

// Div performs division with division by zero detection
func (u U256) Div(other U256) (U256, error) {
	if other.IsZero() {
		return U256{}, fmt.Errorf("division by zero")
	}
	
	a := u.ToBigInt()
	b := other.ToBigInt()
	result := new(big.Int).Div(a, b)
	
	return U256FromBigInt(result)
}

// Mod performs modulo operation
func (u U256) Mod(other U256) (U256, error) {
	if other.IsZero() {
		return U256{}, fmt.Errorf("modulo by zero")
	}
	
	a := u.ToBigInt()
	b := other.ToBigInt()
	result := new(big.Int).Mod(a, b)
	
	return U256FromBigInt(result)
}

// MarshalText implements encoding.TextMarshaler
func (u U256) MarshalText() ([]byte, error) {
	return []byte(u.Hex()), nil
}

// UnmarshalText implements encoding.TextUnmarshaler
func (u *U256) UnmarshalText(text []byte) error {
	val, err := U256FromHex(string(text))
	if err != nil {
		return err
	}
	*u = val
	return nil
}