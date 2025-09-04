package utils

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"
)

// ValidateCallParameters validates all call parameters
func ValidateCallParameters(params types.CallParameters) error {
	if params.CallType == "" {
		return config.NewInputParamError(config.ErrorCallTypeRequired, "call_type")
	}
	
	if !IsValidAddress(params.Caller) {
		return config.NewInputParamError(config.ErrorInvalidCallerAddress, "caller")
	}
	
	if params.CallType != config.CallTypeCreate && params.CallType != config.CallTypeCreate2 {
		if !IsValidAddress(params.Target) {
			return config.NewInputParamError(config.ErrorInvalidTargetAddress, "target")
		}
	}
	
	if _, err := strconv.ParseUint(params.GasLimit, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidGasLimit, "gas_limit")
	}
	
	if _, err := strconv.ParseUint(params.Value, 10, 64); err != nil {
		return config.NewInputParamError(config.ErrorInvalidValue, "value")
	}
	
	if !IsValidHex(params.InputData) {
		return config.NewInputParamError(config.ErrorInvalidInputData, "input_data")
	}
	
	if (params.CallType == config.CallTypeCreate2) && !IsValidHex(params.Salt) {
		return config.NewInputParamError(config.ErrorInvalidSalt, "salt")
	}
	
	return nil
}

// ValidateField validates a single field value
func ValidateField(fieldName, value string) error {
	switch fieldName {
	case config.CallParamCaller:
		if !IsValidAddress(value) {
			return config.NewInputParamError(config.ErrorInvalidCallerAddress, fieldName)
		}
	case config.CallParamTarget:
		if !IsValidAddress(value) {
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
		if !IsValidHex(value) {
			return config.NewInputParamError(config.ErrorInvalidInputData, fieldName)
		}
	case config.CallParamSalt:
		if !IsValidHex(value) {
			return config.NewInputParamError(config.ErrorInvalidSalt, fieldName)
		}
	}
	return nil
}