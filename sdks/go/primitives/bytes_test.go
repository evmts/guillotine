package primitives

import (
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestBytes(t *testing.T) {
	t.Run("NewBytes", func(t *testing.T) {
		data := []byte{1, 2, 3, 4, 5}
		b := NewBytes(data)
		assert.Equal(t, data, b.Data())
		assert.Equal(t, 5, b.Len())
		assert.False(t, b.IsEmpty())
		
		// Ensure it's a copy
		data[0] = 99
		assert.Equal(t, byte(1), b.Data()[0])
	})
	
	t.Run("EmptyBytes", func(t *testing.T) {
		b := EmptyBytes()
		assert.True(t, b.IsEmpty())
		assert.Equal(t, 0, b.Len())
		assert.Equal(t, "0x", b.Hex())
	})
	
	t.Run("BytesFromHex", func(t *testing.T) {
		// Test with 0x prefix
		b1, err := BytesFromHex("0x01020304")
		require.NoError(t, err)
		assert.Equal(t, []byte{1, 2, 3, 4}, b1.Data())
		
		// Test without 0x prefix
		b2, err := BytesFromHex("01020304")
		require.NoError(t, err)
		assert.Equal(t, b1, b2)
		
		// Test odd length (should pad)
		b3, err := BytesFromHex("0x123")
		require.NoError(t, err)
		assert.Equal(t, []byte{0x01, 0x23}, b3.Data())
		
		// Test empty hex
		b4, err := BytesFromHex("0x")
		require.NoError(t, err)
		assert.True(t, b4.IsEmpty())
		
		// Test invalid hex
		_, err = BytesFromHex("0xGG")
		assert.Error(t, err)
	})
	
	t.Run("Hex", func(t *testing.T) {
		b1 := NewBytes([]byte{1, 2, 3, 4})
		assert.Equal(t, "0x01020304", b1.Hex())
		
		b2 := EmptyBytes()
		assert.Equal(t, "0x", b2.Hex())
		
		b3 := NewBytes([]byte{0xde, 0xad, 0xbe, 0xef})
		assert.Equal(t, "0xdeadbeef", b3.Hex())
	})
	
	t.Run("Equal", func(t *testing.T) {
		b1 := NewBytes([]byte{1, 2, 3})
		b2 := NewBytes([]byte{1, 2, 3})
		b3 := NewBytes([]byte{1, 2, 4})
		b4 := NewBytes([]byte{1, 2})
		
		assert.True(t, b1.Equal(b2))
		assert.False(t, b1.Equal(b3))
		assert.False(t, b1.Equal(b4))
	})
	
	t.Run("Append", func(t *testing.T) {
		b1 := NewBytes([]byte{1, 2, 3})
		b2 := b1.Append([]byte{4, 5, 6})
		
		assert.Equal(t, []byte{1, 2, 3, 4, 5, 6}, b2.Data())
		assert.Equal(t, []byte{1, 2, 3}, b1.Data()) // Original unchanged
		
		// Test append to empty
		empty := EmptyBytes()
		b3 := empty.Append([]byte{1, 2, 3})
		assert.Equal(t, []byte{1, 2, 3}, b3.Data())
	})
	
	t.Run("Slice", func(t *testing.T) {
		b := NewBytes([]byte{1, 2, 3, 4, 5})
		
		// Valid slice
		slice, err := b.Slice(1, 4)
		require.NoError(t, err)
		assert.Equal(t, []byte{2, 3, 4}, slice.Data())
		
		// Empty slice
		slice2, err := b.Slice(2, 2)
		require.NoError(t, err)
		assert.True(t, slice2.IsEmpty())
		
		// Full slice
		slice3, err := b.Slice(0, 5)
		require.NoError(t, err)
		assert.Equal(t, b.Data(), slice3.Data())
		
		// Invalid bounds
		_, err = b.Slice(-1, 3)
		assert.Error(t, err)
		
		_, err = b.Slice(1, 0)
		assert.Error(t, err)
		
		_, err = b.Slice(0, 6)
		assert.Error(t, err)
	})
	
	t.Run("At", func(t *testing.T) {
		b := NewBytes([]byte{1, 2, 3, 4, 5})
		
		// Valid index
		val, err := b.At(2)
		require.NoError(t, err)
		assert.Equal(t, byte(3), val)
		
		// Invalid indices
		_, err = b.At(-1)
		assert.Error(t, err)
		
		_, err = b.At(5)
		assert.Error(t, err)
	})
	
	t.Run("String", func(t *testing.T) {
		b := NewBytes([]byte{0xde, 0xad, 0xbe, 0xef})
		assert.Equal(t, "0xdeadbeef", b.String())
	})
	
	t.Run("MarshalUnmarshalText", func(t *testing.T) {
		b1 := NewBytes([]byte{1, 2, 3, 4})
		
		// Marshal
		text, err := b1.MarshalText()
		require.NoError(t, err)
		
		// Unmarshal
		var b2 Bytes
		err = b2.UnmarshalText(text)
		require.NoError(t, err)
		
		assert.Equal(t, b1, b2)
	})
}