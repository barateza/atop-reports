#!/bin/bash
# Simple fixture generator for deployed Linux machines
# (works on any Linux with atop, no VMs needed)

FIXTURE_NAME="v$(atop -V | grep -oP '\d+\.\d+\.\d+')-$(lsb_release -is)-$(lsb_release -rs).raw"
OUTPUT_DIR="${1:-.}"

echo "Generating fixture: $FIXTURE_NAME"
sudo atop -P PRG,PRC,PRM,PRD,DSK 1 15 > "$OUTPUT_DIR/$FIXTURE_NAME"

SIZE=$(du -h "$OUTPUT_DIR/$FIXTURE_NAME" | cut -f1)
echo "✓ Created: $FIXTURE_NAME ($SIZE)"