package main

import (
	"encoding/hex"
	"testing"
	
	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

func TestEVMExecutionFullCallSupport(t *testing.T) {
	// Initialize EVM
	vm, err := evm.New()
	if err != nil {
		t.Fatalf("Failed to create EVM: %v", err)
	}
	defer vm.Close()
	
	// Test addresses
	caller := primitives.NewAddress([20]byte{0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13, 0x14})
	contractAddr := primitives.NewAddress([20]byte{0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28})
	
	// Set up caller account with balance
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		t.Fatalf("Failed to set caller balance: %v", err)
	}
	
	t.Run("CALL operation", func(t *testing.T) {
		// Deploy a simple contract that adds two numbers and returns the result
		// Contract bytecode: PUSH1 0x05 PUSH1 0x03 ADD PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
		// This adds 3+5=8 and returns it
		contractCode := []byte{
			0x60, 0x05, // PUSH1 0x05
			0x60, 0x03, // PUSH1 0x03
			0x01,       // ADD
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Deploy the contract code at the target address
		if err := vm.SetCode(contractAddr, primitives.NewBytes(contractCode)); err != nil {
			t.Fatalf("Failed to set contract code: %v", err)
		}
		
		// Call the contract with empty calldata
		calldata := primitives.NewBytes([]byte{})
		value := primitives.NewU256(100)
		
		result, err := vm.ExecuteCall(caller, contractAddr, value, calldata, 100000)
		if err != nil {
			t.Fatalf("ExecuteCall failed: %v", err)
		}
		
		// Check the execution was successful
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		if result.GasLeft >= 100000 {
			t.Errorf("Expected gas to be consumed, got %d left", result.GasLeft)
		}
		
		// The output should contain the result of 3+5=8
		if len(result.Output.Data()) != 32 {
			t.Errorf("Expected 32 bytes output, got %d", len(result.Output.Data()))
		} else if result.Output.Data()[31] != 8 {
			t.Errorf("Expected result to be 8, got %d", result.Output.Data()[31])
		}
		
		t.Logf("CALL Result - Success: %v, GasLeft: %d, Output: %s", 
			result.Success, result.GasLeft, hex.EncodeToString(result.Output.Data()))
	})
	
	t.Run("STATICCALL operation", func(t *testing.T) {
		// Deploy a contract that reads storage and returns a value
		// Contract: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
		// Returns the constant value 0x42
		contractCode := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Deploy the contract
		staticAddr := primitives.NewAddress([20]byte{0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f, 0x40, 0x41, 0x42, 0x43})
		if err := vm.SetCode(staticAddr, primitives.NewBytes(contractCode)); err != nil {
			t.Fatalf("Failed to set contract code: %v", err)
		}
		
		// Call the contract with empty calldata
		calldata := primitives.NewBytes([]byte{})
		
		result, err := vm.ExecuteStaticCall(caller, staticAddr, calldata, 50000)
		if err != nil {
			t.Fatalf("ExecuteStaticCall failed: %v", err)
		}
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// Check the returned value is 0x42
		if len(result.Output.Data()) != 32 {
			t.Errorf("Expected 32 bytes output, got %d", len(result.Output.Data()))
		} else if result.Output.Data()[31] != 0x42 {
			t.Errorf("Expected result to be 0x42, got 0x%x", result.Output.Data()[31])
		}
		
		// Static calls should be read-only
		if len(result.SelfDestructs) > 0 {
			t.Errorf("STATICCALL should not allow self-destructs")
		}
		
		t.Logf("STATICCALL Result - Success: %v, GasLeft: %d, Output: 0x%s", 
			result.Success, result.GasLeft, hex.EncodeToString(result.Output.Data()))
	})
	
	t.Run("DELEGATECALL operation", func(t *testing.T) {
		// Deploy a contract that stores caller address and returns it
		// Contract: CALLER PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
		contractCode := []byte{
			0x33,       // CALLER
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Deploy implementation contract
		implAddr := primitives.NewAddress([20]byte{0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58})
		if err := vm.SetCode(implAddr, primitives.NewBytes(contractCode)); err != nil {
			t.Fatalf("Failed to set implementation code: %v", err)
		}
		
		// Use empty calldata
		calldata := primitives.NewBytes([]byte{})
		
		result, err := vm.ExecuteDelegateCall(caller, implAddr, calldata, 75000)
		if err != nil {
			t.Fatalf("ExecuteDelegateCall failed: %v", err)
		}
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// DELEGATECALL preserves the caller context
		// The CALLER opcode should return the original caller address
		if len(result.Output.Data()) != 32 {
			t.Errorf("Expected 32 bytes output, got %d", len(result.Output.Data()))
		}
		
		t.Logf("DELEGATECALL Result - Success: %v, GasLeft: %d, Output (caller address): 0x%s", 
			result.Success, result.GasLeft, hex.EncodeToString(result.Output.Data()))
	})
	
	t.Run("CREATE operation", func(t *testing.T) {
		// Init code that deploys a simple contract
		// The deployed contract code: PUSH1 0x42 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
		deployedCode := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Init code: Store the deployed code in memory and return it
		initCode := []byte{}
		// Push the deployed code bytes to memory
		for i := len(deployedCode) - 1; i >= 0; i-- {
			initCode = append(initCode, 0x60, deployedCode[i]) // PUSH1 byte
		}
		// Store each byte at the correct position
		for i := 0; i < len(deployedCode); i++ {
			initCode = append(initCode, 0x60, byte(i)) // PUSH1 position
			initCode = append(initCode, 0x53)          // MSTORE8
		}
		// Return the code from memory
		initCode = append(initCode,
			0x60, byte(len(deployedCode)), // PUSH1 code_length
			0x60, 0x00, // PUSH1 0x00 (memory offset)
			0xf3, // RETURN
		)
		
		input := primitives.NewBytes(initCode)
		value := primitives.NewU256(0)
		
		result, err := vm.ExecuteCreate(caller, value, input, 200000)
		if err != nil {
			t.Fatalf("ExecuteCreate failed: %v", err)
		}
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// CREATE should consume gas
		if result.GasLeft >= 200000 {
			t.Errorf("Expected gas to be consumed, got %d left", result.GasLeft)
		}
		
		t.Logf("CREATE Result - Success: %v, GasLeft: %d, Output length: %d", 
			result.Success, result.GasLeft, len(result.Output.Data()))
	})
	
	t.Run("CREATE2 operation", func(t *testing.T) {
		// Same deployed code as CREATE test
		deployedCode := []byte{
			0x60, 0x99, // PUSH1 0x99
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Simple init code: copy deployed code to memory and return
		initCode := []byte{}
		for i := len(deployedCode) - 1; i >= 0; i-- {
			initCode = append(initCode, 0x60, deployedCode[i])
		}
		for i := 0; i < len(deployedCode); i++ {
			initCode = append(initCode, 0x60, byte(i))
			initCode = append(initCode, 0x53)
		}
		initCode = append(initCode,
			0x60, byte(len(deployedCode)),
			0x60, 0x00,
			0xf3,
		)
		
		input := primitives.NewBytes(initCode)
		value := primitives.NewU256(0)
		
		// Use a deterministic salt for CREATE2
		saltBytes := [32]byte{}
		saltBytes[31] = 0x42
		salt, _ := primitives.U256FromBytes(saltBytes[:])
		
		result, err := vm.ExecuteCreate2(caller, value, input, salt, 250000)
		if err != nil {
			t.Fatalf("ExecuteCreate2 failed: %v", err)
		}
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// CREATE2 should consume gas
		if result.GasLeft >= 250000 {
			t.Errorf("Expected gas to be consumed, got %d left", result.GasLeft)
		}
		
		t.Logf("CREATE2 Result - Success: %v, GasLeft: %d, Salt: 0x%x", 
			result.Success, result.GasLeft, saltBytes[31])
	})
	
	t.Run("Full CallParams with all fields", func(t *testing.T) {
		// Deploy a contract with storage operations
		// Contract code: stores 1 at slot 0, loads it back, and returns it
		contractCode := []byte{
			0x60, 0x01, // PUSH1 0x01
			0x60, 0x00, // PUSH1 0x00  
			0x55,       // SSTORE (store 1 at slot 0)
			0x60, 0x00, // PUSH1 0x00
			0x54,       // SLOAD (load from slot 0)
			0x60, 0x00, // PUSH1 0x00
			0x52,       // MSTORE (store in memory)
			0x60, 0x20, // PUSH1 0x20
			0x60, 0x00, // PUSH1 0x00
			0xf3,       // RETURN
		}
		
		// Deploy the contract
		storageAddr := primitives.NewAddress([20]byte{0x60, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f, 0x70, 0x71, 0x72, 0x73})
		if err := vm.SetCode(storageAddr, primitives.NewBytes(contractCode)); err != nil {
			t.Fatalf("Failed to set contract code: %v", err)
		}
		
		// Call the contract
		params := evm.CallParams{
			CallType: evm.CallTypeCall,
			Caller:   caller,
			To:       storageAddr,
			Value:    primitives.ZeroU256(),
			Input:    primitives.NewBytes([]byte{}), // Empty calldata
			Gas:      500000,
			Salt:     primitives.ZeroU256(),
		}
		
		result, err := vm.ExecuteWithParams(params)
		if err != nil {
			t.Fatalf("ExecuteWithParams failed: %v", err)
		}
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// Check comprehensive results
		t.Logf("Full execution result:")
		t.Logf("  Success: %v", result.Success)
		t.Logf("  GasLeft: %d", result.GasLeft)
		t.Logf("  Output: %s", hex.EncodeToString(result.Output.Data()))
		t.Logf("  Logs: %d entries", len(result.Logs))
		t.Logf("  SelfDestructs: %d", len(result.SelfDestructs))
		t.Logf("  AccessedAddresses: %d", len(result.AccessedAddresses))
		t.Logf("  AccessedStorage: %d", len(result.AccessedStorage))
		
		// Verify the output contains the stored value (1)
		if len(result.Output.Data()) != 32 {
			t.Errorf("Expected 32 bytes output, got %d", len(result.Output.Data()))
		} else if result.Output.Data()[31] != 1 {
			t.Errorf("Expected output value to be 1, got %d", result.Output.Data()[31])
		}
		
		// Verify we got storage access records
		if len(result.AccessedStorage) == 0 {
			t.Logf("Warning: Expected storage access records but got none")
		}
	})
}

func TestEVMCallTypeDifferentiation(t *testing.T) {
	vm, err := evm.New()
	if err != nil {
		t.Fatalf("Failed to create EVM: %v", err)
	}
	defer vm.Close()
	
	caller := primitives.NewAddress([20]byte{0x01})
	targetAddr := primitives.NewAddress([20]byte{0x02})
	
	// Set up caller with balance for CREATE operations
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		t.Fatalf("Failed to set caller balance: %v", err)
	}
	
	// Deploy a simple contract for call operations
	// Contract: PUSH1 0x01 PUSH1 0x00 MSTORE PUSH1 0x20 PUSH1 0x00 RETURN
	simpleContract := []byte{
		0x60, 0x01, // PUSH1 0x01
		0x60, 0x00, // PUSH1 0x00
		0x52,       // MSTORE
		0x60, 0x20, // PUSH1 0x20
		0x60, 0x00, // PUSH1 0x00
		0xf3,       // RETURN
	}
	if err := vm.SetCode(targetAddr, primitives.NewBytes(simpleContract)); err != nil {
		t.Fatalf("Failed to set contract code: %v", err)
	}
	
	// Test that different call types are properly differentiated
	callTypes := []struct {
		name          string
		callType      evm.CallType
		expectSuccess bool
		isCreate      bool
	}{
		{"CALL", evm.CallTypeCall, true, false},
		{"CALLCODE", evm.CallTypeCallcode, true, false},
		{"DELEGATECALL", evm.CallTypeDelegatecall, true, false},
		{"STATICCALL", evm.CallTypeStaticcall, true, false},
		{"CREATE", evm.CallTypeCreate, true, true},
		{"CREATE2", evm.CallTypeCreate2, true, true},
	}
	
	for _, ct := range callTypes {
		t.Run(ct.name, func(t *testing.T) {
			var input primitives.Bytes
			var to primitives.Address
			
			if ct.isCreate {
				// For CREATE operations, use init code that returns empty contract
				initCode := []byte{
					0x60, 0x00, // PUSH1 0x00
					0x60, 0x00, // PUSH1 0x00
					0xf3,       // RETURN
				}
				input = primitives.NewBytes(initCode)
				to = primitives.Address{} // Empty for CREATE
			} else {
				// For CALL operations, use empty calldata
				input = primitives.NewBytes([]byte{})
				to = targetAddr
			}
			
			params := evm.CallParams{
				CallType: ct.callType,
				Caller:   caller,
				To:       to,
				Value:    primitives.ZeroU256(),
				Input:    input,
				Gas:      100000,
				Salt:     primitives.ZeroU256(),
			}
			
			result, err := vm.ExecuteWithParams(params)
			if err != nil {
				t.Fatalf("ExecuteWithParams failed for %s: %v", ct.name, err)
			}
			
			if ct.expectSuccess && !result.Success {
				t.Errorf("%s: Expected success, got failure: %s", ct.name, result.ErrorInfo)
			}
			
			// Verify gas was consumed
			if result.GasLeft >= 100000 {
				t.Errorf("%s: Expected gas to be consumed, got %d left", ct.name, result.GasLeft)
			}
			
			t.Logf("%s executed - Success: %v, GasLeft: %d", 
				ct.name, result.Success, result.GasLeft)
		})
	}
}

func TestEVMLogsAndEvents(t *testing.T) {
	vm, err := evm.New()
	if err != nil {
		t.Fatalf("Failed to create EVM: %v", err)
	}
	defer vm.Close()
	
	caller := primitives.NewAddress([20]byte{0x01})
	eventAddr := primitives.NewAddress([20]byte{0x02})
	
	// Set up caller with balance
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		t.Fatalf("Failed to set caller balance: %v", err)
	}
	
	// First test with a simple LOG0
	t.Run("Simple LOG0", func(t *testing.T) {
		// Contract that stores data and emits LOG0
		// PUSH1 0x42, PUSH1 0x00, MSTORE8
		// PUSH1 0x01 (length), PUSH1 0x00 (offset), LOG0
		simpleLog := []byte{
			0x60, 0x42, // PUSH1 0x42
			0x60, 0x00, // PUSH1 0x00
			0x53,       // MSTORE8
			0x60, 0x01, // PUSH1 0x01 (length)
			0x60, 0x00, // PUSH1 0x00 (offset)
			0xa0,       // LOG0
			0x00,       // STOP
		}
		
		logAddr := primitives.NewAddress([20]byte{0x03})
		if err := vm.SetCode(logAddr, primitives.NewBytes(simpleLog)); err != nil {
			t.Fatalf("Failed to set contract code: %v", err)
		}
		
		params := evm.CallParams{
			CallType: evm.CallTypeCall,
			Caller:   caller,
			To:       logAddr,
			Value:    primitives.ZeroU256(),
			Input:    primitives.NewBytes([]byte{}),
			Gas:      50000,
			Salt:     primitives.ZeroU256(),
		}
		
		result, err := vm.ExecuteWithParams(params)
		if err != nil {
			t.Fatalf("ExecuteWithParams failed: %v", err)
		}
		
		t.Logf("LOG0 test - Success: %v, GasLeft: %d (consumed: %d)", 
			result.Success, result.GasLeft, 50000-result.GasLeft)
		t.Logf("LOG0 test - Logs captured: %d", len(result.Logs))
		
		if len(result.Logs) == 0 {
			t.Error("LOG0: No logs captured")
		}
	})
	
	t.Run("LOG1 with topic", func(t *testing.T) {
		// Deploy a contract that emits a LOG1 event
		// First store some data in memory, then emit a LOG1 event with that data
		// Contract bytecode:
		// PUSH1 0xAB - Store value 0xAB
		// PUSH1 0x00 - Memory position 0
		// MSTORE8 - Store single byte
		// PUSH32 <topic> - Event topic
		// PUSH1 0x01 - Data length (1 byte)
		// PUSH1 0x00 - Data offset (memory position 0)
		// LOG1 - Emit event with 1 topic
		
		topic := [32]byte{}
		// Use a recognizable topic pattern
		for i := 0; i < 32; i++ {
			topic[i] = byte(i + 1)
		}
		
		contractCode := []byte{
			0x60, 0xAB, // PUSH1 0xAB
			0x60, 0x00, // PUSH1 0x00
			0x53,       // MSTORE8
			0x7f,       // PUSH32
		}
		contractCode = append(contractCode, topic[:]...)
		contractCode = append(contractCode,
			0x60, 0x01, // PUSH1 0x01 (data length)
			0x60, 0x00, // PUSH1 0x00 (data offset)
			0xa1,       // LOG1
			0x00,       // STOP - clean execution termination
		)
		
		// Deploy the contract
		if err := vm.SetCode(eventAddr, primitives.NewBytes(contractCode)); err != nil {
			t.Fatalf("Failed to set contract code: %v", err)
		}
		
		// Call the contract with empty calldata
		params := evm.CallParams{
			CallType: evm.CallTypeCall,
			Caller:   caller,
			To:       eventAddr,
			Value:    primitives.ZeroU256(),
			Input:    primitives.NewBytes([]byte{}), // Empty calldata
			Gas:      100000,
			Salt:     primitives.ZeroU256(),
		}
		
		result, err := vm.ExecuteWithParams(params)
		if err != nil {
			t.Fatalf("ExecuteWithParams failed: %v", err)
		}
		
		// Debug: Check execution details
		t.Logf("Execution result - Success: %v, GasLeft: %d (consumed: %d)", 
			result.Success, result.GasLeft, 100000-result.GasLeft)
		
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		
		// Debug: Check all result fields
		t.Logf("Result details:")
		t.Logf("  Output: %s", hex.EncodeToString(result.Output.Data()))
		t.Logf("  Logs count: %d", len(result.Logs))
		t.Logf("  AccessedAddresses: %d", len(result.AccessedAddresses))
		
		// Check if we captured the log event
		if len(result.Logs) > 0 {
			t.Logf("Successfully captured %d log entries", len(result.Logs))
			for i, log := range result.Logs {
			t.Logf("  Log %d:", i)
			addr := log.Address.Array()
			t.Logf("    Address: 0x%s", hex.EncodeToString(addr[:]))
			t.Logf("    Topics: %d", len(log.Topics))
			if len(log.Topics) > 0 {
				for j, topic := range log.Topics {
					topicBytes := topic.Bytes()
					t.Logf("      Topic %d: 0x%s", j, hex.EncodeToString(topicBytes[:]))
				}
			}
			t.Logf("    Data: 0x%s", hex.EncodeToString(log.Data.Data()))
			
			// Verify the log data contains our value (0xAB)
			if len(log.Data.Data()) > 0 && log.Data.Data()[0] != 0xAB {
				t.Errorf("Expected log data to contain 0xAB, got 0x%x", log.Data.Data()[0])
			}
		}
	} else {
		t.Error("No logs captured")
	}
	})
}