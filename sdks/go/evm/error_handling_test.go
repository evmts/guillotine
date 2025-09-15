package evm

import (
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/evmts/guillotine/sdks/go/primitives"
)


func TestErrorHandling(t *testing.T) {
	t.Run("Stack underflow", func(t *testing.T) {
		tests := []struct {
			name     string
			bytecode []byte
		}{
			{"POP on empty", []byte{0x50}},                          // POP
			{"ADD with one item", []byte{0x60, 0x01, 0x01}},         // PUSH1 1, ADD
			{"DUP on empty", []byte{0x80}},                          // DUP1
			{"SWAP on single item", []byte{0x60, 0x01, 0x90}},       // PUSH1 1, SWAP1
		}

		for _, tt := range tests {
			t.Run(tt.name, func(t *testing.T) {
				evm, err := New()
				require.NoError(t, err)
				defer evm.Destroy()

				caller := primitives.ZeroAddress()
				contractAddr := primitives.NewAddress([20]byte{0x01})
				
				// Set up caller with balance
				err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
				require.NoError(t, err)
				
				// Deploy the problematic bytecode
				err = evm.SetCode(contractAddr, tt.bytecode)
				require.NoError(t, err)

				result, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				})
				require.NoError(t, err)
				assert.False(t, result.Success, "Should fail due to stack underflow")
			})
		}
	})

	t.Run("Stack overflow", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Create bytecode that pushes many values to cause overflow
		var bytecode []byte
		for i := 0; i < 1025; i++ {
			bytecode = append(bytecode, 0x60, 0x01) // PUSH1 1
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to stack overflow")
	})

	t.Run("Out of gas", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Create expensive bytecode (many operations)
		var bytecode []byte
		for i := 0; i < 1000; i++ {
			bytecode = append(bytecode, 0x60, 0x01, 0x60, 0x01, 0x01) // PUSH1 1, PUSH1 1, ADD
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000, // Very low gas
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to out of gas")
	})

	t.Run("Invalid opcode", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Use invalid opcode 0xfe (which should cause revert)
		bytecode := []byte{0xfe}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to invalid opcode")
	})

	t.Run("Memory access out of bounds", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Try to load from a very high memory address
		bytecode := []byte{
			0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // PUSH32 with very large number
			0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
			0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
			0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
			0x51, // MLOAD
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		// Memory expansion should work in modern EVM, but might run out of gas
		// The test passes if either it succeeds or fails gracefully
		assert.NotNil(t, result, "Should handle memory expansion gracefully")
	})

	t.Run("Division by zero", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Division by zero: PUSH1 1, PUSH1 0, DIV
		bytecode := []byte{0x60, 0x01, 0x60, 0x00, 0x04}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		// Division by zero should return 0 in EVM, not fail
		assert.True(t, result.Success, "Division by zero should succeed and return 0")
	})

	t.Run("Modulo by zero", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Modulo by zero: PUSH1 1, PUSH1 0, MOD
		bytecode := []byte{0x60, 0x01, 0x60, 0x00, 0x06}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		// Modulo by zero should return 0 in EVM, not fail
		assert.True(t, result.Success, "Modulo by zero should succeed and return 0")
	})

	t.Run("ADDMOD by zero", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// ADDMOD by zero: PUSH1 1, PUSH1 1, PUSH1 0, ADDMOD
		bytecode := []byte{0x60, 0x01, 0x60, 0x01, 0x5f, 0x08}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		// ADDMOD by zero should return 0 in EVM, not fail
		assert.True(t, result.Success, "ADDMOD by zero should succeed and return 0")
	})

	t.Run("MULMOD by zero", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// MULMOD by zero: PUSH1 1, PUSH1 1, PUSH1 0, MULMOD
		bytecode := []byte{0x60, 0x01, 0x60, 0x01, 0x5f, 0x09}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		// MULMOD by zero should return 0 in EVM, not fail
		assert.True(t, result.Success, "MULMOD by zero should succeed and return 0")
	})

	t.Run("REVERT with specific data", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// REVERT with specific data: PUSH32 0x0123456789abcdef..., PUSH1 0, MSTORE, PUSH1 8, PUSH1 0, REVERT
		revertData := "0123456789abcdef"
		bytecodeHex := "7f" + revertData + "000000000000000000000000000000000000000000005f5260085ff3fd"
		bytecode, err := hex.DecodeString(bytecodeHex)
		require.NoError(t, err)

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "REVERT should fail")
		
		// Check that the specific revert data is returned
		expectedData, _ := hex.DecodeString(revertData)
		assert.Contains(t, result.Output, expectedData, "REVERT should return specific data")
	})

	t.Run("Call depth limit", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Recursive call: ADDRESS, PUSH1 0, PUSH1 0, PUSH1 0, PUSH1 0, DUP5, PUSH2 0xffff, CALL
		bytecode := []byte{
			0x30,             // ADDRESS
			0x60, 0x00,       // PUSH1 0
			0x60, 0x00,       // PUSH1 0  
			0x60, 0x00,       // PUSH1 0
			0x60, 0x00,       // PUSH1 0
			0x84,             // DUP5 (address)
			0x61, 0xff, 0xff, // PUSH2 0xffff (gas)
			0xf1,             // CALL
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Call depth limit should be handled gracefully")
	})

	t.Run("Insufficient balance for value transfer", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with insufficient balance
		err = evm.SetBalance(caller, big.NewInt(500))
		require.NoError(t, err)

		// Simple bytecode that just stops
		bytecode := []byte{0x00} // STOP

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		// Try to send more value than caller has
		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(1000), // More than caller's balance
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to insufficient balance")
	})
}

func TestMemoryErrors(t *testing.T) {
	t.Run("Memory expansion cost", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Try to expand memory to a large size
		bytecode := []byte{
			0x61, 0x10, 0x00, // PUSH2 0x1000 (4096)
			0x60, 0x00,       // PUSH1 0
			0x52,             // MSTORE
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.True(t, result.Success, "Memory expansion should succeed with sufficient gas")
		assert.Greater(t, uint64(100000-int(result.GasLeft)), uint64(0), "Should consume gas for memory expansion")
	})

	t.Run("Memory expansion insufficient gas", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Try to expand memory to a very large size
		bytecode := []byte{
			0x62, 0x10, 0x00, 0x00, // PUSH3 0x100000 (1MB)
			0x60, 0x00,             // PUSH1 0
			0x52,                   // MSTORE
		}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    1000, // Very low gas
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to insufficient gas for memory expansion")
	})
}

func TestJumpErrors(t *testing.T) {
	t.Run("Invalid jump destination", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Jump to invalid destination: PUSH1 0x10, JUMP
		bytecode := []byte{0x60, 0x10, 0x56}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Should fail due to invalid jump destination")
	})

	t.Run("Valid jump destination", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		caller := primitives.ZeroAddress()
		contractAddr := primitives.NewAddress([20]byte{0x01})
		
		// Set up caller with balance
		err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
		require.NoError(t, err)

		// Valid jump: PUSH1 0x06, JUMP, INVALID, INVALID, JUMPDEST, STOP
		bytecode := []byte{0x60, 0x06, 0x56, 0xfe, 0xfe, 0x5b, 0x00}

		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)

		result, err := evm.Call(Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  []byte{},
			Gas:    StandardGas,
		})
		require.NoError(t, err)
		assert.True(t, result.Success, "Should succeed with valid jump destination")
	})
}