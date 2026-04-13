# appxA-B.accuracy

## Goal

Evaluate the performance of Intel i210 transmit-time control.

Frames are sent at configured transmission intervals using LaunchTime, and receiver-side intervals are measured.

This evaluation focuses on:

- how stable the measured receive intervals are,
- how small the transmission interval can be set while maintaining stable behavior,
- and how these characteristics change across multiple Ethernet payload sizes.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation.

---

## Instructions Specific to Accuracy Evaluation

### Evaluation Setup

This evaluation iterates over the following Ethernet payload sizes:

- `46, 100, 300, 500, 700, 900, 1100, 1300, 1500` bytes

For each payload size, the sender repeatedly prompts for transmission interval input.

- Enter an interval value (ns): run one measurement for the current payload size.
- Enter `n`: move to the next payload size.

Due to behavior of Intel i210 LaunchTime, the transmit time of a frame is interpreted in 32 ns units. Therefore, the script rounds the user-specified interval down to the nearest multiple of 32 ns that does not exceed the input (unless `-M` is used).

Also, it is worth noting that when running in single-host network namespace mode, measured interval stability can be worse than the paper's inter-host results (Figure 17), likely due to additional netns-related overhead.

### Prerequisite

Build the frame generator tool used by the sender script before running this evaluation.

```bash
cd <repo root>/evaluation/deps/etfloop
```

Then, 

```
make
```

### Usage

- Sender [`appxA-B.accuracy.tx.sh`](../../appxA-B.accuracy.tx.sh)

```bash
$ bash appxA-B.accuracy.tx.sh -h
Sending-side script for evaluation of transmit timing control of Intel i210 NIC.

Note: Intel i210 controls the transmit time of a frame in 32-ns units.
      Therefore, the user specified transmission interval will be rounded down
      to the nearest multiple of 32 ns. (See option -M to disable this behavior)

Usage: appxA-B.accuracy.tx.sh [-NtM] [-1 ETFCPU] [-p PREFIX] [-P CONTROLPORT] 
  [-T TX_SECONDS] -c CONF

Options:
  -N              Use netns for isolating server and client. 
                  Specify this when using only single machine 
                  for evaluation. (default: false)
  -t              Use ts2phc to synchronize the sender PHC to the receiver PHC
                  instead of phc2sys. Only available in single machine setup
  -M              Do not round down the user specified transmission interval to
                  the nearest multiple of 32 ns (default: false)
  -1 ETFCPU       CPU to use for ETF flow (default: 4)
                      e.g., -1 2
  -p PREFIX       Output file prefix (default: result_appxA-B)
  -P CONTROLPORT  Port number used by control messages (default: 9000)
  -T TX_SECONDS   Transmission duration (default: 10 seconds)
                      e.g., -T 5
  -c CONF         Path to user-specific config file to source
  -h              Show this help message and exit
```

- Receiver [`appxA-B.accuracy.rx_stats.sh`](../../appxA-B.accuracy.rx_stats.sh)

```bash
$ bash appxA-B.accuracy.rx_stats.sh -h
Receiving-side script for evaluation of transmit timing control of Intel i210 NIC.

Usage: appxA-B.accuracy.rx_stats.sh [-Nh] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -p PREFIX        Output file prefix (default: result_appxA-B)
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
- `-1 ETFCPU` (sender only)
	- CPU core for the etfloop sender process.
- `-T TX_SECONDS` (sender only)
	- Transmit duration of the evaluation flow.
- `-p PREFIX`
	- Output prefix. Use the same value on both the sender and the receiver.

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./appxA-B.accuracy.rx_stats.sh -N -c ./user.conf
```

Then,

```bash
# Sender
sudo ./appxA-B.accuracy.tx.sh -N -t -c ./user.conf
```

If running in single-host mode (`-N`), make sure to start the scripts in the same directory.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks and waits for the sender control messages. The sender initializes environment and starts clock synchronization.
2. When th sender prompts for synchronization confirmation, check sync logs (especially offset values), then enter `y`.

```text
>>> proceed?(y/n) :
```

3. The sender enters a two-level loop:
The outer loop iterates Ethernet payload sizes (`46, 100, 300, 500, 700, 900, 1100, 1300, 1500`).
The inner loop prompts for transmission interval for the current payload size.

```text
>>> Current ethernet payload size: 46 bytes
>>> Enter the transmission interval (ns), or n to move to the next ethernet payload size:
```

4. Enter an interval value to execute one run for the current payload size. Enter `n` to move to the next payload size.
5. For each run, the sender transmits frames for the duration configured by `-T`, The receiver captures frames, computes interval statistics, and prints the run summary. After the receiver processing completes, control returns to the interval prompt.

The receiver also writes the result to the following files.

- `${PREFIX}interval_stats.log`: contains the results from each run
- `${PREFIX}csv`: contains both the statistics and the parameters of each run in a CSV format.

Example interval statistics output when the payload size is 1100 bytes and the transmit interval is 9600 ns:

```text
Mean	Median	Max	Min	Max-Min	SD
9599.999994239985	9600.0	9625	9576	49	9.860795964530329
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Statistics

Focus on `Mean`, `SD`, and `Max-Min`. These metrics help assess transmit stability and minimum feasible interval per payload size.

- `Mean`: the average inter-arrival time of received frames
- `SD`: the standard deviation of inter-arrival time of received frames
- `Max-Min`: the difference between the maximum and minimum inter-arrival time of received frames

The guidelines for interpreting results are as follows.

- The `Mean` value should be equal or very close to the user-specified transmission interval.
- A small `SD` indicates that the overall interval control was stable.
- A small `Max-Min` indicates that there was no sudden fluctuation in the receive interval.
- When the transmission interval falls below a certain threshold, both the `SD` and the `Max-Min` may increase. This can be taken as an indication of the minimum feasible interval for that payload size.
	- Alternatively, it may simply indicate that the interval has reached the limit imposed by the link speed.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs.

- [`example_results/single_run_sample.tx.txt`](example_results/single_run_sample.tx.txt): sample sender output from a single run with payload size 1100 bytes and interval 9600 ns.
- [`example_results/single_run_sample.rx_stats.txt`](example_results/single_run_sample.rx_stats.txt): sample receiver output from a single run with payload size 1100 bytes and interval 9600 ns.
- [`example_results/multi_run_summary.csv`](example_results/multi_run_summary.csv): summary CSV containing statistics and parameters across multiple runs for different payload sizes and transmission intervals.

### Generated Files

Main summary files:

- `${PREFIX}interval_stats.log`: per-run results formatted for readability
- `${PREFIX}csv`: per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}eth<payload>.interval<ns>.dur<s>.num<count>.<run>.pcap`

Clock synchronization logs (sender side):

- `${PREFIX}phc2sys.log`
- `${PREFIX}ts2phc.log` (when `-t` is used)

Notes:

- In single-host mode (`-N`), scripts automatically append `netns.` to the effective prefix.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).