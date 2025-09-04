package evm

import (
	"encoding/hex"
	"guillotine-cli/internal/types"
	"strconv"
	"strings"

	"github.com/evmts/guillotine/bindings/go/primitives"
)

// ParseEthereumAddress parses a hex string address into primitives.Address
func ParseEthereumAddress(addr string) (primitives.Address, error) {
	if !IsValidAddress(addr) {
		return primitives.Address{}, types.NewInputParamError(types.ErrorInvalidCallerAddress, "address")
	}
	
	hexStr := addr[2:] // Remove 0x prefix
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return primitives.Address{}, err
	}
	
	var addrBytes [20]byte
	copy(addrBytes[:], bytes)
	return primitives.NewAddress(addrBytes), nil
}

// ParseWeiValue parses a decimal string to U256
func ParseWeiValue(value string) (primitives.U256, error) {
	val, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return primitives.U256{}, types.NewInputParamError(types.ErrorInvalidValue, "value")
	}
	
	return primitives.NewU256(val), nil
}

// ParseHexData parses a hex string into bytes
func ParseHexData(data string) ([]byte, error) {
	if !IsValidHex(data) {
		return nil, types.NewInputParamError(types.ErrorInvalidInputData, "hex_data")
	}
	
	hexStr := data[2:] // Remove 0x prefix
	if len(hexStr)%2 != 0 {
		hexStr = "0" + hexStr
	}
	
	bytes, err := hex.DecodeString(hexStr)
	if err != nil {
		return nil, err
	}
	
	return bytes, nil
}

// IsValidAddress checks if a string is a valid Ethereum address
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

// IsValidHex checks if a string is valid hex data
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