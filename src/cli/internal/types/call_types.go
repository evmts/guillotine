package types

import (
	"guillotine-cli/internal/config"
	"github.com/evmts/guillotine/bindings/go/evm"
)

type AppState int

const (
	StateMainMenu AppState = iota
	StateCallParameterList
	StateCallParameterEdit
	StateCallExecuting
	StateCallResult
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
	params := []CallParameter{
		{Name: config.CallParamCallType, Value: cp.CallType},
		{Name: config.CallParamCaller, Value: cp.Caller},
	}
	
	// Hide target address for CREATE and CREATE2
	if cp.CallType != config.CallTypeCreate && cp.CallType != config.CallTypeCreate2 {
		params = append(params, CallParameter{Name: config.CallParamTarget, Value: cp.Target})
	}
	
	// Hide value for STATICCALL
	if cp.CallType != config.CallTypeStaticCall {
		params = append(params, CallParameter{Name: config.CallParamValue, Value: cp.Value})
	}
	
	// Always show gas limit
	params = append(params, CallParameter{Name: config.CallParamGasLimit, Value: cp.GasLimit})
	
	// Show input data with context-aware label
	inputDataLabel := config.CallParamInput
	if cp.CallType == config.CallTypeCreate || cp.CallType == config.CallTypeCreate2 {
		inputDataLabel = config.CallParamInputDeploy
	}
	params = append(params, CallParameter{Name: inputDataLabel, Value: cp.InputData})
	
	// Show salt only for CREATE2
	if cp.CallType == config.CallTypeCreate2 {
		params = append(params, CallParameter{Name: config.CallParamSalt, Value: cp.Salt})
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
		GasLimit:   "100000",
		Salt:       defaults.Salt,
	}
}

type CallExecution struct {
	Success    bool
	GasUsed    uint64
	Output     []byte
	ErrorInfo  string
	Logs       []evm.LogEntry
}