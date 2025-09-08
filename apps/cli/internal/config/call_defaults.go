package config

import (
	guillotine "github.com/evmts/guillotine/sdks/go"
)

type CallDefaults struct {
	CallType    guillotine.CallType
	GasLimit    uint64
	CallerAddr  string
	TargetAddr  string
	Value       string
	InputData   string
	Salt        string
}

func GetCallDefaults() CallDefaults {
	return CallDefaults{
		CallType:    guillotine.CallTypeCall,
		GasLimit:    100000,
		CallerAddr:  "0x0102030405060708090a0b0c0d0e0f1011121314",
		TargetAddr:  "0x15161718191a1b1c1d1e1f20212223242526272e",
		Value:       "0",
		InputData:   "0x",
		Salt:        "0x0000000000000000000000000000000000000000000000000000000000000000",
	}
}