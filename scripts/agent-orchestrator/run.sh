#!/bin/bash
# Agent Orchestrator - Shell wrapper
# Usage: ./run.sh --issue 850 [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Install dependencies if needed
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
fi

# Run the orchestrator
npx tsx src/orchestrator.ts "$@"
