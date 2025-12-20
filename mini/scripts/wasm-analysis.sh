#!/bin/bash

# WASM Size Analysis - Complete Workflow
# This script runs the full analysis pipeline:
# 1. Build WASM (optional)
# 2. Generate function name mapping
# 3. Run comprehensive size analysis
# 4. Display summary

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}🔍 WASM Size Analysis - Complete Pipeline${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Parse arguments
REBUILD=false
LIMIT=50

while [[ $# -gt 0 ]]; do
    case $1 in
        --rebuild|-r)
            REBUILD=true
            shift
            ;;
        --limit|-l)
            LIMIT="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --rebuild, -r     Rebuild WASM before analysis"
            echo "  --limit N, -l N   Show top N functions (default: 50)"
            echo "  --help, -h        Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                # Analyze existing WASM"
            echo "  $0 --rebuild      # Rebuild and analyze"
            echo "  $0 -r -l 100      # Rebuild and show top 100"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Step 1: Build WASM if requested
if [ "$REBUILD" = true ]; then
    echo -e "${YELLOW}📦 Building WASM...${NC}"
    zig build wasm
    echo -e "${GREEN}✅ WASM build complete${NC}"
    echo ""
fi

# Check if WASM exists
if [ ! -f "zig-out/bin/guillotine_mini.wasm" ]; then
    echo -e "${RED}❌ Error: WASM file not found${NC}"
    echo -e "${YELLOW}Run with --rebuild to build it first${NC}"
    exit 1
fi

# Show WASM size
SIZE=$(ls -lh zig-out/bin/guillotine_mini.wasm | awk '{print $5}')
echo -e "${GREEN}📦 WASM Size: ${SIZE}${NC}"
echo ""

# Step 2: Generate function mapping
echo -e "${YELLOW}🗺️  Generating function name mapping...${NC}"
bun scripts/map-wasm-functions.ts
echo ""

# Step 3: Run comprehensive analysis
echo -e "${YELLOW}📊 Running comprehensive size analysis...${NC}"
bun scripts/analyze-wasm-size.ts --limit "$LIMIT"
echo ""

# Step 4: Display key insights
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}📈 Key Insights${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Extract top 5 from function-sizes.txt
if [ -f "reports/wasm-size/function-sizes.txt" ]; then
    echo -e "${GREEN}Top 5 Functions by Size:${NC}"
    echo ""
    grep -A 100 "^Index" reports/wasm-size/function-sizes.txt | head -11 | tail -6
    echo ""
fi

# Show category summary
if [ -f "reports/wasm-size/function-sizes.txt" ]; then
    echo -e "${GREEN}Size by Category:${NC}"
    echo ""
    grep -A 20 "Summary by Category:" reports/wasm-size/function-sizes.txt | tail -8
    echo ""
fi

# Final message
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Analysis Complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📁 Reports saved to:${NC} reports/wasm-size/"
echo ""
echo -e "${YELLOW}📖 Key files:${NC}"
echo "  • function-sizes.txt      - Functions sorted by size with names"
echo "  • function-mapping.json   - Machine-readable function database"
echo "  • ANALYSIS_SUMMARY.md     - Comprehensive analysis and recommendations"
echo "  • wasm-sections.txt       - Section-level breakdown"
echo ""
echo -e "${YELLOW}💡 Next steps:${NC}"
echo "  1. Review: cat reports/wasm-size/ANALYSIS_SUMMARY.md"
echo "  2. Implement optimizations (see recommendations)"
echo "  3. Re-run this script to measure impact"
echo ""
