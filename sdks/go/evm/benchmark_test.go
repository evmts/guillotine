package evm

import (
	"bytes"
	"encoding/hex"
	"fmt"
	"math/big"
	"testing"

	"github.com/evmts/guillotine/sdks/go/primitives"
)


func BenchmarkArithmeticOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"ADD", "600a6014015f5260205ff3"},
		{"SUB", "6014600a035f5260205ff3"},
		{"MUL", "600a6014025f5260205ff3"},
		{"DIV", "6014600a045f5260205ff3"},
		{"MOD", "6014600a065f5260205ff3"},
		{"EXP", "600260080a5f5260205ff3"},
		{"ADDMOD", "6007600a6014085f5260205ff3"},
		{"MULMOD", "6007600a6005095f5260205ff3"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkBitwiseOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"AND", "600f60ff165f5260205ff3"},
		{"OR", "600f60f0175f5260205ff3"},
		{"XOR", "60f060ff185f5260205ff3"},
		{"NOT", "60ff195f5260205ff3"},
		{"SHL", "600160081b5f5260205ff3"},
		{"SHR", "61010060081c5f5260205ff3"},
		{"BYTE", "60ff60001a5f5260205ff3"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkMemoryOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"MSTORE_32", "60aa5f525f5360206000f3"},
		{"MSTORE8", "60ff5f535f60015360016000f3"},
		{"MLOAD", "60aa5f52205f5360206000f3"},
		{"MCOPY_32", "60aa5f5260205f60205e60206020f3"},
		{"MSIZE", "60aa5f5259"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkStorageOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
		setup    func(*EVM, primitives.Address)
	}{
		{
			name:     "SSTORE_cold",
			bytecode: "60aa5f55",
			setup:    nil,
		},
		{
			name:     "SSTORE_warm",
			bytecode: "60bb5f55",
			setup: func(evm *EVM, addr primitives.Address) {
				key := big.NewInt(0)
				value := big.NewInt(0xaa)
				if err := evm.SetStorage(addr, key, value); err != nil {
					panic(err)
				}
			},
		},
		{
			name:     "SLOAD_cold",
			bytecode: "5f54",
			setup:    nil,
		},
		{
			name:     "SLOAD_warm",
			bytecode: "5f545f54",
			setup: func(evm *EVM, addr primitives.Address) {
				key := big.NewInt(0)
				value := big.NewInt(0xaa)
				if err := evm.SetStorage(addr, key, value); err != nil {
					panic(err)
				}
			},
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				evm, _ := New()
				caller := primitives.ZeroAddress()
				contractAddr := primitives.NewAddress([20]byte{0x01})
				
				if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
				if err := evm.SetCode(contractAddr, bytecode); err != nil {
					panic(err)
				}
				
				if bm.setup != nil {
					bm.setup(evm, contractAddr)
				}
				
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
				evm.Destroy()
			}
		})
	}
}

func BenchmarkStackOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"PUSH1", "60aa"},
		{"PUSH32", "7f0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},
		{"POP", "60aa50"},
		{"DUP1", "60aa80"},
		{"DUP16", "6001600260036004600560066007600860096000a6000b6000c6000d6000e6000f60108f"},
		{"SWAP1", "60aa60bb90"},
		{"SWAP16", "6001600260036004600560066007600860096000a6000b6000c6000d6000e6000f60106011901f"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkControlFlow(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"JUMP", "600456005b60aa"},
		{"JUMPI_true", "6001600657005b60aa"},
		{"JUMPI_false", "5f600657005b60aa"},
		{"PC", "58"},
		{"JUMPDEST", "5b"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkKeccak256(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{"KECCAK_0", "5f5f20"},
		{"KECCAK_32", "60aa5f5260205f20"},
		{"KECCAK_64", "60aa5f5260bb60205260405f20"},
		{"KECCAK_128", "60aa5f5260bb60205260cc60405260dd60605260805f20"},
		{"KECCAK_256", "7f0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef5f527f0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef6020527ffedcba9876543210fedcba9876543210fedcba9876543210fedcba98765432106040527ffedcba9876543210fedcba9876543210fedcba9876543210fedcba987654321060605261010060002000"},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkCallOperations(b *testing.B) {
	benchmarks := []struct {
		name     string
		setup    func() (*EVM, primitives.Address, primitives.Address)
	}{
		{
			name: "CALL_simple",
			setup: func() (*EVM, primitives.Address, primitives.Address) {
				evm, _ := New()
				callerAddr := primitives.NewAddress([20]byte{0x01})
				calleeAddr := primitives.NewAddress([20]byte{0x02})
				balance := big.NewInt(LargeBalance)
				if err := evm.SetBalance(callerAddr, balance); err != nil {
					panic(err)
				}
				calleeCode := []byte{0x60, 0xaa, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
				if err := evm.SetCode(calleeAddr, calleeCode); err != nil {
					panic(err)
				}
				return evm, callerAddr, calleeAddr
			},
		},
		{
			name: "DELEGATECALL",
			setup: func() (*EVM, primitives.Address, primitives.Address) {
				evm, _ := New()
				callerAddr := primitives.NewAddress([20]byte{0x03})
				delegateAddr := primitives.NewAddress([20]byte{0x04})
				balance := big.NewInt(LargeBalance)
				if err := evm.SetBalance(callerAddr, balance); err != nil {
					panic(err)
				}
				delegateCode := []byte{0x60, 0xbb, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
				if err := evm.SetCode(delegateAddr, delegateCode); err != nil {
					panic(err)
				}
				return evm, callerAddr, delegateAddr
			},
		},
		{
			name: "STATICCALL",
			setup: func() (*EVM, primitives.Address, primitives.Address) {
				evm, _ := New()
				callerAddr := primitives.NewAddress([20]byte{0x05})
				staticAddr := primitives.NewAddress([20]byte{0x06})
				balance := big.NewInt(LargeBalance)
				if err := evm.SetBalance(callerAddr, balance); err != nil {
					panic(err)
				}
				staticCode := []byte{0x60, 0xcc, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}
				if err := evm.SetCode(staticAddr, staticCode); err != nil {
					panic(err)
				}
				return evm, callerAddr, staticAddr
			},
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				evm, caller, target := bm.setup()
				switch bm.name {
				case "CALL_simple":
					if _, err := evm.Call(Call{
						Caller: caller,
						To:     target,
						Value:  big.NewInt(0),
						Input:  []byte{},
						Gas:    StandardGas,
					}); err != nil {
						panic(err)
					}
				case "DELEGATECALL":
					if _, err := evm.Call(Delegatecall{
						Caller: caller,
						To:     target,
						Input:  []byte{},
						Gas:    StandardGas,
					}); err != nil {
						panic(err)
					}
				case "STATICCALL":
					if _, err := evm.Call(Staticcall{
						Caller: caller,
						To:     target,
						Input:  []byte{},
						Gas:    StandardGas,
					}); err != nil {
						panic(err)
					}
				}
				evm.Destroy()
			}
		})
	}
}

func BenchmarkContractCreation(b *testing.B) {
	benchmarks := []struct {
		name     string
		initCode []byte
		salt     *big.Int
		isCreate2 bool
	}{
		{"CREATE_empty", []byte{}, nil, false},
		{"CREATE_simple", []byte{0x60, 0x80, 0x60, 0x40, 0x52, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}, nil, false},
		{"CREATE2_empty", []byte{}, big.NewInt(0), true},
		{"CREATE2_simple", []byte{0x60, 0x80, 0x60, 0x40, 0x52, 0x5f, 0x52, 0x60, 0x20, 0x5f, 0xf3}, big.NewInt(1), true},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				evm, _ := New()
				addr := primitives.NewAddress([20]byte{byte(i)})
				balance := big.NewInt(LargeBalance)
				if err := evm.SetBalance(addr, balance); err != nil {
					panic(err)
				}
				
				if bm.isCreate2 {
					if _, err := evm.Call(Create2{
						Caller:   addr,
						Value:    big.NewInt(0),
						InitCode: bm.initCode,
						Salt:     bm.salt,
						Gas:      HighGas,
					}); err != nil {
						panic(err)
					}
				} else {
					if _, err := evm.Call(Create{
						Caller:   addr,
						Value:    big.NewInt(0),
						InitCode: bm.initCode,
						Gas:      HighGas,
					}); err != nil {
						panic(err)
					}
				}
				evm.Destroy()
			}
		})
	}
}

func BenchmarkComplexScenarios(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{
			name:     "Fibonacci_10",
			bytecode: "600a5f60015b8283018084116100165790509150806002575b5050",
		},
		{
			name:     "Loop_100",
			bytecode: "60645f5b8060010360008112610014576100085661001a565b50",
		},
		{
			name:     "ERC20_transfer",
			bytecode: "60646000546103e8900360005560646001546103e8010160015560206000f3",
		},
		{
			name:     "Memory_expansion_1KB",
			bytecode: "61040060005260206000f3",
		},
		{
			name:     "Storage_10_writes",
			bytecode: "60015f5560026001556003600255600460035560056004556006600555600760065560086007556009600855600a600955",
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, err := New()
			if err != nil {
				panic(err)
			}
			defer evm.Destroy()
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    VeryHighGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}

func BenchmarkGasIntensive(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode []byte
	}{
		{
			name:     "SSTORE_cold_10",
			bytecode: func() []byte {
				bc, _ := hex.DecodeString("60015f5560026001556003600255600460035560056004556006600555600760065560086007556009600855600a600955")
				return bc
			}(),
		},
		{
			name: "KECCAK_large",
			bytecode: func() []byte {
				bytecode := bytes.Repeat([]byte{0x60, 0xaa}, 512)
				bytecode = append(bytecode, []byte{0x61, 0x10, 0x00, 0x5f, 0x20}...)
				return bytecode
			}(),
		},
		{
			name: "Memory_10MB",
			bytecode: func() []byte {
				bc, _ := hex.DecodeString("7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff6298968052")
				return bc
			}(),
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				evm, _ := New()
				caller := primitives.ZeroAddress()
				contractAddr := primitives.NewAddress([20]byte{0x01})
				
				if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
				if err := evm.SetCode(contractAddr, bm.bytecode); err != nil {
					panic(err)
				}
				
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    ExtremeGas,
				}); err != nil {
					panic(err)
				}
				evm.Destroy()
			}
		})
	}
}

func BenchmarkRealWorldContracts(b *testing.B) {
	benchmarks := []struct {
		name  string
		setup func() ([]byte, *EVM, primitives.Address)
	}{
		{
			name: "UniswapV2_swap",
			setup: func() ([]byte, *EVM, primitives.Address) {
				evm, _ := New()
				reserve0Slot := big.NewInt(0)
				reserve1Slot := big.NewInt(1)
				reserve0 := big.NewInt(DefaultBalance)
				reserve1 := big.NewInt(2000000)
				addr := primitives.NewAddress([20]byte{})
				if err := evm.SetStorage(addr, reserve0Slot, reserve0); err != nil {
					panic(err)
				}
				if err := evm.SetStorage(addr, reserve1Slot, reserve1); err != nil {
					panic(err)
				}
				bytecode, err := hex.DecodeString("5f5460015402619c40116100165761001c5661001c5b60016001555b")
				if err != nil {
					panic(err)
				}
				return bytecode, evm, addr
			},
		},
		{
			name: "ERC721_mint",
			setup: func() ([]byte, *EVM, primitives.Address) {
				evm, _ := New()
				totalSupplySlot := big.NewInt(0)
				currentSupply := big.NewInt(100)
				addr := primitives.NewAddress([20]byte{})
				if err := evm.SetStorage(addr, totalSupplySlot, currentSupply); err != nil {
					panic(err)
				}
				bytecode, err := hex.DecodeString("5f5460010160648111610019576001810190555f52602001f35bfd")
				if err != nil {
					panic(err)
				}
				return bytecode, evm, addr
			},
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				bytecode, evm, addr := bm.setup()
				caller := primitives.ZeroAddress()
				if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
				if err := evm.SetCode(addr, bytecode); err != nil {
					panic(err)
				}
				
				_, _ = evm.Call(Call{
					Caller: caller,
					To:     addr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    HighGas,
				})
				evm.Destroy()
			}
		})
	}
}

func BenchmarkParallelExecution(b *testing.B) {
	bytecode, err := hex.DecodeString("600a6014015f5260205ff3")
	if err != nil {
		panic(err)
	}
	
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			evm, _ := New()
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			if _, err := evm.Call(Call{
				Caller: caller,
				To:     contractAddr,
				Value:  big.NewInt(0),
				Input:  []byte{},
				Gas:    StandardGas,
			}); err != nil {
				panic(err)
			}
			evm.Destroy()
		}
	})
}

func BenchmarkMemoryAllocation(b *testing.B) {
	sizes := []int{32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384}
	
	for _, size := range sizes {
		b.Run(fmt.Sprintf("size_%d", size), func(b *testing.B) {
			bytecode := fmt.Sprintf("60aa%04x52", size)
			bc, _ := hex.DecodeString(bytecode)
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				evm, _ := New()
				caller := primitives.ZeroAddress()
				contractAddr := primitives.NewAddress([20]byte{0x01})
				
				if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
				if err := evm.SetCode(contractAddr, bc); err != nil {
					panic(err)
				}
				
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    StandardGas,
				}); err != nil {
					panic(err)
				}
				evm.Destroy()
			}
		})
	}
}

func BenchmarkCachePerformance(b *testing.B) {
	benchmarks := []struct {
		name     string
		bytecode string
	}{
		{
			name:     "Sequential_reads",
			bytecode: "5f545f545f545f545f545f545f545f54",
		},
		{
			name:     "Random_reads",
			bytecode: "5f546001546002546003546004546005546006546007546008546009545",
		},
		{
			name:     "Sequential_writes",
			bytecode: "60aa5f5560bb60015560cc60025560dd60035560ee60045560ff600555",
		},
		{
			name:     "Alternating_read_write",
			bytecode: "5f5460aa5f556001546001600155600254600260025560035460036003555",
		},
	}

	for _, bm := range benchmarks {
		b.Run(bm.name, func(b *testing.B) {
			evm, _ := New()
			defer evm.Destroy()
			
			caller := primitives.ZeroAddress()
			contractAddr := primitives.NewAddress([20]byte{0x01})
			
			if err := evm.SetBalance(caller, big.NewInt(DefaultBalance)); err != nil {
				panic(err)
			}
			
			for i := uint64(0); i < 10; i++ {
				slot := big.NewInt(int64(i))
				value := big.NewInt(int64(i * 10))
				if err := evm.SetStorage(contractAddr, slot, value); err != nil {
					panic(err)
				}
			}
			
			bytecode, err := hex.DecodeString(bm.bytecode)
			if err != nil {
				panic(err)
			}
			if err := evm.SetCode(contractAddr, bytecode); err != nil {
				panic(err)
			}
			
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				if _, err := evm.Call(Call{
					Caller: caller,
					To:     contractAddr,
					Value:  big.NewInt(0),
					Input:  []byte{},
					Gas:    VeryHighGas,
				}); err != nil {
					panic(err)
				}
			}
		})
	}
}