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

ats_recv_netns_scale() {
  local start=$1
  local end=$2
  for i in $(seq "$start" "$end"); do
    TMPPORT="ATSPORT$i"
    sudo ip netns exec "$RX_NETNS_NAME" nc -u -l -k -p "${!TMPPORT}" >/dev/null 2>&1 &
    declare -g "NC${i}_PID=$!"
  done
}

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

  for i in $(seq 1 "$MAX_FLOWS"); do
    NC_PID_VAR="NC${i}_PID"
    NC_PID="${!NC_PID_VAR:-}"
    if [[ -n "${NC_PID:-}" ]]; then
      sudo kill -15 "${NC_PID}" 
      echo $?
      TMPPORTNUM="ATSPORT${i}"
      echo ">>> killed ${NC_PID} (nc ${!TMPPORTNUM})"
      unset "$NC_PID_VAR"
    fi
  done

  if [[ -n "${TCPDUMP_PID:-}" ]]; then
    sudo kill -15 "${TCPDUMP_PID}" 
    echo $?
    echo ">>> killed ${TCPDUMP_PID} (tcpdump)"
    TCPDUMP_PID=""
  fi
  safe_stty_sane

  if [[ -n "${IPERF_SERV_PID:-}" ]]; then
    sudo kill -15 "${IPERF_SERV_PID}" 
    echo $?
    echo ">>> killed ${IPERF_SERV_PID} (iperf server)"
    IPERF_SERV_PID=""
  fi
  safe_stty_sane

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
Receiving-side script for scalability evaluation with multiple competing ATS 
flows (maximum ${MAX_FLOWS}), all assigned to the same traffic class.
Note: This script only supports the network-namespace-isolated 
      mode (single host); two-host mode is not available.

Usage: ${SCRIPT_NAME} [-h] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -p PREFIX        Output file prefix (default: ${DEFAULT_PREFIX})
  -P CONTROLPORT   Port number used by control messages (default: ${DEFAULT_CONTROLPORT})
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
EOF
  exit "${exit_code}"
}

# Constants
MAX_FLOWS=64 # must be >=8. Could be more than 64 but untested.
USE_NETNS=true

# Centralized defaults. show_usage must refer to DEFAULT_* values.
DEFAULT_PREFIX="result_secV-D2"
DEFAULT_CONTROLPORT=9000

PREFIX=""
CONTROLPORT=$DEFAULT_CONTROLPORT
USER_CONF_PATH=""

while getopts "p:P:c:h" opt; do
  case "$opt" in
    p) PREFIX="$OPTARG" ;;
    P) CONTROLPORT="$OPTARG" ;;
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

# port number for each flow : ATSPORTN
for i in $(seq 1 $MAX_FLOWS); do
  declare "ATSPORT${i}=$((11110 + i))"
done 

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

ats_recv_netns_scale 1 1
sleep 1
safe_stty_sane
echo ">>> $RX_NETNS_NAME receiver started"

#################### warm up run ##############################

# pass

#################### ATS run ##################################

echo ">>> waiting for tx side to start..."

exec 3< <(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME")
IFS= read -r -d '' SCRIPT_VERSION <&3
IFS= read -r -d '' WITH_SP <&3
IFS= read -r -d '' USE_TS2PHC_META <&3
IFS= read -r -d '' TARGET_ISOLCPUS_LIST_META <&3
IFS= read -r -d '' CPUORDER_STR_META <&3
IFS= read -r -d '' USE_SLEEP_MODE_META <&3
IFS= read -r -d '' PDM_META <&3
IFS= read -r -d '' USE_PREEMPT_RT_META <&3
IFS= read -r -d '' ETF_DELTA_META <&3
IFS= read -r -d '' USE_OFFLOAD_META <&3
IFS= read -r -d '' IPERFCPU_META <&3
IFS= read -r -d '' RATE_IPERF_META <&3
IFS= read -r -d '' SENDNUM1_META <&3
IFS= read -r -d '' BASERATE_META <&3
IFS= read -r -d '' RATE_INCREMENT_META <&3
IFS= read -r -d '' tx_command <&3
exec 3<&-
IFS=${oldIFS}

if [[ $WITH_SP == true ]]; then
  PREFIX="${PREFIX}withSP."
else
  PREFIX="${PREFIX}noSP."
fi

STATSFILE="${PREFIX}stats.log"
CSVFILE="${PREFIX}csv"
write_csv_header_if_needed "$CSVFILE" \
  "run_datetime,num_competing_flows,latency_mean_ns,latency_median_ns,latency_max_ns,latency_min_ns,latency_max_minus_min_ns,latency_sd_ns,interval_mean_ns,interval_median_ns,interval_max_ns,interval_min_ns,interval_max_minus_min_ns,interval_sd_ns,cpu_ats_order,cpu_iperf,num_frame_mainflow,rate_ats_base_bps,rate_ats_increment_bps,rate_iperf_bps,with_sp,use_sleep_mode,use_preempt_rt,pdm,etf_delta_ns,use_offload,use_ts2phc,isolcpus_list,script_version,tx_command,rx_command,pcap_file"

{
  echo "#################################################################" 
  echo "# Date: $(date)" 
  echo "# TX Command: ${tx_command}"
  echo "# RX Command: $0 $*"
  echo "#################################################################" 
} >> "$STATSFILE"

num_run=1
num_max_comp_flow=0
while true; do
  echo ">>> waiting for tx side to continue..."
  num_competing_flows_str=$(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME" | head -n 1)
  if [[ "$num_competing_flows_str" == "NUMCOMPETE "* ]]; then
    num_competing_flows=${num_competing_flows_str#NUMCOMPETE }
  elif [[ "$num_competing_flows_str" == "EXIT" ]]; then
    echo ">>> exiting..."
    exit 0
  else
    echo ">>> invalid input continuing..."
    continue
  fi
  

  # find existing files and extract numbers to determine the next file count
  numbers=$(find . -maxdepth 1 -type f -name "${PREFIX}num_competeflow${num_competing_flows}.run*.pcap" 2>/dev/null \
            | sed -n "s/^\.\/${PREFIX}num_competeflow${num_competing_flows}\.run\([0-9]\+\)\.pcap$/\1/p")
  if [[ -z $numbers ]]; then
    count=1
  else
    count=$(printf '%s\n' "$numbers" | sort -n | tail -n1)
    count=$((count + 1)) # increment the count
  fi
  PCAPFILE="${PREFIX}num_competeflow${num_competing_flows}.run${count}.pcap"
  IPERFLOG="${PREFIX}num_competeflow${num_competing_flows}.run${count}.iperf3.log"
  PCAP_EPOCH_FILE="${PCAPFILE}.1.txt"
  AET_EPOCH_FILE="${PREFIX}num_competeflow${num_competing_flows}.run${count}.aet.1.txt"
  LATENCY_RAW_FILE="${PREFIX}num_competeflow${num_competing_flows}.run${count}.latency.1.txt"

  if [[ $num_competing_flows -gt $num_max_comp_flow ]]; then
    # start nc listeners for new flows
    nc_start_num=$((num_max_comp_flow + 2))
    nc_end_num=$((num_competing_flows + 1))
    ats_recv_netns_scale $nc_start_num $nc_end_num
    echo ">>> $RX_NETNS_NAME additional receiver started ($nc_start_num-$nc_end_num)"
    num_max_comp_flow=$num_competing_flows
  fi

  echo ">>> starting tcpdump: ${PCAPFILE}"

  MINPORT=$ATSPORT1
  TMPMAXPORT="ATSPORT$((num_competing_flows + 1))"
  MAXPORT=${!TMPMAXPORT}
  ip netns exec "$RX_NETNS_NAME" tcpdump -n -i "$RX_IF" -j adapter_unsynced --nano udp portrange "$MINPORT-$MAXPORT" -B 4096 -s 38 -w "$PCAPFILE" &
  TCPDUMP_PID=$!
  safe_stty_sane

  if [[ $WITH_SP == true ]]; then
    echo ">>> starting iperf3 server: ${IPERFLOG}"
    ip netns exec "$RX_NETNS_NAME" iperf3 -s > "$IPERFLOG" 2>&1 &
    IPERF_SERV_PID=$!

    sleep 1
  fi
  sleep 1

  # send ready signal to tx side
  echo "READY $count" | nc_send "$TX_IP" "$CONTROLPORT" "$RX_NETNS_NAME"

  # wait for sent signal from tx side
  sent_str=$(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME" | head -n 1)
  if [[ ! "$sent_str" == "SENT" ]]; then
    echo ">>> invalid input, exiting..."
    exit 1
  fi

  # kill iperf server
  if [[ -n "${IPERF_SERV_PID:-}" ]]; then
    sudo kill -15 "${IPERF_SERV_PID}" 
    echo $?
    echo ">>> killed ${IPERF_SERV_PID} (iperf server)"
    IPERF_SERV_PID=""
  fi
  safe_stty_sane

  # kill tcpdump
  if [[ -n "${TCPDUMP_PID:-}" ]]; then
    sudo kill -15 "${TCPDUMP_PID}" 
    echo $?
    echo ">>> killed ${TCPDUMP_PID} (tcpdump)"
    TCPDUMP_PID=""
  else 
    echo ">>> tcpdump already dead"
  fi
  safe_stty_sane
  sleep 1


  echo ">>> calculating statistics of received packet intervals"

  echo "================= RUN $num_run ======================" | tee -a "$STATSFILE"
  echo "- PCAPFILE: ${PCAPFILE}" | tee -a "${STATSFILE}"
  echo "- iperf3 server log: ${IPERFLOG}" | tee -a "${STATSFILE}"
  echo "- latency raw data file: ${LATENCY_RAW_FILE}" | tee -a "${STATSFILE}"
  echo "- number of competing flows: ${num_competing_flows}" | tee -a "${STATSFILE}"
  echo "- total number of flows: $((num_competing_flows + 1))" | tee -a "${STATSFILE}"
  echo "" | tee -a "${STATSFILE}" 
  echo "# Calculating statistics of packet latency of the main flow" | tee -a "${STATSFILE}"
  echo ""
  tcpdump -nr "$PCAPFILE" -tt --nano udp port "$ATSPORT1" 2> /dev/null | cut -f1 -d' ' > "$PCAP_EPOCH_FILE"
  latency_calc_output=$(python3 "$CALCLATENCY_PY" "$PCAP_EPOCH_FILE" "$AET_EPOCH_FILE")
  printf '%s\n' "$latency_calc_output" | awk '/diff/ {print $7}' > "$LATENCY_RAW_FILE"
  latency_output=$(printf '%s\n' "$latency_calc_output" | tail -n 13)
  printf '%s\n' "$latency_output" | tee -a "${STATSFILE}"
  echo "" | tee -a "${STATSFILE}"
  echo "----------------------------------------------" | tee -a "${STATSFILE}"
  echo "# Calculating statistics of received packet intervals" | tee -a "${STATSFILE}"
  echo ""
  interval_output=$(tcpdump -nr "$PCAPFILE" --nano udp port "$ATSPORT1" 2> /dev/null | python3 "$CALCINTERVAL_PY" -r)
  printf '%s\n' "$interval_output" | tee -a "${STATSFILE}"

  interval_stats_line=$(extract_horizontal_stats_line "$interval_output")
  latency_stats_line=$(extract_horizontal_stats_line "$latency_output")

  interval_mean=""
  interval_median=""
  interval_max=""
  interval_min=""
  interval_max_minus_min=""
  interval_sd=""
  if [[ -n "$interval_stats_line" ]]; then
    IFS=$'\t' read -r interval_mean interval_median interval_max interval_min interval_max_minus_min interval_sd <<< "$interval_stats_line"
    IFS=${oldIFS}
  fi

  latency_mean=""
  latency_median=""
  latency_max=""
  latency_min=""
  latency_max_minus_min=""
  latency_sd=""
  if [[ -n "$latency_stats_line" ]]; then
    IFS=$'\t' read -r latency_mean latency_median latency_max latency_min latency_max_minus_min latency_sd <<< "$latency_stats_line"
    IFS=${oldIFS}
  fi

  run_datetime=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$run_datetime")" \
      "$num_competing_flows" \
      "$latency_mean" \
      "$latency_median" \
      "$latency_max" \
      "$latency_min" \
      "$latency_max_minus_min" \
      "$latency_sd" \
      "$interval_mean" \
      "$interval_median" \
      "$interval_max" \
      "$interval_min" \
      "$interval_max_minus_min" \
      "$interval_sd" \
      "$(csv_escape "$CPUORDER_STR_META")" \
      "$IPERFCPU_META" \
      "$SENDNUM1_META" \
      "$BASERATE_META" \
      "$RATE_INCREMENT_META" \
      "$RATE_IPERF_META" \
      "$WITH_SP" \
      "$USE_SLEEP_MODE_META" \
      "$USE_PREEMPT_RT_META" \
      "$(csv_escape "$PDM_META")" \
      "$ETF_DELTA_META" \
      "$USE_OFFLOAD_META" \
      "$USE_TS2PHC_META" \
      "$(csv_escape "$TARGET_ISOLCPUS_LIST_META")" \
      "$(csv_escape "$SCRIPT_VERSION")" \
      "$(csv_escape "$tx_command")" \
      "$(csv_escape "$0 $*")" \
      "$(csv_escape "$PCAPFILE")"
  } >> "$CSVFILE"

  if [[ $WITH_SP == true ]]; then
    echo "" | tee -a "${STATSFILE}" 
    echo "# iperf3 server log" | tee -a "${STATSFILE}"
    echo ""
    tee -a "${STATSFILE}" < "${IPERFLOG}"
  fi
  echo "==============================================" | tee -a "${STATSFILE}"

  echo ""

  echo "FIN" | nc_send "$TX_IP" "$CONTROLPORT" "$RX_NETNS_NAME"
  num_run=$((num_run + 1))
done

cleanup
trap - EXIT

