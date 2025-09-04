package app

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
	"regexp"
	"strconv"
	"strings"
)

// CallInputState represents the state for call input form
type CallInputState struct {
	fromAddress string
	toAddress   string
	value       string
	calldata    string
	gas         string
	activeField InputField
	errors      map[InputField]string
}

type InputField int

const (
	FromField InputField = iota
	ToField
	ValueField
	CalldataField
	GasField
)

// AppMode represents different modes of the application
type AppMode int

const (
	MenuMode AppMode = iota
	CallInputMode
	RPCInputMode
	CarouselMode
	SourceViewerMode
)

// ZigCallParams represents the JSON structure expected by Zig
type ZigCallParams struct {
	Type   string `json:"type"`
	Caller string `json:"caller"`
	To     string `json:"to"`
	Value  string `json:"value"`
	Input  string `json:"input"`
	Gas    string `json:"gas"`
}

// Validation errors
var (
	ErrInvalidAddress  = errors.New("invalid Ethereum address")
	ErrInvalidValue    = errors.New("invalid value amount")
	ErrInvalidCalldata = errors.New("invalid calldata hex")
	ErrInvalidGas      = errors.New("invalid gas amount")
)

// NewCallInputState creates a new call input state with defaults
func NewCallInputState() CallInputState {
	return CallInputState{
		fromAddress: "",
		toAddress:   "",
		value:       "0",
		calldata:    "0x",
		gas:         "21000",
		activeField: FromField,
		errors:      make(map[InputField]string),
	}
}

// Validate validates all input fields
func (c *CallInputState) Validate() error {
	c.errors = make(map[InputField]string) // Clear previous errors

	// Validate from address
	if err := c.validateAddress(c.fromAddress); err != nil {
		c.errors[FromField] = err.Error()
		return err
	}

	// Validate to address
	if err := c.validateAddress(c.toAddress); err != nil {
		c.errors[ToField] = err.Error()
		return err
	}

	// Validate value
	if err := c.validateValue(c.value); err != nil {
		c.errors[ValueField] = err.Error()
		return err
	}

	// Validate calldata
	if err := c.validateCalldata(c.calldata); err != nil {
		c.errors[CalldataField] = err.Error()
		return err
	}

	// Validate gas
	if err := c.validateGas(c.gas); err != nil {
		c.errors[GasField] = err.Error()
		return err
	}

	return nil
}

// validateAddress validates an Ethereum address
func (c *CallInputState) validateAddress(addr string) error {
	if addr == "" {
		return ErrInvalidAddress
	}

	// Remove 0x prefix if present
	if strings.HasPrefix(addr, "0x") {
		addr = addr[2:]
	}

	// Check length (40 hex chars = 20 bytes)
	if len(addr) != 40 {
		return ErrInvalidAddress
	}

	// Check if all characters are hex
	if matched, _ := regexp.MatchString("^[0-9a-fA-F]+$", addr); !matched {
		return ErrInvalidAddress
	}

	return nil
}

// validateValue validates a value amount (should be non-negative)
func (c *CallInputState) validateValue(value string) error {
	if value == "" {
		return ErrInvalidValue
	}

	// Try to parse as big integer
	val := new(big.Int)
	if _, ok := val.SetString(value, 10); !ok {
		return ErrInvalidValue
	}

	// Check if negative
	if val.Sign() < 0 {
		return ErrInvalidValue
	}

	return nil
}

// validateCalldata validates hex calldata
func (c *CallInputState) validateCalldata(data string) error {
	if data == "" || data == "0x" {
		return nil // Empty calldata is valid
	}

	// Must start with 0x
	if !strings.HasPrefix(data, "0x") {
		return ErrInvalidCalldata
	}

	// Remove 0x prefix
	hexData := data[2:]

	// Check if all characters are hex
	if _, err := hex.DecodeString(hexData); err != nil {
		return ErrInvalidCalldata
	}

	return nil
}

// validateGas validates gas amount (must be positive)
func (c *CallInputState) validateGas(gas string) error {
	if gas == "" {
		return ErrInvalidGas
	}

	gasVal, err := strconv.ParseUint(gas, 10, 64)
	if err != nil {
		return ErrInvalidGas
	}

	if gasVal == 0 {
		return ErrInvalidGas
	}

	return nil
}

// ToZigCallParams converts the input state to Zig-compatible JSON
func (c *CallInputState) ToZigCallParams() ([]byte, error) {
	if err := c.Validate(); err != nil {
		return nil, err
	}

	// Ensure addresses have 0x prefix
	fromAddr := c.fromAddress
	if !strings.HasPrefix(fromAddr, "0x") {
		fromAddr = "0x" + fromAddr
	}

	toAddr := c.toAddress
	if !strings.HasPrefix(toAddr, "0x") {
		toAddr = "0x" + toAddr
	}

	// Ensure calldata has 0x prefix
	calldata := c.calldata
	if calldata == "" {
		calldata = "0x"
	}
	if !strings.HasPrefix(calldata, "0x") {
		calldata = "0x" + calldata
	}

	params := ZigCallParams{
		Type:   "call",
		Caller: fromAddr,
		To:     toAddr,
		Value:  c.value,
		Input:  calldata,
		Gas:    c.gas,
	}

	return json.Marshal(params)
}

// Navigation helpers
func (c *CallInputState) nextField() InputField {
	switch c.activeField {
	case FromField:
		return ToField
	case ToField:
		return ValueField
	case ValueField:
		return CalldataField
	case CalldataField:
		return GasField
	case GasField:
		return FromField // Wrap around
	default:
		return FromField
	}
}

func (c *CallInputState) previousField() InputField {
	switch c.activeField {
	case FromField:
		return GasField // Wrap around
	case ToField:
		return FromField
	case ValueField:
		return ToField
	case CalldataField:
		return ValueField
	case GasField:
		return CalldataField
	default:
		return FromField
	}
}

// Field value getters
func (c *CallInputState) getFieldValue(field InputField) string {
	switch field {
	case FromField:
		return c.fromAddress
	case ToField:
		return c.toAddress
	case ValueField:
		return c.value
	case CalldataField:
		return c.calldata
	case GasField:
		return c.gas
	default:
		return ""
	}
}

// Field value setters
func (c *CallInputState) setFieldValue(field InputField, value string) {
	switch field {
	case FromField:
		c.fromAddress = value
	case ToField:
		c.toAddress = value
	case ValueField:
		c.value = value
	case CalldataField:
		c.calldata = value
	case GasField:
		c.gas = value
	}
}