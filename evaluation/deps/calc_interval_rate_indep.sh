#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT

# Calculates statistical information on frame intervals from a given pcap file and computes the receive rate of two flows (UDP port 11111 and 22222).
# Usage: ./calc_interval_rate.sh <input.pcap>

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

INPUT=$1

echo "## ATS1"
echo ""
tcpdump -nr "$INPUT" --nano udp port 11111 2> /dev/null | python3 "$SCRIPT_DIR/_calc_interval_stats.py"
echo '--------------------------------------'
echo ""
echo "## ATS2"
echo ""
tcpdump -nr "$INPUT" --nano udp port 22222 2> /dev/null | python3 "$SCRIPT_DIR/_calc_interval_stats.py"
