#!/bin/bash
################################################################################
# Universal Fixture Generator for Deployed Linux Machines
# 
# Generates atop-reports test fixtures on any Linux system with atop installed.
# No VMs, no special dependencies - just one command on a deployed machine.
#
# Usage:
#   ./universal-fixture-generator.sh [OUTPUT_DIR]
#   ./universal-fixture-generator.sh /tmp
#   ./universal-fixture-generator.sh  # Saves to current directory
#
# Output: v{ATOP_VERSION}-{OS}-{RELEASE}.raw (e.g., v2.7.1-ubuntu-22.04.raw)
#
# Requirements:
#   - atop installed and accessible
#   - bash 3.x+
#   - ~10 seconds runtime (15-second atop capture)
#
################################################################################

set -e

OUTPUT_DIR="${1:-.}"

# ============================================================================
# VALIDATION
# ============================================================================

# Check atop is installed
if ! command -v atop &>/dev/null; then
    echo "❌ ERROR: atop is not installed or not in PATH" >&2
    echo "Install with:" >&2
    echo "  Ubuntu/Debian: sudo apt-get install atop" >&2
    echo "  RHEL/CentOS/AlmaLinux: sudo yum install atop" >&2
    exit 1
fi

# Check output directory exists and is writable
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "❌ ERROR: Output directory does not exist: $OUTPUT_DIR" >&2
    exit 1
fi

if [ ! -w "$OUTPUT_DIR" ]; then
    echo "❌ ERROR: Output directory is not writable: $OUTPUT_DIR" >&2
    exit 1
fi

# ============================================================================
# DETECT SYSTEM INFO
# ============================================================================

# Get atop version
ATOP_VERSION=$(atop -V 2>&1 | grep -oP 'Version\s+\d+\.\d+\.\d+' | grep -oP '\d+\.\d+\.\d+')
if [ -z "$ATOP_VERSION" ]; then
    ATOP_VERSION=$(atop -V 2>&1 | grep -oP '\d+\.\d+\.\d+' | head -1)
fi
if [ -z "$ATOP_VERSION" ]; then
    echo "❌ ERROR: Could not detect atop version" >&2
    exit 1
fi

# Get OS and release (fallback chain for maximum compatibility)
OS_NAME=""
OS_RELEASE=""

if command -v lsb_release &>/dev/null; then
    OS_NAME=$(lsb_release -is 2>/dev/null | tr '[:upper:]' '[:lower:]')
    OS_RELEASE=$(lsb_release -rs 2>/dev/null)
elif [ -f /etc/os-release ]; then
    OS_NAME=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    OS_RELEASE=$(grep '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
elif [ -f /etc/redhat-release ]; then
    OS_NAME="rhel"
    OS_RELEASE=$(grep -oP '\d+\.\d+' /etc/redhat-release | head -1)
elif [ -f /etc/debian_version ]; then
    OS_NAME="debian"
    OS_RELEASE=$(cat /etc/debian_version)
else
    OS_NAME="unknown"
    OS_RELEASE="0.0"
fi

# Validate detection
if [ -z "$OS_NAME" ] || [ -z "$OS_RELEASE" ]; then
    echo "❌ ERROR: Could not detect OS information" >&2
    echo "Try setting OS info manually:" >&2
    echo "  export OS_NAME=ubuntu OS_RELEASE=22.04" >&2
    echo "  $0 $OUTPUT_DIR" >&2
    exit 1
fi

FIXTURE_NAME="v${ATOP_VERSION}-${OS_NAME}-${OS_RELEASE}.raw"
OUTPUT_FILE="$OUTPUT_DIR/$FIXTURE_NAME"

# ============================================================================
# GENERATE FIXTURE
# ============================================================================

echo "════════════════════════════════════════════════════════════════"
echo "🔧 Generating Test Fixture"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  atop version:      $ATOP_VERSION"
echo "  OS:                $OS_NAME"
echo "  Release:           $OS_RELEASE"
echo "  Output:            $OUTPUT_FILE"
echo ""
echo "  Capturing 15-second atop snapshot..."
echo ""

# Capture fixture (15 second window)
if sudo atop -P PRG,PRC,PRM,PRD,DSK 1 15 > "$OUTPUT_FILE" 2>&1; then
    echo "✓ Snapshot captured successfully"
else
    echo "❌ ERROR: Failed to capture atop snapshot" >&2
    rm -f "$OUTPUT_FILE"
    exit 1
fi

# ============================================================================
# VALIDATE OUTPUT
# ============================================================================

if [ ! -f "$OUTPUT_FILE" ]; then
    echo "❌ ERROR: Fixture file was not created" >&2
    exit 1
fi

FILE_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || stat -f%z "$OUTPUT_FILE" 2>/dev/null || echo "0")
FILE_SIZE_KB=$((FILE_SIZE / 1024))

if [ "$FILE_SIZE" -lt 100 ]; then
    echo "❌ ERROR: Fixture file is too small ($FILE_SIZE bytes) - likely contains only error messages" >&2
    cat "$OUTPUT_FILE" >&2
    rm -f "$OUTPUT_FILE"
    exit 1
fi

LINE_COUNT=$(wc -l < "$OUTPUT_FILE")

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "✅ SUCCESS"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  Fixture:           $FIXTURE_NAME"
echo "  Size:              $FILE_SIZE_KB KB"
echo "  Lines:             $LINE_COUNT"
echo "  Location:          $OUTPUT_FILE"
echo ""
echo "📋 To use this fixture:"
echo "   1. Move to atop-reports/tests/fixtures/"
echo "   2. Run Docker Compose test: docker-compose run test-<service>"
echo ""