package types

import (
	"time"
	
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