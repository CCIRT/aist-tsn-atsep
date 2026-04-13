# secV-D2.scalability

## Goal

This evaluation extends [secV-D1.contention_delay](../secV-D1.contention_delay/README.md) to a more demanding case.

We prepare up to 63 competing ATS flows (plus one main ATS flow) and verify that contention delay remains bounded as the number of competing flows increases.

For the definition and interpretation of contention delay, refer to [Goal](../secV-D1.contention_delay/README.md#goal) section in secV-D1.contention_delay.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation. 

---

## Instructions Specific to Scalability Evaluation

### Evaluation Setup

This evaluation measures contention delay of the main ATS flow while scaling the number of competing ATS flows up to 63. All flows are assigned to the same traffic class.

- The configuration of each flow in Figure 13 is as follows, where there are up to 7 competing flows.

This can be reproduced with `-b 100000000 -i 1000000` options in the sender script.

| Flow | Traffic Class | CIR/Rate | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 (main flow) | TC7 | CIR = 100 Mbps | 1,538 bytes | 1,538 bytes |
| ATS2 | TC7 | CIR = 101 Mbps | 1,538 bytes | 1,538 bytes |
| ATS3 | TC7 | CIR = 102 Mbps | 1,538 bytes | 1,538 bytes |
| ATS4 | TC7 | CIR = 103 Mbps | 1,538 bytes | 1,538 bytes |
| ATS5 | TC7 | CIR = 104 Mbps | 1,538 bytes | 1,538 bytes |
| ATS6 | TC7 | CIR = 105 Mbps | 1,538 bytes | 1,538 bytes |
| ATS7 | TC7 | CIR = 106 Mbps | 1,538 bytes | 1,538 bytes |
| ATS8 | TC7 | CIR = 107 Mbps | 1,538 bytes | 1,538 bytes |
| SP (optional) | TC5 | 100 Mbps (default) | 1,538 bytes | N/A |

- The configuration of each flow in Figure 14 of the paper is as follows, where there are up to 63 competing flows.

This can be reproduced with `-b 10000000 -i 100000` options in the sender script.

| Flow | Traffic Class | CIR/Rate | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 (main flow) | TC7 | CIR = 10 Mbps | 1,538 bytes | 1,538 bytes |
| ATS2 | TC7 | CIR = 10.1 Mbps | 1,538 bytes | 1,538 bytes |
| ATS3 | TC7 | CIR = 10.2 Mbps | 1,538 bytes | 1,538 bytes |
| ATS4 | TC7 | CIR = 10.3 Mbps | 1,538 bytes | 1,538 bytes |
| ... | ... | ... | ... | ... |
| ATS61 | TC7 | CIR = 16.0 Mbps | 1,538 bytes | 1,538 bytes |
| ATS62 | TC7 | CIR = 16.1 Mbps | 1,538 bytes | 1,538 bytes |
| ATS63 | TC7 | CIR = 16.2 Mbps | 1,538 bytes | 1,538 bytes |
| ATS64 | TC7 | CIR = 16.3 Mbps | 1,538 bytes | 1,538 bytes |
| SP (optional) | TC5 | 100 Mbps (default) | 1,538 bytes | N/A |

Note: The `-b` option in iperf3 specifies the bitrate based on payload, not the physical layer rate. The value shown above is the iperf3 default rate for this script, converted into the physical layer rate.

### Usage

- Sender [`secV-D2.scalability.tx.sh`](../../secV-D2.scalability.tx.sh)

```bash
$ bash secV-D2.scalability.tx.sh -h
Sending-side script for scalability evaluation with multiple competing ATS 
flows (maximum 63), all assigned to the same traffic class.
Note: This script only supports the network-namespace-isolated 
      mode (single host); two-host mode is not available.

Usage: secV-D2.scalability.tx.sh [-tSRNsdh] [-p PREFIX] [-1 ATSCPUS] [-m PDM]  
       [-n NUMPACKETS] [-b BASERATE] [-i INCREMENT] [-D DELTA] [-3 IPERF3CPU] 
       [-r RATE] [-P CONTROLPORT] -c CONF

Clock synchronization options:
  -t   
                  Use ts2phc to synchronize the sender PHC to the receiver PHC 
                  instead of phc2sys 

Output options:
  -p PREFIX
                  Output file prefix (default: result_secV-D2)

ATS process options:
  -1  ATSCPUS
                  Set CPU assignment for each flow in a comma-separated list. 
                  The list can contain individual CPU numbers or ranges 
                  (e.g., "2,4,6-8"). The assignment will be repeated if the 
                  number of flows exceeds the length of the list 
                  (default: "0-3")
  -S
                  Use sleep-loop mode instead of busy-waiting for sending 
                  packets in ATS processes. This may reduce packet drops at 
                  higher numbers of competing flows, but may induce jitter in 
                  packet sending intervals
  -m PDM
                  Processing Delay Max in nanoseconds. Must be a multiple of 
                  32 (default: 100000)
  -R
                  Lock memory pages of ATS processes to prevent swapping. 
                  Requires PREEMPT_RT kernel

Flow configuration options:
  -n NUMPACKETS
                  Number of packets to be sent for the main flow (flow 1). This 
                  also acts as a base number for calculating sending duration 
                  and number of packets for other flows (default: 100000)
  -b BASERATE
                  Base sending rate in bps for the main flow (flow 1). This 
                  also acts as a base rate for calculating sending rates for 
                  other flows (default: 10000000)
  -i INCREMENT
                  Rate increment in bps for each additional flow 
                  (default: 100000)

ETF qdisc options:
  -D DELTA
                  Delta value of etf qdisc in nanoseconds (default: 500000)
  -N
                  No offload. Unset "offload" parameter of etf qdisc

SP (iperf3) options: 
  -s
                  Run iperf3 as a competing SP flow
  -3 IPERF3CPU
                  Set CPU assignment for iperf3 client (default: 4)
  -r RATE
                  Set iperf3 target bitrate to RATE bps 
                  (-b option of iperf3. default: 95.71M)
                       e.g., -r 700M

Misc options:
  -P CONTROLPORT
                  Port number used by control messages (default: 9000)
  -c CONF
                  Path to user-specific config file to source
  -d
                  Dry run: print out rates, number of packets, and estimated 
                  sending duration for each of 64 ATS flows without 
                  actually running ATS
  -h
                  Show this help message and exit
```

- Receiver [`secV-D2.scalability.rx_stats.sh`](../../secV-D2.scalability.rx_stats.sh)

```bash
$ bash secV-D2.scalability.rx_stats.sh -h
Receiving-side script for scalability evaluation with multiple competing ATS 
flows (maximum 64), all assigned to the same traffic class.
Note: This script only supports the network-namespace-isolated 
      mode (single host); two-host mode is not available.

Usage: secV-D2.scalability.rx_stats.sh [-h] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -p PREFIX        Output file prefix (default: result_secV-D2)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./secV-D2.scalability.rx_stats.sh -c ./user.conf
```

Then,

```bash
# Sender
sudo ./secV-D2.scalability.tx.sh -t -n 100000 -b 100000000 -i 1000000 -D 250000 -m 300000 -c ./user.conf
```

Make sure to start the scripts in the same directory.

#### Key Options

- `-c CONF`
	- **Required** user config file. Refer to [evaluation/README.md](../../README.md#prepare-config-file) for details.
- `-t` (sender only)
	- Use `ts2phc` to synchronize the sender PHC to the receiver PHC in single-host mode.
- `-n`, `-b`, `-i` (sender only)
	- Flow scaling and rate profile controls for ATS flows.
- `-s`, `-3 IPERF3CPU`, `-r RATE` (sender only)
	- Enable and configure the optional competing SP flow (iperf3).
- `-p PREFIX`
	- Output prefix. Use the same value on both the sender and the receiver.

This script pair supports single-host netns mode only.

##### `-1 ATSCPUS` Option Note

- The CPU assignment list specified by `-1` is applied to all ATS flows in a round-robin manner. For example, if you specify `-1 2,4-6`, the CPU assignment for flows will be as follows:
	- ATS1: CPU 2
	- ATS2: CPU 4
	- ATS3: CPU 5
	- ATS4: CPU 6
	- ATS5: CPU 2
	- ATS6: CPU 4
	- ATS7: CPU 5
	- ATS8: CPU 6
	- ...
- To check the CPU information of the machine, use `lscpu -e` command. For example:

```bash
$ lscpu -e
CPU NODE SOCKET CORE L1d:L1i:L2:L3 ONLINE    MAXMHZ   MINMHZ       MHZ
  0    0      0    0 0:0:0:0          yes 4500.0000 400.0000 1014.8470
  1    0      0    0 0:0:0:0          yes 4500.0000 400.0000 1204.6840
  2    0      0    1 4:4:1:0          yes 4500.0000 400.0000 1102.7030
  3    0      0    1 4:4:1:0          yes 4500.0000 400.0000  998.9760
  4    0      0    2 12:12:3:0        yes 3300.0000 400.0000 1292.7720
  5    0      0    3 13:13:3:0        yes 3300.0000 400.0000 1357.1340
  6    0      0    4 14:14:3:0        yes 3300.0000 400.0000 1282.3710
  7    0      0    5 15:15:3:0        yes 3300.0000 400.0000 1265.3010
```

##### `-d` (Dry Run) Option Note

Use `-d` in the the sender script to print the flow profile without executing traffic generation. This can be useful for playing around with the options below to verify the flow profile before running the actual evaluation.

- `-1 ATSCPUS`
- `-n NUMPACKETS`
- `-b BASERATE`
- `-i INCREMENT`

```bash
$ sudo ./secV-D2.scalability.tx.sh -1 0-6,12 -n 10000 -b 11000000 -i 90000 -c ./user.conf -d
Flow	Port	CPU	Rate(bps)	NumPackets	SendDur(s)
1	11111	0	11000000	10000	11.18545
2	11112	1	11090000	11073	12.28545
3	11113	2	11180000	11208	12.33545
4	11114	3	11270000	11344	12.38545
5	11115	4	11360000	11481	12.43545

...

60	11170	3	16310000	20129	15.18545
61	11171	4	16400000	20307	15.23545
62	11172	5	16490000	20485	15.28545
63	11173	6	16580000	20664	15.33545
64	11174	12	16670000	20844	15.38545
TOTAL	-	-	885440000	1000866	-
```

##### `-D DELTA` and `-m PDM` Option Note

This evaluation focuses on contention among multiple flows, where a large number of frames can accumulate in the ETF qdisc queue. As a result, the behavior is sensitive to the ETF qdisc delta and PDM parameters, and frame drops may occur. Please adjust these parameters as necessary. For details on tuning, see [Tuning Notes](../../README.md#tuning-notes).

##### `-S` Option Note

When the number of competing flows is very large, using `-S` is recommended.

By default, frame transmission is performed using busy-waiting: once the transmit buffer becomes available, frames are immediately scheduled for transmission in a tight loop until the buffer is filled again. As a result, a large number of frames can temporarily accumulate in the ETF qdisc queue. While this is not an issue with a small number of competing flows, increasing the number of flows raises the queue load, which can cause frames in the queue to expire and increases the likelihood of frame drops.

In sleep-loop mode, the ATS process sleeps for approximately the transmission interval using `nanosleep()` before initiating the transmission of each frame. This reduces the number of frames accumulated in the queue, and can significantly decrease frame drops even when many flows are competing. However, note that the use of `nanosleep()` may introduce some jitter into the transmission interval.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks, and waits for the sender control messages. The sender performs environment checks, configures qdiscs, and starts clock synchronization.

2. When the sender prompts for synchronization confirmation, check sync logs (especially offset values) and enter `y` to continue. Warmup runs automatically after this, then the ATS run loop starts.

```text
>>> proceed?(y/n) :
```

3. Enter the number of competing ATS flows, where the input range is `0` to `63`. Enter `n` to exit.

```text
>>> Enter a number of competing flows (0~63), excluding the main flow , or "n" to quit:
```

4. The specified number of flows, along with one main flow ATS sender process, will be launched. The receiver computes latency and interval statistics for the main flow and the sender asks for the next value.

The receiver also writes the result to the following files.

- `${PREFIX}<sp_prefix>.stats.log`: contains the results from each run
- `${PREFIX}<sp_prefix>.csv`: contains both the statistics and the parameters of each run in a CSV format.

Example of latency statistics of the main flow when there are 3 competing flows:

```text
Mean	Median	Max	Min	Max-Min	SD
2726.78832	424.0	35535	412	35123	4400.861656202292
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Statistics

Use the model and definitions in [Goal](#goal) and [Evaluation Setup](#evaluation-setup) when interpreting the results.

When reading results, focus on `Max-Min` in the Latency section.

- `Min` is treated as baseline latency (cable propagation + processing time without contention).
- `Max-Min` is interpreted as contention delay.

The guidelines for interpreting results are as follows.

- The theoretical worst-case contention delay is given by the formula in Appendix D of the paper. In the example above, a total of 4 ATS flows are active, and no SP traffic is present. Therefore, the worst-case contention delay is estimated to be 36,912 ns. Please verify that `Max-Min` does not exceed this value.
- In some cases, the observed `Max-Min` is significantly lower than the theoretical worst-case contention delay. This is because the probability that frames from many competing flows align and contend can be extremely low, depending on the parameter settings.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs for both `noSP` and `withSP` cases.

- noSP case:
  - [`example_results/single_run_sample.noSP.tx.txt`](example_results/single_run_sample.noSP.tx.txt): sample sender output from a single run with 3 competing flows and no SP.
  - [`example_results/single_run_sample.noSP.rx_stats.txt`](example_results/single_run_sample.noSP.rx_stats.txt): sample receiver output from a single run with 3 competing flows and no SP.
  - [`example_results/multi_run_summary.noSP.csv`](example_results/multi_run_summary.noSP.csv): summary CSV containing statistics and parameters across multiple runs for competing-flow counts from 0 to 7.
- withSP case:
  - [`example_results/single_run_sample.withSP.sp95_71Mbps.tx.txt`](example_results/single_run_sample.withSP.sp95_71Mbps.tx.txt): sample sender output from a single run with 3 competing flows and SP enabled.
  - [`example_results/single_run_sample.withSP.sp95_71Mbps.rx_stats.txt`](example_results/single_run_sample.withSP.sp95_71Mbps.rx_stats.txt): sample receiver output from a single run with 3 competing flows and SP enabled.
  - [`example_results/multi_run_summary.withSP.sp95_71Mbps.csv`](example_results/multi_run_summary.withSP.sp95_71Mbps.csv): summary CSV containing statistics and parameters across multiple runs for competing-flow counts from 0 to 7 with SP enabled.

### Generated Files

Main summary files:

- `${PREFIX}<sp_prefix>.stats.log` - per-run results formatted for readability
- `${PREFIX}<sp_prefix>.csv` - per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}<sp_prefix>num_competeflow<N>.run<R>.pcap`

Supporting files:

- `${PREFIX}<sp_prefix>num_competeflow<N>.run<R>.iperf3.log` (when SP is enabled)
- `${PREFIX}<sp_prefix>num_competeflow<N>.run<R>.pcap.1.txt` (main flow receive timestamps)
- `${PREFIX}<sp_prefix>num_competeflow<N>.run<R>.latency.1.txt` (main flow latency raw data)
- `${PREFIX}<sp_prefix>num_competeflow<N>.run<R>.aet.<flow_index>.txt` (Assigned Eligibility Time for each flow)

Clock synchronization logs (sender side):

- `${PREFIX}withSP.phc2sys.log` or `${PREFIX}noSP.phc2sys.log`
- `${PREFIX}withSP.ts2phc.log` or `${PREFIX}noSP.ts2phc.log` (when `-t` is used)

`<sp_prefix>` is automatically selected by scripts:

- `withSP.` when `-s` is enabled
- `noSP.` when `-s` is disabled

AET file note:

- `.aet.1.txt` corresponds to the main flow.
- `.aet.2.txt` and later correspond to competing flows.
- These timestamps are paired with receive-side packet timestamps for latency calculation.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).