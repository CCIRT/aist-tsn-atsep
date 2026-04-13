#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
set -euo pipefail

###############################################################
#
###############################################################

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
    if process_is_alive "$IPERF_CLIE_PID"; then
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
Sending-side script for evaluation of transmit timing control of Intel i210 NIC.

Note: Intel i210 controls the transmit time of a frame in 32-ns units.
      Therefore, the user specified transmission interval will be rounded down
      to the nearest multiple of 32 ns. (See option -M to disable this behavior)

Usage: ${SCRIPT_NAME} [-NtM] [-1 ETFCPU] [-p PREFIX] [-P CONTROLPORT] 
  [-T TX_SECONDS] -c CONF

Options:
  -N              Use netns for isolating server and client. 
                  Specify this when using only single machine 
                  for evaluation. (default: false)
  -t              Use ts2phc to synchronize the sender PHC to the receiver PHC
                  instead of phc2sys. Only available in single machine setup
  -M              Do not round down the user specified transmission interval to
                  the nearest multiple of 32 ns (default: ${DEFAULT_DISABLE_ROUNDING})
  -1 ETFCPU       CPU to use for ETF flow (default: ${DEFAULT_CPU_ETF})
                      e.g., -1 2
  -p PREFIX       Output file prefix (default: ${DEFAULT_PREFIX})
  -P CONTROLPORT  Port number used by control messages (default: ${DEFAULT_CONTROLPORT})
  -T TX_SECONDS   Transmission duration (default: ${DEFAULT_TX_SECONDS} seconds)
                      e.g., -T 5
  -c CONF         Path to user-specific config file to source
  -h              Show this help message and exit
EOF
  exit "$exit_code"
}

# Centralized defaults. show_usage must refer to DEFAULT_* values.
DEFAULT_PREFIX="result_appxA-B"
DEFAULT_CPU_ETF=4
DEFAULT_CONTROLPORT=9000
DEFAULT_TX_SECONDS=10
DEFAULT_USE_NETNS=false
DEFAULT_USE_TS2PHC=false
DEFAULT_DISABLE_ROUNDING=false
SCRIPT_VERSION="1.0.0"

USE_NETNS=$DEFAULT_USE_NETNS
USE_TS2PHC=$DEFAULT_USE_TS2PHC
DISABLE_ROUNDING=$DEFAULT_DISABLE_ROUNDING
CPU_ETF=$DEFAULT_CPU_ETF
PREFIX=""
CONTROLPORT=$DEFAULT_CONTROLPORT
TX_SECONDS=$DEFAULT_TX_SECONDS
USER_CONF_PATH=""

while getopts "NtM1:p:P:T:c:h" opt; do
  case "$opt" in
    N) USE_NETNS=true ;;
    t) USE_TS2PHC=true ;;
    M) DISABLE_ROUNDING=true ;;
    1) CPU_ETF="$OPTARG" ;;
    p) PREFIX="$OPTARG" ;;
    P) CONTROLPORT="$OPTARG" ;;
    T) TX_SECONDS="$OPTARG" ;;
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

if [[ $USE_TS2PHC == true && $USE_NETNS == false ]]; then
  echo "err: ts2phc option can only be used in single machine setup."
  exit 1
fi

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

# CPU_ETF must be a non-negative integer
if ! [[ "$CPU_ETF" =~ ^[0-9]+$ ]] || [ "$CPU_ETF" -lt 0 ]; then
  echo "err: CPU_ETF must be a non-negative integer"
  exit 1
fi

# TX_SECONDS must be a positive integer
if ! [[ "$TX_SECONDS" =~ ^[0-9]+$ ]] || [ "$TX_SECONDS" -le 0 ]; then
  echo "err: TX_SECONDS must be a positive integer"
  exit 1
fi

#################### env ######################################

check_rootpriv
echo ">>> root privilege check ok"
check_isolcpus
echo ">>> isolcpus check ok"
check_cpupower
echo ">>> cpupower check ok"

#################### netns ####################################

if [[ $USE_NETNS == true ]]; then
  echo ">>> creating netns..."
  if check_netns; then
    echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME already exist"
  else
    create_netns 
    echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME created"
  fi
fi

sleep 2

#################### EEE ######################################

if [[ $USE_NETNS == true ]]; then
  set_eee_netns
  echo ">>> ${TX_IF} ${RX_IF} EEE set to off"
else 
  set_eee_tx
  echo ">>> ${TX_IF} EEE set to off"
fi

#################### qdisc ####################################

if [[ $USE_NETNS == true ]]; then
  qdisc_netns true 500000
  echo ">>> $TX_NETNS_NAME $TX_IF qdisc set"
else 
  qdisc_host true 500000
  echo ">>> $TX_IF qdisc set"
fi

sleep 1

#################### ring buffer ##############################

if [[ $USE_NETNS == true ]]; then
  tx_ringbuffer_netns
  echo ">>> $TX_NETNS_NAME $TX_IF ring buffer set"
else 
  tx_ringbuffer_host
  echo ">>> $TX_IF ring buffer set"
fi

sleep 1

#################### arp table ################################

if [[ $USE_NETNS == true ]]; then
  tx_arptable_netns
  echo ">>> $TX_NETNS_NAME $TX_IF arp table set"
else 
  tx_arptable_host
  echo ">>> $TX_IF arp table set"
fi

sleep 1


#################### clock sync ###############################

if [[ $USE_NETNS == true ]]; then
  CLOCKID_TX=$(ip netns exec "$TX_NETNS_NAME" ethtool -T "$TX_IF" | grep 'PTP Hardware Clock' | cut -d' ' -f4)
  CLOCKID_RX=$(ip netns exec "$RX_NETNS_NAME" ethtool -T "$RX_IF" | grep 'PTP Hardware Clock' | cut -d' ' -f4)

  if [[ $USE_TS2PHC == true ]]; then
    # sync tx phc to rx phc using ts2phc
    clocksync_ts2phc "$CLOCKID_TX" "$CLOCKID_RX"
    # sync tx phc to system clock using phc2sys
    clocksync_phc2sys "$CLOCKID_TX"
    echo ">>> clocksync ts2phc and phc2sys set"
    echo ">>>     - log file: ${PREFIX}ts2phc.log"
    echo ">>>     - log file: ${PREFIX}phc2sys.log"
  else
    # sync tx phc to rx phc and system clock using phc2sys
    clocksync_phc2sys_all "$CLOCKID_TX" "$CLOCKID_RX"
    echo ">>> clocksync phc2sys set"
    echo ">>>     - log file: ${PREFIX}phc2sys.log"
  fi
else 
  CLOCKID_TX=$(ethtool -T "$TX_IF" | grep 'PTP Hardware Clock' | cut -d' ' -f4)
  CLOCKID_RX=$(ethtool -T "$RX_IF" | grep 'PTP Hardware Clock' | cut -d' ' -f4)

  # sync tx phc to system clock using phc2sys
  clocksync_phc2sys "$CLOCKID_TX"
  echo ">>> clocksync phc2sys set"
  echo ">>>     - log file: ${PREFIX}phc2sys.log"
fi

echo ">>> check the above log files and wait for clock sync to stabilize before proceeding..."

#################### proceed check ############################

read -p '>>> proceed?(y/n) :' answer

if [ "$answer" != "y" ]; then
  echo "exiting..."
  exit 1
fi

#################### receiver #################################

# pass

#################### warm up run ##############################

echo ">>> warmup start"
echo ""

if [[ $USE_NETNS == true ]]; then
  ip netns exec "$TX_NETNS_NAME" "$BUSYLOOPETF_BIN" -i "$TX_IF" -c "$CPU_ETF" -B 100000 -U "$RX_IP" -I 13984 -p 90 -E -n 50000 -L 1472
else 
  "$BUSYLOOPETF_BIN" -i "$TX_IF" -c "$CPU_ETF" -B 100000 -U "$RX_IP" -I 13984 -p 90 -E -n 50000 -L 1472
fi

safe_stty_sane
sleep 1
echo ""
echo ">>> warmup complete"

#################### etf run ##################################

printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
  "$SCRIPT_VERSION" \
  "$USE_TS2PHC" \
  "$USE_NETNS" \
  "$TARGET_ISOLCPUS_LIST" \
  "$CPU_ETF" \
  "$DISABLE_ROUNDING" \
  "$0 $*" \
  | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"

echo ""
echo ">>> The evaluation will be performed for each ethernet payload size"
echo ">>>     - ETH_PAYLOAD_SIZES: ${ETH_PAYLOAD_SIZES[*]}"
echo ""

for idx in "${!ETH_PAYLOAD_SIZES[@]}"; do
  echo ">>> Current ethernet payload size: ${ETH_PAYLOAD_SIZES[$idx]} bytes"

  num_runs=0
  while true; do
    read -rp '>>> Enter the transmission interval (ns), or 'n' to move to the next ethernet payload size: ' input

    if [[ "$input" == "n" ]]; then
      echo ">>> proceeding to the next Ethernet payload size"
      printf "NEXT\0%s\0" "$idx" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"
      break
    elif ! [[ "$input" =~ ^[0-9]+$ ]]; then
      echo ">>> invalid input, please enter a number or 'n'"
      continue
    else
      if [[ $DISABLE_ROUNDING == false ]] && (( input % 32 != 0 )); then
        interval=$((input / 32 * 32 ))
        echo ">>> input is not a multiple of 32, rounding to $interval ns"
      else
        interval=$input
      fi

      tmp_frames=$(echo "1000000000 / $interval * $TX_SECONDS" | bc -l)
      num_frames=$(printf "%.0f" "$tmp_frames") # round to nearest integer

      # send both interval and num_frames with NULL as separator, and parse them on the rx side
      printf "START\0%s\0%s\0%s\0" "$interval" "$num_frames" "$TX_SECONDS"  | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"
    fi

    # wait for rx side to start up tcpdump
    ready_str=$(nc_recv "$CONTROLPORT" "$TX_NETNS_NAME" | head -n 1)
    if [[ "$ready_str" == "READY" ]]; then
      echo ">>> RX side is ready, starting..."
    else
      echo ">>> RX side not ready, continuing..."
      continue
    fi

    sleep 1

    echo ">>> starting ETF run with ethernet payload size: ${ETH_PAYLOAD_SIZES[$idx]} bytes, interval: $interval ns, frames: $num_frames"
    echo ""

    set +e
    if [[ $USE_NETNS == true ]]; then
      ip netns exec "$TX_NETNS_NAME" "$BUSYLOOPETF_BIN" -i "$TX_IF" -c "$CPU_ETF" -B 100000 -U "$RX_IP" -I "$interval" -p 90 -E -n "$num_frames" -L "${UDP_PAYLOAD_SIZES[$idx]}" 
    else 
      "$BUSYLOOPETF_BIN" -i "$TX_IF" -c "$CPU_ETF" -B 100000 -U "$RX_IP" -I "$interval" -p 90 -E -n "$num_frames" -L "${UDP_PAYLOAD_SIZES[$idx]}" 
    fi
    set -e
    echo ""

    safe_stty_sane
    sleep 1

    echo ">>> ETF run complete"

    echo ">>> waiting for RX side to finish processing..."
    echo "SENT" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"

    fin_str=$(nc_recv "$CONTROLPORT" "$TX_NETNS_NAME" | head -n 1)
    if [[ "$fin_str" == "FIN" ]]; then
      echo ">>> RX side finished processing, continuing..."
    else
      echo ">>> RX side did not finish properly, continuing..."
      continue
    fi
  done
done

echo ">>> all ethernet payload sizes complete, exiting..."


cleanup
trap - EXIT
