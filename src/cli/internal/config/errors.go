package config

import "fmt"

// InputParamErrorType represents the type of input parameter validation error
type InputParamErrorType int

const (
	ErrorCallTypeRequired InputParamErrorType = iota
	ErrorInvalidCallerAddress
	ErrorInvalidTargetAddress
	ErrorInvalidGasLimit
	ErrorInvalidValue
	ErrorInvalidInputData
	ErrorInvalidSalt
	ErrorUnsupportedCallType
)

// InputParamError represents a validation error for input parameters
type InputParamError struct {
	Type InputParamErrorType
	Field string
}

func (e InputParamError) Error() string {
	switch e.Type {
	case ErrorCallTypeRequired:
		return "call type is required"
	case ErrorInvalidCallerAddress:
		return "caller address must be a valid 40-character hex address"
	case ErrorInvalidTargetAddress:
		return "target address must be a valid 40-character hex address"
	case ErrorInvalidGasLimit:
		return "gas limit must be a valid number"
	case ErrorInvalidValue:
		return "value must be a valid number in Wei"
	case ErrorInvalidInputData:
		return "input data must be valid hex (starting with 0x)"
	case ErrorInvalidSalt:
		return "salt must be valid hex for CREATE2 operations"
	case ErrorUnsupportedCallType:
		return "unsupported call type"
	default:
		return fmt.Sprintf("unknown validation error for field: %s", e.Field)
	}
}

// NewInputParamError creates a new input parameter validation error
func NewInputParamError(errorType InputParamErrorType, field string) InputParamError {
	return InputParamError{
		Type: errorType,
		Field: field,
	}
}

// Enhanced error message for UI display (includes examples where helpful)
func (e InputParamError) UIError() string {
	switch e.Type {
	case ErrorInvalidValue:
		return "value must be a valid number in Wei (e.g., 0, 1000000)"
	default:
		return e.Error()
	}
}