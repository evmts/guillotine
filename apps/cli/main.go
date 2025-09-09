package main

import (
	"encoding/hex"
	"fmt"
	"io"
	"math/big"
	"os"
	"strings"
	"time"

	"guillotine-cli/internal/app"
	"guillotine-cli/internal/compiler"

	tea "github.com/charmbracelet/bubbletea"
	guillotine "github.com/evmts/guillotine/sdks/go"
	"github.com/evmts/guillotine/sdks/go/evm"
	"github.com/evmts/guillotine/sdks/go/primitives"
	"github.com/urfave/cli/v2"
)

func main() {
	app := &cli.App{
		Name:  "guillotine-bench",
		Usage: "Guillotine EVM CLI and benchmarking tool",
		Action: func(c *cli.Context) error {
			return runTUI()
		},
		Commands: []*cli.Command{
			{
				Name:  "tui",
				Usage: "Launch interactive TUI",
				Action: func(c *cli.Context) error {
					return runTUI()
				},
			},
			{
				Name:  "run",
				Usage: "Execute EVM bytecode",
				Flags: []cli.Flag{
					&cli.StringFlag{
						Name:  "codefile",
						Usage: "Path to file containing bytecode (hex format)",
					},
					&cli.StringFlag{
						Name:     "gas",
						Usage:    "Gas limit for execution",
						Required: true,
					},
					&cli.StringFlag{
						Name:  "input",
						Usage: "Calldata/input data in hex format",
						Value: "",
					},
					&cli.BoolFlag{
						Name:  "deploy",
						Usage: "Deploy the bytecode first (for constructor bytecode)",
						Value: false,
					},
				},
				Action: func(c *cli.Context) error {
					return runBytecode(c)
				},
			},
			{
				Name:  "trace",
				Usage: "Execute and write JSON-RPC trace to a file (default: trace.json)",
				Flags: []cli.Flag{
					&cli.StringFlag{ Name: "bytecode", Usage: "Path to runtime bytecode hex (defaults to snailtracer runtime_clean.txt)", Value: "" },
					&cli.StringFlag{ Name: "calldata", Usage: "Path to calldata hex (defaults to snailtracer calldata.txt)", Value: "" },
					&cli.StringFlag{ Name: "out", Usage: "Output trace file", Value: "trace.json" },
					&cli.StringFlag{ Name: "gas", Usage: "Gas limit", Value: "10000000" },
				},
				Action: func(c *cli.Context) error {
					return runTrace(c)
				},
			},
			{
				Name:  "compile",
				Usage: "Compile Solidity source code",
				Flags: []cli.Flag{
					&cli.StringFlag{
						Name:     "source",
						Aliases:  []string{"s"},
						Usage:    "Solidity source code (inline)",
					},
					&cli.StringFlag{
						Name:     "file",
						Aliases:  []string{"f"},
						Usage:    "Path to Solidity source file",
					},
					&cli.StringFlag{
						Name:     "output",
						Aliases:  []string{"o"},
						Usage:    "Output file path (default: stdout)",
					},
					&cli.StringFlag{
						Name:    "format",
						Usage:   "Output format: json, hex, combined",
						Value:   "json",
					},
					&cli.BoolFlag{
						Name:    "optimize",
						Usage:   "Enable optimizer",
						Value:   true,
					},
					&cli.UintFlag{
						Name:    "optimize-runs",
						Usage:   "Optimizer runs",
						Value:   200,
					},
					&cli.StringFlag{
						Name:    "evm-version",
						Usage:   "EVM version (e.g., london, paris, shanghai)",
					},
				},
				Action: func(c *cli.Context) error {
					return runCompile(c)
				},
			},
		},
	}

	if err := app.Run(os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func runTUI() error {
	p := tea.NewProgram(app.InitialModel())
	if _, err := p.Run(); err != nil {
		return fmt.Errorf("error running Guillotine CLI: %w", err)
	}
	return nil
}

func runBytecode(c *cli.Context) error {
	var bytecode []byte
	var err error

	// Get bytecode from file or stdin
	codeFile := c.String("codefile")
	if codeFile != "" {
		// Read from file
		data, err := os.ReadFile(codeFile)
		if err != nil {
			return fmt.Errorf("failed to read codefile: %w", err)
		}
		bytecode, err = parseHex(string(data))
		if err != nil {
			return fmt.Errorf("invalid hex in codefile: %w", err)
		}
	} else {
		// Read from stdin
		data, err := io.ReadAll(os.Stdin)
		if err != nil {
			return fmt.Errorf("failed to read from stdin: %w", err)
		}
		if len(data) == 0 {
			return fmt.Errorf("no bytecode provided via --codefile or stdin")
		}
		bytecode, err = parseHex(string(data))
		if err != nil {
			return fmt.Errorf("invalid hex from stdin: %w", err)
		}
	}

	// Debug: Log what we got from file
	if codeFile != "" {
		fileData, _ := os.ReadFile(codeFile)
		fmt.Fprintf(os.Stderr, "Raw file length: %d chars\n", len(fileData))
		if len(fileData) > 0 {
			fmt.Fprintf(os.Stderr, "First 40 chars: %s\n", fileData[:min(40, len(fileData))])
			fmt.Fprintf(os.Stderr, "Last 40 chars: %s\n", fileData[max(0, len(fileData)-40):])
		}
	}
	
	// Debug: Log bytecode info
	fmt.Fprintf(os.Stderr, "Parsed bytecode length: %d bytes\n", len(bytecode))
	if len(bytecode) > 0 {
		fmt.Fprintf(os.Stderr, "First 20 bytes: %x\n", bytecode[:min(20, len(bytecode))])
		fmt.Fprintf(os.Stderr, "Last 20 bytes: %x\n", bytecode[max(0, len(bytecode)-20):])
	}
	
	// Parse gas limit
	gasStr := c.String("gas")
	if gasStr == "" {
		return fmt.Errorf("--gas is required")
	}
	var gas uint64
	if _, err := fmt.Sscanf(gasStr, "%d", &gas); err != nil {
		return fmt.Errorf("invalid gas limit: %w", err)
	}

	// Parse input data
	inputStr := c.String("input")
	var input []byte
	if inputStr != "" {
		input, err = parseHex(inputStr)
		if err != nil {
			return fmt.Errorf("invalid hex in input: %w", err)
		}
	}

	// Create EVM instance
	vm, err := evm.New()
	if err != nil {
		return fmt.Errorf("failed to create EVM: %w", err)
	}
	defer vm.Destroy()
	
	// Use a default caller address
	caller, err := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
	if err != nil {
		return fmt.Errorf("failed to create caller address: %w", err)
	}
	
	// Set caller balance to ensure execution
	if err := vm.SetBalance(caller, big.NewInt(1000000000000000000)); err != nil {
		return fmt.Errorf("failed to set caller balance: %w", err)
	}
	
	var contractAddr primitives.Address
	var callResult *guillotine.CallResult
	
	if c.Bool("deploy") {
		// Deploy the bytecode first (treating it as constructor bytecode)
		fmt.Fprintf(os.Stderr, "Deploying bytecode (%d bytes)...\n", len(bytecode))
		
		// Start timing for deployment + execution
		start := time.Now()
		
		// Deploy the contract using Create
		deployResult, err := vm.Call(evm.Create{
			Caller:   caller,
			Value:    big.NewInt(0),
			InitCode: bytecode,
			Gas:      gas / 2, // Use half gas for deployment
		})
		
		if err != nil {
			return fmt.Errorf("deployment failed: %w", err)
		}
		
		if !deployResult.Success {
			return fmt.Errorf("deployment reverted: %s", deployResult.ErrorInfo)
		}
		
		if deployResult.CreatedAddress != nil {
			contractAddr = *deployResult.CreatedAddress
		} else {
			return fmt.Errorf("deployment succeeded but no address returned")
		}
		fmt.Fprintf(os.Stderr, "Contract deployed at: %s\n", contractAddr.Hex())
		fmt.Fprintf(os.Stderr, "Deployment gas used: %d\n", (gas/2) - deployResult.GasLeft)
		
		// Now call the deployed contract
		callResult, err = vm.Call(evm.Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  input,
			Gas:    gas / 2, // Use remaining half for call
		})
		
		// End timing
		elapsed := time.Since(start)
		fmt.Fprintf(os.Stderr, "Total execution time (deploy + call): %v\n", elapsed)
	} else {
		// For benchmarking, we expect already-deployed runtime bytecode
		// Set up a contract address for execution
		contractAddr, _ = primitives.AddressFromHex("0x1000000000000000000000000000000000000001")
		
		// Set the runtime code at the contract address
		if err := vm.SetCode(contractAddr, bytecode); err != nil {
			return fmt.Errorf("failed to set contract code: %w", err)
		}
		
		// Start timing for the actual execution
		execStart := time.Now()
		
		// Call the contract with the input data
		callResult, err = vm.Call(evm.Call{
			Caller: caller,
			To:     contractAddr,
			Value:  big.NewInt(0),
			Input:  input,
			Gas:    gas,
		})
		
		// End timing
		elapsed := time.Since(execStart)
		fmt.Fprintf(os.Stderr, "Execution time: %v\n", elapsed)
		
	}
	
	if err != nil {
		return fmt.Errorf("call failed: %w", err)
	}
	
	// Calculate gas consumed
	gasUsed := gas - callResult.GasLeft
	fmt.Fprintf(os.Stderr, "Gas consumed: %d / %d\n", gasUsed, gas)
	
	if !callResult.Success {
		return fmt.Errorf("call reverted: %s", callResult.ErrorInfo)
	}
	
	// Output results
	if callResult.Output != nil {
		fmt.Printf("0x%x\n", callResult.Output)
	}
	
	return nil
}

func runTrace(c *cli.Context) error {
    bytecodePath := c.String("bytecode")
    calldataPath := c.String("calldata")
    outPath := c.String("out")
    gasStr := c.String("gas")

    if bytecodePath == "" {
        bytecodePath = "/Users/williamcory/Guillotine/src/_test_utils/fixtures/snailtracer/runtime_clean.txt"
    }
    if calldataPath == "" {
        calldataPath = "/Users/williamcory/Guillotine/src/_test_utils/fixtures/snailtracer/calldata.txt"
    }

    bcBytesRaw, err := os.ReadFile(bytecodePath)
    if err != nil { return fmt.Errorf("failed to read bytecode: %w", err) }
    bytecode, err := parseHex(string(bcBytesRaw))
    if err != nil { return fmt.Errorf("invalid bytecode hex: %w", err) }

    cdBytesRaw, err := os.ReadFile(calldataPath)
    if err != nil { return fmt.Errorf("failed to read calldata: %w", err) }
    calldata, err := parseHex(string(cdBytesRaw))
    if err != nil { return fmt.Errorf("invalid calldata hex: %w", err) }

    var gas uint64
    if _, err := fmt.Sscanf(gasStr, "%d", &gas); err != nil {
        return fmt.Errorf("invalid gas: %w", err)
    }

    vm, err := evm.NewTracing()
    if err != nil { return fmt.Errorf("failed to create tracing EVM: %w", err) }
    defer vm.Destroy()

    // Use a deterministic caller and contract address
    caller, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000000")
    contract, _ := primitives.AddressFromHex("0x1000000000000000000000000000000000000001")
    // Fund caller
    if err := vm.SetBalance(caller, big.NewInt(1_000_000_000_000_000_000)); err != nil {
        return fmt.Errorf("failed to set balance: %w", err)
    }
    // Set code at contract
    if err := vm.SetCode(contract, bytecode); err != nil {
        return fmt.Errorf("failed to set code: %w", err)
    }

    res, err := vm.Call(evm.Call{
        Caller: caller,
        To:     contract,
        Value:  big.NewInt(0),
        Input:  calldata,
        Gas:    gas,
    })
    if err != nil { return fmt.Errorf("call failed: %w", err) }

    if len(res.TraceJSON) == 0 {
        return fmt.Errorf("no trace produced")
    }
    if err := os.WriteFile(outPath, res.TraceJSON, 0o644); err != nil {
        return fmt.Errorf("failed to write %s: %w", outPath, err)
    }
    fmt.Fprintf(os.Stderr, "Wrote trace to %s (%d bytes)\n", outPath, len(res.TraceJSON))
    return nil
}

func parseHex(s string) ([]byte, error) {
	original := s
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "0x")
	s = strings.TrimPrefix(s, "0X")
	
	// Debug logging
	fmt.Fprintf(os.Stderr, "parseHex: original len=%d, after trim len=%d\n", len(original), len(s))
	if len(s) % 2 != 0 {
		fmt.Fprintf(os.Stderr, "WARNING: Odd number of hex chars: %d\n", len(s))
		// Pad with a zero if odd
		s = s + "0"
	}
	
	result, err := hex.DecodeString(s)
	if err != nil {
		fmt.Fprintf(os.Stderr, "hex.DecodeString error: %v\n", err)
	}
	return result, err
}

func runCompile(c *cli.Context) error {
	// Get source code - either from inline or file
	var source string
	var filename string
	
	if c.IsSet("source") {
		source = c.String("source")
		filename = "inline.sol"
	} else if c.IsSet("file") {
		filepath := c.String("file")
		content, err := os.ReadFile(filepath)
		if err != nil {
			return fmt.Errorf("failed to read source file: %w", err)
		}
		source = string(content)
		
		// Extract filename from path
		parts := strings.Split(filepath, "/")
		filename = parts[len(parts)-1]
	} else {
		return fmt.Errorf("either --source or --file must be provided")
	}
	
	// Setup compiler settings
	settings := compiler.CompilerSettings{
		OptimizerEnabled:       c.Bool("optimize"),
		OptimizerRuns:          uint32(c.Uint("optimize-runs")),
		EVMVersion:             c.String("evm-version"),
		OutputAbi:              true,
		OutputBytecode:         true,
		OutputDeployedBytecode: true,
		OutputAst:              false,
	}
	
	// Compile the source
	result, err := compiler.CompileSource(filename, source, settings)
	if err != nil {
		return fmt.Errorf("compilation failed: %w", err)
	}
	
	// Check for compilation errors
	if len(result.Errors) > 0 {
		fmt.Fprintf(os.Stderr, "Compilation errors:\n")
		for _, err := range result.Errors {
			fmt.Fprintf(os.Stderr, "  - %s\n", err)
		}
		if len(result.Contracts) == 0 {
			return fmt.Errorf("compilation failed with errors")
		}
	}
	
	// Show warnings if any
	if len(result.Warnings) > 0 {
		fmt.Fprintf(os.Stderr, "Warnings:\n")
		for _, warning := range result.Warnings {
			fmt.Fprintf(os.Stderr, "  - %s\n", warning)
		}
	}
	
	// Format output based on requested format
	var output string
	format := c.String("format")
	
	switch format {
	case "json":
		output, err = result.ToJSON()
		if err != nil {
			return fmt.Errorf("failed to format as JSON: %w", err)
		}
	case "hex":
		// Output just the bytecode in hex format
		if len(result.Contracts) > 0 {
			output = result.Contracts[0].Bytecode
		} else {
			return fmt.Errorf("no contracts compiled")
		}
	case "combined":
		// Output ABI and bytecode in a combined format
		if len(result.Contracts) > 0 {
			contract := result.Contracts[0]
			output = fmt.Sprintf("ABI:\n%s\n\nBytecode:\n%s\n\nDeployed Bytecode:\n%s\n",
				contract.ABI, contract.Bytecode, contract.DeployedBytecode)
		} else {
			return fmt.Errorf("no contracts compiled")
		}
	default:
		return fmt.Errorf("unsupported format: %s", format)
	}
	
	// Output to file or stdout
	outputPath := c.String("output")
	if outputPath != "" {
		if err := os.WriteFile(outputPath, []byte(output), 0644); err != nil {
			return fmt.Errorf("failed to write output file: %w", err)
		}
		fmt.Fprintf(os.Stderr, "Compilation result written to: %s\n", outputPath)
	} else {
		fmt.Print(output)
	}
	
	// Print summary to stderr
	fmt.Fprintf(os.Stderr, "\nCompiled %d contract(s) successfully\n", len(result.Contracts))
	for _, contract := range result.Contracts {
		fmt.Fprintf(os.Stderr, "  - %s\n", contract.Name)
	}
	
	return nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}