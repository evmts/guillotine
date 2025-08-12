package main

import (
    "encoding/hex"
    "flag"
    "fmt"
    "math/big"
    "os"
    "strings"

    "github.com/ethereum/go-ethereum/common"
    "github.com/ethereum/go-ethereum/core/state"
    "github.com/ethereum/go-ethereum/core/types"
    "github.com/ethereum/go-ethereum/core/vm/runtime"
    "github.com/ethereum/go-ethereum/params"
    "github.com/holiman/uint256"
)

var callerAddress = common.HexToAddress("0x1000000000000000000000000000000000000001")
var contractAddress = common.HexToAddress("0x5FbDB2315678afecb367f032d93F642f64180aa3")

func main() {
	// Parse command line arguments
	var contractCodePath string
	var calldataHex string
	var numRuns int

	flag.StringVar(&contractCodePath, "contract-code-path", "", "Path to the hex contract code to deploy and run")
	flag.StringVar(&calldataHex, "calldata", "", "Hex of calldata to use when calling the contract")
	flag.IntVar(&numRuns, "num-runs", 1, "Number of times to run the benchmark")
	flag.IntVar(&numRuns, "n", 1, "Number of times to run the benchmark (short)")
	
	help := flag.Bool("help", false, "Print help information")
	helpShort := flag.Bool("h", false, "Print help information (short)")

	flag.Parse()

	if *help || *helpShort {
		fmt.Println("Geth EVM runner interface\n")
		fmt.Println("Usage: runner [OPTIONS]\n")
		fmt.Println("Options:")
		fmt.Println("  --contract-code-path <PATH>  Path to the hex contract code to deploy and run")
		fmt.Println("  --calldata <HEX>            Hex of calldata to use when calling the contract")
		fmt.Println("  -n, --num-runs <N>          Number of times to run the benchmark [default: 1]")
		fmt.Println("  -h, --help                  Print help information")
		os.Exit(0)
	}

	// Read contract code
	contractCodeBytes, err := os.ReadFile(contractCodePath)
	if err != nil {
		panic(fmt.Sprintf("Failed to read contract code: %v", err))
	}
	contractCodeHex := strings.TrimSpace(string(contractCodeBytes))
	contractCodeHex = strings.TrimPrefix(contractCodeHex, "0x")
	contractCode, err := hex.DecodeString(contractCodeHex)
	if err != nil {
		panic(fmt.Sprintf("Failed to decode contract code: %v", err))
	}

	// Decode calldata
	calldataHex = strings.TrimPrefix(calldataHex, "0x")
	calldata, err := hex.DecodeString(calldataHex)
	if err != nil {
		panic(fmt.Sprintf("Failed to decode calldata: %v", err))
	}

    // Use mainnet chain config as a proxy for latest supported rules
    chainConfig := params.MainnetChainConfig

    // Create state once and deploy runtime code once (apples-to-apples)
    statedb, _ := state.New(types.EmptyRootHash, state.NewDatabaseForTesting())
    statedb.CreateAccount(callerAddress)
    statedb.CreateAccount(contractAddress)
    statedb.SetBalance(callerAddress, uint256.MustFromBig(new(big.Int).Lsh(big.NewInt(1), 256-1)), 0) // Max balance

    cfg := runtime.Config{
        ChainConfig: chainConfig,
        Origin:      callerAddress,
        GasLimit:    1_000_000_000,
        GasPrice:    big.NewInt(1),
        Value:       big.NewInt(0),
        Difficulty:  big.NewInt(0),
        Time:        1_800_000_000, // ensure after Shanghai
        Coinbase:    common.Address{},
        BlockNumber: big.NewInt(20_000_000), // ensure after all fork blocks
        State:       statedb,
        BaseFee:     big.NewInt(7),
    }

    // Deploy once if input is initcode; if deployment returns runtime code and address, prefer that
    if len(contractCode) > 0 {
        if ret, createdAddr, _, err := runtime.Create(contractCode, &cfg); err == nil && len(ret) > 0 {
            // Use created address and runtime code
            contractAddress = createdAddr
        } else {
            // Otherwise, treat as runtime code at fixed address
            statedb.SetCode(contractAddress, contractCode)
        }
    }

    // Precompute selector for simple output sanity checks
    var selector uint32
    if len(calldata) >= 4 {
        selector = uint32(calldata[0])<<24 | uint32(calldata[1])<<16 | uint32(calldata[2])<<8 | uint32(calldata[3])
    }

    // Run the benchmark num_runs times (no redeploy)
    for i := 0; i < numRuns; i++ {
        ret, gasLeft, err := runtime.Call(contractAddress, calldata, &cfg)
        if err != nil {
            panic(fmt.Sprintf("Call failed: %v", err))
        }
        // Sanity: ensure gas was consumed
        const gasLimit uint64 = 1_000_000_000
        if gasLeft >= gasLimit {
            panic("Sanity failed: no gas consumed")
        }
        // Basic output validation aligned with other runners
        switch selector {
        case 0xa9059cbb, 0x095ea7b3, 0x40c10f19: // transfer/approve/mint -> 32-byte true
            if len(ret) < 32 || ret[len(ret)-1] != 1 {
                panic("Unexpected boolean return (expected 32-byte true)")
            }
        case 0x30627b7c: // TenThousandHashes.Benchmark()
            if len(ret) != 0 {
                panic("Unexpected output for Benchmark()")
            }
        }
        _ = ret
    }
}