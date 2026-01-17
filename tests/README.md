# Test Infrastructure

This directory contains the test infrastructure for validating `atop-reports.sh` across multiple atop versions (2.3.0 to 2.10.0).

## Directory Structure

```
tests/
├── README.md                    # This file
├── generate-fixtures.sh         # Multipass-based fixture generator
├── run-test.sh                  # Docker container test runner
├── fixtures/                    # Golden master atop raw logs
│   ├── v2.3.0-ubuntu18.04.raw  # Ubuntu 18.04 (atop 2.3.0)
│   ├── v2.4.0-ubuntu20.04.raw  # Ubuntu 20.04 (atop 2.4.0)
│   ├── v2.7.1-ubuntu22.04.raw  # Ubuntu 22.04 (atop 2.7.1)
│   └── v2.10.0-ubuntu24.04.raw # Ubuntu 24.04 (atop 2.10.0)
└── expected/                    # Expected JSON outputs (optional)
    └── v2.7.1-output.json
```

## Quick Start

### Prerequisites

**For Fixture Generation (one-time):**

- **Ubuntu:** Multipass installed: `brew install multipass` (macOS)
- **Debian/AlmaLinux:** Lima installed: `brew install lima` (macOS)
- Internet connection for VM downloads (first run: 200-500MB per OS family)

**For Running Tests:**

- Docker and Docker Compose installed
- Fixture files in `tests/fixtures/` (generated or downloaded)

### Generate Fixtures

```bash
# Generate golden master fixtures for all versions
./tests/generate-fixtures.sh

# This will:
# 1. Launch Ubuntu VMs (18.04, 20.04, 22.04, 24.04)
# 2. Install atop in each
# 3. Capture 15-second atop raw logs
# 4. Transfer to tests/fixtures/
# 5. Clean up VMs
```

**Time:** ~10-15 minutes per VM (4 VMs = 40-60 minutes total)  
**Disk:** ~5-20MB per fixture file

### Run Tests

```bash
# Run all tests (Ubuntu 18.04, 20.04, 22.04, 24.04)
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
