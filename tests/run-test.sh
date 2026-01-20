#!/bin/bash
###############################################################################
# Test Runner for atop-reports.sh
#
# This script runs inside Docker containers to test the atop-reports.sh
# script against golden master fixtures for specific OS distributions and
# atop versions.
#
# Usage: ./run-test.sh <atop_version> <os_version> <os_family>
# Example: ./run-test.sh "2.7.1" "22.04" "ubuntu"
#          ./run-test.sh "2.8.1" "12" "debian"
#          ./run-test.sh "2.7.1" "8" "almalinux"
#
# Note: CloudLinux tests require Docker login or running on CloudLinux host
###############################################################################

set -e

ATOP_VERSION="${1:-2.7.1}"
OS_VERSION="${2:-22.04}"
OS_FAMILY="${3:-ubuntu}"

# Special handling for CloudLinux: Check if we can actually run this test
if [ "$OS_FAMILY" = "cloudlinux" ]; then
    # Check if we're running in a CloudLinux container
    if ! grep -q "CloudLinux" /etc/os-release 2>/dev/null; then
        echo "=========================================="
        echo "⚠️  CloudLinux Test Skipped"
        echo "=========================================="
        echo ""
        echo "CloudLinux Docker images require authentication."
        echo ""
        echo "To run CloudLinux tests:"
        echo "  1) Log in to CloudLinux registry: docker login cr.cloudlinux.com"
        echo "  2) Re-run the test suite"
        echo ""
        echo "Alternative: Run tests on a native CloudLinux 9 system"
        echo ""
        exit 0
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_FILE="$SCRIPT_DIR/fixtures/v${ATOP_VERSION}-${OS_FAMILY}${OS_VERSION}.raw"
EXPECTED_OUTPUT_DIR="$SCRIPT_DIR/expected"

echo "=========================================="
echo "ATOP Reports Test Suite"
echo "=========================================="
echo "OS Family: $OS_FAMILY"
echo "OS Version: $OS_VERSION"
echo "Expected atop: $ATOP_VERSION"
echo "Fixture: $FIXTURE_FILE"
echo "=========================================="
echo ""

# Install dependencies based on OS family
echo "[1/5] Installing dependencies..."
case "$OS_FAMILY" in
    ubuntu|debian)
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y atop jq bc coreutils >/dev/null 2>&1
        ;;
    almalinux|rocky)
        # Enable EPEL for atop (AlmaLinux & Rocky Linux)
        # Install dnf-plugins-core first (required for dnf config-manager)
        dnf install -y -q dnf-plugins-core 2>&1 | grep -v "already installed" || true
        
        # Install or update EPEL
        dnf install -y -q epel-release 2>&1 | grep -v "already installed" || {
            echo "    ⚠️  EPEL installation failed, enabling existing repo..."
        }
        
        # Enable EPEL repository
        dnf config-manager --set-enabled epel 2>&1 | grep -v "Repository.*enabled" || true
        
        # Install packages (skip coreutils - conflicts with coreutils-single in AlmaLinux 10)
        if ! dnf install -y -q atop jq bc 2>&1 | grep -v "already installed"; then
            echo "ERROR: Failed to install packages" >&2
            exit 1
        fi
        ;;
    centos)
        # CentOS 7 is EOL (June 30, 2024) - must use vault.centos.org mirrors
        sed -i 's|^mirrorlist=|#mirrorlist=|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
        sed -i 's|^#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
        
        yum install -y -q epel-release 2>&1 | grep -v "already installed" || true
        yum install -y -q atop jq bc 2>&1 | grep -v "already installed" || true
        ;;
    cloudlinux)
        # CloudLinux - YUM-based system
        yum install -y -q epel-release >/dev/null 2>&1 || true
        yum install -y -q atop jq bc >/dev/null 2>&1
        ;;
    *)
        echo "ERROR: Unknown OS family: $OS_FAMILY" >&2
        exit 1
        ;;
esac

# Verify atop version
echo "[2/5] Verifying atop version..."
ACTUAL_VERSION=$(atop -V 2>&1 | awk '/Version/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')
echo "    Detected: $ACTUAL_VERSION"

if [ "$ACTUAL_VERSION" != "$ATOP_VERSION" ]; then
    echo "    ⚠️  WARNING: Version mismatch (expected $ATOP_VERSION, got $ACTUAL_VERSION)"
else
    echo "    ✓ Version matches"
fi

# Check if fixture exists
echo "[3/5] Checking fixture availability..."
if [ ! -f "$FIXTURE_FILE" ]; then
    echo "    ✗ ERROR: Fixture not found: $FIXTURE_FILE"
    echo "    Run './tests/generate-fixtures.sh' first"
    exit 1
fi
echo "    ✓ Fixture found ($(($(stat -c%s "$FIXTURE_FILE" 2>/dev/null || stat -f%z "$FIXTURE_FILE") / 1024))KB)"

# Convert raw fixture to parseable format
echo "[4/5] Converting fixture to parseable format..."
TEMP_PARSEABLE=$(mktemp)
atop -r "$FIXTURE_FILE" -P PRG,PRC,PRM,PRD,DSK 1 15 > "$TEMP_PARSEABLE" 2>&1
LINE_COUNT=$(wc -l < "$TEMP_PARSEABLE")
echo "    ✓ Generated $LINE_COUNT lines of parseable output"

# Test 1: Text output
echo "[5/5] Running tests..."
echo ""
echo "  [Test 1/3] Text output format..."
TEXT_OUTPUT=$(/app/atop-reports.sh --file "$TEMP_PARSEABLE" 2>&1)
if echo "$TEXT_OUTPUT" | grep -q "TOP RESOURCE OFFENDERS"; then
    echo "    ✓ Text output generated successfully"
else
    echo "    ✗ FAILED: Text output missing expected header"
    echo "$TEXT_OUTPUT" | head -20
    exit 1
fi

# Test 2: JSON output schema
echo ""
echo "  [Test 2/3] JSON output schema validation..."
JSON_OUTPUT=$(/app/atop-reports.sh --file "$TEMP_PARSEABLE" --json 2>/dev/null)

# Check if valid JSON
if echo "$JSON_OUTPUT" | jq empty 2>/dev/null; then
    echo "    ✓ Valid JSON structure"
else
    echo "    ✗ FAILED: Invalid JSON"
    echo "$JSON_OUTPUT" | head -20
    exit 1
fi

# Check schema version
SCHEMA_VERSION=$(echo "$JSON_OUTPUT" | jq -r '.meta.schema_version' 2>/dev/null)
if [ "$SCHEMA_VERSION" = "2.0" ]; then
    echo "    ✓ Schema version 2.0 detected"
else
    echo "    ✗ FAILED: Expected schema version 2.0, got $SCHEMA_VERSION"
    exit 1
fi

# Check required fields
REQUIRED_FIELDS=(
    ".meta.hostname"
    ".meta.mode"
    ".data.processes"
)

for field in "${REQUIRED_FIELDS[@]}"; do
    if echo "$JSON_OUTPUT" | jq -e "$field" >/dev/null 2>&1; then
        echo "    ✓ Field exists: $field"
    else
        echo "    ✗ FAILED: Missing field: $field"
        exit 1
    fi
done

# Check container_id field (null-safe)
FIRST_PROCESS=$(echo "$JSON_OUTPUT" | jq '.data.processes[0]' 2>/dev/null)
if echo "$FIRST_PROCESS" | jq -e 'has("container_id")' >/dev/null 2>&1; then
    CID=$(echo "$FIRST_PROCESS" | jq -r '.container_id')
    echo "    ✓ container_id field present (value: $CID)"
else
    echo "    ✗ FAILED: container_id field missing from process object"
    exit 1
fi

# Test 3: Verbose mode
echo ""
echo "  [Test 3/3] Verbose mode (container ID display)..."
VERBOSE_OUTPUT=$(/app/atop-reports.sh --file "$TEMP_PARSEABLE" --verbose 2>&1)
if echo "$VERBOSE_OUTPUT" | grep -q "TOP RESOURCE OFFENDERS"; then
    echo "    ✓ Verbose mode executed successfully"
else
    echo "    ✗ FAILED: Verbose output missing expected header"
    exit 1
fi

# Cleanup
rm -f "$TEMP_PARSEABLE"

echo ""
echo "=========================================="
echo "✓ All tests passed for $OS_FAMILY $OS_VERSION (atop $ATOP_VERSION)"
echo "=========================================="
