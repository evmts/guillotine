package evm

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"
)

// CallValidator handles all validation for EVM call parameters
type CallValidator struct{}

// NewCallValidator creates a new validator instance
func NewCallValidator() *CallValidator {
	return &CallValidator{}
}

// ValidateCallParameters validates all call parameters before execution
func (v *CallValidator) ValidateCallParameters(params types.CallParametersStrings) error {
	// Validate call type
	if params.CallType == "" {
		return types.NewInputParamError(types.ErrorCallTypeRequired, "call_type")
	}
	
	// Validate caller address
	if !IsValidAddress(params.Caller) {
		return types.NewInputParamError(types.ErrorInvalidCallerAddress, "caller")
	}
	
	// Validate target address (not required for CREATE/CREATE2)
	if params.CallType != config.CallTypeCreate && params.CallType != config.CallTypeCreate2 {
		if !IsValidAddress(params.Target) {
			return types.NewInputParamError(types.ErrorInvalidTargetAddress, "target")
		}
	}
	
	// Validate gas limit
	if _, err := strconv.ParseUint(params.GasLimit, 10, 64); err != nil {
		return types.NewInputParamError(types.ErrorInvalidGasLimit, "gas_limit")
	}
	
	// Validate value
	if _, err := strconv.ParseUint(params.Value, 10, 64); err != nil {
		return types.NewInputParamError(types.ErrorInvalidValue, "value")
	}
	
	// Validate input data
	if !IsValidHex(params.InputData) {
		return types.NewInputParamError(types.ErrorInvalidInputData, "input_data")
	}
	
	// Validate salt for CREATE2
	if params.CallType == config.CallTypeCreate2 {
		if !IsValidHex(params.Salt) {
			return types.NewInputParamError(types.ErrorInvalidSalt, "salt")
		}
	}
	
	return nil
}

// ValidateField validates a single field value
func (v *CallValidator) ValidateField(fieldName, value string) error {
	switch fieldName {
	case config.CallParamCaller:
		if !IsValidAddress(value) {
			return types.NewInputParamError(types.ErrorInvalidCallerAddress, fieldName)
		}
		
	case config.CallParamTarget:
		if !IsValidAddress(value) {
			return types.NewInputParamError(types.ErrorInvalidTargetAddress, fieldName)
		}
		
	case config.CallParamValue:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return types.NewInputParamError(types.ErrorInvalidValue, fieldName)
		}
		
	case config.CallParamGasLimit:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return types.NewInputParamError(types.ErrorInvalidGasLimit, fieldName)
		}
		
	case config.CallParamInput, config.CallParamInputDeploy:
		if !IsValidHex(value) {
			return types.NewInputParamError(types.ErrorInvalidInputData, fieldName)
		}
		
	case config.CallParamSalt:
		if !IsValidHex(value) {
			return types.NewInputParamError(types.ErrorInvalidSalt, fieldName)
		}
	}
	
	return nil
}

// ValidateGasLimit validates and parses a gas limit string
func (v *CallValidator) ValidateGasLimit(gasLimit string) (uint64, error) {
	gas, err := strconv.ParseUint(gasLimit, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid gas limit: %w", err)
	}
	if gas == 0 {
		return 0, fmt.Errorf("gas limit must be greater than 0")
	}
	return gas, nil
}

// ValidateWeiValue validates and parses a wei value string
func (v *CallValidator) ValidateWeiValue(value string) (uint64, error) {
	wei, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid value: %w", err)
	}
	return wei, nil
}