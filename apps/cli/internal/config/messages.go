package config

const (
	// Application info
	AppTitle       = "GUILLOTINE"
	AppSubtitle    = "High-Performance EVM Implementation"
	
	// Messages
	GoodbyeMessage = "Execution complete. Goodbye!"
	LoadingMessage = "Loading..."
	
	// Menu items
	MenuMakeCall   = "Make call"
	MenuExit       = "Exit"
	
	// Call parameter names
	CallParamCallType    = "Call type"
	CallParamCaller      = "Caller address"
	CallParamTarget      = "Target address"
	CallParamValue       = "Value (wei)"
	CallParamInput       = "Input data"
	CallParamInputDeploy = "Input data (deployment bytecode)"
	CallParamGasLimit    = "Gas limit"
	CallParamSalt        = "Salt"
	
	// Call states
	CallStateTitle       = "Configure call parameters"
	CallEditTitle        = "Edit parameter"
	CallExecutingTitle   = "Executing call"
	CallResultTitle      = "Call result"
	
	// Call messages
	CallExecutingMsg     = "Executing EVM call..."
	CallSuccessMsg       = "Call executed successfully"
	CallFailureMsg       = "Call execution failed"
	
	// Call type options
	CallTypeCall         = "CALL"
	CallTypeCallcode     = "CALLCODE"
	CallTypeStaticCall   = "STATICCALL"
	CallTypeDelegateCall = "DELEGATECALL"
	CallTypeCreate       = "CREATE"
	CallTypeCreate2      = "CREATE2"
)

// GetMenuItems returns the default menu items
func GetMenuItems() []string {
	return []string{
		MenuMakeCall,
		MenuExit,
	}
}