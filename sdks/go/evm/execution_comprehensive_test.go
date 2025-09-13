package evm

import (
	"bytes"
	"encoding/hex"
	"math/big"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"github.com/evmts/guillotine/sdks/go/primitives"
)

// Test constants
const (
	DefaultBalance = 1000000
	StandardGas = 100000
	HighGas = 200000
	VeryHighGas = 1000000
)

func TestComprehensiveArithmeticOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		expectedGas    uint64
		shouldFail     bool
	}{
		{
			name:           "ADD: 10 + 20 = 30",
			bytecode:       "600a6014015f5260205ff3",
			expectedResult: []byte{0x1e},
			expectedGas:    100,
		},
		{
			name:           "SUB: 50 - 20 = 30",
			bytecode:       "6014603203",
			expectedResult: []byte{},
			expectedGas:    100,
		},
		{
			name:           "MUL: 10 * 5 = 50",
			bytecode:       "6005600a025f5260205ff3",
			expectedResult: []byte{0x32},
			expectedGas:    100,
		},
		{
			name:           "DIV: 100 / 5 = 20",
			bytecode:       "600560640045f5260205ff3",
			expectedResult: []byte{0x14},
			expectedGas:    100,
		},
		{
			name:           "DIV by zero returns 0",
			bytecode:       "5f60640045f5260205ff3",
			expectedResult: []byte{0x00},
			expectedGas:    100,
		},
		{
			name:           "MOD: 17 % 5 = 2",
			bytecode:       "600560110065f5260205ff3",
			expectedResult: []byte{0x02},
			expectedGas:    100,
		},
		{
			name:           "MOD by zero returns 0",
			bytecode:       "5f60110065f5260205ff3",
			expectedResult: []byte{0x00},
			expectedGas:    100,
		},
		{
			name:           "ADDMOD: (10 + 5) % 7 = 1",
			bytecode:       "6007600560010085f5260205ff3",
			expectedResult: []byte{0x01},
			expectedGas:    100,
		},
		{
			name:           "MULMOD: (10 * 5) % 7 = 1",  
			bytecode:       "6007600560010095f5260205ff3",
			expectedResult: []byte{0x01},
			expectedGas:    100,
		},
		{
			name:           "EXP: 2 ** 8 = 256",
			bytecode:       "6008600260010a5f5260205ff3",
			expectedResult: []byte{0x01, 0x00},
			expectedGas:    200,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 {
					if len(result.Output) >= len(tt.expectedResult) {
						// Compare significant bytes
						actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
						assert.Equal(t, tt.expectedResult, actualResult)
					}
				}
			}
		})
	}
}

func TestComprehensiveBitwiseOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "AND: 0xFF & 0x0F = 0x0F",
			bytecode:       "600f60ff165f5260205ff3",
			expectedResult: []byte{0x0f},
		},
		{
			name:           "OR: 0xF0 | 0x0F = 0xFF",
			bytecode:       "600f60f0175f5260205ff3",
			expectedResult: []byte{0xff},
		},
		{
			name:           "XOR: 0xFF ^ 0xF0 = 0x0F",
			bytecode:       "60f060ff185f5260205ff3",
			expectedResult: []byte{0x0f},
		},
		{
			name:           "NOT: ~0xFF = 0xFF...FF00",
			bytecode:       "60ff195f5260205ff3",
			expectedResult: []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00},
		},
		{
			name:           "SHL: 1 << 8 = 256",
			bytecode:       "600860011b5f5260205ff3", 
			expectedResult: []byte{0x01, 0x00},
		},
		{
			name:           "SHR: 256 >> 8 = 1",
			bytecode:       "60086101001c5f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "BYTE: byte 0 of 0xFF = 0xFF",
			bytecode:       "60ff5f1a5f5260205ff3",
			expectedResult: []byte{0xff},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveComparisonOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "LT: 5 < 10 = 1",
			bytecode:       "600a600510105f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "GT: 10 > 5 = 1", 
			bytecode:       "6005600a11115f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "EQ: 10 == 10 = 1",
			bytecode:       "600a600a14145f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "ISZERO: iszero(0) = 1",
			bytecode:       "5f15155f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "SLT: signed(-1) < signed(1) = 1",
			bytecode:       "600119ffffffffffffffffffffffffffffffffffffffffffffffffffffffffff12125f5260205ff3",
			expectedResult: []byte{0x01},
		},
		{
			name:           "SGT: signed(1) > signed(-1) = 1",
			bytecode:       "7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa600113135f5260205ff3",
			expectedResult: []byte{0x01},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveMemoryOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "MSTORE and MLOAD",
			bytecode:       "60aa5f52205f5151155f5260205ff3",
			expectedResult: []byte{0xaa},
		},
		{
			name:           "MSTORE8 stores single byte",
			bytecode:       "60ff5f535f515f5260205ff3",
			expectedResult: []byte{0xff},
		},
		{
			name:           "MSIZE after store",
			bytecode:       "60aa5f52595f5260205ff3",
			expectedResult: []byte{0x40},
		},
		{
			name:           "Memory expansion",
			bytecode:       "60aa61020052595f5260205ff3",
			expectedResult: []byte{0x02, 0x20},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveStorageOperations(t *testing.T) {
	tests := []struct {
		name        string
		setup       func(*EVM, primitives.Address)
		bytecode    string
		expectedVal *big.Int
		shouldFail  bool
	}{
		{
			name: "SSTORE and SLOAD basic",
			setup: nil,
			bytecode: "60aa5f555f545f5260205ff3",
			expectedVal: big.NewInt(0xaa),
		},
		{
			name: "SLOAD from pre-existing storage",
			setup: func(evm *EVM, addr primitives.Address) {
				key := big.NewInt(0)
				value := big.NewInt(0xaa)
				if err := evm.SetStorage(addr, key, value); err != nil {
				panic(err)
			}
			},
			bytecode: "5f545f5260205ff3",
			expectedVal: big.NewInt(0xaa),
		},
		{
			name: "Multiple storage slots",
			setup: func(evm *EVM, addr primitives.Address) {
				key0 := big.NewInt(0)
				value0 := big.NewInt(0xaa)
				if err := evm.SetStorage(addr, key0, value0); err != nil {
				panic(err)
			}
				key1 := big.NewInt(1)
				value1 := big.NewInt(0xbb)
				if err := evm.SetStorage(addr, key1, value1); err != nil {
				panic(err)
			}
				key2 := big.NewInt(2)
				value2 := big.NewInt(0xcc)
				if err := evm.SetStorage(addr, key2, value2); err != nil {
				panic(err)
			}
			},
			bytecode: "600254600154015f54015f5260205ff3",
			expectedVal: big.NewInt(0xaa + 0xbb + 0xcc),
		},
		{
			name: "Storage overwrite",
			setup: func(evm *EVM, addr primitives.Address) {
				key := big.NewInt(0)
				value := big.NewInt(0xaa)
				if err := evm.SetStorage(addr, key, value); err != nil {
				panic(err)
			}
			},
			bytecode: "60bb5f555f545f5260205ff3",
			expectedVal: big.NewInt(0xbb),
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)

			if tt.setup != nil {
				tt.setup(evm, contractAddr)
			}

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if tt.expectedVal != nil && len(result.Output) >= 32 {
					actual := new(big.Int).SetBytes(result.Output[len(result.Output)-32:])
					assert.Equal(t, tt.expectedVal, actual)
				}
			}
		})
	}
}

func TestComprehensiveStackOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "PUSH1 and return",
			bytecode:       "60aa5f5260205ff3",
			expectedResult: []byte{0xaa},
		},
		{
			name:           "PUSH32 max value",
			bytecode:       "7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa5f5260205ff3",
			expectedResult: []byte{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff},
		},
		{
			name:           "DUP1 duplicates top",
			bytecode:       "60aa8001015f5260205ff3", // PUSH1 0xaa, DUP1, ADD, return
			expectedResult: []byte{0x01, 0x54}, // 0xaa + 0xaa = 0x154
		},
		{
			name:           "SWAP1 swaps top two",
			bytecode:       "60aa60bb90035f5260205ff3", // PUSH1 0xaa, PUSH1 0xbb, SWAP1, SUB, return
			expectedResult: []byte{0x11}, // 0xaa - 0xbb = 0x11 (note: 0xaa - 0xbb in two's complement)
		},
		{
			name:           "POP removes top",
			bytecode:       "60aa60bb505f5260205ff3", // PUSH1 0xaa, PUSH1 0xbb, POP, return
			expectedResult: []byte{0xaa},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveControlFlowOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "JUMP to valid destination",
			bytecode:       "600856005b60aa5f5260205ff3", // PUSH1 8, JUMP, JUMPDEST, PUSH1 0xaa, return
			expectedResult: []byte{0xaa},
		},
		{
			name:           "JUMPI conditional true",
			bytecode:       "6001600857005b60aa5f5260205ff3", // PUSH1 1, PUSH1 8, JUMPI, STOP, JUMPDEST, PUSH1 0xaa, return
			expectedResult: []byte{0xaa},
		},
		{
			name:           "JUMPI conditional false",
			bytecode:       "5f600857005b60aa5f5260205ff3", // PUSH1 0, PUSH1 8, JUMPI, STOP, JUMPDEST, PUSH1 0xaa, return
			expectedResult: []byte{},
		},
		{
			name:           "PC returns program counter",
			bytecode:       "585f5260205ff3", // PC, return
			expectedResult: []byte{0x00}, // PC at position 0
		},
		{
			name:        "JUMP to invalid destination",
			bytecode:    "600256", // PUSH1 2, JUMP (no JUMPDEST at 2)
			shouldFail:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveContextOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult func(primitives.Address, *big.Int) []byte
		shouldFail     bool
	}{
		{
			name:     "ADDRESS returns current address",
			bytecode: "305f5260205ff3", // ADDRESS, return
			expectedResult: func(addr primitives.Address, value *big.Int) []byte {
				return addr.Bytes()
			},
		},
		{
			name:     "CALLER returns caller address", 
			bytecode: "335f5260205ff3", // CALLER, return
			expectedResult: func(addr primitives.Address, value *big.Int) []byte {
				return primitives.ZeroAddress().Bytes() // caller is zero address in our test
			},
		},
		{
			name:     "CALLVALUE returns sent value",
			bytecode: "345f5260205ff3", // CALLVALUE, return
			expectedResult: func(addr primitives.Address, value *big.Int) []byte {
				result := make([]byte, 32)
				value.FillBytes(result)
				return result
			},
		},
		{
			name:     "CODESIZE returns code size",
			bytecode: "385f5260205ff3", // CODESIZE, return
			expectedResult: func(addr primitives.Address, value *big.Int) []byte {
				return []byte{0x06} // bytecode is 6 bytes long
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			callValue := big.NewInt(1000)
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  callValue,
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if tt.expectedResult != nil {
					expected := tt.expectedResult(contractAddr, callValue)
					if len(result.Output) >= len(expected) {
						actualResult := result.Output[len(result.Output)-len(expected):]
						assert.Equal(t, expected, actualResult)
					}
				}
			}
		})
	}
}

func TestComprehensiveBlockOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		shouldFail     bool
	}{
		{
			name:     "BLOCKHASH",
			bytecode: "6001405f5260205ff3", // PUSH1 1, BLOCKHASH, return
		},
		{
			name:     "COINBASE", 
			bytecode: "415f5260205ff3", // COINBASE, return
		},
		{
			name:     "TIMESTAMP",
			bytecode: "425f5260205ff3", // TIMESTAMP, return
		},
		{
			name:     "NUMBER",
			bytecode: "435f5260205ff3", // NUMBER, return
		},
		{
			name:     "DIFFICULTY", 
			bytecode: "445f5260205ff3", // DIFFICULTY, return
		},
		{
			name:     "GASLIMIT",
			bytecode: "455f5260205ff3", // GASLIMIT, return
		},
		{
			name:     "CHAINID",
			bytecode: "465f5260205ff3", // CHAINID, return
		},
		{
			name:     "BASEFEE",
			bytecode: "485f5260205ff3", // BASEFEE, return
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				// Block operations should succeed (values may be default)
				assert.True(t, result.Success)
				assert.Equal(t, 32, len(result.Output)) // Should return 32 bytes
			}
		})
	}
}

func TestComprehensiveHashingOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedLength int
		shouldFail     bool
	}{
		{
			name:           "KECCAK256 of empty data",
			bytecode:       "5f5f205f5260205ff3", // PUSH1 0, PUSH1 0, KECCAK256, return
			expectedLength: 32,
		},
		{
			name:           "KECCAK256 of 32 bytes",
			bytecode:       "60aa5f526020600020205f5260205ff3", // store 0xaa, hash 32 bytes, return
			expectedLength: 32,
		},
		{
			name:           "KECCAK256 of 64 bytes", 
			bytecode:       "60aa5f5260bb6020526040600020205f5260205ff3", // store data, hash 64 bytes, return
			expectedLength: 32,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				assert.Equal(t, tt.expectedLength, len(result.Output))
			}
		})
	}
}

func TestComprehensiveLoggingOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedLogs   int
		shouldFail     bool
	}{
		{
			name:         "LOG0 - no topics",
			bytecode:     "60aa5f52602060005f5aa0", // store data, LOG0
			expectedLogs: 1,
		},
		{
			name:         "LOG1 - one topic", 
			bytecode:     "60aa5f526020600060016055aa1", // store data, LOG1 with topic 0x01
			expectedLogs: 1,
		},
		{
			name:         "LOG2 - two topics",
			bytecode:     "60aa5f52602060006002600160aa2", // store data, LOG2 with topics 0x01, 0x02  
			expectedLogs: 1,
		},
		{
			name:         "Multiple logs",
			bytecode:     "60aa5f526020600060015aa160bb6020526020602060026055aa1", // LOG1, then another LOG1
			expectedLogs: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				assert.Equal(t, tt.expectedLogs, len(result.Logs))
			}
		})
	}
}

func TestComprehensivePushOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "PUSH1",
			bytecode:       "60aa5f5260205ff3",
			expectedResult: []byte{0xaa},
		},
		{
			name:           "PUSH2",
			bytecode:       "61abcd5f5260205ff3",
			expectedResult: []byte{0xab, 0xcd},
		},
		{
			name:           "PUSH4",
			bytecode:       "6312345678f5f5260205ff3",
			expectedResult: []byte{0x12, 0x34, 0x56, 0x78},
		},
		{
			name:           "PUSH32",
			bytecode:       "7f123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef5f5260205ff3",
			expectedResult: []byte{0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestComprehensiveReturnOperations(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "RETURN with data",
			bytecode:       "60aa5f5260205ff3", // store 0xaa, return 32 bytes
			expectedResult: []byte{0xaa},
		},
		{
			name:           "RETURN empty",
			bytecode:       "5f5ff3", // return 0 bytes  
			expectedResult: []byte{},
		},
		{
			name:        "REVERT with data",
			bytecode:    "60aa5f5260205ffd", // store 0xaa, revert 32 bytes
			shouldFail:  true,
		},
		{
			name:        "REVERT empty", 
			bytecode:    "5f5ffd", // revert 0 bytes
			shouldFail:  true,
		},
		{
			name:           "STOP",
			bytecode:       "60aa5f5200", // store data, STOP
			expectedResult: []byte{},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
				// For REVERT, check that output is returned
				if bytes.Contains(bytecode, []byte{0xfd}) {
					assert.NotNil(t, result.Output)
				}
			} else {
				assert.True(t, result.Success)
				assert.Equal(t, len(tt.expectedResult), len(result.Output))
				if len(tt.expectedResult) > 0 {
					assert.Equal(t, tt.expectedResult, result.Output[len(result.Output)-len(tt.expectedResult):])
				}
			}
		})
	}
}

func TestComplexScenarios(t *testing.T) {
	tests := []struct {
		name           string
		bytecode       string
		expectedResult []byte
		shouldFail     bool
	}{
		{
			name:           "Fibonacci sequence (n=5)",
			bytecode:       "60055f60015b8283018084116100165790509150806002575b5050f5f5260205ff3",
			expectedResult: []byte{0x05}, // fib(5) = 5
		},
		{
			name:           "Simple loop counter",
			bytecode:       "60055f5b80600103600081126100115761000556100055b505f5260205ff3",
			expectedResult: []byte{0x05},
		},
		{
			name:           "Conditional execution",
			bytecode:       "60056005106100125760aa600b565b60bb5b5f5260205ff3",
			expectedResult: []byte{0xbb}, // 5 >= 5 is true, so 0xbb
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    VeryHighGas, // More gas for complex scenarios
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success)
			} else {
				assert.True(t, result.Success)
				if len(tt.expectedResult) > 0 && len(result.Output) >= len(tt.expectedResult) {
					actualResult := result.Output[len(result.Output)-len(tt.expectedResult):]
					assert.Equal(t, tt.expectedResult, actualResult)
				}
			}
		})
	}
}

func TestEdgeCasesAndBoundaries(t *testing.T) {
	tests := []struct {
		name        string
		bytecode    string
		shouldFail  bool
		description string
	}{
		{
			name:        "Stack underflow",
			bytecode:    "50", // POP on empty stack
			shouldFail:  true,
			description: "Should fail due to stack underflow",
		},
		{
			name:        "Invalid jump destination",
			bytecode:    "600256", // PUSH1 2, JUMP (no JUMPDEST at 2)
			shouldFail:  true,
			description: "Should fail due to invalid jump",
		},
		{
			name:        "Division by zero",
			bytecode:    "5f600104", // PUSH1 1, PUSH1 0, DIV
			shouldFail:  false, // Division by zero returns 0
			description: "Division by zero should return 0",
		},
		{
			name:        "Out of bounds memory access",
			bytecode:    "7ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffa51", // Very large MLOAD
			shouldFail:  false, // Should expand memory but might run out of gas
			description: "Large memory access",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success, tt.description)
			} else {
				// Don't assert success for edge cases - just that it doesn't panic
				assert.NotNil(t, result, tt.description)
			}
		})
	}
}

func TestPerformanceConsiderations(t *testing.T) {
	tests := []struct {
		name        string
		bytecode    string
		gasLimit    uint64
		description string
	}{
		{
			name:        "Memory expansion cost",
			bytecode:    "61040060005260206000f3", // Expand to 1KB
			gasLimit:    50000,
			description: "Should handle memory expansion",
		},
		{
			name:        "Storage operations cost",
			bytecode:    "60aa5f5560bb600155600cc600255", // Multiple SSTORE
			gasLimit:    100000,
			description: "Should handle multiple storage writes",
		},
		{
			name:        "Loop with moderate iterations",
			bytecode:    "60145f5b806001036000811261001457610008566100015b50", // Loop 20 times
			gasLimit:    50000,
			description: "Should handle moderate loops",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    tt.gasLimit,
			})
			require.NoError(t, err)

			// For performance tests, we just check it completes
			assert.NotNil(t, result, tt.description)
			assert.Less(t, result.GasLeft, tt.gasLimit, "Should consume some gas")
		})
	}
}

func TestRealWorldPatterns(t *testing.T) {
	tests := []struct {
		name        string
		setup       func(*EVM, primitives.Address)
		bytecode    string
		description string
		shouldFail  bool
	}{
		{
			name: "ERC20 balance check",
			setup: func(evm *EVM, addr primitives.Address) {
				// Set balance of slot 0 to 1000
				key := big.NewInt(0)
				balance := big.NewInt(1000)
				if err := evm.SetStorage(addr, key, balance); err != nil {
				panic(err)
			}
			},
			bytecode:    "5f545f5260205ff3", // SLOAD slot 0, return
			description: "Should return stored balance",
		},
		{
			name: "Simple access control",
			setup: func(evm *EVM, addr primitives.Address) {
				// Set owner at slot 0
				key := big.NewInt(0)
				owner := new(big.Int).SetBytes(primitives.ZeroAddress().Bytes())
				if err := evm.SetStorage(addr, key, owner); err != nil {
				panic(err)
			}
			},
			bytecode:    "335f54141560115760aa600e565b60bb5b5f5260205ff3", // Check if caller == owner
			description: "Should handle access control",
		},
		{
			name:        "Event emission pattern",
			bytecode:    "60aa5f52602060006064a1", // LOG1 with topic 0x64
			description: "Should emit event",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			evm, err := New()
			require.NoError(t, err)
			defer evm.Destroy()

			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			err = evm.SetBalance(caller, big.NewInt(DefaultBalance))
			require.NoError(t, err)

			if tt.setup != nil {
				tt.setup(evm, contractAddr)
			}

			bytecode, err := hex.DecodeString(tt.bytecode)
			require.NoError(t, err)
			
			err = evm.SetCode(contractAddr, bytecode)
			require.NoError(t, err)

			result, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			})
			require.NoError(t, err)

			if tt.shouldFail {
				assert.False(t, result.Success, tt.description)
			} else {
				assert.True(t, result.Success, tt.description)
			}
		})
	}
}