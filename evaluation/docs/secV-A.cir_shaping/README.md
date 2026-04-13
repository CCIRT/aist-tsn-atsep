# secV-A.cir_shaping

## Goal

Verify that the ATS endpoint correctly shapes traffic for different CIR settings.

The sender transmits ATS traffic with user-specified CIR values, and the receiver measures inter-arrival behavior.

This evaluation focuses on:

- how correctly can the ATS sender shape traffic according to the configured CIR,
- and how stable the shaping is over time.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation.

---

## Instructions Specific to CIR Shaping Evaluation

### Evaluation Setup

The details of the ATS flow are specified in the table below.

| Flow | Traffic Class | CIR | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 | TC7 | User-specified value | 1,538 bytes | 1,538 bytes |

### Usage

- Sender [`secV-A.cir_shaping.tx.sh`](../../secV-A.cir_shaping.tx.sh)

```bash
$ bash secV-A.cir_shaping.tx.sh -h
Sending-side script for CIR shaping evaluation.

Usage: secV-A.cir_shaping.tx.sh [-Nth] [-1 CPU] [-p PREFIX] [-P CONTROLPORT] [-T TX_SECONDS] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -t               Use ts2phc to synchronize the sender PHC to the receiver PHC instead of phc2sys. Only available in single machine setup
  -1 CPU           CPU to use for ATS flow (default: 4)
                       e.g., -1 2
  -p PREFIX        Output file prefix (default: result_secV-A)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -T TX_SECONDS    Transmission duration (default: 10 seconds)
                       e.g., -T 5
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

- Receiver [`secV-A.cir_shaping.rx_stats.sh`](../../secV-A.cir_shaping.rx_stats.sh)

```bash
$ bash secV-A.cir_shaping.rx_stats.sh -h
Receiving-side script for CIR shaping evaluation.

Usage: secV-A.cir_shaping.rx_stats.sh [-Nh] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -p PREFIX        Output file prefix (default: result_secV-A)
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
- `-T TX_SECONDS` (sender only)
	- Transmission duration of the ATS flow.
- `-1 CPU` (sender only)
	- CPU core for the ATS sender process.
- `-p PREFIX`
  - Output prefix. Use the same value on both the sender and the receiver.

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./secV-A.cir_shaping.rx_stats.sh -N -c ./user.conf
```

Then, 

```bash
# Sender
sudo ./secV-A.cir_shaping.tx.sh -N -t -c ./user.conf
```

If running in single-host mode (`-N`), make sure to start the scripts in the same directory.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks, starts packet capture, and waits for control messages from the sender. The sender performs environment checks, configures qdiscs, and starts clock synchronization.

2. When the sender prompts for synchronization confirmation, check sync logs (especially offset values) and enter `y` to continue. Warmup runs automatically after this, then the ATS run loop starts.

```text
>>> proceed?(y/n) :
```

3. When prompted as follows, enter the CIR in Mbps (e.g., 100). An ATS flow with the specified CIR will then start. Enter `n` when you want to stop additional runs.

```text
>>> Enter CIR in Mbps, or "n" to quit:
```

4. For each run, the sender starts ATS transmission with the selected CIR and the duration specified by `-T TX_SECONDS`. The receiver captures packets into a CIR-specific pcap file, then computes receive rate and interval statistics, and outputs the result. After the receiver completes processing, the sender prompts for the next CIR.

The receiver also writes the result to the following files.

- `${PREFIX}interval_stats.log`: contains the results from each run
- `${PREFIX}csv`: contains both the statistics and the parameters for each run in a CSV format.

Example statistics excerpt:

```text
### Overall rate

Flow	Rate(Mbps)	Duration(s)
1	100.00123113094783	9.999829849

----- Flow 1 -----
NumPackets: 81274

### Stats : Horizontal format (nanoseconds)

Mean	Median	Max	Min	Max-Min	SD
123039.99912640115	123041	123058	123017	41	6.318794958379091
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Statistics

Among the reported metrics, focus on `Rate(Mbps)`, `Mean`, `SD`, and `Max-Min`. These metrics help assess transmit stability.

- `Rate(Mbps)`: the average receive rate of the flow during the run
- `Mean`: the average inter-arrival time of received frames
- `SD`: the standard deviation of inter-arrival time of received frames
- `Max-Min`: the difference between the maximum and minimum inter-arrival time of received frames

The guidelines for interpreting results are as follows.

- The `Rate(Mbps)` value should be equal or very close to the configured CIR value. This indicates that the shaping was working correctly.
  - You can also check this using the `Mean` value, which should be equal or very close to the expected transmission interval derived from the CIR value.
- A small `SD` indicates that the overall interval control and shaping were stable.
- A small `Max-Min` indicates that there was no sudden fluctuation in the receive interval.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs.

- [`example_results/single_run_sample.tx.txt`](example_results/single_run_sample.tx.txt): sample sender output from a single run with CIR 100 Mbps.
- [`example_results/single_run_sample.rx_stats.txt`](example_results/single_run_sample.rx_stats.txt): sample receiver output from a single run with CIR 100 Mbps.
- [`example_results/multi_run_summary.csv`](example_results/multi_run_summary.csv): summary CSV containing statistics and parameters across multiple runs for CIR cases from 100 Mbps to 999 Mbps.

### Generated Files

Main summary files:

- `${PREFIX}interval_stats.log`: per-run results formatted for readability
- `${PREFIX}csv`: per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}cir<Mbps>.dur<TX_SECONDS>.<run>.pcap`

Clock synchronization logs (sender side):

- `${PREFIX}phc2sys.log`
- `${PREFIX}ts2phc.log` (when `-t` is used)

Notes:

- In single-host mode (`-N`), scripts automatically append `netns.` to the effective prefix.


## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).