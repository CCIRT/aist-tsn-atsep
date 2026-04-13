# secV-B.cbs_shaping

## Goal

Verify that the ATS endpoint correctly enforces different CBS settings.

The sender transmits ATS traffic with user-specified CBS values, and the receiver measures inter-arrival behavior.

This evaluation focuses on the capability to control the burst transfer of an ATS flow according to its CBS.

## Before You Proceed

Prerequisites for running the evaluation are documented in [evaluation/README.md](../../README.md). Please read the document before proceeding with the evaluation.

---

## Instructions Specific to CBS Shaping Evaluation

### Evaluation Setup

The details of the ATS flow are specified in the table below.

| Flow | Traffic Class | CIR | Frame size (physical layer) | CBS |
|---|---|---|---|---|
| ATS1 | TC7 | 100 Mbps | 1,538 bytes | `1,538 * User-specified value` |

### Usage

- Sender [`secV-B.cbs_shaping.tx.sh`](../../secV-B.cbs_shaping.tx.sh)

```bash
$ bash secV-B.cbs_shaping.tx.sh -h
Sending-side script for CBS shaping evaluation.

Usage: secV-B.cbs_shaping.tx.sh [-Nth] [-1 CPU] [-p PREFIX] [-P CONTROLPORT] [-f TX_FRAMES] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -t               Use ts2phc to synchronize the sender PHC to the receiver PHC instead of phc2sys. Only available in single machine setup
  -1 CPU           CPU to use for ATS flow (default: 4)
                       e.g., -1 2
  -p PREFIX        Output file prefix (default: result_secV-B)
  -P CONTROLPORT   Port number used by control messages (default: 9000)
  -f TX_FRAMES     Number of frames to send (default: 100)
                       e.g., -f 5
  -c CONF          Path to user-specific config file to source
  -h               Show this help message and exit
```

- Receiver [`secV-B.cbs_shaping.rx_stats.sh`](../../secV-B.cbs_shaping.rx_stats.sh)

```bash
$ bash secV-B.cbs_shaping.rx_stats.sh -h
Receiving-side script for CBS shaping evaluation.

Usage: secV-B.cbs_shaping.rx_stats.sh [-Nh] [-p PREFIX] [-P CONTROLPORT] -c CONF

Options:
  -N               Use netns for isolating server and client. 
                   Specify this when using only single machine 
                   for evaluation. (default: false)
  -p PREFIX        Output file prefix (default: result_secV-B)
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
- `-f TX_FRAMES` (sender only)
	- Number of frames to send per CBS case.
- `-1 CPU` (sender only)
	- CPU core for the ATS sender process.
- `-p PREFIX`
	- Output prefix. Use the same value on both the sender and the receiver.

### Command Example

After moving to the working directory,

```bash
# Receiver
sudo ./secV-B.cbs_shaping.rx_stats.sh -N -c ./user.conf
```

Then,

```bash
# Sender
sudo ./secV-B.cbs_shaping.tx.sh -N -t -f 100 -c ./user.conf
```

If running in single-host mode (`-N`), make sure to start the scripts in the same directory.

### Execution Flow

1. Start both the receiver and the sender. The receiver initializes checks, starts packet capture, and waits for control messages from the sender. The sender performs environment checks, configures qdiscs, and starts clock synchronization.

2. When the sender prompts for synchronization confirmation, check sync logs (especially offset values) and enter `y` to continue. Warmup runs automatically after this, then the ATS run loop starts.

```text
>>> proceed?(y/n) :
```

3. When prompted as follows, enter the CBS multiplier (e.g., 8). The sender sets the CBS to the value obtained by multiplying 1538 by the input value and starts the ATS flow. Enter `n` when you want to stop additional runs.

```text
>>> Enter a multiplier of the frame size for CBS, or "n" to quit:
```

For example, if you enter `8`, the sender sets CBS to `1,538 * 8 = 12,304 bytes` and starts transmission of the ATS flow with that CBS.

4. For each run, the sender starts transmission with the selected CBS multiplier and the frame count specified by `-f TX_FRAMES`. The receiver captures packets into a CBS-specific pcap file, computes interval statistics, and output the result with raw interval values. After the receiver completes processing, the sender prompts for the next CBS multiplier.

The receiver also writes result to the following files.

- `${PREFIX}interval_stats.log`: contains the results from each run.
- `${PREFIX}interval_summary.txt`: raw interval values for each run (one run per column block). Use this file when comparing burst behavior across different CBS multipliers.
- `${PREFIX}csv`: contains both the statistics and the parameters for each run in a CSV format.

Example frame intervals excerpt from the receiver output when the CBS multiplier is 8:

```text
No.	Interval
0	12320
1	12336
2	12321
3	12320
4	12320
5	12304
6	12320
7	36800
8	123041
9	123042
10	123041
...	...
```

See [Example Results Directory](#example-results-directory) for a full example of the results.

### Guidelines for Interpreting Interval Data

In this evaluation, focus on the frame intervals themselves rather than their statistical values.

ATS transmits frames immediately as long as sufficient burst size remains. Therefore, for 1,538 bytes frames, the inter-frame interval is approximately 12,300 ns. After the burst size is exhausted, frames are transmitted according to the configured CIR, resulting in an interval of approximately 123,000 ns in this evaluation (CIR = 100 Mbps).

Examine the observed frame interval data and check how many intervals of approximately 12,300 ns appear. When the CBS multiplier is `N`, the CBS is `1538 × N`, meaning that at least `N` frames of 1,538 bytes are required to consume the burst. Therefore, it is expected that at least `N−1` intervals of approximately 12,300 ns will be observed.

### Example Results Directory

In the `example_results` directory, you can find sample output files from actual runs.

- [`example_results/single_run_sample.tx.txt`](example_results/single_run_sample.tx.txt): sample sender output from a single run with CBS multiplier 8.
- [`example_results/single_run_sample.rx_stats.txt`](example_results/single_run_sample.rx_stats.txt): sample receiver output from a single run with CBS multiplier 8.
- [`example_results/multi_run_interval_summary.txt`](example_results/multi_run_interval_summary.txt): raw interval values across multiple runs for CBS multiplier cases 8, 16, and 32.
- [`example_results/multi_run_summary.csv`](example_results/multi_run_summary.csv): summary CSV containing statistics and parameters across multiple runs for CBS multiplier cases 8, 16, and 32.

### Generated Files

Main summary files:

- `${PREFIX}interval_stats.log`: per-run results formatted for readability
- `${PREFIX}interval_summary.txt`: raw interval values for each run, appended side-by-side (one run per column block)
- `${PREFIX}csv`: per-run measurement statistics and parameters (one row per run)

Packet capture results:

- `${PREFIX}cbs<multiplier>x.num<TX_FRAMES>.<run>.pcap`

Clock synchronization logs (sender side):

- `${PREFIX}phc2sys.log`
- `${PREFIX}ts2phc.log` (when `-t` is used)

Notes:

- In single-host mode (`-N`), scripts automatically append `netns.` to the effective prefix.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../../../LICENSE).