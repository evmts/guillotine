package evm

import (
	"fmt"
	"sync"

	"github.com/evmts/guillotine/sdks/go/evm"
)

type VMManager struct {
	mu       sync.RWMutex
	vm       *evm.EVM
	initOnce sync.Once
	initErr  error
}

var (
	instance *VMManager
	once     sync.Once
)

// GetVMManager returns the singleton VM manager instance
func GetVMManager() (*VMManager, error) {
	once.Do(func() {
		instance = &VMManager{}
	})

	instance.initOnce.Do(func() {
		vm, err := evm.New()
		if err != nil {
			instance.initErr = fmt.Errorf("failed to create EVM instance: %w", err)
			return
		}
		instance.vm = vm
	})

	return instance, instance.initErr
}

// GetVM returns the EVM instance
func (vm *VMManager) GetVM() (*evm.EVM, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()

	if vm.vm == nil {
		return nil, fmt.Errorf("VM not initialized")
	}
	return vm.vm, nil
}

// Reset creates a new VM instance, clearing all state
func (vm *VMManager) Reset() error {
	vm.mu.Lock()
	defer vm.mu.Unlock()

	if vm.vm != nil {
		vm.vm.Destroy()
	}

	newVM, err := evm.New()
	if err != nil {
		return fmt.Errorf("failed to reset VM: %w", err)
	}

	vm.vm = newVM
	return nil
}

// GetCode retrieves the deployed bytecode at the given address
func (vm *VMManager) GetCode(address string) ([]byte, error) {
	vm.mu.RLock()
	defer vm.mu.RUnlock()

	if vm.vm == nil {
		return nil, fmt.Errorf("VM not initialized")
	}

	// Parse address string to primitives.Address
	addr, err := ParseEthereumAddress(address)
	if err != nil {
		return nil, fmt.Errorf("invalid address format: %w", err)
	}

	code, err := vm.vm.GetCode(addr)
	if err != nil {
		return nil, fmt.Errorf("failed to get code: %w", err)
	}

	return code, nil
}


// Close releases the VM resources
func (vm *VMManager) Close() {
	vm.mu.Lock()
	defer vm.mu.Unlock()

	if vm.vm != nil {
		vm.vm.Destroy()
		vm.vm = nil
	}
}