package config

import (
	"github.com/evmts/guillotine/bindings/go/evm"
)

type CallDefaults struct {
	CallType    evm.CallType
	GasLimit    uint64
	CallerAddr  string
	TargetAddr  string
	Value       string
	InputData   string
	Salt        string
}

func GetCallDefaults() CallDefaults {
	return CallDefaults{
		CallType:    evm.CallTypeCall,
		GasLimit:    100000,
		CallerAddr:  "0x0102030405060708090a0b0c0d0e0f1011121314",
		TargetAddr:  "0x15161718191a1b1c1d1e1f20212223242526272e",
		Value:       "0",
		InputData:   "0x",
		Salt:        "0x0000000000000000000000000000000000000000000000000000000000000000",
	}
}

func GetCallTypeOptions() []string {
	return []string{
		CallTypeCall,
		CallTypeStaticCall,
		CallTypeDelegateCall,
		CallTypeCreate,
		CallTypeCreate2,
	}
}

func CallTypeFromString(s string) evm.CallType {
	switch s {
	case CallTypeCall:
		return evm.CallTypeCall
	case CallTypeStaticCall:
		return evm.CallTypeStaticcall
	case CallTypeDelegateCall:
		return evm.CallTypeDelegatecall
	case CallTypeCreate:
		return evm.CallTypeCreate
	case CallTypeCreate2:
		return evm.CallTypeCreate2
	default:
		return evm.CallTypeCall
	}
}

func CallTypeToString(ct evm.CallType) string {
	switch ct {
	case evm.CallTypeCall:
		return CallTypeCall
	case evm.CallTypeStaticcall:
		return CallTypeStaticCall
	case evm.CallTypeDelegatecall:
		return CallTypeDelegateCall
	case evm.CallTypeCreate:
		return CallTypeCreate
	case evm.CallTypeCreate2:
		return CallTypeCreate2
	default:
		return CallTypeCall
	}
}