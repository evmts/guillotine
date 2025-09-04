package app

import (
	"fmt"
	"strconv"
	"strings"
)

// SourceLocation represents a location in source code
type SourceLocation struct {
	Line     int    `json:"line"`
	Column   int    `json:"column"`
	Length   int    `json:"length"`
	SourceID int    `json:"source_id"`
	FileName string `json:"file_name"`
}

// SourceFile represents a source code file
type SourceFile struct {
	ID       int      `json:"id"`
	Path     string   `json:"path"`
	Content  []string `json:"content"` // Split by lines
	Language string   `json:"language"`
}

// SourceMapParser handles Solidity source map parsing
type SourceMapParser struct {
	sourceFiles  map[int]SourceFile
	pcToLocation map[uint32]SourceLocation
}

// NewSourceMapParser creates a new source map parser
func NewSourceMapParser() *SourceMapParser {
	return &SourceMapParser{
		sourceFiles:  make(map[int]SourceFile),
		pcToLocation: make(map[uint32]SourceLocation),
	}
}

// AddSourceFile adds a source file to the parser
func (p *SourceMapParser) AddSourceFile(id int, path string, content string) {
	lines := strings.Split(content, "\n")
	p.sourceFiles[id] = SourceFile{
		ID:       id,
		Path:     path,
		Content:  lines,
		Language: getLanguageFromPath(path),
	}
}

// ParseSourceMap parses a Solidity-style source map
// Format: "s:l:f:j;s:l:f:j;..." where s=start, l=length, f=file, j=jump
func (p *SourceMapParser) ParseSourceMap(sourceMapData string) error {
	if sourceMapData == "" {
		return fmt.Errorf("empty source map")
	}

	segments := strings.Split(sourceMapData, ";")
	var pc uint32 = 0

	// Previous values for compression
	var prevStart, prevLength, prevFile, prevJump int = -1, -1, -1, -1

	for _, segment := range segments {
		if segment == "" {
			pc++
			continue
		}

		parts := strings.Split(segment, ":")
		if len(parts) < 1 {
			pc++
			continue
		}

		// Parse each field, using previous values if empty
		start := parseIntOrPrevious(parts[0], prevStart)
		length := parseIntOrPrevious(getOrEmpty(parts, 1), prevLength)
		file := parseIntOrPrevious(getOrEmpty(parts, 2), prevFile)
		jump := parseIntOrPrevious(getOrEmpty(parts, 3), prevJump)

		prevStart, prevLength, prevFile, prevJump = start, length, file, jump

		if start >= 0 && file >= 0 {
			sourceFile, exists := p.sourceFiles[file]
			if !exists {
				pc++
				continue
			}

			// Convert byte offset to line/column
			line, column := p.byteOffsetToLineColumn(sourceFile.Content, start)
			if line >= 0 {
				location := SourceLocation{
					Line:     line,
					Column:   column,
					Length:   length,
					SourceID: file,
					FileName: sourceFile.Path,
				}
				p.pcToLocation[pc] = location
			}
		}

		pc++
	}

	return nil
}

// GetLocationForPC returns the source location for a given PC
func (p *SourceMapParser) GetLocationForPC(pc uint32) (SourceLocation, bool) {
	location, exists := p.pcToLocation[pc]
	return location, exists
}

// GetSourceFile returns a source file by ID
func (p *SourceMapParser) GetSourceFile(id int) (SourceFile, bool) {
	file, exists := p.sourceFiles[id]
	return file, exists
}

// byteOffsetToLineColumn converts a byte offset to line and column
func (p *SourceMapParser) byteOffsetToLineColumn(lines []string, offset int) (int, int) {
	if offset < 0 {
		return -1, -1
	}

	currentOffset := 0
	for lineIdx, line := range lines {
		lineLength := len(line) + 1 // +1 for newline character
		if currentOffset+lineLength > offset {
			column := offset - currentOffset
			return lineIdx, column
		}
		currentOffset += lineLength
	}

	// If offset is beyond the file, return last line
	if len(lines) > 0 {
		return len(lines) - 1, len(lines[len(lines)-1])
	}

	return -1, -1
}

// Helper functions
func getOrEmpty(parts []string, index int) string {
	if index < len(parts) {
		return parts[index]
	}
	return ""
}

func parseIntOrPrevious(s string, previous int) int {
	if s == "" {
		return previous
	}
	if val, err := strconv.Atoi(s); err == nil {
		return val
	}
	return previous
}

func getLanguageFromPath(path string) string {
	if strings.HasSuffix(path, ".sol") {
		return "solidity"
	}
	if strings.HasSuffix(path, ".vy") {
		return "vyper"
	}
	return "unknown"
}

// SourceVisualizationState represents the state for source code visualization
type SourceVisualizationState struct {
	parser       *SourceMapParser
	currentPC    uint32
	highlightPC  uint32
	executionTrace ExecutionTrace
	sourceFiles  []SourceFile
	activeFileID int
	viewMode     SourceViewMode
}

type SourceViewMode int

const (
	SourceMainView SourceViewMode = iota
	SourceFullscreenView
)

// NewSourceVisualizationState creates a new source visualization state
func NewSourceVisualizationState() SourceVisualizationState {
	return SourceVisualizationState{
		parser:       NewSourceMapParser(),
		currentPC:    0,
		highlightPC:  0,
		executionTrace: ExecutionTrace{Steps: []ExecutionStep{}, CurrentStep: 0},
		sourceFiles:  []SourceFile{},
		activeFileID: 0,
		viewMode:     SourceMainView,
	}
}

// LoadMockSourceData loads mock source code and mapping for demonstration
func (s *SourceVisualizationState) LoadMockSourceData() {
	// Mock Solidity contract
	mockContract := `pragma solidity ^0.8.0;

contract SimpleStorage {
    uint256 public value;
    
    function setValue(uint256 _value) public {
        value = _value;
    }
    
    function getValue() public view returns (uint256) {
        return value;
    }
}`

	// Add the mock source file
	s.parser.AddSourceFile(0, "SimpleStorage.sol", mockContract)
	
	// Create mock source map (simplified)
	// This maps PC positions to source locations
	mockSourceMap := "0:50:0;50:20:0;70:15:0;85:30:0;115:10:0"
	s.parser.ParseSourceMap(mockSourceMap)
	
	// Store source files for UI
	if file, exists := s.parser.GetSourceFile(0); exists {
		s.sourceFiles = []SourceFile{file}
		s.activeFileID = 0
	}
}

// UpdatePC updates the current program counter and highlights the corresponding source line
func (s *SourceVisualizationState) UpdatePC(pc uint32) {
	s.currentPC = pc
	s.highlightPC = pc
}

// GetCurrentSourceLocation returns the current source location
func (s *SourceVisualizationState) GetCurrentSourceLocation() (SourceLocation, bool) {
	return s.parser.GetLocationForPC(s.highlightPC)
}

// GetActiveSourceFile returns the currently active source file
func (s *SourceVisualizationState) GetActiveSourceFile() (SourceFile, bool) {
	if s.activeFileID < len(s.sourceFiles) {
		return s.sourceFiles[s.activeFileID], true
	}
	return SourceFile{}, false
}

// GetHighlightedLine returns the line number that should be highlighted
func (s *SourceVisualizationState) GetHighlightedLine() int {
	if location, exists := s.GetCurrentSourceLocation(); exists {
		return location.Line
	}
	return -1
}

// SourceVisualizationContext provides context for rendering source visualization
type SourceVisualizationContext struct {
	SourceFile      SourceFile
	HighlightLine   int
	HighlightColumn int
	HighlightLength int
	CurrentPC       uint32
	Location        SourceLocation
	HasSourceMap    bool
	ViewMode        SourceViewMode
}

// GetVisualizationContext returns context for UI rendering
func (s *SourceVisualizationState) GetVisualizationContext() SourceVisualizationContext {
	ctx := SourceVisualizationContext{
		CurrentPC:    s.currentPC,
		ViewMode:     s.viewMode,
		HasSourceMap: len(s.sourceFiles) > 0,
	}

	if sourceFile, exists := s.GetActiveSourceFile(); exists {
		ctx.SourceFile = sourceFile
	}

	if location, exists := s.GetCurrentSourceLocation(); exists {
		ctx.Location = location
		ctx.HighlightLine = location.Line
		ctx.HighlightColumn = location.Column
		ctx.HighlightLength = location.Length
	} else {
		ctx.HighlightLine = -1
	}

	return ctx
}