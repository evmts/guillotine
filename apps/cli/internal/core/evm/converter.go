package evm

import (
	"encoding/hex"
	"fmt"
	"math/big"
	"strconv"

	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ParseGasLimit converts string to uint64 gas limit
func ParseGasLimit(gasLimit string) (uint64, error) {
	gas, err := strconv.ParseUint(gasLimit, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid gas limit: %w", err)
	}
	return gas, nil
}

// ParseSalt converts hex salt string to *big.Int
func ParseSalt(salt string) (*big.Int, error) {
	if salt == "" || salt == "0x" || salt == "0x0" {
		return big.NewInt(0), nil
	}
	
	saltBytes, err := ParseHexData(salt)
	if err != nil {
		return nil, fmt.Errorf("invalid salt: %w", err)
	}
	
	return new(big.Int).SetBytes(saltBytes), nil
}

// ExtractCreatedAddress extracts address from CREATE/CREATE2 result
func ExtractCreatedAddress(createdAddr *primitives.Address) string {
	if createdAddr == nil {
		return ""
	}
	return createdAddr.Hex()
}

// FormatOutputData formats output bytes as hex string
func FormatOutputData(output []byte) string {
	if len(output) == 0 {
		return "0x"
	}
	return "0x" + hex.EncodeToString(output)
}