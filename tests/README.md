# Test Infrastructure

This directory contains the test infrastructure for validating `atop-reports.sh` across multiple atop versions (2.3.0 to 2.11.1).

## Directory Structure

```
tests/
├── README.md                        # This file
├── generate-all-fixtures.sh         # Lima-based unified fixture generator (ALL OS families)
├── run-test.sh                      # Docker container test runner
├── validate-fixture.sh              # Binary fixture quality checker
├── fixtures/                        # Golden master atop raw logs (13/16 platforms)
│   ├── UBUNTU (4/4 ✅):
│   │   ├── v2.3.0-ubuntu18.04.raw  # Ubuntu 18.04 - Bionic (atop 2.3.0)
│   │   ├── v2.4.0-ubuntu20.04.raw  # Ubuntu 20.04 - Focal (atop 2.4.0)
│   │   ├── v2.7.1-ubuntu22.04.raw  # Ubuntu 22.04 - Jammy (atop 2.7.1, Container ID support)
│   │   └── v2.10.0-ubuntu24.04.raw # Ubuntu 24.04 - Noble (atop 2.10.0)
│   ├── DEBIAN (3/4):
│   │   ├── v2.6.0-debian11.raw     # Debian 11 - Bullseye (atop 2.6.0)
│   │   ├── v2.8.1-debian12.raw     # Debian 12 - Bookworm (atop 2.8.1, CRITICAL - untested version)
│   │   └── v2.11.1-debian13.raw    # Debian 13 - Trixie (atop 2.11.1, bleeding edge)
│   │   ❌ v2.4.0-debian10 skipped (EOL June 2024)
│   ├── CENTOS (1/1 ✅):
│   │   └── v2.3.0-centos7.raw      # CentOS 7 (atop 2.3.0, ELS until Jan 1, 2027)
│   ├── CLOUDLINUX (3/3 ✅):
│   │   ├── v2.3.0-cloudlinux7.raw  # CloudLinux 7 (atop 2.3.0, ELS until Jan 1, 2027)
│   │   ├── v2.7.1-cloudlinux8.raw  # CloudLinux 8 (atop 2.7.1)
│   │   └── v2.7.1-cloudlinux9.raw  # CloudLinux 9 (atop 2.7.1)
│   ├── ROCKY LINUX (2/2 ✅):
│   │   ├── v2.7.1-rocky8.raw       # Rocky Linux 8 (atop 2.7.1, explicit testing for OS quirks)
│   │   └── v2.7.1-rocky9.raw       # Rocky Linux 9 (atop 2.7.1)
│   └── ALMALINUX (v2.1 target):
│       ├── v2.7.1-almalinux8.raw   # AlmaLinux 8 (atop 2.7.1, code complete, fixtures deferred to v2.1)
│       └── v2.7.1-almalinux9.raw   # AlmaLinux 9 (atop 2.7.1, code complete, fixtures deferred to v2.1)
├── lima-templates/                  # Lima YAML configurations for all OS families
│   ├── UBUNTU:
│   │   ├── ubuntu-18.04.yaml
│   │   ├── ubuntu-20.04.yaml
│   │   ├── ubuntu-22.04.yaml
│   │   └── ubuntu-24.04.yaml
│   ├── DEBIAN:
│   │   ├── debian-10.yaml (optional, EOL)
│   │   ├── debian-11.yaml
│   │   ├── debian-12.yaml
│   │   └── debian-13.yaml
│   ├── RHEL FAMILY:
│   │   ├── centos-7.yaml (RHEL 7 baseline, ELS until Jan 1, 2027)
│   │   ├── cloudlinux-7.yaml (CloudLinux 7, ELS until Jan 1, 2027)
│   │   ├── cloudlinux-8.yaml
│   │   ├── cloudlinux-9.yaml
│   │   ├── rocky-8.yaml (explicit separate testing for OS-specific quirks)
│   │   ├── rocky-9.yaml
│   │   ├── almalinux-8.yaml (v2.1 target)
│   │   └── almalinux-9.yaml (v2.1 target)
└── expected/                        # Expected JSON outputs (optional)
    └── v2.7.1-output.json
```

**Coverage:** ✅ 13/16 platforms (81% - Ubuntu 4/4, Debian 3/4, CentOS 7, CloudLinux 7/8/9, Rocky 8/9)  
**v2.1 Targets:** AlmaLinux 8/9 (code production-ready, fixtures deferred)

## Quick Start

### Prerequisites

**For Fixture Generation (one-time):**

- **Lima installed:** `brew install lima` (macOS/Linux) - unified backend for **all 10 OS families**
- Internet connection for VM downloads (first run: 200-500MB per OS family)

**For Running Tests:**

- Docker and Docker Compose installed
- Fixture files in `tests/fixtures/` (generated or downloaded)

**Supported OS Families (Unified Lima Backend):**
- Ubuntu: 18.04, 20.04, 22.04, 24.04
- Debian: 10, 11, 12, 1310 OS families)

```bash
# Generate all 13/16 target fixtures
./tests/generate-all-fixtures.sh

# Generate specific OS family
./tests/generate-all-fixtures.sh --os ubuntu      # All 4 Ubuntu versions
./tests/generate-all-fixtures.sh --os debian      # Debian 11, 12, 13
./tests/generate-all-fixtures.sh --os centos      # CentOS 7
./tests/generate-all-fixtures.sh --os cloudlinux  # CloudLinux 7, 8, 9
./tests/generate-all-fixtures.sh --os rocky       # Rocky Linux 8, 9
./tests/generate-all-fixtures.sh --os almalinux   # AlmaLinux 8, 9 (v2.1 target)

# Generate specific version
./tests/generate-all-fixtures.sh --os debian --version 12
./tests/generate-all-fixtures.sh --os cloudlinux --version 8
./tests/generate-all-fixtures.sh --os rocky --version 9

# Force rebuild (delete and recreate VMs)
./tests/generate-all-fixtures.sh --force-rebuild
```

**Process Overview:**

1. **VM Launch**: Creates VM with unified naming `vm-atop-${os_family}-${os_version}`
2. **atop Install**: Installs version appropriate to OS (via apt/dnf/yum)
3. **Snapshot Capture**: `atop -w /tmp/fixture.raw 15 1` (15-second capture)
4. **SSH Transfer**: `limactl cp` via deterministic SSH (not unreliable VirtioFS)
5. **Cleanup**: Optionally deletes VM (or reuses for faster warm runs)

**VM Naming Convention:**
- Pattern: `vm-atop-${os_family}-${os_version}` (consistent across all platforms)
- Examples:
  - `vm-atop-ubuntu-22.04`
  - `vm-atop-cloudlinux-8`
  - `vm-atop-rocky-9`
  - `vm-atop-almalinux-9`
# Force rebuild (delete and recreate VMs)
./generate-all-fixtures.sh --force-rebuild
```

**VM Naming Convention:**
13 active services + 2 AlmaLinux v2.1 targets)
docker-compose up --abort-on-container-exit

# Run specific OS version
docker-compose run --rm test-bionic      # Ubuntu 18.04 (atop 2.3.0)
docker-compose run --rm test-focal       # Ubuntu 20.04 (atop 2.4.0)
docker-compose run --rm test-jammy       # Ubuntu 22.04 (atop 2.7.1)
docker-compose run --rm test-noble       # Ubuntu 24.04 (atop 2.10.0)
docker-compose run --rm test-debian11    # Debian 11 (atop 2.6.0)
docker-compose run --rm test-debian12    # Debian 12 (atop 2.8.1, CRITICAL version)
docker-compose run --rm test-debian13    # Debian 13 (atop 2.11.1)
docker-compose run --rm test-centos7     # CentOS 7 (atop 2.3.0, ELS until Jan 1, 2027)
dockeBinary Fixture Format**
   - Valid atop raw log format
   - Reasonable file size (5-20KB for idle VMs, 50-500KB for loaded systems)

2. **Parseable Output Extraction**
   - Minimum 600 lines of parseable atop output
   - All required label types present (PRG, PRC, PRM, PRD, DSK)
   - Header line detection for dynamic field mapping

3. **JSON Schema Validation**
   - Valid JSON structure (parseable by `jq`)
   - Schema version field (`meta.schema_version = "2.0"`)
   - Required fields (`meta`, `data`, `processes`)
   - Container ID field presence (null for pre-2.7.1, value for 2.7.1+)

4. **Text Report Generation**
   - Ranked process list
   - System metrics (CPU, Memory, Disk I/O)
   - Verbose mode with container ID display

5. **Version-Specific Validation**
   - Dynamic header detection (all versions 2.3.0-2.11.1)
   - Fallback field maps for legacy systems
   - Graceful null handling for missing fields4, 24.04)
docker-compose up --abort-on-container-exit

# Run specific version
docker-compose run test-jammy   # Ubuntu 22.04 (atop 2.7.1)
docker-compose run test-bionic  # Ubuntu 18.04 (atop 2.3.0)
```

## Test Coverage

Each test validates:

1. **Text Output Format**
   - Header presence (`TOP RESOURCE OFFENDERS`)
   - Process ranking
   - Metric formatting

2. **JSON Schema Validation**
   - Valid JSON structure (parseable by `jq`)
   - Schema version field (`meta.schema_version = "2.0"`)
   - Required fields (`meta.hostname`, `data.processes`)
   - Container ID field presence (null-safe)

3. **Verbose Mode**
   - `--verbose` flag execution
   - Container ID display (when available)

## Manual Testing

### Test Against Real System

```bash
# Capture live snapshot
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 15 > /tmp/live-snapshot.txt

# Test text output
./atop-reports.sh --file /tmp/live-snapshot.txt

# Test JSON output
./atop-reports.sh --file /tmp/live-snapshot.txt --json | jq .

# Test verbose mode
./atop-reports.sh --file /tmp/live-snapshot.txt --verbose
```

### Test Replay Mode

```bash
# Convert raw binary log to parseable text
atop -r tests/fixtures/v2.7.1-ubuntu22.04.raw -P PRG,PRC,PRM,PRD,DSK 1 15 > /tmp/parsed.txt

# Replay through script
./atop-reports.sh --file /tmp/parsed.txt --json
```

## Fixture Format

Fixtures are **atop raw binary logs** created with:

```bash
atop -w /tmp/fixture.raw 15 1
```

**Contents:**

- 15 samples @ 1-second intervals (15 seconds total)
- System-level metrics (CPU, Memory, Disk, Network)
- Process-level metrics (PID, CPU, Memory, Disk I/O)
- Container IDs (atop 2.7.1+ only)

**Why Binary?**

- Preserves exact atop version behavior
- No precision loss from text conversion
- Can be replayed with native atop on different systems

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Test atop-reports

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        ubuntu: ['18.04', '20.04', '22.04', '24.04']
    
    steps:
      - uses: actions/checkout@v3
      
      - name: Run tests for Ubuntu ${{ matrix.ubuntu }}
        run: docker-compose run test-$(echo ${{ matrix.ubuntu }} | tr '.' '-')
```

### Local Pre-commit Hook

```bash
# .git/hooks/pre-commit
#!/bin/bash
docker-compose up --abort-on-container-exit || {
  echo "Tests failed. Commit aborted."
  exit 1
}
```

## Troubleshooting

### Fixture Generation Fails

**Error:** `multipass launch failed`

**Solution:**

```bash
# Check Multipass status
multipass version

# Check existing VMs
multipass list

# Delete stale VMs
multipass delete --all --purge
```

### Test Container Fails

**Error:** `atop: command not found`

**Solution:** The test script installs atop automatically. Check Docker logs:

```bash
docker-compose logs test-jammy
```

### Version Mismatch Warning

```
⚠️  WARNING: Version mismatch (expected 2.7.1, got 2.7.0)
```

**Explanation:** Ubuntu repositories may have slightly different atop versions than expected. Tests will continue but may show minor behavioral differences.

**Action:** Review test output for actual failures (exit code != 0).

### Empty Fixture File

**Error:** `Fixture is empty!`

**Cause:** atop failed to capture data (permission issue, short capture time)

**Solution:**

1. Verify atop works in VM: `multipass exec vm-name -- atop 1 1`
2. Check VM has activity: `multipass exec vm-name -- ps aux`
3. Increase capture time in script (15 → 30 seconds)

## Advanced Usage

### Custom Fixture Capture

```bash
# Launch VM
multipass launch 22.04 --name custom-atop

# SSH into VM
multipass shell custom-atop

# Generate load
stress-ng --cpu 4 --vm 2 --vm-bytes 1G --timeout 60s &

# Capture during load
sudo atop -w /tmp/high-load.raw 15 1

# Transfer fixture
multipass transfer custom-atop:/tmp/high-load.raw ./tests/fixtures/
```

### Expected Output Snapshots

Create expected JSON outputs for regression testing:

```bash
# Generate baseline
./atop-reports.sh --file tests/fixtures/v2.7.1-ubuntu22.04.raw --json \
  | jq 'del(.meta.timestamp)' > tests/expected/v2.7.1-output.json

# Compare future runs
diff <(jq . tests/expected/v2.7.1-output.json) \
     <(./atop-reports.sh --file tests/fixtures/v2.7.1-ubuntu22.04.raw --json | jq 'del(.meta.timestamp)')
```

## Maintenance

### When to Regenerate Fixtures

- ✅ **Do:** When upgrading script to support new atop versions
- ✅ **Do:** When atop package updates significantly change output
- ❌ **Don't:** On every commit (fixtures are stable)
- ❌ **Don't:** To "refresh" data (fixtures are golden masters, not live data)

### Fixture Lifecycle

1. **Initial Capture:** One-time generation per OS version
2. **Commit to Git:** Store in repository (5-20MB total)
3. **Use for Testing:** Run tests against static fixtures
4. **Regenerate:** Only when adding support for new OS/atop versions

### Adding New OS Version

To add support for a new Ubuntu release:

1. Update `tests/generate-fixtures.sh`:

   ```bash
   declare -a VMS=(
       "atop-bionic:18.04:2.3.0"
       "atop-focal:20.04:2.4.0"
       "atop-jammy:22.04:2.7.1"
       "atop-noble:24.04:2.10.0"
       "atop-oracular:24.10:2.11.0"  # ADD NEW
   )
   ```

2. Update `docker-compose.yml`:

   ```yaml
   test-oracular:
     image: ubuntu:24.10
     volumes: [...]
     command: /tests/run-test.sh "2.11.0" "24.10"
   ```

3. Generate fixture:

   ```bash
   ./tests/generate-fixtures.sh
   ```

4. Run test:

   ```bash
   docker-compose run test-oracular
   ```

## Performance

### Fixture Generation

- **Ubuntu 18.04:** ~12 minutes (slow APT mirrors)
- **Ubuntu 20.04:** ~10 minutes
- **Ubuntu 22.04:** ~8 minutes
- **Ubuntu 24.04:** ~8 minutes
- **Total:** ~40 minutes for all versions

### Test Execution

- **Per container:** ~30 seconds
- **All containers:** ~2 minutes (parallel)
- **CI/CD:** ~3 minutes (including Docker pull)

## Best Practices

1. **Commit Fixtures to Git:** Enables reproducible testing without VMs
2. **Run Tests Locally:** Before pushing commits
3. **Use Docker Compose:** Ensures consistent test environment
4. **Document Expected Behavior:** Add comments to test scripts
5. **Version Control Test Data:** Commit expected outputs for regression testing

## Support

For test infrastructure issues, check:

1. Docker/Multipass installation
2. Fixture file existence and size
3. Container logs: `docker-compose logs`
4. atop version in container: `docker-compose run test-jammy atop -V`

Report issues with:

- Your OS and Docker version
- Full test output
- Fixture file size and checksum
