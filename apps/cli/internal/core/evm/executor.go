package evm

import (
	"fmt"
	"guillotine-cli/internal/types"
	"math/big"

	guillotine "github.com/evmts/guillotine/sdks/go"
	"github.com/evmts/guillotine/sdks/go/evm"
)

func ExecuteCall(vmMgr *VMManager, params types.CallParametersStrings) (*guillotine.CallResult, error) {
	validator := NewCallValidator()
	if err := validator.ValidateCallParameters(params); err != nil {
		return nil, err
	}
	
	vm, err := vmMgr.GetVM()
	if err != nil {
		return nil, fmt.Errorf("failed to get VM: %w", err)
	}
	
	// Parse common parameters
	caller, err := ParseEthereumAddress(params.Caller)
	if err != nil {
		return nil, fmt.Errorf("invalid caller address: %w", err)
	}
	
	value, err := ParseWeiValue(params.Value)
	if err != nil {
		return nil, fmt.Errorf("invalid value: %w", err)
	}
	
	gasLimit, err := ParseGasLimit(params.GasLimit)
	if err != nil {
		return nil, err
	}
	
	inputBytes, err := ParseHexData(params.InputData)
	if err != nil {
		return nil, fmt.Errorf("invalid input data: %w", err)
	}
	
	// Set caller balance for testing (temporary until we have proper state management)
	// TODO: add some flag to bypass balance checks when we have cheatcodes to deal ether
	if err := vm.SetBalance(caller, big.NewInt(1000000)); err != nil {
		return nil, fmt.Errorf("failed to set caller balance: %w", err)
	}
	
	// Use the CallTypeFromString from types package
	callType := types.CallTypeFromString(params.CallType)
	
	// Build appropriate call parameter based on type
	var callParams evm.CallParams
	
	switch callType {
	case guillotine.CallTypeCall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		callParams = evm.Call{
			Caller: caller,
			To:     target,
			Value:  value,
			Input:  inputBytes,
			Gas:    gasLimit,
		}
		
	case guillotine.CallTypeCallcode:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		callParams = evm.Callcode{
			Caller: caller,
			To:     target,
			Value:  value,
			Input:  inputBytes,
			Gas:    gasLimit,
		}
		
	case guillotine.CallTypeStaticcall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		callParams = evm.Staticcall{
			Caller: caller,
			To:     target,
			Input:  inputBytes,
			Gas:    gasLimit,
		}
		
	case guillotine.CallTypeDelegatecall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		callParams = evm.Delegatecall{
			Caller: caller,
			To:     target,
			Input:  inputBytes,
			Gas:    gasLimit,
		}
		
	case guillotine.CallTypeCreate:
		callParams = evm.Create{
			Caller:   caller,
			Value:    value,
			InitCode: inputBytes,
			Gas:      gasLimit,
		}
		
	case guillotine.CallTypeCreate2:
		salt, err := ParseSalt(params.Salt)
		if err != nil {
			return nil, err
		}
		callParams = evm.Create2{
			Caller:   caller,
			Value:    value,
			InitCode: inputBytes,
			Salt:     salt,
			Gas:      gasLimit,
		}
		
	default:
		return nil, types.NewInputParamError(types.ErrorUnsupportedCallType, "call_type")
	}
	
	// Execute the call using the unified interface
	result, err := vm.Call(callParams)
	if err != nil {
		// Return a failed result with error info
		return &guillotine.CallResult{
			Success:   false,
			ErrorInfo: err.Error(),
			GasLeft:   0,
		}, nil
	}
	
	return result, nil
}