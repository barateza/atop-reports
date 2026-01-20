#!/bin/bash
# Quick reference for Ubuntu 24 test machine deployment

# 1. Clone repository (if not already done)
git clone <repository-url> atop-reports
cd atop-reports

# 2. Make test script executable
chmod +x ubuntu24-full-test.sh

# 3. Run complete test suite
./ubuntu24-full-test.sh

# OR run manually step-by-step:

# Generate fixtures (2-4 hours)
cd tests
./generate-all-fixtures.sh
cd ..

# Verify fixtures
ls -lh tests/fixtures/*.raw

# Run Docker tests
docker-compose up --abort-on-container-exit

# Run specific tier tests
docker-compose run --rm test-noble       # Ubuntu 24.04 [RECOMMENDED]
docker-compose run --rm test-alma10      # AlmaLinux 10 [RECOMMENDED]
docker-compose run --rm test-debian13    # Debian 13 [RECOMMENDED]
docker-compose run --rm test-cloudlinux9 # CloudLinux 9 [RECOMMENDED]
docker-compose run --rm test-alma9       # AlmaLinux 9 [RECOMMENDED] (RHEL 9 proxy)
docker-compose run --rm test-jammy       # Ubuntu 22.04 [RECOMMENDED]
docker-compose run --rm test-centos7     # CentOS 7 [RECOMMENDED]

# Regenerate specific fixture
cd tests
./generate-all-fixtures.sh --os ubuntu --version 24.04
cd ..

# Check test results
docker-compose logs test-noble
