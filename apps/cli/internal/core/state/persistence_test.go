package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"guillotine-cli/internal/types"
)

func TestGetStateFilePath(t *testing.T) {
	// Test custom environment variable
	customPath := "/custom/path/state.json"
	os.Setenv("GUILLOTINE_STATE_FILE", customPath)
	defer os.Unsetenv("GUILLOTINE_STATE_FILE")
	
	if path := GetStateFilePath(); path != customPath {
		t.Errorf("Expected custom path %s, got %s", customPath, path)
	}
}

func TestLoadStateFileNonExistent(t *testing.T) {
	tempDir := t.TempDir()
	nonExistentPath := filepath.Join(tempDir, "nonexistent.json")
	
	state, err := LoadStateFile(nonExistentPath)
	if err != nil {
		t.Fatalf("LoadStateFile should not error for non-existent file: %v", err)
	}
	
	if state.Version != StateFileVersion {
		t.Errorf("Expected version %s, got %s", StateFileVersion, state.Version)
	}
	
	if len(state.Calls) != 0 {
		t.Errorf("Expected empty calls array, got %d calls", len(state.Calls))
	}
}

func TestSaveAndLoadStateFile(t *testing.T) {
	tempDir := t.TempDir()
	testPath := filepath.Join(tempDir, StateFileName)
	
	// Create test state
	originalState := &StateFile{
		Version: StateFileVersion,
		Calls: []PersistedCall{
			{
				CallType:  "CALL",
				Caller:    "0x1234567890123456789012345678901234567890",
				Target:    "0x0987654321098765432109876543210987654321",
				Value:     "1000000",
				GasLimit:  "100000",
				InputData: "0x",
				Timestamp: time.Now().Unix(),
			},
		},
	}
	
	// Save state
	if err := SaveStateFile(testPath, originalState); err != nil {
		t.Fatalf("SaveStateFile failed: %v", err)
	}
	
	// Load state
	loadedState, err := LoadStateFile(testPath)
	if err != nil {
		t.Fatalf("LoadStateFile failed: %v", err)
	}
	
	// Verify
	if loadedState.Version != originalState.Version {
		t.Errorf("Expected version %s, got %s", originalState.Version, loadedState.Version)
	}
	
	if len(loadedState.Calls) != len(originalState.Calls) {
		t.Errorf("Expected %d calls, got %d", len(originalState.Calls), len(loadedState.Calls))
	}
	
	if loadedState.Calls[0].CallType != originalState.Calls[0].CallType {
		t.Errorf("Expected call type %s, got %s", 
			originalState.Calls[0].CallType, loadedState.Calls[0].CallType)
	}
}

func TestAppendCall(t *testing.T) {
	tempDir := t.TempDir()
	testPath := filepath.Join(tempDir, StateFileName)
	
	// First call
	call1 := PersistedCall{
		CallType:  "CALL",
		Caller:    "0x1111111111111111111111111111111111111111",
		Value:     "1000",
		GasLimit:  "50000",
		Timestamp: time.Now().Unix(),
	}
	
	if err := AppendCall(testPath, call1); err != nil {
		t.Fatalf("AppendCall failed: %v", err)
	}
	
	// Second call
	call2 := PersistedCall{
		CallType:  "CREATE",
		Caller:    "0x2222222222222222222222222222222222222222",
		Value:     "0",
		GasLimit:  "200000",
		InputData: "0x608060405234801561001057600080fd5b50",
		Timestamp: time.Now().Unix(),
	}
	
	if err := AppendCall(testPath, call2); err != nil {
		t.Fatalf("Second AppendCall failed: %v", err)
	}
	
	// Load and verify
	state, err := LoadStateFile(testPath)
	if err != nil {
		t.Fatalf("LoadStateFile failed: %v", err)
	}
	
	if len(state.Calls) != 2 {
		t.Errorf("Expected 2 calls, got %d", len(state.Calls))
	}
	
	if state.Calls[0].CallType != call1.CallType {
		t.Errorf("Expected first call type %s, got %s", call1.CallType, state.Calls[0].CallType)
	}
	
	if state.Calls[1].CallType != call2.CallType {
		t.Errorf("Expected second call type %s, got %s", call2.CallType, state.Calls[1].CallType)
	}
}

func TestConvertFromCallParameters(t *testing.T) {
	params := types.CallParametersStrings{
		CallType:  "STATICCALL",
		Caller:    "0x1111111111111111111111111111111111111111",
		Target:    "0x2222222222222222222222222222222222222222",
		Value:     "0",
		GasLimit:  "75000",
		InputData: "0x70a08231",
	}
	
	persisted := ConvertFromCallParameters(params, time.Now())
	
	if persisted.CallType != params.CallType {
		t.Errorf("Expected call type %s, got %s", params.CallType, persisted.CallType)
	}
	
	if persisted.Caller != params.Caller {
		t.Errorf("Expected caller %s, got %s", params.Caller, persisted.Caller)
	}
	
	if persisted.Timestamp == 0 {
		t.Error("Expected timestamp to be set, got 0")
	}
}

func TestConvertToCallParameters(t *testing.T) {
	persisted := PersistedCall{
		CallType:  "DELEGATECALL",
		Caller:    "0x3333333333333333333333333333333333333333",
		Target:    "0x4444444444444444444444444444444444444444",
		Value:     "500000",
		GasLimit:  "120000",
		InputData: "0xa9059cbb",
		Timestamp: time.Now().Unix(),
	}
	
	params := ConvertToCallParameters(persisted)
	
	if params.CallType != persisted.CallType {
		t.Errorf("Expected call type %s, got %s", persisted.CallType, params.CallType)
	}
	
	if params.Caller != persisted.Caller {
		t.Errorf("Expected caller %s, got %s", persisted.Caller, params.Caller)
	}
	
	if params.Target != persisted.Target {
		t.Errorf("Expected target %s, got %s", persisted.Target, params.Target)
	}
}

func TestClearStateFile(t *testing.T) {
	tempDir := t.TempDir()
	testPath := filepath.Join(tempDir, StateFileName)
	
	// Create a state file
	state := &StateFile{
		Version: StateFileVersion,
		Calls:   []PersistedCall{},
	}
	
	if err := SaveStateFile(testPath, state); err != nil {
		t.Fatalf("SaveStateFile failed: %v", err)
	}
	
	// Verify it exists
	if _, err := os.Stat(testPath); os.IsNotExist(err) {
		t.Fatal("State file should exist before clearing")
	}
	
	// Clear it
	if err := ClearStateFile(testPath); err != nil {
		t.Fatalf("ClearStateFile failed: %v", err)
	}
	
	// Verify it's gone
	if _, err := os.Stat(testPath); !os.IsNotExist(err) {
		t.Error("State file should not exist after clearing")
	}
}