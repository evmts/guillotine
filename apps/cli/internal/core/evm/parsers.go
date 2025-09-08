package evm

import (
	"encoding/hex"
	"guillotine-cli/internal/types"
	"math/big"
	"strconv"
	"strings"

	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ParseEthereumAddress parses a hex string address into primitives.Address
func ParseEthereumAddress(addr string) (primitives.Address, error) {
	if !IsValidAddress(addr) {
		return primitives.Address{}, types.NewInputParamError(types.ErrorInvalidCallerAddress, "address")
	}
	
	// Use the SDK's built-in parser
	return primitives.AddressFromHex(addr)
}

// ParseWeiValue parses a decimal string to *big.Int
func ParseWeiValue(value string) (*big.Int, error) {
	val, err := strconv.ParseUint(value, 10, 64)
	if err != nil {
		return nil, types.NewInputParamError(types.ErrorInvalidValue, "value")
	}
	
	return big.NewInt(int64(val)), nil
}

// ParseHexData parses a hex string into bytes
func ParseHexData(data string) ([]byte, error) {
	if !IsValidHex(data) {
		return nil, types.NewInputParamError(types.ErrorInvalidInputData, "hex_data")
	}
	
	hexStr := strings.TrimPrefix(data, "0x")
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
	hexStr := addr[2:]
	if len(hexStr) != 40 {
		return false
	}
	for _, c := range hexStr {
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
	hexStr := data[2:]
	for _, c := range hexStr {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return false
		}
	}
	return true
}