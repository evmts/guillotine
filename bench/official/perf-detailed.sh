#!/bin/bash

# Enhanced performance analysis script for Zig EVM
# Captures detailed metrics including cache misses, branch predictions, and instruction counts

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Detailed Performance Analysis for Zig EVM ===${NC}"
echo ""

# Check if hyperfine is installed
if ! command -v hyperfine &> /dev/null; then
    echo -e "${RED}Error: hyperfine is not installed${NC}"
    echo "Install with: brew install hyperfine"
    exit 1
fi

# Build the Zig runner
echo -e "${YELLOW}Building Zig EVM runner...${NC}"
zig build build-evm-runner

# Test cases to benchmark
CASES=(
    "erc20-transfer:0xa9059cbb00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b9060000000000000000000000000000000000000000000000000000000000000001"
    "erc20-mint:0x40c10f190000000000000000000000001000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000a"
    "erc20-approval-transfer:0x095ea7b300000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b9060000000000000000000000000000000000000000000000000000000000000064"
    "ten-thousand-hashes:0x30627b7c"
    "snailtracer:0x30627b7c"
)

# Create results directory
RESULTS_DIR="bench/official/results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo -e "${GREEN}Results will be saved to: $RESULTS_DIR${NC}"
echo ""

# Function to run detailed benchmark
run_detailed_benchmark() {
    local CASE_NAME="$1"
    local CALLDATA="$2"
    local BYTECODE_PATH="bench/official/cases/$CASE_NAME/bytecode.txt"
    
    echo -e "${BLUE}Benchmarking: $CASE_NAME${NC}"
    
    # Determine internal runs based on case
    INTERNAL_RUNS=100
    if [[ "$CASE_NAME" == "snailtracer" ]]; then
        INTERNAL_RUNS=1
    fi
    
    # Basic timing benchmark
    echo "  Running basic timing analysis..."
    hyperfine \
        --runs 10 \
        --warmup 3 \
        --style full \
        --export-json "$RESULTS_DIR/${CASE_NAME}_timing.json" \
        --export-markdown "$RESULTS_DIR/${CASE_NAME}_timing.md" \
        --ignore-failure \
        "./zig-out/bin/evm-runner --contract-code-path $BYTECODE_PATH --calldata $CALLDATA --num-runs $INTERNAL_RUNS" || true
    
    # If on Linux, run with perf stats
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "  Running performance counter analysis..."
        
        # Cache statistics
        perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,L1-icache-load-misses \
            ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 10 \
            2> "$RESULTS_DIR/${CASE_NAME}_cache.txt"
        
        # Branch prediction statistics
        perf stat -e branches,branch-misses,branch-loads,branch-load-misses \
            ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 10 \
            2> "$RESULTS_DIR/${CASE_NAME}_branches.txt"
        
        # Instruction statistics
        perf stat -e instructions,cycles,cpu-clock,task-clock \
            ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 10 \
            2> "$RESULTS_DIR/${CASE_NAME}_instructions.txt"
        
        # Memory statistics
        perf stat -e page-faults,minor-faults,major-faults \
            ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 10 \
            2> "$RESULTS_DIR/${CASE_NAME}_memory.txt"
    fi
    
    # On macOS, use dtrace or instruments if available
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "  Running macOS performance analysis..."
        
        # Time profiling with sample
        if command -v sample &> /dev/null; then
            sample ./zig-out/bin/evm-runner 1 -file "$RESULTS_DIR/${CASE_NAME}_sample.txt" &
            SAMPLE_PID=$!
            ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 10
            kill $SAMPLE_PID 2>/dev/null || true
        fi
        
        # System trace with dtruss (requires sudo)
        # Uncomment if you want system call tracing
        # sudo dtruss -c ./zig-out/bin/evm-runner --contract-code-path "$BYTECODE_PATH" --calldata "$CALLDATA" --num-runs 1 \
        #     2> "$RESULTS_DIR/${CASE_NAME}_syscalls.txt"
    fi
    
    echo ""
}

# Run benchmarks for each case
for CASE_DATA in "${CASES[@]}"; do
    IFS=':' read -r CASE_NAME CALLDATA <<< "$CASE_DATA"
    run_detailed_benchmark "$CASE_NAME" "$CALLDATA"
done

# Generate summary report
echo -e "${YELLOW}Generating summary report...${NC}"

cat > "$RESULTS_DIR/summary.md" << EOF
# Detailed Performance Analysis Report
Generated: $(date)

## Test Environment
- Platform: $(uname -s)
- CPU: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || lscpu | grep "Model name" | cut -d: -f2 | xargs)
- Memory: $(sysctl -n hw.memsize 2>/dev/null | awk '{print $1/1024/1024/1024 " GB"}' || free -h | awk '/^Mem:/ {print $2}')
- Zig Version: $(zig version)

## Benchmark Results

EOF

# Parse JSON results and add to summary
for CASE_DATA in "${CASES[@]}"; do
    IFS=':' read -r CASE_NAME CALLDATA <<< "$CASE_DATA"
    if [[ -f "$RESULTS_DIR/${CASE_NAME}_timing.json" ]]; then
        echo "### $CASE_NAME" >> "$RESULTS_DIR/summary.md"
        echo "" >> "$RESULTS_DIR/summary.md"
        
        # Extract key metrics from JSON
        if command -v jq &> /dev/null; then
            MEAN=$(jq '.results[0].mean' "$RESULTS_DIR/${CASE_NAME}_timing.json")
            MIN=$(jq '.results[0].min' "$RESULTS_DIR/${CASE_NAME}_timing.json")
            MAX=$(jq '.results[0].max' "$RESULTS_DIR/${CASE_NAME}_timing.json")
            STDDEV=$(jq '.results[0].stddev' "$RESULTS_DIR/${CASE_NAME}_timing.json")
            
            echo "- Mean: ${MEAN}s" >> "$RESULTS_DIR/summary.md"
            echo "- Min: ${MIN}s" >> "$RESULTS_DIR/summary.md"
            echo "- Max: ${MAX}s" >> "$RESULTS_DIR/summary.md"
            echo "- StdDev: ${STDDEV}s" >> "$RESULTS_DIR/summary.md"
        fi
        
        echo "" >> "$RESULTS_DIR/summary.md"
    fi
done

echo -e "${GREEN}Analysis complete! Results saved to: $RESULTS_DIR${NC}"
echo ""
echo "Key files generated:"
echo "  - summary.md: Overall performance summary"
echo "  - *_timing.json: Detailed timing data"
echo "  - *_timing.md: Markdown formatted timing results"

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "  - *_cache.txt: Cache miss statistics"
    echo "  - *_branches.txt: Branch prediction statistics"
    echo "  - *_instructions.txt: Instruction count statistics"
    echo "  - *_memory.txt: Memory fault statistics"
fi

# Generate comparison report if requested
if [[ "$1" == "--compare" ]]; then
    echo ""
    echo -e "${YELLOW}Running comparison with other EVMs...${NC}"
    ./zig-out/bin/orchestrator --compare --export detailed --perf-output "$RESULTS_DIR"
fi

# Advanced analysis with flamegraph (if available)
if command -v perf &> /dev/null && command -v flamegraph &> /dev/null; then
    echo ""
    echo -e "${YELLOW}Generating flamegraphs (requires sudo)...${NC}"
    echo "Run the following to generate flamegraphs:"
    echo "  sudo perf record -F 99 -g ./zig-out/bin/evm-runner --contract-code-path bench/official/cases/snailtracer/bytecode.txt --calldata 0x30627b7c --num-runs 1"
    echo "  sudo perf script | flamegraph > $RESULTS_DIR/flamegraph.svg"
fi