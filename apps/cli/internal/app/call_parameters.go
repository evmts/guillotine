package app

import (
	"guillotine-cli/internal/config"
	"guillotine-cli/internal/types"
)

// GetCallParams returns the list of parameters based on call type
func GetCallParams(cp types.CallParametersStrings) []types.CallParameter {
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
	
	params := []types.CallParameter{}
	for _, cfg := range paramConfig {
		if cfg.showWhen(cp.CallType) {
			paramName := cfg.name
			if cfg.nameFunc != nil {
				paramName = cfg.nameFunc(cp.CallType)
			}
			params = append(params, types.CallParameter{Name: paramName, Value: cfg.value})
		}
	}
	
	return params
}

// SetCallParam updates a specific parameter value
func SetCallParam(cp *types.CallParametersStrings, name, value string) {
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

// NewCallParameters creates a new CallParameters with default values
func NewCallParameters() types.CallParametersStrings {
	defaults := config.GetCallDefaults()
	return types.CallParametersStrings{
		CallType:   types.CallTypeToString(defaults.CallType),
		Caller:     defaults.CallerAddr,
		Target:     defaults.TargetAddr,
		Value:      defaults.Value,
		InputData:  defaults.InputData,
		GasLimit:   config.DefaultGasLimit,
		Salt:       defaults.Salt,
	}
}