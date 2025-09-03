package config

const (
	// Application info
	AppTitle       = "GUILLOTINE"
	AppSubtitle    = "High-Performance EVM Implementation"
	
	// Messages
	GoodbyeMessage = "Execution complete. Goodbye!"
	LoadingMessage = "Loading..."
	
	// Menu items
	MenuMakeCall   = "Make Call"
	MenuExit       = "Exit"
	
	// Call parameter names
	CallParamCallType    = "Call Type"
	CallParamCaller      = "Caller Address"
	CallParamTarget      = "Target Address"
	CallParamValue       = "Value (Wei)"
	CallParamInput       = "Input Data"
	CallParamGasLimit    = "Gas Limit"
	CallParamSalt        = "Salt (CREATE2 only)"
	
	// Call states
	CallStateTitle       = "Configure Call Parameters"
	CallEditTitle        = "Edit Parameter"
	CallExecutingTitle   = "Executing Call"
	CallResultTitle      = "Call Result"
	
	// Call messages
	CallExecutingMsg     = "Executing EVM call..."
	CallSuccessMsg       = "Call executed successfully"
	CallFailureMsg       = "Call execution failed"
	
	// Call type options
	CallTypeCall         = "CALL"
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