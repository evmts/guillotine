package guillotine

/*
#cgo CFLAGS: -I../../zig-out/include -I../../src
#cgo LDFLAGS: -L../../zig-out/lib -lGuillotine

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>

// ========================
// Types from evm_c_api.zig
// ========================

// Opaque EVM handle
typedef struct EvmHandle EvmHandle;

// Block info for EVM creation
typedef struct {
    uint64_t number;
    uint64_t timestamp;
    uint64_t gas_limit;
    uint8_t coinbase[20];
    uint64_t base_fee;
    uint64_t chain_id;
    uint64_t difficulty;
    uint8_t prev_randao[32];
} BlockInfoFFI;

// Call parameters from evm_c_api.zig
typedef struct {
    uint8_t caller[20];
    uint8_t to[20];
    uint8_t value[32];  // u256 as bytes
    const uint8_t* input;
    size_t input_len;
    uint64_t gas;
    uint8_t call_type;  // 0=CALL, 1=DELEGATECALL, 2=STATICCALL, 3=CREATE, 4=CREATE2
    uint8_t salt[32];   // For CREATE2
} CallParams;

// Result structure from evm_c_api.zig
typedef struct {
    bool success;
    uint64_t gas_left;
    const uint8_t* output;
    size_t output_len;
    const char* error_message;
} EvmResult;

// ========================
// Functions from evm_c_api.zig
// ========================

// FFI initialization and cleanup
void guillotine_init(void);
void guillotine_cleanup(void);

// EVM instance management
EvmHandle* guillotine_evm_create(const BlockInfoFFI* block_info);
void guillotine_evm_destroy(EvmHandle* handle);

// State management
bool guillotine_set_balance(EvmHandle* handle, const uint8_t* address, const uint8_t* balance);
bool guillotine_set_code(EvmHandle* handle, const uint8_t* address, const uint8_t* code, size_t code_len);

// Note: Get functions are not exposed in evm_c_api.zig yet, would need to add them

// Execution
EvmResult* guillotine_call(EvmHandle* handle, const CallParams* params);
void guillotine_free_result(EvmResult* result);
void guillotine_free_output(uint8_t* output, size_t len);

// Error handling
const char* guillotine_get_last_error(void);

*/
import "C"
import (
	"errors"
	"fmt"
	"math/big"
	"sync"
	"unsafe"
	
	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ========================
// Errors
// ========================

var (
	ErrInvalidInput = errors.New("invalid input")
)

// ========================
// VM Handle
// ========================

// VMHandle wraps the C EVM handle
type VMHandle struct {
	ptr *C.EvmHandle
	mu  sync.RWMutex
}

// BlockInfo contains the block context for EVM execution
type BlockInfo struct {
	Number     uint64
	Timestamp  uint64
	GasLimit   uint64
	Coinbase   primitives.Address
	BaseFee    uint64
	ChainID    uint64
	Difficulty uint64
	PrevRandao [32]byte
}

// NewVMHandle creates a new EVM instance with optional block info
// If blockInfo is nil or not provided, uses default values
func NewVMHandle(blockInfo ...*BlockInfo) (*VMHandle, error) {
	// Initialize FFI allocator
	C.guillotine_init()
	
	// Use provided block info or defaults
	var info BlockInfo
	if len(blockInfo) > 0 && blockInfo[0] != nil {
		info = *blockInfo[0]
	} else {
		// Default values
		info = BlockInfo{
			Number:     0,
			Timestamp:  0,
			GasLimit:   30_000_000,
			Coinbase:   primitives.ZeroAddress(),
			BaseFee:    0,
			ChainID:    1, // Ethereum mainnet
			Difficulty: 0,
			PrevRandao: [32]byte{},
		}
	}
	
	// Convert to C struct
	var cBlockInfo C.BlockInfoFFI
	cBlockInfo.number = C.uint64_t(info.Number)
	cBlockInfo.timestamp = C.uint64_t(info.Timestamp)
	cBlockInfo.gas_limit = C.uint64_t(info.GasLimit)
	cBlockInfo.base_fee = C.uint64_t(info.BaseFee)
	cBlockInfo.chain_id = C.uint64_t(info.ChainID)
	cBlockInfo.difficulty = C.uint64_t(info.Difficulty)
	
	// Copy address bytes
	coinbaseArray := info.Coinbase.Array()
	for i := 0; i < 20; i++ {
		cBlockInfo.coinbase[i] = C.uint8_t(coinbaseArray[i])
	}
	
	// Copy randao bytes
	for i := 0; i < 32; i++ {
		cBlockInfo.prev_randao[i] = C.uint8_t(info.PrevRandao[i])
	}
	
	ptr := C.guillotine_evm_create(&cBlockInfo)
	if ptr == nil {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return nil, fmt.Errorf("failed to create EVM: %s", errMsg)
		}
		return nil, ErrVMCreationFailed
	}
	return &VMHandle{ptr: ptr}, nil
}

// Close destroys the EVM instance
func (vm *VMHandle) Close() error {
	vm.mu.Lock()
	defer vm.mu.Unlock()
	
	if vm.ptr != nil {
		C.guillotine_evm_destroy(vm.ptr)
		vm.ptr = nil
		C.guillotine_cleanup()
	}
	return nil
}

// ========================
// Execution
// ========================

// Execute runs a call with the given parameters
func (vm *VMHandle) Execute(params *CallParams) (*CallResult, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return nil, ErrVMClosed
	}
	
	// Convert Go types to C types
	var cParams C.CallParams
	
	// Copy addresses
	callerArray := params.Caller.Array()
	toArray := params.To.Array()
	for i := 0; i < 20; i++ {
		cParams.caller[i] = C.uint8_t(callerArray[i])
		cParams.to[i] = C.uint8_t(toArray[i])
	}
	
	// Convert value and salt to bytes (big-endian as expected by evm_c_api.zig)
	valueBytes := bigIntToBytes32(params.Value)
	saltBytes := bigIntToBytes32(params.Salt)
	for i := 0; i < 32; i++ {
		cParams.value[i] = C.uint8_t(valueBytes[i])
		cParams.salt[i] = C.uint8_t(saltBytes[i])
	}
	
	// Handle input bytes
	if len(params.Input) > 0 {
		cParams.input = (*C.uint8_t)(unsafe.Pointer(&params.Input[0]))
		cParams.input_len = C.size_t(len(params.Input))
	} else {
		cParams.input = nil
		cParams.input_len = 0
	}
	
	// Set call type
	cParams.call_type = C.uint8_t(params.CallType)
	cParams.gas = C.uint64_t(params.Gas)
	
	// Execute the call
	cResult := C.guillotine_call(vm.ptr, &cParams)
	if cResult == nil {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return nil, fmt.Errorf("execution failed: %s", errMsg)
		}
		return nil, ErrExecutionFailed
	}
	defer C.guillotine_free_result(cResult)
	
	// Convert result
	result := &CallResult{
		Success: bool(cResult.success),
		GasLeft: uint64(cResult.gas_left),
	}
	
	// Copy output if present
	if cResult.output_len > 0 && cResult.output != nil {
		result.Output = C.GoBytes(unsafe.Pointer(cResult.output), C.int(cResult.output_len))
	}
	
	// Set error info if present
	if cResult.error_message != nil {
		result.ErrorInfo = C.GoString(cResult.error_message)
	}
	
	// Note: Logs, selfdestructs, and access lists are not exposed in EvmResult yet
	
	return result, nil
}

// ========================
// State Management
// ========================

// SetBalance sets the balance of an address
func (vm *VMHandle) SetBalance(address [20]byte, balance [32]byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	success := C.guillotine_set_balance(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		(*C.uint8_t)(unsafe.Pointer(&balance[0])),
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return fmt.Errorf("failed to set balance: %s", errMsg)
		}
		return errors.New("failed to set balance")
	}
	
	return nil
}

// GetBalance gets the balance of an address
// Note: This function is not implemented in evm_c_api.zig yet
func (vm *VMHandle) GetBalance(address [20]byte) ([32]byte, error) {
	// TODO: Needs to be implemented in evm_c_api.zig
	return [32]byte{}, errors.New("GetBalance not implemented in evm_c_api.zig")
}

// SetCode sets the code at an address
func (vm *VMHandle) SetCode(address [20]byte, code []byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	var codePtr *C.uint8_t
	if len(code) > 0 {
		codePtr = (*C.uint8_t)(unsafe.Pointer(&code[0]))
	}
	
	success := C.guillotine_set_code(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		codePtr,
		C.size_t(len(code)),
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return fmt.Errorf("failed to set code: %s", errMsg)
		}
		return errors.New("failed to set code")
	}
	
	return nil
}

// GetCode gets the code at an address
// Note: This function is not implemented in evm_c_api.zig yet
func (vm *VMHandle) GetCode(address [20]byte) ([]byte, error) {
	// TODO: Needs to be implemented in evm_c_api.zig
	return nil, errors.New("GetCode not implemented in evm_c_api.zig")
}

// SetStorage sets a storage value at an address
// Note: This function is not implemented in evm_c_api.zig yet
func (vm *VMHandle) SetStorage(address [20]byte, key, value [32]byte) error {
	// TODO: Needs to be implemented in evm_c_api.zig
	return errors.New("SetStorage not implemented in evm_c_api.zig")
}

// GetStorage gets a storage value at an address
// Note: This function is not implemented in evm_c_api.zig yet
func (vm *VMHandle) GetStorage(address [20]byte, key [32]byte) ([32]byte, error) {
	// TODO: Needs to be implemented in evm_c_api.zig
	return [32]byte{}, errors.New("GetStorage not implemented in evm_c_api.zig")
}

// ========================
// Legacy Compatibility Functions
// ========================

// Call executes a CALL operation
func (vm *VMHandle) Call(caller, to primitives.Address, value *big.Int, input []byte, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeCall,
		Caller:   caller,
		To:       to,
		Value:    value,
		Input:    input,
		Gas:      gasLimit,
		Salt:     big.NewInt(0),
	})
}

// Callcode executes a CALLCODE operation
func (vm *VMHandle) Callcode(caller, to primitives.Address, value *big.Int, input []byte, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeCallcode,
		Caller:   caller,
		To:       to,
		Value:    value,
		Input:    input,
		Gas:      gasLimit,
		Salt:     big.NewInt(0),
	})
}

// Delegatecall executes a DELEGATECALL operation
func (vm *VMHandle) Delegatecall(caller, to primitives.Address, input []byte, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeDelegatecall,
		Caller:   caller,
		To:       to,
		Value:    big.NewInt(0),
		Input:    input,
		Gas:      gasLimit,
		Salt:     big.NewInt(0),
	})
}

// Staticcall executes a STATICCALL operation
func (vm *VMHandle) Staticcall(caller, to primitives.Address, input []byte, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeStaticcall,
		Caller:   caller,
		To:       to,
		Value:    big.NewInt(0),
		Input:    input,
		Gas:      gasLimit,
		Salt:     big.NewInt(0),
	})
}

// Create executes a CREATE operation
func (vm *VMHandle) Create(caller primitives.Address, value *big.Int, initCode []byte, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeCreate,
		Caller:   caller,
		To:       primitives.ZeroAddress(),
		Value:    value,
		Input:    initCode,
		Gas:      gasLimit,
		Salt:     big.NewInt(0),
	})
}

// Create2 executes a CREATE2 operation
func (vm *VMHandle) Create2(caller primitives.Address, value *big.Int, initCode []byte, salt *big.Int, gasLimit uint64) (*CallResult, error) {
	return vm.Execute(&CallParams{
		CallType: CallTypeCreate2,
		Caller:   caller,
		To:       primitives.ZeroAddress(),
		Value:    value,
		Input:    initCode,
		Gas:      gasLimit,
		Salt:     salt,
	})
}

// ========================
// Helper Functions
// ========================

// bigIntToBytes32 converts a big.Int to a 32-byte array (big-endian for evm_c_api.zig)
func bigIntToBytes32(n *big.Int) [32]byte {
	var result [32]byte
	if n == nil {
		return result
	}
	
	// Get big-endian bytes
	bigEndian := n.Bytes()
	
	// Copy to result, right-aligned (big-endian)
	if len(bigEndian) <= 32 {
		copy(result[32-len(bigEndian):], bigEndian)
	} else {
		// If the number is too large, copy the least significant 32 bytes
		copy(result[:], bigEndian[len(bigEndian)-32:])
	}
	
	return result
}

// bytes32ToBigInt converts a 32-byte array (big-endian from evm_c_api.zig) to big.Int
func bytes32ToBigInt(bytes [32]byte) *big.Int {
	// Trim leading zeros
	start := 0
	for start < 32 && bytes[start] == 0 {
		start++
	}
	
	if start == 32 {
		return big.NewInt(0)
	}
	
	return new(big.Int).SetBytes(bytes[start:])
}