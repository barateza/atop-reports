#!/bin/bash
###############################################################################
# Ubuntu 24 Test Machine - Complete Fixture Generation & Testing Script
# 
# Purpose: Generate all Plesk OS fixtures and run Docker Compose tests
# Platform: Ubuntu 24.04 LTS (4vCPU, 16GB RAM, 50GB disk)
# Duration: ~2-4 hours for Stage 1 (Recommended), ~6-8 hours for full run
#
# Prerequisites (already installed on your machine):
#   - Docker 28.2.2 ✅
#   - Docker Compose 1.29.2 ✅
#   - Lima (latest) ✅
#   - Git ✅
#
# Usage:
#   chmod +x ubuntu24-full-test.sh
#   ./ubuntu24-full-test.sh
###############################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================================================${NC}"
echo -e "${BLUE}  atop-reports.sh - Full Plesk OS Test Suite${NC}"
echo -e "${BLUE}  Ubuntu 24.04 Test Machine${NC}"
echo -e "${BLUE}================================================================${NC}"
echo ""

# Step 1: Verify Prerequisites
echo -e "${YELLOW}[1/5] Verifying prerequisites...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}ERROR: Docker not found${NC}"
    exit 1
fi
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}ERROR: Docker Compose not found${NC}"
    exit 1
fi
if ! command -v limactl &> /dev/null; then
    echo -e "${RED}ERROR: Lima not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ All prerequisites verified${NC}"
echo ""

# Step 2: Verify we're in the right directory
echo -e "${YELLOW}[2/5] Verifying repository structure...${NC}"
if [ ! -f "atop-reports.sh" ] || [ ! -d "tests" ]; then
    echo -e "${RED}ERROR: Must run from atop-reports repository root${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Repository structure verified${NC}"
echo ""

# Step 3: Generate fixtures
echo -e "${YELLOW}[3/5] Generating fixtures (this will take 2-4 hours)...${NC}"
echo -e "${BLUE}Stages:${NC}"
echo -e "  ${GREEN}[RECOMMENDED]${NC} Stage 1: 6 OSes (Ubuntu 24/22, Debian 13, AlmaLinux 10/9, CentOS 7)"
echo -e "  ${BLUE}[EXTENDED]${NC}   Stage 2: 10 OSes (Ubuntu 20/18, Debian 12/11, AlmaLinux 8, CloudLinux 9/8/7, Rocky 8)"
echo ""

cd tests

# Check if we should regenerate or use existing
if ls fixtures/*.raw 1> /dev/null 2>&1; then
    echo -e "${YELLOW}Found existing fixtures:${NC}"
    ls -lh fixtures/*.raw | awk '{print "  " $9 " (" $5 ")"}'
    echo ""
    read -p "Regenerate all fixtures? (y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Skipping fixture generation, using existing files${NC}"
    else
        ./generate-all-fixtures.sh
    fi
else
    ./generate-all-fixtures.sh
fi

cd ..

echo -e "${GREEN}✓ Fixture generation complete${NC}"
echo ""

# Step 4: Verify fixtures
echo -e "${YELLOW}[4/5] Verifying generated fixtures...${NC}"
FIXTURE_COUNT=$(ls tests/fixtures/*.raw 2>/dev/null | wc -l)
echo -e "${BLUE}Total fixtures: $FIXTURE_COUNT${NC}"

if [ "$FIXTURE_COUNT" -lt 6 ]; then
    echo -e "${RED}WARNING: Expected at least 6 fixtures (Recommended tier)${NC}"
    echo -e "${RED}Found: $FIXTURE_COUNT${NC}"
    echo -e "${YELLOW}Continuing anyway...${NC}"
else
    echo -e "${GREEN}✓ Fixture count meets Recommended tier minimum${NC}"
fi

echo ""
echo -e "${BLUE}Generated fixtures:${NC}"
ls -lh tests/fixtures/*.raw | awk '{print "  " $9 " (" $5 ")"}'
echo ""

# Step 5: Run Docker Compose tests
echo -e "${YELLOW}[5/5] Running Docker Compose test suite...${NC}"
echo -e "${BLUE}This will test all fixtures against their respective OS versions${NC}"
echo ""

# Ask user if they want to run all tests or specific tier
echo -e "Test options:"
echo -e "  ${GREEN}1)${NC} Run all tests (full suite)"
echo -e "  ${GREEN}2)${NC} Run Recommended tier only (7 OSes)"
echo -e "  ${GREEN}3)${NC} Run specific service"
echo -e "  ${GREEN}4)${NC} Skip tests"
echo ""
read -p "Select option (1-4): " -n 1 -r
echo ""

case $REPLY in
    1)
        echo -e "${BLUE}Running full test suite...${NC}"
        docker-compose up --abort-on-container-exit
        ;;
    2)
        echo -e "${BLUE}Running Recommended tier tests...${NC}"
        docker-compose run --rm test-noble       # Ubuntu 24.04
        docker-compose run --rm test-alma10      # AlmaLinux 10
        docker-compose run --rm test-debian13    # Debian 13
        docker-compose run --rm test-alma9       # AlmaLinux 9 (RHEL 9 proxy)
        docker-compose run --rm test-jammy       # Ubuntu 22.04
        docker-compose run --rm test-centos7     # CentOS 7
        ;;
    3)
        echo -e "${BLUE}Available services:${NC}"
        docker-compose config --services | sed 's/^/  /'
        echo ""
        read -p "Enter service name: " SERVICE_NAME
        docker-compose run --rm "$SERVICE_NAME"
        ;;
    4)
        echo -e "${YELLOW}Skipping tests${NC}"
        ;;
    *)
        echo -e "${RED}Invalid option${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  Test suite complete!${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "${BLUE}Summary:${NC}"
echo -e "  Fixtures generated: $FIXTURE_COUNT"
echo -e "  Tests executed: Check output above for pass/fail status"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "  1. Review test results above"
echo -e "  2. Check logs in /var/log/atop-resource-alerts.log (if running monitoring)"
echo -e "  3. Deploy to production servers if all tests pass"
echo ""
echo -e "${BLUE}Useful commands:${NC}"
echo -e "  ${GREEN}# Run specific test${NC}"
echo -e "  docker-compose run --rm test-noble"
echo ""
echo -e "  ${GREEN}# View fixture details${NC}"
echo -e "  ls -lh tests/fixtures/*.raw"
echo ""
echo -e "  ${GREEN}# Regenerate single fixture${NC}"
echo -e "  cd tests && ./generate-all-fixtures.sh --os ubuntu --version 24.04"
echo ""
