package state

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"guillotine-cli/internal/types"
)

const (
	StateFileName    = "state.json"
	StateFileVersion = "1.0"
	DefaultStateDir  = ".guillotine"
)

type PersistedCall struct {
	CallType  string `json:"call_type"`
	Caller    string `json:"caller"`
	Target    string `json:"target,omitempty"`
	Value     string `json:"value"`
	GasLimit  string `json:"gas_limit"`
	InputData string `json:"input_data,omitempty"`
	Salt      string `json:"salt,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

type StateFile struct {
	Version string          `json:"version"`
	Calls   []PersistedCall `json:"calls"`
}

func GetStateFilePath() string {
	if custom := os.Getenv("GUILLOTINE_STATE_FILE"); custom != "" {
		return custom
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", DefaultStateDir, StateFileName)
	}
	return filepath.Join(home, DefaultStateDir, StateFileName)
}

func ensureStateDir() error {
	statePath := GetStateFilePath()
	stateDir := filepath.Dir(statePath)
	return os.MkdirAll(stateDir, 0755)
}

func LoadStateFile(path string) (*StateFile, error) {
	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &StateFile{
				Version: StateFileVersion,
				Calls:   make([]PersistedCall, 0),
			}, nil
		}
		return nil, fmt.Errorf("failed to open state file: %w", err)
	}
	defer file.Close()

	var state StateFile
	decoder := json.NewDecoder(file)
	if err := decoder.Decode(&state); err != nil {
		if err == io.EOF {
			return &StateFile{
				Version: StateFileVersion,
				Calls:   make([]PersistedCall, 0),
			}, nil
		}
		return nil, fmt.Errorf("failed to decode state file: %w", err)
	}

	if state.Version == "" {
		state.Version = StateFileVersion
	}

	if state.Calls == nil {
		state.Calls = make([]PersistedCall, 0)
	}

	return &state, nil
}

func SaveStateFile(path string, state *StateFile) error {
	if err := ensureStateDir(); err != nil {
		return fmt.Errorf("failed to create state directory: %w", err)
	}

	tempPath := path + ".tmp"
	file, err := os.Create(tempPath)
	if err != nil {
		return fmt.Errorf("failed to create temp state file: %w", err)
	}

	encoder := json.NewEncoder(file)
	encoder.SetIndent("", "  ")
	err = encoder.Encode(state)
	closeErr := file.Close()

	if err != nil {
		os.Remove(tempPath)
		return fmt.Errorf("failed to encode state file: %w", err)
	}

	if closeErr != nil {
		os.Remove(tempPath)
		return fmt.Errorf("failed to close state file: %w", closeErr)
	}

	if err := os.Rename(tempPath, path); err != nil {
		os.Remove(tempPath)
		return fmt.Errorf("failed to atomically write state file: %w", err)
	}

	return nil
}

func AppendCall(path string, call PersistedCall) error {
	state, err := LoadStateFile(path)
	if err != nil {
		return fmt.Errorf("failed to load existing state: %w", err)
	}

	state.Calls = append(state.Calls, call)

	return SaveStateFile(path, state)
}

func ConvertFromCallParameters(params types.CallParametersStrings, timestamp time.Time) PersistedCall {
	return PersistedCall{
		CallType:  params.CallType,
		Caller:    params.Caller,
		Target:    params.Target,
		Value:     params.Value,
		GasLimit:  params.GasLimit,
		InputData: params.InputData,
		Salt:      params.Salt,
		Timestamp: timestamp.Unix(),
	}
}

func ConvertToCallParameters(call PersistedCall) types.CallParametersStrings {
	return types.CallParametersStrings{
		CallType:  call.CallType,
		Caller:    call.Caller,
		Target:    call.Target,
		Value:     call.Value,
		GasLimit:  call.GasLimit,
		InputData: call.InputData,
		Salt:      call.Salt,
	}
}

func ClearStateFile(path string) error {
	return os.Remove(path)
}