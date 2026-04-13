#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT

# Calculates statistical information on frame intervals from a given pcap file and computes the receive rate.
# Usage: ./calc_interval_rate.sh <input.pcap>

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

INPUT=$1

if [ -z "$INPUT" ]; then
    INPUT=$(ls -t | head -n 1)
    # check if the INPUT ends with .pcap
    if [[ ! $INPUT == *.pcap ]]; then
        echo "Usage: $0 <input.pcap>"
        exit 1
    fi
fi

tcpdump -r "$INPUT" --nano udp port 11111 2> /dev/null | python3 "$SCRIPT_DIR/_calc_interval_stats.py" -r
