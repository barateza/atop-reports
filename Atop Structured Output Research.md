# **Comprehensive Analysis of Atop Structured Output Architectures and Version-Specific Implementations (Versions 2.3.0 to 2.11.1)**

## **Executive Summary**

The observability of Linux systems requires tools that not only display real-time data but also provide mechanisms for historical analysis and automated ingestion. Among the myriad of performance monitoring utilities, atop stands distinct due to its architectural emphasis on persistent data logging and rigorous structured output capabilities. This report provides an exhaustive technical analysis of the structured output formats—specifically the Parseable (ASCII) and JSON specifications—of the atop utility. The scope of this research encompasses the specific versions deployed across major enterprise Linux distributions, ranging from the legacy 2.3.0 release found in Ubuntu 18.04 LTS to the bleeding-edge 2.11.1 version available in AlmaLinux 10 and Debian 13\.

The analysis reveals a trajectory of increasing complexity and granularity. Earlier versions (2.3.x–2.4.x) rely on a rigid, position-dependent ASCII format that demands strict parser versioning. The intermediate period (2.6.x–2.7.x) introduced a paradigm shift with the implementation of JSON output, addressing the fragility of text parsing while simultaneously incorporating kernel advancements such as Pressure Stall Information (PSI). The modern era (2.10.x–2.11.x) reflects the dominance of cgroup v2 hierarchies and containerization, fundamentally altering how resource consumption is attributed and reported.

This document serves as a definitive reference for systems architects, site reliability engineers (SREs), and developers of monitoring agents who operate in heterogeneous environments. It details the exact field definitions, schema evolutions, and compatibility considerations required to extract high-fidelity performance data from the atop utility across the entire supported ecosystem of modern Linux distributions.

## ---

**1\. Introduction: The Philosophy and Architecture of Atop Data Serialization**

To fully comprehend the structured output of atop, it is essential to first understand the underlying data collection engine that generates it. Unlike standard process viewers such as top or htop, which typically rely on instantaneous snapshots of the /proc filesystem, atop functions as a comprehensive accounting system. It maintains a continuous record of system activity, capturing not just the state of processes at the moment of sampling, but also the cumulative resource usage of processes that started and finished *between* samples. This distinction is crucial for the structured output, as it dictates the presence of specific fields related to process accounting, exit codes, and aggregate counters that are absent in other tools.1

The utility operates on a dual-layer architecture. The bottom layer handles the raw data acquisition from kernel interfaces—reading from /proc, /sys, and utilizing the process accounting subsystem (or the atopacctd daemon in newer versions). This raw data is stored in internal C structures (sstat for system-level statistics and tstat for task-level statistics). The top layer is responsible for presentation, which includes the interactive ncurses interface and, pertinent to this report, the structured output streams.3

When a user or a monitoring agent requests structured output, atop serializes these internal structures into text. This serialization comes in two primary forms: the legacy Parseable output (-P), which produces space-separated values, and the modern JSON output (-J), which produces hierarchical data structures. The evolution of these formats is not arbitrary; it mirrors the evolution of the Linux kernel itself. As the kernel introduced new metrics—such as the proportional set size (PSS) for memory, instructions per cycle (IPC) for CPU efficiency, or the distinction between "available" and "free" memory—atop adapted its output schemas.

For an engineer responsible for a fleet of servers running a mix of CentOS 7, Ubuntu 20.04, and Debian 12, treating atop output as uniform is a recipe for failure. A script written to parse the disk statistics of version 2.3.0 will fail catastrophically if applied to version 2.7.1 due to the insertion of latency metrics that shift column indices. Similarly, the method for extracting container IDs has transitioned from non-existent to appended fields, and finally to dedicated cgroup structures. This report dissects these variations, providing the granular detail necessary to build robust, version-aware ingestion pipelines.

## ---

**2\. The Parseable Output Standard (-P)**

The Parseable output format, invoked via the \-P flag followed by a list of labels (e.g., atop \-P CPU,DSK), is the oldest and most universally supported interface for machine reading. It is available in every version covered in this report, from 2.3.0 to 2.11.1. Despite its longevity, it is brittle; it relies on a strict, space-delimited structure where the meaning of a value is determined solely by its ordinal position in the line.

### **2.1 The Universal Header Structure**

Regardless of the specific version or the metric label being reported, every line of parseable output begins with a standardized six-field header. This consistency allows parsers to identify the data type and temporal context before attempting to decode the payload.

The six header fields are defined as follows:

1. **Label:** A string identifier indicating the type of resource (e.g., CPU, DSK, NET, PRC). This determines the schema for the rest of the line.  
2. **Host:** The hostname of the machine. This is critical for centralized logging aggregation where streams from multiple servers are merged.  
3. **Epoch:** The timestamp of the sample in seconds since the UNIX epoch (1970-01-01).  
4. **Date:** The calendar date in YYYY/MM/DD format.  
5. **Time:** The clock time in HH:MM:SS format.  
6. **Interval:** The duration in seconds since the previous sample. This value is vital for rate calculations (e.g., calculating I/O operations per second requires dividing the accumulated counter by this interval).1

A distinct feature of the parseable output is the SEP label. After all requested metrics for a given interval have been printed, atop outputs a single line containing only the label SEP. This acts as a reliable delimiter between samples in a continuous stream. Furthermore, a RESET label indicates that the counters have been reset, typically signaling a system reboot or a restart of the atop daemon, implying that the next sample represents values "since boot" rather than a delta from the previous interval.6

### **2.2 System-Level Metrics Breakdown**

The following sections detail the field definitions for key system-level labels (CPU, MEM, DSK, NET), tracking their evolution across the target versions.

#### **2.2.1 Processor Metrics: CPU and cpu**

The processor metrics are split into two label types: CPU (all-caps) reports the aggregated total for the system, while cpu (lowercase) reports statistics for individual cores.

**Evolution of the CPU Schema:**

In the legacy era (Version 2.3.0, found in Ubuntu 18.04), the CPU line contained a fixed set of fields primarily derived from /proc/stat. These included the number of clock ticks spent in various modes: system, user, nice, idle, wait, irq, softirq, steal, and guest.

With the advent of Version 2.4.0 (Ubuntu 20.04), a significant enhancement was made: the inclusion of frequency and instruction counters. This marked a shift in observability from purely "time-based" metrics (how long was the CPU busy?) to "efficiency-based" metrics (how much work did it actually do?). Fields for current frequency (curf), frequency percentage (freq%), and instructions per cycle (ipc) were appended to the line.

**Table 1: Field Map for CPU Label (System Total)**

| Field Index | Metric Description | v2.3.0 (Ubuntu 18.04) | v2.4.0 (Ubuntu 20.04) | v2.7.1 (RHEL 9 / Ubuntu 22.04) | v2.11.1 (AlmaLinux 10\) |
| :---- | :---- | :---- | :---- | :---- | :---- |
| 1-6 | **Header** | Header | Header | Header | Header |
| 7 | **Ticks/Sec** | Yes | Yes | Yes | Yes |
| 8 | **\# Processors** | Yes | Yes | Yes | Yes |
| 9 | **System Mode** | Yes | Yes | Yes | Yes |
| 10 | **User Mode** | Yes | Yes | Yes | Yes |
| 11 | **User (Nice)** | Yes | Yes | Yes | Yes |
| 12 | **Idle Mode** | Yes | Yes | Yes | Yes |
| 13 | **Wait (Disk)** | Yes | Yes | Yes | Yes |
| 14 | **IRQ Mode** | Yes | Yes | Yes | Yes |
| 15 | **SoftIRQ** | Yes | Yes | Yes | Yes |
| 16 | **Steal Time** | Yes | Yes | Yes | Yes |
| 17 | **Guest Mode** | Yes | Yes | Yes | Yes |
| 18 | **Current Freq** | *Absent* | **Present** | **Present** | **Present** |
| 19 | **Freq %** | *Absent* | **Present** | **Present** | **Present** |
| 20 | **IPC** | *Absent* | **Present** | **Present** | **Present** |
| 21 | **Cycles** | *Absent* | **Present** | **Present** | **Present** |

**Insight:** The addition of IPC and Cycles in v2.4.0+ is particularly relevant for diagnosing "stalled" CPUs. A high CPU utilization (low idle) coupled with a low IPC suggests the processor is waiting on memory fetches (cache misses), whereas a high IPC indicates dense computational work. Parsers designed for v2.3.0 will simply ignore the extra fields in newer versions, but parsers expecting v2.11.1 data will crash or return nulls if run against v2.3.0.4

#### **2.2.2 Memory Metrics: MEM and SWP**

The memory accounting landscape in Linux changed drastically with the introduction of the "Available" memory metric in newer kernels, which atop adopted.

In Version 2.3.0, the MEM line reported total, free, cached, buffered, and slab memory. However, "free" memory is often a misleading metric in Linux because the kernel aggressively caches files. The "available" metric, which estimates how much memory can be reclaimed for new applications without swapping, provides a more realistic view of memory pressure.

**Table 2: Field Map for MEM Label**

| Field Index | Metric Description | v2.3.0 | v2.7.1 | v2.11.1 |
| :---- | :---- | :---- | :---- | :---- |
| 7 | **Page Size** | Yes | Yes | Yes |
| 8 | **Total Memory** | Yes | Yes | Yes |
| 9 | **Free Memory** | Yes | Yes | Yes |
| 10 | **Cache** | Yes | Yes | Yes |
| 11 | **Buffer** | Yes | Yes | Yes |
| 12 | **Slab** | Yes | Yes | Yes |
| 13 | **Dirty** | Yes | Yes | Yes |
| 14 | **Shared** | Yes | Yes | Yes |
| 15 | **Available** | *Absent* | **Present** | **Present** |
| 16+ | **HugePages/ZSwap** | *Absent* | *Partial* | **Present** |

In version 2.11.1 (and 2.10.0), the MEM output is further extended to include metrics for Static Huge Pages and ZSwap (compressed swap cache), reflecting the growing use of these technologies in high-performance computing and containerized environments. Parsing the MEM line requires careful checking of the version or the number of fields, as the "Available" field—critical for OOM (Out of Memory) prediction—is simply missing in the legacy versions.8

#### **2.2.3 Disk Metrics: DSK, LVM, MDD**

The disk statistics present one of the most significant compatibility challenges. The metric avio (Average I/O time per request) is a derived statistic that is incredibly valuable for identifying storage bottlenecks.

In Version 2.3.0, atop did not output avio in the parseable stream. Administrators had to manually calculate it using the formula: (IO Time) / (Reads \+ Writes). From Version 2.7.1 onwards, atop calculates this internally and exposes it as a distinct field.

**Field Structure for DSK Label (v2.7.1+):**

7\. **Disk Name** (e.g., sda, nvme0n1)

8\. **IO Time (ms):** Total time the disk spent doing I/O.

9\. **Reads Issued:** Number of read requests.

10\. **Read Sectors:** Total sectors read.

11\. **Writes Issued:** Number of write requests.

12\. **Write Sectors:** Total sectors written.

13\. **Cancelled Writes:** WCANCL (filesystem optimization).

14\. **Avg IO (avio):** Average time per request in microseconds (µs).

In Version 2.10.0 (Ubuntu 24.04), the handling of LVM (Logical Volume Manager) and MDD (Multi-Device Driver / RAID) was unified to better support NVMe multipathing. The output for these devices closely mirrors physical disks, but the naming conventions in the "Name" field can vary significantly (e.g., dm-0 vs md127).10

#### **2.2.4 Network Metrics: NET**

The NET label covers transport layers (NET | transport), network layers (NET | network), and interfaces (NET | \[interface\_name\]).

The transport layer metrics (tcpi, tcpo, udpi, udpo) have remained relatively stable. A critical field here is tcpretrans (TCP Retransmissions), which is a primary indicator of network congestion or packet loss.

For interfaces, atop versions 2.7.1 and newer implement smarter filtering of virtual interfaces. In environments running Docker or Kubernetes, thousands of veth interfaces can pollute the logs. Newer atop versions prioritize physical interfaces or those with significant traffic, whereas v2.3.0 often dumped statistics for every active interface, bloating the parseable output size significantly.1

### **2.3 Process-Level Metrics (PRC, PRG, PRM)**

Process data is where the sheer volume of atop output expands. The PRG (Process General) label provides the standard PID, PPID, User, Group, State, and Exit Code.

**The Container ID (CID) Evolution:**

In the era of v2.3.0, atop had no concept of containers. Processes running inside Docker containers looked like normal host processes.

In v2.7.1, atop began querying the Docker daemon or cgroup paths to identify Container IDs. This CID field is typically appended to the end of the PRG line.

In v2.11.1, with full Cgroups v2 support, this mechanism is further refined to identify Podman containers and Kubernetes pods more reliably.

**Table 3: Field Map for PRG Label**

| Field Index | Metric Description |
| :---- | :---- |
| 7 | **PID** |
| 8 | **PPID** (Parent PID) |
| 9 | **TGID** (Thread Group ID) |
| 10 | **UID** (User ID) |
| 11 | **GID** (Group ID) |
| 12 | **State** (R, S, D, Z, T, E) |
| 13 | **Exit Code** |
| 14 | **Start Time** |
| 15 | **Command** (Name) |
| 16 | **NProcs** (Number of processes in group) |
| 17 | **CID** (Container ID) \- *Present in v2.7+* |

**Crucial Insight for Parsers:** The "Command" field (Field 15\) can contain spaces (e.g., python script.py). This breaks simple space-based splitters. atop attempts to mitigate this by wrapping the command in parentheses (command), but a robust parser must use a regular expression or a stateful splitter to handle this field correctly. Version 2.10 introduced the \-Z flag which replaces spaces in the command line with underscores, eliminating this parsing ambiguity.5

## ---

**3\. The JSON Output Standard (-J)**

The introduction of JSON output in version 2.6.0 represented a modernization of atop's interface, decoupling data extraction from the rigid column counting of the \-P format.

### **3.1 Availability and Adoption**

* **Unsupported:** Ubuntu 18.04 (v2.3.0), Ubuntu 20.04 (v2.4.0), Debian 10 (v2.4.0).  
* **Supported:** Debian 11 (v2.6.0), Ubuntu 22.04 (v2.7.1), RHEL 8/9 (v2.7.1), and all newer versions.

### **3.2 Schema Structure**

Invoked via atop \-J, the output consists of a stream of JSON objects, typically one per sample. The schema is hierarchical:

JSON

{  
  "raw": {  
    "host": "server01",  
    "epoch": 1625140000,  
    "dt": "2021-07-01",  
    "ti": "12:00:00",  
    "int": 10,  
    "sstat": {  
      "cpu": {  
        "total": {... },  
        "proc": \[... \]  
      },  
      "mem": {... },  
      "dsk": {... },  
      "net": {... },  
      "psi": {... }  // Added in v2.7+  
    },  
    "tstat": \[  
      {  
        "pid": 1234,  
        "name": "nginx",  
        "cpu": {... },  
        "mem": {... }  
      },  
     ...  
    \]  
  }  
}

### **3.3 Advantages for Modern Monitoring**

The JSON format offers several distinct advantages over Parseable output:

1. **Schema Resilience:** New fields (like PSI or GPU metrics) appear as new keys. Parsers looking for sstat.mem.free will not break if sstat.mem.available is added next to it.  
2. **Type Safety:** Numeric values are represented as numbers, not strings, reducing the need for casting in the ingestion layer.  
3. **Nested Data:** Per-core CPU stats are naturally represented as an array sstat.cpu.proc, whereas in \-P mode they appear as multiple lines with the label cpu, requiring the parser to maintain state to aggregate them.

### **3.4 Version-Specific Keys**

* **PSI (Pressure Stall Information):** In v2.7.1 and above (on supported kernels), the sstat.psi object provides cpu, mem, and io objects, each containing avg10, avg60, avg300, and total. This is critical for SREs monitoring resource saturation beyond simple utilization.  
* **GPU:** In v2.10+, sstat.gpu provides aggregate GPU metrics if atopgpud is active.

## ---

**4\. Detailed Version Analysis and OS Implementations**

This section provides a granular analysis of the atop version provided by each requested operating system repository, highlighting specific capabilities and parsing strategies.

### **4.1 Legacy Era: Version 2.3.0**

* **OS:** Ubuntu 18.04 LTS  
* **Status:** End-of-Life (EOL) for standard support, but prevalent in legacy infrastructure.  
* **Structured Output:** \-P only.  
* **Key Characteristics:**  
  * No JSON support.  
  * No PSI support (Kernel 4.15).  
  * No "Available" memory field.  
  * Disk avio must be calculated manually.  
  * No Container ID awareness.  
* **Parsing Strategy:** Parsers must strictly adhere to the 2.3 field definitions. Any attempt to access field indices \> 17 for CPU or \> 14 for Memory will result in errors.

### **4.2 The 2.4.0 Update**

* **OS:** Ubuntu 20.04 LTS, Debian 10 (Buster)  
* **Structured Output:** \-P only.  
* **Key Changes:**  
  * Introduction of CPU frequency and IPC fields in Parseable output.  
  * Still no JSON support.  
  * Still pre-PSI in standard configuration (though some 5.4 kernels support PSI, atop 2.4.0 does not natively expose it in \-P).  
* **Implication:** This is a "middle-child" version. It breaks 2.3 parsers due to appended CPU fields but lacks the modern features of 2.6+.

### **4.3 The JSON Revolution: Version 2.6.0**

* **OS:** Debian 11 (Bullseye)  
* **Key Changes:**  
  * **JSON Introduced:** The \-J flag becomes available, fundamentally changing how automation can interact with atop.  
  * **PSI Support:** Native support for Pressure Stall Information.  
  * **Memory "Available":** Added to standard outputs.

### **4.4 The Mainstream Standard: Version 2.7.1**

* **OS:** Ubuntu 22.04 LTS, AlmaLinux 9, Rocky Linux 8/9, RHEL 8/9, CloudLinux 7/8/9, CentOS 7 (via EPEL).  
* **Status:** The most widely deployed version in current enterprise environments.  
* **Key Characteristics:**  
  * Robust JSON support.  
  * Native avio (disk latency) field in \-P output.  
  * Container ID support in \-P (PRG label).  
  * **Raw Log Incompatibility:** Note that the raw log format of 2.7.x is generally incompatible with 2.3/2.4 readers.  
* **Analysis:** This version represents the "sweet spot" for stability and feature set. It supports enough modern metrics (PSI, Docker) to be useful for SREs while being stable enough for RHEL/CentOS.

### **4.5 The Modern Era: Versions 2.10.0 and 2.11.1**

* **OS:** Ubuntu 24.04 LTS (2.10.0), AlmaLinux 10 / Debian 13 (2.11.1).  
* **Key Characteristics:**  
  * **Cgroups v2:** Full awareness of the unified hierarchy. Process grouping is no longer just by PID/TGID but by cgroup path.  
  * **NVMe Multipath:** Better aggregation of physical vs logical namespaces.  
  * **Parseable Output Extensions:** New labels for cgroup statistics (CGR).  
  * **GPU:** Enhanced integration with atopgpud for NVIDIA metrics.  
* **Implication:** Automation built for this version can leverage the rich cgroup data to correlate resource usage with systemd services (e.g., nginx.service usage vs. just nginx process usage).9

## ---

**5\. Developing Parsers for Heterogeneous Environments**

For organizations managing a mixed fleet (e.g., transitioning from CentOS 7 to AlmaLinux 9 or Ubuntu 18.04 to 24.04), a unified parsing strategy is required.

### **5.1 Strategy: Feature Detection over Version Checking**

Instead of maintaining a mapping of "Version X \= Schema Y," effective parsers should detect features.

**Pseudo-code Algorithm:**

1. **Check for JSON:** Run atop \-J 1 1\. If successful (exit code 0 and valid JSON output), use the JSON parser. This covers Ubuntu 22.04+, Debian 11+, RHEL 8/9.  
2. **Fallback to Parseable:** If \-J fails (Ubuntu 18.04/20.04), fall back to \-P.  
3. **Inspect Header:** Read the first sample's CPU line. Count the number of fields.  
   * If Fields \== 17: Treat as v2.3 (Legacy).  
   * If Fields \> 17: Treat as v2.4+ (Extended).  
4. **Metric Availability:**  
   * If PSI label exists in \-P stream, ingest pressure metrics.  
   * If avio (Field 14\) exists in DSK, use it; otherwise calculate (Time / IOs).

### **5.2 Handling Raw Logs**

A common workflow involves shipping raw atop logs (/var/log/atop/atop\_YYYYMMDD) to a central server for analysis.

* **Challenge:** The binary format of raw logs changes between versions. An atop binary from v2.10 cannot read a v2.3 log file.  
* **Solution:** Do not ship raw logs for central processing unless the central analyzer has multi-version binaries available. Instead, run atop \-r \[logfile\] \-P \[labels\] *on the source host* to convert to ASCII/JSON before shipping. This leverages the local binary which matches the log version, ensuring data integrity.14

## ---

**6\. Updating Atop and Configuration**

### **6.1 Update Instructions**

While the user requested analysis of "standard" repository versions, maintaining consistency often requires upgrading legacy hosts.

* **RHEL/CentOS/AlmaLinux:**  
  The EPEL (Extra Packages for Enterprise Linux) repository is the standard source.  
  Bash  
  \# Enable EPEL  
  dnf install epel-release  
  \# Install/Update  
  dnf install atop

  *Note: On RHEL 7 / CentOS 7, EPEL provides v2.7.1, which is a significant upgrade from the base OS version.*  
* **Ubuntu/Debian:**  
  To get newer versions on older distros (e.g., v2.7+ on Ubuntu 20.04), one must download the upstream .deb or compile from source, as official backports are rare for system monitors.  
  Bash  
  \# Check version  
  atop \-V

### **6.2 Configuring Logging Intervals**

The default logging interval is often 600 seconds (10 minutes), which is too coarse for modern micro-burst analysis.

* **RHEL/CentOS/Systemd Systems:**  
  Edit /etc/sysconfig/atop (RHEL) or /etc/default/atop (Debian/Ubuntu).  
  Bash  
  \# Change interval to 60 seconds  
  LOGINTERVAL=60

  Restart the service:  
  Bash  
  systemctl restart atop

  *Insight:* Reducing the interval to 60s increases log size by 10x. Ensure log rotation (/etc/logrotate.d/atop) is configured to retain files for fewer days if disk space is constrained.15

## ---

**7\. Conclusion**

The atop utility has evolved from a sophisticated top replacement into a comprehensive system data recorder. For modern Linux environments (Ubuntu 22.04+, RHEL 8+), the **JSON output format** provides a stable, robust, and extensible contract for automation, supporting critical metrics like PSI and Cgroups v2. However, the persistence of legacy versions in LTS lifecycles necessitates that tooling maintain backward compatibility with the **Parseable (-P)** format.

By adhering to the schema definitions and parsing strategies outlined in this report, engineering teams can bridge the gap between legacy infrastructure and modern observability standards, ensuring total visibility across the compute estate.

### ---

**Sources**

* 1 Atop General Documentation and Usage  
* 3 Man Pages for Ubuntu/Debian Versions  
* 10 JSON Output Introduction and Mechanics  
* 9 Changelogs for v2.10, v2.11  
* 8 PSI and GPU Feature Integration  
* 15 Configuration and Usage Guides (Tecmint)  
* 5 StackOverflow/Exchange Technical Discussions on Parsing

#### **Works cited**

1. Use atop and atopsar for historical statistics in my EC2 instance | AWS re:Post, accessed January 16, 2026, [https://repost.aws/knowledge-center/ec2-linux-monitor-stats-with-atop](https://repost.aws/knowledge-center/ec2-linux-monitor-stats-with-atop)  
2. Atoptool.nl, accessed January 16, 2026, [https://www.atoptool.nl/](https://www.atoptool.nl/)  
3. atop \- Advanced System & Process Monitor \- Ubuntu Manpage, accessed January 16, 2026, [https://manpages.ubuntu.com/manpages/jammy/man1/atop.1.html](https://manpages.ubuntu.com/manpages/jammy/man1/atop.1.html)  
4. atop/parseable.c at master · Atoptool/atop \- GitHub, accessed January 16, 2026, [https://github.com/Atoptool/atop/blob/master/parseable.c](https://github.com/Atoptool/atop/blob/master/parseable.c)  
5. Dudes about parsable output in atop \- linux \- Stack Overflow, accessed January 16, 2026, [https://stackoverflow.com/questions/62362472/dudes-about-parsable-output-in-atop](https://stackoverflow.com/questions/62362472/dudes-about-parsable-output-in-atop)  
6. atop(1) \- testing \- Debian Manpages, accessed January 16, 2026, [https://manpages.debian.org/testing/atop/atop.1.en.html](https://manpages.debian.org/testing/atop/atop.1.en.html)  
7. Linux System and process analysis with atop \- Atoptool.nl, accessed January 16, 2026, [https://www.atoptool.nl/download/atop2022.pdf](https://www.atoptool.nl/download/atop2022.pdf)  
8. Download atop \- Atoptool.nl, accessed January 16, 2026, [https://www.atoptool.nl/downloadatop.php](https://www.atoptool.nl/downloadatop.php)  
9. Releases · Atoptool/atop \- GitHub, accessed January 16, 2026, [https://github.com/Atoptool/atop/releases](https://github.com/Atoptool/atop/releases)  
10. How to avoid interactive mode of \`atop\` and redirect output to the file? \- Ask Ubuntu, accessed January 16, 2026, [https://askubuntu.com/questions/1549856/how-to-avoid-interactive-mode-of-atop-and-redirect-output-to-the-file](https://askubuntu.com/questions/1549856/how-to-avoid-interactive-mode-of-atop-and-redirect-output-to-the-file)  
11. How to log disk load? \- Ask Ubuntu, accessed January 16, 2026, [https://askubuntu.com/questions/1287516/how-to-log-disk-load](https://askubuntu.com/questions/1287516/how-to-log-disk-load)  
12. atop(1) \- Arch manual pages, accessed January 16, 2026, [https://man.archlinux.org/man/atop.1.en](https://man.archlinux.org/man/atop.1.en)  
13. Change log : atop package : Ubuntu \- Launchpad, accessed January 16, 2026, [https://launchpad.net/ubuntu/+source/atop/+changelog](https://launchpad.net/ubuntu/+source/atop/+changelog)  
14. Parsing Atop log files with Dissect \- Hunt & Hackett, accessed January 16, 2026, [https://www.huntandhackett.com/blog/parsing-atop-log-files-with-dissect](https://www.huntandhackett.com/blog/parsing-atop-log-files-with-dissect)  
15. How to Install 'atop' to Monitor Real-Time System Performance, accessed January 16, 2026, [https://www.tecmint.com/atop-linux-performance-monitoring/](https://www.tecmint.com/atop-linux-performance-monitoring/)  
16. Analyzing Linux server performance with atop \- Red Hat, accessed January 16, 2026, [https://www.redhat.com/en/blog/analyzing-linux-server-performance-atop](https://www.redhat.com/en/blog/analyzing-linux-server-performance-atop)  
17. pcp-atop, pmatop \- Advanced System and Process Monitor \- Ubuntu Manpage, accessed January 16, 2026, [https://manpages.ubuntu.com/manpages/bionic/man1/pcp-atop.1.html](https://manpages.ubuntu.com/manpages/bionic/man1/pcp-atop.1.html)  
18. atop-2.8.1-bp156.2.8 \- SUSE Package Hub, accessed January 16, 2026, [https://packagehub.suse.com/packages/atop/2\_8\_1-bp156\_2\_8/](https://packagehub.suse.com/packages/atop/2_8_1-bp156_2_8/)  
19. atop-2.7.1-bp154.2.3.1 \- SUSE Package Hub \-, accessed January 16, 2026, [https://packagehub.suse.com/packages/atop/2\_7\_1-bp154\_2\_3\_1/](https://packagehub.suse.com/packages/atop/2_7_1-bp154_2_3_1/)
