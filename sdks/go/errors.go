package guillotine

import (
	"errors"
	"fmt"
)

// Common errors
var (
	ErrInitializationFailed = errors.New("failed to initialize Guillotine")
	ErrVMCreationFailed     = errors.New("failed to create VM instance")
	ErrVMClosed             = errors.New("VM instance has been closed")
	ErrExecutionFailed      = errors.New("EVM execution failed")
	ErrInvalidBytecode      = errors.New("invalid bytecode")
	ErrInvalidAddress       = errors.New("invalid address")
	ErrInvalidValue         = errors.New("invalid value")
	ErrOutOfGas             = errors.New("out of gas")
	ErrStackOverflow        = errors.New("stack overflow")
	ErrStackUnderflow       = errors.New("stack underflow")
	ErrInvalidJump          = errors.New("invalid jump destination")
	ErrInvalidOpcode        = errors.New("invalid opcode")
)

// ErrorType represents the type of Guillotine error
type ErrorType int

const (
	ErrorUnknown ErrorType = iota
	ErrorInitializationFailed
	ErrorVMCreationFailed
	ErrorVMClosed
	ErrorExecutionFailed
	ErrorInvalidBytecode
	ErrorInvalidAddress
	ErrorInvalidValue
	ErrorOutOfGas
	ErrorStackOverflow
	ErrorStackUnderflow
	ErrorInvalidJump
	ErrorInvalidOpcode
)

// GuillotineError represents a typed error from the Guillotine EVM
type GuillotineError struct {
	Type    ErrorType
	Message string
	Cause   error
}

// Error implements the error interface
func (e *GuillotineError) Error() string {
	if e.Cause != nil {
		return fmt.Sprintf("%s: %v", e.Message, e.Cause)
	}
	return e.Message
}

// Unwrap implements the unwrapper interface
func (e *GuillotineError) Unwrap() error {
	return e.Cause
}

// NewGuillotineError creates a new GuillotineError
func NewGuillotineError(errorType ErrorType, message string, cause error) *GuillotineError {
	return &GuillotineError{
		Type:    errorType,
		Message: message,
		Cause:   cause,
	}
}