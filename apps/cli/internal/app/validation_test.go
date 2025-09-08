package app

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
		errorType   config.InputParamErrorType
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
			errorType:   config.ErrorCallTypeRequired,
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
			errorType:   config.ErrorInvalidCallerAddress,
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
			errorType:   config.ErrorInvalidGasLimit,
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
			errorType:   config.ErrorInvalidInputData,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateCallParameters(tt.params)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got nil")
					return
				}
				
				// Check if it's the right type of error
				if inputErr, ok := err.(config.InputParamError); ok {
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
		errorType   config.InputParamErrorType
	}{
		{config.CallParamCaller, "0x0102030405060708090a0b0c0d0e0f1011121314", false, 0},
		{config.CallParamCaller, "invalid", true, config.ErrorInvalidCallerAddress},
		{config.CallParamTarget, "0x0102030405060708090a0b0c0d0e0f1011121314", false, 0},
		{config.CallParamTarget, "invalid", true, config.ErrorInvalidTargetAddress},
		{config.CallParamValue, "123", false, 0},
		{config.CallParamValue, "invalid", true, config.ErrorInvalidValue},
		{config.CallParamGasLimit, "100000", false, 0},
		{config.CallParamGasLimit, "invalid", true, config.ErrorInvalidGasLimit},
		{config.CallParamInput, "0x", false, 0},
		{config.CallParamInput, "invalid", true, config.ErrorInvalidInputData},
		{config.CallParamSalt, "0x0000000000000000000000000000000000000000000000000000000000000000", false, 0},
		{config.CallParamSalt, "invalid", true, config.ErrorInvalidSalt},
	}

	for _, tt := range tests {
		t.Run(tt.field+"_"+tt.value, func(t *testing.T) {
			err := validateField(tt.field, tt.value)
			
			if tt.expectError {
				if err == nil {
					t.Error("Expected error but got nil")
					return
				}
				
				if inputErr, ok := err.(config.InputParamError); ok {
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