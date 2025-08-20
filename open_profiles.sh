#!/bin/bash
# Script to open all profiling results

echo "🔍 Opening Guillotine EVM Profile Analysis..."

# Open the analysis report
echo "📄 Opening analysis report..."
open advanced_cpu_profiles/ANALYSIS_REPORT.md

# Wait a moment
sleep 2

# Open key trace files
echo "📊 Opening detailed hash profile..."
open advanced_cpu_profiles/ten_thousand_hashes_detailed.trace

echo "🧠 Opening system trace profile..."
open advanced_cpu_profiles/snailtracer_system_trace.trace

echo "💰 Opening ERC20 transfer profile..."
open advanced_cpu_profiles/erc20-transfer_profile.trace

echo "✅ All profiles opened! Check Instruments.app and your markdown viewer."
echo ""
echo "Available profiles:"
ls -1 advanced_cpu_profiles/*.trace | sed 's/advanced_cpu_profiles\//  - /'