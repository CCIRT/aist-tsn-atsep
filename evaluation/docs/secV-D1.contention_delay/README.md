# secV-D1.contention_delay

## Goal

Verify that contention delay of ATS flows is bounded.

In this section, we evaluate contention delay, that is, the delay caused by frame contention at the sender-side traffic-class/priority arbiter.

To do so, we transmit two ATS flows in different traffic classes and evaluate one-way frame latency using the following formula.

- `latency = (Receiver hardware RX timestamp) - (Sender Assigned Eligibility Time set to the frame)`

Cable propagation after actual transmission is treated as constant, therefore latency variation mainly reflects contention delay.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation.

---

## Instructions Specific to Contention Delay Evaluation

### Evaluation Setup

The following three flows appear in this experiment. We evaluate the contention among these three flows.

| Flow | Traffic Class | CIR/Rate | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 | TC7 | 100 Mbps | 1,538 bytes | 1,538 bytes |
| ATS2 | TC6 | 101 Mbps | 1,538 bytes | 1,538 bytes |
| SP (optional) | TC5 | 700 Mbps (default) | 1,538 bytes | N/A |

Note: The `-b` option in iperf3 specifies the bitrate based on payload, not the physical layer rate. The value shown above is the iperf3 default rate for this script, converted into the physical layer rate.

### Usage

- Sender [`secV-D1.contention_delay.tx.sh`](../../secV-D1.contention_delay.tx.sh)

```bash
$ bash secV-D1.contention_delay.tx.sh -h
Sending-side script for contention delay evaluation with two competing ATS flows and optional SP flow, each assigned to a different traffic class.
- ATS1         : TC7, CIR=100Mbps, CBS=1538 bytes, frame size=1538 bytes at physical layer
- ATS2         : TC6, CIR=101Mbps, CBS=1538 bytes, frame size=1538 bytes at physical layer
- SP (optional): TC5, iperf3 UDP flow with 1472 bytes payload, target bitrate specified by -r option

Note: This script only supports the network-namespace-isolated mode (single host); two-host mode is not available.

Usage: secV-D1.contention_delay.tx.sh [-tsh] [-r RATE] [-1 ATS1CPU] [-2 ATS2CPU] [-3 IPERF3CPU] [-l ATS1PRIO] [-L ATS2PRIO] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -t               Use ts2phc to synchronize the sender PHC to the receiver PHC instead of phc2sys
  -s               Run iperf3 as a competing SP flow
  -r RATE          Set iperf3 target bitrate to RATE bps (-b option of iperf3. default: 671M)
                       e.g., -r 0, -r 100M
  -1 ATS1CPU       CPU to use for ATS1 flow (default: 2)
  -2 ATS2CPU       CPU to use for ATS2 flow (default: 4)
  -3 IPERF3CPU     CPU to use for iperf3 client (default: 6)
  -l ATS1PRIO      SO_PRIORITY to set for ATS1 flow (default: 3)
                       e.g., -l 3
  -L ATS2PRIO      SO_PRIORITY to set for ATS2 flow (default: 2)
                       e.g., -L 2
  -p PREFIX        Output file prefix (default: result_secV-D1)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

- Receiver [`secV-D1.contention_delay.rx_stats.sh`](../../secV-D1.contention_delay.rx_stats.sh)

```bash
$ bash secV-D1.contention_delay.rx_stats.sh -h
Receiving-side script for contention delay evaluation with two competing ATS flows, each assigned to a different traffic class.
Note: This script only supports the network-namespace-isolated mode (single host); two-host mode is not available.

Usage: secV-D1.contention_delay.rx_stats.sh [-h] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -p PREFIX        Output file prefix (default: result_secV-D1)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

#### Key Options

- `-c CONF`
	- **Required** user config file. Refer to [evaluation/README.md](../../README.md#prepare-config-file) for details.
- `-t` (sender only)
	- Use `ts2phc` to synchronize the sender PHC to the receiver PHC in single-host mode.
- `-s` (sender only)
	- Enable competing SP flow (iperf3).
- `-r RATE` (sender only)
	- iperf3 bitrate when `-s` is enabled.
- `-1`, `-2`, `-3` (sender only)
	- CPU assignment for ATS1, ATS2, and iperf3.
- `-l`, `-L` (sender only)
	- `SO_PRIORITY` for ATS1 and ATS2.
- `-p PREFIX`
	- Output prefix. Use the same value on both the sender and the receiver.

This script pair supports single-host netns mode only.

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./secV-D1.contention_delay.rx_stats.sh -c ./user.conf
```

Then,

```bash
# Sender (with competing SP flow)
sudo ./secV-D1.contention_delay.tx.sh -t -s -c ./user.conf
```

Make sure to start the scripts in the same directory.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks, and waits for control messages from the sender. The sender performs environment checks, configures qdiscs, and starts clock synchronization.
2. In this evaluation, one session runs one measurement run and then exits. The only interactive prompt is synchronization confirmation. Check sync logs (especially offset values), then enter `y` to continue. Warmup runs automatically after this, then the ATS run starts.

```text
>>> proceed?(y/n) :
```

3. The sender launches two independent ATS sender processes (ATS1 and ATS2) and optional Strict Priority iperf3, then finishes after the single run. Depending on CPU options, ATS1 and ATS2 may run on different cores or the same core. The receiver computes statistics for both ATS flows and outputs the result.

The receiver also writes the result to the following files.

- `${PREFIX}<sp_prefix>.stats.log`: contains the results from each run
- `${PREFIX}<sp_prefix>.csv`: contains both the statistics and the parameters of each run in a CSV format.

Example of latency statistics from the case without SP:

```text
## ATS1
Mean	Median	Max	Min	Max-Min	SD
1046.28061	430.0	12716	420	12296	2156.968173916349

## ATS2
Mean	Median	Max	Min	Max-Min	SD
1049.01252	430.0	12750	420	12330	2164.639739777326
```

Example of latency statistics from the case with SP (`-s -r 671M`):

```text
## ATS1
Mean	Median	Max	Min	Max-Min	SD
7645.55161	7854.0	14295	423	13872	4428.992931910866

## ATS2
Mean	Median	Max	Min	Max-Min	SD
8265.98276	7759.0	26597	423	26174	5583.944235083547
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Statistics

Use the model and definitions in [Goal](#goal) and [Evaluation Setup](#evaluation-setup) when interpreting the results.

When reading results, focus on `Max-Min` in the Latency section.

- `Min` is treated as baseline latency (cable propagation + processing time without contention).
- `Max-Min` is interpreted as contention delay.

The guidelines for interpreting results are as follows.

- Without Strict Priority (`-s` disabled): ATS1 and ATS2 contend with each other. The theoretical worst-case contention delay is the time required to send out one frame, 12304 ns (see Appendix D in the paper for calculation). `Max-Min` values near this level are expected.
- With Strict Priority (`-s` enabled):
	- ATS1 (TC7, higher priority) has theoretical worst-case contention delay of the time required to send out one frame, 12,304 ns.
	- ATS2 (TC6, lower priority) can be delayed by SP and ATS1, so theoretical worst-case contention delay is the time required to send out **two** frames, 24,608 ns.
	- Compare measured `Max-Min` values of ATS1/ATS2 against these bounds.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs for both `noSP` and `withSP` cases.

- noSP case:
  - [`example_results/single_run_sample.noSP.tx.txt`](example_results/single_run_sample.noSP.tx.txt): sample sender output from a single run without SP.
  - [`example_results/single_run_sample.noSP.rx_stats.txt`](example_results/single_run_sample.noSP.rx_stats.txt): sample receiver output from a single run without SP.
  - [`example_results/single_run_result.noSP.csv`](example_results/single_run_result.noSP.csv): result CSV containing statistics and parameters from a single run without SP.
- withSP case (with iperf3 at 700 Mbps physical layer rate):
  - [`example_results/single_run_sample.withSP.sp671Mbps.tx.txt`](example_results/single_run_sample.withSP.sp671Mbps.tx.txt): sample sender output from a single run with SP.
  - [`example_results/single_run_sample.withSP.sp671Mbps.rx_stats.txt`](example_results/single_run_sample.withSP.sp671Mbps.rx_stats.txt): sample receiver output from a single run with SP.
  - [`example_results/single_run_result.withSP.sp671Mbps.csv`](example_results/single_run_result.withSP.sp671Mbps.csv): result CSV containing statistics and parameters from a single run with SP.

### Generated Files

Main summary files:

- `${PREFIX}<sp_prefix>.stats.log`: per-run results formatted for readability
- `${PREFIX}<sp_prefix>.csv`: per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}<sp_prefix><run>.tc7_tc6.pcap`

Supporting files:

- `${PREFIX}<sp_prefix><run>.tc7.aet.txt`: ATS1 Assigned Eligibility Time list
- `${PREFIX}<sp_prefix><run>.tc6.aet.txt`: ATS2 Assigned Eligibility Time list
- `${PREFIX}<sp_prefix><run>.tc7.latency.txt`: ATS1 latency raw data list
- `${PREFIX}<sp_prefix><run>.tc6.latency.txt`: ATS2 latency raw data list
- `${PREFIX}<sp_prefix><run>.iperf3.log` (when SP is enabled)

Clock synchronization logs (sender side):

- `${PREFIX}withSP.phc2sys.log` or `${PREFIX}noSP.phc2sys.log`
- `${PREFIX}withSP.ts2phc.log` or `${PREFIX}noSP.ts2phc.log` (when `-t` is used)

`<sp_prefix>` is automatically selected by scripts:

- `withSP.sp<RATE>bps.` when `-s` is enabled
- `noSP.` when `-s` is disabled

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).