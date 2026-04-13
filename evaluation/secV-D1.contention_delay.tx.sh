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
Sending-side script for contention delay evaluation with two competing ATS flows and optional SP flow, each assigned to a different traffic class.
- ATS1         : TC7, CIR=100Mbps, CBS=1538 bytes, frame size=1538 bytes at physical layer
- ATS2         : TC6, CIR=101Mbps, CBS=1538 bytes, frame size=1538 bytes at physical layer
- SP (optional): TC5, iperf3 UDP flow with 1472 bytes payload, target bitrate specified by -r option

Note: This script only supports the network-namespace-isolated mode (single host); two-host mode is not available.

Usage: ${SCRIPT_NAME} [-tsh] [-r RATE] [-1 ATS1CPU] [-2 ATS2CPU] [-3 IPERF3CPU] [-l ATS1PRIO] [-L ATS2PRIO] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -t               Use ts2phc to synchronize the sender PHC to the receiver PHC instead of phc2sys
  -s               Run iperf3 as a competing SP flow
  -r RATE          Set iperf3 target bitrate to RATE bps (-b option of iperf3. default: ${DEFAULT_RATE_IPERF})
                       e.g., -r 0, -r 100M
  -1 ATS1CPU       CPU to use for ATS1 flow (default: ${DEFAULT_CPU_ATS1})
  -2 ATS2CPU       CPU to use for ATS2 flow (default: ${DEFAULT_CPU_ATS2})
  -3 IPERF3CPU     CPU to use for iperf3 client (default: ${DEFAULT_CPU_IPERF})
  -l ATS1PRIO      SO_PRIORITY to set for ATS1 flow (default: ${DEFAULT_PRIO_ATS1})
                       e.g., -l 3
  -L ATS2PRIO      SO_PRIORITY to set for ATS2 flow (default: ${DEFAULT_PRIO_ATS2})
                       e.g., -L 2
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
DEFAULT_RATE_IPERF=671M
DEFAULT_CPU_ATS1=2
DEFAULT_CPU_ATS2=4
DEFAULT_CPU_IPERF=6
DEFAULT_PRIO_ATS1=3
DEFAULT_PRIO_ATS2=2
DEFAULT_USE_TS2PHC=false
DEFAULT_WITH_SP=false
SCRIPT_VERSION="1.0.0"
RATE_ATS1_BPS=100000000
RATE_ATS2_BPS=101000000

USE_TS2PHC=$DEFAULT_USE_TS2PHC
WITH_SP=$DEFAULT_WITH_SP
RATE_IPERF=$DEFAULT_RATE_IPERF
CPU_ATS1=$DEFAULT_CPU_ATS1
CPU_ATS2=$DEFAULT_CPU_ATS2
CPU_IPERF=$DEFAULT_CPU_IPERF
PRIO_ATS1=$DEFAULT_PRIO_ATS1
PRIO_ATS2=$DEFAULT_PRIO_ATS2
PREFIX=""
CONTROLPORT=$DEFAULT_CONTROLPORT
USER_CONF_PATH=""


while getopts "tsr:1:2:3:l:L:p:P:c:h" opt; do
  case "$opt" in
    t) USE_TS2PHC=true ;;
    s) WITH_SP=true ;;
    r) RATE_IPERF="$OPTARG" ;;
    1) CPU_ATS1="$OPTARG" ;;
    2) CPU_ATS2="$OPTARG" ;;
    3) CPU_IPERF="$OPTARG" ;;
    l) PRIO_ATS1="$OPTARG" ;;
    L) PRIO_ATS2="$OPTARG" ;;
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

if [ -n "$PREFIX" ]; then
  if [[ "$PREFIX" != *"." ]]; then
    PREFIX="${PREFIX}."
  fi
else
  PREFIX="${DEFAULT_PREFIX}."
fi

if [[ $WITH_SP == true ]]; then
  PREFIX="${PREFIX}withSP."
else
  PREFIX="${PREFIX}noSP."
fi

if [[ $WITH_SP == true ]]; then
  AET_PREFIX="${PREFIX}sp${RATE_IPERF}bps."
else
  AET_PREFIX="$PREFIX"
fi

if ! [[ "$PRIO_ATS1" =~ ^[0-9]+$ ]] || ! [[ "$PRIO_ATS2" =~ ^[0-9]+$ ]]; then
  echo "err: SO_PRIORITY for ATS flows must be specified as numbers"
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

echo ">>> creating netns..."
if check_netns; then
  echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME already exist"
else
  create_netns 
  echo ">>> netns $TX_NETNS_NAME and $RX_NETNS_NAME created"
fi

sleep 2

#################### EEE ######################################

set_eee_netns
echo ">>> ${TX_IF} ${RX_IF} EEE set to off"

#################### qdisc ####################################

qdisc_netns true 500000
echo ">>> $TX_NETNS_NAME $TX_IF qdisc set"

sleep 1

#################### ring buffer ##############################

tx_ringbuffer_netns
echo ">>> $TX_NETNS_NAME $TX_IF ring buffer set"

sleep 1

#################### arp table ################################

tx_arptable_netns
echo ">>> $TX_NETNS_NAME $TX_IF arp table set"

sleep 1

#################### clock sync ###############################

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

echo ">>> check the above log files and wait for clock sync to stabilize before proceeding..."

#################### proceed check ############################

read -p '>>> proceed?(y/n) :' answer

if [ "$answer" != "y" ]; then
  echo "exiting..."
  exit 1
fi

#################### receiver #################################

# pass

#################### warmup run ###############################

echo ">>> warmup start"
echo ""

warmup_ats_netns

stty sane
sleep 1
echo ""
echo ">>> warmup complete"

#################### ATS run ##################################


printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
  "$SCRIPT_VERSION" \
  "$WITH_SP" \
  "$USE_TS2PHC" \
  "$TARGET_ISOLCPUS_LIST" \
  "$CPU_ATS1" \
  "$CPU_ATS2" \
  "$CPU_IPERF" \
  "$PRIO_ATS1" \
  "$PRIO_ATS2" \
  "$RATE_IPERF" \
  "$0 $*" \
  | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"
echo ">>> ats run start"


# wait for rx side to start up tcpdump and/or iperf3 server
ready_str=$(nc_recv "$CONTROLPORT" "$TX_NETNS_NAME" | head -n 1)
if [[ "$ready_str" == "READY "* ]]; then
  echo ">>> RX side is ready, starting..."
  count=${ready_str#READY }
else
  echo ">>> RX side not ready, exiting..."
  exit 1
fi

AET1FILE="${AET_PREFIX}${count}.tc7.aet.txt"
AET2FILE="${AET_PREFIX}${count}.tc6.aet.txt"

if [[ $WITH_SP == true ]]; then
  echo ">>> starting Strict Priority iperf3"
  ip netns exec "$TX_NETNS_NAME" iperf3 -c "$RX_IP" -u -l 1472 -b "$RATE_IPERF" -A "$CPU_IPERF" -t 0 > /dev/null 2>&1 &
  IPERF_CLIE_PID=$!

  stty sane
fi

sleep 3

echo ">>> starting ATS1 run with CIR (Mbps): 100, #frames: 100000, SO_PRIORITY: ${PRIO_ATS1}, CPU: ${CPU_ATS1}"
echo ">>> starting ATS2 run with CIR (Mbps): 101, #frames: 100000, SO_PRIORITY: ${PRIO_ATS2}, CPU: ${CPU_ATS2}"

echo ""
ip netns exec "$TX_NETNS_NAME" "$ATS_BIN" -I "$TX_IF" -d "$RX_IP" -D 11111 -S 11111 -p "$PRIO_ATS1" -c "$CPU_ATS1" -n 100000 -r "$RATE_ATS1_BPS" -P -y | awk -F, 'NR > 1 { print $3 }' > "$AET1FILE" & \
ip netns exec "$TX_NETNS_NAME" "$ATS_BIN" -I "$TX_IF" -d "$RX_IP" -D 22222 -S 22222 -p "$PRIO_ATS2" -c "$CPU_ATS2" -n 100000 -r "$RATE_ATS2_BPS" -P -y | awk -F, 'NR > 1 { print $3 }' > "$AET2FILE"
echo ""

stty sane
sleep 3

echo ">>> ATS run complete"

echo "SENT" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"

cleanup
trap - EXIT
