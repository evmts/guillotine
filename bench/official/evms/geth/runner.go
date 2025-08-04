package main

import (
	"encoding/hex"
	"flag"
	"fmt"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm/runtime"
	"github.com/ethereum/go-ethereum/params"
	"github.com/holiman/uint256"
)

var callerAddress = common.HexToAddress("0x1000000000000000000000000000000000000001")

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

	// Create runtime config with Shanghai support for PUSH0
	shanghaiTime := uint64(0)
	chainConfig := &params.ChainConfig{
		ChainID:                       big.NewInt(1),
		HomesteadBlock:                big.NewInt(0),
		EIP150Block:                   big.NewInt(0),
		EIP155Block:                   big.NewInt(0),
		EIP158Block:                   big.NewInt(0),
		ByzantiumBlock:                big.NewInt(0),
		ConstantinopleBlock:           big.NewInt(0),
		PetersburgBlock:               big.NewInt(0),
		IstanbulBlock:                 big.NewInt(0),
		MuirGlacierBlock:              big.NewInt(0),
		BerlinBlock:                   big.NewInt(0),
		LondonBlock:                   big.NewInt(0),
		ArrowGlacierBlock:             big.NewInt(0),
		GrayGlacierBlock:              big.NewInt(0),
		MergeNetsplitBlock:            big.NewInt(0),
		ShanghaiTime:                  &shanghaiTime, // Shanghai at genesis (supports PUSH0)
		TerminalTotalDifficulty:       big.NewInt(0),
	}
	
	// Note: We deploy fresh for each run to avoid state accumulation issues

	// Run the benchmark num_runs times
	for i := 0; i < numRuns; i++ {
		// Create fresh state for each run to avoid state accumulation issues
		freshStatedb, _ := state.New(types.EmptyRootHash, state.NewDatabaseForTesting())
		freshStatedb.CreateAccount(callerAddress)
		freshStatedb.SetBalance(callerAddress, uint256.MustFromBig(new(big.Int).Lsh(big.NewInt(1), 256-1)), 0) // Max balance
		
		// Create fresh config with the fresh state
		freshCfg := runtime.Config{
			ChainConfig: chainConfig,
			Origin:      callerAddress,
			GasLimit:    1_000_000_000,
			GasPrice:    big.NewInt(0),
			Value:       big.NewInt(0),
			Difficulty:  big.NewInt(0),
			Time:        1,
			Coinbase:    common.Address{},
			BlockNumber: big.NewInt(1),
			State:       freshStatedb,
		}
		
		// Deploy contract using bytecode directly as init code (like Guillotine does)
		_, freshContractAddr, _, err := runtime.Create(contractCode, &freshCfg)
		if err != nil {
			panic(fmt.Sprintf("Contract creation failed in run %d: %v", i, err))
		}
		
		// Start timing
		start := time.Now()
		
		// Call the deployed contract
		ret, _, err := runtime.Call(freshContractAddr, calldata, &freshCfg)

		// End timing
		duration := time.Since(start)
		durationMs := float64(duration.Nanoseconds()) / 1_000_000.0

		// Check for errors
		if err != nil {
			panic(fmt.Sprintf("Call failed: %v", err))
		}
		_ = ret // Ignore return value

	}
}