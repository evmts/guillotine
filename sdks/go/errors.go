package guillotine

import "errors"

// Common errors used by the Guillotine SDK
var (
	ErrInitializationFailed = errors.New("failed to initialize Guillotine")
	ErrVMCreationFailed     = errors.New("failed to create VM instance")
	ErrVMClosed             = errors.New("VM instance has been closed")
	ErrExecutionFailed      = errors.New("EVM execution failed")
	ErrInvalidInput         = errors.New("invalid input")
)