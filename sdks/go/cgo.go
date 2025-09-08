package guillotine

/*
#cgo CFLAGS: -I${SRCDIR}/../../zig-out/include -I${SRCDIR}/../../src
#cgo LDFLAGS: -L${SRCDIR}/../../zig-out/lib -lguillotine_ffi
#cgo darwin LDFLAGS: -Wl,-rpath,${SRCDIR}/../../zig-out/lib
#cgo linux LDFLAGS: -Wl,-rpath,${SRCDIR}/../../zig-out/lib

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

// Log entry from evm_c_api.zig
typedef struct {
    uint8_t address[20];
    const uint8_t (*topics)[32];  // Array of 32-byte topics
    size_t topics_len;
    const uint8_t* data;
    size_t data_len;
} LogEntry;

// Self-destruct record from evm_c_api.zig
typedef struct {
    uint8_t contract[20];
    uint8_t beneficiary[20];
} SelfDestructRecord;

// Storage access record from evm_c_api.zig
typedef struct {
    uint8_t address[20];
    uint8_t slot[32];  // u256 as bytes
} StorageAccessRecord;

// Result structure from evm_c_api.zig
typedef struct {
    bool success;
    uint64_t gas_left;
    const uint8_t* output;
    size_t output_len;
    const char* error_message;
    // Additional fields
    const LogEntry* logs;
    size_t logs_len;
    const SelfDestructRecord* selfdestructs;
    size_t selfdestructs_len;
    const uint8_t (*accessed_addresses)[20];  // Array of addresses
    size_t accessed_addresses_len;
    const StorageAccessRecord* accessed_storage;
    size_t accessed_storage_len;
    uint8_t created_address[20];  // For CREATE/CREATE2
    bool has_created_address;
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

// State query functions
bool guillotine_get_balance(EvmHandle* handle, const uint8_t* address, uint8_t* balance_out);
bool guillotine_get_code(EvmHandle* handle, const uint8_t* address, uint8_t** code_out, size_t* len_out);
void guillotine_free_code(uint8_t* code, size_t len);
bool guillotine_set_storage(EvmHandle* handle, const uint8_t* address, const uint8_t* key, const uint8_t* value);
bool guillotine_get_storage(EvmHandle* handle, const uint8_t* address, const uint8_t* key, uint8_t* value_out);

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
	"runtime"
	"sync"
	"unsafe"
	
	"github.com/evmts/guillotine/sdks/go/primitives"
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

// Destroy destroys the EVM instance (consistent with guillotine_evm_destroy)
func (vm *VMHandle) Destroy() error {
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

// Call runs a call with the given parameters (consistent with guillotine_call)
func (vm *VMHandle) Call(params *CallParams) (*CallResult, error) {
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
	// Note: evm_c_api.zig uses std.mem.readInt with .big endian
	valueBytes := BigIntToBytes32(params.Value)
	saltBytes := BigIntToBytes32(params.Salt)
	for i := 0; i < 32; i++ {
		cParams.value[i] = C.uint8_t(valueBytes[i])
		cParams.salt[i] = C.uint8_t(saltBytes[i])
	}
	
	// Handle input bytes with runtime.Pinner
	var pinner runtime.Pinner
	defer pinner.Unpin()
	
	if len(params.Input) > 0 {
		// Pin the slice data to prevent GC from moving it
		pinner.Pin(&params.Input[0])
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
	
	// Copy logs if present
	if cResult.logs_len > 0 && cResult.logs != nil {
		logs := (*[1 << 30]C.LogEntry)(unsafe.Pointer(cResult.logs))[:cResult.logs_len:cResult.logs_len]
		result.Logs = make([]LogEntry, len(logs))
		for i, log := range logs {
			// Convert address
			result.Logs[i].Address = primitives.NewAddress(*(*[20]byte)(unsafe.Pointer(&log.address[0])))
			
			// Convert topics
			if log.topics_len > 0 && log.topics != nil {
				topics := (*[1 << 30][32]byte)(unsafe.Pointer(log.topics))[:log.topics_len:log.topics_len]
				result.Logs[i].Topics = make([]*big.Int, len(topics))
				for j, topic := range topics {
					result.Logs[i].Topics[j] = Bytes32ToBigInt(topic)
				}
			}
			
			// Copy data
			if log.data_len > 0 && log.data != nil {
				result.Logs[i].Data = C.GoBytes(unsafe.Pointer(log.data), C.int(log.data_len))
			}
		}
	}
	
	// Copy selfdestructs if present
	if cResult.selfdestructs_len > 0 && cResult.selfdestructs != nil {
		sds := (*[1 << 30]C.SelfDestructRecord)(unsafe.Pointer(cResult.selfdestructs))[:cResult.selfdestructs_len:cResult.selfdestructs_len]
		result.SelfDestructs = make([]SelfDestructRecord, len(sds))
		for i, sd := range sds {
			result.SelfDestructs[i].Contract = primitives.NewAddress(*(*[20]byte)(unsafe.Pointer(&sd.contract[0])))
			result.SelfDestructs[i].Beneficiary = primitives.NewAddress(*(*[20]byte)(unsafe.Pointer(&sd.beneficiary[0])))
		}
	}
	
	// Copy accessed addresses if present
	if cResult.accessed_addresses_len > 0 && cResult.accessed_addresses != nil {
		addrs := (*[1 << 30][20]byte)(unsafe.Pointer(cResult.accessed_addresses))[:cResult.accessed_addresses_len:cResult.accessed_addresses_len]
		result.AccessedAddresses = make([]primitives.Address, len(addrs))
		for i, addr := range addrs {
			result.AccessedAddresses[i] = primitives.NewAddress(addr)
		}
	}
	
	// Copy accessed storage if present
	if cResult.accessed_storage_len > 0 && cResult.accessed_storage != nil {
		storages := (*[1 << 30]C.StorageAccessRecord)(unsafe.Pointer(cResult.accessed_storage))[:cResult.accessed_storage_len:cResult.accessed_storage_len]
		result.AccessedStorage = make([]StorageAccessRecord, len(storages))
		for i, storage := range storages {
			result.AccessedStorage[i].Address = primitives.NewAddress(*(*[20]byte)(unsafe.Pointer(&storage.address[0])))
			result.AccessedStorage[i].Slot = Bytes32ToBigInt(*(*[32]byte)(unsafe.Pointer(&storage.slot[0])))
		}
	}
	
	// Set created address if present (for CREATE/CREATE2)
	if cResult.has_created_address {
		createdAddr := primitives.NewAddress(*(*[20]byte)(unsafe.Pointer(&cResult.created_address[0])))
		result.CreatedAddress = &createdAddr
	}
	
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
func (vm *VMHandle) GetBalance(address [20]byte) ([32]byte, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return [32]byte{}, ErrVMClosed
	}
	
	var balance [32]byte
	success := C.guillotine_get_balance(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		(*C.uint8_t)(unsafe.Pointer(&balance[0])),
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return [32]byte{}, fmt.Errorf("failed to get balance: %s", errMsg)
		}
		return [32]byte{}, errors.New("failed to get balance")
	}
	
	return balance, nil
}

// SetCode sets the code at an address
func (vm *VMHandle) SetCode(address [20]byte, code []byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	// Pin memory for slice data
	var pinner runtime.Pinner
	defer pinner.Unpin()
	
	var codePtr *C.uint8_t
	if len(code) > 0 {
		// Pin the slice data to prevent GC from moving it
		pinner.Pin(&code[0])
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
func (vm *VMHandle) GetCode(address [20]byte) ([]byte, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return nil, ErrVMClosed
	}
	
	var codePtr *C.uint8_t
	var codeLen C.size_t
	
	success := C.guillotine_get_code(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		&codePtr,
		&codeLen,
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return nil, fmt.Errorf("failed to get code: %s", errMsg)
		}
		return nil, errors.New("failed to get code")
	}
	
	// If no code, return empty slice
	if codeLen == 0 {
		return []byte{}, nil
	}
	
	// Copy the code to Go memory before freeing C memory
	code := C.GoBytes(unsafe.Pointer(codePtr), C.int(codeLen))
	
	// Free the C-allocated memory
	C.guillotine_free_code(codePtr, codeLen)
	
	return code, nil
}

// SetStorage sets a storage value at an address
func (vm *VMHandle) SetStorage(address [20]byte, key, value [32]byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	success := C.guillotine_set_storage(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		(*C.uint8_t)(unsafe.Pointer(&key[0])),
		(*C.uint8_t)(unsafe.Pointer(&value[0])),
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return fmt.Errorf("failed to set storage: %s", errMsg)
		}
		return errors.New("failed to set storage")
	}
	
	return nil
}

// GetStorage gets a storage value at an address
func (vm *VMHandle) GetStorage(address [20]byte, key [32]byte) ([32]byte, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return [32]byte{}, ErrVMClosed
	}
	
	var value [32]byte
	success := C.guillotine_get_storage(
		vm.ptr,
		(*C.uint8_t)(unsafe.Pointer(&address[0])),
		(*C.uint8_t)(unsafe.Pointer(&key[0])),
		(*C.uint8_t)(unsafe.Pointer(&value[0])),
	)
	
	if !success {
		errMsg := C.GoString(C.guillotine_get_last_error())
		if errMsg != "" {
			return [32]byte{}, fmt.Errorf("failed to get storage: %s", errMsg)
		}
		return [32]byte{}, errors.New("failed to get storage")
	}
	
	return value, nil
}



// ========================
// Helper Functions
// ========================

// BigIntToBytes32 converts a big.Int to a 32-byte array (big-endian)
// Note: evm_c_api.zig expects big-endian (uses std.mem.readInt with .big)
func BigIntToBytes32(n *big.Int) [32]byte {
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

// Bytes32ToBigInt converts a 32-byte array (big-endian) to big.Int
func Bytes32ToBigInt(bytes [32]byte) *big.Int {
	// Trim leading zeros
	start := 0
	for start < 32 && bytes[start] == 0 {
		start++
	}
	
	if start == 32 {
		return big.NewInt(0)
	}
	
	// SetBytes expects big-endian, which is what we have
	return new(big.Int).SetBytes(bytes[start:])
}

