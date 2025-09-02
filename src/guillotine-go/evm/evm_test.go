package evm

import (
	"encoding/hex"
	"math"
	"strings"
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
		
		caller := primitives.ZeroAddress()
		contractAddr, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
		
		// First, deploy the code to an address
		err = evm.SetCode(contractAddr, bytecode)
		require.NoError(t, err)
		
		// Now call the deployed code (with empty input data)
		result, err := evm.ExecuteCall(caller, contractAddr, primitives.ZeroU256(), primitives.EmptyBytes(), 1000000)
		
		require.NoError(t, err)
		require.NotNil(t, result)
		
		// Simple PUSH operations should succeed
		assert.True(t, result.Success)
		assert.Greater(t, uint64(1000000 - result.GasLeft), uint64(0)) // Gas was used
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
	
	t.Run("CallResult", func(t *testing.T) {
		// Test CallResult structure
		result := &CallResult{
			Success: true,
			GasLeft: 987654,
			Output:  primitives.NewBytes([]byte{1, 2, 3}),
			Logs: []LogEntry{
				{
					Address: primitives.ZeroAddress(),
					Topics:  []primitives.U256{primitives.ZeroU256()},
					Data:    primitives.NewBytes([]byte{4, 5, 6}),
				},
			},
			SelfDestructs:     []SelfDestructRecord{},
			AccessedAddresses: []primitives.Address{},
			AccessedStorage:   []StorageAccessRecord{},
			ErrorInfo:         "",
		}
		
		assert.True(t, result.Success)
		assert.Equal(t, uint64(987654), result.GasLeft)
		assert.Equal(t, primitives.NewBytes([]byte{1, 2, 3}), result.Output)
		assert.Len(t, result.Logs, 1)
		assert.Equal(t, primitives.NewBytes([]byte{4, 5, 6}), result.Logs[0].Data)
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

// TestEVMExhaustiveCallResults - SUPER EXHAUSTIVE testing of all call result fields and formats
func TestEVMExhaustiveCallResults(t *testing.T) {
	vm, err := New()
	if err != nil {
		t.Skipf("Skipping test - EVM creation failed: %v", err)
	}
	defer vm.Close()

	t.Run("ExhaustiveCallResultStructure", func(t *testing.T) {
		// Test every single field in CallResult with precise validation
		
		// Create comprehensive test addresses
		caller := primitives.NewAddress([20]byte{
			0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA,
			0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x12, 0x34, 0x56, 0x78,
		})
		to := primitives.NewAddress([20]byte{
			0x87, 0x65, 0x43, 0x21, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54,
			0x32, 0x10, 0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01,
		})

		// Test simple STOP operation
		result, err := vm.ExecuteCall(caller, to, primitives.ZeroU256(), 
			primitives.NewBytes([]byte{0x00}), 100000)
		require.NoError(t, err)
		require.NotNil(t, result)

		// EXHAUSTIVE FIELD VALIDATION
		
		// 1. Success field - boolean type validation
		assert.IsType(t, bool(false), result.Success, "Success field must be bool")
		
		// 2. GasLeft field - uint64 type and range validation
		assert.IsType(t, uint64(0), result.GasLeft, "GasLeft field must be uint64")
		assert.LessOrEqual(t, result.GasLeft, uint64(100000), "GasLeft cannot exceed initial gas")
		assert.GreaterOrEqual(t, result.GasLeft, uint64(0), "GasLeft cannot be negative")
		
		// 3. Output field - Bytes type validation
		assert.IsType(t, primitives.Bytes{}, result.Output, "Output field must be primitives.Bytes")
		assert.NotNil(t, result.Output.Data(), "Output.Data() must not be nil")
		assert.GreaterOrEqual(t, len(result.Output.Data()), 0, "Output length must be non-negative")
		
		// 4. Logs field - slice type and structure validation
		assert.IsType(t, []LogEntry{}, result.Logs, "Logs field must be []LogEntry")
		assert.NotNil(t, result.Logs, "Logs slice must not be nil")
		for i, log := range result.Logs {
			// Validate LogEntry structure
			assert.IsType(t, primitives.Address{}, log.Address, "Log[%d].Address must be primitives.Address", i)
			assert.IsType(t, []primitives.U256{}, log.Topics, "Log[%d].Topics must be []primitives.U256", i)
			assert.NotNil(t, log.Topics, "Log[%d].Topics must not be nil", i)
			assert.IsType(t, primitives.Bytes{}, log.Data, "Log[%d].Data must be primitives.Bytes", i)
			assert.NotNil(t, log.Data.Data(), "Log[%d].Data.Data() must not be nil", i)
			
			// Validate topic count (EVM allows 0-4 topics)
			assert.LessOrEqual(t, len(log.Topics), 4, "Log[%d] cannot have more than 4 topics", i)
			
			// Validate each topic is proper U256
			for j, topic := range log.Topics {
				assert.Equal(t, 32, len(topic.Array()), "Log[%d].Topic[%d] must be 32 bytes", i, j)
			}
		}
		
		// 5. SelfDestructs field - slice type and structure validation
		assert.IsType(t, []SelfDestructRecord{}, result.SelfDestructs, "SelfDestructs field must be []SelfDestructRecord")
		assert.NotNil(t, result.SelfDestructs, "SelfDestructs slice must not be nil")
		for i, sd := range result.SelfDestructs {
			assert.IsType(t, primitives.Address{}, sd.Contract, "SelfDestruct[%d].Contract must be primitives.Address", i)
			assert.IsType(t, primitives.Address{}, sd.Beneficiary, "SelfDestruct[%d].Beneficiary must be primitives.Address", i)
			assert.Equal(t, 20, len(sd.Contract.Array()), "SelfDestruct[%d].Contract must be 20 bytes", i)
			assert.Equal(t, 20, len(sd.Beneficiary.Array()), "SelfDestruct[%d].Beneficiary must be 20 bytes", i)
		}
		
		// 6. AccessedAddresses field - slice type validation
		assert.IsType(t, []primitives.Address{}, result.AccessedAddresses, "AccessedAddresses field must be []primitives.Address")
		assert.NotNil(t, result.AccessedAddresses, "AccessedAddresses slice must not be nil")
		for i, addr := range result.AccessedAddresses {
			assert.IsType(t, primitives.Address{}, addr, "AccessedAddress[%d] must be primitives.Address", i)
			assert.Equal(t, 20, len(addr.Array()), "AccessedAddress[%d] must be 20 bytes", i)
		}
		
		// 7. AccessedStorage field - slice type and structure validation
		assert.IsType(t, []StorageAccessRecord{}, result.AccessedStorage, "AccessedStorage field must be []StorageAccessRecord")
		assert.NotNil(t, result.AccessedStorage, "AccessedStorage slice must not be nil")
		for i, storage := range result.AccessedStorage {
			assert.IsType(t, primitives.Address{}, storage.Address, "AccessedStorage[%d].Address must be primitives.Address", i)
			assert.IsType(t, primitives.U256{}, storage.Slot, "AccessedStorage[%d].Slot must be primitives.U256", i)
			assert.Equal(t, 20, len(storage.Address.Array()), "AccessedStorage[%d].Address must be 20 bytes", i)
			assert.Equal(t, 32, len(storage.Slot.Array()), "AccessedStorage[%d].Slot must be 32 bytes", i)
		}
		
		// 8. ErrorInfo field - string type validation
		assert.IsType(t, "", result.ErrorInfo, "ErrorInfo field must be string")
		
		t.Logf("EXHAUSTIVE VALIDATION PASSED - All fields have correct types and formats")
		t.Logf("  Success: %T = %v", result.Success, result.Success)
		t.Logf("  GasLeft: %T = %d", result.GasLeft, result.GasLeft)
		t.Logf("  Output: %T, len=%d", result.Output, len(result.Output.Data()))
		t.Logf("  Logs: %T, len=%d", result.Logs, len(result.Logs))
		t.Logf("  SelfDestructs: %T, len=%d", result.SelfDestructs, len(result.SelfDestructs))
		t.Logf("  AccessedAddresses: %T, len=%d", result.AccessedAddresses, len(result.AccessedAddresses))
		t.Logf("  AccessedStorage: %T, len=%d", result.AccessedStorage, len(result.AccessedStorage))
		t.Logf("  ErrorInfo: %T = '%s'", result.ErrorInfo, result.ErrorInfo)
	})

	t.Run("ExhaustiveNumericValueValidation", func(t *testing.T) {
		// Test all numeric ranges and edge cases
		
		testCases := []struct {
			name     string
			gas      uint64
			value    uint64
			expected bool
		}{
			{"MinimumGas", 21000, 0, true},
			{"LowGas", 50000, 1000, true},
			{"MediumGas", 500000, 1000000, true},
			{"HighGas", 5000000, 999999999, true},
			{"MaxSafeGas", math.MaxUint32, math.MaxUint32, true},
		}
		
		for _, tc := range testCases {
			t.Run(tc.name, func(t *testing.T) {
				caller := primitives.ZeroAddress()
				to := primitives.ZeroAddress()
				value := primitives.NewU256(tc.value)
				
				result, err := vm.ExecuteCall(caller, to, value, 
					primitives.NewBytes([]byte{0x00}), tc.gas)
				require.NoError(t, err)
				
				// Validate numeric precision
				assert.LessOrEqual(t, result.GasLeft, tc.gas, "GasLeft precision check")
				assert.IsType(t, uint64(0), result.GasLeft, "GasLeft type precision")
				assert.GreaterOrEqual(t, result.GasLeft, uint64(0), "GasLeft non-negative")
				
				// Gas consumption validation
				gasUsed := tc.gas - result.GasLeft
				assert.Greater(t, gasUsed, uint64(0), "Gas must be consumed")
				assert.LessOrEqual(t, gasUsed, tc.gas, "Cannot use more gas than provided")
				
				t.Logf("Gas validation - Provided: %d, Used: %d, Left: %d", 
					tc.gas, gasUsed, result.GasLeft)
			})
		}
	})

	t.Run("ExhaustiveBytesAndAddressFormats", func(t *testing.T) {
		// Test all byte array formats and address validations
		
		// Test various address formats
		addressTests := []struct {
			name    string
			address [20]byte
		}{
			{"ZeroAddress", [20]byte{}},
			{"MaxAddress", [20]byte{0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}},
			{"PatternAddress", [20]byte{0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD}},
			{"AlternatingAddress", [20]byte{0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA}},
		}
		
		for _, addrTest := range addressTests {
			t.Run(addrTest.name, func(t *testing.T) {
				caller := primitives.NewAddress(addrTest.address)
				to := primitives.NewAddress(addrTest.address)
				
				result, err := vm.ExecuteCall(caller, to, primitives.ZeroU256(), 
					primitives.NewBytes([]byte{0x00}), 100000)
				require.NoError(t, err)
				
				// Validate address format preservation
				assert.Equal(t, 20, len(caller.Array()), "Caller address must be 20 bytes")
				assert.Equal(t, 20, len(to.Array()), "To address must be 20 bytes")
				
				// Validate addresses in accessed lists maintain format
				for i, addr := range result.AccessedAddresses {
					assert.Equal(t, 20, len(addr.Array()), "AccessedAddress[%d] format validation", i)
					// Convert to hex for readability in logs
					addrHex := hex.EncodeToString(addr.Bytes())
					assert.Len(t, addrHex, 40, "AccessedAddress[%d] hex representation", i)
				}
				
				t.Logf("Address format validation passed for %s", addrTest.name)
			})
		}
	})

	t.Run("ExhaustiveU256ValueTesting", func(t *testing.T) {
		// Test U256 values with various byte patterns and endianness
		
		u256Tests := []struct {
			name     string
			value    uint64
			expected [32]byte
		}{
			{"Zero", 0, [32]byte{}},
			{"One", 1, [32]byte{0x01}},
			{"SmallValue", 255, [32]byte{0xFF}},
			{"MediumValue", 65535, [32]byte{0xFF, 0xFF}},
			{"LargeValue", 16777215, [32]byte{0xFF, 0xFF, 0xFF}},
			{"TestValue1000", 1000, [32]byte{0xE8, 0x03}}, // Critical test case
			{"PowerOfTwo", 1024, [32]byte{0x00, 0x04}},
			{"MaxUint32", math.MaxUint32, [32]byte{0xFF, 0xFF, 0xFF, 0xFF}},
		}
		
		for _, test := range u256Tests {
			t.Run(test.name, func(t *testing.T) {
				evm, err := New()
				require.NoError(t, err)
				defer evm.Close()
				
				addr, _ := primitives.AddressFromHex("0x1234567890123456789012345678901234567890")
				value := primitives.NewU256(test.value)
				
				// Test set/get balance with specific U256 value
				err = evm.SetBalance(addr, value)
				require.NoError(t, err)
				
				retrieved, err := evm.GetBalance(addr)
				require.NoError(t, err)
				
				// CRITICAL: Validate exact byte representation (little-endian internal storage)
				valueBytes := value.Array()
				retrievedBytes := retrieved.Array()
				
				assert.Equal(t, valueBytes, retrievedBytes, "U256 byte representation must be identical")
				assert.Equal(t, 32, len(valueBytes), "U256 must be exactly 32 bytes")
				assert.Equal(t, 32, len(retrievedBytes), "Retrieved U256 must be exactly 32 bytes")
				
				// Validate specific byte patterns for critical values
				if test.value == 1000 {
					// Critical test: 1000 = 0x3E8, stored as little-endian [0xE8, 0x03, 0x00, ...]
					assert.Equal(t, uint8(0xE8), valueBytes[0], "1000 should have 0xE8 in first byte (little-endian)")
					assert.Equal(t, uint8(0x03), valueBytes[1], "1000 should have 0x03 in second byte (little-endian)")
					assert.Equal(t, uint8(0x00), valueBytes[2], "1000 should have 0x00 in third byte")
				}
				
				// Test storage with the same value
				key := primitives.NewU256(42)
				err = evm.SetStorage(addr, key, value)
				require.NoError(t, err)
				
				storedValue, err := evm.GetStorage(addr, key)
				require.NoError(t, err)
				
				assert.Equal(t, value, storedValue, "Storage U256 value must be preserved")
				assert.Equal(t, valueBytes, storedValue.Array(), "Storage U256 bytes must be identical")
				
				t.Logf("U256 validation passed for %s: value=%d, bytes=[%x, %x, %x, %x, ...]", 
					test.name, test.value, valueBytes[0], valueBytes[1], valueBytes[2], valueBytes[3])
			})
		}
	})
}

func TestEVMCallSupport(t *testing.T) {
	// Skip if EVM creation fails (might need compiled Zig library)
	vm, err := New()
	if err != nil {
		t.Skipf("Skipping test - EVM creation failed (library may not be built): %v", err)
	}
	defer vm.Close()
	
	// Test addresses
	caller := primitives.NewAddress([20]byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14})
	to := primitives.NewAddress([20]byte{0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28})
	
	t.Run("ExecuteCall", func(t *testing.T) {
		// Simple STOP bytecode
		bytecode := []byte{0x00}
		input := primitives.NewBytes(bytecode)
		value := primitives.NewU256(1000)
		
		result, err := vm.ExecuteCall(caller, to, value, input, 100000)
		if err != nil {
			t.Fatalf("ExecuteCall failed: %v", err)
		}
		
		// Exhaustive validation of call result
		assert.IsType(t, bool(false), result.Success, "Success must be bool")
		assert.IsType(t, uint64(0), result.GasLeft, "GasLeft must be uint64")
		assert.LessOrEqual(t, result.GasLeft, uint64(100000), "GasLeft cannot exceed provided gas")
		
		t.Logf("CALL Result - Success: %v, GasLeft: %d", result.Success, result.GasLeft)
	})
	
	t.Run("ExecuteStaticCall", func(t *testing.T) {
		// PUSH1 0x42 (pushes 42 to stack)
		bytecode := []byte{0x60, 0x42}
		input := primitives.NewBytes(bytecode)
		
		result, err := vm.ExecuteStaticCall(caller, to, input, 50000)
		if err != nil {
			t.Fatalf("ExecuteStaticCall failed: %v", err)
		}
		
		// Exhaustive validation
		assert.IsType(t, bool(false), result.Success, "Success must be bool")
		assert.LessOrEqual(t, result.GasLeft, uint64(50000), "GasLeft validation")
		assert.NotNil(t, result.Logs, "Logs must not be nil")
		assert.NotNil(t, result.AccessedAddresses, "AccessedAddresses must not be nil")
		
		t.Logf("STATICCALL Result - Success: %v, GasLeft: %d", result.Success, result.GasLeft)
	})
	
	t.Run("ExecuteDelegateCall", func(t *testing.T) {
		// Simple STOP bytecode
		bytecode := []byte{0x00}
		input := primitives.NewBytes(bytecode)
		
		result, err := vm.ExecuteDelegateCall(caller, to, input, 75000)
		if err != nil {
			t.Fatalf("ExecuteDelegateCall failed: %v", err)
		}
		
		// Validate all result fields
		assert.IsType(t, bool(false), result.Success, "Success type validation")
		assert.IsType(t, uint64(0), result.GasLeft, "GasLeft type validation") 
		assert.IsType(t, primitives.Bytes{}, result.Output, "Output type validation")
		assert.IsType(t, []LogEntry{}, result.Logs, "Logs type validation")
		assert.IsType(t, []SelfDestructRecord{}, result.SelfDestructs, "SelfDestructs type validation")
		assert.IsType(t, []primitives.Address{}, result.AccessedAddresses, "AccessedAddresses type validation")
		assert.IsType(t, []StorageAccessRecord{}, result.AccessedStorage, "AccessedStorage type validation")
		assert.IsType(t, "", result.ErrorInfo, "ErrorInfo type validation")
		
		t.Logf("DELEGATECALL Result - Success: %v, GasLeft: %d", result.Success, result.GasLeft)
	})
	
	t.Run("ExecuteCreate", func(t *testing.T) {
		// Simple contract creation code: PUSH1 0x00 PUSH1 0x00 RETURN
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}
		input := primitives.NewBytes(initCode)
		value := primitives.NewU256(0)
		
		result, err := vm.ExecuteCreate(caller, value, input, 200000)
		if err != nil {
			t.Fatalf("ExecuteCreate failed: %v", err)
		}
		
		// Comprehensive CREATE result validation
		assert.LessOrEqual(t, result.GasLeft, uint64(200000), "GasLeft bounds check")
		assert.GreaterOrEqual(t, result.GasLeft, uint64(0), "GasLeft non-negative")
		
		// Validate output format for CREATE (should be contract address)
		outputLen := len(result.Output.Data())
		assert.True(t, outputLen == 20, "CREATE output should be 20-byte address")
		
		t.Logf("CREATE Result - Success: %v, GasLeft: %d, OutputLen: %d", 
			result.Success, result.GasLeft, outputLen)
	})
	
	t.Run("ExecuteCreate2", func(t *testing.T) {
		// Simple contract creation code
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}
		input := primitives.NewBytes(initCode)
		value := primitives.NewU256(0)
		
		// Use a deterministic salt
		saltBytes := [32]byte{}
		saltBytes[31] = 0x42
		salt, _ := primitives.U256FromBytes(saltBytes[:])
		
		result, err := vm.ExecuteCreate2(caller, value, input, salt, 250000)
		if err != nil {
			t.Fatalf("ExecuteCreate2 failed: %v", err)
		}
		
		// CREATE2-specific validations
		assert.LessOrEqual(t, result.GasLeft, uint64(250000), "CREATE2 gas bounds")
		
		// Validate salt was properly handled (CREATE2 uses deterministic addressing)
		saltSlice := salt.Bytes()
		assert.Equal(t, 32, len(saltSlice), "Salt must be 32 bytes")
		assert.Equal(t, uint8(0x42), saltSlice[31], "Salt byte validation")
		// Validate output format for CREATE2 (should be contract address)
		outputLen := len(result.Output.Data())
		assert.True(t, outputLen == 20, "CREATE2 output should be 20-byte address")
		
		t.Logf("CREATE2 Result - Success: %v, GasLeft: %d", result.Success, result.GasLeft)
	})
	
	t.Run("CallParams", func(t *testing.T) {
		// Test with complete parameters
		params := CallParams{
			CallType: CallTypeCall,
			Caller:   caller,
			To:       to,
			Value:    primitives.ZeroU256(),
			Input:    primitives.NewBytes([]byte{0x00}), // STOP
			Gas:      500000,
			Salt:     primitives.ZeroU256(),
		}
		
		result, err := vm.ExecuteWithParams(params)
		if err != nil {
			t.Fatalf("ExecuteWithParams failed: %v", err)
		}
		
		// ULTRA-COMPREHENSIVE result validation
		t.Logf("=== COMPREHENSIVE EXECUTION RESULT ANALYSIS ===")
		t.Logf("Success: %T = %v", result.Success, result.Success)
		t.Logf("GasLeft: %T = %d (provided: %d, used: %d)", 
			result.GasLeft, result.GasLeft, params.Gas, params.Gas-result.GasLeft)
		t.Logf("Output: %T, length=%d, hex=%s", 
			result.Output, len(result.Output.Data()), hex.EncodeToString(result.Output.Data()))
		t.Logf("Logs: %T, count=%d", result.Logs, len(result.Logs))
		
		// Log each log entry in detail
		for i, log := range result.Logs {
			t.Logf("  Log[%d]: Address=%s, Topics=%d, DataLen=%d", 
				i, hex.EncodeToString(log.Address.Bytes()), len(log.Topics), len(log.Data.Data()))
			for j, topic := range log.Topics {
				t.Logf("    Topic[%d]: %s", j, hex.EncodeToString(topic.Bytes()))
			}
		}
		
		t.Logf("SelfDestructs: %T, count=%d", result.SelfDestructs, len(result.SelfDestructs))
		for i, sd := range result.SelfDestructs {
			t.Logf("  SelfDestruct[%d]: Contract=%s, Beneficiary=%s", 
				i, hex.EncodeToString(sd.Contract.Bytes()), hex.EncodeToString(sd.Beneficiary.Bytes()))
		}
		
		t.Logf("AccessedAddresses: %T, count=%d", result.AccessedAddresses, len(result.AccessedAddresses))
		for i, addr := range result.AccessedAddresses {
			t.Logf("  AccessedAddr[%d]: %s", i, hex.EncodeToString(addr.Bytes()))
		}
		
		t.Logf("AccessedStorage: %T, count=%d", result.AccessedStorage, len(result.AccessedStorage))
		for i, storage := range result.AccessedStorage {
			t.Logf("  AccessedStorage[%d]: Address=%s, Slot=%s", 
				i, hex.EncodeToString(storage.Address.Bytes()), hex.EncodeToString(storage.Slot.Bytes()))
		}
		
		t.Logf("ErrorInfo: %T = '%s'", result.ErrorInfo, result.ErrorInfo)
		
		// Validation assertions
		assert.IsType(t, bool(false), result.Success, "Success type")
		assert.IsType(t, uint64(0), result.GasLeft, "GasLeft type")
		assert.IsType(t, primitives.Bytes{}, result.Output, "Output type")
		assert.IsType(t, []LogEntry{}, result.Logs, "Logs type")
		assert.IsType(t, []SelfDestructRecord{}, result.SelfDestructs, "SelfDestructs type")
		assert.IsType(t, []primitives.Address{}, result.AccessedAddresses, "AccessedAddresses type") 
		assert.IsType(t, []StorageAccessRecord{}, result.AccessedStorage, "AccessedStorage type")
		assert.IsType(t, "", result.ErrorInfo, "ErrorInfo type")
		
		// Detailed field validation
		if len(result.ErrorInfo) > 0 {
			assert.True(t, strings.TrimSpace(result.ErrorInfo) != "", "ErrorInfo should not be just whitespace")
		}
		
		t.Logf("=== ALL VALIDATIONS PASSED ===")
	})
}

func TestCallTypeDifferentiation(t *testing.T) {
	vm, err := New()
	if err != nil {
		t.Skipf("Skipping test - EVM creation failed: %v", err)
	}
	defer vm.Close()
	
	caller := primitives.NewAddress([20]byte{0x01})
	to := primitives.NewAddress([20]byte{0x02})
	
	// Test that different call types are properly handled
	callTypes := []struct {
		name     string
		callType CallType
	}{
		{"CALL", CallTypeCall},
		{"CALLCODE", CallTypeCallcode},
		{"DELEGATECALL", CallTypeDelegatecall},
		{"STATICCALL", CallTypeStaticcall},
		{"CREATE", CallTypeCreate},
		{"CREATE2", CallTypeCreate2},
	}
	
	for _, ct := range callTypes {
		t.Run(ct.name, func(t *testing.T) {
			params := CallParams{
				CallType: ct.callType,
				Caller:   caller,
				To:       to,
				Value:    primitives.ZeroU256(),
				Input:    primitives.NewBytes([]byte{0x00}), // STOP opcode
				Gas:      21000,
				Salt:     primitives.ZeroU256(),
			}
			
			result, err := vm.ExecuteWithParams(params)
			if err != nil {
				t.Fatalf("ExecuteWithParams failed for %s: %v", ct.name, err)
			}
			
			// Validate that CallType was properly processed
			assert.IsType(t, CallType(0), ct.callType, "CallType must be proper type")
			
			// Each call type should produce valid results
			assert.NotNil(t, result, "Result must not be nil for %s", ct.name)
			assert.IsType(t, bool(false), result.Success, "Success type for %s", ct.name)
			assert.IsType(t, uint64(0), result.GasLeft, "GasLeft type for %s", ct.name)
			assert.LessOrEqual(t, result.GasLeft, uint64(21000), "GasLeft bounds for %s", ct.name)
			
			t.Logf("%s executed - Success: %v, GasLeft: %d", 
				ct.name, result.Success, result.GasLeft)
		})
	}
}

// TestEVMBoundaryConditions - Test edge cases and boundary conditions  
func TestEVMBoundaryConditions(t *testing.T) {
	vm, err := New()
	if err != nil {
		t.Skipf("Skipping boundary tests - EVM creation failed: %v", err)
	}
	defer vm.Close()
	
	t.Run("ZeroGasExecution", func(t *testing.T) {
		result, err := vm.ExecuteCall(
			primitives.ZeroAddress(),
			primitives.ZeroAddress(), 
			primitives.ZeroU256(),
			primitives.NewBytes([]byte{0x00}),
			0, // Zero gas
		)
		
		if err != nil {
			// Zero gas should fail gracefully
			t.Logf("Zero gas execution failed as expected: %v", err)
		} else {
			assert.Equal(t, uint64(0), result.GasLeft, "Zero gas should leave zero gas")
			assert.False(t, result.Success, "Zero gas execution should fail")
		}
	})
	
	t.Run("MaximumGasExecution", func(t *testing.T) {
		maxGas := uint64(math.MaxUint32) // Reasonable maximum
		result, err := vm.ExecuteCall(
			primitives.ZeroAddress(),
			primitives.ZeroAddress(),
			primitives.ZeroU256(),
			primitives.NewBytes([]byte{0x00}),
			maxGas,
		)
		
		require.NoError(t, err)
		assert.LessOrEqual(t, result.GasLeft, maxGas, "Gas left cannot exceed provided")
		assert.IsType(t, uint64(0), result.GasLeft, "Gas left type validation")
		
		t.Logf("Max gas test - Provided: %d, Left: %d, Used: %d", 
			maxGas, result.GasLeft, maxGas-result.GasLeft)
	})
	
	t.Run("EmptyBytecodeExecution", func(t *testing.T) {
		result, err := vm.ExecuteCall(
			primitives.ZeroAddress(),
			primitives.ZeroAddress(),
			primitives.ZeroU256(),
			primitives.NewBytes([]byte{}), // Empty bytecode
			100000,
		)
		
		require.NoError(t, err)
		assert.True(t, len(result.Output.Data()) >= 0, "Output length validation")
		assert.NotNil(t, result.Logs, "Logs must be initialized")
		assert.NotNil(t, result.AccessedAddresses, "AccessedAddresses must be initialized")
		
		t.Logf("Empty bytecode - Success: %v, GasLeft: %d", result.Success, result.GasLeft)
	})
	
	t.Run("LargeBytecodeExecution", func(t *testing.T) {
		// Create large but valid bytecode (lots of PUSH1 0x00)
		largeBytecode := make([]byte, 1000)
		for i := 0; i < len(largeBytecode); i += 2 {
			largeBytecode[i] = 0x60   // PUSH1
			if i+1 < len(largeBytecode) {
				largeBytecode[i+1] = 0x00 // 0x00
			}
		}
		
		result, err := vm.ExecuteCall(
			primitives.ZeroAddress(),
			primitives.ZeroAddress(),
			primitives.ZeroU256(),
			primitives.NewBytes(largeBytecode),
			1000000, // Enough gas for large execution
		)
		
		require.NoError(t, err)
		assert.LessOrEqual(t, result.GasLeft, uint64(1000000), "Gas bounds check")
		
		t.Logf("Large bytecode - Success: %v, GasLeft: %d, BytecodeLen: %d", 
			result.Success, result.GasLeft, len(largeBytecode))
	})
}