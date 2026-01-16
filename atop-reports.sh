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
# Version      : 1.0
#########

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

#==============================================================================
# INITIALIZATION - Do Not Edit Below This Line
#==============================================================================

# Auto-detect system clock ticks per second (needed for CPU calculations)
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)

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

# Validate atop is installed
if ! command -v atop >/dev/null 2>&1; then
    echo "ERROR: atop is not installed or not in PATH." >&2
    echo "Install with: yum install atop (RHEL/AlmaLinux/Rocky) or apt install atop (Ubuntu/Debian)" >&2
    exit 1
fi

# Check atop version (require >= 2.3.0)
ATOP_VERSION=$(atop -V 2>&1 | grep -oP 'Version \K[0-9.]+' | head -n1)
if [ -z "$ATOP_VERSION" ]; then
    echo "WARNING: Could not detect atop version. Proceeding anyway..." >&2
fi

# Test log file writeability
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "ERROR: Cannot write to log file: $LOG_FILE" >&2
    echo "Check permissions or change LOG_FILE path in configuration." >&2
    exit 1
fi

# Get total system memory in KB for percentage calculations
TOTAL_MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')

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
        echo "ERROR: Snapshot file is empty or missing" >> "$report_file"
        return 1
    fi
    
    # Temporary files for processing
    local temp_dir="/tmp/atop-parse-$$"
    mkdir -p "$temp_dir"
    
    # Parse structured output with awk
    awk -v clk_tck="$CLK_TCK" -v total_mem="$TOTAL_MEM_KB" -v limited="$LIMITED_MODE" \
        -v min_thresh="$MIN_OFFENDER_THRESHOLD" -v temp_dir="$temp_dir" '
    BEGIN {
        sample_count = 0
        max_disk_read = 0
        max_disk_write = 0
        system_disk_read = 0
        system_disk_write = 0
    }
    
    # Track samples
    /^SEP/ {
        sample_count++
        next
    }
    
    # Parse PRG (General process info)
    /^PRG/ {
        pid = $7
        cmd_name = $8
        # Store command name for this PID
        prg_cmd[pid] = cmd_name
        next
    }
    
    # Parse PRC (CPU metrics)
    /^PRC/ {
        pid = $7
        user_ticks = $11
        sys_ticks = $12
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
    /^PRM/ {
        pid = $7
        res_mem_kb = $11
        
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
    /^PRD/ {
        if (limited == 1) next
        
        pid = $7
        sectors_read = $12
        sectors_write = $14
        
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
    /^DSK/ {
        # Fields: label host epoch date time interval diskname reads sectors_read writes sectors_write ...
        sectors_read = $9
        sectors_write = $11
        
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
            
            # Store PIDs for this command (for parent resolution)
            if (agg_pids[cmd] == "") {
                agg_pids[cmd] = pid
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
            
            # Output for sorting
            printf "%s|%.1f|%.1f|%.2f|%.1f|%.2f|%.1f|%d|%.1f|%.2f|%.1f|%s|%s\n", \
                cmd, avg_cpu_pct, avg_mem_gb, avg_mem_pct, avg_disk_total_mbs, avg_disk_pct, \
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
        echo "No significant resource offenders detected (all processes below ${MIN_OFFENDER_THRESHOLD}% threshold)" >> "$report_file"
        rm -rf "$temp_dir"
        return 0
    fi
    
    # Sort by combined score and get top 10
    sort -t'|' -k13 -rn "$temp_dir/scores.txt" | head -10 > "$temp_dir/top10.txt"
    
    # Generate report
    echo "" >> "$report_file"
    echo "TOP RESOURCE OFFENDERS (Monitored: ${start_time} - ${end_time}, 15 seconds):" >> "$report_file"
    echo "================================================================================" >> "$report_file"
    
    local rank=1
    local has_partial=0
    
    while IFS='|' read -r cmd avg_cpu avg_mem_gb avg_mem_pct avg_disk avg_disk_pct \
        peak_cpu peak_mem_gb peak_mem_pct peak_disk peak_disk_pct suffix combined_score; do
        
        # Get parent/pool information
        local parent_info=""
        local sample_pid=$(awk -v cmd="$cmd" '$1 == "PRG" && $8 == cmd {print $7; exit}' "$snapshot_file")
        
        if [ -n "$sample_pid" ] && [ -d "/proc/$sample_pid" ]; then
            parent_info=$(get_parent_info "$sample_pid")
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
        printf "#%-2d %s%s\n" "$rank" "$cmd" "$parent_info" >> "$report_file"
        printf "    AVG:  CPU %.1f%%, MEM %.2fGB (%.1f%%), DISK %s\n" \
            "$avg_cpu" "$avg_mem_gb" "$avg_mem_pct" "$avg_disk_display" >> "$report_file"
        printf "    PEAK: CPU %.1f%%, MEM %.2fGB (%.1f%%), DISK %s\n" \
            "$peak_cpu" "$peak_mem_gb" "$peak_mem_pct" "$peak_disk_display" >> "$report_file"
        printf "    Score: %.1f%s\n" "$combined_score" "$suffix" >> "$report_file"
        echo "" >> "$report_file"
        
        rank=$((rank + 1))
    done < "$temp_dir/top10.txt"
    
    # Add legend if partial scores exist
    if [ "$has_partial" -eq 1 ] || [ "$LIMITED_MODE" -eq 1 ]; then
        echo "* Score excludes Disk I/O (requires root)" >> "$report_file"
        echo "" >> "$report_file"
    fi
    
    # Add system-level disk metrics
    if [ -f "$temp_dir/system_disk.txt" ]; then
        read -r sys_read sys_write < "$temp_dir/system_disk.txt"
        echo "================================================================================" >> "$report_file"
        echo "System-Level Disk I/O (Unattributed): ${sys_read} MB/s read, ${sys_write} MB/s write" >> "$report_file"
    fi
    
    # Cleanup
    rm -rf "$temp_dir"
}

# Get parent process information and extract pool/vhost details
get_parent_info() {
    local pid="$1"
    local info_parts=""
    
    # Try to get command line
    if [ -f "/proc/$pid/cmdline" ]; then
        local cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
        
        # Extract PHP-FPM pool
        local pool=$(echo "$cmdline" | grep -oP 'pool[= ]\K[^ ]+' | head -1)
        if [ -z "$pool" ]; then
            pool=$(echo "$cmdline" | grep -oP 'php-fpm: pool \K[^ ]+' | head -1)
        fi
        
        # Extract Apache vhost
        local vhost=$(echo "$cmdline" | grep -oP '\-D[^ ]*VHOST[^ ]*' | head -1)
        if [ -z "$vhost" ]; then
            vhost=$(echo "$cmdline" | grep -oP '\-f [^ ]*/([^/]+\.conf)' | head -1)
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
    
    # Try to get parent process name
    if [ -f "/proc/$pid/status" ]; then
        local ppid=$(grep '^PPid:' "/proc/$pid/status" 2>/dev/null | awk '{print $2}')
        if [ -n "$ppid" ] && [ "$ppid" -gt 1 ] && [ -f "/proc/$ppid/comm" ]; then
            local parent_name=$(cat "/proc/$ppid/comm" 2>/dev/null)
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
    MEM_USED_PERCENT=$(free | grep Mem | awk '{print ($3/$2) * 100.0}')
    
    # Get CPU I/O Wait % (Using vmstat for a 1-second sample)
    # The 16th column in vmstat output is usually 'wa' (wait)
    # We run it twice because the first line of vmstat is the average since boot.
    CPU_WAIT=$(vmstat 1 2 | tail -1 | awk '{print $16}')

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
        SNAPSHOT_FILE="/tmp/atop-snapshot-$$"
        
        # Capture 15-second atop snapshot with structured output
        atop -P PRG,PRC,PRM,PRD,DSK 1 15 > "$SNAPSHOT_FILE" 2>&1
        ATOP_EXIT=$?
        
        TIMESTAMP_END=$(date "+%Y-%m-%d %H:%M:%S")
        
        # Check if atop succeeded
        if [ $ATOP_EXIT -ne 0 ] || [ ! -s "$SNAPSHOT_FILE" ]; then
            echo "" >> "$LOG_FILE"
            echo "##############################################################################" >> "$LOG_FILE"
            if [ "$LIMITED_MODE" -eq 1 ]; then
                echo " ALERT TRIGGERED (Mode: Limited): $TIMESTAMP_START | REASON: $REASON" >> "$LOG_FILE"
            else
                echo " ALERT TRIGGERED: $TIMESTAMP_START | REASON: $REASON" >> "$LOG_FILE"
            fi
            echo "##############################################################################" >> "$LOG_FILE"
            echo "ERROR: atop failed to capture metrics (exit code: $ATOP_EXIT)" >> "$LOG_FILE"
            echo "------------------------------------------------------------------------------" >> "$LOG_FILE"
            rm -f "$SNAPSHOT_FILE"
        else
            # Parse atop output and generate report
            echo "" >> "$LOG_FILE"
            echo "##############################################################################" >> "$LOG_FILE"
            if [ "$LIMITED_MODE" -eq 1 ]; then
                echo " ALERT TRIGGERED (Mode: Limited): $TIMESTAMP_START | REASON: $REASON" >> "$LOG_FILE"
            else
                echo " ALERT TRIGGERED: $TIMESTAMP_START | REASON: $REASON" >> "$LOG_FILE"
            fi
            echo "##############################################################################" >> "$LOG_FILE"
            
            parse_atop_output "$SNAPSHOT_FILE" "$TIMESTAMP_START" "$TIMESTAMP_END" "$LOG_FILE"
            
            echo "------------------------------------------------------------------------------" >> "$LOG_FILE"
            rm -f "$SNAPSHOT_FILE"
        fi
        
        sleep "$COOLDOWN"
    else
        sleep "$CHECK_INTERVAL"
    fi
done