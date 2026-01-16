# ATOP Resource Monitor - Production-Ready Edition

## Overview

This script monitors system resources on Plesk servers and generates detailed reports of top resource offenders when thresholds are exceeded. It captures CPU, Memory, and Disk I/O metrics over 15-second windows, identifies problematic processes and websites, and provides ranked analysis to help system administrators diagnose performance issues.

**Version:** 1.1 (Production-Hardened)

## What's New in v1.1

### Critical Production Fixes
- ✅ **Signal handling & graceful shutdown** - Proper cleanup of temp files and child processes
- ✅ **Lock file mechanism** - Prevents multiple instances from conflicting
- ✅ **Secure temporary files** - Uses `mktemp` with proper permissions instead of predictable names
- ✅ **ShellCheck compliance** - Clean output with zero warnings/errors
- ✅ **Hybrid configuration** - Supports both inline defaults and `/etc/atop-reports.conf` override

### Performance Improvements
- ⚡ **Non-blocking metrics** - Replaced `vmstat 1 2` (2s delay) with `/proc/stat` (0.1s delay)
- ⚡ **Instant monitoring** - Reduced check interval latency by 95%
- ⚡ **Validated metrics** - All parsed values checked for validity before comparison

### New Features
- 🎯 **Replay mode** - Analyze existing snapshots with `--file <snapshot>`
- 📊 **JSON output** - Machine-readable format with `--json` flag
- 🔒 **Enhanced security** - Proper temp file handling, input validation, race condition protection
- 📝 **Better error handling** - Comprehensive validation and clear error messages

### Code Quality
- ✨ Portable `awk` instead of GNU-specific `grep -oP`
- ✨ Grouped redirects for efficiency
- ✨ Separated declaration and assignment (SC2155 compliant)
- ✨ Explicit ShellCheck directives for intentional deviations

## Requirements

- **OS:** Linux (RHEL, AlmaLinux, Rocky, Ubuntu, Debian, CloudLinux)
- **Shell:** bash 3.x or higher
- **Tools:** atop >= 2.3.0, GNU coreutils, awk, flock
- **Kernel:** Linux kernel with process accounting (CONFIG_TASK_IO_ACCOUNTING)
- **Privileges:** Root access recommended for full disk I/O metrics (runs in limited mode as non-root)

## Installation

### Quick Start (Single Server)

```bash
# Download the script
wget https://your-repo/atop-reports.sh
chmod +x atop-reports.sh

# Install atop if not present
# RHEL/AlmaLinux/Rocky:
sudo yum install atop

# Ubuntu/Debian:
sudo apt install atop

# Run the script
sudo ./atop-reports.sh
```

### Fleet Deployment (Ansible/Puppet)

```bash
# Copy script to target location
sudo cp atop-reports.sh /usr/local/bin/atop-reports.sh
sudo chmod +x /usr/local/bin/atop-reports.sh

# Create custom configuration (optional)
sudo cp atop-reports.conf.example /etc/atop-reports.conf
sudo vim /etc/atop-reports.conf  # Customize thresholds

# Run as systemd service or cron job
sudo systemctl daemon-reload
sudo systemctl enable atop-reports
sudo systemctl start atop-reports
```

## Configuration

### Inline Defaults (Easy for Quick Diagnosis)

The script works out-of-the-box with sensible defaults:

```bash
LOAD_THRESHOLD=4.0              # Trigger at load average > 4.0
MEM_THRESHOLD=80                # Trigger at memory usage > 80%
IO_WAIT_THRESHOLD=25            # Trigger at I/O wait > 25%
CHECK_INTERVAL=10               # Check every 10 seconds
COOLDOWN=300                    # Wait 5 minutes after alert
LOG_FILE="/var/log/atop-resource-alerts.log"
MIN_OFFENDER_THRESHOLD=10       # Only show processes using > 10% resources
```

### Configuration File Override (Scalable for Fleet)

Create `/etc/atop-reports.conf` to override defaults:

```bash
# /etc/atop-reports.conf
LOAD_THRESHOLD=8.0
MEM_THRESHOLD=90
CHECK_INTERVAL=5
COOLDOWN=180
```

The script automatically loads this file if present, allowing:
- **Quick diagnosis:** Just download and run with defaults
- **Fleet management:** Deploy via Ansible/Puppet with custom configs

## Usage

### Normal Monitoring Mode

```bash
# Run in foreground (Ctrl+C to stop)
sudo ./atop-reports.sh

# Run in background
sudo nohup ./atop-reports.sh > /dev/null 2>&1 &

# Run as systemd service
sudo systemctl start atop-reports
```

### Replay Mode (Post-Mortem Analysis)

```bash
# Capture snapshot during incident
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 15 > /tmp/incident-snapshot.txt

# Later: Analyze the snapshot
./atop-reports.sh --file /tmp/incident-snapshot.txt

# With JSON output
./atop-reports.sh --file /tmp/incident-snapshot.txt --json | jq .
```

### JSON Output (ELK/Grafana Integration)

```bash
# JSON output to stdout
./atop-reports.sh --json

# Pipe to Logstash/Filebeat
./atop-reports.sh --json | filebeat -c filebeat.yml

# Save to file for later processing
./atop-reports.sh --file snapshot.txt --json > report.json
```

## JSON Schema

Version 1.0 schema with metadata envelope:

```json
{
  "meta": {
    "schema_version": "1.0",
    "timestamp": "2026-01-16T14:30:00Z",
    "hostname": "server.example.com",
    "mode": "full",
    "start_time": "2026-01-16 09:30:00",
    "end_time": "2026-01-16 09:30:15",
    "duration_seconds": 15
  },
  "data": {
    "trigger_reason": "HIGH LOAD (5.2)",
    "processes": [
      {
        "process": "php-fpm",
        "avg": {
          "cpu_percent": 45.2,
          "memory_gb": 1.23,
          "memory_percent": 15.4,
          "disk_mbs": 12.5,
          "disk_percent": 65.3
        },
        "peak": {
          "cpu_percent": 78.1,
          "memory_gb": 1.45,
          "memory_percent": 18.1,
          "disk_mbs": 28.3,
          "disk_percent": 100.0
        },
        "score": 52.3
      }
    ],
    "system_disk": {
      "read_mbs": 45.2,
      "write_mbs": 89.7
    }
  }
}
```

## Output Examples

### Text Format (Default)

```
##############################################################################
 ALERT TRIGGERED: 2026-01-16 09:30:00 | REASON: HIGH LOAD (5.2)
##############################################################################

TOP RESOURCE OFFENDERS (Monitored: 2026-01-16 09:30:00 - 2026-01-16 09:30:15, 15 seconds):
================================================================================
#1  php-fpm [pool: example.com, parent: php-fpm]
    AVG:  CPU 45.2%, MEM 1.23GB (15.4%), DISK 12.5 MB/s (65%)
    PEAK: CPU 78.1%, MEM 1.45GB (18.1%), DISK 28.3 MB/s (100%)
    Score: 52.3

#2  mysqld
    AVG:  CPU 23.1%, MEM 0.89GB (11.1%), DISK 8.2 MB/s (43%)
    PEAK: CPU 34.5%, MEM 0.92GB (11.5%), DISK 15.1 MB/s (63%)
    Score: 31.8

================================================================================
System-Level Disk I/O (Unattributed): 45.2 MB/s read, 89.7 MB/s write
```

### JSON Format

```json
{
  "meta": {
    "schema_version": "1.0",
    "timestamp": "2026-01-16T14:30:00Z",
    "hostname": "server.example.com",
    "mode": "full"
  },
  "data": {
    "trigger_reason": "HIGH LOAD (5.2)",
    "processes": [...]
  }
}
```

## Architecture Decisions

### 1. Disk I/O Percentile (Relative Scaling)

**Design:** Disk percentage is calculated relative to the heaviest process (100%), not absolute disk limits.

**Rationale:**
- NVMe drives: 100 MB/s might be 5% of capacity
- SATA HDD: 100 MB/s might saturate the drive
- **Solution:** Relative scaling creates a "Heaviest Offender Index" independent of hardware

### 2. Lock File Location

**Design:** Dynamic hierarchy: `/run/lock` → `/var/lock` → `/tmp`

**Rationale:**
- `/run/lock` (systemd): tmpfs, auto-clears on reboot, prevents stale locks
- `/var/lock` (legacy): compatibility with older systems
- `/tmp` (fallback): works everywhere but less ideal

### 3. JSON Schema Versioning

**Design:** Metadata envelope with `schema_version` field

**Rationale:**
- Field additions (v1.1): Parsers ignore unknown fields safely
- Breaking changes (v2.0): Parsers route based on version before parsing

**Example:**
```json
{
  "meta": {"schema_version": "1.0", ...},
  "data": {...}
}
```

## Troubleshooting

### Script Already Running

```
ERROR: Another instance of this script is already running
Lock file: /run/lock/atop-reports.lock
```

**Solution:** Check if process is actually running: `ps aux | grep atop-reports`. If not, remove stale lock: `sudo rm /run/lock/atop-reports.lock`

### Limited Mode (No Disk I/O)

```
WARNING: Running as non-root user.
Per-process Disk I/O metrics will be unavailable.
```

**Solution:** Run with `sudo` or as `root` for full metrics.

### Configuration Validation Failed

```
ERROR: MEM_THRESHOLD must be between 0-100 (current: 150)
Configuration validation failed with 1 error(s)
```

**Solution:** Check `/etc/atop-reports.conf` or inline values in script. Ensure all thresholds are valid numbers within acceptable ranges.

### Disk Space Warning

```
WARNING: Less than 100MB free in log directory: /var/log
Available: 45MB
```

**Solution:** Clean up old logs or change `LOG_FILE` location in configuration.

## Performance Characteristics

### Resource Usage
- **CPU:** ~0.5-1% during monitoring, ~5-10% during 15s capture
- **Memory:** 50-100MB typical, up to 200MB with 10,000+ processes
- **Disk:** Sequential writes to log file, ~1-5KB per alert
- **I/O Wait Sampling:** 0.1s (vs 2s in older versions)

### Scalability
- Tested on servers with 1,000+ processes
- AWK memory-efficient (associative arrays)
- Alert cooldown prevents log spam

## Security Considerations

### Secure Temporary Files
- Uses `mktemp` with random suffixes (not predictable PIDs)
- Permissions: 700 (dirs), 600 (files)
- Automatic cleanup via trap handlers

### Input Validation
- All configuration values validated before use
- Metrics checked for numeric/non-negative values
- Race condition protection for /proc reads

### Privilege Separation
- Runs in limited mode if non-root (degrades gracefully)
- No sudo escalation attempts
- Clear warnings about missing capabilities

## Development

### Testing

```bash
# Syntax check
bash -n atop-reports.sh

# ShellCheck compliance
shellcheck atop-reports.sh

# Test replay mode
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 5 > test-snapshot.txt
./atop-reports.sh --file test-snapshot.txt

# Test JSON output
./atop-reports.sh --file test-snapshot.txt --json | jq .
```

### Contributing

When modifying the script:
1. Run `shellcheck` and ensure clean output
2. Test both root and non-root modes
3. Test replay mode and JSON output
4. Verify trap handlers clean up temp files
5. Update schema version if breaking JSON format

## License

Copyright 1999-2026. WebPros International GmbH.

## Support

For issues, questions, or contributions, contact your system administrator or open an issue in the repository.

---

**Production-Ready Status:** ✅ This version has been hardened for production use with comprehensive error handling, security fixes, and performance optimizations.
