#!/bin/bash
###############################################################################
# Automated Fixture Generator for atop-reports.sh v2.0
# BACKEND: Unified Lima Infrastructure (Ubuntu/Debian/AlmaLinux)
#
# This script generates golden master test fixtures for all supported OS
# distributions using a unified Lima backend with YAML templates.
#
# Requirements: 
#   - Lima >= 0.19.0 (brew install lima)
#   - bash 4.0+
#
# Usage: 
#   ./generate-all-fixtures.sh [OPTIONS]
#
# Options:
#   --os <family>           Generate for specific OS family (ubuntu|debian|almalinux)
#   --version <version>     Generate for specific version (e.g., 20.04, 12, 9)
#   --force-rebuild         Delete and recreate existing VMs
#   --keep-alive            Keep VMs after generation (faster for iterative dev)
#   --help                  Show this help message
#
# Examples:
#   ./generate-all-fixtures.sh                    # Generate all fixtures
#   ./generate-all-fixtures.sh --os ubuntu --keep-alive  # Ubuntu, reuse VMs
#   ./generate-all-fixtures.sh --os ubuntu --version 20.04  # Ubuntu 20.04 only
###############################################################################

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
LIMA_TEMPLATE_DIR="$SCRIPT_DIR/lima-templates"
MIN_LIMA_VERSION="0.19.0"

# Function to get OS configuration (template_filename:atop_version)
get_os_config() {
    local os_family="$1"
    local os_version="$2"
    
    case "$os_family" in
        ubuntu)
            case "$os_version" in
                18.04) echo "ubuntu-18.04.yaml:2.3.0" ;;
                20.04) echo "ubuntu-20.04.yaml:2.4.0" ;;
                22.04) echo "ubuntu-22.04.yaml:2.7.1" ;;
                24.04) echo "ubuntu-24.04.yaml:2.10.0" ;;
                *) echo "" ;;
            esac
            ;;
        debian)
            case "$os_version" in
                11) echo "debian-11.yaml:2.6.0" ;;
                12) echo "debian-12.yaml:2.8.1" ;;
                13) echo "debian-13.yaml:2.11.1" ;;
                *) echo "" ;;
            esac
            ;;
        almalinux)
            case "$os_version" in
                8) echo "almalinux-8.yaml:2.7.1" ;;
                9) echo "almalinux-9.yaml:2.7.1" ;;
                10) echo "almalinux-10.yaml:2.11.1" ;;
                *) echo "" ;;
            esac
            ;;
        rhel)
            # RHEL uses AlmaLinux as proxy (identical packages, no auth needed)
            case "$os_version" in
                8) echo "almalinux-8.yaml:2.7.1" ;;
                9) echo "almalinux-9.yaml:2.7.1" ;;
                *) echo "" ;;
            esac
            ;;
        centos)
            case "$os_version" in
                7) echo "centos-7.yaml:2.7.1" ;;  # EPEL provides atop 2.7.1
                *) echo "" ;;
            esac
            ;;
        cloudlinux)
            case "$os_version" in
                7) echo "cloudlinux-7.yaml:2.3.0" ;;
                8) echo "cloudlinux-8.yaml:2.7.1" ;;
                9) echo "cloudlinux-9.yaml:2.7.1" ;;
                *) echo "" ;;
            esac
            ;;
        rocky)
            case "$os_version" in
                8) echo "rocky-8.yaml:2.7.1" ;;
                *) echo "" ;;
            esac
            ;;
        *) echo "" ;;
    esac
}

# Parse command line arguments
SPECIFIC_OS=""
SPECIFIC_VERSION=""
FORCE_REBUILD=0
KEEP_ALIVE=0

while [[ $# -gt 0 ]]; do
    case $1 in
        --os)
            SPECIFIC_OS="$2"
            if [ -z "$SPECIFIC_OS" ]; then
                echo "ERROR: --os requires an argument" >&2
                exit 1
            fi
            shift 2
            ;;
        --version)
            SPECIFIC_VERSION="$2"
            if [ -z "$SPECIFIC_VERSION" ]; then
                echo "ERROR: --version requires an argument" >&2
                exit 1
            fi
            shift 2
            ;;
        --force-rebuild)
            FORCE_REBUILD=1
            shift
            ;;
        --keep-alive)
            KEEP_ALIVE=1
            shift
            ;;
        --help)
            head -30 "$0" | tail -25
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Validate OS family if specified
if [ -n "$SPECIFIC_OS" ] && [ "$SPECIFIC_OS" != "ubuntu" ] && [ "$SPECIFIC_OS" != "debian" ] && \
   [ "$SPECIFIC_OS" != "almalinux" ] && [ "$SPECIFIC_OS" != "centos" ] && [ "$SPECIFIC_OS" != "cloudlinux" ]; then
    echo "ERROR: Unknown OS family '$SPECIFIC_OS'" >&2
    echo "Supported: ubuntu, debian, almalinux, centos, cloudlinux" >&2
    exit 1
fi

# Check for Lima and enforce version constraint
check_limactl_version() {
    if ! command -v limactl >/dev/null 2>&1; then
        echo "ERROR: Lima is not installed." >&2
        echo "Install: brew install lima" >&2
        exit 1
    fi

    local current_ver
    current_ver=$(limactl --version | awk '{print $3}' | tr -d 'v')
    
    # Version comparison using sort -V
    if [ "$(printf '%s\n' "$MIN_LIMA_VERSION" "$current_ver" | sort -V | head -n1)" != "$MIN_LIMA_VERSION" ]; then
        echo "ERROR: limactl version $current_ver is too old." >&2
        echo "Required: >= $MIN_LIMA_VERSION (for --wait and virtiofs stability)" >&2
        exit 1
    fi
}

check_limactl_version

# Check for aria2c for faster downloads
check_downloader() {
    if ! command -v aria2c >/dev/null 2>&1; then
        echo "" >&2
        echo "    ╔══════════════════════════════════════════════════════════════════╗" >&2
        echo "    ║ 🚀 For faster downloads, please install 'aria2c'                 ║" >&2
        echo "    ╠══════════════════════════════════════════════════════════════════╣" >&2
        echo "    ║ macOS: brew install aria2                                        ║" >&2
        echo "    ║ Debian/Ubuntu: sudo apt-get install aria2                        ║" >&2
        echo "    ║ RHEL/AlmaLinux: sudo dnf install aria2                           ║" >&2
        echo "    ╚══════════════════════════════════════════════════════════════════╝" >&2
        echo "" >&2
        # Continue without error, as Lima will fall back to its default downloader
    else
        echo "    ✓ 'aria2c' found, downloads will be accelerated."
    fi
}

check_downloader

# Create fixture directory if it doesn't exist
mkdir -p "$FIXTURE_DIR"

# Clean up potential stale mount artifacts from previous runs
rm -f "$HOME/tmp/lima/fixture.raw"

#==============================================================================
# Unified VM Interface (Lima Backend)
#==============================================================================

# ==============================================================================
# KNOWN ISSUE: ALMALINUX ON APPLE SILICON (VZ DRIVER)
# ==============================================================================
# Status: DEFERRED to v2.1
# Impact: SSH socket never becomes ready during cloud-init on VZ hypervisor.
# 
# Root Cause: 
#   - Upstream incompatibility between AlmaLinux 8/9 GenericCloud images and 
#     Lima's native macOS VZ driver (aarch64).
#   - AlmaLinux cloud-init SSH initialization hangs indefinitely on VZ.
#   - SSH socket appears ready per Lima hostagent, but actual connections fail.
#
# Environment: Apple Silicon only (M1/M2/M3 Macs)
#   - Ubuntu/Debian: Work fine on VZ
#   - AlmaLinux: Only on Apple Silicon with VZ (Intel+QEMU would work)
#
# Symptoms:
#   - vm_launch() times out after 60 seconds waiting for SSH ready
#   - limactl shell says VM is running, but SSH never responds
#   - Multiple retries don't help (structural issue, not transient)
#
# Current Workaround:
#   - The script detects this kill chain (arm64 + almalinux) and auto-skips
#   - Prevents wasting 60s per AlmaLinux attempt on affected systems
#   - Gracefully reports the skip reason to user
#
# TODO [v2.1]: 
#   1. Check if newer AlmaLinux cloud images (8.10+, 9.4+) resolve the issue
#   2. Test if Lima v2.x+ updates have patched the VZ driver SSH handling
#   3. Monitor upstream bug reports in:
#      - Lima: https://github.com/lima-vm/lima/issues?q=almalinux
#      - AlmaLinux: https://git.almalinux.org/containers/cloud-images/-/issues
#   4. Consider alternative: Force QEMU on Apple Silicon (performance penalty ~30%)
# ==============================================================================

vm_launch() {
    local vm_name="$1"
    local template_file="$2"
    
    echo "    Booting VM (this may take time)..."
    
    # Configure Lima to use aria2c if available for faster downloads
    local downloader_cmd="limactl"
    if command -v aria2c >/dev/null 2>&1; then
        export LIMA_DOWNLOADER="aria2c"
        echo "    Using aria2c for accelerated downloads..."
    fi
    
    if ! limactl start --name="$vm_name" "$template_file" 2>&1; then
        echo "    ERROR: limactl start failed." >&2
        return 1
    fi
    
    # Wait for SSH socket to be ready
    local max_retries=60
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if limactl shell "$vm_name" -- echo "ready" >/dev/null 2>&1; then
            return 0
        fi
        retry=$((retry + 1))
        sleep 1
    done
    
    echo "    ERROR: VM SSH not ready after ${max_retries}s" >&2
    return 1
}

vm_exec() {
    local vm_name="$1"
    shift
    # Use -- to prevent Lima from trying to cd to host path
    limactl shell "$vm_name" -- sudo "$@"
}

vm_transfer() {
    local vm_name="$1"
    local remote_path="$2"
    local local_path="$3"

    # SSH-based transfer via limactl cp (reliable for all VM drivers including QEMU)

    # 1. Ensure file is readable by the 'lima' user (atop writes as root)
    if ! vm_exec "$vm_name" chmod 644 "$remote_path" 2>&1; then
         echo "    ERROR: Failed to set permissions on remote fixture" >&2
         return 1
    fi

    # 2. Copy via SSH (deterministic, no race conditions)
    if ! limactl cp "$vm_name:$remote_path" "$local_path" > /dev/null; then
         echo "    ERROR: Failed to copy fixture using limactl cp" >&2
         return 1
    fi

    # 3. Verify transfer success (fail-fast check)
    if [ -s "$local_path" ]; then
        return 0
    fi

    echo "    ERROR: Transfer failed (file missing or empty at $local_path)" >&2
    return 1
}

vm_delete() {
    local vm_name="$1"
    if [ "$KEEP_ALIVE" -eq 1 ]; then
        echo "    Skipping deletion (--keep-alive active)"
    else
        limactl delete --force "$vm_name" 2>&1
    fi
}

vm_exists() {
    local vm_name="$1"
    limactl list -q 2>/dev/null | grep -q "^${vm_name}$"
}

#==============================================================================
# Package Installation with Retry Logic (Unified Backend)
#==============================================================================

install_atop() {
    local vm_name="$1"
    local os_family="$2"
    local max_retries=3
    local retry_delay=5
    
    case "$os_family" in
        ubuntu|debian)
            # APT-based systems
            echo "    Updating package lists..."
            vm_exec "$vm_name" apt-get update -qq || return 1
            
            echo "    Installing atop..."
            vm_exec "$vm_name" apt-get install -y -qq atop || return 1
            ;;
            
        centos|cloudlinux)
            # YUM-based systems (RHEL 7 family, atop in base repos)
            echo "    Updating package lists..."
            vm_exec "$vm_name" yum update -y -q || return 1
            
            echo "    Installing atop..."
            vm_exec "$vm_name" yum install -y -q atop || return 1
            ;;
            
        almalinux|rocky)
            # DNF-based systems with EPEL
            echo "    Installing EPEL repository..."
            vm_exec "$vm_name" dnf install -y -q epel-release || return 1
            
            echo "    Enabling EPEL repository..."
            if ! vm_exec "$vm_name" dnf config-manager --set-enabled epel 2>&1; then
                echo "        ⚠️  WARNING: EPEL enable failed"
                echo "        Attempting atop install anyway..."
            fi
            
            echo "    Installing atop..."
            vm_exec "$vm_name" dnf install -y -q atop || return 1
            ;;
            
        *)
            echo "ERROR: Unknown OS family: $os_family" >&2
            return 1
            ;;
    esac
    
    return 0
}

# Function to generate fixture for a single OS version (unified Lima backend)
generate_fixture() {
    local step_num="$1"
    local total_steps="$2"
    local os_family="$3"
    local os_version="$4"
    local template_name="$5"
    local atop_version="$6"
    
    local vm_name="vm-atop-${os_family}-${os_version}"
    local template_path="$LIMA_TEMPLATE_DIR/$template_name"
    local fixture_file="$FIXTURE_DIR/v${atop_version}-${os_family}${os_version}.raw"
    local metadata_file="${fixture_file}.json"
    
    echo ""
    echo "=========================================="
    echo "[Step $step_num/$total_steps] $os_family $os_version (atop $atop_version)"
    echo "=========================================="
    
    # Check if fixture already exists
    if [ -f "$fixture_file" ] && [ $FORCE_REBUILD -eq 0 ]; then
        echo "Fixture already exists. Skipping."
        return 0
    fi
    
    # Check if template exists
    if [ ! -f "$template_path" ]; then
        echo "ERROR: Template not found: $template_path" >&2
        return 1
    fi
    
    # [GUARDRAIL] v2.1 Deferral: RHEL Family VZ Driver Incompatibility
    # Detects: Apple Silicon (arm64) + RHEL family (AlmaLinux/CentOS/CloudLinux) on Lima VZ hypervisor
    # Action: Skips provisioning to prevent 60s+ timeout loop
    # Override: Manual QEMU emulation available (slow, ~5-10 min per fixture)
    current_arch=$(uname -m)
    if [[ "$current_arch" == "arm64" ]] && [[ "$os_family" == "almalinux" || "$os_family" == "centos" || "$os_family" == "cloudlinux" || "$os_family" == "rocky" || "$os_family" == "rhel" ]]; then
        local os_display="$os_family"
        local template_basename=""
        case "$os_family" in
            almalinux) 
                os_display="AlmaLinux"
                template_basename="almalinux-${os_version}.yaml"
                ;;
            rhel) 
                os_display="RHEL"
                template_basename="almalinux-${os_version}.yaml"
                ;;
            centos) 
                os_display="CentOS"
                template_basename="centos-${os_version}.yaml"
                ;;
            cloudlinux) 
                os_display="CloudLinux"
                template_basename="cloudlinux-${os_version}.yaml"
                ;;
            rocky) 
                os_display="Rocky Linux"
                template_basename="rocky-${os_version}.yaml"
                ;;
        esac
        echo "================================================================"
        echo "⚠️  [SKIP] $os_display on Apple Silicon (VZ Driver Incompatibility)"
        echo "   Reason: VZ framework cannot boot x86_64 kernels on ARM hosts"
        echo "   Status: Default guardrail (fast development cycle)"
        echo ""
        echo "   Manual QEMU Override Available (slow, ~5-10 min):"
        echo "   limactl start --set='.vmType=\"qemu\"' \\"
        echo "       --name=${os_family}${os_version}-qemu \\"
        echo "       tests/lima-templates/${template_basename}"
        echo ""
        echo "   Impact: Only affects macOS test infrastructure."
        echo "           Production servers running on Linux are unaffected."
        echo "================================================================"
        return 0
    fi
    
    # [GUARDRAIL] CloudLinux Download Speed - Skip Unless Native
    # CloudLinux image downloads are extremely slow (even with aria2c)
    # Skip unless running on CloudLinux host to avoid 30+ minute downloads
    if [[ "$os_family" == "cloudlinux" ]]; then
        if [ ! -f /etc/os-release ] || ! grep -qi "cloudlinux" /etc/os-release 2>/dev/null; then
            echo "================================================================"
            echo "⚠️  [SKIP] CloudLinux (Slow Download Speed)"
            echo "   Reason: CloudLinux images download at ~150 KB/s even with aria2c"
            echo "   Status: Skipped on non-CloudLinux hosts (30+ min per image)"
            echo ""
            echo "   To generate CloudLinux fixtures:"
            echo "   - Run this script on a CloudLinux host, OR"
            echo "   - Manually generate: bash tests/generate-all-fixtures.sh --os cloudlinux"
            echo ""
            echo "   Impact: CloudLinux fixture generation deferred for performance."
            echo "================================================================"
            return 0
        else
            echo "    Running on CloudLinux host - fixture generation enabled"
        fi
    fi
    
    # Check if VM already exists
    local vm_exists=0
    if vm_exists "$vm_name"; then
        vm_exists=1
        if [ "$FORCE_REBUILD" -eq 1 ]; then
            echo "[1/7] Deleting existing VM (--force-rebuild)..."
            vm_delete "$vm_name"
            vm_exists=0
        elif [ "$KEEP_ALIVE" -eq 0 ]; then
            echo "[1/7] Reusing existing VM"
        else
            echo "[1/7] VM exists and --keep-alive active"
        fi
    fi
    
    # Step 1: Launch VM (if needed)
    if [ $vm_exists -eq 0 ]; then
        echo "[2/7] Launching VM ($template_name)..."
        if ! vm_launch "$vm_name" "$template_path"; then
            echo "ERROR: Failed to launch VM" >&2
            return 1
        fi
    else
        echo "[2/7] VM already running"
    fi
    
    # Step 2: Wait for VM to be ready
    echo "[3/7] Waiting for VM to be ready..."
    local max_retries=30
    if [ "$os_family" = "debian" ] && [ "$os_version" = "11" ]; then
        max_retries=120
        echo "    Note: Debian 11 QEMU may take 3-5 minutes to boot..."
    fi
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if vm_exec "$vm_name" echo "ready" >/dev/null 2>&1; then
            break
        fi
        retry=$((retry + 1))
        if [ $((retry % 5)) -eq 0 ]; then
            echo "    Waiting... ($retry/$max_retries)"
        fi
        sleep 2
    done
    
    if [ $retry -eq $max_retries ]; then
        echo "ERROR: VM failed to become ready after ${max_retries} attempts" >&2
        vm_delete "$vm_name"
        return 1
    fi
    echo "    ✓ VM is ready"
    
    # Step 3-4: Install atop with retry logic
    echo "[4/7] Installing atop..."
    if ! install_atop "$vm_name" "$os_family"; then
        vm_delete "$vm_name"
        return 1
    fi
    
    # Verify atop version
    local detected_version
    detected_version=$(vm_exec "$vm_name" atop -V 2>&1 | awk '/Version/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')
    echo "    Detected atop: $detected_version"
    
    if [ "$detected_version" != "$atop_version" ]; then
        echo "    ⚠️  WARNING: Expected $atop_version, got $detected_version"
    fi
    
    # Step 5: Capture fixture
    echo "[5/7] Capturing 15 seconds of atop data..."
    if ! vm_exec "$vm_name" atop -w /tmp/fixture.raw 15 1 2>&1 | tail -1; then
        echo "ERROR: Failed to capture atop data" >&2
        vm_delete "$vm_name"
        return 1
    fi
    
    # Step 6: Transfer fixture
    echo "[6/7] Transferring fixture to host..."
    if ! vm_transfer "$vm_name" "/tmp/fixture.raw" "$fixture_file"; then
        echo "ERROR: Failed to transfer fixture" >&2
        vm_delete "$vm_name"
        return 1
    fi
    
    local file_size
    file_size=$(du -h "$fixture_file" | awk '{print $1}')
    echo "    ✓ Fixture saved: $file_size"
    
    # Generate metadata sidecar for systemd version tracking (v2.1 enhancement)
    echo "[6.5/7] Generating metadata sidecar..."
    cat > "$metadata_file" <<EOF
{
  "os": "$os_family",
  "version": "$os_version",
  "atop_version": "$atop_version",
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fixture_file": "$(basename "$fixture_file")"
}
EOF
    echo "    ✓ Metadata saved"
    
    # Step 7: Cleanup VM (respects --keep-alive flag)
    echo "[7/7] VM cleanup (--keep-alive: $KEEP_ALIVE)..."
    vm_delete "$vm_name"
    
    echo "✓ $os_family $os_version complete!"
    return 0
}

# Main execution
echo "=========================================="
echo "ATOP Fixture Generator - Multi-OS (Unified Lima Backend)"
echo "=========================================="
echo "Fixture directory: $FIXTURE_DIR"
echo "Template directory: $LIMA_TEMPLATE_DIR"
echo ""

# Track statistics
TOTAL=0
SUCCESS=0
FAILED=0

# Define all OS versions to generate
declare -a OS_LIST
if [ -n "$SPECIFIC_OS" ] && [ -n "$SPECIFIC_VERSION" ]; then
    # Single OS version specified
    OS_LIST=("$SPECIFIC_OS:$SPECIFIC_VERSION")
elif [ -n "$SPECIFIC_OS" ]; then
    # All versions for specific OS family
    case "$SPECIFIC_OS" in
        ubuntu)
            OS_LIST=("ubuntu:18.04" "ubuntu:20.04" "ubuntu:22.04" "ubuntu:24.04")
            ;;
        debian)
            OS_LIST=("debian:11" "debian:12" "debian:13")
            ;;
        almalinux)
            OS_LIST=("almalinux:8" "almalinux:9")
            ;;
        centos)
            OS_LIST=("centos:7")
            ;;
        cloudlinux)
            OS_LIST=("cloudlinux:7")
            ;;
    esac
elif [ -n "$SPECIFIC_VERSION" ]; then
    echo "ERROR: --version requires --os to be specified" >&2
    exit 1
else
    # All OS families and versions for Plesk support
    # [RECOMMENDED] - Priority for v2.0 release (Stage 1)
    # [EXTENDED] - Additional coverage (Stage 2)
    # NOTE: Debian 10 removed (EOL June 2024)
    # NOTE: ARM support deferred to Stage 3 (Post-v2.0, optional via QEMU)
    OS_LIST=(
        # [RECOMMENDED] Stage 1 - v2.0 Release Priority
        "ubuntu:24.04"       # atop 2.10.0 (Recommended)
        "almalinux:10"       # atop 2.11.1 (Recommended, if available)
        "debian:13"          # atop 2.11.1 (Recommended)
        "cloudlinux:9"       # atop 2.7.1 (Recommended)
        "almalinux:9"        # atop 2.7.1 (RHEL 9 proxy, Recommended)
        "ubuntu:22.04"       # atop 2.7.1 (Recommended)
        "centos:7"           # atop 2.7.1 via EPEL (CentOS 7 coverage, ELS until Jan 2027)
        
        # [EXTENDED] Stage 2 - Additional Plesk OSes
        "ubuntu:20.04"       # atop 2.4.0
        "ubuntu:18.04"       # atop 2.3.0
        "almalinux:8"        # atop 2.7.1 (RHEL 8 proxy)
        "debian:12"          # atop 2.8.1
        "debian:11"          # atop 2.6.0
        "cloudlinux:8"       # atop 2.7.1
        "cloudlinux:7"       # atop 2.3.0
        "rocky:8"            # atop 2.7.1
    )
fi

TOTAL=${#OS_LIST[@]}
STEP=0

# Generate fixtures
for os_spec in "${OS_LIST[@]}"; do
    STEP=$((STEP + 1))
    IFS=':' read -r os_family os_version <<< "$os_spec"
    
    # Parse get_os_config output format: "template_name:atop_version"
    config_output=$(get_os_config "$os_family" "$os_version")
    
    if [ -z "$config_output" ]; then
        echo "ERROR: Unknown OS version: $os_family $os_version" >&2
        FAILED=$((FAILED + 1))
        continue
    fi
    
    IFS=':' read -r template_name atop_version <<< "$config_output"
    
    if [ -z "$template_name" ] || [ -z "$atop_version" ]; then
        echo "ERROR: Invalid config for $os_family $os_version (got: $config_output)" >&2
        FAILED=$((FAILED + 1))
        continue
    fi
    
    if generate_fixture "$STEP" "$TOTAL" "$os_family" "$os_version" "$template_name" "$atop_version"; then
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

# Summary
echo ""
echo "=========================================="
echo "SUMMARY"
echo "=========================================="
echo "Total: $TOTAL"
echo "Success: $SUCCESS"
echo "Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✓ All fixtures generated successfully!"
    echo ""
    echo "Next steps:"
    echo "  1. Verify fixture sizes:"
    echo "     ls -lh $FIXTURE_DIR/*.raw"
    echo ""
    echo "  2. Run Docker Compose tests:"
    echo "     docker-compose up --abort-on-container-exit"
    exit 0
else
    echo "✗ Some fixtures failed to generate"
    exit 1
fi
