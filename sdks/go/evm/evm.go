package evm

import (
	"fmt"
	"math/big"
	"runtime"
	"sync"
	
	guillotine "github.com/evmts/guillotine/sdks/go"
	"github.com/evmts/guillotine/sdks/go/primitives"
)

// ========================
// Call Parameter Interfaces
// ========================

// CallParams is the interface for all call types
type CallParams interface {
	callType() string
}

// Call represents a regular CALL operation
type Call struct {
	Caller primitives.Address
	To     primitives.Address
	Value  *big.Int
	Input  []byte
	Gas    uint64
}
func (c Call) callType() string { return "call" }

// Callcode represents a CALLCODE operation: execute external code with current storage/context
// Executes code at `to`, but uses caller's storage and address context
type Callcode struct {
	Caller primitives.Address
	To     primitives.Address
	Value  *big.Int
	Input  []byte
	Gas    uint64
}
func (c Callcode) callType() string { return "callcode" }

// Delegatecall represents a DELEGATECALL operation (preserves caller context)
type Delegatecall struct {
	Caller primitives.Address // Original caller, not current contract
	To     primitives.Address
	Input  []byte
	Gas    uint64
}
func (d Delegatecall) callType() string { return "delegatecall" }

// Staticcall represents a STATICCALL operation (read-only)
type Staticcall struct {
	Caller primitives.Address
	To     primitives.Address
	Input  []byte
	Gas    uint64
}
func (s Staticcall) callType() string { return "staticcall" }

// Create represents a CREATE operation
type Create struct {
	Caller   primitives.Address
	Value    *big.Int
	InitCode []byte
	Gas      uint64
}
func (c Create) callType() string { return "create" }

// Create2 represents a CREATE2 operation
type Create2 struct {
	Caller   primitives.Address
	Value    *big.Int
	InitCode []byte
	Salt     *big.Int
	Gas      uint64
}
func (c Create2) callType() string { return "create2" }

// ========================
// EVM Instance
// ========================

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
	_ = evm.Destroy()
}

// Close destroys the EVM instance
func (evm *EVM) Destroy() error {
	evm.mu.Lock()
	defer evm.mu.Unlock()
	
	if evm.vm != nil {
		err := evm.vm.Destroy()
		evm.vm = nil
		runtime.SetFinalizer(evm, nil)
		return err
	}
	return nil
}

// Call executes any type of EVM call using the interface parameter
func (evm *EVM) Call(params CallParams) (*guillotine.CallResult, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	// Convert interface to guillotine.CallParams based on type
	var callParams *guillotine.CallParams
	
	switch p := params.(type) {
	case Call:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeCall,
			Caller:   p.Caller,
			To:       p.To,
			Value:    p.Value,
			Input:    p.Input,
			Gas:      p.Gas,
			Salt:     big.NewInt(0),
		}
	case Callcode:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeCallcode,
			Caller:   p.Caller,
			To:       p.To,
			Value:    p.Value,
			Input:    p.Input,
			Gas:      p.Gas,
			Salt:     big.NewInt(0),
		}
	case Delegatecall:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeDelegatecall,
			Caller:   p.Caller,
			To:       p.To,
			Value:    big.NewInt(0),
			Input:    p.Input,
			Gas:      p.Gas,
			Salt:     big.NewInt(0),
		}
	case Staticcall:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeStaticcall,
			Caller:   p.Caller,
			To:       p.To,
			Value:    big.NewInt(0),
			Input:    p.Input,
			Gas:      p.Gas,
			Salt:     big.NewInt(0),
		}
	case Create:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeCreate,
			Caller:   p.Caller,
			To:       primitives.ZeroAddress(),
			Value:    p.Value,
			Input:    p.InitCode,
			Gas:      p.Gas,
			Salt:     big.NewInt(0),
		}
	case Create2:
		callParams = &guillotine.CallParams{
			CallType: guillotine.CallTypeCreate2,
			Caller:   p.Caller,
			To:       primitives.ZeroAddress(),
			Value:    p.Value,
			Input:    p.InitCode,
			Gas:      p.Gas,
			Salt:     p.Salt,
		}
	default:
		return nil, fmt.Errorf("unknown call type: %T", params)
	}
	
	// Execute through the VMHandle
	return evm.vm.Call(callParams)
}

// ========================
// State Management
// ========================

// SetBalance sets the balance of an address
func (evm *EVM) SetBalance(address primitives.Address, balance *big.Int) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetBalance(address.Array(), guillotine.BigIntToBytes32(balance))
}

// GetBalance gets the balance of an address
func (evm *EVM) GetBalance(address primitives.Address) (*big.Int, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	bytes, err := evm.vm.GetBalance(address.Array())
	if err != nil {
		return nil, err
	}
	return guillotine.Bytes32ToBigInt(bytes), nil
}

// SetCode sets the code at an address
func (evm *EVM) SetCode(address primitives.Address, code []byte) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetCode(address.Array(), code)
}

// GetCode gets the code at an address
func (evm *EVM) GetCode(address primitives.Address) ([]byte, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.GetCode(address.Array())
}

// SetStorage sets a storage value at an address
func (evm *EVM) SetStorage(address primitives.Address, key, value *big.Int) error {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return fmt.Errorf("EVM instance has been closed")
	}
	
	return evm.vm.SetStorage(address.Array(), guillotine.BigIntToBytes32(key), guillotine.BigIntToBytes32(value))
}

// GetStorage gets a storage value at an address
func (evm *EVM) GetStorage(address primitives.Address, key *big.Int) (*big.Int, error) {
	evm.mu.RLock()
	defer evm.mu.RUnlock()
	
	if evm.vm == nil {
		return nil, fmt.Errorf("EVM instance has been closed")
	}
	
	bytes, err := evm.vm.GetStorage(address.Array(), guillotine.BigIntToBytes32(key))
	if err != nil {
		return nil, err
	}
	return guillotine.Bytes32ToBigInt(bytes), nil
}

