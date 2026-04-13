#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
set -euo pipefail

###############################################################
#
###############################################################

oldIFS=${IFS:-}

# load configs
BASE_DIR="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
export BASE_DIR

if [[ ! -e "${BASE_DIR}/configs/defaults.conf" ]] || [[ ! -e "${BASE_DIR}/lib/common.sh" ]]; then
  echo ">>> err: required config or lib cannot be resolved."
  echo ">>> Either place a symlink in the working directory that points to the actual file in the repo's evaluation directory, or use the file directly from the evaluation directory."
  exit 1
fi

source "${BASE_DIR}/configs/defaults.conf"
source "${BASE_DIR}/lib/common.sh"

###############################################################


cleanup() {
  IFS=${oldIFS}
  echo ">>> cleaning up"
  if [[ -n "${PHC2SYS_PID:-}" ]]; then
    sudo kill -15 "${PHC2SYS_PID}" 
    echo $?
    echo ">>> killed ${PHC2SYS_PID} (phc2sys)"
    PHC2SYS_PID=""
  fi

  if [[ -n "${TS2PHC_PID:-}" ]]; then
    sudo kill -15 "${TS2PHC_PID}" 
    echo $?
    echo ">>> killed ${TS2PHC_PID} (ts2phc)"
    TS2PHC_PID=""
  fi

  if [[ -n "${NC1_PID:-}" ]]; then
    sudo kill -15 "${NC1_PID}" 
    echo $?
    echo ">>> killed ${NC1_PID} (nc 11111)"
    NC1_PID=""
  fi

  if [[ -n "${NC2_PID:-}" ]]; then
    sudo kill -15 "${NC2_PID}" 
    echo $?
    echo ">>> killed ${NC2_PID} (nc 22222)"
    NC2_PID=""
  fi

  if [[ -n "${TCPDUMP_PID:-}" ]]; then
    sudo kill -15 "${TCPDUMP_PID}" 
    echo $?
    echo ">>> killed ${TCPDUMP_PID} (tcpdump)"
    TCPDUMP_PID=""
  fi
  stty sane

  if [[ -n "${IPERF_SERV_PID:-}" ]]; then
    sudo kill -15 "${IPERF_SERV_PID}" 
    echo $?
    echo ">>> killed ${IPERF_SERV_PID} (iperf server)"
    IPERF_SERV_PID=""
  fi
  stty sane

  if [[ -n "${IPERF_CLIE_PID:-}" ]]; then
    if process_live_check "$IPERF_CLIE_PID"; then
      sudo kill -15 "${IPERF_CLIE_PID}" 
      echo $?
      echo ">>> killed ${IPERF_CLIE_PID} (iperf client)"
      IPERF_CLIE_PID=""
    else 
      echo ">>> ${IPERF_CLIE_PID} already dead"
    fi
  fi
}
trap cleanup EXIT

###############################################################

SCRIPT_NAME=$(basename "$0")
show_usage() {
  local exit_code=${1:-0}
  trap - EXIT
  cat <<EOF
Receiving-side script for contention delay evaluation with two competing ATS flows, each assigned to a different traffic class.
Note: This script only supports the network-namespace-isolated mode (single host); two-host mode is not available.

Usage: ${SCRIPT_NAME} [-h] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -p PREFIX        Output file prefix (default: ${DEFAULT_PREFIX})
  -P CONTROLPORT   Port number used by control messages (default: ${DEFAULT_CONTROLPORT})
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
EOF
  exit "$exit_code"
}

USE_NETNS=true # constant
# Centralized defaults. show_usage must refer to DEFAULT_* values.
DEFAULT_PREFIX="result_secV-D1"
DEFAULT_CONTROLPORT=9000

PREFIX=""
CONTROLPORT=$DEFAULT_CONTROLPORT
USER_CONF_PATH=""

while getopts "p:P:c:h" opt; do
  case "$opt" in
    p) PREFIX="$OPTARG" ;;
    P) CONTROLPORT=$OPTARG ;;
    c) USER_CONF_PATH="$OPTARG" ;;
    h) show_usage 0 ;;
    *) show_usage 1 ;;
  esac
done

if [[ -z "$USER_CONF_PATH" ]]; then
  echo "err: user config file must be specified with -c"
  exit 1
fi

if [[ ! -e "$USER_CONF_PATH" ]]; then
  echo "err: user config file not found: $USER_CONF_PATH"
  exit 1
fi

# shellcheck source=/dev/null
source "$USER_CONF_PATH"

check_counterpart_script "$0" || exit 1

if [ -n "$PREFIX" ]; then
  if [[ "$PREFIX" != *"." ]]; then
    PREFIX="${PREFIX}."
  fi
else
  PREFIX="${DEFAULT_PREFIX}."
fi

#################### env ######################################

check_rootpriv
echo ">>> root privilege check ok"
check_irqbalance
echo ">>> irqbalance check ok"

#################### netns ####################################

echo ">>> waiting for tx side to set up netns..."
while true; do
  if check_netns; then
    echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME found"
    break
  fi
  echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME not found, retrying in 5 second..."
  sleep 5
done

#################### EEE ######################################

# pass

#################### qdisc ####################################

# pass

#################### ring buffer ##############################

# pass

#################### arp table ################################

# pass

#################### clock sync ###############################

# pass

#################### proceed check ############################

# pass

#################### receiver #################################

ats_recv_netns
ats_recv_netns2
sleep 1
echo ">>> $RX_NETNS_NAME receiver started"

#################### warmup run ###############################

# pass

#################### ATS run ##################################

echo ">>> waiting for tx side..."

exec 3< <(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME")
IFS= read -r -d '' SCRIPT_VERSION <&3
IFS= read -r -d '' WITH_SP <&3
IFS= read -r -d '' USE_TS2PHC_META <&3
IFS= read -r -d '' TARGET_ISOLCPUS_LIST_META <&3
IFS= read -r -d '' CPU_ATS1_META <&3
IFS= read -r -d '' CPU_ATS2_META <&3
IFS= read -r -d '' CPU_IPERF_META <&3
IFS= read -r -d '' PRIO_ATS1_META <&3
IFS= read -r -d '' PRIO_ATS2_META <&3
IFS= read -r -d '' RATE_IPERF_META <&3
IFS= read -r -d '' tx_command  <&3
exec 3<&-
IFS=${oldIFS}

if [[ $WITH_SP == true ]]; then
  PREFIX="${PREFIX}withSP.sp${RATE_IPERF_META}bps."
else
  PREFIX="${PREFIX}noSP."
fi

# find existing files and extract numbers to determine the next file count
numbers=$(find . -maxdepth 1 -type f -name "${PREFIX}*.tc7_tc6.pcap" 2>/dev/null \
          | sed -n "s/^\.\/${PREFIX}\([0-9]\+\)\.tc7_tc6\.pcap$/\1/p")
if [[ -z $numbers ]]; then
  count=1
else
  count=$(printf '%s\n' "$numbers" | sort -n | tail -n1)
  count=$((count + 1)) # increment the count
fi

STATSFILE="${PREFIX}stats.log"
CSVFILE="${PREFIX}csv"
PCAPFILE="${PREFIX}${count}.tc7_tc6.pcap"
IPERFLOG="${PREFIX}${count}.iperf3.log"
AET1FILE="${PREFIX}${count}.tc7.aet.txt"
AET2FILE="${PREFIX}${count}.tc6.aet.txt"
LATENCY_TC7_FILE="${PREFIX}${count}.tc7.latency.txt"
LATENCY_TC6_FILE="${PREFIX}${count}.tc6.latency.txt"

write_csv_header_if_needed "$CSVFILE" \
  "run_datetime,latency_tc7_mean_ns,latency_tc7_median_ns,latency_tc7_max_ns,latency_tc7_min_ns,latency_tc7_max_minus_min_ns,latency_tc7_sd_ns,latency_tc6_mean_ns,latency_tc6_median_ns,latency_tc6_max_ns,latency_tc6_min_ns,latency_tc6_max_minus_min_ns,latency_tc6_sd_ns,interval_tc7_mean_ns,interval_tc7_median_ns,interval_tc7_max_ns,interval_tc7_min_ns,interval_tc7_max_minus_min_ns,interval_tc7_sd_ns,interval_tc6_mean_ns,interval_tc6_median_ns,interval_tc6_max_ns,interval_tc6_min_ns,interval_tc6_max_minus_min_ns,interval_tc6_sd_ns,cpu_tc7,cpu_tc6,cpu_iperf,prio_tc7,prio_tc6,rate_iperf_bps,with_sp,use_ts2phc,isolcpus_list,script_version,tx_command,rx_command,pcap_file,aet_tc7_file,aet_tc6_file,iperf_log_file"

{
  echo "#################################################################" 
  echo "# Date: $(date)" 
  echo "# TX Command: ${tx_command}"
  echo "# RX Command: $0 $*"
  echo "#################################################################" 
} >> "$STATSFILE"


echo ">>> starting tcpdump: ${PCAPFILE}"
ip netns exec "$RX_NETNS_NAME" tcpdump -n -i "${RX_IF}" -j adapter_unsynced --nano udp port 11111 or 22222 -B 4096 -s 38 -w "$PCAPFILE" &
TCPDUMP_PID=$!
stty sane

if [[ $WITH_SP == true ]]; then
  echo ">>> starting iperf3 server: ${IPERFLOG}"
  ip netns exec "$RX_NETNS_NAME" iperf3 -s > "$IPERFLOG" 2>&1 &
  IPERF_SERV_PID=$!

  sleep 2
fi

# send ready signal to tx side
echo "READY $count" | nc_send "$TX_IP" "$CONTROLPORT" "$RX_NETNS_NAME"

# wait for sent signal from tx side
sent_str=$(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME" | head -n 1)
if [[ ! "$sent_str" == "SENT" ]]; then
  echo ">>> invalid input, exiting..."
  exit 1
fi

cleanup
trap - EXIT

echo "==============================================" | tee -a "${STATSFILE}"
echo "- PCAPFILE: ${PCAPFILE}" | tee -a "${STATSFILE}"
echo "- iperf3 server log: ${IPERFLOG}" | tee -a "${STATSFILE}"
echo "- latency raw data file (tc7): ${LATENCY_TC7_FILE}" | tee -a "${STATSFILE}"
echo "- latency raw data file (tc6): ${LATENCY_TC6_FILE}" | tee -a "${STATSFILE}"
echo "" | tee -a "${STATSFILE}" 
echo "# Calculating statistics of packet latency" | tee -a "${STATSFILE}"
echo ""
latency_output=$(bash "$CALCSTATS_LATENCY" "${PCAPFILE}" "${AET1FILE}" "${AET2FILE}" "${LATENCY_TC7_FILE}" "${LATENCY_TC6_FILE}")
printf '%s\n' "$latency_output" | tee -a "${STATSFILE}"
echo "" | tee -a "${STATSFILE}" 
echo "----------------------------------------------" | tee -a "${STATSFILE}"
echo "# Calculating statistics of received packet intervals" | tee -a "${STATSFILE}"
echo ""
interval_output=$(bash "$CALCSTATS_INDEP" "${PCAPFILE}")
printf '%s\n' "$interval_output" | tee -a "${STATSFILE}"

latency_tc7_stats_line=$(extract_horizontal_stats_line_n "$latency_output" 1)
latency_tc6_stats_line=$(extract_horizontal_stats_line_n "$latency_output" 2)
interval_tc7_stats_line=$(extract_horizontal_stats_line_n "$interval_output" 1)
interval_tc6_stats_line=$(extract_horizontal_stats_line_n "$interval_output" 2)

latency_tc7_mean=""
latency_tc7_median=""
latency_tc7_max=""
latency_tc7_min=""
latency_tc7_max_minus_min=""
latency_tc7_sd=""
if [[ -n "$latency_tc7_stats_line" ]]; then
  IFS=$'\t' read -r latency_tc7_mean latency_tc7_median latency_tc7_max latency_tc7_min latency_tc7_max_minus_min latency_tc7_sd <<< "$latency_tc7_stats_line"
  IFS=${oldIFS}
fi

latency_tc6_mean=""
latency_tc6_median=""
latency_tc6_max=""
latency_tc6_min=""
latency_tc6_max_minus_min=""
latency_tc6_sd=""
if [[ -n "$latency_tc6_stats_line" ]]; then
  IFS=$'\t' read -r latency_tc6_mean latency_tc6_median latency_tc6_max latency_tc6_min latency_tc6_max_minus_min latency_tc6_sd <<< "$latency_tc6_stats_line"
  IFS=${oldIFS}
fi

interval_tc7_mean=""
interval_tc7_median=""
interval_tc7_max=""
interval_tc7_min=""
interval_tc7_max_minus_min=""
interval_tc7_sd=""
if [[ -n "$interval_tc7_stats_line" ]]; then
  IFS=$'\t' read -r interval_tc7_mean interval_tc7_median interval_tc7_max interval_tc7_min interval_tc7_max_minus_min interval_tc7_sd <<< "$interval_tc7_stats_line"
  IFS=${oldIFS}
fi

interval_tc6_mean=""
interval_tc6_median=""
interval_tc6_max=""
interval_tc6_min=""
interval_tc6_max_minus_min=""
interval_tc6_sd=""
if [[ -n "$interval_tc6_stats_line" ]]; then
  IFS=$'\t' read -r interval_tc6_mean interval_tc6_median interval_tc6_max interval_tc6_min interval_tc6_max_minus_min interval_tc6_sd <<< "$interval_tc6_stats_line"
  IFS=${oldIFS}
fi

run_datetime=$(date '+%Y-%m-%d %H:%M:%S')
{
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$run_datetime")" \
    "$latency_tc7_mean" \
    "$latency_tc7_median" \
    "$latency_tc7_max" \
    "$latency_tc7_min" \
    "$latency_tc7_max_minus_min" \
    "$latency_tc7_sd" \
    "$latency_tc6_mean" \
    "$latency_tc6_median" \
    "$latency_tc6_max" \
    "$latency_tc6_min" \
    "$latency_tc6_max_minus_min" \
    "$latency_tc6_sd" \
    "$interval_tc7_mean" \
    "$interval_tc7_median" \
    "$interval_tc7_max" \
    "$interval_tc7_min" \
    "$interval_tc7_max_minus_min" \
    "$interval_tc7_sd" \
    "$interval_tc6_mean" \
    "$interval_tc6_median" \
    "$interval_tc6_max" \
    "$interval_tc6_min" \
    "$interval_tc6_max_minus_min" \
    "$interval_tc6_sd" \
    "$CPU_ATS1_META" \
    "$CPU_ATS2_META" \
    "$CPU_IPERF_META" \
    "$PRIO_ATS1_META" \
    "$PRIO_ATS2_META" \
    "$RATE_IPERF_META" \
    "$WITH_SP" \
    "$USE_TS2PHC_META" \
    "$(csv_escape "$TARGET_ISOLCPUS_LIST_META")" \
    "$(csv_escape "$SCRIPT_VERSION")" \
    "$(csv_escape "$tx_command")" \
    "$(csv_escape "$0 $*")" \
    "$(csv_escape "$PCAPFILE")" \
    "$(csv_escape "$AET1FILE")" \
    "$(csv_escape "$AET2FILE")" \
    "$(csv_escape "$IPERFLOG")"
} >> "$CSVFILE"
if [[ $WITH_SP == true ]]; then
  echo "" | tee -a "${STATSFILE}" 
  echo "# iperf3 server log" | tee -a "${STATSFILE}"
  echo ""
  tee -a "${STATSFILE}" < "${IPERFLOG}"
fi
echo "==============================================" | tee -a "${STATSFILE}"


