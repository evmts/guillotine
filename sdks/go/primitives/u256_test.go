package primitives

import (
	"math/big"
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestU256(t *testing.T) {
	t.Run("NewU256", func(t *testing.T) {
		u := NewU256(42)
		assert.False(t, u.IsZero())
		assert.Equal(t, uint64(42), u.Uint64())
	})
	
	t.Run("ZeroU256", func(t *testing.T) {
		u := ZeroU256()
		assert.True(t, u.IsZero())
		assert.Equal(t, uint64(0), u.Uint64())
	})
	
	t.Run("OneU256", func(t *testing.T) {
		u := OneU256()
		assert.False(t, u.IsZero())
		assert.Equal(t, uint64(1), u.Uint64())
	})
	
	t.Run("MaxU256", func(t *testing.T) {
		u := MaxU256()
		assert.False(t, u.IsZero())
		
		// Should panic when converting to uint64
		assert.Panics(t, func() {
			u.Uint64()
		})
		
		// But TryUint64 should return false
		_, ok := u.TryUint64()
		assert.False(t, ok)
	})
	
	t.Run("U256FromBytes", func(t *testing.T) {
		// Test with small number
		bytes := []byte{0x2A} // 42 in hex
		u, err := U256FromBytes(bytes)
		require.NoError(t, err)
		assert.Equal(t, uint64(42), u.Uint64())
		
		// Test with zero
		u2, err := U256FromBytes([]byte{})
		require.NoError(t, err)
		assert.True(t, u2.IsZero())
		
		// Test too large
		largeBytes := make([]byte, 33)
		largeBytes[32] = 1
		_, err = U256FromBytes(largeBytes)
		assert.Error(t, err)
	})
	
	t.Run("U256FromHex", func(t *testing.T) {
		// Test with 0x prefix
		u1, err := U256FromHex("0x2A")
		require.NoError(t, err)
		assert.Equal(t, uint64(42), u1.Uint64())
		
		// Test without 0x prefix
		u2, err := U256FromHex("2A")
		require.NoError(t, err)
		assert.Equal(t, u1, u2)
		
		// Test odd length (should pad)
		u3, err := U256FromHex("0xF")
		require.NoError(t, err)
		assert.Equal(t, uint64(15), u3.Uint64())
		
		// Test invalid hex
		_, err = U256FromHex("0xGG")
		assert.Error(t, err)
	})
	
	t.Run("U256FromBigInt", func(t *testing.T) {
		// Test positive number
		big1 := big.NewInt(12345)
		u1, err := U256FromBigInt(big1)
		require.NoError(t, err)
		assert.Equal(t, uint64(12345), u1.Uint64())
		
		// Test negative number (should fail)
		big2 := big.NewInt(-1)
		_, err = U256FromBigInt(big2)
		assert.Error(t, err)
		
		// Test too large number
		big3 := new(big.Int).Lsh(big.NewInt(1), 257) // 2^257
		_, err = U256FromBigInt(big3)
		assert.Error(t, err)
	})
	
	t.Run("Hex", func(t *testing.T) {
		u1 := NewU256(0)
		assert.Equal(t, "0x0", u1.Hex())
		
		u2 := NewU256(42)
		assert.Equal(t, "0x2a", u2.Hex())
		
		u3 := NewU256(255)
		assert.Equal(t, "0xff", u3.Hex())
	})
	
	t.Run("ToBigInt", func(t *testing.T) {
		u := NewU256(12345)
		big := u.ToBigInt()
		assert.Equal(t, int64(12345), big.Int64())
	})
	
	t.Run("Equal", func(t *testing.T) {
		u1 := NewU256(42)
		u2 := NewU256(42)
		u3 := NewU256(43)
		
		assert.True(t, u1.Equal(u2))
		assert.False(t, u1.Equal(u3))
	})
	
	t.Run("Comparison", func(t *testing.T) {
		u1 := NewU256(10)
		u2 := NewU256(20)
		u3 := NewU256(10)
		
		assert.True(t, u1.Less(u2))
		assert.False(t, u2.Less(u1))
		assert.False(t, u1.Less(u3))
		
		assert.False(t, u1.Greater(u2))
		assert.True(t, u2.Greater(u1))
		assert.False(t, u1.Greater(u3))
		
		assert.True(t, u1.LessOrEqual(u2))
		assert.True(t, u1.LessOrEqual(u3))
		assert.False(t, u2.LessOrEqual(u1))
		
		assert.False(t, u1.GreaterOrEqual(u2))
		assert.True(t, u1.GreaterOrEqual(u3))
		assert.True(t, u2.GreaterOrEqual(u1))
	})
	
	t.Run("Add", func(t *testing.T) {
		u1 := NewU256(10)
		u2 := NewU256(20)
		
		result, err := u1.Add(u2)
		require.NoError(t, err)
		assert.Equal(t, uint64(30), result.Uint64())
		
		// Test overflow
		max := MaxU256()
		_, err = max.Add(OneU256())
		assert.Error(t, err)
	})
	
	t.Run("Sub", func(t *testing.T) {
		u1 := NewU256(20)
		u2 := NewU256(10)
		
		result, err := u1.Sub(u2)
		require.NoError(t, err)
		assert.Equal(t, uint64(10), result.Uint64())
		
		// Test underflow
		_, err = u2.Sub(u1)
		assert.Error(t, err)
	})
	
	t.Run("Mul", func(t *testing.T) {
		u1 := NewU256(10)
		u2 := NewU256(20)
		
		result, err := u1.Mul(u2)
		require.NoError(t, err)
		assert.Equal(t, uint64(200), result.Uint64())
		
		// Test overflow
		big1, _ := U256FromHex("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
		big2, _ := U256FromHex("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
		_, err = big1.Mul(big2)
		assert.Error(t, err)
	})
	
	t.Run("Div", func(t *testing.T) {
		u1 := NewU256(20)
		u2 := NewU256(10)
		
		result, err := u1.Div(u2)
		require.NoError(t, err)
		assert.Equal(t, uint64(2), result.Uint64())
		
		// Test division by zero
		zero := ZeroU256()
		_, err = u1.Div(zero)
		assert.Error(t, err)
	})
	
	t.Run("Mod", func(t *testing.T) {
		u1 := NewU256(23)
		u2 := NewU256(10)
		
		result, err := u1.Mod(u2)
		require.NoError(t, err)
		assert.Equal(t, uint64(3), result.Uint64())
		
		// Test modulo by zero
		zero := ZeroU256()
		_, err = u1.Mod(zero)
		assert.Error(t, err)
	})
	
	t.Run("MarshalUnmarshalText", func(t *testing.T) {
		u1 := NewU256(12345)
		
		// Marshal
		text, err := u1.MarshalText()
		require.NoError(t, err)
		
		// Unmarshal
		var u2 U256
		err = u2.UnmarshalText(text)
		require.NoError(t, err)
		
		assert.Equal(t, u1, u2)
	})
}