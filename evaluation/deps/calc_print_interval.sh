#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT

# Prints frame intervals from a given pcap file.
# Usage: ./calc_print_interval.sh <input.pcap>

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

INPUT=$1

tcpdump -r "$INPUT" --nano udp port 11111 2> /dev/null | python3 "${SCRIPT_DIR}/_calc_interval_stats.py" -p
