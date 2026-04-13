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
Receiving-side script for CIR shaping evaluation.

Usage: ${SCRIPT_NAME} [-Nh] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -p PREFIX        Output file prefix (default: ${DEFAULT_PREFIX})
  -P CONTROLPORT   Port number used by control messages (default: ${DEFAULT_CONTROLPORT})
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
EOF
  exit "${exit_code}"
}

# Centralized defaults. show_usage must refer to DEFAULT_* values.
DEFAULT_PREFIX="result_secV-A"
DEFAULT_CONTROLPORT=9000
DEFAULT_USE_NETNS=false

USE_NETNS=$DEFAULT_USE_NETNS
PREFIX=""
CONTROLPORT=$DEFAULT_CONTROLPORT
USER_CONF_PATH=""

while getopts "Np:P:c:h" opt; do
  case "$opt" in
    N) USE_NETNS=true ;;
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

if [ -n "$PREFIX" ]; then
  if [[ "$PREFIX" != *"." ]]; then
    PREFIX="${PREFIX}."
  fi
else
  PREFIX="${DEFAULT_PREFIX}."
  if [[ $USE_NETNS == true ]]; then
    PREFIX="${PREFIX}netns."
  fi
fi

#################### env ######################################

check_rootpriv
echo ">>> root privilege check ok"
check_isolcpus
echo ">>> isolcpus check ok"
check_irqbalance
echo ">>> irqbalance check ok"
check_cpupower
echo ">>> cpupower check ok"

#################### netns ####################################

if [[ $USE_NETNS == true ]]; then
  echo ">>> waiting for tx side to set up netns..."
  while true; do
    if check_netns; then
      echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME found"
      break
    fi
    echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME not found, retrying in 5 second..."
    sleep 5
  done
fi

#################### EEE ######################################

if [[ $USE_NETNS == false ]]; then
  set_eee_rx
  echo ">>> ${RX_IF} EEE set to off"
fi

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

if [[ $USE_NETNS == true ]]; then
  ats_recv_netns
  sleep 1
  echo ">>> $RX_NETNS_NAME receiver started"
else 
  ats_recv_host
  sleep 1
  echo ">>> receiver started"
fi

#################### warmup run ##############################

# pass

#################### ats run ##################################

echo ">>> waiting for tx side to start..."

exec 3< <(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME")
IFS= read -r -d '' SCRIPT_VERSION <&3
IFS= read -r -d '' USE_TS2PHC_META <&3
IFS= read -r -d '' USE_NETNS_META <&3
IFS= read -r -d '' TARGET_ISOLCPUS_LIST_META <&3
IFS= read -r -d '' CPU_ATS1_META <&3
IFS= read -r -d '' TX_SECONDS_META <&3
IFS= read -r -d '' tx_command <&3
exec 3<&-
IFS=${oldIFS}

STATSFILE="${PREFIX}interval_stats.log"
CSVFILE="${PREFIX}csv"
write_csv_header_if_needed "$CSVFILE" \
  "run_datetime,cir_mbps,interval_mean_ns,interval_median_ns,interval_max_ns,interval_min_ns,interval_max_minus_min_ns,interval_sd_ns,cpu_ats,tx_duration_s,use_ts2phc,use_netns,isolcpus_list,script_version,tx_command,rx_command,pcap_file"

{
  echo "#################################################################" 
  echo "# Date: $(date)" 
  echo "# TX Command: ${tx_command}"
  echo "# RX Command: $0 $*"
  echo "#################################################################" 
} >> "$STATSFILE"

num_run=1
while true; do
  echo ">>> waiting for tx side to continue..."
  cir_input_str=$(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME" | head -n 1)
  if [[ "$cir_input_str" == "CIR "* ]]; then
    cir_input=${cir_input_str#CIR }
  elif [[ "$cir_input_str" == "EXIT" ]]; then
    echo ">>> exiting..."
    exit 0
  else
    echo ">>> invalid input continuing..."
    continue
  fi

  # find existing files and extract numbers to determine the next file count
  numbers=$(find . -maxdepth 1 -type f -name "${PREFIX}cir${cir_input}Mbps.dur${TX_SECONDS_META}.*.pcap" 2>/dev/null \
            | sed -n "s/^\.\/${PREFIX}cir${cir_input}Mbps\.dur${TX_SECONDS_META}\.\([0-9]\+\)\.pcap$/\1/p")
  if [[ -z $numbers ]]; then
    count=1
  else
    count=$(printf '%s\n' "$numbers" | sort -n | tail -n1)
    count=$((count + 1)) # increment the count
  fi
  PCAPFILE="${PREFIX}cir${cir_input}Mbps.dur${TX_SECONDS_META}.${count}.pcap"

  echo ">>> starting tcpdump: ${PCAPFILE}"

  if [[ $USE_NETNS == true ]]; then
    ip netns exec "$RX_NETNS_NAME" tcpdump -n -i "${RX_IF}" -j adapter_unsynced --nano udp port 11111 -B 4096 -s 38 -w "${PCAPFILE}" &
    TCPDUMP_PID=$!
  else 
    tcpdump -n -i "${RX_IF}" -j adapter_unsynced --nano udp port 11111 -B 4096 -s 38 -w "${PCAPFILE}" &
    TCPDUMP_PID=$!
  fi
  stty sane
  sleep 2

  # send ready signal to tx side
  echo "READY" | nc_send "$TX_IP" "$CONTROLPORT" "$RX_NETNS_NAME"

  # wait for sent signal from tx side
  sent_str=$(nc_recv "$CONTROLPORT" "$RX_NETNS_NAME" | head -n 1)
  if [[ ! "$sent_str" == "SENT" ]]; then
    echo ">>> invalid input, continuing..."
    continue
  fi

  if [[ -n "${TCPDUMP_PID:-}" ]]; then
    sudo kill -15 "${TCPDUMP_PID}" 
    echo $?
    echo ">>> killed ${TCPDUMP_PID} (tcpdump)"
    TCPDUMP_PID=""
  else 
    echo ">>> ${TCPDUMP_PID} already dead"
  fi
  sleep 2

  echo ">>> calculating statistics of received packet intervals"

  echo "================= RUN $num_run ======================" | tee -a "$STATSFILE"
  echo "- PCAPFILE: ${PCAPFILE}" | tee -a "$STATSFILE"
  echo "- CIR (Mbps): ${cir_input}" | tee -a "$STATSFILE"
  echo "" | tee -a "$STATSFILE" 
  set +e
  interval_output=$(bash "$CALCSTATS_RATE" "${PCAPFILE}")
  set -e
  printf '%s\n' "$interval_output" | tee -a "$STATSFILE"

  interval_stats_line=$(extract_horizontal_stats_line "$interval_output")
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

  run_datetime=$(date '+%Y-%m-%d %H:%M:%S')
  {
    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
      "$(csv_escape "$run_datetime")" \
      "$cir_input" \
      "$interval_mean" \
      "$interval_median" \
      "$interval_max" \
      "$interval_min" \
      "$interval_max_minus_min" \
      "$interval_sd" \
      "$CPU_ATS1_META" \
      "$TX_SECONDS_META" \
      "$USE_TS2PHC_META" \
      "$USE_NETNS_META" \
      "$(csv_escape "$TARGET_ISOLCPUS_LIST_META")" \
      "$(csv_escape "$SCRIPT_VERSION")" \
      "$(csv_escape "$tx_command")" \
      "$(csv_escape "$0 $*")" \
      "$(csv_escape "$PCAPFILE")"
  } >> "$CSVFILE"

  echo "==============================================" | tee -a "$STATSFILE"

  echo "FIN" | nc_send "$TX_IP" "$CONTROLPORT" "$RX_NETNS_NAME"
  num_run=$((num_run + 1))
done

cleanup
trap - EXIT

