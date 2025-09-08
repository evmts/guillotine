package evm

import (
	"testing"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
)

func TestValidateCallParameters(t *testing.T) {
	tests := []struct {
		name        string
		params      types.CallParametersStrings
		expectError bool
		errorType   types.InputParamErrorType
	}{
		{
			name: "Valid parameters",
			params: types.CallParametersStrings{
				CallType:  config.CallTypeCall,
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "0x",
				Salt:      "0x0000000000000000000000000000000000000000000000000000000000000000",
			},
			expectError: false,
		},
		{
			name: "Missing call type",
			params: types.CallParametersStrings{
				CallType:  "",
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "0x",
				Salt:      "0x0000000000000000000000000000000000000000000000000000000000000000",
			},
			expectError: true,
			errorType:   types.ErrorCallTypeRequired,
		},
		{
			name: "Invalid caller address",
			params: types.CallParametersStrings{
				CallType:  config.CallTypeCall,
				Caller:    "invalid",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "0x",
				Salt:      "0x0000000000000000000000000000000000000000000000000000000000000000",
			},
			expectError: true,
			errorType:   types.ErrorInvalidCallerAddress,
		},
		{
			name: "Invalid gas limit",
			params: types.CallParametersStrings{
				CallType:  config.CallTypeCall,
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "invalid",
				InputData: "0x",
				Salt:      "0x0000000000000000000000000000000000000000000000000000000000000000",
			},
			expectError: true,
			errorType:   types.ErrorInvalidGasLimit,
		},
		{
			name: "Invalid input data",
			params: types.CallParametersStrings{
				CallType:  config.CallTypeCall,
				Caller:    "0x0102030405060708090a0b0c0d0e0f1011121314",
				Target:    "0x15161718191a1b1c1d1e1f20212223242526272e",
				Value:     "0",
				GasLimit:  "100000",
				InputData: "invalid",
				Salt:      "0x0000000000000000000000000000000000000000000000000000000000000000",
			},
			expectError: true,
			errorType:   types.ErrorInvalidInputData,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			validator := NewCallValidator()
			err := validator.ValidateCallParameters(tt.params)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got nil")
					return
				}
				
				// Check if it's the right type of error
				if inputErr, ok := err.(types.InputParamError); ok {
					if inputErr.Type != tt.errorType {
						t.Errorf("Expected error type %d, got %d", tt.errorType, inputErr.Type)
					}
				} else {
					t.Errorf("Expected InputParamError, got %T", err)
				}
			} else {
				if err != nil {
					t.Errorf("Expected no error but got: %v", err)
				}
			}
		})
	}
}

func TestValidateField(t *testing.T) {
	tests := []struct {
		field       string
		value       string
		expectError bool
		errorType   types.InputParamErrorType
	}{
		{config.CallParamCaller, "0x0102030405060708090a0b0c0d0e0f1011121314", false, 0},
		{config.CallParamCaller, "invalid", true, types.ErrorInvalidCallerAddress},
		{config.CallParamTarget, "0x0102030405060708090a0b0c0d0e0f1011121314", false, 0},
		{config.CallParamTarget, "invalid", true, types.ErrorInvalidTargetAddress},
		{config.CallParamValue, "123", false, 0},
		{config.CallParamValue, "invalid", true, types.ErrorInvalidValue},
		{config.CallParamGasLimit, "100000", false, 0},
		{config.CallParamGasLimit, "invalid", true, types.ErrorInvalidGasLimit},
		{config.CallParamInput, "0x", false, 0},
		{config.CallParamInput, "invalid", true, types.ErrorInvalidInputData},
		{config.CallParamSalt, "0x0000000000000000000000000000000000000000000000000000000000000000", false, 0},
		{config.CallParamSalt, "invalid", true, types.ErrorInvalidSalt},
	}

	for _, tt := range tests {
		t.Run(tt.field+"_"+tt.value, func(t *testing.T) {
			validator := NewCallValidator()
			err := validator.ValidateField(tt.field, tt.value)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got nil")
					return
				}
				
				if inputErr, ok := err.(types.InputParamError); ok {
					if inputErr.Type != tt.errorType {
						t.Errorf("Expected error type %d, got %d", tt.errorType, inputErr.Type)
					}
				} else {
					t.Errorf("Expected InputParamError, got %T", err)
				}
			} else {
				if err != nil {
					t.Errorf("Expected no error but got: %v", err)
				}
			}
		})
	}
}