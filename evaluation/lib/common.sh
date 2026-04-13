#!/bin/bash
# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
set -euo pipefail

###############################################################
check_rootpriv() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "err: this script must be run as root"
    exit 1
  fi
}

# check if CPUs that are actually isolated are the same as the ones that are intended to be isolated
check_isolcpus() {
  if [ -f "$ISOLATEDCPUSFILE" ]; then
    ACTUAL_ISOLCPUS_LIST=$(tr -d ' \n' < "$ISOLATEDCPUSFILE")
    if [ "$ACTUAL_ISOLCPUS_LIST" != "$TARGET_ISOLCPUS_LIST" ]; then
      echo "err: isolcpus is not set to $TARGET_ISOLCPUS_LIST (actual: $ACTUAL_ISOLCPUS_LIST)"
      exit 1
    fi
  else
    echo "warning: $ISOLATEDCPUSFILE does not exist"
  fi
}

check_irqbalance() {
  # check if no options are set in /etc/default/irqbalance
  if [ -f "$IRQBALANCEFILE" ]; then
    if grep -q -e '^IRQBALANCE_BANNED_CPUS=.*' "$IRQBALANCEFILE"; then
      echo "err: irqbalance has banned CPUs set"
      exit 1
    fi

    if grep -q -e '^IRQBALANCE_BANNED_CPULIST=.*' "$IRQBALANCEFILE"; then
      echo "err: irqbalance has banned CPUs list set"
      exit 1
    fi

    if grep -q -e '^IRQBALANCE_ARGS=.*' "$IRQBALANCEFILE"; then
      echo "err: irqbalance has additional arguments set"
      exit 1
    fi
  else
    echo "err: $IRQBALANCEFILE does not exist"
    exit 1
  fi
}


check_cpupower() {
  for file in $SCALINGGOVERNORFILE; do
    if [ "$(cat "$file")" != "performance" ]; then
      echo "err: scaling governor is not set to performance"
      exit 1
    fi
  done
}
###############################################################

######################### EEE #################################
set_eee_netns() {
  # set Energy Efficient Ethernet (EEE) to off
  ip netns exec "$TX_NETNS_NAME" ethtool --set-eee "$TX_IF" eee off
  ip netns exec "$RX_NETNS_NAME" ethtool --set-eee "$RX_IF" eee off
}

set_eee_tx() {
  # set Energy Efficient Ethernet (EEE) to off
  ethtool --set-eee "$TX_IF" eee off
}

set_eee_rx() {
  # set Energy Efficient Ethernet (EEE) to off
  ethtool --set-eee "$RX_IF" eee off
}
###############################################################

######################### NETNS ###############################
create_netns() {
  ip netns add "$TX_NETNS_NAME"
  ip netns add "$RX_NETNS_NAME"
  ip link set "$TX_IF" netns "$TX_NETNS_NAME"
  ip link set "$RX_IF" netns "$RX_NETNS_NAME"

  ip netns exec "$TX_NETNS_NAME" ip addr add dev "$TX_IF" "$TX_IP"/"$TX_SUBNET"
  ip netns exec "$RX_NETNS_NAME" ip addr add dev "$RX_IF" "$RX_IP"/"$RX_SUBNET"

  ip netns exec "$TX_NETNS_NAME" ip link set dev "$TX_IF" up
  ip netns exec "$RX_NETNS_NAME" ip link set dev "$RX_IF" up
}

check_netns() {
  if ! ip netns exec "$TX_NETNS_NAME" true 2>/dev/null; then
    # err: netns $TX_NETNS_NAME does not exist
    return 1
  fi

  if ! ip netns exec "$RX_NETNS_NAME" true 2>/dev/null; then
    # err: netns $RX_NETNS_NAME does not exist
    return 1
  fi
}

# check_counterpart_script [self_script_path]
check_counterpart_script() {
  local self_script_path="${1:-$0}"
  local use_netns="${USE_NETNS:-false}"

  if [[ "$use_netns" != true ]]; then
    return 0
  fi

  local self_dir self_name counterpart_name counterpart_path
  self_dir="$(cd -- "$(dirname -- "$self_script_path")" && pwd -P)"
  self_name="$(basename -- "$self_script_path")"

  case "$self_name" in
    *.rx_stats.sh)
      counterpart_name="${self_name%.rx_stats.sh}.tx.sh"
      ;;
    *.tx.sh)
      counterpart_name="${self_name%.tx.sh}.rx_stats.sh"
      ;;
    *)
      echo "err: cannot infer counterpart script from name: ${self_name}" >&2
      echo "err: expected suffix .rx_stats.sh or .tx.sh" >&2
      return 1
      ;;
  esac

  counterpart_path="${self_dir}/${counterpart_name}"

  if [[ -e "$counterpart_path" ]]; then
    # echo ">>> counterpart script found: ${counterpart_path}"
    return 0
  fi

  echo "err: counterpart script not found: ${counterpart_path}" >&2
  echo "err: when the network-namespace-isolated mode is used, place tx/rx script (symlink) in the same experiment directory." >&2
  return 1
}


###############################################################

######################### QDISC ###############################
# qdisc_netns offload_option etf_delta
# offload_option: boolean
# etf_delta: number in nanosecond
qdisc_netns() {
    local offload_option=()
    if [[ $1 == true ]]; then
      offload_option=("offload")
    fi
    local etf_delta="$2"
    set +e
    echo ">>> deleting existing qdisc on $TX_IF if exists. Ignore 'Error: Cannot delete qdisc with handle of zero.' error message if it appears."
    ip netns exec "$TX_NETNS_NAME" tc qdisc del dev "$TX_IF" root
    set -e

    ip netns exec "$TX_NETNS_NAME" tc qdisc replace dev "$TX_IF" parent root handle 100 mqprio  \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@1 2@2 hw 0

    ip netns exec "$TX_NETNS_NAME" tc qdisc add dev "$TX_IF" parent 100:1 etf   \
        "${offload_option[@]}" clockid CLOCK_TAI delta "${etf_delta}"

    ip netns exec "$TX_NETNS_NAME" tc qdisc add dev "$TX_IF" parent 100:2 etf   \
        "${offload_option[@]}" clockid CLOCK_TAI delta "${etf_delta}"
}

# qdisc_host offload_option etf_delta
# offload_option: boolean
# etf_delta: number in nanosecond
qdisc_host() {
    local offload_option=()
    if [[ $1 == true ]]; then
      offload_option=("offload")
    fi
    local etf_delta="$2"
    set +e
    echo ">>> deleting existing qdisc on $TX_IF if exists. Ignore 'Error: Cannot delete qdisc with handle of zero.' error message if it appears."
    tc qdisc del dev "$TX_IF" root
    set -e

    tc qdisc replace dev "$TX_IF" parent root handle 100 mqprio  \
        num_tc 3 \
        map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
        queues 1@0 1@1 2@2 hw 0

    tc qdisc add dev "$TX_IF" parent 100:1 etf   \
        "${offload_option[@]}" clockid CLOCK_TAI delta "${etf_delta}"

    tc qdisc add dev "$TX_IF" parent 100:2 etf   \
        "${offload_option[@]}" clockid CLOCK_TAI delta "${etf_delta}"
}
###############################################################

######################### RING BUFFER #########################
tx_ringbuffer_netns() {
  ip netns exec "$TX_NETNS_NAME" ethtool -G "$TX_IF" tx 4096 rx 4096
}

tx_ringbuffer_host() {
  ethtool -G "$TX_IF" tx 4096 rx 4096
}
###############################################################

######################### ARP TABLE ###########################
tx_arptable_netns() {
  echo ">>> adding ARP entry. Ignore 'RTNETLINK answers: File exists' error message if it appears."
  set +e
  ip netns exec "$TX_NETNS_NAME" ip n add "$RX_IP" dev "$TX_IF" lladdr "$RX_IF_MAC" nud permanent
  set -e
}

tx_arptable_host() {
  echo ">>> adding ARP entry. Ignore 'RTNETLINK answers: File exists' error message if it appears."
  set +e
  ip n add "$RX_IP" dev "$TX_IF" lladdr "$RX_IF_MAC" nud permanent
  set -e
}
###############################################################

######################### RECEIVER ############################
ats_recv_netns() {
  ip netns exec "$RX_NETNS_NAME" nc -u -l -k -p 11111 &
  NC1_PID=$!
}
ats_recv_netns2() {
  ip netns exec "$RX_NETNS_NAME" nc -u -l -k -p 22222 &
  NC2_PID=$!
}

ats_recv_host() {
  nc -u -l -k -p 11111 &
  NC1_PID=$!
}
###############################################################

######################### CLOCK SYNC ##########################
# sync tx phc to rx phc and system clock using phc2sys
# usage: clocksync_phc2sys_all sender_clockid receiver_clockid
clocksync_phc2sys_all() {
  $PHC2SYS_BIN -s "/dev/ptp$1" -c "/dev/ptp$2" -c CLOCK_REALTIME -O 0 -m --step_threshold=1 > "${PREFIX}phc2sys.log" 2>&1 &
  PHC2SYS_PID=$!
}

# sync tx phc to rx phc using ts2phc
# usage: clocksync_ts2phc sender_clockid receiver_clockid
clocksync_ts2phc() {
  cat "$TS2PHC_CONFIG_TEMPLATE" | sed "s|master_placeholder|/dev/ptp$1|" | sed "s|sink_placeholder|/dev/ptp$2|" > "$TS2PHC_CONFIG"
  $TS2PHC_BIN -c "/dev/ptp$2" -l 7 -f "$TS2PHC_CONFIG" -m -q > ${PREFIX}ts2phc.log 2>&1 &
  TS2PHC_PID=$!
}

# sync tx phc to system clock using phc2sys
# usage: clocksync_phc2sys sender_clockid
clocksync_phc2sys() {
  $PHC2SYS_BIN -s "/dev/ptp$1" -c CLOCK_REALTIME -O 0 -m --step_threshold=1 > "${PREFIX}phc2sys.log" 2>&1 &
  PHC2SYS_PID=$!
}
###############################################################

######################### CONTROL #############################
nc_recv() {
  USE_NETNS=${USE_NETNS:-false}
  local port="$1"
  local netnsname="$2"
  if [[ $USE_NETNS == true ]]; then
    ip netns exec "$netnsname" nc -l -p "$port"
  else
    nc -l -p "$port"
  fi
}

nc_send() {
  USE_NETNS=${USE_NETNS:-false}
  local host="$1"
  local port="$2"
  local netnsname="$3"
  if [[ $USE_NETNS == true ]]; then
    ip netns exec "$netnsname" nc "$host" "$port"
  else
    nc "$host" "$port"
  fi
}
###############################################################

######################### MISC ################################
# process_live_check target_pid
# returns 0 if alive, 1 if not
process_live_check() {
  kill -0 "$1" 2>/dev/null
}

# warmup command
warmup_ats_netns() {
  ip netns exec "$TX_NETNS_NAME" "$ATS_BIN" -I "$TX_IF" -d "$RX_IP" -D 11111 -S 11111 -p 3 -c "$CPU_ATS1" -n 50000 -r 900000000 
}
warmup_ats_host() {
  "$ATS_BIN" -I "$TX_IF" -d "$RX_IP" -D 11111 -S 11111 -p 3 -c "$CPU_ATS1" -n 50000 -r 900000000
}

safe_stty_sane() {
  [[ -t 0 ]] && stty sane
}

######################### CSV ################################
# extract_horizontal_stats_line <stats_output_string>
# Extracts the tab-delimited values line from the Horizontal format block.
extract_horizontal_stats_line() {
  local stats_output="$1"
  printf '%s\n' "$stats_output" | awk '/^Mean\tMedian\tMax\tMin\tMax-Min\tSD$/{getline; print; exit}'
}

# extract_horizontal_stats_line_n <stats_output_string> <index>
# Extracts the Nth tab-delimited values line from Horizontal format blocks.
extract_horizontal_stats_line_n() {
  local stats_output="$1"
  local index="${2:-1}"
  printf '%s\n' "$stats_output" | awk -v idx="$index" '/^Mean\tMedian\tMax\tMin\tMax-Min\tSD$/{c++; if (c==idx) {getline; print; exit}}'
}

# csv_escape <string>
# Wraps the string in double quotes and escapes internal double quotes.
csv_escape() {
  local s="$1"
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

# write_csv_header_if_needed <csv_file> <header_line>
# Creates csv_file with header_line if the file does not already exist.
write_csv_header_if_needed() {
  local csv_file="$1"
  local header="$2"
  if [[ ! -e "$csv_file" ]]; then
    printf '%s\n' "$header" > "$csv_file"
  fi
}
###############################################################