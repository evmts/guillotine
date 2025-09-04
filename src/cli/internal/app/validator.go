package app

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/utils"
	"strconv"
)

// CallValidator handles all validation for EVM call parameters
type CallValidator struct{}

// NewCallValidator creates a new validator instance
func NewCallValidator() *CallValidator {
	return &CallValidator{}
}

// ValidateCallParameters validates all call parameters before execution
func (v *CallValidator) ValidateCallParameters(params types.CallParameters) error {
	// Validate call type
	if params.CallType == "" {
		return config.NewInputParamError(config.ErrorCallTypeRequired, "call_type")
	}
	
	// Validate caller address
	if !utils.IsValidAddress(params.Caller) {
		return config.NewInputParamError(config.ErrorInvalidCallerAddress, "caller")
	}
	
	// Validate target address (not required for CREATE/CREATE2)
	if params.CallType != config.CallTypeCreate && params.CallType != config.CallTypeCreate2 {
		if !utils.IsValidAddress(params.Target) {
			return config.NewInputParamError(config.ErrorInvalidTargetAddress, "target")
		}
	}
	
	// Validate gas limit
	if _, err := strconv.ParseUint(params.GasLimit, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidGasLimit, "gas_limit")
	}
	
	// Validate value
	if _, err := strconv.ParseUint(params.Value, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidValue, "value")
	}
	
	// Validate input data
	if !utils.IsValidHex(params.InputData) {
		return config.NewInputParamError(config.ErrorInvalidInputData, "input_data")
	}
	
	// Validate salt for CREATE2
	if params.CallType == config.CallTypeCreate2 {
		if !utils.IsValidHex(params.Salt) {
			return config.NewInputParamError(config.ErrorInvalidSalt, "salt")
		}
	}
	
	return nil
}

// ValidateField validates a single field value
func (v *CallValidator) ValidateField(fieldName, value string) error {
	switch fieldName {
	case config.CallParamCaller:
		if !utils.IsValidAddress(value) {
			return config.NewInputParamError(config.ErrorInvalidCallerAddress, fieldName)
		}
		
	case config.CallParamTarget:
		if !utils.IsValidAddress(value) {
			return config.NewInputParamError(config.ErrorInvalidTargetAddress, fieldName)
		}
		
	case config.CallParamValue:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return config.NewInputParamError(config.ErrorInvalidValue, fieldName)
		}
		
	case config.CallParamGasLimit:
		if _, err := strconv.ParseUint(value, 10, 64); err != nil {
			return config.NewInputParamError(config.ErrorInvalidGasLimit, fieldName)
		}
		
	case config.CallParamInput, config.CallParamInputDeploy:
		if !utils.IsValidHex(value) {
			return config.NewInputParamError(config.ErrorInvalidInputData, fieldName)
		}
		
	case config.CallParamSalt:
		if !utils.IsValidHex(value) {
			return config.NewInputParamError(config.ErrorInvalidSalt, fieldName)
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