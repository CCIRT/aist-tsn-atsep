#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT

# Calculates statistical information on frame latency from a pcap file and files containing assigned eligibility times.
# Usage:
#   ./calc_latency.sh <input.pcap> <AET file for port 11111> <AET file for port 22222>
#   ./calc_latency.sh <input.pcap> <AET file for port 11111> <AET file for port 22222> <raw latency file for port 11111> <raw latency file for port 22222>

SCRIPT_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"

FILE=$1
AETFILE1=$2
AETFILE2=$3
RAW_LATENCY_FILE1=${4:-}
RAW_LATENCY_FILE2=${5:-}

PORT1FILE="$FILE.11111.txt"
PORT2FILE="$FILE.22222.txt"

# Check if the number of arguments is 3 or 5
if [[ $# -ne 3 && $# -ne 5 ]]; then
    echo "Usage: $0 <pcap file> <AET file 1> <AET file 2> [raw latency file 1] [raw latency file 2]"
    exit 1
fi

# if the file does not end with .pcap, then exit
if [[ $FILE != *.pcap ]]; then
    echo "File does not end with .pcap"
    exit 1
fi

tcpdump -nr "$FILE" -tt --nano udp port 11111 2> /dev/null | cut -f1 -d' ' > "$PORT1FILE"
tcpdump -nr "$FILE" -tt --nano udp port 22222 2> /dev/null | cut -f1 -d' ' > "$PORT2FILE"

echo "## ATS1"
echo ""
ats1_output=$(python3 "$SCRIPT_DIR/_calc_latency.py" "$PORT1FILE" "$AETFILE1")
if [[ -n "$RAW_LATENCY_FILE1" ]]; then
    printf '%s\n' "$ats1_output" | grep diff | awk '{print $7}' > "$RAW_LATENCY_FILE1"
fi
printf '%s\n' "$ats1_output" | tail -n 13
echo '--------------------------------------'
echo ""
echo "## ATS2"
echo ""
ats2_output=$(python3 "$SCRIPT_DIR/_calc_latency.py" "$PORT2FILE" "$AETFILE2")
if [[ -n "$RAW_LATENCY_FILE2" ]]; then
    printf '%s\n' "$ats2_output" | grep diff | awk '{print $7}' > "$RAW_LATENCY_FILE2"
fi
printf '%s\n' "$ats2_output" | tail -n 13