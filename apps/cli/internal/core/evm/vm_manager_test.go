package evm

import (
	"testing"
)

func TestGetVMManager(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	if vmMgr == nil {
		t.Fatal("VM manager is nil")
	}

	// Test that we get the same instance (singleton)
	vmMgr2, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager second time: %v", err)
	}

	if vmMgr != vmMgr2 {
		t.Error("GetVMManager() should return same instance")
	}
}

func TestVMManager_GetVM(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	vm, err := vmMgr.GetVM()
	if err != nil {
		t.Fatalf("Failed to get VM: %v", err)
	}

	if vm == nil {
		t.Fatal("VM is nil")
	}
}

func TestVMManager_Reset(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	// Get initial VM
	vm1, err := vmMgr.GetVM()
	if err != nil {
		t.Fatalf("Failed to get initial VM: %v", err)
	}

	// Reset
	err = vmMgr.Reset()
	if err != nil {
		t.Fatalf("Failed to reset VM: %v", err)
	}

	// Get VM after reset
	vm2, err := vmMgr.GetVM()
	if err != nil {
		t.Fatalf("Failed to get VM after reset: %v", err)
	}

	if vm2 == nil {
		t.Fatal("VM is nil after reset")
	}

	// Note: We can't directly compare VM pointers as they're internal
	// But we verify both operations succeed
	_ = vm1 // Use vm1 to avoid unused variable warning
}

func TestVMManager_GetCode(t *testing.T) {
	vmMgr, err := GetVMManager()
	if err != nil {
		t.Fatalf("Failed to get VM manager: %v", err)
	}

	// Test with a valid address format (should return empty code for non-existent contract)
	code, err := vmMgr.GetCode("0x0000000000000000000000000000000000000000")
	if err != nil {
		t.Fatalf("Failed to get code: %v", err)
	}

	if code == nil {
		t.Fatal("Code should not be nil (empty is ok)")
	}

	// Test with invalid address
	_, err = vmMgr.GetCode("invalid")
	if err == nil {
		t.Error("Expected error for invalid address")
	}
}