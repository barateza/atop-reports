#!/bin/bash
###############################################################################
# Docker-based Fixture Generator for atop-reports.sh
# Generates golden master fixtures for all supported OS versions
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
mkdir -p "$FIXTURES_DIR"

# Configuration matrix
declare -a FIXTURES=(
    "ubuntu:18.04:2.3.0:v2.3.0-ubuntu18.04.raw"
    "ubuntu:20.04:2.4.0:v2.4.0-ubuntu20.04.raw"
    "ubuntu:22.04:2.7.1:v2.7.1-ubuntu22.04.raw"
    "debian:10:2.4.0:v2.4.0-debian10.raw"
    "debian:11:2.6.0:v2.6.0-debian11.raw"
    "debian:12:2.8.1:v2.8.1-debian12.raw"
    "debian:13:2.11.1:v2.11.1-debian13.raw"
)

# Utility functions
print_status() {
    echo -e "${BLUE}[*]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}
print_status() {
    echo "[*] $1"
}

print_success() {
    echo "[✓] $1"
}

print_error() {
    echo "[✗] $1" >&2
}

# Generate fixture for a single OS
generate_fixture() {
    local os_image="$1"
    local expected_version="$2"
    local fixture_name="$3"
    local fixture_path="$FIXTURES_DIR/$fixture_name"
    
    print_status "Generating: $fixture_name (OS: $os_image, atop: $expected_version)"
    
    if [ -f "$fixture_path" ]; then
        print_status "  Fixture exists ($(du -h "$fixture_path" | cut -f1))"
        return 0
    fi
    
    # Create temp script for container
    local script_file
    script_file=$(mktemp)
    cat > "$script_file" << 'DOCKER_SCRIPT'
#!/bin/bash
apt-get update -qq 2>&1 | grep -v "^Get:"
apt-get install -y atop 2>&1 | tail -1
atop -P PRG,PRC,PRM,PRD,DSK 1 15
DOCKER_SCRIPT
    
    print_status "  Pulling image: $os_image..."
    docker pull "$os_image" > /dev/null 2>&1
    
    print_status "  Capturing 15-second snapshot..."
    if docker run --rm -i "$os_image" bash < "$script_file" > "$fixture_path" 2>/dev/null; then
        local fixture_size
        fixture_size=$(du -h "$fixture_path" | cut -f1)
        local line_count
        line_count=$(wc -l < "$fixture_path")
        
        print_success "Generated: $fixture_name ($fixture_size, $line_count lines)"
        rm -f "$script_file"
        return 0
    else
        print_error "Failed to generate $fixture_name"
        rm -f "$script_file" "$fixture_path"
        return 1
    fi
}

# Main execution
main() {
    echo "════════════════════════════════════════════════════════════════"
    echo "  atop-reports.sh Fixture Generator (Docker Edition)"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
    
    if ! docker ps > /dev/null 2>&1; then
        print_error "Docker daemon not running"
        exit 1
    fi
    
    print_status "Docker $(docker --version | awk '{print $3}')"
    echo ""
    
    local success_count=0
    local fail_count=0
    
    for fixture_spec in "${FIXTURES[@]}"; do
        IFS=':' read -r os_image expected_version fixture_name <<< "$fixture_spec"
        
        if generate_fixture "$os_image" "$expected_version" "$fixture_name"; then
            ((success_count++))
        else
            ((fail_count++))
        fi
    done
    
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "  Summary: $success_count generated, $fail_count failed"
    echo "════════════════════════════════════════════════════════════════"
    
    if [ $success_count -gt 0 ]; then
        echo ""
        ls -lh "$FIXTURES_DIR"/*.raw 2>/dev/null || echo "No fixtures found"
    fi
    
    [ $fail_count -eq 0 ] && exit 0 || exit 1
}

main "$@"
