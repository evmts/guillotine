package stack

/*
#cgo CFLAGS: -I../../../zig-out/include
#cgo LDFLAGS: -L../../../zig-out/lib -levm_c

#include <stdlib.h>
#include <stdint.h>

// Stack C API declarations
typedef struct StackHandle StackHandle;

// Lifecycle
StackHandle* evm_stack_create(void);
void evm_stack_destroy(StackHandle* handle);
int evm_stack_reset(StackHandle* handle);

// Push operations
int evm_stack_push_u64(StackHandle* handle, uint64_t value);
int evm_stack_push_bytes(StackHandle* handle, const uint8_t bytes[32]);

// Pop operations  
int evm_stack_pop_u64(StackHandle* handle, uint64_t* value_out);
int evm_stack_pop_bytes(StackHandle* handle, uint8_t bytes_out[32]);

// Peek operations
int evm_stack_peek_u64(const StackHandle* handle, uint64_t* value_out);
int evm_stack_peek_bytes(const StackHandle* handle, uint8_t bytes_out[32]);
int evm_stack_peek_at(const StackHandle* handle, uint32_t depth, uint8_t bytes_out[32]);

// EVM operations
int evm_stack_dup(StackHandle* handle, uint32_t depth);
int evm_stack_swap(StackHandle* handle, uint32_t depth);

// Status
uint32_t evm_stack_size(const StackHandle* handle);
int evm_stack_is_empty(const StackHandle* handle);
int evm_stack_is_full(const StackHandle* handle);
uint32_t evm_stack_capacity(const StackHandle* handle);

// Contents
int evm_stack_get_contents(const StackHandle* handle, uint8_t* buffer, uint32_t max_items, uint32_t* count_out);

// Error codes
#define EVM_STACK_SUCCESS 0
#define EVM_STACK_ERROR_NULL_POINTER -1
#define EVM_STACK_ERROR_OVERFLOW -2
#define EVM_STACK_ERROR_UNDERFLOW -3
#define EVM_STACK_ERROR_OUT_OF_MEMORY -4
#define EVM_STACK_ERROR_INVALID_INDEX -5
*/
import "C"

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"github.com/evmts/guillotine/bindings/go/primitives"
)

var (
	// ErrStackClosed is returned when operation is attempted on closed stack
	ErrStackClosed = errors.New("stack is closed")
	// ErrStackOverflow is returned when stack is full
	ErrStackOverflow = errors.New("stack overflow")
	// ErrStackUnderflow is returned when stack is empty
	ErrStackUnderflow = errors.New("stack underflow")  
	// ErrInvalidIndex is returned when index is out of bounds
	ErrInvalidIndex = errors.New("invalid index")
	// ErrOutOfMemory is returned on memory allocation failure
	ErrOutOfMemory = errors.New("out of memory")
)

// Stack represents an EVM execution stack
type Stack struct {
	handle *C.StackHandle
	mu     sync.RWMutex
	closed bool
}

// New creates a new EVM stack
func New() (*Stack, error) {
	handle := C.evm_stack_create()
	if handle == nil {
		return nil, ErrOutOfMemory
	}

	stack := &Stack{
		handle: handle,
	}

	// Set finalizer for automatic cleanup
	runtime.SetFinalizer(stack, (*Stack).finalize)

	return stack, nil
}

// Close releases the stack resources
func (s *Stack) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return nil // Already closed
	}

	if s.handle != nil {
		C.evm_stack_destroy(s.handle)
		s.handle = nil
	}

	s.closed = true
	runtime.SetFinalizer(s, nil)
	return nil
}

// finalize is called by garbage collector
func (s *Stack) finalize() {
	s.Close()
}

// Reset clears the stack to empty state
func (s *Stack) Reset() error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrStackClosed
	}

	result := C.evm_stack_reset(s.handle)
	return cErrorToGoError(result)
}

// PushU64 pushes a 64-bit value onto the stack (zero-extended to 256 bits)
func (s *Stack) PushU64(value uint64) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrStackClosed
	}

	result := C.evm_stack_push_u64(s.handle, C.uint64_t(value))
	return cErrorToGoError(result)
}

// PushU256 pushes a 256-bit value onto the stack
func (s *Stack) PushU256(value primitives.U256) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrStackClosed
	}

	// Convert U256 to big-endian bytes
	bytes := value.Bytes()
	var cBytes [32]C.uint8_t
	for i := 0; i < 32; i++ {
		cBytes[i] = C.uint8_t(bytes[i])
	}

	result := C.evm_stack_push_bytes(s.handle, (*C.uint8_t)(&cBytes[0]))
	return cErrorToGoError(result)
}

// PopU64 pops and returns a 64-bit value from the stack
func (s *Stack) PopU64() (uint64, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return 0, ErrStackClosed
	}

	var value C.uint64_t
	result := C.evm_stack_pop_u64(s.handle, &value)
	if err := cErrorToGoError(result); err != nil {
		return 0, err
	}

	return uint64(value), nil
}

// PopU256 pops and returns a 256-bit value from the stack
func (s *Stack) PopU256() (primitives.U256, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return primitives.ZeroU256(), ErrStackClosed
	}

	var cBytes [32]C.uint8_t
	result := C.evm_stack_pop_bytes(s.handle, (*C.uint8_t)(&cBytes[0]))
	if err := cErrorToGoError(result); err != nil {
		return primitives.ZeroU256(), err
	}

	// Convert C bytes to Go bytes
	bytes := make([]byte, 32)
	for i := 0; i < 32; i++ {
		bytes[i] = byte(cBytes[i])
	}

	u256, err := primitives.U256FromBytes(bytes)
	if err != nil {
		return primitives.ZeroU256(), fmt.Errorf("failed to parse U256: %w", err)
	}

	return u256, nil
}

// PeekU64 returns the top 64-bit value without removing it
func (s *Stack) PeekU64() (uint64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return 0, ErrStackClosed
	}

	var value C.uint64_t
	result := C.evm_stack_peek_u64(s.handle, &value)
	if err := cErrorToGoError(result); err != nil {
		return 0, err
	}

	return uint64(value), nil
}

// PeekU256 returns the top 256-bit value without removing it
func (s *Stack) PeekU256() (primitives.U256, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return primitives.ZeroU256(), ErrStackClosed
	}

	var cBytes [32]C.uint8_t
	result := C.evm_stack_peek_bytes(s.handle, (*C.uint8_t)(&cBytes[0]))
	if err := cErrorToGoError(result); err != nil {
		return primitives.ZeroU256(), err
	}

	// Convert C bytes to Go bytes
	bytes := make([]byte, 32)
	for i := 0; i < 32; i++ {
		bytes[i] = byte(cBytes[i])
	}

	u256, err := primitives.U256FromBytes(bytes)
	if err != nil {
		return primitives.ZeroU256(), fmt.Errorf("failed to parse U256: %w", err)
	}

	return u256, nil
}

// PeekAt returns the value at the given depth (0 = top) as a 64-bit value
func (s *Stack) PeekAt(depth uint32) (uint64, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return 0, ErrStackClosed
	}

	var cBytes [32]C.uint8_t
	result := C.evm_stack_peek_at(s.handle, C.uint32_t(depth), (*C.uint8_t)(&cBytes[0]))
	if err := cErrorToGoError(result); err != nil {
		return 0, err
	}

	// Convert bytes to U256, then extract lower 64 bits
	bytes := make([]byte, 32)
	for i := 0; i < 32; i++ {
		bytes[i] = byte(cBytes[i])
	}

	u256, err := primitives.U256FromBytes(bytes)
	if err != nil {
		return 0, fmt.Errorf("failed to parse U256: %w", err)
	}

	// Extract the lower 64 bits (assuming little-endian internal representation)
	return u256.Uint64(), nil
}

// PeekAtU256 returns the 256-bit value at the given depth (0 = top)
func (s *Stack) PeekAtU256(depth uint32) (primitives.U256, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return primitives.ZeroU256(), ErrStackClosed
	}

	var cBytes [32]C.uint8_t
	result := C.evm_stack_peek_at(s.handle, C.uint32_t(depth), (*C.uint8_t)(&cBytes[0]))
	if err := cErrorToGoError(result); err != nil {
		return primitives.ZeroU256(), err
	}

	// Convert C bytes to Go bytes
	bytes := make([]byte, 32)
	for i := 0; i < 32; i++ {
		bytes[i] = byte(cBytes[i])
	}

	u256, err := primitives.U256FromBytes(bytes)
	if err != nil {
		return primitives.ZeroU256(), fmt.Errorf("failed to parse U256: %w", err)
	}

	return u256, nil
}

// Dup duplicates the stack item at the given depth
// depth=1 duplicates the top item (DUP1), depth=2 duplicates second item (DUP2), etc.
func (s *Stack) Dup(depth uint32) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrStackClosed
	}

	// Convert from 1-based EVM convention to 0-based C API convention
	if depth == 0 {
		return ErrInvalidIndex
	}
	cDepth := depth - 1

	result := C.evm_stack_dup(s.handle, C.uint32_t(cDepth))
	return cErrorToGoError(result)
}

// Swap exchanges the top item with the item at the given depth
// depth=1 swaps top two items (SWAP1), depth=2 swaps top and third (SWAP2), etc.
func (s *Stack) Swap(depth uint32) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.closed {
		return ErrStackClosed
	}

	result := C.evm_stack_swap(s.handle, C.uint32_t(depth))
	return cErrorToGoError(result)
}

// Size returns the current number of items on the stack
func (s *Stack) Size() uint32 {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return 0
	}

	return uint32(C.evm_stack_size(s.handle))
}

// IsEmpty returns true if the stack has no items
func (s *Stack) IsEmpty() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return true
	}

	return C.evm_stack_is_empty(s.handle) != 0
}

// IsFull returns true if the stack is at capacity
func (s *Stack) IsFull() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return false
	}

	return C.evm_stack_is_full(s.handle) != 0
}

// Capacity returns the maximum number of items the stack can hold
func (s *Stack) Capacity() uint32 {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return 0
	}

	return uint32(C.evm_stack_capacity(s.handle))
}

// GetContents returns all items on the stack (top to bottom order)
func (s *Stack) GetContents() ([]primitives.U256, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if s.closed {
		return nil, ErrStackClosed
	}

	size := uint32(C.evm_stack_size(s.handle))
	if size == 0 {
		return []primitives.U256{}, nil
	}

	// Allocate buffer for all stack contents (32 bytes per item)
	bufferSize := size * 32
	buffer := make([]byte, bufferSize)
	var count C.uint32_t

	result := C.evm_stack_get_contents(
		s.handle,
		(*C.uint8_t)(unsafe.Pointer(&buffer[0])),
		C.uint32_t(size),
		&count,
	)

	if err := cErrorToGoError(result); err != nil {
		return nil, err
	}

	// Convert buffer to U256 values
	items := make([]primitives.U256, count)
	for i := uint32(0); i < uint32(count); i++ {
		start := i * 32
		end := start + 32
		itemBytes := buffer[start:end]
		
		u256, err := primitives.U256FromBytes(itemBytes)
		if err != nil {
			return nil, fmt.Errorf("failed to parse U256 at index %d: %w", i, err)
		}
		
		items[i] = u256
	}

	return items, nil
}

// cErrorToGoError converts C error codes to Go errors
func cErrorToGoError(code C.int) error {
	switch code {
	case C.EVM_STACK_SUCCESS:
		return nil
	case C.EVM_STACK_ERROR_NULL_POINTER:
		return ErrStackClosed
	case C.EVM_STACK_ERROR_OVERFLOW:
		return ErrStackOverflow
	case C.EVM_STACK_ERROR_UNDERFLOW:
		return ErrStackUnderflow
	case C.EVM_STACK_ERROR_OUT_OF_MEMORY:
		return ErrOutOfMemory
	case C.EVM_STACK_ERROR_INVALID_INDEX:
		return ErrInvalidIndex
	default:
		return fmt.Errorf("unknown stack error: %d", int(code))
	}
}