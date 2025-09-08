package config

const (
	// Application info
	AppTitle       = "GUILLOTINE"
	AppSubtitle    = "High-Performance EVM Implementation"
	
	// Messages
	GoodbyeMessage = "Execution complete. Goodbye!"
	LoadingMessage = "Loading..."
	
	// Menu items
	MenuRunTest    = "Run test call"
	MenuExit       = "Exit"
)

// GetMenuItems returns the default menu items
func GetMenuItems() []string {
	return []string{
		MenuRunTest,
		MenuExit,
	}
}