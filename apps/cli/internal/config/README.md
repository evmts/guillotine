# CLI Config

Small set of constants and helpers used by the Bubble Tea demo.

## Files

- `keys.go` — well-known keys/flags/env names used around the CLI
- `messages.go` — user-facing strings and prompts
- `theme.go` — color palette and layout constants

## Usage

These packages are imported by `internal/app` and `internal/ui` to keep copy in one place:

```go
import (
    cfg "guillotine-cli/internal/config"
)

// Example usage
view := lipgloss.NewStyle().Foreground(cfg.ThemeAccent)
fmt.Println(cfg.MsgWelcome)
```

This layer intentionally avoids any dynamic file I/O or env parsing. If the CLI grows beyond demos, add a proper configuration loader (flags > env > file) in a new package rather than expanding these constants.
- RPC endpoint URLs for Ethereum nodes
- API keys for external services
- Timeout and retry configurations
- SSL/TLS settings for secure connections

#### EVM Parameters
- Gas limit and price defaults
- Hardfork selection and EIP activation
- Tracing and debugging verbosity levels
- Memory and execution limits

#### Display Options
- Output format preferences (JSON, table, etc.)
- Color scheme and theme selection
- Progress indicator styles
- Log level and destination

#### Developer Settings
- Debug mode activation
- Performance profiling options
- Test network configurations
- Development-specific defaults

## Architecture

### Hierarchical Configuration
```go
type Config struct {
    Connection ConnectionConfig `json:"connection"`
    EVM        EVMConfig        `json:"evm"`
    Display    DisplayConfig    `json:"display"`
    Debug      DebugConfig      `json:"debug,omitempty"`
}
```

### Validation Framework
- Schema validation for structured data
- Range checking for numeric values
- Format validation for addresses, hashes, and URLs
- Dependency validation between related settings

### Theme System
The theme system provides:
- Color schemes for different terminal types
- Customizable UI element styling
- Accessibility options for different user needs
- Responsive layouts for different terminal sizes

## Usage Patterns

### Loading Configuration
```go
config, err := LoadConfig(
    WithConfigFile("~/.guillotine/config.yaml"),
    WithEnvironmentPrefix("GUILLOTINE_"),
    WithFlags(cmd.Flags()),
)
```

### Environment Variable Mapping
Environment variables use the `GUILLOTINE_` prefix:
- `GUILLOTINE_RPC_URL` → Connection.RPCUrl
- `GUILLOTINE_DEBUG_MODE` → Debug.Enabled
- `GUILLOTINE_LOG_LEVEL` → Display.LogLevel

### Configuration Validation
```go
func (c *Config) Validate() error {
    if err := c.Connection.Validate(); err != nil {
        return fmt.Errorf("connection config: %w", err)
    }
    // ... additional validation
    return nil
}
```

## Configuration Schema

### Connection Configuration
```go
type ConnectionConfig struct {
    RPCUrl      string        `json:"rpc_url" validate:"required,url"`
    Timeout     time.Duration `json:"timeout" default:"30s"`
    MaxRetries  int          `json:"max_retries" default:"3"`
    APIKey      string       `json:"api_key,omitempty"`
}
```

### EVM Configuration
```go
type EVMConfig struct {
    GasLimit    uint64    `json:"gas_limit" default:"10000000"`
    Hardfork    string    `json:"hardfork" default:"london"`
    TracingMode string    `json:"tracing_mode" default:"basic"`
    ChainID     *big.Int  `json:"chain_id"`
}
```

### Display Configuration
```go
type DisplayConfig struct {
    OutputFormat string `json:"output_format" default:"table"`
    Theme        string `json:"theme" default:"auto"`
    ColorMode    string `json:"color_mode" default:"auto"`
    ShowProgress bool   `json:"show_progress" default:"true"`
}
```

## Security Considerations

### Sensitive Data Handling
- API keys and secrets are masked in logs and debug output
- Configuration files with sensitive data should use appropriate file permissions
- Environment variables are preferred for secrets in production environments

### Configuration File Security
- Validate file permissions before reading configuration files
- Support for encrypted configuration files for sensitive environments
- Clear documentation on which settings contain sensitive information

## Development Guidelines

### Adding New Configuration Options
1. Define the configuration key in `keys.go`
2. Add the field to the appropriate configuration struct
3. Include validation tags and default values
4. Add help text to `messages.go`
5. Update theme settings in `theme.go` if needed
6. Write tests for the new configuration option

### Configuration Testing
- Test default value application
- Test validation with both valid and invalid inputs
- Test precedence of different configuration sources
- Test theme application and display formatting

## Integration Points

The configuration system integrates with:
- **Command-line parser** - For flag definitions and values
- **Environment reader** - For environment variable processing
- **File system** - For configuration file loading
- **UI components** - For theme and display settings
- **EVM core** - For execution parameter configuration
