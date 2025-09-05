package config

const (
	// Application info
	AppTitle       = "GUILLOTINE"
	AppSubtitle    = "High-Performance EVM Implementation"
	
	// Messages
	GoodbyeMessage = "Execution complete. Goodbye!"
	LoadingMessage = "Loading..."
	
	// Menu items
	MenuMakeCall    = "Make call"
	MenuCallHistory = "Call History"
	MenuContracts   = "Contracts"
	MenuResetState  = "Reset State"
	MenuExit        = "Exit"
	
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
	CallStateTitle         = "Make call"
	CallStateSubtitle      = "Configure call parameters"
	CallEditTitle          = "Edit parameter"
	CallEditSubtitle       = ""
	CallExecutingTitle     = "Executing call"
	CallExecutingSubtitle  = ""
	CallResultTitle        = "Call result"
	CallResultSubtitle     = ""
	
	// History states
	CallHistoryTitle       = "Call History"
	CallHistorySubtitle    = "Browse previous EVM calls"
	CallHistoryDetailTitle = "Call Details"
	CallHistoryDetailSubtitle = ""
	
	// Contract states
	ContractsTitle         = "Deployed Contracts"
	ContractsSubtitle      = "Browse deployed contracts"
	ContractDetailTitle    = "Contract Details"
	ContractDetailSubtitle = ""
	ContractBytecodeTitle  = "Contract Bytecode"
	ContractBytecodeSubtitle = ""
	
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
	
	// Reset state messages
	ResetStateTitle      = "Reset State"
	ResetStateSubtitle   = "Are you sure? This will clear all call history and contracts."
	ResetConfirmMessage  = "Press ENTER to confirm reset or ESC to cancel"
	
	// Log detail messages
	LogDetailTitle       = "Log Details"
	LogDetailSubtitle    = "Full log entry information"
)

// GetMenuItems returns the default menu items
func GetMenuItems() []string {
	return []string{
		MenuMakeCall,
		MenuCallHistory,
		MenuContracts,
		MenuResetState,
		MenuExit,
	}
}