package primitives

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Address represents a 20-byte Ethereum address
type Address struct {
	bytes [20]byte
}

// NewAddress creates a new Address from a byte array
func NewAddress(bytes [20]byte) Address {
	return Address{bytes: bytes}
}

// AddressFromBytes creates an Address from a byte slice
func AddressFromBytes(b []byte) (Address, error) {
	if len(b) != 20 {
		return Address{}, fmt.Errorf("invalid address length: expected 20 bytes, got %d", len(b))
	}
	
	var addr Address
	copy(addr.bytes[:], b)
	return addr, nil
}

// AddressFromHex creates an Address from a hex string
func AddressFromHex(s string) (Address, error) {
	// Remove 0x prefix if present
	s = strings.TrimPrefix(s, "0x")
	
	// Pad with leading zeros if necessary
	if len(s) < 40 {
		s = strings.Repeat("0", 40-len(s)) + s
	}
	
	if len(s) != 40 {
		return Address{}, fmt.Errorf("invalid hex address length: expected 40 characters, got %d", len(s))
	}
	
	bytes, err := hex.DecodeString(s)
	if err != nil {
		return Address{}, fmt.Errorf("invalid hex address: %w", err)
	}
	
	return AddressFromBytes(bytes)
}

// ZeroAddress returns the zero address (0x0000...0000)
func ZeroAddress() Address {
	return Address{}
}

// Bytes returns the address as a byte slice
func (a Address) Bytes() []byte {
	result := make([]byte, 20)
	copy(result, a.bytes[:])
	return result
}

// Array returns the address as a byte array
func (a Address) Array() [20]byte {
	return a.bytes
}

// Hex returns the address as a hex string with 0x prefix
func (a Address) Hex() string {
	return "0x" + hex.EncodeToString(a.bytes[:])
}

// String returns the address as a hex string with 0x prefix
func (a Address) String() string {
	return a.Hex()
}

// IsZero returns true if the address is the zero address
func (a Address) IsZero() bool {
	for _, b := range a.bytes {
		if b != 0 {
			return false
		}
	}
	return true
}

// Equal returns true if two addresses are equal
func (a Address) Equal(other Address) bool {
	return a.bytes == other.bytes
}

// MarshalText implements encoding.TextMarshaler
func (a Address) MarshalText() ([]byte, error) {
	return []byte(a.Hex()), nil
}

// UnmarshalText implements encoding.TextUnmarshaler
func (a *Address) UnmarshalText(text []byte) error {
	addr, err := AddressFromHex(string(text))
	if err != nil {
		return err
	}
	*a = addr
	return nil
}