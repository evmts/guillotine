package primitives

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Hash represents a 32-byte hash value
type Hash struct {
	bytes [32]byte
}

// NewHash creates a new Hash from a byte array
func NewHash(bytes [32]byte) Hash {
	return Hash{bytes: bytes}
}

// HashFromBytes creates a Hash from a byte slice
func HashFromBytes(b []byte) (Hash, error) {
	if len(b) != 32 {
		return Hash{}, fmt.Errorf("invalid hash length: expected 32 bytes, got %d", len(b))
	}
	
	var hash Hash
	copy(hash.bytes[:], b)
	return hash, nil
}

// HashFromHex creates a Hash from a hex string
func HashFromHex(s string) (Hash, error) {
	// Remove 0x prefix if present
	s = strings.TrimPrefix(s, "0x")
	
	// Pad with leading zeros if necessary
	if len(s) < 64 {
		s = strings.Repeat("0", 64-len(s)) + s
	}
	
	if len(s) != 64 {
		return Hash{}, fmt.Errorf("invalid hex hash length: expected 64 characters, got %d", len(s))
	}
	
	bytes, err := hex.DecodeString(s)
	if err != nil {
		return Hash{}, fmt.Errorf("invalid hex hash: %w", err)
	}
	
	return HashFromBytes(bytes)
}

// ZeroHash returns the zero hash (0x0000...0000)
func ZeroHash() Hash {
	return Hash{}
}

// Bytes returns the hash as a byte slice
func (h Hash) Bytes() []byte {
	result := make([]byte, 32)
	copy(result, h.bytes[:])
	return result
}

// Array returns the hash as a byte array
func (h Hash) Array() [32]byte {
	return h.bytes
}

// Hex returns the hash as a hex string with 0x prefix
func (h Hash) Hex() string {
	return "0x" + hex.EncodeToString(h.bytes[:])
}

// String returns the hash as a hex string with 0x prefix
func (h Hash) String() string {
	return h.Hex()
}

// IsZero returns true if the hash is the zero hash
func (h Hash) IsZero() bool {
	for _, b := range h.bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

// Equal returns true if two hashes are equal
func (h Hash) Equal(other Hash) bool {
	return h.bytes == other.bytes
}

// MarshalText implements encoding.TextMarshaler
func (h Hash) MarshalText() ([]byte, error) {
	return []byte(h.Hex()), nil
}

// UnmarshalText implements encoding.TextUnmarshaler
func (h *Hash) UnmarshalText(text []byte) error {
	hash, err := HashFromHex(string(text))
	if err != nil {
		return err
	}
	*h = hash
	return nil
}