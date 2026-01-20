# Fixtures Directory

This directory contains golden master atop raw log files for testing across different versions.

## Files

Generate fixtures using:

```bash
# Generate all fixtures (all OS families via unified Lima backend)
../generate-all-fixtures.sh

# Generate specific OS family
../generate-all-fixtures.sh --os debian
../generate-all-fixtures.sh --os almalinux

# Generate specific version
../generate-all-fixtures.sh --os debian --version 12
```

## VM Naming Convention

All test VMs follow unified naming: `vm-atop-${os_family}-${os_version}`

Examples:
- `vm-atop-ubuntu-18.04` → v2.3.0-ubuntu18.04.raw
- `vm-atop-debian-12` → v2.8.1-debian12.raw
- `vm-atop-almalinux-9` → v2.7.1-almalinux9.raw

## Expected Files

**Ubuntu (via unified Lima backend):**
- `v2.3.0-ubuntu18.04.raw` - Ubuntu 18.04 LTS (atop 2.3.0)
- `v2.4.0-ubuntu20.04.raw` - Ubuntu 20.04 LTS (atop 2.4.0)
- `v2.7.1-ubuntu22.04.raw` - Ubuntu 22.04 LTS (atop 2.7.1)
- `v2.10.0-ubuntu24.04.raw` - Ubuntu 24.04 LTS (atop 2.10.0)

**Debian (via unified Lima backend):**
- `v2.4.0-debian10.raw` - Debian 10 Buster (atop 2.4.0)
- `v2.6.0-debian11.raw` - Debian 11 Bullseye (atop 2.6.0)
- `v2.8.1-debian12.raw` - Debian 12 Bookworm (atop 2.8.1) **CRITICAL**
- `v2.11.1-debian13.raw` - Debian 13 Trixie (atop 2.11.1) **LATEST**

**AlmaLinux (via unified Lima backend):**
- `v2.7.1-almalinux8.raw` - AlmaLinux 8 (atop 2.7.1)
- `v2.7.1-almalinux9.raw` - AlmaLinux 9 (atop 2.7.1)

## Size

Each fixture is approximately 5-12KB (15 seconds of idle VM data).
Production servers under load may generate larger fixtures (50-500KB).

## Format

These are **atop raw binary logs** created with:

```bash
atop -w /tmp/fixture.raw 15 1
```

To replay:

```bash
atop -r v2.7.1-ubuntu22.04.raw -P PRG,PRC,PRM,PRD,DSK 1 15
```

## Git Tracking

By default, fixtures are **not tracked** in git (see `.gitignore`).

To track fixtures after generation:

1. Edit `tests/.gitignore`
2. Comment out: `# fixtures/*.raw`
3. Commit: `git add tests/fixtures/*.raw`

## Regeneration

Only regenerate when:

- Adding support for new OS versions
- atop package significantly changes output format
- Testing new features that depend on specific atop data

Do NOT regenerate on every commit.
