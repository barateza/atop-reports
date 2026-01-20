#!/bin/bash
###############################################################################
# ⚠️ DEPRECATED: Use tests/generate-all-fixtures.sh instead (Lima-based, all OS families)
###############################################################################
# Fixture Generation Script - Multipass-based golden master capture
# 
# This script automates the generation of atop raw log fixtures for testing
# across multiple Ubuntu versions using Multipass VMs.
#
# Usage: ./generate-fixtures.sh
# 
# Requirements:
#   - Multipass installed (https://multipass.run/)
#   - Internet connection for VM downloads
#
# Output: tests/fixtures/*.raw files
###############################################################################

set -e  # Exit on error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"

# Ensure fixtures directory exists
mkdir -p "$FIXTURE_DIR"

echo "=========================================="
echo "ATOP Fixture Generator"
echo "=========================================="
echo ""

# VM configurations: name, ubuntu version, expected atop version
declare -a VMS=(
    "atop-bionic:18.04:2.3.0"
    "atop-focal:20.04:2.4.0"
    "atop-jammy:22.04:2.7.1"
    "atop-noble:24.04:2.10.0"
)

generate_fixture() {
    local vm_name="$1"
    local ubuntu_version="$2"
    local atop_version="$3"
    local fixture_file="$FIXTURE_DIR/v${atop_version}-ubuntu${ubuntu_version}.raw"
    
    echo "=========================================="
    echo "Generating fixture: $fixture_file"
    echo "VM: $vm_name (Ubuntu $ubuntu_version)"
    echo "Expected atop: $atop_version"
    echo "=========================================="
    
    # Check if fixture already exists
    if [ -f "$fixture_file" ]; then
        read -p "Fixture already exists. Overwrite? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Skipping $vm_name"
            return
        fi
    fi
    
    # Launch VM
    echo "[1/7] Launching VM..."
    multipass launch "$ubuntu_version" --name "$vm_name" --memory 1G --disk 5G --cpus 1
    
    # Wait for VM to be ready with retry logic
    echo "[2/7] Waiting for VM to initialize..."
    local max_retries=30
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if multipass exec "$vm_name" -- echo "ready" >/dev/null 2>&1; then
            echo "    ✓ VM is ready"
            break
        fi
        retry=$((retry + 1))
        echo "    Waiting for SSH... ($retry/$max_retries)"
        sleep 2
    done
    
    if [ $retry -eq $max_retries ]; then
        echo "    ✗ ERROR: VM failed to become ready"
        multipass delete "$vm_name" --purge
        return 1
    fi
    
    # Update package lists
    echo "[3/7] Updating package lists..."
    if ! multipass exec "$vm_name" -- sudo apt-get update -qq; then
        echo "    ✗ ERROR: Failed to update package lists"
        multipass delete "$vm_name" --purge
        return 1
    fi
    
    # Install atop
    echo "[4/7] Installing atop..."
    if ! multipass exec "$vm_name" -- sudo apt-get install -y atop >/dev/null 2>&1; then
        echo "    ✗ ERROR: Failed to install atop"
        multipass delete "$vm_name" --purge
        return 1
    fi
    
    # Verify atop version
    echo "[5/7] Verifying atop version..."
    actual_version=$(multipass exec "$vm_name" -- atop -V 2>&1 | awk '/Version/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')
    echo "    Detected: $actual_version (expected: $atop_version)"
    
    # Capture 15-second atop snapshot
    echo "[6/7] Capturing 15-second snapshot..."
    if ! multipass exec "$vm_name" -- sudo atop -w /tmp/fixture.raw 15 1; then
        echo "    ✗ ERROR: Failed to capture atop snapshot"
        multipass delete "$vm_name" --purge
        return 1
    fi
    
    # Transfer fixture to host
    echo "[7/7] Transferring fixture to host..."
    if ! multipass transfer "$vm_name:/tmp/fixture.raw" "$fixture_file"; then
        echo "    ✗ ERROR: Failed to transfer fixture"
        multipass delete "$vm_name" --purge
        return 1
    fi
    
    # Verify fixture size
    local size
    size=$(stat -f%z "$fixture_file" 2>/dev/null || stat -c%s "$fixture_file" 2>/dev/null || echo 0)
    if [ "$size" -gt 0 ]; then
        echo "    ✓ Fixture created: $fixture_file ($((size / 1024))KB)"
    else
        echo "    ✗ ERROR: Fixture is empty!"
        rm -f "$fixture_file"
    fi
    
    # Cleanup VM
    echo "    Cleaning up VM..."
    multipass delete "$vm_name" --purge
    
    echo ""
}

# Check if multipass is installed
if ! command -v multipass >/dev/null 2>&1; then
    echo "ERROR: Multipass is not installed."
    echo "Install from: https://multipass.run/"
    echo ""
    echo "macOS: brew install multipass"
    exit 1
fi

# Generate fixtures for each version
for vm_config in "${VMS[@]}"; do
    IFS=':' read -r vm_name ubuntu_version atop_version <<< "$vm_config"
    generate_fixture "$vm_name" "$ubuntu_version" "$atop_version"
done

echo "=========================================="
echo "Fixture generation complete!"
echo "=========================================="
echo ""
echo "Generated files:"
ls -lh "$FIXTURE_DIR"/*.raw 2>/dev/null || echo "No fixtures created."
echo ""
echo "Next steps:"
echo "  1. Commit fixtures to git (they're ~1-5MB each)"
echo "  2. Run tests: ./tests/run-test.sh"
echo "  3. Verify output against expected JSON schemas"
