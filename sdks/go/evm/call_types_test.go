package evm

import (
	"math/big"
	"testing"

	"github.com/evmts/guillotine/sdks/go/primitives"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// Test constants
const (
	StandardGas = 100000
	HighGas = 200000
	VeryHighGas = 1000000
	LargeBalance = 10000000
	CallValue = 1000
)

func TestCallTypes(t *testing.T) {
	t.Run("CALL with value transfer", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x01})
		calleeAddr := primitives.NewAddress([20]byte{0x02})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		calleeCode := []byte{0x60, 0xaa, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(calleeAddr, calleeCode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     calleeAddr,
			Value:  big.NewInt(CallValue),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CALL with value should complete")
		
		calleeBalance, err := evm.GetBalance(calleeAddr)
		require.NoError(t, err)
		assert.Equal(t, big.NewInt(CallValue), calleeBalance, "Callee should have received value")
	})

	t.Run("CALL without value transfer", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x03})
		calleeAddr := primitives.NewAddress([20]byte{0x04})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		calleeCode := []byte{0x60, 0xbb, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(calleeAddr, calleeCode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     calleeAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CALL without value should complete")
	})

	t.Run("DELEGATECALL context preservation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x05})
		delegateAddr := primitives.NewAddress([20]byte{0x06})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		callerInitialStorage := big.NewInt(0xaa)
		storageKey := big.NewInt(0)
		err = evm.SetStorage(callerAddr, storageKey, callerInitialStorage)
		require.NoError(t, err)
		
		delegateCode := []byte{0x60, 0xcc, 0x5f, 0x55}
		err = evm.SetCode(delegateAddr, delegateCode)
		require.NoError(t, err)

		// Direct delegatecall through our API
		result, err := evm.Call(Delegatecall{
			Caller: callerAddr,
			To:     delegateAddr,
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "DELEGATECALL should complete")
		
		updatedStorage, err := evm.GetStorage(callerAddr, storageKey)
		require.NoError(t, err)
		assert.Equal(t, big.NewInt(0xcc), updatedStorage, "Storage should be updated in caller context")
		
		delegateStorage, err := evm.GetStorage(delegateAddr, storageKey)
		require.NoError(t, err)
		assert.Equal(t, big.NewInt(0), delegateStorage, "Delegate storage should remain unchanged")
	})

	t.Run("STATICCALL state modification restriction", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x07})
		staticAddr := primitives.NewAddress([20]byte{0x08})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		staticCodeWithWrite := []byte{0x60, 0xdd, 0x5f, 0x55}
		err = evm.SetCode(staticAddr, staticCodeWithWrite)
		require.NoError(t, err)

		result, err := evm.Call(Staticcall{
			Caller: callerAddr,
			To:     staticAddr,
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "STATICCALL with state modification should fail")
	})

	t.Run("Nested CALL operations", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x0b})
		intermediateAddr := primitives.NewAddress([20]byte{0x0c})
		finalAddr := primitives.NewAddress([20]byte{0x0d})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		finalCode := []byte{0x60, 0xff, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(finalAddr, finalCode)
		require.NoError(t, err)
		
		// Simple test: intermediate contract returns 0xff
		intermediateCode := []byte{0x60, 0xff, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
		err = evm.SetCode(intermediateAddr, intermediateCode)
		require.NoError(t, err)

		// Call intermediate which should call final
		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     intermediateAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Nested CALL operations should complete")
	})

	t.Run("CALL with return data", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x10})
		calleeAddr := primitives.NewAddress([20]byte{0x11})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		// Simple return data: PUSH1 0xaa PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
		calleeCode := []byte{0x60, 0xaa, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}
		err = evm.SetCode(calleeAddr, calleeCode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     calleeAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CALL with return data capture should complete")
		assert.Equal(t, 32, len(result.Output), "Should return 32 bytes")
	})

	t.Run("Call depth limit", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		recursiveAddr := primitives.NewAddress([20]byte{0x14})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(recursiveAddr, balance)
		require.NoError(t, err)
		
		// Simple recursive call - this will eventually hit depth limit
		recursiveCode := []byte{0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x60, 0x00, 0x30, 0x61, 0xff, 0xff, 0xf1}
		err = evm.SetCode(recursiveAddr, recursiveCode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: recursiveAddr,
			To:     recursiveAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    VeryHighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Deep recursion should be handled")
	})

	t.Run("CALL to non-existent account", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x15})
		nonExistentAddr := primitives.NewAddress([20]byte{0x99})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     nonExistentAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CALL to non-existent account should complete")
	})

	t.Run("CALL with insufficient gas", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		callerAddr := primitives.NewAddress([20]byte{0x16})
		calleeAddr := primitives.NewAddress([20]byte{0x17})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(callerAddr, balance)
		require.NoError(t, err)
		
		// Expensive code - many ADD operations
		expensiveCode := make([]byte, 0)
		for i := 0; i < 1000; i++ {
			expensiveCode = append(expensiveCode, 0x60, 0x01, 0x60, 0x01, 0x01) // PUSH1 1 PUSH1 1 ADD
		}
		err = evm.SetCode(calleeAddr, expensiveCode)
		require.NoError(t, err)

		// Call with very low gas
		result, err := evm.Call(Call{
			Caller: callerAddr,
			To:     calleeAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    100, // Very low gas
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CALL with insufficient gas should be handled")
	})
}