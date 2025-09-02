package app

import (
	"encoding/hex"
	"errors"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
	"strconv"
	"strings"

	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

func ValidateCallParameters(params types.CallParameters) error {
	if params.CallType == "" {
		return errors.New("call type is required")
	}
	
	if !IsValidAddress(params.Caller) {
		return errors.New("caller address must be a valid 40-character hex address")
	}
	
	if params.CallType != config.CallTypeCreate && params.CallType != config.CallTypeCreate2 {
		if !IsValidAddress(params.Target) {
			return errors.New("target address must be a valid 40-character hex address")
		}
	}
	
	if _, err := strconv.ParseUint(params.GasLimit, 10, 64); err != nil {
		return errors.New("gas limit must be a valid number")
	}
	
	if _, err := strconv.ParseUint(params.Value, 10, 64); err != nil {
		return errors.New("value must be a valid number in Wei")
	}
	
	if !IsValidHex(params.InputData) {
		return errors.New("input data must be valid hex (starting with 0x)")
	}
	
	if (params.CallType == config.CallTypeCreate2) && !IsValidHex(params.Salt) {
		return errors.New("salt must be valid hex for CREATE2 operations")
	}
	
	return nil
}

func ExecuteCall(params types.CallParameters) (*types.CallExecution, error) {
	if err := ValidateCallParameters(params); err != nil {
		return nil, err
	}
	
	vm, err := evm.New()
	if err != nil {
		return nil, errors.New("failed to create EVM: " + err.Error())
	}
	defer vm.Close()
	
	caller, err := parseAddress(params.Caller)
	if err != nil {
		return nil, errors.New("invalid caller address: " + err.Error())
	}
	
	value, err := parseWeiValue(params.Value)
	if err != nil {
		return nil, errors.New("invalid value: " + err.Error())
	}
	
	gasLimit, err := strconv.ParseUint(params.GasLimit, 10, 64)
	if err != nil {
		return nil, errors.New("invalid gas limit: " + err.Error())
	}
	
	inputData, err := parseBytes(params.InputData)
	if err != nil {
		return nil, errors.New("invalid input data: " + err.Error())
	}
	
	// TODO: when we have state persistance and cheatcodes add a switch to bypass or not caller balance and give the exact amount required for the call
	if err := vm.SetBalance(caller, primitives.NewU256(1000000)); err != nil {
		return nil, errors.New("failed to set caller balance: " + err.Error())
	}
	
	callType := config.CallTypeFromString(params.CallType)
	
	var result *evm.CallResult
	
	switch callType {
	case evm.CallTypeCall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, errors.New("invalid target address: " + err.Error())
		}
		result, err = vm.ExecuteCall(caller, target, value, inputData, gasLimit)
		
	case evm.CallTypeStaticcall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, errors.New("invalid target address: " + err.Error())
		}
		result, err = vm.ExecuteStaticCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeDelegatecall:
		target, err := parseAddress(params.Target)
		if err != nil {
			return nil, errors.New("invalid target address: " + err.Error())
		}
		result, err = vm.ExecuteDelegateCall(caller, target, inputData, gasLimit)
		
	case evm.CallTypeCreate:
		result, err = vm.ExecuteCreate(caller, value, inputData, gasLimit)
		
	case evm.CallTypeCreate2:
		salt, err := parseU256(params.Salt)
		if err != nil {
			return nil, errors.New("invalid salt: " + err.Error())
		}
		result, err = vm.ExecuteCreate2(caller, value, inputData, salt, gasLimit)
		
	default:
		return nil, errors.New("unsupported call type")
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
		return primitives.Address{}, errors.New("invalid address format")
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
		return primitives.U256{}, errors.New("invalid hex format")
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
		return primitives.Bytes{}, errors.New("invalid hex format")
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
		return primitives.U256{}, errors.New("value must be a valid number")
	}
	
	// Convert to U256
	return primitives.NewU256(val), nil
}