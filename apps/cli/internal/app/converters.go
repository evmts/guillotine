package app

import (
	"encoding/hex"
	"fmt"
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/persistence"
	"guillotine-cli/internal/types"
	"guillotine-cli/internal/utils"
	"strconv"
	"time"

	"github.com/evmts/guillotine/bindings/go/evm"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

// TypeConverter handles conversions between different types
type TypeConverter struct{}

// NewTypeConverter creates a new type converter
func NewTypeConverter() *TypeConverter {
	return &TypeConverter{}
}

// ConvertToEVMAddress converts a string address to primitives.Address
func (tc *TypeConverter) ConvertToEVMAddress(addr string) (primitives.Address, error) {
	return utils.ParseEthereumAddress(addr)
}

// ConvertToU256 converts a string value to primitives.U256
func (tc *TypeConverter) ConvertToU256(value string) (primitives.U256, error) {
	return utils.ParseWeiValue(value)
}

// ConvertToBytes converts hex string to primitives.Bytes
func (tc *TypeConverter) ConvertToBytes(data string) (primitives.Bytes, error) {
	bytes, err := utils.ParseHexData(data)
	if err != nil {
		return primitives.Bytes{}, err
	}
	return primitives.NewBytes(bytes), nil
}

// ConvertToGasLimit converts string to uint64 gas limit
func (tc *TypeConverter) ConvertToGasLimit(gasLimit string) (uint64, error) {
	gas, err := strconv.ParseUint(gasLimit, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid gas limit: %w", err)
	}
	return gas, nil
}

// ConvertSaltToU256 converts hex salt string to primitives.U256
func (tc *TypeConverter) ConvertSaltToU256(salt string) (primitives.U256, error) {
	saltBytes, err := utils.ParseHexData(salt)
	if err != nil {
		return primitives.U256{}, fmt.Errorf("invalid salt: %w", err)
	}
	
	var u256Bytes [32]byte
	copy(u256Bytes[32-len(saltBytes):], saltBytes)
	
	u256, err := primitives.U256FromBytes(u256Bytes[:])
	if err != nil {
		return primitives.U256{}, fmt.Errorf("invalid salt: %w", err)
	}
	
	return u256, nil
}

// ConvertCallType converts string to evm.CallType
func (tc *TypeConverter) ConvertCallType(callType string) evm.CallType {
	return config.CallTypeFromString(callType)
}

// ConvertFromCallParameters converts types.CallParameters to persistence.PersistedCall
func (tc *TypeConverter) ConvertFromCallParameters(params types.CallParameters) persistence.PersistedCall {
	return persistence.PersistedCall{
		CallType:  params.CallType,
		Caller:    params.Caller,
		Target:    params.Target,
		Value:     params.Value,
		GasLimit:  params.GasLimit,
		InputData: params.InputData,
		Salt:      params.Salt,
		Timestamp: time.Now().Unix(),
	}
}

// ConvertToCallParameters converts persistence.PersistedCall to types.CallParameters
func (tc *TypeConverter) ConvertToCallParameters(call persistence.PersistedCall) types.CallParameters {
	return types.CallParameters{
		CallType:  call.CallType,
		Caller:    call.Caller,
		Target:    call.Target,
		Value:     call.Value,
		GasLimit:  call.GasLimit,
		InputData: call.InputData,
		Salt:      call.Salt,
	}
}

// ConvertAddressFromOutput extracts address from CREATE/CREATE2 output
func (tc *TypeConverter) ConvertAddressFromOutput(output primitives.Bytes) (string, error) {
	outputData := output.Data()
	if len(outputData) != 20 {
		return "", fmt.Errorf("invalid address output: expected 20 bytes, got %d", len(outputData))
	}
	return "0x" + hex.EncodeToString(outputData), nil
}