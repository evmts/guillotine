package evm

import (
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"

	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

func ExecuteCall(vmMgr *VMManager, params types.CallParameters) (*evm.CallResult, error) {
	validator := NewCallValidator()
	if err := validator.ValidateCallParameters(params); err != nil {
		return nil, err
	}
	
	vm, err := vmMgr.GetVM()
	if err != nil {
		return nil, fmt.Errorf("failed to get VM: %w", err)
	}
	
	caller, err := ParseEthereumAddress(params.Caller)
	if err != nil {
		return nil, fmt.Errorf("invalid caller address: %w", err)
	}
	
	value, err := ParseWeiValue(params.Value)
	if err != nil {
		return nil, fmt.Errorf("invalid value: %w", err)
	}
	
	gasLimit, err := strconv.ParseUint(params.GasLimit, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid gas limit: %w", err)
	}
	
	inputBytes, err := ParseHexData(params.InputData)
	if err != nil {
		return nil, fmt.Errorf("invalid input data: %w", err)
	}
	inputData := primitives.NewBytes(inputBytes)
	
	// Set caller balance for testing (temporary until we have proper state management)
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		return nil, fmt.Errorf("failed to set caller balance: %w", err)
	}
	
	callType := config.CallTypeFromString(params.CallType)
	
	var result *evm.CallResult
	
	switch callType {
	case evm.CallTypeCall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteCall(caller, target, value, inputData, gasLimit)
		
	case evm.CallTypeStaticcall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteStaticCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeDelegatecall:
		target, err := ParseEthereumAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteDelegateCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeCreate:
		result, err = vm.ExecuteCreate(caller, value, inputData, gasLimit)
		
	case evm.CallTypeCreate2:
		saltBytes, err := ParseHexData(params.Salt)
		if err != nil {
			return nil, fmt.Errorf("invalid salt: %w", err)
		}
		// Convert salt bytes to U256
		var u256Bytes [32]byte
		copy(u256Bytes[32-len(saltBytes):], saltBytes)
		salt, err := primitives.U256FromBytes(u256Bytes[:])
		if err != nil {
			return nil, fmt.Errorf("invalid salt: %w", err)
		}
		result, err = vm.ExecuteCreate2(caller, value, inputData, salt, gasLimit)
		
	default:
		return nil, types.NewInputParamError(types.ErrorUnsupportedCallType, "call_type")
	}
	
	if err != nil {
		result = &evm.CallResult{
			Success:   false,
			ErrorInfo: err.Error(),
			GasLeft:   0,
		}
	}
	
	return result, nil
}