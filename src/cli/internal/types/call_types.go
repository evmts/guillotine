package types

import (
	"time"
	
	"guillotine-cli/internal/config"
	"github.com/evmts/guillotine/bindings/go/evm"
)

type AppState int

const (
	StateMainMenu AppState = iota
	StateCallParameterList
	StateCallParameterEdit
	StateCallTypeEdit
	StateCallExecuting
	StateCallResult
	StateCallHistory
	StateCallHistoryDetail
	StateContracts
	StateContractDetail
	StateConfirmReset
)

type CallParameter struct {
	Name  string
	Value string
}

type CallParameters struct {
	CallType   string
	Caller     string
	Target     string
	Value      string
	InputData  string
	GasLimit   string
	Salt       string
}

func (cp *CallParameters) GetParams() []CallParameter {
	// Define parameter visibility rules based on call type
	paramConfig := []struct {
		name      string
		value     string
		showWhen  func(string) bool
		nameFunc  func(string) string
	}{
		{
			name:     config.CallParamCallType,
			value:    cp.CallType,
			showWhen: func(t string) bool { return true },
		},
		{
			name:     config.CallParamCaller,
			value:    cp.Caller,
			showWhen: func(t string) bool { return true },
		},
		{
			name:     config.CallParamTarget,
			value:    cp.Target,
			showWhen: func(t string) bool { return t != config.CallTypeCreate && t != config.CallTypeCreate2 },
		},
		{
			name:     config.CallParamValue,
			value:    cp.Value,
			showWhen: func(t string) bool { return t != config.CallTypeStaticCall },
		},
		{
			name:     config.CallParamGasLimit,
			value:    cp.GasLimit,
			showWhen: func(t string) bool { return true },
		},
		{
			name:     config.CallParamInput,
			value:    cp.InputData,
			showWhen: func(t string) bool { return true },
			nameFunc: func(t string) string {
				if t == config.CallTypeCreate || t == config.CallTypeCreate2 {
					return config.CallParamInputDeploy
				}
				return config.CallParamInput
			},
		},
		{
			name:     config.CallParamSalt,
			value:    cp.Salt,
			showWhen: func(t string) bool { return t == config.CallTypeCreate2 },
		},
	}
	
	params := []CallParameter{}
	for _, cfg := range paramConfig {
		if cfg.showWhen(cp.CallType) {
			paramName := cfg.name
			if cfg.nameFunc != nil {
				paramName = cfg.nameFunc(cp.CallType)
			}
			params = append(params, CallParameter{Name: paramName, Value: cfg.value})
		}
	}
	
	return params
}

func (cp *CallParameters) SetParam(name, value string) {
	switch name {
	case config.CallParamCallType:
		cp.CallType = value
	case config.CallParamCaller:
		cp.Caller = value
	case config.CallParamTarget:
		cp.Target = value
	case config.CallParamValue:
		cp.Value = value
	case config.CallParamGasLimit:
		cp.GasLimit = value
	case config.CallParamInput, config.CallParamInputDeploy:
		cp.InputData = value
	case config.CallParamSalt:
		cp.Salt = value
	}
}

func NewCallParameters() CallParameters {
	defaults := config.GetCallDefaults()
	return CallParameters{
		CallType:   config.CallTypeToString(defaults.CallType),
		Caller:     defaults.CallerAddr,
		Target:     defaults.TargetAddr,
		Value:      defaults.Value,
		InputData:  defaults.InputData,
		GasLimit:   config.DefaultGasLimit,
		Salt:       defaults.Salt,
	}
}

type CallHistoryEntry struct {
	ID         string
	Timestamp  time.Time
	Parameters CallParameters
	Result     *evm.CallResult
}

type DeployedContract struct {
	Address   string
	Bytecode  []byte
	Timestamp time.Time
}

type TabType int

const (
	TabMakeCall TabType = iota
	TabCallHistory
	TabContracts
	TabSettings
)