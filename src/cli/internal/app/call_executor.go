package app

import (
	"encoding/hex"
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"
	"strings"

	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

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

func ExecuteCall(params types.CallParameters) (*types.CallExecution, error) {
	if err := ValidateCallParameters(params); err != nil {
		return nil, err
	}
	
	vm, err := evm.New()
	if err != nil {
		return nil, fmt.Errorf("failed to create EVM: %w", err)
	}
	defer vm.Close()
	
	caller, err := parseAddress(params.Caller)
	if err != nil {
		return nil, fmt.Errorf("invalid caller address: %w", err)
	}
	
	value, err := parseWeiValue(params.Value)
	if err != nil {
		return nil, fmt.Errorf("invalid value: %w", err)
	}
	
	gasLimit, err := strconv.ParseUint(params.GasLimit, 10, 64)
	if err != nil {
		return nil, fmt.Errorf("invalid gas limit: %w", err)
	}
	
	inputData, err := parseBytes(params.InputData)
	if err != nil {
		return nil, fmt.Errorf("invalid input data: %w", err)
	}
	
	// TODO: when we have state persistance and cheatcodes add a switch to bypass or not caller balance and give the exact amount required for the call
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		return nil, fmt.Errorf("failed to set caller balance: %w", err)
	}
	
	callType := config.CallTypeFromString(params.CallType)
	
	var result *evm.CallResult
	
	switch callType {
	case evm.CallTypeCall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteCall(caller, target, value, inputData, gasLimit)
		
	case evm.CallTypeStaticcall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteStaticCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeDelegatecall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, fmt.Errorf("invalid target address: %w", err)
		}
		result, err = vm.ExecuteDelegateCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeCreate:
		result, err = vm.ExecuteCreate(caller, value, inputData, gasLimit)
		
	case evm.CallTypeCreate2:
		salt, err := parseU256(params.Salt)
		if err != nil {
			return nil, fmt.Errorf("invalid salt: %w", err)
		}
		result, err = vm.ExecuteCreate2(caller, value, inputData, salt, gasLimit)
		
	default:
		return nil, config.NewInputParamError(config.ErrorUnsupportedCallType, "call_type")
	}
	
	if err != nil {
		return &types.CallExecution{
			Success:   false,
			GasUsed:   0,
			Output:    nil,
			ErrorInfo: err.Error(),
			Logs:      nil,
		}, nil
	}
	
	gasUsed := gasLimit - result.GasLeft
	
	return &types.CallExecution{
		Success:   result.Success,
		GasUsed:   gasUsed,
		Output:    result.Output.Data(),
		ErrorInfo: result.ErrorInfo,
		Logs:      result.Logs,
	}, nil
}

func IsValidAddress(addr string) bool {
	if !strings.HasPrefix(addr, "0x") {
		return false
	}
	hex := addr[2:]
	if len(hex) != 40 {
		return false
	}
	for _, c := range hex {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func IsValidHex(data string) bool {
	if !strings.HasPrefix(data, "0x") {
		return false
	}
	hex := data[2:]
	for _, c := range hex {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}

func parseAddress(addr string) (primitives.Address, error) {
	if !IsValidAddress(addr) {
		return primitives.Address{}, config.NewInputParamError(config.ErrorInvalidCallerAddress, "address")
	}
	
	hexStr := addr[2:]
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return primitives.Address{}, err
	}
	
	var addrBytes [20]byte
	copy(addrBytes[:], bytes)
	return primitives.NewAddress(addrBytes), nil
}

func parseU256(value string) (primitives.U256, error) {
	if !IsValidHex(value) {
		return primitives.U256{}, config.NewInputParamError(config.ErrorInvalidInputData, "hex_value")
	}
	
	hexStr := value[2:]
	if len(hexStr)%2 != 0 {
		hexStr = "0" + hexStr
	}
	
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return primitives.U256{}, err
	}
	
	var u256Bytes [32]byte
	copy(u256Bytes[32-len(bytes):], bytes)
	
	return primitives.U256FromBytes(u256Bytes[:])
}

func parseBytes(data string) (primitives.Bytes, error) {
	if !IsValidHex(data) {
		return primitives.Bytes{}, config.NewInputParamError(config.ErrorInvalidInputData, "hex_data")
	}
	
	hexStr := data[2:]
	if len(hexStr)%2 != 0 {
		hexStr = "0" + hexStr
	}
	
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return primitives.Bytes{}, err
	}
	
	return primitives.NewBytes(bytes), nil
}

func parseWeiValue(value string) (primitives.U256, error) {
	// Parse as decimal number
	val, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return primitives.U256{}, config.NewInputParamError(config.ErrorInvalidValue, "value")
	}
	
	// Convert to U256
	return primitives.NewU256(val), nil
}