package types

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
	StateLogDetail
)

type TabType int

const (
	TabMakeCall TabType = iota
	TabCallHistory
	TabContracts
	TabSettings
)