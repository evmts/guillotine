package guillotine

/*
#cgo CFLAGS: -I../../zig-out/include
#cgo LDFLAGS: -L../../zig-out/lib -lGuillotine -Wl,-rpath -Wl,${SRCDIR}/../../zig-out/lib

#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <stdbool.h>

// ========================
// Core Types
// ========================

typedef struct {
    uint8_t bytes[20];
} GuillotineAddress;

typedef struct {
    uint8_t bytes[32];
} GuillotineU256;

typedef struct {
    uint8_t bytes[32];
} GuillotineHash;

typedef struct {
    uint8_t* data;
    size_t len;
} GuillotineBytes;

// ========================
// Call Types and Parameters
// ========================

typedef enum {
    CALL_TYPE_CALL = 0,
    CALL_TYPE_CALLCODE = 1,
    CALL_TYPE_DELEGATECALL = 2,
    CALL_TYPE_STATICCALL = 3,
    CALL_TYPE_CREATE = 4,
    CALL_TYPE_CREATE2 = 5,
} GuillotineCallType;

typedef struct {
    GuillotineCallType call_type;
    GuillotineAddress caller;
    GuillotineAddress to;
    GuillotineU256 value;
    GuillotineBytes input;
    uint64_t gas;
    GuillotineU256 salt;
} GuillotineCallParams;

// ========================
// Result Types
// ========================

typedef struct {
    GuillotineAddress address;
    GuillotineU256* topics;
    size_t topics_len;
    GuillotineBytes data;
} GuillotineLog;

typedef struct {
    GuillotineAddress contract;
    GuillotineAddress beneficiary;
} GuillotineSelfDestruct;

typedef struct {
    GuillotineAddress address;
    GuillotineU256 slot;
} GuillotineStorageAccess;

typedef struct {
    bool success;
    uint64_t gas_left;
    GuillotineBytes output;
    GuillotineLog* logs;
    size_t logs_len;
    GuillotineSelfDestruct* selfdestructs;
    size_t selfdestructs_len;
    GuillotineAddress* accessed_addresses;
    size_t accessed_addresses_len;
    GuillotineStorageAccess* accessed_storage;
    size_t accessed_storage_len;
    const char* error_info;
} GuillotineCallResult;

// ========================
// VM Handle
// ========================

typedef struct GuillotineVm GuillotineVm;

// ========================
// Core Functions
// ========================

// Initialization
int guillotine_init(void);
void guillotine_deinit(void);
int guillotine_is_initialized(void);
const char* guillotine_version(void);

// VM operations
GuillotineVm* guillotine_vm_create(void);
void guillotine_vm_destroy(GuillotineVm* vm);

// Execution - new comprehensive API
GuillotineCallResult guillotine_vm_execute(
    GuillotineVm* vm,
    const GuillotineCallParams* params
);

// Helper to free result memory
static void guillotine_free_call_result(GuillotineCallResult* result) {
    if (result->output.data != NULL) {
        free(result->output.data);
    }
    if (result->logs != NULL) {
        for (size_t i = 0; i < result->logs_len; i++) {
            if (result->logs[i].topics != NULL) {
                free(result->logs[i].topics);
            }
            if (result->logs[i].data.data != NULL) {
                free(result->logs[i].data.data);
            }
        }
        free(result->logs);
    }
    if (result->selfdestructs != NULL) {
        free(result->selfdestructs);
    }
    if (result->accessed_addresses != NULL) {
        free(result->accessed_addresses);
    }
    if (result->accessed_storage != NULL) {
        free(result->accessed_storage);
    }
}

// ========================
// State Management
// ========================

int guillotine_set_balance(GuillotineVm* vm, GuillotineAddress* address, GuillotineU256* balance);
int guillotine_set_code(GuillotineVm* vm, GuillotineAddress* address, uint8_t* code, size_t code_len);
int guillotine_set_storage(GuillotineVm* vm, GuillotineAddress* address, GuillotineU256* key, GuillotineU256* value);

GuillotineU256 guillotine_get_balance(GuillotineVm* vm, GuillotineAddress* address);
GuillotineBytes guillotine_get_code(GuillotineVm* vm, GuillotineAddress* address);
GuillotineU256 guillotine_get_storage(GuillotineVm* vm, GuillotineAddress* address, GuillotineU256* key);

// ========================
// Utility Functions
// ========================

// Address operations
GuillotineAddress guillotine_address_from_hex(const char* hex_str);
char* guillotine_address_to_hex(GuillotineAddress address);
int guillotine_address_eq(GuillotineAddress a, GuillotineAddress b);

// U256 operations
GuillotineU256 guillotine_u256_from_hex(const char* hex_str);
char* guillotine_u256_to_hex(GuillotineU256 value);
GuillotineU256 guillotine_u256_from_uint64(uint64_t value);

// Arithmetic operations
GuillotineU256 guillotine_u256_add(GuillotineU256 a, GuillotineU256 b, int* overflow);
GuillotineU256 guillotine_u256_sub(GuillotineU256 a, GuillotineU256 b, int* underflow);
GuillotineU256 guillotine_u256_mul(GuillotineU256 a, GuillotineU256 b, int* overflow);
GuillotineU256 guillotine_u256_div(GuillotineU256 a, GuillotineU256 b, int* div_by_zero);

// Comparison operations
int guillotine_u256_eq(GuillotineU256 a, GuillotineU256 b);
int guillotine_u256_lt(GuillotineU256 a, GuillotineU256 b);
int guillotine_u256_gt(GuillotineU256 a, GuillotineU256 b);

// Hash operations
GuillotineHash guillotine_hash_from_hex(const char* hex_str);
char* guillotine_hash_to_hex(GuillotineHash hash);
int guillotine_hash_eq(GuillotineHash a, GuillotineHash b);
*/
import "C"

import (
	"math/big"
	"runtime"
	"sync"
	"unsafe"

	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ========================
// Package initialization
// ========================

var (
	initOnce sync.Once
	initErr  error
)

func init() {
	initOnce.Do(func() {
		if C.guillotine_init() != 0 {
			initErr = ErrInitializationFailed
		}
	})
}

// ========================
// VM Handle
// ========================

// VMHandle represents a Guillotine VM instance
type VMHandle struct {
	ptr *C.GuillotineVm
	mu  sync.RWMutex
}

// NewVMHandle creates a new VM instance
func NewVMHandle() (*VMHandle, error) {
	if initErr != nil {
		return nil, initErr
	}
	
	ptr := C.guillotine_vm_create()
	if ptr == nil {
		return nil, ErrVMCreationFailed
	}
	
	vm := &VMHandle{ptr: ptr}
	runtime.SetFinalizer(vm, (*VMHandle).finalize)
	return vm, nil
}

// finalize is called by the garbage collector
func (vm *VMHandle) finalize() {
	vm.Close()
}

// Close destroys the VM instance
func (vm *VMHandle) Close() error {
	vm.mu.Lock()
	defer vm.mu.Unlock()
	
	if vm.ptr != nil {
		C.guillotine_vm_destroy(vm.ptr)
		vm.ptr = nil
		runtime.SetFinalizer(vm, nil)
	}
	return nil
}

// ========================
// Execution Methods
// ========================

// Execute executes bytecode with comprehensive result data using a CallParams struct
func (vm *VMHandle) Execute(params *CallParams) (*CallResult, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return nil, ErrVMClosed
	}
	
	// Convert big.Int to bytes (big-endian for C compatibility)
	valueBytes := bigIntToBytes32(params.Value)
	saltBytes := bigIntToBytes32(params.Salt)
	
	// Convert Go types to C types
	cParams := C.GuillotineCallParams{
		call_type: C.GuillotineCallType(params.CallType),
		caller:    cAddress(params.Caller.Array()),
		to:        cAddress(params.To.Array()),
		value:     cU256(valueBytes),
		input:     cBytes(params.Input),
		gas:       C.uint64_t(params.Gas),
		salt:      cU256(saltBytes),
	}
	defer freeBytes(cParams.input)
	
	// Call the C function
	result := C.guillotine_vm_execute(vm.ptr, &cParams)
	defer C.guillotine_free_call_result(&result)
	
	return convertCallResult(&result), nil
}

// Call performs a CALL operation
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

// StaticCall performs a STATICCALL operation (read-only)
func (vm *VMHandle) StaticCall(caller, to primitives.Address, input []byte, gasLimit uint64) (*CallResult, error) {
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

// DelegateCall performs a DELEGATECALL operation
func (vm *VMHandle) DelegateCall(caller, to primitives.Address, input []byte, gasLimit uint64) (*CallResult, error) {
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

// Create performs a CREATE operation
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

// Create2 performs a CREATE2 operation
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
// State Management
// ========================

// SetBalance sets the balance of an address
func (vm *VMHandle) SetBalance(address [20]byte, balance [32]byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	cAddr := cAddress(address)
	cBalance := cU256(balance)
	
	if C.guillotine_set_balance(vm.ptr, &cAddr, &cBalance) == 0 {
		return ErrExecutionFailed
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
	
	cAddr := cAddress(address)
	cBalance := C.guillotine_get_balance(vm.ptr, &cAddr)
	return goU256(cBalance), nil
}

// SetCode sets the code at an address
func (vm *VMHandle) SetCode(address [20]byte, code []byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	cAddr := cAddress(address)
	var codePtr *C.uint8_t
	if len(code) > 0 {
		codePtr = (*C.uint8_t)(C.CBytes(code))
		defer C.free(unsafe.Pointer(codePtr))
	}
	
	if C.guillotine_set_code(vm.ptr, &cAddr, codePtr, C.size_t(len(code))) == 0 {
		return ErrExecutionFailed
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
	
	cAddr := cAddress(address)
	cBytes := C.guillotine_get_code(vm.ptr, &cAddr)
	defer freeBytes(cBytes)
	
	return goBytes(cBytes), nil
}

// SetStorage sets a storage value at an address
func (vm *VMHandle) SetStorage(address [20]byte, key, value [32]byte) error {
	vm.mu.RLock()
	defer vm.mu.RUnlock()
	
	if vm.ptr == nil {
		return ErrVMClosed
	}
	
	cAddr := cAddress(address)
	cKey := cU256(key)
	cValue := cU256(value)
	
	if C.guillotine_set_storage(vm.ptr, &cAddr, &cKey, &cValue) == 0 {
		return ErrExecutionFailed
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
	
	cAddr := cAddress(address)
	cKey := cU256(key)
	cValue := C.guillotine_get_storage(vm.ptr, &cAddr, &cKey)
	return goU256(cValue), nil
}

// ========================
// Helper Functions - Type Conversions
// ========================

// bigIntToBytes32 converts a big.Int to a 32-byte array (little-endian for Zig)
func bigIntToBytes32(n *big.Int) [32]byte {
	var result [32]byte
	if n == nil {
		return result
	}
	
	// Get big-endian bytes
	bigEndian := n.Bytes()
	
	// Convert to little-endian (Zig expects little-endian)
	for i := 0; i < len(bigEndian) && i < 32; i++ {
		result[i] = bigEndian[len(bigEndian)-1-i]
	}
	
	return result
}

// bytes32ToBigInt converts a 32-byte array (little-endian from Zig) to big.Int
func bytes32ToBigInt(bytes [32]byte) *big.Int {
	// Convert from little-endian to big-endian
	var bigEndian [32]byte
	for i := 0; i < 32; i++ {
		bigEndian[31-i] = bytes[i]
	}
	
	// Trim leading zeros
	start := 0
	for start < 32 && bigEndian[start] == 0 {
		start++
	}
	
	if start == 32 {
		return big.NewInt(0)
	}
	
	return new(big.Int).SetBytes(bigEndian[start:])
}

// cAddress converts Go address to C
func cAddress(goAddr [20]byte) C.GuillotineAddress {
	var cAddr C.GuillotineAddress
	for i, b := range goAddr {
		cAddr.bytes[i] = C.uint8_t(b)
	}
	return cAddr
}

// goAddress converts C address to Go
func goAddress(cAddr C.GuillotineAddress) [20]byte {
	var goAddr [20]byte
	for i := 0; i < 20; i++ {
		goAddr[i] = byte(cAddr.bytes[i])
	}
	return goAddr
}

// cU256 converts Go U256 to C
func cU256(goU256 [32]byte) C.GuillotineU256 {
	var cU256 C.GuillotineU256
	for i, b := range goU256 {
		cU256.bytes[i] = C.uint8_t(b)
	}
	return cU256
}

// goU256 converts C U256 to Go
func goU256(cU256 C.GuillotineU256) [32]byte {
	var goU256 [32]byte
	for i := 0; i < 32; i++ {
		goU256[i] = byte(cU256.bytes[i])
	}
	return goU256
}

// cHash converts Go hash to C
func cHash(goHash [32]byte) C.GuillotineHash {
	var cHash C.GuillotineHash
	for i, b := range goHash {
		cHash.bytes[i] = C.uint8_t(b)
	}
	return cHash
}

// goHash converts C hash to Go
func goHash(cHash C.GuillotineHash) [32]byte {
	var goHash [32]byte
	for i := 0; i < 32; i++ {
		goHash[i] = byte(cHash.bytes[i])
	}
	return goHash
}

// cBytes converts Go bytes to C
func cBytes(goBytes []byte) C.GuillotineBytes {
	if len(goBytes) == 0 {
		return C.GuillotineBytes{data: nil, len: 0}
	}
	return C.GuillotineBytes{
		data: (*C.uint8_t)(C.CBytes(goBytes)),
		len:  C.size_t(len(goBytes)),
	}
}

// goBytes converts C bytes to Go
func goBytes(cBytes C.GuillotineBytes) []byte {
	if cBytes.len == 0 || cBytes.data == nil {
		return []byte{}
	}
	return C.GoBytes(unsafe.Pointer(cBytes.data), C.int(cBytes.len))
}

// freeBytes frees C bytes
func freeBytes(cBytes C.GuillotineBytes) {
	if cBytes.data != nil {
		C.free(unsafe.Pointer(cBytes.data))
	}
}

// convertCallResult converts C call result directly to public CallResult structure
func convertCallResult(result *C.GuillotineCallResult) *CallResult {
	goResult := &CallResult{
		Success: bool(result.success),
		GasLeft: uint64(result.gas_left),
	}
	
	// Copy output
	if result.output.len > 0 && result.output.data != nil {
		goResult.Output = C.GoBytes(unsafe.Pointer(result.output.data), C.int(result.output.len))
	} else {
		goResult.Output = []byte{}
	}
	
	// Copy logs
	if result.logs_len > 0 && result.logs != nil {
		logs := (*[1 << 30]C.GuillotineLog)(unsafe.Pointer(result.logs))[:result.logs_len:result.logs_len]
		goResult.Logs = make([]LogEntry, result.logs_len)
		
		for i, log := range logs {
			goResult.Logs[i].Address = primitives.NewAddress(goAddress(log.address))
			
			// Copy topics
			if log.topics_len > 0 && log.topics != nil {
				topics := (*[1 << 30]C.GuillotineU256)(unsafe.Pointer(log.topics))[:log.topics_len:log.topics_len]
				goResult.Logs[i].Topics = make([]*big.Int, log.topics_len)
				for j, topic := range topics {
					topicBytes := goU256(topic)
					// Topics from Zig are little-endian
					goResult.Logs[i].Topics[j] = bytes32ToBigInt(topicBytes)
				}
			} else {
				goResult.Logs[i].Topics = make([]*big.Int, 0)
			}
			
			// Copy data
			if log.data.len > 0 && log.data.data != nil {
				goResult.Logs[i].Data = C.GoBytes(unsafe.Pointer(log.data.data), C.int(log.data.len))
			} else {
				goResult.Logs[i].Data = []byte{}
			}
		}
	} else {
		goResult.Logs = make([]LogEntry, 0)
	}
	
	// Copy selfdestructs
	if result.selfdestructs_len > 0 && result.selfdestructs != nil {
		sds := (*[1 << 30]C.GuillotineSelfDestruct)(unsafe.Pointer(result.selfdestructs))[:result.selfdestructs_len:result.selfdestructs_len]
		goResult.SelfDestructs = make([]SelfDestructRecord, result.selfdestructs_len)
		
		for i, sd := range sds {
			goResult.SelfDestructs[i] = SelfDestructRecord{
				Contract:    primitives.NewAddress(goAddress(sd.contract)),
				Beneficiary: primitives.NewAddress(goAddress(sd.beneficiary)),
			}
		}
	} else {
		goResult.SelfDestructs = make([]SelfDestructRecord, 0)
	}
	
	// Copy accessed addresses
	if result.accessed_addresses_len > 0 && result.accessed_addresses != nil {
		addrs := (*[1 << 30]C.GuillotineAddress)(unsafe.Pointer(result.accessed_addresses))[:result.accessed_addresses_len:result.accessed_addresses_len]
		goResult.AccessedAddresses = make([]primitives.Address, result.accessed_addresses_len)
		
		for i, addr := range addrs {
			goResult.AccessedAddresses[i] = primitives.NewAddress(goAddress(addr))
		}
	} else {
		goResult.AccessedAddresses = make([]primitives.Address, 0)
	}
	
	// Copy accessed storage
	if result.accessed_storage_len > 0 && result.accessed_storage != nil {
		storages := (*[1 << 30]C.GuillotineStorageAccess)(unsafe.Pointer(result.accessed_storage))[:result.accessed_storage_len:result.accessed_storage_len]
		goResult.AccessedStorage = make([]StorageAccessRecord, result.accessed_storage_len)
		
		for i, storage := range storages {
			slotBytes := goU256(storage.slot)
			// Storage slots from Zig are little-endian
			goResult.AccessedStorage[i] = StorageAccessRecord{
				Address: primitives.NewAddress(goAddress(storage.address)),
				Slot:    bytes32ToBigInt(slotBytes),
			}
		}
	} else {
		goResult.AccessedStorage = make([]StorageAccessRecord, 0)
	}
	
	// Copy error info
	if result.error_info != nil {
		goResult.ErrorInfo = C.GoString(result.error_info)
	}
	
	return goResult
}

// ========================
// Utility Functions
// ========================

// IsInitialized checks if Guillotine is initialized
func IsInitialized() bool {
	return C.guillotine_is_initialized() != 0
}

// Version returns the Guillotine version string
func Version() string {
	return C.GoString(C.guillotine_version())
}