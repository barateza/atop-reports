# Fixtures Directory

This directory contains golden master atop raw log files for testing across different versions.

## Files

Generate fixtures using:
```bash
../generate-fixtures.sh
```

Expected files:
- `v2.3.0-ubuntu18.04.raw` - Ubuntu 18.04 LTS (atop 2.3.0)
- `v2.4.0-ubuntu20.04.raw` - Ubuntu 20.04 LTS (atop 2.4.0)
- `v2.7.1-ubuntu22.04.raw` - Ubuntu 22.04 LTS (atop 2.7.1)
- `v2.10.0-ubuntu24.04.raw` - Ubuntu 24.04 LTS (atop 2.10.0)

## Size

Each fixture is approximately 1-5MB (15 seconds of system data).

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
