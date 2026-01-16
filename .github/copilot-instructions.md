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
```

### Modifying AWK Processing
The `parse_atop_output()` function (lines 287-576) processes atop's structured output:
- **PRG:** Process general info (PID, command name)
- **PRC:** CPU metrics (user_ticks, sys_ticks)
- **PRM:** Memory metrics (RSS in KB)
- **PRD:** Disk I/O metrics (sectors read/written)
- **DSK:** System-level disk stats

Variables MUST use AWK arrays indexed by PID: `prc_cpu_sum[pid]`, `prm_mem_peak[pid]`

## Error Handling Conventions

### Validation Pattern (All User Inputs)
```bash
if ! [[ $VALUE =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$VALUE" -lt 0 ]; then
    echo "ERROR: Invalid value: $VALUE" >&2
    exit 1
fi
```
See `validate_config()` (lines 104-151) for complete validation logic.

### Graceful Degradation
Script runs in **LIMITED_MODE** if non-root (lines 193-202). Per-process disk I/O unavailable but continues monitoring CPU/memory. Always check `LIMITED_MODE` flag before processing disk metrics.

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

## Known Constraints
- **Platform:** Linux only (requires `/proc` filesystem)
- **atop version:** Requires >= 2.3.0 for structured output (`-P` flag)
- **Kernel config:** CONFIG_TASK_IO_ACCOUNTING needed for per-process disk stats
- **Root privileges:** Recommended for full metrics; degrades gracefully without

## When Modifying This Script
1. Preserve ShellCheck cleanliness (zero warnings)
2. Track all temp resources in CLEANUP arrays
3. Test both root and non-root execution
4. Verify trap handlers work with `kill -TERM`
5. Update IMPLEMENTATION_SUMMARY.md for significant changes
6. Test replay mode after parsing changes
