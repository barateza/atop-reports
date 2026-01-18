#!/bin/bash
# Quick fixture validation script (runs on systems with atop installed)
# Usage: ./validate-fixture.sh <fixture.raw>

set -euo pipefail

FIXTURE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATOP_REPORTS="$SCRIPT_DIR/../atop-reports.sh"

if [ ! -f "$FIXTURE" ]; then
    echo "ERROR: Fixture not found: $FIXTURE" >&2
    exit 1
fi

if ! command -v atop >/dev/null 2>&1; then
    echo "ERROR: atop not installed" >&2
    exit 1
fi

echo "=========================================="
echo "Validating fixture: $(basename "$FIXTURE")"
echo "=========================================="

# Convert binary to parseable
TEMP_TXT=$(mktemp -t atop-validate.XXXXXX)
trap "rm -f '$TEMP_TXT'" EXIT

atop -r "$FIXTURE" -P PRG,PRC,PRM,PRD,DSK > "$TEMP_TXT"

echo ""
echo "[1/4] Fixture statistics:"
echo "  - Size: $(du -h "$FIXTURE" | awk '{print $1}')"
echo "  - SEP lines (samples): $(grep -c '^SEP' "$TEMP_TXT" || echo 0)"
echo "  - PRG lines (processes): $(grep -c '^PRG' "$TEMP_TXT" || echo 0)"
echo "  - Atop version: $(head -1 "$TEMP_TXT" | awk '{print $1 " " $2}')"

# Check for header lines (dynamic detection test)
echo ""
echo "[2/4] Header detection:"
if grep -q '^PRG .* pid ' "$TEMP_TXT"; then
    echo "  ✓ PRG header found (supports dynamic detection)"
else
    echo "  ✗ PRG header NOT found (will use fallback)"
fi

# Check for Container ID field
echo ""
echo "[3/4] Container ID support:"
PRG_HEADER=$(grep '^PRG .* pid ' "$TEMP_TXT" | head -1 || echo "")
if echo "$PRG_HEADER" | grep -iq 'cid\|container'; then
    echo "  ✓ Container ID field present (atop 2.7.1+)"
else
    echo "  ⚠ Container ID field absent (atop < 2.7.1)"
fi

# Test with atop-reports.sh
echo ""
echo "[4/4] Testing with atop-reports.sh:"
if "$ATOP_REPORTS" --file "$TEMP_TXT" --json > /dev/null 2>&1; then
    echo "  ✓ Text parsing successful"
else
    echo "  ✗ Text parsing FAILED"
    exit 1
fi

if "$ATOP_REPORTS" --file "$TEMP_TXT" --json 2>&1 | jq -e '.meta.schema_version == "2.0"' > /dev/null 2>&1; then
    echo "  ✓ JSON output valid (schema v2.0)"
else
    echo "  ✗ JSON output FAILED or wrong schema"
    exit 1
fi

# Check container_id field presence
JSON_OUTPUT=$("$ATOP_REPORTS" --file "$TEMP_TXT" --json 2>&1)
if echo "$JSON_OUTPUT" | jq -e '.data.processes[0].container_id' > /dev/null 2>&1; then
    echo "  ✓ container_id field present in JSON"
else
    echo "  ✗ container_id field MISSING"
    exit 1
fi

echo ""
echo "=========================================="
echo "✅ All validations passed!"
echo "=========================================="
