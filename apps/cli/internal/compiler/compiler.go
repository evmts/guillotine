package compiler

/*
#cgo CFLAGS: -I${SRCDIR}/../../../../lib/foundry-compilers
#cgo LDFLAGS: -L${SRCDIR}/../../../../target/aarch64-apple-darwin/release -lfoundry_wrapper
#cgo darwin LDFLAGS: -framework Security -framework SystemConfiguration -framework CoreFoundation -lc++
#cgo linux LDFLAGS: -lm -lpthread -ldl

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>
#include "foundry_wrapper.h"
*/
import "C"
import (
	"encoding/json"
	"fmt"
	"unsafe"
)

type CompilerSettings struct {
	OptimizerEnabled       bool
	OptimizerRuns          uint32
	EVMVersion             string
	Remappings             []string
	CacheEnabled           bool
	CachePath              string
	OutputAbi              bool
	OutputBytecode         bool
	OutputDeployedBytecode bool
	OutputAst              bool
}

type CompiledContract struct {
	Name             string `json:"name"`
	ABI              string `json:"abi"`
	Bytecode         string `json:"bytecode"`
	DeployedBytecode string `json:"deployedBytecode"`
}

type CompilationResult struct {
	Contracts []CompiledContract `json:"contracts"`
	Errors    []string          `json:"errors,omitempty"`
	Warnings  []string          `json:"warnings,omitempty"`
}

func CompileSource(sourceName string, sourceContent string, settings CompilerSettings) (*CompilationResult, error) {
	// Convert Go strings to C strings
	cSourceName := C.CString(sourceName)
	defer C.free(unsafe.Pointer(cSourceName))
	
	cSourceContent := C.CString(sourceContent)
	defer C.free(unsafe.Pointer(cSourceContent))
	
	// Create C settings struct
	var cSettings C.foundry_CompilerSettings
	cSettings.optimizer_enabled = C.bool(settings.OptimizerEnabled)
	cSettings.optimizer_runs = C.uint32_t(settings.OptimizerRuns)
	
	var cEvmVersion *C.char
	if settings.EVMVersion != "" {
		cEvmVersion = C.CString(settings.EVMVersion)
		defer C.free(unsafe.Pointer(cEvmVersion))
		cSettings.evm_version = cEvmVersion
	}
	
	// Handle remappings
	var cRemappings **C.char
	if len(settings.Remappings) > 0 {
		// Allocate array of char pointers (+1 for NULL terminator)
		cRemappings = (**C.char)(C.calloc(C.size_t(len(settings.Remappings)+1), C.size_t(unsafe.Sizeof(uintptr(0)))))
		defer C.free(unsafe.Pointer(cRemappings))
		
		// Convert each remapping to C string
		for i, remapping := range settings.Remappings {
			cStr := C.CString(remapping)
			// Store pointer in array
			ptr := uintptr(unsafe.Pointer(cRemappings)) + uintptr(i)*unsafe.Sizeof(uintptr(0))
			*(**C.char)(unsafe.Pointer(ptr)) = cStr
			defer C.free(unsafe.Pointer(cStr))
		}
		cSettings.remappings = cRemappings
	}
	
	cSettings.cache_enabled = C.bool(settings.CacheEnabled)
	
	var cCachePath *C.char
	if settings.CachePath != "" {
		cCachePath = C.CString(settings.CachePath)
		defer C.free(unsafe.Pointer(cCachePath))
		cSettings.cache_path = cCachePath
	}
	
	cSettings.output_abi = C.bool(settings.OutputAbi)
	cSettings.output_bytecode = C.bool(settings.OutputBytecode)
	cSettings.output_deployed_bytecode = C.bool(settings.OutputDeployedBytecode)
	cSettings.output_ast = C.bool(settings.OutputAst)
	
	// Call the compiler
	var resultPtr *C.foundry_CompilationResult
	var errorPtr *C.foundry_FoundryError
	
	success := C.foundry_compile_source(
		cSourceName,
		cSourceContent,
		&cSettings,
		&resultPtr,
		&errorPtr,
	)
	
	if success == 0 {
		if errorPtr != nil {
			defer C.foundry_free_error(errorPtr)
			errMsg := C.GoString(C.foundry_get_error_message(errorPtr))
			return nil, fmt.Errorf("compilation failed: %s", errMsg)
		}
		return nil, fmt.Errorf("compilation failed with unknown error")
	}
	
	if resultPtr == nil {
		return nil, fmt.Errorf("compilation succeeded but no result returned")
	}
	defer C.foundry_free_compilation_result(resultPtr)
	
	// Convert C result to Go
	result := &CompilationResult{
		Contracts: make([]CompiledContract, 0),
		Errors:    make([]string, 0),
		Warnings:  make([]string, 0),
	}
	
	// Convert contracts
	if resultPtr.contracts_count > 0 && resultPtr.contracts != nil {
		contracts := (*[1 << 30]C.foundry_CompiledContract)(unsafe.Pointer(resultPtr.contracts))[:resultPtr.contracts_count:resultPtr.contracts_count]
		for _, contract := range contracts {
			result.Contracts = append(result.Contracts, CompiledContract{
				Name:             C.GoString(contract.name),
				ABI:              C.GoString(contract.abi),
				Bytecode:         C.GoString(contract.bytecode),
				DeployedBytecode: C.GoString(contract.deployed_bytecode),
			})
		}
	}
	
	// Convert errors
	if resultPtr.errors_count > 0 && resultPtr.errors != nil {
		errors := (*[1 << 30]C.foundry_CompilerError)(unsafe.Pointer(resultPtr.errors))[:resultPtr.errors_count:resultPtr.errors_count]
		for _, err := range errors {
			result.Errors = append(result.Errors, C.GoString(err.message))
		}
	}
	
	// Convert warnings
	if resultPtr.warnings_count > 0 && resultPtr.warnings != nil {
		warnings := (*[1 << 30]C.foundry_CompilerError)(unsafe.Pointer(resultPtr.warnings))[:resultPtr.warnings_count:resultPtr.warnings_count]
		for _, warning := range warnings {
			result.Warnings = append(result.Warnings, C.GoString(warning.message))
		}
	}
	
	return result, nil
}

func (r *CompilationResult) ToJSON() (string, error) {
	data, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data), nil
}

func (r *CompilationResult) Print() {
	for _, contract := range r.Contracts {
		fmt.Printf("Contract: %s\n", contract.Name)
		fmt.Printf("  Bytecode: %s\n", contract.Bytecode)
		fmt.Printf("  Deployed Bytecode: %s\n", contract.DeployedBytecode)
		fmt.Printf("  ABI: %s\n", contract.ABI)
		fmt.Println()
	}
	
	if len(r.Errors) > 0 {
		fmt.Println("Errors:")
		for _, err := range r.Errors {
			fmt.Printf("  - %s\n", err)
		}
	}
	
	if len(r.Warnings) > 0 {
		fmt.Println("Warnings:")
		for _, warning := range r.Warnings {
			fmt.Printf("  - %s\n", warning)
		}
	}
}