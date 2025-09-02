package evm

import (
	"fmt"
	"runtime"
	"sync"
	
	"github.com/evmts/guillotine/bindings/go"
	"github.com/evmts/guillotine/bindings/go/primitives"
)

// Re-export types from guillotine package for public API
type CallType = guillotine.CallType
type CallParams = guillotine.CallParams
type CallResult = guillotine.CallResult
type LogEntry = guillotine.LogEntry
type SelfDestructRecord = guillotine.SelfDestructRecord
type StorageAccessRecord = guillotine.StorageAccessRecord

// Re-export constants
const (
	CallTypeCall         = guillotine.CallTypeCall
	CallTypeCallcode     = guillotine.CallTypeCallcode
	CallTypeDelegatecall = guillotine.CallTypeDelegatecall
	CallTypeStaticcall   = guillotine.CallTypeStaticcall
	CallTypeCreate       = guillotine.CallTypeCreate
	CallTypeCreate2      = guillotine.CallTypeCreate2
)

// EVM represents an instance of the Ethereum Virtual Machine
type EVM struct {
	vm *guillotine.VMHandle
	mu sync.RWMutex
}

// New creates a new EVM instance
func New() (*EVM, error) {
	vm, err := guillotine.NewVMHandle()
	if err != nil {
		return nil, fmt.Errorf("failed to create EVM instance: %w", err)
	}
	
	evm := &EVM{vm: vm}
	runtime.SetFinalizer(evm, (*EVM).finalize)
	return evm, nil
}

// finalize is called by the garbage collector
func (evm *EVM) finalize() {
	_ = evm.Close()
}

// Close destroys the EVM instance
func (evm *EVM) Close() error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm != nil {
		err := evm.vm.Close()
		evm.vm = nil
		runtime.SetFinalizer(evm, nil)
		return err
	}
	return nil
}

// ExecuteWithParams executes bytecode with complete call parameters
func (evm *EVM) ExecuteWithParams(params CallParams) (*CallResult, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	// Convert primitives to raw bytes for VMHandle
	callType := uint8(params.CallType)
	caller := params.Caller.Array()
	to := params.To.Array()  
	value := params.Value.Array()
	input := params.Input.Data()
	salt := params.Salt.Array()
	
	// Execute through the guillotine VMHandle - now returns public types directly
	result, err := evm.vm.ExecuteWithParams(callType, caller, to, value, input, params.Gas, salt)
	if err != nil {
		return nil, err
	}
	
	return result, nil
}

// ExecuteCall performs a simple CALL operation
func (evm *EVM) ExecuteCall(caller, to primitives.Address, value primitives.U256, input primitives.Bytes, gasLimit uint64) (*CallResult, error) {
	return evm.ExecuteWithParams(CallParams{
		CallType: CallTypeCall,
		Caller:   caller,
		To:       to,
		Value:    value,
		Input:    input,
		Gas:      gasLimit,
		Salt:     primitives.ZeroU256(),
	})
}

// ExecuteStaticCall performs a STATICCALL operation (read-only)
func (evm *EVM) ExecuteStaticCall(caller, to primitives.Address, input primitives.Bytes, gasLimit uint64) (*CallResult, error) {
	return evm.ExecuteWithParams(CallParams{
		CallType: CallTypeStaticcall,
		Caller:   caller,
		To:       to,
		Value:    primitives.ZeroU256(),
		Input:    input,
		Gas:      gasLimit,
		Salt:     primitives.ZeroU256(),
	})
}

// ExecuteDelegateCall performs a DELEGATECALL operation
func (evm *EVM) ExecuteDelegateCall(caller, to primitives.Address, input primitives.Bytes, gasLimit uint64) (*CallResult, error) {
	return evm.ExecuteWithParams(CallParams{
		CallType: CallTypeDelegatecall,
		Caller:   caller,
		To:       to,
		Value:    primitives.ZeroU256(),
		Input:    input,
		Gas:      gasLimit,
		Salt:     primitives.ZeroU256(),
	})
}

// ExecuteCreate performs a CREATE operation
func (evm *EVM) ExecuteCreate(caller primitives.Address, value primitives.U256, initCode primitives.Bytes, gasLimit uint64) (*CallResult, error) {
	return evm.ExecuteWithParams(CallParams{
		CallType: CallTypeCreate,
		Caller:   caller,
		To:       primitives.ZeroAddress(),
		Value:    value,
		Input:    initCode,
		Gas:      gasLimit,
		Salt:     primitives.ZeroU256(),
	})
}

// ExecuteCreate2 performs a CREATE2 operation
func (evm *EVM) ExecuteCreate2(caller primitives.Address, value primitives.U256, initCode primitives.Bytes, salt primitives.U256, gasLimit uint64) (*CallResult, error) {
	return evm.ExecuteWithParams(CallParams{
		CallType: CallTypeCreate2,
		Caller:   caller,
		To:       primitives.ZeroAddress(),
		Value:    value,
		Input:    initCode,
		Gas:      gasLimit,
		Salt:     salt,
	})
}

// SetBalance sets the balance of an address
func (evm *EVM) SetBalance(addr primitives.Address, balance primitives.U256) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetBalance(addr.Array(), balance.Array())
}

// GetBalance gets the balance of an address
func (evm *EVM) GetBalance(addr primitives.Address) (primitives.U256, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.ZeroU256(), fmt.Errorf("EVM instance has been closed")
	}
	
	balanceBytes, err := evm.vm.GetBalance(addr.Array())
	if err != nil {
		return primitives.ZeroU256(), err
	}
	
	// Zig returns little-endian bytes
	result, err := primitives.U256FromLittleEndianBytes(balanceBytes[:])
	if err != nil {
		return primitives.ZeroU256(), err
	}
	return result, nil
}

// SetCode sets the code at an address
func (evm *EVM) SetCode(addr primitives.Address, code primitives.Bytes) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetCode(addr.Array(), code.Data())
}

// GetCode gets the code at an address
func (evm *EVM) GetCode(addr primitives.Address) (primitives.Bytes, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.EmptyBytes(), fmt.Errorf("EVM instance has been closed")
	}
	
	codeBytes, err := evm.vm.GetCode(addr.Array())
	if err != nil {
		return primitives.EmptyBytes(), err
	}
	
	return primitives.NewBytes(codeBytes), nil
}

// SetStorage sets a storage value at an address
func (evm *EVM) SetStorage(addr primitives.Address, key, value primitives.U256) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetStorage(addr.Array(), key.Array(), value.Array())
}

// GetStorage gets a storage value at an address
func (evm *EVM) GetStorage(addr primitives.Address, key primitives.U256) (primitives.U256, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return primitives.ZeroU256(), fmt.Errorf("EVM instance has been closed")
	}
	
	valueBytes, err := evm.vm.GetStorage(addr.Array(), key.Array())
	if err != nil {
		return primitives.ZeroU256(), err
	}
	
	// Zig returns little-endian bytes
	result, err := primitives.U256FromLittleEndianBytes(valueBytes[:])
	if err != nil {
		return primitives.ZeroU256(), err
	}
	return result, nil
}
