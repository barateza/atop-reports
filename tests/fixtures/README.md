# Fixtures Directory

This directory contains golden master atop raw log files for testing across **10 OS families** (13/16 v2.0 platforms).

## Expected Files (13/16 v2.0 Coverage - 81%)

Generate fixtures using:

```bash
# Generate all fixtures (all 10 OS families via unified Lima backend)
../generate-all-fixtures.sh

# Generate specific OS family
../generate-all-fixtures.sh --os ubuntu      # All 4 Ubuntu versions
../generate-all-fixtures.sh --os debian      # Debian 11, 12, 13
../generate-all-fixtures.sh --os centos      # CentOS 7
../generate-all-fixtures.sh --os cloudlinux  # CloudLinux 7, 8, 9
../generate-all-fixtures.sh --os rocky       # Rocky Linux 8, 9
../generate-all-fixtures.sh --os almalinux   # AlmaLinux 8, 9 (v2.1 target)

# Generate specific version
../generate-all-fixtures.sh --os debian --version 12
../generate-all-fixtures.sh --os cloudlinux --version 8
```

## Complete Fixture Breakdown (16 Total Files)

### UBUNTU (4/4 ✅)
- `v2.3.0-ubuntu18.04.raw` - Ubuntu 18.04 LTS - Bionic (atop 2.3.0)
- `v2.4.0-ubuntu20.04.raw` - Ubuntu 20.04 LTS - Focal (atop 2.4.0)
- `v2.7.1-ubuntu22.04.raw` - Ubuntu 22.04 LTS - Jammy (atop 2.7.1, Container ID support)
- `v2.10.0-ubuntu24.04.raw` - Ubuntu 24.04 LTS - Noble (atop 2.10.0)

### DEBIAN (3/4)
- `v2.6.0-debian11.raw` - Debian 11 - Bullseye (atop 2.6.0)
- `v2.8.1-debian12.raw` - Debian 12 - Bookworm (atop 2.8.1) **CRITICAL - untested version**
- `v2.11.1-debian13.raw` - Debian 13 - Trixie (atop 2.11.1) **LATEST - bleeding edge**
- ❌ Debian 10 skipped (EOL June 2024, image 404)

### CENTOS (1/1 ✅)
- `v2.3.0-centos7.raw` - CentOS 7 (atop 2.3.0) **ELS until January 1, 2027**

### CLOUDLINUX (3/3 ✅)
- `v2.3.0-cloudlinux7.raw` - CloudLinux 7 (atop 2.3.0) **ELS until January 1, 2027**
- `v2.7.1-cloudlinux8.raw` - CloudLinux 8 (atop 2.7.1)
- `v2.7.1-cloudlinux9.raw` - CloudLinux 9 (atop 2.7.1)

### ROCKY LINUX (2/2 ✅)
- `v2.7.1-rocky8.raw` - Rocky Linux 8 (atop 2.7.1) **Explicit testing for OS-specific quirks**
- `v2.7.1-rocky9.raw` - Rocky Linux 9 (atop 2.7.1)

### ALMALINUX (v2.1 TARGET)
- `v2.7.1-almalinux8.raw` - AlmaLinux 8 (atop 2.7.1) - **v2.1 target** (code production-ready, fixtures deferred to v2.1)
- `v2.7.1-almalinux9.raw` - AlmaLinux 9 (atop 2.7.1) - **v2.1 target** (code production-ready, fixtures deferred to v2.1)

## VM Naming Convention

All test VMs follow unified naming: `vm-atop-${os_family}-${os_version}`

Examples:
- `vm-atop-ubuntu-18.04` → v2.3.0-ubuntu18.04.raw
- `vm-atop-centos-7` → v2.3.0-centos7.raw
- `vm-atop-cloudlinux-8` → v2.7.1-cloudlinux8.raw
- `vm-atop-rocky-9` → v2.7.1-rocky9.raw
- `vm-atop-almalinux-9` → v2.7.1-almalinux9.raw (v2.1 target)

## Size and Coverage

**v2.0 (13/16 platforms - 81% coverage):**
- ✅ Ubuntu: 4/4 (all versions)
- ✅ Debian: 3/4 (all current versions, 10 skipped - EOL)
- ✅ RHEL Family: 6/6 (CentOS 7, CloudLinux 7/8/9, Rocky 8/9)
- **Total: 13/16 platforms ready for production**

**v2.1 Targets (2/2 platforms):**
- 🟡 AlmaLinux 8/9 (code production-ready, fixtures deferred due to upstream Lima VZ driver limitation on Apple Silicon)

**Key Notes:**
- **Debian 12/13:** CRITICAL - test previously untested atop versions (2.8.1, 2.11.1)
- **CentOS 7 & CloudLinux 7:** ELS until January 1, 2027 (Plesk official support timeline)
- **Rocky Linux:** Explicit separate testing to catch OS-specific quirks (vendor-specific builds, kernel configs, systemd defaults)

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
