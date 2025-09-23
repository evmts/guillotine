#!/usr/bin/env bash
set -euo pipefail

FIXTURES_TYPE="fixtures_stable"  # Can be fixtures_stable, fixtures_develop, or fixtures_benchmark
FIXTURES_BASE_DIR="test/execution-spec-tests/fixtures"
FIXTURES_DIR="$FIXTURES_BASE_DIR/$FIXTURES_TYPE"
VERSION_FILE=".test-fixtures-version"
REQUIRED_VERSION=$(cat "$VERSION_FILE")
CURRENT_VERSION_FILE="$FIXTURES_DIR/.version"

# Check if we already have the right version
if [[ -f "$CURRENT_VERSION_FILE" ]]; then
    CURRENT_VERSION=$(cat "$CURRENT_VERSION_FILE")
    if [[ "$CURRENT_VERSION" == "$REQUIRED_VERSION" ]]; then
        echo "✅ Test fixtures ($FIXTURES_TYPE) $REQUIRED_VERSION already installed"
        exit 0
    fi
fi

echo "📥 Fetching Ethereum test fixtures ($FIXTURES_TYPE) $REQUIRED_VERSION..."

# Get absolute path for the fixtures directory
REPO_ROOT=$(git rev-parse --show-toplevel)
FIXTURES_DIR_ABS="$REPO_ROOT/$FIXTURES_DIR"

# Clean old fixtures
rm -rf "$FIXTURES_DIR_ABS"
mkdir -p "$REPO_ROOT/$FIXTURES_BASE_DIR"

# Create temp directory for extraction
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Download from GitHub releases (ethereum/execution-spec-tests)
echo "Downloading $FIXTURES_TYPE.tar.gz..."
curl -L "https://github.com/ethereum/execution-spec-tests/releases/download/$REQUIRED_VERSION/${FIXTURES_TYPE}.tar.gz" \
     -o "$TEMP_DIR/fixtures.tar.gz"

# Extract to temp directory
cd "$TEMP_DIR"
tar -xzf fixtures.tar.gz

# Move the extracted 'fixtures' directory to the correct location with the right name
mv fixtures "$FIXTURES_DIR_ABS"

# Mark version
echo "$REQUIRED_VERSION" > "$FIXTURES_DIR_ABS/.version"

echo "✅ Test fixtures ($FIXTURES_TYPE) $REQUIRED_VERSION installed"