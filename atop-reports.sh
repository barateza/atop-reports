#!/bin/bash
### Copyright 1999-2026. WebPros International GmbH.
###############################################################################
# This script monitors system resources and generates detailed reports of top
# resource offenders when thresholds are exceeded. It captures CPU, Memory, and
# Disk I/O metrics over 15-second windows, identifies problematic processes and
# websites, and provides ranked analysis to help system administrators diagnose
# performance issues on Plesk servers.
#
# Requirements : bash 3.x, atop >= 2.3.0, GNU coreutils, Linux kernel with
#                process accounting (CONFIG_TASK_IO_ACCOUNTING), root access
#                recommended for full disk I/O metrics
# Version      : 2.0.0
#########

#==============================================================================
# CLI ARGUMENT PARSING
#==============================================================================

REPLAY_FILE=""
OUTPUT_FORMAT="text"  # text or json
VERBOSE_MODE=0  # Show container IDs in text output

while [[ $# -gt 0 ]]; do
    case $1 in
        --file)
            REPLAY_FILE="$2"
            shift 2
            ;;
        --json)
            OUTPUT_FORMAT="json"
            shift
            ;;
        --verbose|-v)
            VERBOSE_MODE=1
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --file <snapshot>   Replay/analyze existing atop snapshot file"
            echo "  --json              Output in JSON format instead of text"
            echo "  --verbose, -v       Show container IDs in text output"
            echo "  --help              Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

#==============================================================================
# GLOBAL CLEANUP TRACKING
#==============================================================================

CLEANUP_DIRS=()
CLEANUP_FILES=()
ATOP_PID=""
LOCK_FD=""

#==============================================================================
# CONFIGURATION - Customer Editable
#==============================================================================

# Load Average Threshold: Trigger when load exceeds this value
# Recommended: Set to number of CPU cores (e.g., 4.0 for 4-core system)
LOAD_THRESHOLD=4.0

# Memory Usage Threshold: Trigger when memory usage exceeds this percentage
# Recommended: 80 for production servers, 90 for development
MEM_THRESHOLD=80

# I/O Wait Threshold: Trigger when CPU I/O wait exceeds this percentage
# Recommended: 25 means 25% of CPU time spent waiting for disk I/O
IO_WAIT_THRESHOLD=25

# Check Interval: Seconds between metric checks when system is normal
CHECK_INTERVAL=10

# Cooldown Period: Seconds to wait after an alert before next check
# This prevents alert spam during sustained high load
COOLDOWN=300

# Log File: Path where alerts and reports will be written
LOG_FILE="/var/log/atop-resource-alerts.log"

# Minimum Resource Threshold: Only show processes using more than this percentage
# of any single resource (CPU, Memory, or Disk)
MIN_OFFENDER_THRESHOLD=10

# Override defaults with config file if present (Hybrid Configuration)
if [ -f /etc/atop-reports.conf ]; then
    # shellcheck source=/dev/null
    source /etc/atop-reports.conf
fi

#==============================================================================
# INITIALIZATION - Do Not Edit Below This Line
#==============================================================================

# Validate configuration values
validate_config() {
    local errors=0
    
    # Validate numeric and positive values
    if ! [[ $LOAD_THRESHOLD =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$(echo "$LOAD_THRESHOLD <= 0" | bc)" -eq 1 ] 2>/dev/null; then
        echo "ERROR: LOAD_THRESHOLD must be a positive number (current: $LOAD_THRESHOLD)" >&2
        errors=$((errors + 1))
    fi
    
    if ! [[ $MEM_THRESHOLD =~ ^[0-9]+$ ]] || [ "$MEM_THRESHOLD" -lt 0 ] || [ "$MEM_THRESHOLD" -gt 100 ]; then
        echo "ERROR: MEM_THRESHOLD must be between 0-100 (current: $MEM_THRESHOLD)" >&2
        errors=$((errors + 1))
    fi
    
    if ! [[ $IO_WAIT_THRESHOLD =~ ^[0-9]+$ ]] || [ "$IO_WAIT_THRESHOLD" -lt 0 ] || [ "$IO_WAIT_THRESHOLD" -gt 100 ]; then
        echo "ERROR: IO_WAIT_THRESHOLD must be between 0-100 (current: $IO_WAIT_THRESHOLD)" >&2
        errors=$((errors + 1))
    fi
    
    if ! [[ $CHECK_INTERVAL =~ ^[0-9]+$ ]] || [ "$CHECK_INTERVAL" -le 0 ]; then
        echo "ERROR: CHECK_INTERVAL must be a positive integer (current: $CHECK_INTERVAL)" >&2
        errors=$((errors + 1))
    fi
    
    if ! [[ $COOLDOWN =~ ^[0-9]+$ ]] || [ "$COOLDOWN" -le 0 ]; then
        echo "ERROR: COOLDOWN must be a positive integer (current: $COOLDOWN)" >&2
        errors=$((errors + 1))
    fi
    
    if ! [[ $MIN_OFFENDER_THRESHOLD =~ ^[0-9]+$ ]] || [ "$MIN_OFFENDER_THRESHOLD" -lt 0 ] || [ "$MIN_OFFENDER_THRESHOLD" -gt 100 ]; then
        echo "ERROR: MIN_OFFENDER_THRESHOLD must be between 0-100 (current: $MIN_OFFENDER_THRESHOLD)" >&2
        errors=$((errors + 1))
    fi
    
    # Check disk space in log directory (require 100MB free)
    local log_dir
    log_dir=$(dirname "$LOG_FILE")
    if [ -d "$log_dir" ]; then
        local available_kb
        available_kb=$(df -k "$log_dir" | awk 'NR==2 {print $4}')
        if [ -n "$available_kb" ] && [ "$available_kb" -lt 102400 ]; then
            echo "WARNING: Less than 100MB free in log directory: $log_dir" >&2
            echo "Available: $((available_kb / 1024))MB" >&2
        fi
    fi
    
    if [ $errors -gt 0 ]; then
        echo "Configuration validation failed with $errors error(s)" >&2
        exit 1
    fi
}

validate_config

# Auto-detect system clock ticks per second (needed for CPU calculations)
# Default to 100 if getconf fails (prevents zero-division in AWK)
CLK_TCK=$(getconf CLK_TCK 2>/dev/null)
if [ -z "$CLK_TCK" ] || [ "$CLK_TCK" -eq 0 ] 2>/dev/null; then
    CLK_TCK=100
fi

# Validate system requirements
if [ ! -d /proc ] || [ ! -f /proc/meminfo ]; then
    echo "ERROR: /proc filesystem not available" >&2
    exit 1
fi

# Check required commands
for cmd in atop awk sort mktemp flock; do
    if ! command -v $cmd >/dev/null 2>&1; then
        echo "ERROR: Required command '$cmd' not found in PATH" >&2
        exit 1
    fi
done

# Setup lock file to prevent multiple instances
if [ -d "/run/lock" ]; then
    LOCK_DIR="/run/lock"
elif [ -d "/var/lock" ]; then
    LOCK_DIR="/var/lock"
else
    LOCK_DIR="/tmp"
fi

LOCK_FILE="${LOCK_DIR}/atop-reports.lock"

# Acquire exclusive lock (non-blocking)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "ERROR: Another instance of this script is already running" >&2
    echo "Lock file: $LOCK_FILE" >&2
    exit 1
fi
LOCK_FD=200

# Check for root privileges
LIMITED_MODE=0
if [ "$(id -u)" -ne 0 ]; then
    echo "   WARNING: Running as non-root user." >&2
    echo "   Per-process Disk I/O metrics will be unavailable." >&2
    echo "   Please run with 'sudo' or as 'root' for full system visibility." >&2
    echo "   Starting in limited mode..." >&2
    sleep 2
    LIMITED_MODE=1
fi

# Cleanup function for trap handler
cleanup() {
    local exit_code=$?
    
    # Kill child atop process if running
    if [ -n "$ATOP_PID" ] && kill -0 "$ATOP_PID" 2>/dev/null; then
        kill -TERM "$ATOP_PID" 2>/dev/null
        wait "$ATOP_PID" 2>/dev/null
    fi
    
    # Remove temporary files
    for file in "${CLEANUP_FILES[@]}"; do
        [ -f "$file" ] && rm -f "$file"
    done
    
    # Remove temporary directories
    for dir in "${CLEANUP_DIRS[@]}"; do
        [ -d "$dir" ] && rm -rf "$dir"
    done
    
    # Release lock
    if [ -n "$LOCK_FD" ]; then
        flock -u "$LOCK_FD" 2>/dev/null
    fi
    
    # Log shutdown if in monitoring mode
    if [ -z "$REPLAY_FILE" ] && [ -w "$LOG_FILE" ]; then
        echo "ATOP Resource Monitor stopped at $(date)" >> "$LOG_FILE" 2>/dev/null
    fi
    
    exit $exit_code
}

# Register trap handlers
trap cleanup EXIT TERM INT HUP

# Validate atop is installed
if ! command -v atop >/dev/null 2>&1; then
    echo "ERROR: atop is not installed or not in PATH." >&2
    echo "Install with: yum install atop (RHEL/AlmaLinux/Rocky) or apt install atop (Ubuntu/Debian)" >&2
    exit 1
fi

# Check atop version (require >= 2.3.0) - using awk instead of grep -oP for portability
ATOP_VERSION=$(atop -V 2>&1 | awk '/Version/ {for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+$/) {print $i; exit}}')
if [ -z "$ATOP_VERSION" ]; then
    echo "WARNING: Could not detect atop version. Proceeding anyway..." >&2
fi

# Version-based fallback maps for field positions (used when dynamic detection fails)
# These maps define stable field positions for major atop versions
# Format: PRG_PID=7 means PID is at field index 7 in PRG label lines
FIELD_MAP_V23="PRG_PID=7 PRG_CMD=8 PRC_PID=7 PRC_USER=11 PRC_SYS=12 PRM_PID=7 PRM_RSS=11 PRD_PID=7 PRD_SECTORS_READ=12 PRD_SECTORS_WRITE=14 DSK_SECTORS_READ=9 DSK_SECTORS_WRITE=11"
FIELD_MAP_V24="PRG_PID=7 PRG_CMD=8 PRC_PID=7 PRC_USER=11 PRC_SYS=12 PRM_PID=7 PRM_RSS=11 PRD_PID=7 PRD_SECTORS_READ=12 PRD_SECTORS_WRITE=14 DSK_SECTORS_READ=9 DSK_SECTORS_WRITE=11"
FIELD_MAP_V27="PRG_PID=7 PRG_CMD=8 PRG_CID=17 PRC_PID=7 PRC_USER=11 PRC_SYS=12 PRM_PID=7 PRM_RSS=11 PRD_PID=7 PRD_SECTORS_READ=12 PRD_SECTORS_WRITE=14 DSK_SECTORS_READ=9 DSK_SECTORS_WRITE=11"

# Select appropriate field map based on detected version
FIELD_MAP="$FIELD_MAP_V23"  # Default to oldest supported version
if [ -n "$ATOP_VERSION" ]; then
    VERSION_MAJOR=$(echo "$ATOP_VERSION" | cut -d. -f1)
    VERSION_MINOR=$(echo "$ATOP_VERSION" | cut -d. -f2)
    
    if [ "$VERSION_MAJOR" -eq 2 ]; then
        if [ "$VERSION_MINOR" -ge 7 ]; then
            FIELD_MAP="$FIELD_MAP_V27"
        elif [ "$VERSION_MINOR" -ge 4 ]; then
            FIELD_MAP="$FIELD_MAP_V24"
        fi
    elif [ "$VERSION_MAJOR" -gt 2 ]; then
        FIELD_MAP="$FIELD_MAP_V27"  # Assume future versions follow v2.7+ structure
    fi
fi

# Test log file writeability
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to log file: $LOG_FILE" >&2
    echo "Check permissions or change LOG_FILE path in configuration." >&2
    exit 1
fi

# Get total system memory in KB for percentage calculations
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

# Handle replay mode (--file flag)
if [ -n "$REPLAY_FILE" ]; then
    if [ ! -f "$REPLAY_FILE" ]; then
        echo "ERROR: Snapshot file not found: $REPLAY_FILE" >&2
        exit 1
    fi
    
    if [ ! -s "$REPLAY_FILE" ]; then
        echo "ERROR: Snapshot file is empty: $REPLAY_FILE" >&2
        exit 1
    fi
    
    # Replay mode: parse the file and exit
    echo "Replay mode: Analyzing snapshot file $REPLAY_FILE" >&2
    TIMESTAMP_START=$(date "+%Y-%m-%d %H:%M:%S")
    TIMESTAMP_END="$TIMESTAMP_START"
    REASON="replay"
    
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        parse_atop_output "$REPLAY_FILE" "$TIMESTAMP_START" "$TIMESTAMP_END" "/dev/null"
    else
        parse_atop_output "$REPLAY_FILE" "$TIMESTAMP_START" "$TIMESTAMP_END" "/dev/stdout"
    fi
    
    exit 0
fi

# Normal monitoring mode initialization
echo "ATOP Resource Monitor started at $(date)" >> "$LOG_FILE"
echo "Configuration: Load=${LOAD_THRESHOLD}, Memory=${MEM_THRESHOLD}%, I/O Wait=${IO_WAIT_THRESHOLD}%" >> "$LOG_FILE"
if [ "$LIMITED_MODE" -eq 1 ]; then
    echo "Mode: LIMITED (non-root - per-process disk I/O unavailable)" >> "$LOG_FILE"
else
    echo "Mode: FULL (root access - all metrics available)" >> "$LOG_FILE"
fi
echo "================================================================================" >> "$LOG_FILE"

#==============================================================================
# HELPER FUNCTIONS
#==============================================================================

# Parse atop structured output and generate report
parse_atop_output() {
    local snapshot_file="$1"
    local start_time="$2"
    local end_time="$3"
    local report_file="$4"
    
    # Check if snapshot file exists and has content
    if [ ! -s "$snapshot_file" ]; then
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            printf '{"meta":{"schema_version":"1.0","error":"Snapshot file is empty or missing"}}\n'
        else
            echo "ERROR: Snapshot file is empty or missing" >> "$report_file"
        fi
        return 1
    fi
    
    # Temporary files for processing (secure with mktemp)
    local temp_dir
    temp_dir=$(mktemp -d -t atop-parse.XXXXXX)
    chmod 700 "$temp_dir"
    CLEANUP_DIRS+=("$temp_dir")
    
    # Parse structured output with awk - version-agnostic dynamic header detection
    awk -v clk_tck="$CLK_TCK" -v total_mem="$TOTAL_MEM_KB" -v limited="$LIMITED_MODE" \
        -v min_thresh="$MIN_OFFENDER_THRESHOLD" -v temp_dir="$temp_dir" \
        -v field_map="$FIELD_MAP" -v is_tty="$( [ -t 1 ] && echo 1 || echo 0 )" '
    BEGIN {
        sample_count = 0
        max_disk_read = 0
        max_disk_write = 0
        system_disk_read = 0
        system_disk_write = 0
        header_detected = 0
        fallback_used = 0
        
        # Parse fallback field map into associative array
        n = split(field_map, pairs, " ")
        for (i = 1; i <= n; i++) {
            split(pairs[i], kv, "=")
            fallback_map[kv[1]] = kv[2]
        }
    }
    
    # Dynamic Column Mapping: Parse header lines to learn field positions
    # Header lines contain field names (e.g., "PRG host epoch date time interval pid ppid ...")
    # Data lines contain only values
    $1 ~ /^(PRG|PRC|PRM|PRD|DSK)$/ && NF > 10 && $7 !~ /^[0-9]+$/ {
        # This is a header line (field 7 is not numeric)
        type = $1
        for (i = 1; i <= NF; i++) {
            # Store field position by name
            col_map[type, toupper($i)] = i
        }
        header_detected = 1
        next
    }
    
    # Track samples
    /^SEP/ {
        sample_count++
        next
    }
    
    # Parse PRG (General process info)
    # Fields: PID (stable v2.3.0+), Command Name (stable v2.3.0+), CID (v2.7.1+ only)
    /^PRG/ && $7 ~ /^[0-9]+$/ {
        # Get field positions (dynamic or fallback)
        if ((type, "PID") in col_map) {
            pid_col = col_map["PRG", "PID"]
            cmd_col = col_map["PRG", "NAME"]
            if (!cmd_col) cmd_col = col_map["PRG", "CMD"]
            if (!cmd_col) cmd_col = col_map["PRG", "COMMAND"]
            cid_col = col_map["PRG", "CID"]
            if (!cid_col) cid_col = col_map["PRG", "CONTAINER"]
        } else {
            # Fallback to version-based map
            if (!fallback_used && is_tty == 1) {
                print "⚠️  Dynamic header detection failed, using legacy field map" > "/dev/stderr"
                fallback_used = 1
            }
            pid_col = fallback_map["PRG_PID"]
            cmd_col = fallback_map["PRG_CMD"]
            cid_col = fallback_map["PRG_CID"]
            if (!pid_col) pid_col = 7  # Ultimate fallback
            if (!cmd_col) cmd_col = 8
        }
        
        pid = $(pid_col)
        cmd_name = $(cmd_col)
        container_id = (cid_col && cid_col <= NF) ? $(cid_col) : ""
        
        # Store command name and container ID for this PID
        prg_cmd[pid] = cmd_name
        if (container_id != "" && container_id != "-") {
            prg_cid[pid] = container_id
        }
        next
    }
    
    # Parse PRC (CPU metrics)
    # Fields: PID (stable), User Ticks (stable), System Ticks (stable)
    /^PRC/ && $7 ~ /^[0-9]+$/ {
        if (("PRC", "PID") in col_map) {
            pid_col = col_map["PRC", "PID"]
            user_col = col_map["PRC", "UTIME"]
            if (!user_col) user_col = col_map["PRC", "USR"]
            sys_col = col_map["PRC", "STIME"]
            if (!sys_col) sys_col = col_map["PRC", "SYS"]
        } else {
            pid_col = fallback_map["PRC_PID"]
            user_col = fallback_map["PRC_USER"]
            sys_col = fallback_map["PRC_SYS"]
            if (!pid_col) pid_col = 7
            if (!user_col) user_col = 11
            if (!sys_col) sys_col = 12
        }
        
        pid = $(pid_col)
        user_ticks = $(user_col)
        sys_ticks = $(sys_col)
        total_ticks = user_ticks + sys_ticks
        
        # Accumulate for average
        prc_cpu_sum[pid] += total_ticks
        prc_cpu_samples[pid]++
        
        # Track peak
        if (total_ticks > prc_cpu_peak[pid]) {
            prc_cpu_peak[pid] = total_ticks
        }
        next
    }
    
    # Parse PRM (Memory metrics)
    # Fields: PID (stable), RSS Memory (stable)
    /^PRM/ && $7 ~ /^[0-9]+$/ {
        if (("PRM", "PID") in col_map) {
            pid_col = col_map["PRM", "PID"]
            rss_col = col_map["PRM", "RMEM"]
            if (!rss_col) rss_col = col_map["PRM", "RSS"]
        } else {
            pid_col = fallback_map["PRM_PID"]
            rss_col = fallback_map["PRM_RSS"]
            if (!pid_col) pid_col = 7
            if (!rss_col) rss_col = 11
        }
        
        pid = $(pid_col)
        res_mem_kb = $(rss_col)
        
        # Accumulate for average
        prm_mem_sum[pid] += res_mem_kb
        prm_mem_samples[pid]++
        
        # Track peak
        if (res_mem_kb > prm_mem_peak[pid]) {
            prm_mem_peak[pid] = res_mem_kb
        }
        next
    }
    
    # Parse PRD (Disk I/O metrics) - only if not in limited mode
    # Fields: PID (stable), Sectors Read (stable), Sectors Write (stable)
    /^PRD/ && $7 ~ /^[0-9]+$/ {
        if (limited == 1) next
        
        if (("PRD", "PID") in col_map) {
            pid_col = col_map["PRD", "PID"]
            read_col = col_map["PRD", "RDDSK"]
            if (!read_col) read_col = col_map["PRD", "READ"]
            write_col = col_map["PRD", "WRDSK"]
            if (!write_col) write_col = col_map["PRD", "WRITE"]
        } else {
            pid_col = fallback_map["PRD_PID"]
            read_col = fallback_map["PRD_SECTORS_READ"]
            write_col = fallback_map["PRD_SECTORS_WRITE"]
            if (!pid_col) pid_col = 7
            if (!read_col) read_col = 12
            if (!write_col) write_col = 14
        }
        
        pid = $(pid_col)
        sectors_read = $(read_col)
        sectors_write = $(write_col)
        
        # Convert sectors to KB (512 bytes per sector)
        kb_read = sectors_read * 0.5
        kb_write = sectors_write * 0.5
        
        # Accumulate for average
        prd_read_sum[pid] += kb_read
        prd_write_sum[pid] += kb_write
        prd_samples[pid]++
        
        # Track peak
        if (kb_read > prd_read_peak[pid]) {
            prd_read_peak[pid] = kb_read
        }
        if (kb_write > prd_write_peak[pid]) {
            prd_write_peak[pid] = kb_write
        }
        
        # Track max for percentile calculation
        if (kb_read > max_disk_read) max_disk_read = kb_read
        if (kb_write > max_disk_write) max_disk_write = kb_write
        
        next
    }
    
    # Parse DSK (System-level disk metrics)
    # Fields: Sectors Read (stable v2.3.0+), Sectors Write (stable v2.3.0+)
    /^DSK/ && $7 !~ /^[0-9]+$/ {
        if (("DSK", "READ") in col_map) {
            read_col = col_map["DSK", "READ"]
            if (!read_col) read_col = col_map["DSK", "RDDSK"]
            write_col = col_map["DSK", "WRITE"]
            if (!write_col) write_col = col_map["DSK", "WRDSK"]
        } else {
            read_col = fallback_map["DSK_SECTORS_READ"]
            write_col = fallback_map["DSK_SECTORS_WRITE"]
            if (!read_col) read_col = 9
            if (!write_col) write_col = 11
        }
        
        sectors_read = $(read_col)
        sectors_write = $(write_col)
        
        # Convert sectors to MB
        mb_read = (sectors_read * 0.5) / 1024
        mb_write = (sectors_write * 0.5) / 1024
        
        system_disk_read += mb_read
        system_disk_write += mb_write
        next
    }
    
    END {
        # Aggregate by process name
        for (pid in prg_cmd) {
            cmd = prg_cmd[pid]
            
            # CPU metrics
            if (prc_cpu_samples[pid] > 0) {
                agg_cpu_sum[cmd] += prc_cpu_sum[pid]
                agg_cpu_peak[cmd] += prc_cpu_peak[pid]
                agg_cpu_samples[cmd] = prc_cpu_samples[pid]
            }
            
            # Memory metrics
            if (prm_mem_samples[pid] > 0) {
                agg_mem_sum[cmd] += prm_mem_sum[pid]
                agg_mem_peak[cmd] += prm_mem_peak[pid]
            }
            
            # Disk metrics
            if (prd_samples[pid] > 0) {
                agg_disk_read_sum[cmd] += prd_read_sum[pid]
                agg_disk_write_sum[cmd] += prd_write_sum[pid]
                agg_disk_read_peak[cmd] += prd_read_peak[pid]
                agg_disk_write_peak[cmd] += prd_write_peak[pid]
                agg_disk_avail[cmd] = 1
            }
            
            # Store PIDs and Container IDs for this command
            if (agg_pids[cmd] == "") {
                agg_pids[cmd] = pid
            }
            # Track container ID (use first non-empty CID found)
            if (prg_cid[pid] != "" && agg_cid[cmd] == "") {
                agg_cid[cmd] = prg_cid[pid]
            }
        }
        
        # Calculate scores and filter
        for (cmd in agg_cpu_sum) {
            # Calculate average CPU %
            if (agg_cpu_samples[cmd] > 0) {
                avg_cpu_ticks = agg_cpu_sum[cmd] / agg_cpu_samples[cmd]
                avg_cpu_pct = (avg_cpu_ticks / clk_tck) * 100
                peak_cpu_pct = (agg_cpu_peak[cmd] / clk_tck) * 100
            } else {
                avg_cpu_pct = 0
                peak_cpu_pct = 0
            }
            
            # Calculate average Memory %
            avg_mem_kb = agg_mem_sum[cmd] / sample_count
            peak_mem_kb = agg_mem_peak[cmd]
            avg_mem_gb = avg_mem_kb / 1024 / 1024
            peak_mem_gb = peak_mem_kb / 1024 / 1024
            avg_mem_pct = (avg_mem_kb / total_mem) * 100
            peak_mem_pct = (peak_mem_kb / total_mem) * 100
            
            # Calculate disk I/O (MB/s) and percentile
            disk_available = 0
            if (agg_disk_avail[cmd] == 1 && limited == 0) {
                disk_available = 1
                avg_disk_read_kb = agg_disk_read_sum[cmd] / sample_count
                avg_disk_write_kb = agg_disk_write_sum[cmd] / sample_count
                peak_disk_read_kb = agg_disk_read_peak[cmd]
                peak_disk_write_kb = agg_disk_write_peak[cmd]
                
                # Convert to MB/s
                avg_disk_read_mbs = avg_disk_read_kb / 1024
                avg_disk_write_mbs = avg_disk_write_kb / 1024
                peak_disk_read_mbs = peak_disk_read_kb / 1024
                peak_disk_write_mbs = peak_disk_write_kb / 1024
                
                avg_disk_total_mbs = avg_disk_read_mbs + avg_disk_write_mbs
                peak_disk_total_mbs = peak_disk_read_mbs + peak_disk_write_mbs
                
                # Calculate percentile (max disk = 100%)
                if (max_disk_read + max_disk_write > 0) {
                    max_disk_total = (max_disk_read + max_disk_write) / 1024
                    avg_disk_pct = (avg_disk_total_mbs / max_disk_total) * 100
                    peak_disk_pct = (peak_disk_total_mbs / max_disk_total) * 100
                } else {
                    avg_disk_pct = 0
                    peak_disk_pct = 0
                }
            }
            
            # Filter: only include if peak of any metric > threshold
            if (peak_cpu_pct < min_thresh && peak_mem_pct < min_thresh && peak_disk_pct < min_thresh) {
                continue
            }
            
            # Calculate scores
            if (disk_available == 1) {
                avg_score = (avg_cpu_pct + avg_mem_pct + avg_disk_pct) / 3
                peak_score = (peak_cpu_pct + peak_mem_pct + peak_disk_pct) / 3
                score_suffix = ""
            } else {
                avg_score = (avg_cpu_pct + avg_mem_pct) / 2
                peak_score = (peak_cpu_pct + peak_mem_pct) / 2
                score_suffix = "*"
            }
            
            combined_score = (avg_score + peak_score) / 2
            
            # Get container ID (null-safe)
            cid = (agg_cid[cmd] != "") ? agg_cid[cmd] : "null"
            
            # Output for sorting (added CID field)
            printf "%s|%s|%.1f|%.1f|%.2f|%.1f|%.2f|%.1f|%d|%.1f|%.2f|%.1f|%s|%s\n", \
                cmd, cid, avg_cpu_pct, avg_mem_gb, avg_mem_pct, avg_disk_total_mbs, avg_disk_pct, \
                peak_cpu_pct, peak_mem_gb, peak_mem_pct, peak_disk_total_mbs, peak_disk_pct, \
                score_suffix, combined_score > temp_dir"/scores.txt"
        }
        
        # Output system disk metrics
        if (sample_count > 0) {
            avg_sys_disk_read = system_disk_read / sample_count
            avg_sys_disk_write = system_disk_write / sample_count
            printf "%.1f|%.1f\n", avg_sys_disk_read, avg_sys_disk_write > temp_dir"/system_disk.txt"
        }
    }
    ' "$snapshot_file"
    
    # Check if parsing produced results
    if [ ! -f "$temp_dir/scores.txt" ] || [ ! -s "$temp_dir/scores.txt" ]; then
        if [ "$OUTPUT_FORMAT" = "json" ]; then
            printf '{"meta":{"schema_version":"2.0","timestamp":"%s","hostname":"%s","mode":"%s"},"data":{"message":"No significant resource offenders detected"}}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$([ "$LIMITED_MODE" -eq 1 ] && echo limited || echo full)"
        else
            echo "No significant resource offenders detected (all processes below ${MIN_OFFENDER_THRESHOLD}% threshold)" >> "$report_file"
        fi
        return 0
    fi
    
    # Sort by combined score and get top 10 (note: CID is now field 2, combined_score is field 14)
    sort -t'|' -k14 -rn "$temp_dir/scores.txt" | head -10 > "$temp_dir/top10.txt"
    
    # Output format: JSON or text
    if [ "$OUTPUT_FORMAT" = "json" ]; then
        # Generate JSON output with metadata envelope (schema version 2.0)
        printf '{"meta":{"schema_version":"2.0","timestamp":"%s","hostname":"%s","mode":"%s","start_time":"%s","end_time":"%s","duration_seconds":15},"data":{"trigger_reason":"%s","processes":[' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(hostname)" "$([ "$LIMITED_MODE" -eq 1 ] && echo limited || echo full)" \
            "$start_time" "$end_time" "${REASON:-manual}"
        
        local first=1
        while IFS='|' read -r cmd cid avg_cpu avg_mem_gb avg_mem_pct avg_disk avg_disk_pct \
            peak_cpu peak_mem_gb peak_mem_pct peak_disk peak_disk_pct suffix combined_score; do
            
            [ $first -eq 0 ] && printf ','
            first=0
            
            # Format container_id (null-safe - always present)
            local cid_json
            if [ "$cid" = "null" ] || [ -z "$cid" ]; then
                cid_json="null"
            else
                cid_json="\"$cid\""
            fi
            
            # Format disk values (null if N/A)
            local avg_disk_json peak_disk_json avg_disk_pct_json peak_disk_pct_json
            if [ "$LIMITED_MODE" -eq 1 ] || [ "$suffix" = "*" ]; then
                avg_disk_json="null"
                peak_disk_json="null"
                avg_disk_pct_json="null"
                peak_disk_pct_json="null"
            else
                avg_disk_json="$avg_disk"
                peak_disk_json="$peak_disk"
                avg_disk_pct_json="$avg_disk_pct"
                peak_disk_pct_json="$peak_disk_pct"
            fi
            
            printf '{"process":"%s","container_id":%s,"avg":{"cpu_percent":%.1f,"memory_gb":%.2f,"memory_percent":%.1f,"disk_mbs":%s,"disk_percent":%s},"peak":{"cpu_percent":%.1f,"memory_gb":%.2f,"memory_percent":%.1f,"disk_mbs":%s,"disk_percent":%s},"score":%.1f}' \
                "$cmd" "$cid_json" "$avg_cpu" "$avg_mem_gb" "$avg_mem_pct" "$avg_disk_json" "$avg_disk_pct_json" \
                "$peak_cpu" "$peak_mem_gb" "$peak_mem_pct" "$peak_disk_json" "$peak_disk_pct_json" \
                "$combined_score"
        done < "$temp_dir/top10.txt"
        
        # Add system disk metrics if available
        if [ -f "$temp_dir/system_disk.txt" ]; then
            read -r sys_read sys_write < "$temp_dir/system_disk.txt"
            printf '],"system_disk":{"read_mbs":%.1f,"write_mbs":%.1f}}}' "$sys_read" "$sys_write"
        else
            printf '],"system_disk":null}}'
        fi
        printf '\n'
    else
        # Generate text report
        {
            echo ""
            echo "TOP RESOURCE OFFENDERS (Monitored: ${start_time} - ${end_time}, 15 seconds):"
            echo "================================================================================"
        } >> "$report_file"
        
        local rank=1
        local has_partial=0
        
        while IFS='|' read -r cmd cid avg_cpu avg_mem_gb avg_mem_pct avg_disk avg_disk_pct \
            peak_cpu peak_mem_gb peak_mem_pct peak_disk peak_disk_pct suffix combined_score; do
            
            # Get parent/pool information
            local parent_info=""
            local sample_pid
            sample_pid=$(awk -v cmd="$cmd" '$1 == "PRG" && $8 == cmd {print $7; exit}' "$snapshot_file")
            
            if [ -n "$sample_pid" ] && [ -d "/proc/$sample_pid" ]; then
                parent_info=$(get_parent_info "$sample_pid" "$cid")
            fi
            
            # Format disk display
            local avg_disk_display peak_disk_display
            if [ "$LIMITED_MODE" -eq 1 ] || [ -z "$suffix" ]; then
                avg_disk_display="N/A"
                peak_disk_display="N/A"
            else
                if [ "$suffix" = "*" ]; then
                    avg_disk_display="N/A"
                    peak_disk_display="N/A"
                    has_partial=1
                else
                    avg_disk_display=$(printf "%.1f MB/s (%.0f%%)" "$avg_disk" "$avg_disk_pct")
                    peak_disk_display=$(printf "%.1f MB/s (%.0f%%)" "$peak_disk" "$peak_disk_pct")
                fi
            fi
            
            # Format output
            {
                printf "#%-2d %s%s\\n" "$rank" "$cmd" "$parent_info"
                printf "    AVG:  CPU %.1f%%, MEM %.2fGB (%.1f%%), DISK %s\\n" \
                    "$avg_cpu" "$avg_mem_gb" "$avg_mem_pct" "$avg_disk_display"
                printf "    PEAK: CPU %.1f%%, MEM %.2fGB (%.1f%%), DISK %s\\n" \
                    "$peak_cpu" "$peak_mem_gb" "$peak_mem_pct" "$peak_disk_display"
                printf "    Score: %.1f%s\\n" "$combined_score" "$suffix"
                echo ""
            } >> "$report_file"
            
            rank=$((rank + 1))
        done < "$temp_dir/top10.txt"
        
        # Add legend if partial scores exist
        if [ "$has_partial" -eq 1 ] || [ "$LIMITED_MODE" -eq 1 ]; then
            {
                echo "* Score excludes Disk I/O (requires root)"
                echo ""
            } >> "$report_file"
        fi
        
        # Add system-level disk metrics
        if [ -f "$temp_dir/system_disk.txt" ]; then
            read -r sys_read sys_write < "$temp_dir/system_disk.txt"
            {
                echo "================================================================================"
                echo "System-Level Disk I/O (Unattributed): ${sys_read} MB/s read, ${sys_write} MB/s write"
            } >> "$report_file"
        fi
    fi
}

# Get parent process information and extract pool/vhost details
get_parent_info() {
    local pid="$1"
    local cid="$2"  # Container ID (may be "null" or empty)
    local info_parts=""
    
    # Check if process still exists (race condition protection)
    if [ ! -d "/proc/$pid" ]; then
        return
    fi
    
    # Try to get command line
    if [ -f "/proc/$pid/cmdline" ]; then
        local cmdline
        cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        
        # Extract PHP-FPM pool
        local pool
        pool=$(echo "$cmdline" | awk -F'pool[= ]' 'NF>1 {print $2}' | awk '{print $1}')
        if [ -z "$pool" ]; then
            pool=$(echo "$cmdline" | awk -F'php-fpm: pool ' 'NF>1 {print $2}' | awk '{print $1}')
        fi
        
        # Extract Apache vhost
        local vhost
        vhost=$(echo "$cmdline" | awk '/-D.*VHOST/ {for(i=1;i<=NF;i++) if($i ~ /^-D.*VHOST/) print $i}' | head -1)
        if [ -z "$vhost" ]; then
            vhost=$(echo "$cmdline" | awk -F'-f ' 'NF>1 {print $2}' | awk '{match($0, /\/([^\/]+\.conf)/, a); print a[1]}')
        fi
        
        # Build info string
        if [ -n "$pool" ]; then
            info_parts="pool: $pool"
        fi
        if [ -n "$vhost" ]; then
            if [ -n "$info_parts" ]; then
                info_parts="$info_parts, vhost: $vhost"
            else
                info_parts="vhost: $vhost"
            fi
        fi
    fi
    
    # Add Container ID if verbose mode is enabled and CID is available
    if [ "$VERBOSE_MODE" -eq 1 ] && [ -n "$cid" ] && [ "$cid" != "null" ]; then
        if [ -n "$info_parts" ]; then
            info_parts="$info_parts, container: $cid"
        else
            info_parts="container: $cid"
        fi
    fi
    
    # Try to get parent process name
    if [ -f "/proc/$pid/status" ]; then
        local ppid
        ppid=$(grep '^PPid:' "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        if [ -n "$ppid" ] && [ "$ppid" -gt 1 ] && [ -f "/proc/$ppid/comm" ]; then
            local parent_name
            parent_name=$(cat "/proc/$ppid/comm" 2>/dev/null)
            if [ -n "$parent_name" ] && [ "$parent_name" != "systemd" ] && [ "$parent_name" != "init" ]; then
                if [ -n "$info_parts" ]; then
                    info_parts="$info_parts, parent: $parent_name"
                else
                    info_parts="parent: $parent_name"
                fi
            fi
        fi
    fi
    
    # Return formatted info
    if [ -n "$info_parts" ]; then
        echo " [$info_parts]"
    fi
}

#==============================================================================
# MAIN MONITORING LOOP
#==============================================================================

while true; do
    # 1. GET CURRENT METRICS
    
    # Get 1-min Load Average
    CURRENT_LOAD=$(awk '{print $1}' /proc/loadavg)
    
    # Get Memory Usage %
    if command -v free >/dev/null 2>&1; then
        MEM_USED_PERCENT=$(free | grep Mem | awk '{print ($3/$2) * 100.0}')
    else
        MEM_USED_PERCENT=0
    fi
    
    # Get CPU I/O Wait % by reading /proc/stat (non-blocking, 0.1s sampling)
    # Fields: user nice system idle iowait irq softirq
    if [ -f /proc/stat ]; then
        read -r cpu_line1 < <(grep '^cpu ' /proc/stat)
        sleep 0.1
        read -r cpu_line2 < <(grep '^cpu ' /proc/stat)
        
        # Parse both samples (skip 'cpu' label)
        # shellcheck disable=SC2086  # Intentional word splitting to parse /proc/stat fields
        set -- $cpu_line1
        user1=$2 nice1=$3 system1=$4 idle1=$5 iowait1=$6
        total1=$((user1 + nice1 + system1 + idle1 + iowait1))
        
        # shellcheck disable=SC2086  # Intentional word splitting to parse /proc/stat fields
        set -- $cpu_line2
        user2=$2 nice2=$3 system2=$4 idle2=$5 iowait2=$6
        total2=$((user2 + nice2 + system2 + idle2 + iowait2))
        
        # Calculate deltas
        iowait_delta=$((iowait2 - iowait1))
        total_delta=$((total2 - total1))
        
        # Calculate percentage
        if [ "$total_delta" -gt 0 ]; then
            CPU_WAIT=$((iowait_delta * 100 / total_delta))
        else
            CPU_WAIT=0
        fi
    else
        CPU_WAIT=0
    fi

    # Validate metrics are numeric and non-negative
    if ! [[ $CURRENT_LOAD =~ ^[0-9]+\.?[0-9]*$ ]]; then
        CURRENT_LOAD=0
    fi
    if ! [[ $MEM_USED_PERCENT =~ ^[0-9]+\.?[0-9]*$ ]] || [ "$(echo "$MEM_USED_PERCENT < 0" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
        MEM_USED_PERCENT=0
    fi
    if ! [[ $CPU_WAIT =~ ^[0-9]+$ ]] || [ "$CPU_WAIT" -lt 0 ]; then
        CPU_WAIT=0
    fi

    # Integer conversion for comparison
    LOAD_INT=${CURRENT_LOAD%.*}
    MEM_INT=${MEM_USED_PERCENT%.*}
    WAIT_INT=${CPU_WAIT}
    LOAD_THRESH_INT=${LOAD_THRESHOLD%.*}

    # 2. CHECK IF THRESHOLDS EXCEEDED
    TRIGGERED=0
    REASON=""

    if [ "$LOAD_INT" -ge "$LOAD_THRESH_INT" ]; then
        TRIGGERED=1
        REASON="HIGH LOAD ($CURRENT_LOAD)"
    elif [ "$MEM_INT" -ge "$MEM_THRESHOLD" ]; then
        TRIGGERED=1
        REASON="HIGH MEMORY (${MEM_INT}%)"
    elif [ "$WAIT_INT" -ge "$IO_WAIT_THRESHOLD" ]; then
        TRIGGERED=1
        REASON="HIGH I/O WAIT (${WAIT_INT}%)"
    fi

    # 3. CAPTURE SNAPSHOT IF TRIGGERED
    if [ "$TRIGGERED" -eq 1 ]; then
        TIMESTAMP_START=$(date "+%Y-%m-%d %H:%M:%S")
        SNAPSHOT_FILE=$(mktemp -t atop-snapshot.XXXXXX)
        chmod 600 "$SNAPSHOT_FILE"
        CLEANUP_FILES+=("$SNAPSHOT_FILE")
        
        # Check file size warning for memory usage
        if [ -f "$SNAPSHOT_FILE" ] && [ "$(stat -f%z "$SNAPSHOT_FILE" 2>/dev/null || stat -c%s "$SNAPSHOT_FILE" 2>/dev/null || echo 0)" -gt 104857600 ]; then
            echo "WARNING: Large snapshot file (>100MB). Processing may consume significant RAM." >&2
        fi
        
        # Capture 15-second atop snapshot with structured output
        atop -P PRG,PRC,PRM,PRD,DSK 1 15 > "$SNAPSHOT_FILE" 2>&1 &
        ATOP_PID=$!
        wait $ATOP_PID
        ATOP_EXIT=$?
        ATOP_PID=""
        
        TIMESTAMP_END=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Check if atop succeeded
        if [ $ATOP_EXIT -ne 0 ] || [ ! -s "$SNAPSHOT_FILE" ]; then
            {
                echo ""
                echo "##############################################################################"
                if [ "$LIMITED_MODE" -eq 1 ]; then
                    echo " ALERT TRIGGERED (Mode: Limited): $TIMESTAMP_START | REASON: $REASON"
                else
                    echo " ALERT TRIGGERED: $TIMESTAMP_START | REASON: $REASON"
                fi
                echo "##############################################################################"
                echo "ERROR: atop failed to capture metrics (exit code: $ATOP_EXIT)"
                echo "------------------------------------------------------------------------------"
            } >> "$LOG_FILE"
        else
            # Parse atop output and generate report
            {
                echo ""
                echo "##############################################################################"
                if [ "$LIMITED_MODE" -eq 1 ]; then
                    echo " ALERT TRIGGERED (Mode: Limited): $TIMESTAMP_START | REASON: $REASON"
                else
                    echo " ALERT TRIGGERED: $TIMESTAMP_START | REASON: $REASON"
                fi
                echo "##############################################################################"
            } >> "$LOG_FILE"
            
            parse_atop_output "$SNAPSHOT_FILE" "$TIMESTAMP_START" "$TIMESTAMP_END" "$LOG_FILE"
            
            echo "------------------------------------------------------------------------------" >> "$LOG_FILE"
        fi
        
        sleep "$COOLDOWN"
    else
        sleep "$CHECK_INTERVAL"
    fi
done