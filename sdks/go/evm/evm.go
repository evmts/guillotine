package evm

import (
	"sync"
	"unsafe"
	
	"github.com/evmts/guillotine/bindings/go/primitives"
)

/*
#cgo CFLAGS: -I../../../zig-out/include
#cgo LDFLAGS: -L../../../zig-out/lib -lGuillotine

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t bytes[20];
} GuillotineAddress;

typedef struct {
    uint8_t bytes[32];
} GuillotineU256;

typedef struct {
    uint8_t* data;
    size_t len;
    size_t cap;
} GuillotineBytes;

typedef struct GuillotineVm GuillotineVm;

typedef struct {
    int success;
    uint64_t gas_used;
    GuillotineBytes return_data;
    GuillotineBytes revert_reason;
} GuillotineExecutionResult;

int guillotine_init(void);
GuillotineVm* guillotine_vm_create(void);
void guillotine_vm_destroy(GuillotineVm* vm);

GuillotineExecutionResult guillotine_vm_execute(
    GuillotineVm* vm,
    GuillotineBytes bytecode,
    GuillotineAddress caller,
    GuillotineAddress to,
    GuillotineU256 value,
    GuillotineBytes input,
    uint64_t gas_limit
);

int guillotine_vm_set_balance(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 balance);
int guillotine_vm_set_code(GuillotineVm* vm, GuillotineAddress address, GuillotineBytes code);
int guillotine_vm_set_storage(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 key, GuillotineU256 value);

GuillotineU256 guillotine_vm_get_balance(GuillotineVm* vm, GuillotineAddress address);
GuillotineBytes guillotine_vm_get_code(GuillotineVm* vm, GuillotineAddress address);
GuillotineU256 guillotine_vm_get_storage(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 key);

void guillotine_bytes_destroy(GuillotineBytes bytes);
*/
import "C"

import (
	"fmt"
	"runtime"
)

// EVM represents a Guillotine EVM instance
type EVM struct {
	vm *C.GuillotineVm
	mu sync.RWMutex
}

// ExecutionParams holds parameters for EVM execution
type ExecutionParams struct {
	Bytecode primitives.Bytes
	Caller   primitives.Address
	To       primitives.Address
	Value    primitives.U256
	Input    primitives.Bytes
	GasLimit uint64
}

// New creates a new EVM instance
func New() (*EVM, error) {
	// Initialize the library if not already done
	if result := C.guillotine_init(); result != 0 {
		return nil, fmt.Errorf("failed to initialize Guillotine library")
	}
	
	vm := C.guillotine_vm_create()
	if vm == nil {
		return nil, fmt.Errorf("failed to create VM instance")
	}
	
	evm := &EVM{vm: vm}
	runtime.SetFinalizer(evm, (*EVM).finalize)
	return evm, nil
}

// Close closes the EVM instance and releases resources
func (evm *EVM) Close() error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm != nil {
		C.guillotine_vm_destroy(evm.vm)
		evm.vm = nil
		runtime.SetFinalizer(evm, nil)
	}
	
	return nil
}

// finalize is called by the garbage collector
func (evm *EVM) finalize() {
	evm.Close()
}

// Execute executes bytecode on the EVM
func (evm *EVM) Execute(params ExecutionParams) (*ExecutionResult, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	// Convert Go types to C types
	cBytecode := bytesToC(params.Bytecode)
	defer freeCBytes(cBytecode)
	
	cCaller := addressToC(params.Caller)
	cTo := addressToC(params.To)
	cValue := u256ToC(params.Value)
	
	cInput := bytesToC(params.Input)
	defer freeCBytes(cInput)
	
	// Call the C function
	result := C.guillotine_vm_execute(
		evm.vm,
		cBytecode,
		cCaller,
		cTo,
		cValue,
		cInput,
		C.uint64_t(params.GasLimit),
	)
	
	// Convert result back to Go
	goResult := &ExecutionResult{
		success:     result.success != 0,
		gasUsed:     uint64(result.gas_used),
		returnData:  bytesFromC(result.return_data),
		revertReason: bytesFromC(result.revert_reason),
	}
	
	// Clean up C memory
	C.guillotine_bytes_destroy(result.return_data)
	C.guillotine_bytes_destroy(result.revert_reason)
	
	return goResult, nil
}

// SetBalance sets the balance of an account
func (evm *EVM) SetBalance(address primitives.Address, balance primitives.U256) error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cBalance := u256ToC(balance)
	
	result := C.guillotine_vm_set_balance(evm.vm, cAddress, cBalance)
	if result != 0 {
		return fmt.Errorf("failed to set balance")
	}
	
	return nil
}

// SetCode sets the code of an account
func (evm *EVM) SetCode(address primitives.Address, code primitives.Bytes) error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cCode := bytesToC(code)
	defer freeCBytes(cCode)
	
	result := C.guillotine_vm_set_code(evm.vm, cAddress, cCode)
	if result != 0 {
		return fmt.Errorf("failed to set code")
	}
	
	return nil
}

// SetStorage sets a storage slot for an account
func (evm *EVM) SetStorage(address primitives.Address, key primitives.U256, value primitives.U256) error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cKey := u256ToC(key)
	cValue := u256ToC(value)
	
	result := C.guillotine_vm_set_storage(evm.vm, cAddress, cKey, cValue)
	if result != 0 {
		return fmt.Errorf("failed to set storage")
	}
	
	return nil
}

// GetBalance gets the balance of an account
func (evm *EVM) GetBalance(address primitives.Address) (primitives.U256, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.ZeroU256(), fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cBalance := C.guillotine_vm_get_balance(evm.vm, cAddress)
	
	return u256FromC(cBalance), nil
}

// GetCode gets the code of an account
func (evm *EVM) GetCode(address primitives.Address) (primitives.Bytes, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.EmptyBytes(), fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cCode := C.guillotine_vm_get_code(evm.vm, cAddress)
	defer C.guillotine_bytes_destroy(cCode)
	
	return bytesFromC(cCode), nil
}

// GetStorage gets a storage slot for an account
func (evm *EVM) GetStorage(address primitives.Address, key primitives.U256) (primitives.U256, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.ZeroU256(), fmt.Errorf("EVM instance has been closed")
	}
	
	cAddress := addressToC(address)
	cKey := u256ToC(key)
	cValue := C.guillotine_vm_get_storage(evm.vm, cAddress, cKey)
	
	return u256FromC(cValue), nil
}

// Helper functions for type conversion

func bytesToC(b primitives.Bytes) C.GuillotineBytes {
	data := b.Data()
	if len(data) == 0 {
		return C.GuillotineBytes{data: nil, len: 0, cap: 0}
	}
	
	// Allocate C memory and copy data
	cData := C.malloc(C.size_t(len(data)))
	C.memcpy(cData, unsafe.Pointer(&data[0]), C.size_t(len(data)))
	
	return C.GuillotineBytes{
		data: (*C.uint8_t)(cData),
		len:  C.size_t(len(data)),
		cap:  C.size_t(len(data)),
	}
}

func bytesFromC(cBytes C.GuillotineBytes) primitives.Bytes {
	if cBytes.data == nil || cBytes.len == 0 {
		return primitives.EmptyBytes()
	}
	
	data := C.GoBytes(unsafe.Pointer(cBytes.data), C.int(cBytes.len))
	return primitives.NewBytes(data)
}

func freeCBytes(cBytes C.GuillotineBytes) {
	if cBytes.data != nil {
		C.free(unsafe.Pointer(cBytes.data))
	}
}

func addressToC(addr primitives.Address) C.GuillotineAddress {
	var cAddr C.GuillotineAddress
	bytes := addr.Array()
	for i, b := range bytes {
		cAddr.bytes[i] = C.uint8_t(b)
	}
	return cAddr
}

func addressFromC(cAddr C.GuillotineAddress) primitives.Address {
	var bytes [20]byte
	for i := 0; i < 20; i++ {
		bytes[i] = byte(cAddr.bytes[i])
	}
	return primitives.NewAddress(bytes)
}

func u256ToC(u primitives.U256) C.GuillotineU256 {
	var cU256 C.GuillotineU256
	bytes := u.Array() // Little-endian internal representation
	for i, b := range bytes {
		cU256.bytes[i] = C.uint8_t(b)
	}
	return cU256
}

func u256FromC(cU256 C.GuillotineU256) primitives.U256 {
	var bytes [32]byte
	for i := 0; i < 32; i++ {
		bytes[i] = byte(cU256.bytes[i])
	}
	
	// Create U256 from the byte array (assuming it's in the correct internal format)
	u256, _ := primitives.U256FromBytes(reverseBytes(bytes[:])) // Convert from little-endian to big-endian for FromBytes
	return u256
}

func reverseBytes(b []byte) []byte {
	result := make([]byte, len(b))
	for i, j := 0, len(b)-1; i < len(b); i, j = i+1, j-1 {
		result[i] = b[j]
	}
	return result
}