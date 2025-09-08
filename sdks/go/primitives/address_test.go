package primitives

import (
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestAddress(t *testing.T) {
	t.Run("ZeroAddress", func(t *testing.T) {
		addr := ZeroAddress()
		assert.True(t, addr.IsZero())
		assert.Equal(t, "0x0000000000000000000000000000000000000000", addr.Hex())
	})
	
	t.Run("NewAddress", func(t *testing.T) {
		bytes := [20]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
		addr := NewAddress(bytes)
		assert.False(t, addr.IsZero())
		assert.Equal(t, bytes, addr.Array())
	})
	
	t.Run("AddressFromBytes", func(t *testing.T) {
		bytes := []byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
		addr, err := AddressFromBytes(bytes)
		require.NoError(t, err)
		assert.Equal(t, bytes, addr.Bytes())
		
		// Test invalid length
		_, err = AddressFromBytes([]byte{1, 2, 3})
		assert.Error(t, err)
	})
	
	t.Run("AddressFromHex", func(t *testing.T) {
		// Test with 0x prefix
		addr1, err := AddressFromHex("0x1234567890123456789012345678901234567890")
		require.NoError(t, err)
		assert.Equal(t, "0x1234567890123456789012345678901234567890", addr1.Hex())
		
		// Test without 0x prefix
		addr2, err := AddressFromHex("1234567890123456789012345678901234567890")
		require.NoError(t, err)
		assert.Equal(t, addr1, addr2)
		
		// Test short hex (should pad with zeros)
		addr3, err := AddressFromHex("0x1234")
		require.NoError(t, err)
		assert.Equal(t, "0x0000000000000000000000000000000000001234", addr3.Hex())
		
		// Test invalid hex
		_, err = AddressFromHex("0xgg")
		assert.Error(t, err)
	})
	
	t.Run("Equal", func(t *testing.T) {
		addr1, _ := AddressFromHex("0x1234567890123456789012345678901234567890")
		addr2, _ := AddressFromHex("0x1234567890123456789012345678901234567890")
		addr3, _ := AddressFromHex("0x0987654321098765432109876543210987654321")
		
		assert.True(t, addr1.Equal(addr2))
		assert.False(t, addr1.Equal(addr3))
	})
	
	t.Run("String", func(t *testing.T) {
		addr, _ := AddressFromHex("0x1234567890123456789012345678901234567890")
		assert.Equal(t, "0x1234567890123456789012345678901234567890", addr.String())
	})
	
	t.Run("MarshalUnmarshalText", func(t *testing.T) {
		addr1, _ := AddressFromHex("0x1234567890123456789012345678901234567890")
		
		// Marshal
		text, err := addr1.MarshalText()
		require.NoError(t, err)
		
		// Unmarshal
		var addr2 Address
		err = addr2.UnmarshalText(text)
		require.NoError(t, err)
		
		assert.Equal(t, addr1, addr2)
	})
}