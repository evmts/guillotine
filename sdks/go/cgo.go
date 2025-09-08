package guillotine

/*
#cgo CFLAGS: -I../../zig-out/include
#cgo LDFLAGS: -L../../zig-out/lib -lGuillotine

#include <stdlib.h>
#include <stdint.h>
#include <string.h>

// Zig-exported C functions
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
    size_t cap;
} GuillotineBytes;

typedef struct GuillotineVm GuillotineVm;

typedef struct {
    int success;
    uint64_t gas_used;
    GuillotineBytes return_data;
    GuillotineBytes revert_reason;
} GuillotineExecutionResult;

// Core functions
int guillotine_init(void);
void guillotine_deinit(void);

// VM operations
GuillotineVm* guillotine_vm_create(void);
void guillotine_vm_destroy(GuillotineVm* vm);

// Execution
GuillotineExecutionResult guillotine_vm_execute(
    GuillotineVm* vm,
    GuillotineBytes bytecode,
    GuillotineAddress caller,
    GuillotineAddress to,
    GuillotineU256 value,
    GuillotineBytes input,
    uint64_t gas_limit
);

// State management
int guillotine_vm_set_balance(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 balance);
int guillotine_vm_set_code(GuillotineVm* vm, GuillotineAddress address, GuillotineBytes code);
int guillotine_vm_set_storage(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 key, GuillotineU256 value);

GuillotineU256 guillotine_vm_get_balance(GuillotineVm* vm, GuillotineAddress address);
GuillotineBytes guillotine_vm_get_code(GuillotineVm* vm, GuillotineAddress address);
GuillotineU256 guillotine_vm_get_storage(GuillotineVm* vm, GuillotineAddress address, GuillotineU256 key);

// Memory management for bytes
GuillotineBytes guillotine_bytes_create(uint8_t* data, size_t len);
void guillotine_bytes_destroy(GuillotineBytes bytes);

// Utility functions
GuillotineAddress guillotine_address_from_hex(const char* hex_str);
char* guillotine_address_to_hex(GuillotineAddress address);
GuillotineU256 guillotine_u256_from_hex(const char* hex_str);
char* guillotine_u256_to_hex(GuillotineU256 value);
GuillotineHash guillotine_hash_from_hex(const char* hex_str);
char* guillotine_hash_to_hex(GuillotineHash hash);

// Arithmetic operations
GuillotineU256 guillotine_u256_add(GuillotineU256 a, GuillotineU256 b, int* overflow);
GuillotineU256 guillotine_u256_sub(GuillotineU256 a, GuillotineU256 b, int* underflow);
GuillotineU256 guillotine_u256_mul(GuillotineU256 a, GuillotineU256 b, int* overflow);
GuillotineU256 guillotine_u256_div(GuillotineU256 a, GuillotineU256 b, int* div_by_zero);

// Comparison operations
int guillotine_u256_eq(GuillotineU256 a, GuillotineU256 b);
int guillotine_u256_lt(GuillotineU256 a, GuillotineU256 b);
int guillotine_u256_gt(GuillotineU256 a, GuillotineU256 b);

// Address operations
int guillotine_address_eq(GuillotineAddress a, GuillotineAddress b);

// Hash operations
int guillotine_hash_eq(GuillotineHash a, GuillotineHash b);
*/
import "C"

import (
	"runtime"
	"sync"
	"unsafe"
)

var (
	initOnce sync.Once
	initErr  error
)

// Initialize the Guillotine library
func init() {
	initOnce.Do(func() {
		result := C.guillotine_init()
		if result != 0 {
			initErr = ErrInitializationFailed
		}
	})
}

// GetInitError returns any initialization error that occurred
func GetInitError() error {
	return initErr
}

// Helper functions for converting between Go and C types

func goBytes(cBytes C.GuillotineBytes) []byte {
	if cBytes.data == nil || cBytes.len == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(cBytes.data), C.int(cBytes.len))
}

func cBytes(goBytes []byte) C.GuillotineBytes {
	if len(goBytes) == 0 {
		return C.GuillotineBytes{data: nil, len: 0, cap: 0}
	}
	
	// Create a copy in C memory
	cData := C.malloc(C.size_t(len(goBytes)))
	C.memcpy(cData, unsafe.Pointer(&goBytes[0]), C.size_t(len(goBytes)))
	
	return C.GuillotineBytes{
		data: (*C.uint8_t)(cData),
		len:  C.size_t(len(goBytes)),
		cap:  C.size_t(len(goBytes)),
	}
}

func freeCBytes(cBytes C.GuillotineBytes) {
	if cBytes.data != nil {
		C.free(unsafe.Pointer(cBytes.data))
	}
}

func goString(cStr *C.char) string {
	if cStr == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(cStr))
	return C.GoString(cStr)
}

func cAddress(goAddr [20]byte) C.GuillotineAddress {
	var cAddr C.GuillotineAddress
	for i, b := range goAddr {
		cAddr.bytes[i] = C.uint8_t(b)
	}
	return cAddr
}

func goAddress(cAddr C.GuillotineAddress) [20]byte {
	var goAddr [20]byte
	for i := 0; i < 20; i++ {
		goAddr[i] = byte(cAddr.bytes[i])
	}
	return goAddr
}

func cU256(goU256 [32]byte) C.GuillotineU256 {
	var cU256 C.GuillotineU256
	for i, b := range goU256 {
		cU256.bytes[i] = C.uint8_t(b)
	}
	return cU256
}

func goU256(cU256 C.GuillotineU256) [32]byte {
	var goU256 [32]byte
	for i := 0; i < 32; i++ {
		goU256[i] = byte(cU256.bytes[i])
	}
	return goU256
}

func cHash(goHash [32]byte) C.GuillotineHash {
	var cHash C.GuillotineHash
	for i, b := range goHash {
		cHash.bytes[i] = C.uint8_t(b)
	}
	return cHash
}

func goHash(cHash C.GuillotineHash) [32]byte {
	var goHash [32]byte
	for i := 0; i < 32; i++ {
		goHash[i] = byte(cHash.bytes[i])
	}
	return goHash
}

// VM wrapper with finalizer
type vmHandle struct {
	ptr *C.GuillotineVm
	mu  sync.RWMutex
}

func newVMHandle() (*vmHandle, error) {
	if initErr != nil {
		return nil, initErr
	}
	
	ptr := C.guillotine_vm_create()
	if ptr == nil {
		return nil, ErrVMCreationFailed
	}
	
	vm := &vmHandle{ptr: ptr}
	runtime.SetFinalizer(vm, (*vmHandle).finalize)
	return vm, nil
}

func (vm *vmHandle) finalize() {
	vm.mu.Lock()
	defer vm.mu.Unlock()
	
	if vm.ptr != nil {
		C.guillotine_vm_destroy(vm.ptr)
		vm.ptr = nil
	}
}

func (vm *vmHandle) close() {
	runtime.SetFinalizer(vm, nil)
	vm.finalize()
}