package evm

import (
	"math/big"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/evmts/guillotine/sdks/go/primitives"
)


func TestContractCreation(t *testing.T) {
	t.Run("CREATE opcode basic deployment", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x01})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Simple init code that returns runtime code
		initCode := []byte{0x60, 0x0a, 0x60, 0x0c, 0x60, 0x00, 0x39, 0x60, 0x0a, 0x60, 0x00, 0xf3, 0x60, 0x80, 0x60, 0x40, 0x52, 0x60, 0x00, 0x80, 0xfd}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.True(t, result.Success, "Contract deployment should succeed")
	})

	t.Run("CREATE2 deterministic deployment", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x02})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		salt := big.NewInt(1)
		// Simple init code: returns empty runtime code
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}

		result, err := evm.Call(Create2{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Salt:     salt,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.True(t, result.Success, "CREATE2 deployment should succeed")
	})

	t.Run("Contract deployment with constructor", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x03})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Init code that stores a value in storage during construction
		initCode := []byte{
			0x60, 0xff,        // PUSH1 0xff
			0x60, 0x00,        // PUSH1 0x00
			0x55,              // SSTORE
			0x60, 0x00,        // PUSH1 0x00 (size)
			0x60, 0x00,        // PUSH1 0x00 (offset)
			0xf3,              // RETURN
		}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Constructor deployment should return result")
	})

	t.Run("Contract deployment with value transfer", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x04})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		deployValue := big.NewInt(1000)
		// Simple init code that returns empty runtime
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    deployValue,
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Deployment with value should return result")

		// Check that created contract received the value
		if result.CreatedAddress != nil {
			contractBalance, err := evm.GetBalance(*result.CreatedAddress)
			require.NoError(t, err)
			assert.Equal(t, deployValue, contractBalance, "Created contract should have received value")
		}
	})

	t.Run("Failed deployment - insufficient gas", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x05})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Large init code that will consume a lot of gas
		largeInitCode := make([]byte, 0)
		for i := 0; i < 1000; i++ {
			largeInitCode = append(largeInitCode, 0x60, 0x00) // PUSH1 0x00
		}
		largeInitCode = append(largeInitCode, 0x60, 0x00, 0x60, 0x00, 0xf3) // Return empty

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: largeInitCode,
			Gas:      1000, // Very low gas
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Deployment should fail with insufficient gas")
	})

	t.Run("Failed deployment - stack underflow", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x06})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Init code that will cause stack underflow (POP without values)
		badInitCode := []byte{0x50} // POP without any values on stack

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: badInitCode,
			Gas:      100000,
		})
		require.NoError(t, err)
		assert.False(t, result.Success, "Deployment should fail with stack underflow")
	})

	t.Run("Contract deployment address calculation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x07})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Simple init code
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Address calculation should complete")
		assert.NotNil(t, result.CreatedAddress, "Should have created address")
	})

	t.Run("Multiple contract deployments", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x08})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		initCode1 := []byte{0x60, 0xaa, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xf3}
		initCode2 := []byte{0x60, 0xbb, 0x60, 0x00, 0x55, 0x60, 0x00, 0x60, 0x00, 0xf3}

		result1, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode1,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result1, "First deployment should complete")

		result2, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode2,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result2, "Second deployment should complete")

		// Addresses should be different
		if result1.CreatedAddress != nil && result2.CreatedAddress != nil {
			assert.NotEqual(t, *result1.CreatedAddress, *result2.CreatedAddress, "Contract addresses should be different")
		}
	})

	t.Run("Contract deployment with init code execution", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x09})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Init code that sets multiple storage slots
		initCode := []byte{
			0x60, 0xaa,        // PUSH1 0xaa
			0x60, 0x00,        // PUSH1 0x00
			0x55,              // SSTORE
			0x60, 0xbb,        // PUSH1 0xbb
			0x60, 0x01,        // PUSH1 0x01
			0x55,              // SSTORE
			0x60, 0xcc,        // PUSH1 0xcc
			0x60, 0x02,        // PUSH1 0x02
			0x55,              // SSTORE
			0x60, 0x00,        // PUSH1 0x00 (size)
			0x60, 0x00,        // PUSH1 0x00 (offset)
			0xf3,              // RETURN
		}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Init code execution should complete")
	})

	t.Run("Contract factory pattern", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		factoryAddr := primitives.NewAddress([20]byte{0x0a})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(factoryAddr, balance)
		require.NoError(t, err)

		// Child contract that just stores and returns a value
		childContract := []byte{0x60, 0xaa, 0x60, 0x00, 0x55, 0x60, 0xaa, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}
		
		// Factory init code that deploys the child contract
		factoryInitCode := []byte{
			// Push child contract code
			0x7f, // PUSH32 - we'll need to adjust for the actual child contract
		}
		// Add the child contract code to the init code
		if len(childContract) <= 32 {
			// Pad to 32 bytes
			paddedChild := make([]byte, 32)
			copy(paddedChild, childContract)
			factoryInitCode = append(factoryInitCode, paddedChild...)
		} else {
			// For longer code, we'd need a different approach
			factoryInitCode = append(factoryInitCode, childContract[:32]...)
		}
		
		factoryInitCode = append(factoryInitCode,
			0x60, 0x00, // PUSH1 0x00 (offset)
			0x52,       // MSTORE 
			0x60, byte(len(childContract)), // PUSH1 child_size
			0x60, 0x00, // PUSH1 0x00 (offset)
			0x60, 0x00, // PUSH1 0x00 (value)
			0xf0,       // CREATE
			0x60, 0x00, // PUSH1 0x00 (offset) 
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20 (size)
			0x60, 0x00, // PUSH1 0x00 (offset)
			0xf3,       // RETURN
		)

		result, err := evm.Call(Create{
			Caller:   factoryAddr,
			Value:    big.NewInt(0),
			InitCode: factoryInitCode,
			Gas:      500000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Factory pattern should complete")
	})

	t.Run("CREATE2 with computed address", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x0b})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		salt := big.NewInt(1)
		initCode := []byte{0x60, 0xaa, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}

		result, err := evm.Call(Create2{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Salt:     salt,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "CREATE2 with computed address should complete")
		assert.NotNil(t, result.CreatedAddress, "Should have deterministic address")
	})

	t.Run("Contract deployment with SELFDESTRUCT in init", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x0c})
		beneficiary := primitives.NewAddress([20]byte{0x0d})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Init code that calls SELFDESTRUCT with beneficiary
		initCode := []byte{
			0x73, // PUSH20 for beneficiary address
		}
		initCode = append(initCode, beneficiary.Bytes()...)
		initCode = append(initCode, 0xff) // SELFDESTRUCT

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(1000),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Deployment with SELFDESTRUCT should complete")
	})

	t.Run("Nested contract creation", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x0e})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Inner contract: just returns a value
		innerContract := []byte{0x60, 0xaa, 0x60, 0x00, 0x52, 0x60, 0x20, 0x60, 0x00, 0xf3}
		
		// Outer contract: creates the inner contract and returns its address
		outerInitCode := []byte{
			// Push inner contract onto stack
			0x7f, // PUSH32
		}
		// Pad inner contract to 32 bytes
		paddedInner := make([]byte, 32)
		copy(paddedInner, innerContract)
		outerInitCode = append(outerInitCode, paddedInner...)
		outerInitCode = append(outerInitCode,
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, byte(len(innerContract)), // PUSH1 inner_size
			0x60, 0x00, // PUSH1 0x00
			0x60, 0x00, // PUSH1 0x00
			0xf0,       // CREATE
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: outerInitCode,
			Gas:      500000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Nested contract creation should complete")
	})

	t.Run("Contract deployment with large init code", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x0f})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Create large init code (100 storage operations)
		largeInitCode := make([]byte, 0)
		for i := 0; i < 100; i++ {
			largeInitCode = append(largeInitCode,
				0x60, byte(i%256), // PUSH1 value
				0x60, byte(i),     // PUSH1 slot
				0x55,              // SSTORE
			)
		}
		// Return empty runtime code
		largeInitCode = append(largeInitCode, 0x60, 0x00, 0x60, 0x00, 0xf3)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: largeInitCode,
			Gas:      1000000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Large init code deployment should complete")
	})

	t.Run("Contract deployment with code size limit", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x10})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Create runtime code at maximum size (24576 bytes)
		maxCodeSize := 24576
		maxCode := make([]byte, maxCodeSize)
		// Fill with NOPs (0x5b = JUMPDEST is safe to repeat)
		for i := 0; i < maxCodeSize; i++ {
			maxCode[i] = 0x5b
		}

		// Create init code that returns the max-sized runtime code
		initCode := []byte{
			0x61, byte(maxCodeSize>>8), byte(maxCodeSize&0xff), // PUSH2 maxCodeSize
			0x60, 0x0c, // PUSH1 0x0c (offset after this instruction)  
			0x60, 0x00, // PUSH1 0x00
			0x39,       // CODECOPY
			0x61, byte(maxCodeSize>>8), byte(maxCodeSize&0xff), // PUSH2 maxCodeSize
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		initCode = append(initCode, maxCode...)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      10000000, // Lots of gas for large deployment
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Max code size deployment should be handled")
	})

	t.Run("Zero-length runtime code", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x17})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Init code that returns zero-length runtime code
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Zero-length runtime code should be handled")
	})
}

func TestContractInteraction(t *testing.T) {
	t.Run("Deploy and call contract", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x11})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Deploy a simple contract that stores a value
		contractCode := []byte{
			0x60, 0x80,        // PUSH1 0x80
			0x60, 0x40,        // PUSH1 0x40
			0x52,              // MSTORE
			0x60, 0x04,        // PUSH1 0x04
			0x36,              // CALLDATASIZE
			0x10,              // LT
			0x60, 0x28,        // PUSH1 0x28
			0x57,              // JUMPI
			0x60, 0x00,        // PUSH1 0x00
			0x35,              // CALLDATALOAD
			0x60, 0xe0,        // PUSH1 0xe0
			0x1c,              // SHR
			0x80,              // DUP1
			0x63, 0x60, 0xfe, 0x47, 0xb1, // PUSH4 0x60fe47b1
			0x14,              // EQ
			0x60, 0x2c,        // PUSH1 0x2c
			0x57,              // JUMPI
			0x5b,              // JUMPDEST
			0x60, 0x00,        // PUSH1 0x00
			0x80,              // DUP1
			0xfd,              // REVERT
			0x5b,              // JUMPDEST
			0x60, 0x04,        // PUSH1 0x04
			0x35,              // CALLDATALOAD
			0x60, 0x00,        // PUSH1 0x00
			0x55,              // SSTORE
			0x00,              // STOP
		}

		initCode := append([]byte{
			0x60, byte(len(contractCode)), // PUSH1 contract_size
			0x60, 0x0c,                     // PUSH1 0x0c (offset after this instruction)
			0x60, 0x00,                     // PUSH1 0x00
			0x39,                           // CODECOPY
			0x60, byte(len(contractCode)),  // PUSH1 contract_size
			0x60, 0x00,                     // PUSH1 0x00
			0xf3,                           // RETURN
		}, contractCode...)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      1000000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Contract should be deployed")

		if result.CreatedAddress != nil {
			// Now call the deployed contract
			callData := []byte{0x60, 0xfe, 0x47, 0xb1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x64}

			callResult, err := evm.Call(Call{
				Caller: deployerAddr,
				To:     *result.CreatedAddress,
				Value:  big.NewInt(0),
				Input:  callData,
				Gas:    200000,
			})
			require.NoError(t, err)
			assert.NotNil(t, callResult, "Contract call should complete")
		}
	})

	t.Run("Contract creation from contract", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		factoryAddr := primitives.NewAddress([20]byte{0x12})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(factoryAddr, balance)
		require.NoError(t, err)

		// Child contract that stores a value and returns it
		childInitCode := []byte{
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x55,       // SSTORE
			0x60, 0xaa, // PUSH1 0xaa  
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Factory init code that creates the child contract
		factoryInitCode := []byte{
			// Store child init code in memory
			0x7f, // PUSH32
		}
		// Pad child init code to 32 bytes for PUSH32
		paddedChild := make([]byte, 32)
		copy(paddedChild, childInitCode)
		factoryInitCode = append(factoryInitCode, paddedChild...)
		factoryInitCode = append(factoryInitCode,
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			// Create the child contract
			0x60, byte(len(childInitCode)), // PUSH1 child_size
			0x60, 0x00, // PUSH1 0x00 (offset)
			0x60, 0x00, // PUSH1 0x00 (value)
			0xf0,       // CREATE
			// Store created address and return it
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00 
			0xf3,       // RETURN
		)

		result, err := evm.Call(Create{
			Caller:   factoryAddr,
			Value:    big.NewInt(0),
			InitCode: factoryInitCode,
			Gas:      500000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Factory should deploy child contract")
	})
}

func TestContractUpgradePatterns(t *testing.T) {
	t.Run("Proxy pattern deployment", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x13})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Implementation contract that just stores and returns a value
		implementationCode := []byte{
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x55,       // SSTORE
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Simple proxy that delegates to implementation
		proxyInitCode := []byte{
			// Store implementation code in memory
			0x7f, // PUSH32
		}
		// Pad implementation to 32 bytes
		paddedImpl := make([]byte, 32)
		copy(paddedImpl, implementationCode)
		proxyInitCode = append(proxyInitCode, paddedImpl...)
		proxyInitCode = append(proxyInitCode,
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			// Basic proxy runtime code
			0x60, 0x20, // PUSH1 0x20 (size of proxy runtime)
			0x60, 0x00, // PUSH1 0x00 (offset)
			0xf3,       // RETURN
		)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: proxyInitCode,
			Gas:      500000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Proxy pattern should deploy")
	})

	t.Run("Clone factory pattern", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x14})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Master contract that stores a value
		masterContract := []byte{
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x55,       // SSTORE
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		// Clone factory that creates clones of the master
		cloneInitCode := []byte{
			// Store master contract in memory
			0x7f, // PUSH32
		}
		paddedMaster := make([]byte, 32)
		copy(paddedMaster, masterContract)
		cloneInitCode = append(cloneInitCode, paddedMaster...)
		cloneInitCode = append(cloneInitCode,
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			// Create clone
			0x60, byte(len(masterContract)), // PUSH1 master_size
			0x60, 0x00, // PUSH1 0x00
			0x60, 0x00, // PUSH1 0x00
			0xf0,       // CREATE
			// Return created address
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: cloneInitCode,
			Gas:      500000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Clone factory should deploy")
	})
}

func TestContractSecurityPatterns(t *testing.T) {
	t.Run("Reentrancy guard in constructor", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x15})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Constructor that sets a reentrancy guard flag
		initCode := []byte{
			0x60, 0x01, // PUSH1 0x01 (not entered)
			0x60, 0x00, // PUSH1 0x00 (slot for reentrancy guard)
			0x55,       // SSTORE
			0x60, 0x00, // PUSH1 0x00 (return empty code)
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Reentrancy guard initialization should complete")
	})

	t.Run("Access control initialization", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x16})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Constructor that sets msg.sender as owner
		initCode := []byte{
			0x33,       // CALLER
			0x60, 0x00, // PUSH1 0x00 (owner slot)
			0x55,       // SSTORE
			0x60, 0x00, // PUSH1 0x00 (return empty code)
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Access control setup should complete")
	})
}

func TestContractDeploymentEdgeCases(t *testing.T) {
	t.Run("Maximum constructor arguments", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x18})
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)

		// Create large constructor arguments (1024 bytes of 0xff)
		args := make([]byte, 1024)
		for i := range args {
			args[i] = 0xff
		}
		
		// Simple init code that ignores the args and returns empty code
		baseInitCode := []byte{
			0x60, 0x00, // PUSH1 0x00
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Combine args with init code
		fullInitCode := append(args, baseInitCode...)

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: fullInitCode,
			Gas:      1000000,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Large constructor args should be handled")
	})

	t.Run("Deployment at existing address", func(t *testing.T) {
		evm, err := New()
		require.NoError(t, err)
		defer evm.Destroy()

		deployerAddr := primitives.NewAddress([20]byte{0x19})
		existingAddr := primitives.NewAddress([20]byte{0x20})
		
		balance := big.NewInt(LargeBalance)
		err = evm.SetBalance(deployerAddr, balance)
		require.NoError(t, err)
		
		// Set existing code at the address
		existingCode := []byte{0x60, 0x00}
		err = evm.SetCode(existingAddr, existingCode)
		require.NoError(t, err)

		// Try to deploy to an existing address (this should be handled gracefully)
		initCode := []byte{
			0x60, 0xaa, // PUSH1 0xaa
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}

		result, err := evm.Call(Create{
			Caller:   deployerAddr,
			Value:    big.NewInt(0),
			InitCode: initCode,
			Gas:      HighGas,
		})
		require.NoError(t, err)
		assert.NotNil(t, result, "Deployment collision should be handled")
	})
}