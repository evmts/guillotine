package evm

import (
	"math/big"
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	
	"github.com/evmts/guillotine/sdks/go/primitives"
)

func TestEVM(t *testing.T) {
	t.Run("NewEVM", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		require.NotNil(t, evm)
		defer evm.Destroy()
	})
	
	t.Run("ExecuteSimpleBytecode", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()
		
		// Simple bytecode: PUSH1 0x42 (pushes 42 onto stack)
		bytecode := []byte{0x60, 0x42}
		
		caller := primitives.ZeroAddress()
		contractAddr, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
		
		// First, deploy the code to an address
		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)
		
		// Now call the deployed code (with empty input data)
		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Simple PUSH operations should succeed
		assert.True(t, result.Success)
		assert.Greater(t, uint64(1000000 - result.GasLeft), uint64(0)) // Gas was used
	})
	
	t.Run("SetGetBalance", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		balance := big.NewInt(1000)
		
		// Set balance
		err = evm.SetBalance(addr, balance)
		require.NoError(t, err)
		
		// Get balance
		retrievedBalance, err := evm.GetBalance(addr)
		require.NoError(t, err)
		assert.Equal(t, balance, retrievedBalance)
	})
	
	t.Run("SetGetCode", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		code := []byte{0x60, 0x80, 0x60, 0x40, 0x52}
		
		// Set code
		err = evm.SetCode(addr, code)
		require.NoError(t, err)
		
		// Get code
		retrievedCode, err := evm.GetCode(addr)
		require.NoError(t, err)
		assert.Equal(t, code, retrievedCode)
	})
	
	t.Run("SetGetStorage", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		key := big.NewInt(1)
		value := big.NewInt(42)
		
		// Set storage
		err = evm.SetStorage(addr, key, value)
		require.NoError(t, err)
		
		// Get storage
		retrievedValue, err := evm.GetStorage(addr, key)
		require.NoError(t, err)
		assert.Equal(t, value, retrievedValue)
	})
	
	t.Run("CallTypes", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()
		
		caller := primitives.ZeroAddress()
		to, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
		
		// Give caller sufficient balance for value transfers
		err = evm.SetBalance(caller, big.NewInt(1000))
		require.NoError(t, err)
		
		// Test CALL
		result, err := evm.Call(Call{
			Caller: caller,
			To:     to,
			Value:  big.NewInt(100),
			Input:  []byte{0x01, 0x02},
			Gas:    100000,
		})
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Test STATICCALL
		result, err = evm.Call(Staticcall{
			Caller: caller,
			To:     to,
			Input:  []byte{0x01, 0x02},
			Gas:    100000,
		})
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Test DELEGATECALL
		result, err = evm.Call(Delegatecall{
			Caller: caller,
			To:     to,
			Input:  []byte{0x01, 0x02},
			Gas:    100000,
		})
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Test CREATE
		result, err = evm.Call(Create{
			Caller:   caller,
			Value:    big.NewInt(0),
			InitCode: []byte{0x60, 0x00, 0x60, 0x00, 0xf3}, // Simple contract that returns empty
			Gas:      200000,
		})
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Test CREATE2
		result, err = evm.Call(Create2{
			Caller:   caller,
			Value:    big.NewInt(0),
			InitCode: []byte{0x60, 0x00, 0x60, 0x00, 0xf3},
			Salt:     big.NewInt(12345),
			Gas:      200000,
		})
		require.NoError(t, err)
		require.NotNil(t, result)
	})
}