package types

type AppState int

const (
	StateMainMenu AppState = iota
	StateCallParameterList
	StateCallParameterEdit
	StateCallExecuting
	StateCallResult
)