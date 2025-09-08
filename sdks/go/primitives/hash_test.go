package primitives

import (
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestHash(t *testing.T) {
	t.Run("ZeroHash", func(t *testing.T) {
		hash := ZeroHash()
		assert.True(t, hash.IsZero())
		assert.Equal(t, "0x0000000000000000000000000000000000000000000000000000000000000000", hash.Hex())
	})
	
	t.Run("NewHash", func(t *testing.T) {
		bytes := [32]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}
		hash := NewHash(bytes)
		assert.False(t, hash.IsZero())
		assert.Equal(t, bytes, hash.Array())
	})
	
	t.Run("HashFromBytes", func(t *testing.T) {
		bytes := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}
		hash, err := HashFromBytes(bytes)
		require.NoError(t, err)
		assert.Equal(t, bytes, hash.Bytes())
		
		// Test invalid length
		_, err = HashFromBytes([]byte{1, 2, 3})
		assert.Error(t, err)
	})
	
	t.Run("HashFromHex", func(t *testing.T) {
		// Test with 0x prefix
		hash1, err := HashFromHex("0x1234567890123456789012345678901234567890123456789012345678901234")
		require.NoError(t, err)
		assert.Equal(t, "0x1234567890123456789012345678901234567890123456789012345678901234", hash1.Hex())
		
		// Test without 0x prefix
		hash2, err := HashFromHex("1234567890123456789012345678901234567890123456789012345678901234")
		require.NoError(t, err)
		assert.Equal(t, hash1, hash2)
		
		// Test short hex (should pad with zeros)
		hash3, err := HashFromHex("0x1234")
		require.NoError(t, err)
		assert.Equal(t, "0x0000000000000000000000000000000000000000000000000000000000001234", hash3.Hex())
		
		// Test invalid hex
		_, err = HashFromHex("0xgg")
		assert.Error(t, err)
	})
	
	t.Run("Equal", func(t *testing.T) {
		hash1, _ := HashFromHex("0x1234567890123456789012345678901234567890123456789012345678901234")
		hash2, _ := HashFromHex("0x1234567890123456789012345678901234567890123456789012345678901234")
		hash3, _ := HashFromHex("0x0987654321098765432109876543210987654321098765432109876543210987")
		
		assert.True(t, hash1.Equal(hash2))
		assert.False(t, hash1.Equal(hash3))
	})
	
	t.Run("String", func(t *testing.T) {
		hash, _ := HashFromHex("0x1234567890123456789012345678901234567890123456789012345678901234")
		assert.Equal(t, "0x1234567890123456789012345678901234567890123456789012345678901234", hash.String())
	})
	
	t.Run("MarshalUnmarshalText", func(t *testing.T) {
		hash1, _ := HashFromHex("0x1234567890123456789012345678901234567890123456789012345678901234")
		
		// Marshal
		text, err := hash1.MarshalText()
		require.NoError(t, err)
		
		// Unmarshal
		var hash2 Hash
		err = hash2.UnmarshalText(text)
		require.NoError(t, err)
		
		assert.Equal(t, hash1, hash2)
	})
}