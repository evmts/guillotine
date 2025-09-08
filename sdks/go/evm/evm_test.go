package evm

import (
	"testing"
	
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	
	"github.com/evmts/guillotine/bindings/go/primitives"
)

func TestEVM(t *testing.T) {
	t.Run("NewEVM", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		require.NotNil(t, evm)
		defer evm.Close()
	})
	
	t.Run("ExecuteSimpleBytecode", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Close()
		
		// Simple bytecode: PUSH1 0x42 (pushes 42 onto stack)
		bytecode := primitives.NewBytes([]byte{0x60, 0x42})
		
		result, err := evm.Execute(ExecutionParams{
			Bytecode: bytecode,
			Caller:   primitives.ZeroAddress(),
			To:       primitives.ZeroAddress(),
			Value:    primitives.ZeroU256(),
			Input:    primitives.EmptyBytes(),
			GasLimit: 1000000,
		})
		
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Simple PUSH operations should succeed
		assert.True(t, result.IsSuccess())
		assert.Greater(t, result.GasUsed(), uint64(0))
	})
	
	t.Run("SetGetBalance", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Close()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		balance := primitives.NewU256(1000)
		
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
		defer evm.Close()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		code := primitives.NewBytes([]byte{0x60, 0x80, 0x60, 0x40, 0x52})
		
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
		defer evm.Close()
		
		addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
		key := primitives.NewU256(1)
		value := primitives.NewU256(42)
		
		// Set storage
		err = evm.SetStorage(addr, key, value)
		require.NoError(t, err)
		
		// Get storage
		retrievedValue, err := evm.GetStorage(addr, key)
		require.NoError(t, err)
		assert.Equal(t, value, retrievedValue)
	})
	
	t.Run("CloseEVM", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		
		// Close should not error
		err = evm.Close()
		require.NoError(t, err)
		
		// Operations after close should fail
		_, err = evm.GetBalance(primitives.ZeroAddress())
		assert.Error(t, err)
		assert.Contains(t, err.Error(), "closed")
	})
	
	t.Run("ExecutionResult", func(t *testing.T) {
		// Test ExecutionResult methods
		result := &ExecutionResult{
			success:      true,
			gasUsed:      12345,
			returnData:   primitives.NewBytes([]byte{1, 2, 3}),
			revertReason: primitives.EmptyBytes(),
		}
		
		assert.True(t, result.IsSuccess())
		assert.Equal(t, uint64(12345), result.GasUsed())
		assert.True(t, result.HasReturnData())
		assert.False(t, result.HasRevertReason())
		assert.Equal(t, primitives.NewBytes([]byte{1, 2, 3}), result.ReturnData())
		assert.Equal(t, primitives.EmptyBytes(), result.RevertReason())
	})
	
	t.Run("MultipleEVMInstances", func(t *testing.T) {
		// Test that multiple EVM instances work independently
		evm1, err := New()
		require.NoError(t, err)
		defer evm1.Close()
		
		evm2, err := New()
		require.NoError(t, err)
		defer evm2.Close()
		
		addr := primitives.ZeroAddress()
		balance1 := primitives.NewU256(100)
		balance2 := primitives.NewU256(200)
		
		// Set different balances in each EVM
		err = evm1.SetBalance(addr, balance1)
		require.NoError(t, err)
		
		err = evm2.SetBalance(addr, balance2)
		require.NoError(t, err)
		
		// Verify they're independent
		retrieved1, err := evm1.GetBalance(addr)
		require.NoError(t, err)
		assert.Equal(t, balance1, retrieved1)
		
		retrieved2, err := evm2.GetBalance(addr)
		require.NoError(t, err)
		assert.Equal(t, balance2, retrieved2)
	})
}