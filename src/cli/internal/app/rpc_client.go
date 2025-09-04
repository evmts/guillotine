package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"time"
)

// RPCClient handles JSON-RPC requests to Ethereum nodes
type RPCClient struct {
	endpoint   string
	httpClient *http.Client
}

// RPCRequest represents a JSON-RPC request
type RPCRequest struct {
	JsonRPC string        `json:"jsonrpc"`
	Method  string        `json:"method"`
	Params  []interface{} `json:"params"`
	ID      int           `json:"id"`
}

// RPCResponse represents a JSON-RPC response
type RPCResponse struct {
	JsonRPC string          `json:"jsonrpc"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
	ID      int             `json:"id"`
}

// RPCError represents a JSON-RPC error
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// NewRPCClient creates a new RPC client
func NewRPCClient(endpoint string) *RPCClient {
	return &RPCClient{
		endpoint: endpoint,
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// GetCode retrieves the bytecode for a contract at the given address
func (c *RPCClient) GetCode(address, block string) (string, error) {
	request := RPCRequest{
		JsonRPC: "2.0",
		Method:  "eth_getCode",
		Params:  []interface{}{address, block},
		ID:      1,
	}

	response, err := c.makeRequest(request)
	if err != nil {
		return "", fmt.Errorf("failed to make RPC request: %w", err)
	}

	if response.Error != nil {
		return "", fmt.Errorf("RPC error %d: %s", response.Error.Code, response.Error.Message)
	}

	var bytecode string
	if err := json.Unmarshal(response.Result, &bytecode); err != nil {
		return "", fmt.Errorf("failed to unmarshal bytecode: %w", err)
	}

	return bytecode, nil
}

// makeRequest performs an HTTP POST request to the RPC endpoint
func (c *RPCClient) makeRequest(request RPCRequest) (*RPCResponse, error) {
	requestBody, err := json.Marshal(request)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	resp, err := c.httpClient.Post(c.endpoint, "application/json", bytes.NewReader(requestBody))
	if err != nil {
		return nil, fmt.Errorf("HTTP request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP error: %s", resp.Status)
	}

	responseBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response body: %w", err)
	}

	var response RPCResponse
	if err := json.Unmarshal(responseBody, &response); err != nil {
		return nil, fmt.Errorf("failed to unmarshal response: %w", err)
	}

	return &response, nil
}

// RPCInputState represents the state for RPC bytecode loading
type RPCInputState struct {
	endpoint    string
	address     string
	block       string
	activeField RPCInputField
	errors      map[RPCInputField]string
	loading     bool
}

type RPCInputField int

const (
	EndpointField RPCInputField = iota
	AddressField
	BlockField
)

// NewRPCInputState creates a new RPC input state with defaults
func NewRPCInputState() RPCInputState {
	return RPCInputState{
		endpoint:    "https://eth.llamarpc.com",
		address:     "",
		block:       "latest",
		activeField: AddressField, // Start with address field as most important
		errors:      make(map[RPCInputField]string),
		loading:     false,
	}
}

// Validate validates all RPC input fields
func (r *RPCInputState) Validate() error {
	r.errors = make(map[RPCInputField]string)

	// Validate endpoint
	if r.endpoint == "" {
		r.errors[EndpointField] = "endpoint required"
		return fmt.Errorf("endpoint required")
	}

	// Validate address
	if err := validateEthereumAddress(r.address); err != nil {
		r.errors[AddressField] = err.Error()
		return err
	}

	// Validate block
	if r.block == "" {
		r.errors[BlockField] = "block required"
		return fmt.Errorf("block required")
	}

	return nil
}

// validateEthereumAddress validates an Ethereum address format
func validateEthereumAddress(addr string) error {
	if addr == "" {
		return fmt.Errorf("address required")
	}

	// Remove 0x prefix if present
	if len(addr) > 2 && addr[:2] == "0x" {
		addr = addr[2:]
	}

	// Check length (40 hex chars = 20 bytes)
	if len(addr) != 40 {
		return fmt.Errorf("address must be 40 hex characters")
	}

	// Check if all characters are hex
	for _, c := range addr {
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return fmt.Errorf("address must contain only hex characters")
		}
	}

	return nil
}

// Navigation helpers for RPC input
func (r *RPCInputState) nextField() RPCInputField {
	switch r.activeField {
	case EndpointField:
		return AddressField
	case AddressField:
		return BlockField
	case BlockField:
		return EndpointField
	default:
		return EndpointField
	}
}

func (r *RPCInputState) previousField() RPCInputField {
	switch r.activeField {
	case EndpointField:
		return BlockField
	case AddressField:
		return EndpointField
	case BlockField:
		return AddressField
	default:
		return EndpointField
	}
}

// Field value getters
func (r *RPCInputState) getFieldValue(field RPCInputField) string {
	switch field {
	case EndpointField:
		return r.endpoint
	case AddressField:
		return r.address
	case BlockField:
		return r.block
	default:
		return ""
	}
}

// Field value setters
func (r *RPCInputState) setFieldValue(field RPCInputField, value string) {
	switch field {
	case EndpointField:
		r.endpoint = value
	case AddressField:
		r.address = value
	case BlockField:
		r.block = value
	}
}