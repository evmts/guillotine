package evm

import "github.com/evmts/guillotine/bindings/go/primitives"

// ExecutionResult represents the result of EVM execution
type ExecutionResult struct {
	success      bool
	gasUsed      uint64
	returnData   primitives.Bytes
	revertReason primitives.Bytes
}

// IsSuccess returns true if the execution was successful
func (r *ExecutionResult) IsSuccess() bool {
	return r.success
}

// GasUsed returns the amount of gas used during execution
func (r *ExecutionResult) GasUsed() uint64 {
	return r.gasUsed
}

// ReturnData returns the data returned by the execution
func (r *ExecutionResult) ReturnData() primitives.Bytes {
	return r.returnData
}

// RevertReason returns the revert reason if execution failed
func (r *ExecutionResult) RevertReason() primitives.Bytes {
	return r.revertReason
}

// HasReturnData returns true if there is return data
func (r *ExecutionResult) HasReturnData() bool {
	return !r.returnData.IsEmpty()
}

// HasRevertReason returns true if there is a revert reason
func (r *ExecutionResult) HasRevertReason() bool {
	return !r.revertReason.IsEmpty()
}