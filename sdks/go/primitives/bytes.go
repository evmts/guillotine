package primitives

import (
	"encoding/hex"
	"fmt"
	"strings"
)

// Bytes represents a variable-length byte array
type Bytes struct {
	data []byte
}

// NewBytes creates a new Bytes from a byte slice
func NewBytes(data []byte) Bytes {
	// Create a copy to avoid external modifications
	result := make([]byte, len(data))
	copy(result, data)
	return Bytes{data: result}
}

// BytesFromHex creates Bytes from a hex string
func BytesFromHex(s string) (Bytes, error) {
	// Remove 0x prefix if present
	s = strings.TrimPrefix(s, "0x")
	
	// Add leading zero if odd length
	if len(s)%2 != 0 {
		s = "0" + s
	}
	
	data, err := hex.DecodeString(s)
	if err != nil {
		return Bytes{}, fmt.Errorf("invalid hex bytes: %w", err)
	}
	
	return NewBytes(data), nil
}

// EmptyBytes creates an empty Bytes
func EmptyBytes() Bytes {
	return Bytes{data: []byte{}}
}

// Data returns a copy of the underlying byte data
func (b Bytes) Data() []byte {
	result := make([]byte, len(b.data))
	copy(result, b.data)
	return result
}

// Len returns the length of the byte array
func (b Bytes) Len() int {
	return len(b.data)
}

// IsEmpty returns true if the byte array is empty
func (b Bytes) IsEmpty() bool {
	return len(b.data) == 0
}

// Hex returns the bytes as a hex string with 0x prefix
func (b Bytes) Hex() string {
	if len(b.data) == 0 {
		return "0x"
	}
	return "0x" + hex.EncodeToString(b.data)
}

// String returns the bytes as a hex string with 0x prefix
func (b Bytes) String() string {
	return b.Hex()
}

// Equal returns true if two Bytes are equal
func (b Bytes) Equal(other Bytes) bool {
	if len(b.data) != len(other.data) {
		return false
	}
	
	for i, v := range b.data {
		if v != other.data[i] {
			return false
		}
	}
	
	return true
}

// Append creates a new Bytes with additional data appended
func (b Bytes) Append(data []byte) Bytes {
	result := make([]byte, len(b.data)+len(data))
	copy(result, b.data)
	copy(result[len(b.data):], data)
	return Bytes{data: result}
}

// Slice returns a new Bytes containing a slice of the data
func (b Bytes) Slice(start, end int) (Bytes, error) {
	if start < 0 || end < 0 || start > end || end > len(b.data) {
		return Bytes{}, fmt.Errorf("invalid slice bounds: start=%d, end=%d, len=%d", start, end, len(b.data))
	}
	
	result := make([]byte, end-start)
	copy(result, b.data[start:end])
	return Bytes{data: result}, nil
}

// At returns the byte at the given index
func (b Bytes) At(index int) (byte, error) {
	if index < 0 || index >= len(b.data) {
		return 0, fmt.Errorf("index out of bounds: %d", index)
	}
	return b.data[index], nil
}

// MarshalText implements encoding.TextMarshaler
func (b Bytes) MarshalText() ([]byte, error) {
	return []byte(b.Hex()), nil
}

// UnmarshalText implements encoding.TextUnmarshaler
func (b *Bytes) UnmarshalText(text []byte) error {
	bytes, err := BytesFromHex(string(text))
	if err != nil {
		return err
	}
	*b = bytes
	return nil
}