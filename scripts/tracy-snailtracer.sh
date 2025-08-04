#!/bin/bash
set -e

echo "Building official Zig benchmark runner with Tracy enabled..."

# Save current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Change to project root
cd "$PROJECT_ROOT"

# First build the main evm-runner with Tracy enabled
echo "Building main evm-runner with Tracy..."
zig build -Dtracy=true -Doptimize=ReleaseFast build-evm-runner

# Copy the Tracy-enabled binary to the official benchmark location
echo "Copying Tracy-enabled binary to official benchmark location..."
cp zig-out/bin/evm-runner bench/official/evms/zig/evm-runner

# Make it executable
chmod +x bench/official/evms/zig/evm-runner

echo ""
echo "Build complete! Now running snailtracer benchmark with 10 internal runs..."
echo ""

# Run the benchmark
cd bench/official/evms/zig
./evm-runner \
    --contract-code-path ../../cases/snailtracer/bytecode.txt \
    --calldata "$(cat ../../cases/snailtracer/calldata.txt)" \
    --num-runs 10

echo ""
echo "Benchmark complete!"
echo ""
echo "To profile with Tracy:"
echo "1. Start Tracy profiler GUI"
echo "2. Run this script again while Tracy is capturing"
echo "3. Analyze the results in Tracy"
echo ""
echo "The Tracy zones will show:"
echo "- 'main': Total execution time"
echo "- 'setup': Initialization and file loading"
echo "- 'deployment': Contract deployment time"
echo "- 'benchmark_runs': All benchmark iterations"
echo "- 'single_run': Each individual run"
echo "- 'contract_execution': Actual EVM execution"
echo "- 'evm.handler.run': Overall interpreter execution (matches REVM format)"
echo "- 'evm.exec': Each opcode execution with 'pc=XXXX opcode=YY' text (matches REVM format)"
echo "- 'analyze_code': Bytecode analysis time"
echo ""
echo "Tracy messages every 100 instructions show: 'pc:XXXX op:YY' for performance overview"