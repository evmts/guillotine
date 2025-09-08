package types

import (
	"guillotine-cli/internal/config"
	guillotine "github.com/evmts/guillotine/sdks/go"
)

type CallParameter struct {
	Name  string
	Value string
}

// CallParametersStrings holds string representations of call parameters for UI
type CallParametersStrings struct {
	CallType   string
	Caller     string
	Target     string
	Value      string
	InputData  string
	GasLimit   string
	Salt       string
}

// GetParams returns parameter list for UI display based on call type
func (cp *CallParametersStrings) GetParams() []CallParameter {
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

// SetParam updates a parameter value by name
func (cp *CallParametersStrings) SetParam(name, value string) {
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

// NewCallParametersStrings creates new parameters with defaults
func NewCallParametersStrings() CallParametersStrings {
	defaults := config.GetCallDefaults()
	return CallParametersStrings{
		CallType:   CallTypeToString(defaults.CallType),
		Caller:     defaults.CallerAddr,
		Target:     defaults.TargetAddr,
		Value:      defaults.Value,
		InputData:  defaults.InputData,
		GasLimit:   "100000",
		Salt:       defaults.Salt,
	}
}

// GetCallTypeOptions returns all available call type options
func GetCallTypeOptions() []string {
	return []string{
		config.CallTypeCall,
		config.CallTypeCallcode,
		config.CallTypeStaticCall,
		config.CallTypeDelegateCall,
		config.CallTypeCreate,
		config.CallTypeCreate2,
	}
}

// CallTypeFromString converts a string to SDK CallType
func CallTypeFromString(s string) guillotine.CallType {
	switch s {
	case config.CallTypeCall:
		return guillotine.CallTypeCall
	case config.CallTypeCallcode:
		return guillotine.CallTypeCallcode
	case config.CallTypeStaticCall:
		return guillotine.CallTypeStaticcall
	case config.CallTypeDelegateCall:
		return guillotine.CallTypeDelegatecall
	case config.CallTypeCreate:
		return guillotine.CallTypeCreate
	case config.CallTypeCreate2:
		return guillotine.CallTypeCreate2
	default:
		return guillotine.CallTypeCall
	}
}

// CallTypeToString converts SDK CallType to string
func CallTypeToString(ct guillotine.CallType) string {
	switch ct {
	case guillotine.CallTypeCall:
		return config.CallTypeCall
	case guillotine.CallTypeCallcode:
		return config.CallTypeCallcode
	case guillotine.CallTypeStaticcall:
		return config.CallTypeStaticCall
	case guillotine.CallTypeDelegatecall:
		return config.CallTypeDelegateCall
	case guillotine.CallTypeCreate:
		return config.CallTypeCreate
	case guillotine.CallTypeCreate2:
		return config.CallTypeCreate2
	default:
		return config.CallTypeCall
	}
}