#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT

# Calculates statistical information and receive rates for the overlapping interval of two flows, based on frame intervals from a given pcap file.
# Usage: ./calc_interval_rate_2flows.sh <input.pcap>

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

INPUT=$1


echo "-------------Input file: $INPUT------------"
tcpdump -r "$INPUT" --nano | python3 "$SCRIPT_DIR/_calc_interval_stats.py" -rr
echo '-------------------------------------------'
