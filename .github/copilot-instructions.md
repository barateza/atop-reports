# ATOP Resource Monitor - AI Agent Instructions

## Project Overview
Production-hardened bash script that monitors Plesk server resources (CPU, memory, disk I/O) using `atop`. Captures 15-second snapshots when thresholds are exceeded, generates ranked reports of resource offenders. Designed for fleet deployment via Ansible/Puppet.

**Current Version:** 2.0.0 (January 16, 2026)

**Key Files:**
- [atop-reports.sh](../atop-reports.sh) - Main monitoring script (882 lines)
- [atop-reports.conf.example](../atop-reports.conf.example) - Config template for `/etc/atop-reports.conf`
- [README.md](../README.md) - User documentation and architecture decisions
- [IMPLEMENTATION_v2.0.md](../IMPLEMENTATION_v2.0.md) - v2.0 dynamic header detection & Container ID support
- [MIGRATION.md](../MIGRATION.md) - v1.1 → v2.0 migration guide (breaking changes)
- [TESTING_STATUS.md](../TESTING_STATUS.md) - CI/CD test results across Ubuntu 18.04-24.04

## Critical Architecture Patterns

### v2.0 Dynamic Header Detection
ALL atop parsing MUST use dynamic column detection to avoid field position brittleness:
```awk
# Parse header to build dynamic column map
$1 ~ /^(PRG|PRC|PRM|PRD|DSK)$/ && NF > 10 && $7 !~ /^[0-9]+$/ {
    type = $1
    for (i = 1; i <= NF; i++) {
        col_map[type, toupper($i)] = i
    }
    next
}

# Use dynamic column lookup in data lines
/^PRG/ && $7 ~ /^[0-9]+$/ {
    pid = $(col_map["PRG", "PID"])
    cmd_name = $(col_map["PRG", "NAME"])
    cid = $(col_map["PRG", "CID"])  # atop 2.7.1+ only
}
```
**Why:** atop field positions vary between versions (2.3.0: 17 CPU fields, 2.4.0+: 21 CPU fields). Dynamic detection eliminates hardcoded `$7`, `$8` assumptions.

**Fallback mechanism:** If dynamic detection fails, script falls back to version-based maps (FIELD_MAP_V23, FIELD_MAP_V24, FIELD_MAP_V27) defined at lines 255-279.

### Resource Lifecycle Management
ALL temp resources MUST be tracked for cleanup via trap handlers:
```bash
# Create temp file
SNAPSHOT_FILE=$(mktemp -t atop-snapshot.XXXXXX)
chmod 600 "$SNAPSHOT_FILE"
CLEANUP_FILES+=("$SNAPSHOT_FILE")  # Track for cleanup

# Create temp directory
temp_dir=$(mktemp -d -t atop-parse.XXXXXX)
chmod 700 "$temp_dir"
CLEANUP_DIRS+=("$temp_dir")  # Track for cleanup
```
The `cleanup()` function (lines 195-226) iterates these arrays on EXIT/TERM/INT/HUP signals.

### ShellCheck Compliance (Zero Warnings Required)
- **SC2155:** Separate declaration from assignment:
  ```bash
  # WRONG
  local result=$(some_command)
  
  # CORRECT
  local result
  result=$(some_command)
  ```
- **SC2129:** Group multiple redirects:
  ```bash
  # WRONG
  echo "Line 1" >> "$LOG_FILE"
  echo "Line 2" >> "$LOG_FILE"
  
  # CORRECT
  {
      echo "Line 1"
      echo "Line 2"
  } >> "$LOG_FILE"
  ```
- **Portable AWK over grep -oP:** This script uses GNU coreutils but runs on BSD/macOS too. Use `awk` pattern matching instead of `grep -P` for regex.

### Hybrid Configuration Philosophy
Script works out-of-box with inline defaults (lines 63-89) but loads `/etc/atop-reports.conf` if present (lines 95-100). This enables:
- **Quick diagnosis:** Download and run immediately
- **Fleet deployment:** Ansible/Puppet pushes custom configs

When adding new config variables, add both inline default and document in [atop-reports.conf.example](../atop-reports.conf.example).

### Disk I/O Percentage (Relative Scaling)
Disk % is calculated relative to heaviest process, NOT absolute hardware limits:
```bash
# In AWK (lines 493-501)
max_disk_total = max disk usage across all processes
disk_percent[pid] = (pid_disk_usage / max_disk_total) * 100
```
**Rationale:** NVMe vs HDD have vastly different throughput. Relative scaling creates hardware-agnostic "Heaviest Offender Index" (see README lines 241-249).

### Non-Blocking Metrics Collection
System metrics MUST NOT block monitoring loop. CPU I/O wait calculated via dual `/proc/stat` samples (lines 760-785):
```bash
# Before: vmstat 1 2 → 2s blocking delay
# After: /proc/stat sampling → 0.1s delay (95% reduction)
grep '^cpu ' /proc/stat  # Sample 1
sleep 0.1
grep '^cpu ' /proc/stat  # Sample 2
# Calculate delta manually
```

## Test Fixture Management

### Automated Fixture Generation (Multi-OS Support)

The project uses golden master fixtures for cross-version testing across **10 OS distributions** (Ubuntu, Debian, AlmaLinux). These fixtures are binary atop snapshots captured from VMs using a **unified Lima backend** for all OS families.

**Fixture Generation Script:** `tests/generate-all-fixtures.sh`

**VM Naming Convention:**

All test VMs follow a unified naming scheme: `vm-atop-${os_family}-${os_version}`

Examples:
- `vm-atop-ubuntu-18.04` (atop 2.3.0)
- `vm-atop-debian-12` (atop 2.8.1)
- `vm-atop-almalinux-9` (atop 2.7.1)

Benefit: Unified naming provides consistency across all hypervisors (Lima/QEMU/VZ) and enables abstract `vm_launch()`, `vm_exec()`, `vm_transfer()` interfaces that work identically for all OS families.

**Prerequisites:**
```bash
# Install Lima (unified VM backend for all OS families)
brew install lima

# Verify installation
limactl version
```

**Full Workflow (30 minutes warm, 2+ hours cold):**
```bash
cd /path/to/atop-reports

# Generate all fixtures (10 OS versions)
./tests/generate-all-fixtures.sh

# Generate specific OS family
./tests/generate-all-fixtures.sh --os debian
./tests/generate-all-fixtures.sh --os almalinux

# Generate single version
./tests/generate-all-fixtures.sh --os debian --version 12

# Force rebuild (delete and recreate VMs)
./tests/generate-all-fixtures.sh --force-rebuild
```

**What happens internally:**
1. **Unified Interface:** Routes all OS families through identical `vm_launch()`, `vm_exec()`, `vm_transfer()` abstractions
2. **VM Launch:** Creates VMs with 2GB RAM / 2 CPUs (prevents OOM)
3. **VM Reuse Check:** Prompts to reuse existing VMs (5 min warm run)
4. **Package Installation:**
   - Ubuntu/Debian: `apt-get install atop`
   - AlmaLinux/CentOS/CloudLinux: `dnf/yum install atop` (with EPEL retry for AlmaLinux)
5. **Version Verification:** Confirms atop version matches expected
6. **Capture:** `atop -w /tmp/fixture.raw 15 1` (15 seconds)
7. **Transfer:** SSH-based `limactl cp` (deterministic, no race conditions)
8. **Cleanup:** Optional VM deletion (or keep for reuse)

**Advantages over Legacy Multipass Approach:**
- Single backend works for all OS families (not platform-specific split)
- SSH-based transfer more reliable than VirtioFS mounts
- Unified abstractions enable code reuse and maintainability
- Intelligent guardrails handle platform constraints (e.g., Apple Silicon VZ timeout)

**Manual Fixture Generation (if automation fails):**

**For Debian (Multipass):**
```bash
# Example: Debian 12
multipass launch debian:12 --name mp-atop-debian12 --memory 2G --disk 5G --cpus 2

# Wait for VM to be ready (check with)
multipass exec mp-atop-debian12 -- echo "ready" || sleep 5

# Update package lists
multipass exec mp-atop-debian12 -- sudo apt-get update -qq

# Install atop (includes automatic version detection)
multipass exec mp-atop-debian12 -- sudo apt-get install -y -qq atop

# Verify version before capture
multipass exec mp-atop-debian12 -- atop -V
# Expected: Version 2.8.1 for Debian 12

# Capture 15-second snapshot (MUST run as root)
multipass exec mp-atop-debian12 -- sudo atop -w /tmp/fixture.raw 15 1
# Note: -w writes binary, 15 = sample interval (seconds), 1 = iteration count
# Total capture time: 15 seconds

# Verify fixture exists and has reasonable size
multipass exec mp-atop-debian12 -- ls -lh /tmp/fixture.raw
# Expected: 5-20KB for idle VM, 50-500KB for loaded system

# Transfer to host
multipass transfer mp-atop-debian12:/tmp/fixture.raw ./tests/fixtures/v2.8.1-debian12.raw

# Verify transfer succeeded
ls -lh ./tests/fixtures/v2.8.1-debian12.raw

# Cleanup VM (or keep for reuse)
multipass delete mp-atop-debian12 --purge
```

**For AlmaLinux (Lima):**
```bash
# Example: AlmaLinux 9
limactl start --name lima-atop-alma9 ./tests/lima-templates/almalinux-9.yaml

# Wait for VM readiness
sleep 10

# Install EPEL (required for atop)
limactl shell lima-atop-alma9 sudo dnf install -y epel-release

# Install atop
limactl shell lima-atop-alma9 sudo dnf install -y atop

# Verify version
limactl shell lima-atop-alma9 atop -V
# Expected: Version 2.7.1 for AlmaLinux 9

# Capture 15-second snapshot
limactl shell lima-atop-alma9 sudo atop -w /tmp/fixture.raw 15 1

# Copy to shared mount
limactl shell lima-atop-alma9 sudo cp /tmp/fixture.raw /tmp/lima/fixture.raw
limactl shell lima-atop-alma9 sudo chmod 644 /tmp/lima/fixture.raw

# Transfer to host (Lima shares home directory)
cp ~/.lima/lima-atop-alma9/tmp/lima/fixture.raw ./tests/fixtures/v2.7.1-almalinux9.raw

# Verify transfer
ls -lh ./tests/fixtures/v2.7.1-almalinux9.raw

# Cleanup VM
limactl delete --force lima-atop-alma9
```

**Troubleshooting VM Issues:**
- **Multipass launch timeout:** Increase retry timeout or check internet connection
- **Lima EPEL fails:** Retry manually (mirrors can be flaky), script has 3-attempt retry
- **SSH not ready:** Add `sleep 10` after launch, before first exec
- **Transfer fails:** Check disk space on host, verify fixture exists in VM
- **Empty fixture:** atop needs root, ensure VM has process activity
- **OOM during dnf install:** Increase VM memory to 2GB (already default)

**Supported Versions:**
| OS Family | Version | Codename | atop Version | Container ID | Fixture File |
|-----------|---------|----------|--------------|--------------|--------------|
| Ubuntu | 18.04 | bionic | 2.3.0 | ❌ Never | v2.3.0-ubuntu18.04.raw |
| Ubuntu | 20.04 | focal | 2.4.0 | ❌ Never | v2.4.0-ubuntu20.04.raw |
| Ubuntu | 22.04 | jammy | 2.7.1 | ✅ Available | v2.7.1-ubuntu22.04.raw |
| Ubuntu | 24.04 | noble | 2.10.0 | ✅ Available | v2.10.0-ubuntu24.04.raw |
| Debian | 10 | buster | 2.4.0 | ❌ Never | v2.4.0-debian10.raw |
| Debian | 11 | bullseye | 2.6.0 | ⚠️ Partial | v2.6.0-debian11.raw |
| Debian | 12 | bookworm | 2.8.1 | ✅ Available | v2.8.1-debian12.raw |
| Debian | 13 | trixie | 2.11.1 | ✅ Available | v2.11.1-debian13.raw |
| AlmaLinux | 8 | - | 2.7.1 | ✅ Available | v2.7.1-almalinux8.raw |
| AlmaLinux | 9 | - | 2.7.1 | ✅ Available | v2.7.1-almalinux9.raw |

**Important Notes:**
- Ubuntu/Debian 22.04+ use version numbers (not codenames) in Multipass
- AlmaLinux uses Lima YAML templates (not Multipass images)
- atop 2.7.1+ includes Container ID field (Field 17 in PRG label)
- Fixtures are binary format - use `atop -r` to convert to text
- Each fixture contains 15 samples (1 per second) from idle VM
- Fixture size varies: 5-20KB idle, 50-500KB under load, 1-5MB on busy production servers
- Debian 12/13 are **critical** - they test untested atop versions 2.8.1 and 2.11.1

### Container ID Support Details

**When is Container ID Available?**

Container ID extraction requires ALL of these conditions:

1. **atop Version:** 2.7.1 or higher
   - Added in atop 2.7.1 (released March 2020)
   - Check with: `atop -V`

2. **Kernel Version:** Linux 4.14+ with cgroup support
   - Container ID read from `/proc/[pid]/cgroup`
   - Check with: `uname -r` (should be >= 4.14)

3. **Cgroup Configuration:**
   - **cgroup v2 (preferred):** Unified hierarchy at `/sys/fs/cgroup`
   - **cgroup v1 (legacy):** Multiple hierarchies, may show different CIDs
   - Check with: `stat -fc %T /sys/fs/cgroup` → `cgroup2fs` (v2) or `tmpfs` (v1)

4. **Container Runtime:**
   - **Docker:** CID format `abc123def456...` (12-64 chars)
   - **Podman:** CID format similar to Docker
   - **Kubernetes:** CID shows pod container ID, not pod name
   - **LXC/LXD:** May show container name directly

5. **Process Context:**
   - Process must be running inside a container
   - Host processes show CID as empty or `-`
   - Systemd services (even in containers) may show systemd slice instead

**Testing Container ID Extraction:**
```bash
# On a system with Docker installed
docker run -d --name test-nginx nginx:alpine

# Capture snapshot
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 3 > /tmp/docker-test.txt

# Check if CID appears in output
grep "^PRG" /tmp/docker-test.txt | head -1 | awk '{print NF}'
# Should print 17 or more (Field 17 = CID)

grep "nginx" /tmp/docker-test.txt | grep "^PRG" | awk '{print $17}'
# Should show container ID (12+ hex chars) or "-" if not available

# Cleanup
docker stop test-nginx && docker rm test-nginx
```

**Why Container ID Might Be Empty:**
- atop < 2.7.1 (field doesn't exist)
- Process not containerized (host process)
- Kernel missing cgroup support (check `/proc/[pid]/cgroup`)
- SELinux/AppArmor blocking cgroup reads
- Container runtime doesn't expose cgroup info

**Graceful Degradation:**
- Script uses `null` in JSON output when CID unavailable
- Text output shows CID only with `--verbose` flag
- Fixtures from Ubuntu 18.04/20.04 always have `container_id: null`
- Fixtures from Ubuntu 22.04/24.04 may have CID if VM runs containers

### Docker Compose Testing
After generating fixtures, validate with Docker:

```bash
# Test all versions (10 OS distributions)
docker-compose up --abort-on-container-exit

# Test single version
docker-compose run --rm test-bionic   # Ubuntu 18.04
docker-compose run --rm test-focal    # Ubuntu 20.04
docker-compose run --rm test-jammy    # Ubuntu 22.04
docker-compose run --rm test-noble    # Ubuntu 24.04
docker-compose run --rm test-debian10 # Debian 10
docker-compose run --rm test-debian11 # Debian 11
docker-compose run --rm test-debian12 # Debian 12 (CRITICAL - atop 2.8.1)
docker-compose run --rm test-debian13 # Debian 13 (LATEST - atop 2.11.1)
docker-compose run --rm test-alma8    # AlmaLinux 8
docker-compose run --rm test-alma9    # AlmaLinux 9
```

**Test Coverage per Version:**
- Text output format validation
- JSON schema v2.0 validation
- Container ID field presence (null-safe)
- Verbose mode execution
- Dynamic header detection
- Version fallback mechanism
- OS-specific package management (apt vs dnf+EPEL)

## Common Development Tasks

### Adding New Metrics
1. Parse from atop output in `parse_atop_output()` AWK block (lines 295-575)
2. Add to process scoring algorithm (lines 489-501)
3. Update JSON schema version if adding fields to `data.processes[]`
4. Document in README JSON Schema section (lines 163-191)

### Testing Changes
```bash
# 1. Syntax validation
bash -n atop-reports.sh

# 2. ShellCheck (must be CLEAN)
shellcheck atop-reports.sh

# 3. Test replay mode with existing fixture
atop -r tests/fixtures/v2.3.0-ubuntu18.04.raw -P PRG,PRC,PRM,PRD,DSK > /tmp/test.txt
./atop-reports.sh --file /tmp/test.txt
./atop-reports.sh --file /tmp/test.txt --json | jq .

# 4. Test signal handling (verify cleanup)
sudo ./atop-reports.sh &
PID=$!
sleep 5
sudo kill -TERM $PID
ls /run/lock/atop-reports.lock  # Should NOT exist

# 5. Run Docker Compose test suite (after code changes)
docker-compose run --rm test-bionic   # Test v2.3.0
docker-compose run --rm test-focal    # Test v2.4.0
docker-compose run --rm test-jammy    # Test v2.7.1 (with Container ID)
docker-compose run --rm test-noble    # Test v2.10.0
docker-compose run --rm test-debian12 # Test v2.8.1 (CRITICAL)
docker-compose run --rm test-debian13 # Test v2.11.1 (LATEST)
docker-compose run --rm test-alma8    # Test AlmaLinux 8
docker-compose run --rm test-alma9    # Test AlmaLinux 9

# 6. Regenerate fixtures if AWK parsing logic changed
./tests/generate-all-fixtures.sh
docker-compose up --abort-on-container-exit  # Validate all versions

# 7. Test on real system with live data
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 15 > /tmp/live.txt
./atop-reports.sh --file /tmp/live.txt --verbose
```

**Version-Specific Testing Notes:**
- v2.3.0 (Ubuntu 18.04): No Container ID, tests null handling
- v2.4.0 (Ubuntu 20.04): Transition version, no major field changes
- v2.6.0 (Debian 11): Version gap test, partial Container ID support
- v2.7.1 (Ubuntu 22.04): Container ID field added (Field 17), tests CID extraction
- v2.8.1 (Debian 12): **CRITICAL** - Untested version, validates dynamic detection
- v2.10.0 (Ubuntu 24.04): Latest format, most comprehensive test
- v2.11.1 (Debian 13): **LATEST** - Future-proofing test, bleeding edge
- v2.7.1 (AlmaLinux): RHEL family validation, dnf + EPEL testing

### Modifying AWK Processing
The `parse_atop_output()` function (lines 287-576) processes atop's structured output using the **Parseable (-P) format**, which is space-delimited and position-dependent.

**Structured Output Format Used:**
```bash
atop -P PRG,PRC,PRM,PRD,DSK 1 15
```

**Label Types and Field Positions:**
- **PRG (Process General):** Fields 7=PID, 8=CommandName, 9-15=metadata
  - Field 17+ (Container ID) only available in atop 2.7+
- **PRC (CPU metrics):** Fields 7=PID, 11=user_ticks, 12=sys_ticks
  - Total CPU ticks = user_ticks + sys_ticks
- **PRM (Memory metrics):** Fields 7=PID, 11=RSS (KB)
  - Direct mapping to resident memory
- **PRD (Disk I/O):** Fields 7=PID, 12=sectors_read, 14=sectors_write
  - Convert sectors to KB: sectors × 0.5 (512 bytes/sector)
- **DSK (System disk):** Fields 9=sectors_read, 11=sectors_write
  - System-level aggregation for unattributed I/O

**Critical Parsing Rules:**
1. **Position-Dependent:** Field meaning determined by index, not labels
2. **Version-Sensitive:** Field positions shift between atop versions
   - atop 2.3.0 (Ubuntu 18.04): 17 CPU fields
   - atop 2.4.0+ (Ubuntu 20.04+): 21 CPU fields (added frequency/IPC)
3. **AWK Arrays:** MUST use PID as index: `prc_cpu_sum[pid]`, `prm_mem_peak[pid]`
4. **Sample Counting:** Track samples via `/^SEP/` delimiter to calculate averages

### Website Identification Logic
The `get_parent_info()` function (lines 642-741) extracts website/vhost details from process command lines:

**PHP-FPM pool detection:**
```bash
# Extract from cmdline like: php-fpm: pool www or pool=example.com
pool=$(echo "$cmdline" | awk -F'pool[= ]' 'NF>1 {print $2}' | awk '{print $1}')
if [ -z "$pool" ]; then
    pool=$(echo "$cmdline" | awk -F'php-fpm: pool ' 'NF>1 {print $2}' | awk '{print $1}')
fi
```

**Apache vhost detection:**
```bash
# Extract from -D flags or .conf file paths
vhost=$(echo "$cmdline" | awk '/-D.*VHOST/ {for(i=1;i<=NF;i++) if($i ~ /^-D.*VHOST/) print $i}' | head -1)
if [ -z "$vhost" ]; then
    vhost=$(echo "$cmdline" | awk -F'-f ' 'NF>1 {print $2}' | awk '{match($0, /\/([^\/]+\.conf)/, a); print a[1]}')
fi
```

**Parent process name:**
```bash
# Skip systemd/init, only show meaningful parents
ppid=$(grep '^PPid:' "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
if [ -n "$ppid" ] && [ "$ppid" -gt 1 ]; then
    parent_name=$(cat "/proc/$ppid/comm" 2>/dev/null)
    # Filter out systemd/init
fi
```

**Output format:** `[pool: example.com, vhost: site.conf, parent: apache2]`

This information appears in text reports after process names to help identify which website is consuming resources.

## Error Handling Conventions

### Validation Pattern (All User Inputs)
```bash
if ! [[ $VALUE =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$VALUE" -lt 0 ]; then
    echo "ERROR: Invalid value: $VALUE" >&2
    exit 1
fi
```

### Lock File Protection
Single-instance enforcement via flock (lines 177-192):
```bash
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "ERROR: Another instance already running" >&2
    exit 1
fi
```
Lock released automatically by `cleanup()` trap handler.

## JSON Output Contract
Schema version 2.0 with metadata envelope and Container ID support (lines 533-575). Breaking changes require version bump to 3.0. Field additions don't require version change (forward-compatible parsers ignore unknown fields).

**Null Safety:** Use `null` for unavailable metrics (e.g., disk I/O in LIMITED_MODE, Container ID in atop < 2.7.1), never omit fields or use placeholder strings.

**v2.0 Schema Example:**
```json
{
  "meta": {
    "schema_version": "2.0",
    "timestamp": "2026-01-16T14:30:00Z",
    "hostname": "server.example.com",
    "mode": "full"
  },
  "data": {
    "processes": [{
      "process": "nginx",
      "container_id": "abc123def456",  // null if N/A
      "avg": {"cpu_percent": 45.2, ...},
      "peak": {"cpu_percent": 78.1, ...}
    }]
  }
}
```

## Production Deployment Notes
- **Systemd integration:** Script loops infinitely; suitable for `Type=simple` service
- **Log rotation:** Append-only to `LOG_FILE`; configure logrotate separately
- **Memory usage:** ~50-100MB typical, up to 200MB with 10,000+ processes
- **Alert cooldown:** `COOLDOWN` period prevents log spam during sustained incidents

## Official Deployment Targets

The script is designed for Plesk-supported operating systems with atop installed from official repositories:

### Ubuntu
- **24.04 LTS (Recommended):** atop 2.10.0
- **22.04 LTS (incl. ARM):** atop 2.7.1
- **20.04 LTS:** atop 2.4.0
- **18.04 LTS:** atop 2.3.0

### Debian
- **13 (Testing/Trixie):** atop 2.11.1
- **12 (Bookworm):** atop 2.8.1
- **11 (Bullseye):** atop 2.6.0
- **10 (Buster):** atop 2.4.0

### AlmaLinux / RHEL / CloudLinux / CentOS
- **AlmaLinux 8.x / RHEL 8.x:** atop 2.7.1
- **CloudLinux 9.x / 8.x:** atop 2.7.1
- **CloudLinux 7.x / CentOS 7.x:** atop 2.7.1

**Minimum version:** 2.3.0 for structured output (`-P` flag support)

## Common Test Infrastructure Issues

### Fixture Generation Problems

**Issue: Lima Shared Mount Contamination (CRITICAL)**
```
ERROR: raw file has incompatible format (created by version 2.11 - current version 2.6)
```
**Root Cause:** All Lima VMs share the same `~/tmp/lima` mount from the host
**Impact:** Sequential fixture generation causes version contamination
**Solutions:**
```bash
# The fix is already applied in lima_transfer() function
# But if you see this error, manually clean the shared mount:
rm -f ~/tmp/lima/fixture.raw

# Before regenerating fixtures:
limactl delete --force lima-atop-debian11
rm -f ~/tmp/lima/fixture.raw tests/fixtures/v2.6.0-debian11.raw
./tests/generate-all-fixtures.sh --os debian --version 11
```

**Prevention:** The script now automatically cleans `~/tmp/lima/fixture.raw` before each transfer. Multiple Lima VMs running simultaneously may still share state through this mount.

**Issue: Multipass VM Launch Fails**
```
ERROR: Failed to launch VM: timeout waiting for initialization
```
**Root Cause:** Hypervisor not running, network timeout, or resource exhaustion
**Solutions:**
```bash
# Check Multipass daemon status
multipass version
multipass list  # Should show running VMs

# Restart Multipass service (macOS)
sudo launchctl kickstart -k system/com.canonical.multipassd

# Restart Multipass service (Linux)
sudo systemctl restart multipass.multipassd

# Check available resources
multipass info --all  # Shows CPU/memory usage

# Delete stale VMs
multipass delete --all --purge

# Last resort: Reinstall Multipass
brew reinstall multipass  # macOS
```

**Issue: SSH Readiness Timeout**
```
Waiting for SSH...... (60 attempts)
ERROR: VM never became SSH-ready
```
**Root Cause:** VM networking not initialized, firewall blocking, or slow VM boot
**Solutions:**
```bash
# Increase retry timeout in generate-all-fixtures.sh
# Change: MAX_RETRIES=60 to MAX_RETRIES=120

# Check VM status manually
multipass list  # Should show "Running"
multipass exec vm-name -- echo "test"  # Test SSH directly

# Check network connectivity
multipass exec vm-name -- ping -c 3 8.8.8.8

# If using VPN: Disable VPN and retry (Multipass + VPN = conflicts)
```

**Issue: APT Package Installation Fails**
```
E: Unable to locate package atop
```
**Root Cause:** APT cache not updated, wrong Ubuntu version, or mirror issues
**Solutions:**
```bash
# Update APT cache manually
multipass exec vm-name -- sudo apt-get update
multipass exec vm-name -- sudo apt-cache search atop

# Check Ubuntu version in VM
multipass exec vm-name -- cat /etc/os-release

# Try different Ubuntu mirror
multipass exec vm-name -- sudo sed -i 's|archive.ubuntu.com|mirror.example.com|g' /etc/apt/sources.list
multipass exec vm-name -- sudo apt-get update
```

**Issue: Fixture File Empty or Corrupt**
```
Fixture size: 0 bytes
```
**Root Cause:** atop capture failed (permissions, no activity, or interrupted)
**Solutions:**
```bash
# Verify atop works in VM
multipass exec vm-name -- sudo atop 1 1  # Should show metrics

# Check VM has process activity
multipass exec vm-name -- ps aux | wc -l  # Should be > 50

# Generate synthetic load during capture
multipass exec vm-name -- sudo sh -c 'stress-ng --cpu 2 --vm 1 --vm-bytes 256M --timeout 30s & atop -w /tmp/fixture.raw 15 1'

# Verify fixture before transfer
multipass exec vm-name -- ls -lh /tmp/fixture.raw
multipass exec vm-name -- file /tmp/fixture.raw  # Should show "data"
```

### Docker Compose Test Failures

**Issue: Docker Container Won't Start**
```
ERROR: for test-jammy  Cannot start service test-jammy: ...
```
**Root Cause:** Docker not running, image pull failed, or volume mount issue
**Solutions:**
```bash
# Check Docker daemon
docker info  # Should show server version
sudo systemctl start docker  # Linux
open -a Docker  # macOS Docker Desktop

# Pull images manually
docker pull ubuntu:18.04
docker pull ubuntu:20.04
docker pull ubuntu:22.04
docker pull ubuntu:24.04

# Check volume mounts
ls -la tests/fixtures/  # Files must exist
chmod 644 tests/fixtures/*.raw  # Ensure readable
```

**Issue: Test Script Not Found**
```
/tests/run-test.sh: No such file or directory
```
**Root Cause:** Volume mount misconfiguration or incorrect working directory
**Solutions:**
```bash
# Verify volume mounts in docker-compose.yml
grep -A2 "volumes:" docker-compose.yml
# Should show:
#   - .:/app
#   - ./tests:/tests

# Check file exists on host
ls -la tests/run-test.sh
chmod +x tests/run-test.sh  # Ensure executable

# Test mount directly
docker-compose run test-jammy ls -la /tests/
```

**Issue: Fixture Not Found in Container**
```
[3/5] Checking fixture availability...
✗ ERROR: Fixture not found: /tests/fixtures/v2.7.1-ubuntu22.04.raw
```
**Root Cause:** Fixture not generated, wrong filename, or mount path issue
**Solutions:**
```bash
# List fixtures on host
ls -la tests/fixtures/

# Verify expected filename format
# Format: v{ATOP_VERSION}-ubuntu{UBUNTU_VERSION}.raw
# Example: v2.7.1-ubuntu22.04.raw

# Check fixture accessible in container
docker-compose run test-jammy ls -la /tests/fixtures/

# Generate missing fixture
./tests/generate-all-fixtures.sh --version 22.04
```

**Issue: atop Version Mismatch**
```
⚠️  WARNING: Version mismatch (expected 2.7.1, got 2.7.0)
```
**Root Cause:** Ubuntu repo has slightly different atop version than fixture name
**Impact:** Tests continue but field positions might differ slightly
**Solutions:**
```bash
# Check actual version in container
docker-compose run test-jammy atop -V

# If test fails: Regenerate fixture with actual version
# OR: Adjust expected version in test script
# tests/run-test.sh: Change ATOP_VERSION="2.7.1" to match actual
```

### Dynamic Header Detection Failures

**Issue: Fallback Warning in Logs**
```
⚠️  Dynamic header detection failed, using legacy field map
```
**Root Cause:** atop output format changed or header line missing
**Impact:** Script uses hardcoded field positions (may break on new atop versions)
**Solutions:**
```bash
# Capture raw output to debug
atop -P PRG,PRC,PRM,PRD,DSK 1 2 > /tmp/debug.txt

# Check header line format
grep "^PRG" /tmp/debug.txt | head -1
# Expected: "PRG host epoch date time interval pid ppid..."

# Count fields
grep "^PRG" /tmp/debug.txt | head -1 | awk '{print NF}'
# v2.3.0: 16 fields, v2.7.1+: 17+ fields

# If header missing: Update FIELD_MAP in atop-reports.sh for this version
# If header format changed: Update dynamic detection regex
```

**Issue: Container ID Always Null**
```json
{"container_id": null}
```
**Root Cause:** See "Container ID Support Details" section above
**Quick Check:**
```bash
# Verify atop version supports CID
atop -V  # Should be >= 2.7.1

# Check if any process has cgroup info
grep "docker\|lxc\|kubepods" /proc/*/cgroup 2>/dev/null | head
# If empty: No containers running on system

# Run test container
docker run -d --name test nginx:alpine
sudo atop -P PRG 1 1 | grep nginx
# Field 17 should show container ID
```

## Known Constraints
- **Platform:** Linux only (requires `/proc` filesystem)
- **Kernel config:** CONFIG_TASK_IO_ACCOUNTING needed for per-process disk stats
- **Root privileges:** Recommended for full metrics; degrades gracefully without
- **Multipass limitations:** May conflict with VPN, requires nested virtualization on cloud VMs
- **Docker requirements:** Tests require Docker 19.03+ and docker-compose 1.27+

## Code Quality Standards

### Function Length Limit
**Hard requirement:** Functions MUST NOT exceed 150 lines for maintainability and readability.

If refactoring a function that exceeds this limit:
1. Extract logical sections into helper functions
2. Use clear, descriptive function names
3. Maintain single responsibility principle
4. Document helper functions with comments

Example refactoring approach:
```bash
# BEFORE: 200-line parse_atop_output() function

# AFTER: Split into logical components
parse_atop_output() {
    validate_snapshot_file "$snapshot_file"
    parse_process_metrics "$snapshot_file"
    calculate_scores_and_ranks "$temp_dir"
    format_output "$report_file"
}
```

### Checklist for All Changes
1. Preserve ShellCheck cleanliness (zero warnings)
2. Track all temp resources in CLEANUP arrays
3. Test both root and non-root execution
4. Verify trap handlers work with `kill -TERM`
5. Keep functions under 150 lines
6. Update IMPLEMENTATION_v2.0.md for significant changes
7. Run Docker Compose tests on all 4 versions
8. Regenerate fixtures if AWK parsing logic modified
9. Test with both --json and text output formats
10. Verify verbose mode if modifying Container ID logic
