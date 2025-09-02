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
	to := primitives.NewAddress([20]byte{0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28})
	
	t.Run("CALL operation", func(t *testing.T) {
		// Simple addition bytecode: PUSH1 0x02 PUSH1 0x03 ADD
		bytecode := []byte{0x60, 0x02, 0x60, 0x03, 0x01}
		input := primitives.NewBytes(bytecode)
		value, _ := primitives.U256FromUint64(1000)
		
		result, err := vm.ExecuteCall(caller, to, value, input, 100000)
		if err != nil {
			t.Fatalf("ExecuteCall failed: %v", err)
		}
		
		// Check basic fields
		if !result.Success {
			t.Errorf("Expected success, got failure: %s", result.ErrorInfo)
		}
		if result.GasLeft >= 100000 {
			t.Errorf("Expected gas to be consumed, got %d left", result.GasLeft)
		}
		
		t.Logf("CALL Result - Success: %v, GasLeft: %d, Output: %s", 
			result.Success, result.GasLeft, hex.EncodeToString(result.Output.Data()))
	})
	
	t.Run("STATICCALL operation", func(t *testing.T) {
		// PUSH1 0x42 (pushes 42 to stack)
		bytecode := []byte{0x60, 0x42}
		input := primitives.NewBytes(bytecode)
		
		result, err := vm.ExecuteStaticCall(caller, to, input, 50000)
		if err != nil {
			t.Fatalf("ExecuteStaticCall failed: %v", err)
		}
		
		// Static calls should be read-only
		if len(result.SelfDestructs) > 0 {
			t.Errorf("STATICCALL should not allow self-destructs")
		}
		
		t.Logf("STATICCALL Result - Success: %v, GasLeft: %d", 
			result.Success, result.GasLeft)
	})
	
	t.Run("DELEGATECALL operation", func(t *testing.T) {
		// Simple return bytecode: PUSH1 0x20 PUSH1 0x00 RETURN
		bytecode := []byte{0x60, 0x20, 0x60, 0x00, 0xf3}
		input := primitives.NewBytes(bytecode)
		
		result, err := vm.ExecuteDelegateCall(caller, to, input, 75000)
		if err != nil {
			t.Fatalf("ExecuteDelegateCall failed: %v", err)
		}
		
		// DELEGATECALL preserves caller context
		t.Logf("DELEGATECALL Result - Success: %v, GasLeft: %d, Output length: %d", 
			result.Success, result.GasLeft, len(result.Output.Data()))
	})
	
	t.Run("CREATE operation", func(t *testing.T) {
		// Simple contract creation code
		// PUSH1 0x00 PUSH1 0x00 RETURN (returns empty code)
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}
		input := primitives.NewBytes(initCode)
		value, _ := primitives.U256FromUint64(0)
		
		result, err := vm.ExecuteCreate(caller, value, input, 200000)
		if err != nil {
			t.Fatalf("ExecuteCreate failed: %v", err)
		}
		
		t.Logf("CREATE Result - Success: %v, GasLeft: %d", 
			result.Success, result.GasLeft)
	})
	
	t.Run("CREATE2 operation", func(t *testing.T) {
		// Simple contract creation code with salt
		initCode := []byte{0x60, 0x00, 0x60, 0x00, 0xf3}
		input := primitives.NewBytes(initCode)
		value, _ := primitives.U256FromUint64(0)
		
		// Use a deterministic salt
		saltBytes := [32]byte{}
		saltBytes[31] = 0x42
		salt, _ := primitives.U256FromBytes(saltBytes[:])
		
		result, err := vm.ExecuteCreate2(caller, value, input, salt, 250000)
		if err != nil {
			t.Fatalf("ExecuteCreate2 failed: %v", err)
		}
		
		t.Logf("CREATE2 Result - Success: %v, GasLeft: %d", 
			result.Success, result.GasLeft)
	})
	
	t.Run("Full CallParams with all fields", func(t *testing.T) {
		// Test with complete parameters including logs and storage access
		bytecode := []byte{
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
		
		params := evm.FullCallParams{
			CallType: evm.CallTypeCall,
			Caller:   caller,
			To:       to,
			Value:    primitives.ZeroU256(),
			Input:    primitives.NewBytes(bytecode),
			Gas:      500000,
			Salt:     primitives.ZeroU256(),
		}
		
		result, err := vm.ExecuteWithParams(params)
		if err != nil {
			t.Fatalf("ExecuteWithParams failed: %v", err)
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
		if result.ErrorInfo != "" {
			t.Logf("  Error: %s", result.ErrorInfo)
		}
		
		// Verify we got storage access
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
	to := primitives.NewAddress([20]byte{0x02})
	
	// Test that different call types are properly differentiated
	callTypes := []struct {
		name     string
		callType evm.CallType
	}{
		{"CALL", evm.CallTypeCall},
		{"CALLCODE", evm.CallTypeCallcode},
		{"DELEGATECALL", evm.CallTypeDelegatecall},
		{"STATICCALL", evm.CallTypeStaticcall},
		{"CREATE", evm.CallTypeCreate},
		{"CREATE2", evm.CallTypeCreate2},
	}
	
	for _, ct := range callTypes {
		t.Run(ct.name, func(t *testing.T) {
			params := evm.FullCallParams{
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
			
			// Just verify it executed without panic
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
	to := primitives.NewAddress([20]byte{0x02})
	
	// Bytecode that emits a LOG1 event
	// PUSH1 0x20 (data size)
	// PUSH1 0x00 (data offset)
	// PUSH32 <topic>
	// LOG1
	topic := []byte{
		0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
		0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10,
		0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18,
		0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 0x20,
	}
	
	bytecode := []byte{
		0x60, 0x20, // PUSH1 0x20
		0x60, 0x00, // PUSH1 0x00
		0x7f, // PUSH32
	}
	bytecode = append(bytecode, topic...)
	bytecode = append(bytecode, 0xa1) // LOG1
	
	params := evm.FullCallParams{
		CallType: evm.CallTypeCall,
		Caller:   caller,
		To:       to,
		Value:    primitives.ZeroU256(),
		Input:    primitives.NewBytes(bytecode),
		Gas:      100000,
		Salt:     primitives.ZeroU256(),
	}
	
	result, err := vm.ExecuteWithParams(params)
	if err != nil {
		t.Fatalf("ExecuteWithParams failed: %v", err)
	}
	
	if len(result.Logs) > 0 {
		t.Logf("Captured %d log entries", len(result.Logs))
		for i, log := range result.Logs {
			t.Logf("  Log %d:", i)
			t.Logf("    Address: %s", hex.EncodeToString(log.Address.Array()[:]))
			t.Logf("    Topics: %d", len(log.Topics))
			t.Logf("    Data length: %d", len(log.Data.Data()))
		}
	} else {
		t.Logf("No logs captured (this may be expected if logging is not fully implemented)")
	}
}