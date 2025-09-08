package evm

import (
	"guillotine-cli/internal/types"
	"testing"
)

func TestExecuteCall_ValidateParameters(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	tests := []struct {
		name      string
		params    types.CallParametersStrings
		wantError bool
	}{
		{
			name: "Valid CALL parameters",
			params: types.CallParametersStrings{
				CallType:  "CALL",
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "0x",
			},
			wantError: false,
		},
		{
			name: "Invalid caller address",
			params: types.CallParametersStrings{
				CallType:  "CALL",
				Caller:    "invalid",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "0x",
			},
			wantError: true,
		},
		{
			name: "Invalid gas limit",
			params: types.CallParametersStrings{
				CallType:  "CALL",
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "invalid",
				InputData: "0x",
			},
			wantError: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := ExecuteCall(vmMgr, tt.params)
			if (err != nil) != tt.wantError {
				t.Errorf("ExecuteCall() error = %v, wantError %v", err, tt.wantError)
			}
		})
	}
}

func TestExecuteCall_CallTypes(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	// Test CREATE call type
	params := types.CallParametersStrings{
		CallType:  "CREATE",
		Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
		Value:     "0",
		GasLimit:  "100000",
		InputData: "0x6080604052348015600f57600080fd5b50",
	}

	result, err := ExecuteCall(vmMgr, params)
	if err != nil {
		t.Errorf("ExecuteCall() with CREATE failed: %v", err)
	}

	if result == nil {
		t.Error("ExecuteCall() returned nil result")
	}
}