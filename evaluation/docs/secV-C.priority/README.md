# secV-C.priority

## Goal

Verify that the priority arbitration of the ATS endpoint correctly enforces priority among different traffic classes.

An ATS flow is transmitted together with a lower-priority SP flow (iperf3), and the receiver checks behavior of frame intervals and receive rate of the ATS flow.

This evaluation focuses on whether higher-priority ATS flow exhibit the same transmission rate as user-configured CIR, and lower-priority SP flow's rate decrease accordingly.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation.

---

## Instructions Specific to Priority Evaluation

### Evaluation Setup

The following two flows appear in this experiment.

| Flow | Traffic Class | CIR/Rate | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 | TC7 | User-specified value | 1,538 bytes | 1,538 bytes |
| SP | TC5 | 1,000 Mbps (default) | 1,538 bytes | N/A |

### Usage

- Sender [`secV-C.priority.tx.sh`](../../secV-C.priority.tx.sh)

```bash
$ bash secV-C.priority.tx.sh -h
Sending-side script for inter-class priority evaluation.

Usage: secV-C.priority.tx.sh [-Nth] [-1 ATSCPU] [-3 IPERF3CPU] [-p PREFIX] [-P CONTROLPORT] [-T TX_SECONDS] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -t               Use ts2phc to synchronize the sender PHC to the receiver PHC instead of phc2sys. Only available in single machine setup
  -1 ATSCPU        CPU to use for ATS flow (default: 4)
                       e.g., -1 2
  -3 IPERF3CPU     CPU to use for iperf3 client (default: 6)
                       e.g., -3 4
  -p PREFIX        Output file prefix (default: result_secV-C)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -T TX_SECONDS    Transmission duration (default: 10 seconds)
                       e.g., -T 5
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

- Receiver [`secV-C.priority.rx_stats.sh`](../../secV-C.priority.rx_stats.sh)

```bash
$ bash secV-C.priority.rx_stats.sh -h
Receiving-side script for inter-class priority evaluation.

Usage: secV-C.priority.rx_stats.sh [-Nh] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -p PREFIX        Output file prefix (default: result_secV-C)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

#### Key Options

- `-c CONF`
	- **Required** user config file. Refer to [evaluation/README.md](../../README.md#prepare-config-file) for details.
- `-N`
	- Enable single-host network namespace mode.
- `-t` (sender only)
	- Use `ts2phc` to synchronize the sender PHC to the receiver PHC in single-host mode.
- `-1 ATSCPU` (sender only)
	- CPU core for the ATS flow process.
- `-3 IPERF3CPU` (sender only)
	- CPU core for the competing SP flow process.
- `-T TX_SECONDS` (sender only)
	- Transmission duration of the ATS flow.
- `-p PREFIX`
	- Output prefix. Use the same value on both the sender and the receiver.

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./secV-C.priority.rx_stats.sh -N -c ./user.conf
```

Then,

```bash
# Sender
sudo ./secV-C.priority.tx.sh -N -t -T 10 -c ./user.conf
```

If running in single-host mode (`-N`), make sure to start the scripts in the same directory.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks, starts packet capture and iperf3 server, and waits for control messages from the sender. The sender performs environment checks, configures qdiscs, and starts clock synchronization.

2. When the sender prompts for synchronization confirmation, check sync logs (especially offset values) and enter `y` to continue. Warmup runs automatically after this, then the ATS run loop starts.

```text
>>> proceed?(y/n) :
```

3. When prompted as follows, enter the CIR in Mbps (e.g., 100). An ATS flow with the specified CIR will then start. Enter `n` when you want to stop additional runs.

```text
>>> Enter CIR in Mbps, or "n" to quit:
```

4. For each run, the sender starts ATS transmission with the selected CIR and the duration specified by `-T TX_SECONDS`, and also runs competing SP traffic (iperf3). The receiver captures packets into a CIR-specific pcap file, computes receive rate and interval statistics, and outputs the result. The iperf3 server log is also recorded. After the receiver completes processing, the sender prompts for the next CIR.

The receiver also writes the result to the following files.

- `${PREFIX}interval_stats.log`: contains the results from each run
- `${PREFIX}csv`: contains both the statistics and the parameters for each run in a CSV format.

Example ATS statistics excerpt:

```text
### Overall rate

Flow	Rate(Mbps)	Duration(s)
1	100.00246131215681	4.999853418

----- Flow 1 -----
NumPackets: 40637

### Stats : Horizontal format (nanoseconds)

Mean	Median	Max	Min	Max-Min	SD
123039.99945860813	123041.0	123042	123033	9	2.818132799686235
```

Example iperf3 server log excerpt:

```text
Accepted connection from 10.0.200.11, port 47250
[  5] local 10.0.200.12 port 5201 connected to 10.0.200.11 port 48677
[ ID] Interval           Transfer     Bitrate         Jitter    Lost/Total Datagrams
[  5]   0.00-1.00   sec   109 MBytes   914 Mbits/sec  0.017 ms  0/77639 (0%)
[  5]   1.00-2.00   sec   114 MBytes   957 Mbits/sec  0.026 ms  47/81271 (0.058%)
[  5]   2.00-3.00   sec   114 MBytes   953 Mbits/sec  0.021 ms  0/80950 (0%)
[  5]   3.00-4.00   sec   103 MBytes   861 Mbits/sec  0.025 ms  0/73142 (0%)
[  5]   4.00-5.00   sec   103 MBytes   861 Mbits/sec  0.032 ms  0/73145 (0%)
[  5]   5.00-6.00   sec   103 MBytes   861 Mbits/sec  0.017 ms  0/73152 (0%)
[  5]   6.00-7.00   sec   103 MBytes   861 Mbits/sec  0.021 ms  0/73147 (0%)
[  5]   7.00-8.00   sec   103 MBytes   865 Mbits/sec  0.024 ms  0/73477 (0%)
[  5]   8.00-9.00   sec   114 MBytes   957 Mbits/sec  0.033 ms  0/81271 (0%)
[  5]   9.00-10.00  sec   114 MBytes   957 Mbits/sec  0.014 ms  0/81284 (0%)
[  5]   9.00-10.00  sec   114 MBytes   957 Mbits/sec  0.014 ms  0/81284 (0%)
- - - - - - - - - - - - - - - - - - - - - - - - -
[ ID] Interval           Transfer     Bitrate         Jitter    Lost/Total Datagrams
[  5]   0.00-10.00  sec  1.16 GBytes   997 Mbits/sec  0.013 ms  47/846268 (0.0056%)  receiver
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Statistics

Among the reported metrics, focus on `Rate(Mbps)`, `Mean`, and `Max-Min`. These metrics help assess transmit stability.

- `Rate(Mbps)`: the average receive rate of the flow during the run
- `Mean`: the average inter-arrival time of received frames
- `Max-Min`: the difference between the maximum and minimum inter-arrival time of received frames

The guidelines for interpreting results are as follows.

- Since the ATS flow has higher priority than the Strict Priority iperf3 traffic, the `Rate(Mbps)` value of the ATS flow should be approximately equal to the user-specified CIR value.
	- You can also check this using the `Mean` value, which should be approximately equal to the expected transmission interval derived from the CIR value.
- The `Max-Min` value of the ATS flow should be less than or equal to 12us. This is because, when a ATS frame is scheduled for transmission, an SP frame may already be in transmission, therefore the ATS frame must wait about 12 us for the 1,538 bytes SP frame to finish.

Also, check the iperf3 server log.

- The SP flow bitrate should decrease by roughly the CIR value assigned to ATS.
	- Example: with ATS CIR = 100 Mbps on a 1 Gbps link, iperf3 bitrate is expected to be around 900 Mbps (allowing normal runtime fluctuation).
	- Note: iperf3 bitrate is payload-based throughput, not physical-layer line rate. Therefore the actual line rate of the iperf3 flow is higher than the reported bitrate.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs.

- [`example_results/single_run_sample.tx.txt`](example_results/single_run_sample.tx.txt): sample sender output from a single run with CIR 100 Mbps.
- [`example_results/single_run_sample.rx_stats.txt`](example_results/single_run_sample.rx_stats.txt): sample receiver output from a single run with CIR 100 Mbps.
- [`example_results/multi_run_summary.csv`](example_results/multi_run_summary.csv): summary CSV containing statistics and parameters across multiple runs for CIR cases from 100 Mbps to 990 Mbps.

### Generated Files

Main summary files:

- `${PREFIX}interval_stats.log`: per-run results formatted for readability
- `${PREFIX}csv`: per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}cir<Mbps>.dur<TX_SECONDS>.<run>.pcap`

Supporting files:

- `${PREFIX}cir<Mbps>.dur<TX_SECONDS>.<run>.iperf3.log`

Clock synchronization logs (sender side):

- `${PREFIX}phc2sys.log`
- `${PREFIX}ts2phc.log` (when `-t` is used)

Notes:

- In single-host mode (`-N`), scripts automatically append `netns.` to the effective prefix.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).