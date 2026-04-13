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

  for i in $(seq 1 "$MAX_FLOWS"); do
    NC_PID_VAR="NC${i}_PID"
    NC_PID="${!NC_PID_VAR:-}"
    if [[ -n "${NC_PID:-}" ]]; then
      sudo kill -15 "${NC_PID}" 
      echo $?
      TMPPORTNUM="ATSPORT${i}"
      echo ">>> killed ${NC_PID} (nc ${!TMPPORTNUM})"
      unset "$NC_PID_VAR"
      safe_stty_sane
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
Sending-side script for scalability evaluation with multiple competing ATS 
flows (maximum $((MAX_FLOWS - 1))), all assigned to the same traffic class.
Note: This script only supports the network-namespace-isolated 
      mode (single host); two-host mode is not available.

Usage: ${SCRIPT_NAME} [-tSRNsdh] [-p PREFIX] [-1 ATSCPUS] [-m PDM]  
       [-n NUMPACKETS] [-b BASERATE] [-i INCREMENT] [-D DELTA] [-3 IPERF3CPU] 
       [-r RATE] [-P CONTROLPORT] -c CONF

Clock synchronization options:
  -t   
                  Use ts2phc to synchronize the sender PHC to the receiver PHC 
                  instead of phc2sys 

Output options:
  -p PREFIX
                  Output file prefix (default: ${DEFAULT_PREFIX})

ATS process options:
  -1  ATSCPUS
                  Set CPU assignment for each flow in a comma-separated list. 
                  The list can contain individual CPU numbers or ranges 
                  (e.g., "2,4,6-8"). The assignment will be repeated if the 
                  number of flows exceeds the length of the list 
                  (default: "${DEFAULT_CPUORDER_STR}")
  -S
                  Use sleep-loop mode instead of busy-waiting for sending 
                  packets in ATS processes. This may reduce packet drops at 
                  higher numbers of competing flows, but may induce jitter in 
                  packet sending intervals
  -m PDM
                  Processing Delay Max in nanoseconds. Must be a multiple of 
                  32 (default: ${DEFAULT_PDM})
  -R
                  Lock memory pages of ATS processes to prevent swapping. 
                  Requires PREEMPT_RT kernel

Flow configuration options:
  -n NUMPACKETS
                  Number of packets to be sent for the main flow (flow 1). This 
                  also acts as a base number for calculating sending duration 
                  and number of packets for other flows (default: ${DEFAULT_SENDNUM1})
  -b BASERATE
                  Base sending rate in bps for the main flow (flow 1). This 
                  also acts as a base rate for calculating sending rates for 
                  other flows (default: ${DEFAULT_BASERATE})
  -i INCREMENT
                  Rate increment in bps for each additional flow 
                  (default: ${DEFAULT_RATE_INCREMENT})

ETF qdisc options:
  -D DELTA
                  Delta value of etf qdisc in nanoseconds (default: ${DEFAULT_ETF_DELTA})
  -N
                  No offload. Unset "offload" parameter of etf qdisc

SP (iperf3) options: 
  -s
                  Run iperf3 as a competing SP flow
  -3 IPERF3CPU
                  Set CPU assignment for iperf3 client (default: ${DEFAULT_IPERFCPU})
  -r RATE
                  Set iperf3 target bitrate to RATE bps 
                  (-b option of iperf3. default: ${DEFAULT_RATE_IPERF})
                       e.g., -r 700M

Misc options:
  -P CONTROLPORT
                  Port number used by control messages (default: ${DEFAULT_CONTROLPORT})
  -c CONF
                  Path to user-specific config file to source
  -d
                  Dry run: print out rates, number of packets, and estimated 
                  sending duration for each of $MAX_FLOWS ATS flows without 
                  actually running ATS
  -h
                  Show this help message and exit

EOF
  exit "${exit_code}"
}

# Constants
MAX_FLOWS=64 # must be >=8. Could be more than 64 but untested.
FRAME_SIZE_PHY=1538
USE_NETNS=true

# Centralized defaults. show_usage must refer to DEFAULT_* values.
DEFAULT_PREFIX="result_secV-D2"
DEFAULT_CPUORDER_STR="0-3"
DEFAULT_PDM=100000
DEFAULT_PDM_RUNTIME=""
DEFAULT_ETF_DELTA=500000
DEFAULT_IPERFCPU=4
DEFAULT_RATE_IPERF=95.71M
DEFAULT_CONTROLPORT=9000
DEFAULT_SENDNUM1=100000
DEFAULT_BASERATE=10000000
DEFAULT_RATE_INCREMENT=100000
DEFAULT_USE_TS2PHC=false
DEFAULT_USE_SLEEP_MODE=false
DEFAULT_USE_PREEMPT_RT=false
DEFAULT_USE_OFFLOAD=true
DEFAULT_WITH_SP=false
DEFAULT_DRY_RUN=false
SCRIPT_VERSION="1.0.0"

USE_TS2PHC=$DEFAULT_USE_TS2PHC
PREFIX=""
CPUORDER_STR="$DEFAULT_CPUORDER_STR"
USE_SLEEP_MODE=$DEFAULT_USE_SLEEP_MODE
PDM="$DEFAULT_PDM_RUNTIME"
USE_PREEMPT_RT=$DEFAULT_USE_PREEMPT_RT
ETF_DELTA=$DEFAULT_ETF_DELTA
USE_OFFLOAD=$DEFAULT_USE_OFFLOAD
WITH_SP=$DEFAULT_WITH_SP
IPERFCPU=$DEFAULT_IPERFCPU
RATE_IPERF=$DEFAULT_RATE_IPERF
CONTROLPORT=$DEFAULT_CONTROLPORT
DRY_RUN=$DEFAULT_DRY_RUN
USER_CONF_PATH=""

# number of packets to be sent for flow 1.
SENDNUM1=$DEFAULT_SENDNUM1
# sending rate for flow 1 in bps
BASERATE=$DEFAULT_BASERATE      # 10Mbps
# rate to increase for each additional flow in bps
RATE_INCREMENT=$DEFAULT_RATE_INCREMENT  # 0.1Mbps

while getopts "tSRNsdhp:1:m:n:b:i:D:3:r:P:c:" opt; do
  case "$opt" in
    t) USE_TS2PHC=true ;;
    p) PREFIX="$OPTARG" ;;
    1) CPUORDER_STR="$OPTARG" ;;
    S) USE_SLEEP_MODE=true ;;
    m) PDM="$OPTARG" ;;
    R) USE_PREEMPT_RT=true ;;
    n) SENDNUM1="$OPTARG" ;;
    b) BASERATE="$OPTARG" ;;
    i) RATE_INCREMENT="$OPTARG" ;;
    D) ETF_DELTA="$OPTARG" ;;
    N) USE_OFFLOAD=false ;;
    s) WITH_SP=true ;;
    3) IPERFCPU="$OPTARG" ;;
    r) RATE_IPERF="$OPTARG" ;;
    P) CONTROLPORT="$OPTARG" ;;
    c) USER_CONF_PATH="$OPTARG" ;;
    d) DRY_RUN=true ;;
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

# Parse CPUORDER_STR into CPUORDER array
CPUORDER=()
oldIFS=${IFS:-}
IFS=',' read -ra PARTS <<< "$CPUORDER_STR"
for part in "${PARTS[@]}"; do
  if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    for n in $(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); do
      CPUORDER+=("$n")
    done
  elif [[ "$part" =~ ^[0-9]+$ ]]; then
    CPUORDER+=("$part")
  else
    echo "err: invalid CPUORDER_STR format: '$part'"
    exit 1
  fi
done
IFS=${oldIFS}
CPUORDERNUM=${#CPUORDER[@]}

# port number for each flow : ATSPORTN
for i in $(seq 1 $MAX_FLOWS); do
  declare "ATSPORT${i}=$((11110 + i))"
done 

# CPU assignment for each flow : ATSCPUN
for i in $(seq 1 $MAX_FLOWS); do
  index=$(( (i - 1) % CPUORDERNUM ))
  declare "ATSCPU${i}=${CPUORDER[$index]}"
done

# ATS sending rate for each flow : ATSRATEN
for i in $(seq 1 $MAX_FLOWS); do
  rate=$((BASERATE + (i - 1) * RATE_INCREMENT))
  # rate=$BASERATE
  declare "ATSRATE${i}=$rate"
done

# ATS sending duration and send number for each flow : SENDDUR_SECN and SENDNUMN
SENDDUR_SEC1=$(echo "scale=5; $FRAME_SIZE_PHY * 8 * (1000000000 / $BASERATE) * $SENDNUM1 / $NS_IN_SEC" | bc)
for i in $(seq 2 $MAX_FLOWS); do
  SENDDUR_SEC_OTHER=$(echo "scale=5; $SENDDUR_SEC1 + 1 + ($i * 0.05)" | bc)
  # echo "Flow ${i}: SENDDUR_SEC=${SENDDUR_SEC_OTHER}"
  declare "SENDDUR_SEC${i}=$SENDDUR_SEC_OTHER"
  tmpatsrate="ATSRATE${i}"
  tmpsendnum=$(echo "scale=6; $SENDDUR_SEC_OTHER * $NS_IN_SEC / ($FRAME_SIZE_PHY * 8 * (1000000000 / ${!tmpatsrate}))  "| bc)
  tmpsendnum=${tmpsendnum%.*}  # round down to integer
  declare "SENDNUM${i}=$tmpsendnum"
done

if [[ $DRY_RUN == true ]]; then
  # tsv header
  echo -e "Flow\tPort\tCPU\tRate(bps)\tNumPackets\tSendDur(s)"
  total_rate=0
  total_numpackets=0
  for i in $(seq 1 $MAX_FLOWS); do
    tmpatscpu="ATSCPU${i}"
    tmpatsrate="ATSRATE${i}"
    tmpsendnum="SENDNUM${i}"
    tmpsenddur="SENDDUR_SEC${i}"
    tmpatsport="ATSPORT${i}"
    echo -e "${i}\t${!tmpatsport}\t${!tmpatscpu}\t${!tmpatsrate}\t${!tmpsendnum}\t${!tmpsenddur}"
    total_rate=$((total_rate + ${!tmpatsrate}))
    total_numpackets=$((total_numpackets + ${!tmpsendnum}))
  done
  echo -e "TOTAL\t-\t-\t${total_rate}\t${total_numpackets}\t-"
  trap - EXIT
  exit 0
fi

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

# ETF_DELTA must be a positive integer
if ! [[ "$ETF_DELTA" =~ ^[0-9]+$ ]] || [ "$ETF_DELTA" -le 0 ]; then
  echo "err: ETF delta must be a positive integer"
  exit 1
fi

# IPERFCPU must be a non-negative integer
if ! [[ "$IPERFCPU" =~ ^[0-9]+$ ]] || [ "$IPERFCPU" -lt 0 ]; then
  echo "err: IPERF3CPU must be a non-negative integer"
  exit 1
fi

PDM_OPTION=""
if [[ -n "$PDM" ]]; then
  # PDM must be a non-negative integer
  if ! [[ "$PDM" =~ ^[0-9]+$ ]] || [ "$PDM" -lt 0 ]; then
    echo "err: PDM must be a non-negative integer"
    exit 1
  fi
  PDM_OPTION=" -M $PDM"
fi

RT_ARG=""
if [[ $USE_PREEMPT_RT == true ]]; then
  RT_ARG="-L"
fi
if [[ $USE_SLEEP_MODE == true ]]; then
  RT_ARG="${RT_ARG} -s"
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

qdisc_netns "$USE_OFFLOAD" "$ETF_DELTA"
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

#################### warm up run ##############################

echo ">>> warmup start"
echo ""

ip netns exec "$TX_NETNS_NAME" "$ATS_BIN" -I "$TX_IF" -d "$RX_IP" -D "$ATSPORT1" -S "$ATSPORT1" -p 3 -c "$ATSCPU1" -n 50000 -r 900000000 

safe_stty_sane
sleep 1
echo ""
echo ">>> warmup complete"


#################### ATS run ##################################

printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
  "$SCRIPT_VERSION" \
  "$WITH_SP" \
  "$USE_TS2PHC" \
  "$TARGET_ISOLCPUS_LIST" \
  "$CPUORDER_STR" \
  "$USE_SLEEP_MODE" \
  "$PDM" \
  "$USE_PREEMPT_RT" \
  "$ETF_DELTA" \
  "$USE_OFFLOAD" \
  "$IPERFCPU" \
  "$RATE_IPERF" \
  "$SENDNUM1" \
  "$BASERATE" \
  "$RATE_INCREMENT" \
  "$0 $*" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"
echo ">>> ats run start"

while true; do
  read -rp ">>> Enter a number of competing flows (0~$((MAX_FLOWS - 1))), excluding the main flow , or \"n\" to quit: " num_competing_flows
  if [[ "$num_competing_flows" == "n" ]]; then
    echo ">>> exiting..."
    echo "EXIT" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"
    exit 0
  fi
  if ! [[ "$num_competing_flows" =~ ^[0-9]+$ ]]; then
    echo ">>> invalid input, please enter a number"
    continue
  fi

  # num_competing_flows must be between 0 and (MAX_FLOWS - 1)
  if [ "$num_competing_flows" -lt 0 ] || [ "$num_competing_flows" -ge "$MAX_FLOWS" ]; then
    echo ">>> invalid input, please enter a number between 0 and $((MAX_FLOWS - 1))"
    continue
  fi

  echo "NUMCOMPETE $num_competing_flows" | nc_send "$RX_IP" "$CONTROLPORT" "$TX_NETNS_NAME"

  # calculate total number of packets to be sent across all flows and display it
  total_sendnum=0
  for i in $(seq 1 $((num_competing_flows + 1))); do
    tmpsendnum="SENDNUM${i}"
    total_sendnum=$((total_sendnum + ${!tmpsendnum}))
  done

  # wait for rx side to start up tcpdump and iperf3 server
  ready_str=$(nc_recv "$CONTROLPORT" "$TX_NETNS_NAME" | head -n 1)
  if [[ "$ready_str" == "READY "* ]]; then
    echo ">>> RX side is ready, starting..."
    count=${ready_str#READY }
  else
    echo ">>> RX side not ready, continuing..."
    continue
  fi
  
  # prepare command strings
  ATS_COMMAND=("ip netns exec $TX_NETNS_NAME $ATS_BIN -I $TX_IF -d $RX_IP -D $ATSPORT1 -S $ATSPORT1 -p 3 -c $ATSCPU1 -n $SENDNUM1 -r $ATSRATE1 -P -Y $PDM_OPTION $RT_ARG")
  for i in $(seq 2 $((num_competing_flows+1)) ); do
    TMPPORT="ATSPORT$i"
    TMPCPU="ATSCPU$i"
    TMPRATE="ATSRATE$i"
    TMPSENDNUMBER="SENDNUM$i"


    TMPCOMMAND="ip netns exec $TX_NETNS_NAME $ATS_BIN -I $TX_IF -d $RX_IP -D ${!TMPPORT} -S ${!TMPPORT} -p 3 -c ${!TMPCPU} -n ${!TMPSENDNUMBER} -r ${!TMPRATE} -P $PDM_OPTION $RT_ARG"
    ATS_COMMAND+=("$TMPCOMMAND")
  done

  # iperf3 client
  if [[ $WITH_SP == true ]]; then
    echo ">>> starting Strict Priority iperf3"
    ip netns exec "$TX_NETNS_NAME" iperf3 -c "$RX_IP" -u -l 1472 -b "$RATE_IPERF" -A "$IPERFCPU" -t 0 > /dev/null 2>&1 &
    IPERF_CLIE_PID=$!

    safe_stty_sane
    sleep 3
  fi

  # echo ">>> Total send number for $num_competing_flows flows: $total_sendnum packets"
  echo ">>> starting ATS run. #flows: $((num_competing_flows + 1)), #total_send_packets: $total_sendnum"
  echo ""

  # Note: start ATS processes in ascending order. This does not ensure that the main flow is always compete with other flows from beginning to end.
  # if [[ $num_competing_flows -eq 0 ]]; then
  #   ${ATS_COMMAND[0]} | grep ets | cut -f1 -d, | cut -f3 -d' ' > "${PREFIX}num_competeflow${num_competing_flows}.run${count}.aet.1.txt" 
  # else
  #   for i in $(seq 1 "$num_competing_flows"); do
  #     ${ATS_COMMAND[$i-1]} | grep ets | cut -f1 -d, | cut -f3 -d' ' > "${PREFIX}num_competeflow${num_competing_flows}.run${count}.aet.${i}.txt" &
  #   done
  #   ${ATS_COMMAND[$num_competing_flows]} | grep ets | cut -f1 -d, | cut -f3 -d' ' > "${PREFIX}num_competeflow${num_competing_flows}.run${count}.aet.$((num_competing_flows+1)).txt"
  # fi

  AET_EPOCH_FILE_PREFIX="${PREFIX}num_competeflow${num_competing_flows}.run${count}.aet"

  # start ATS processes in decending order. The main flow starts last.
  if [[ $num_competing_flows -eq 0 ]]; then
    ${ATS_COMMAND[0]} 2>/dev/null | awk -F, 'NR > 1 { print $3 }' > "${AET_EPOCH_FILE_PREFIX}.1.txt"
  else
    for i in $(seq "$num_competing_flows" -1 1); do
      ${ATS_COMMAND[$i]} 2>/dev/null | awk -F, 'NR > 1 { print $3 }' > "${AET_EPOCH_FILE_PREFIX}.$((i+1)).txt" &
    done
    ${ATS_COMMAND[0]} 2>/dev/null | awk -F, 'NR > 1 { print $3 }' > "${AET_EPOCH_FILE_PREFIX}.1.txt"
  fi

  safe_stty_sane


  sleep_second=$(echo "scale=0; 1 * (100000000 / $BASERATE) / 1 + 1 + 6" | bc)
  echo ""
  echo ">>> sleeping ${sleep_second} seconds to wait for the remaining packets to be sent..."
  sleep "$sleep_second"
  
  echo ">>> ATS run complete"
  echo ">>> killing iperf client"
  # kill iperf client
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

  safe_stty_sane

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

cleanup
trap - EXIT

