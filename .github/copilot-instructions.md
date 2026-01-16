# ATOP Resource Monitor - AI Agent Instructions

## Project Overview
Production-hardened bash script that monitors Plesk server resources (CPU, memory, disk I/O) using `atop`. Captures 15-second snapshots when thresholds are exceeded, generates ranked reports of resource offenders. Designed for fleet deployment via Ansible/Puppet.

**Key Files:**
- [atop-reports.sh](../atop-reports.sh) - Main monitoring script (882 lines)
- [atop-reports.conf.example](../atop-reports.conf.example) - Config template for `/etc/atop-reports.conf`
- [README.md](../README.md) - User documentation and architecture decisions
- [IMPLEMENTATION_SUMMARY.md](../IMPLEMENTATION_SUMMARY.md) - v1.1 production fixes changelog

## Critical Architecture Patterns

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

### Automated Fixture Generation
The project uses golden master fixtures for cross-version testing. These fixtures are binary atop snapshots captured from VMs running specific Ubuntu versions.

**Fixture Generation Script:** `tests/generate-all-fixtures.sh`

**Generate all fixtures:**
```bash
cd /path/to/atop-reports
./1. Syntax validation
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
- v2.7.1 (Ubuntu 22.04): Container ID field added (Field 17), tests CID extraction
- v2.10.0 (Ubuntu 24.04): Latest format, most comprehensive test
**Manual Fixture Generation (if automation fails):**
```bash
# Example: Ubuntu 20.04
multipass launch focal --name atop-focal --memory 1G --disk 5G
multipass exec atop-focal -- sudo apt-get update -qq
multipass exec atop-focal -- sudo apt-get install -y -qq atop
multipass exec atop-focal -- sudo atop -w /tmp/fixture.raw 15 1
multipass transfer atop-focal:/tmp/fixture.raw ./tests/fixtures/v2.4.0-ubuntu20.04.raw
multipass delete atop-focal --purge
```

**Supported Versions:**
| Ubuntu | Codename | atop Version | Fixture File |
|--------|----------|--------------|--------------|
| 18.04  | bionic   | 2.3.0        | v2.3.0-ubuntu18.04.raw |
| 20.04  | focal    | 2.4.0        | v2.4.0-ubuntu20.04.raw |
| 22.04  | jammy    | 2.7.1        | v2.7.1-ubuntu22.04.raw |
| 24.04  | noble    | 2.10.0       | v2.10.0-ubuntu24.04.raw |

**Important Notes:**
- Ubuntu 22.04+ use version numbers (`22.04`) not codenames (`jammy`) in Multipass
- atop 2.7.1+ includes Container ID field (Field 17 in PRG label)
- Fixtures are binary format - use `atop -r` to convert to text
- Each fixture contains 15 samples (1 per second) from idle VM

### Docker Compose Testing
After generating fixtures, validate with Docker:

```bash
# Test all versions
docker-compose up --abort-on-container-exit

# Test single version
docker-compose run --rm test-bionic   # Ubuntu 18.04
docker-compose run --rm test-focal    # Ubuntu 20.04
docker-compose run --rm test-jammy    # Ubuntu 22.04
docker-compose run --rm test-noble    # Ubuntu 24.04
```

**Test Coverage per Version:**
- Text output format validation
- JSON schema v2.0 validation
- Container ID field presence (null-safe)
- Verbose mode execution
- Dynamic header detection
- Version fallback mechanism

## Common Development Tasks

### Adding New Metrics
1. Parse from atop output in `parse_atop_output()` AWK block (lines 295-575)
2. Add to process scoring algorithm (lines 489-501)
3. Update JSON schema version if adding fields to `data.processes[]`
4. Document in README JSON Schema section (lines 163-191)

### Testing Changes
```bash
# Syntax validation
bash -n atop-reports.sh

# ShellCheck (must be CLEAN)
shellcheck atop-reports.sh

# Test replay mode with existing snapshot
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 5 > test.txt
./atop-reports.sh --file test.txt
./atop-reports.sh --file test.txt --json | jq .

# Test signal handling (verify cleanup)
sudo ./atop-reports.sh &
PID=$!
sleep 5
sudo kill -TERM $PID
ls /run/lock/atop-reports.lock  # Should NOT exist

# Test across different atop versions (if available)
atop -V  # Check version
# v2.3.0: No Container ID, no avio field
# v2.7.1+: Container ID present, avio pre-calculated
```

### Modifying AWK Processing
The `parse_atop_output()` function (lines 287-576) processes atop's structured output using the **Parseable (-P) format**, which is space-delimited and position-dependent.

**Structured Output Format Used:**
```bash
atoRun Docker Compose tests on all 4 versions
7. Regenerate fixtures if AWK parsing logic modified
8. Update IMPLEMENTATION_v2.0.md for breaking changes
9. Test with both --json and text output formats
10. Verify verbose mode if modifying Container ID logic``

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
fiCode Quality Standards

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
6. Update IMPLEMENTATION_SUMMARY.md for significant changes
7
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
Schema version 1.0 with metadata envelope (lines 533-575). Breaking changes require version bump to 2.0. Field additions don't require version change (forward-compatible parsers ignore unknown fields).

**Null Safety:** Use `null` for unavailable metrics (e.g., disk I/O in LIMITED_MODE), never omit fields or use placeholder strings.

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

###Atop Parseable Output Architecture

### Format Characteristics
This script uses atop's **Parseable (-P) output**, a legacy format that is:
- **Space-delimited:** Fields separated by single spaces
- **Position-dependent:** Field meaning determined by ordinal position (brittle)
- **Universally supported:** Available in all versions from 2.3.0 to 2.11.1
- **Non-JSON:** Predates JSON output (introduced in atop 2.6.0)

### Version-Specific Field Mapping

**Header Structure (Always Fields 1-6):**
```
Label Host Epoch Date Time Interval
```

**PRG Label Evolution:**
- **v2.3.0-2.6.x:** 16 fields (no Container ID)
- *Compatibility Notes for Future Development

### Atop Output Format Migration
If migrating from Parseable (-P) to JSON (-J) output:
- **Pros:** Schema resilience, type safety, nested data structures
- **Cons:** Not available in Ubuntu 18.04/20.04 (atop < 2.6.0)
- **Current choice:** Parseable format ensures compatibility across all supported OS versions

### Field Position Awareness
When modifying AWK parsing logic:
1. **Never assume field count:** Different atop versions have different field counts
2. **Use explicit field numbers:** Comment with version compatibility
   ```awk
   # Field 7 = PID (stable across all versions)
   # Field 17 = Container ID (only v2.7.1+, may be empty)
   ```
3. **Test on minimum version:** Ubuntu 18.04 (atop 2.3.0) is the compatibility baseline
4. **Document version-specific features:** If using Container ID, note it requires v2.7.1+

### Breaking Change Detection
If atop parsing fails unexpectedly:
```bash
# Capture raw output for debugging
atop -P PRG,PRC,PRM,PRD,DSK 1 2 > debug-snapshot.txt
# Count fields manually
awk '/^PRG/ {print NF; exit}' debug-snapshot.txt  # Should be 16 (v2.3) or 17+ (v2.7+)
```

## When Modifying This Script
1. Preserve ShellCheck cleanliness (zero warnings)
2. Track all temp resources in CLEANUP arrays
3. Test both root and non-root execution
4. Verify trap handlers work with `kill -TERM`
5. Keep functions under 150 lines
6. Update IMPLEMENTATION_SUMMARY.md for significant changes
7. Test replay mode after parsing changes
8. **Verify on minimum atop version (2.3.0)** if changing AWK field position
- **v2.3.0-2.6.x:** No `avio` field (avg I/O time) - must calculate manually
- **v2.7.1+:** Field 14 = `avio` in microseconds (pre-calculated)

### Parsing Robustness Strategy

**Command Name Handling (PRG Field 8):**
```bash
# PROBLEM: Command names can contain spaces (e.g., "python script.py")
# SOLUTION: atop wraps in parentheses but spaces break naive split()
# This script aggregates by command name, so spaces are preserved in AWK
```

**Sector-to-KB Conversion (PRD/DSK):**
```bash
# Linux reports disk I/O in 512-byte sectors
kb_read = sectors_read * 0.5
kb_write = sectors_write * 0.5
```

**Clock Ticks to CPU Percentage:**
```bash
# CPU usage reported in clock ticks (jiffies)
# CLK_TCK = ticks per second (typically 100, validated at startup)
cpu_percent = (total_ticks / CLK_TCK) * 100
```

### Known Constraints
- **Platform:** Linux only (requires `/proc` filesystem)
- **Kernel config:** CONFIG_TASK_IO_ACCOUNTING needed for per-process disk stats
- **Root privileges:** Recommended for full metrics; degrades gracefully without
- **Format Fragility:** Adding fields to atop output breaks position-based parsers
- **AlmaLinux 8.x / RHEL 8.x:** atop 2.7.1

### Debian
- **13 (Testing/Trixie):** atop 2.11.1
- **12 (Bookworm):** atop 2.8.1
- **11 (Bullseye):** atop 2.6.0
- **10 (Buster):** atop 2.4.0

### CloudLinux / CentOS
- **CloudLinux 9.x / 8.x:** atop 2.7.1
- **CloudLinux 7.x / CentOS 7.x:** atop 2.7.1

**Minimum version:** 2.3.0 for structured output (`-P` flag support)

## Known Constraints
- **Platform:** Linux only (requires `/proc` filesystem)
- **Kernel config:** CONFIG_TASK_IO_ACCOUNTING needed for per-process disk stats
- **Root privileges:** Recommended for full metrics; degrades gracefully without

## When Modifying This Script
1. Preserve ShellCheck cleanliness (zero warnings)
2. Track all temp resources in CLEANUP arrays
3. Test both root and non-root execution
4. Verify trap handlers work with `kill -TERM`
5. Update IMPLEMENTATION_SUMMARY.md for significant changes
6. Test replay mode after parsing changes
