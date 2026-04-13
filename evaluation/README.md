# Evaluation

This directory contains scripts to reproduce the six evaluations in the paper, along with supporting documentation.

- This `README.md`: Environment requirements and execution procedures shared by all evaluations.
- Evaluation scripts: Reproduce each of the six evaluations described in the paper.
- `docs/`: Per-evaluation `README.md` files with detailed usage instructions, output documentation, and examples.

To reproduce the evaluations:

1. Read this `README.md` to understand the environment requirements and common procedure.
	- [Execution Model](#execution-model)
	- [Environment Requirements](#environment-requirements)
	- [Prepare Config File](#prepare-config-file)
	- [Steps to Run Evaluations](#steps-to-run-evaluations)
2. Read the per-evaluation `README.md` for the specific evaluation you want to run.

## Paper Section and Script Mapping

| Paper section | Script pair | Detailed Docs & Examples | Verification target |
|---|---|---|---|
| Section V. Evaluation, A. CIR | [`./secV-A.cir_shaping.tx.sh`](./secV-A.cir_shaping.tx.sh)<br> [`./secV-A.cir_shaping.rx_stats.sh`](./secV-A.cir_shaping.rx_stats.sh) | [docs/secV-A.cir_shaping/](docs/secV-A.cir_shaping/) | Verify that the ATS endpoint correctly shapes traffic for different CIR settings. |
| Section V. Evaluation, B. CBS | [`./secV-B.cbs_shaping.tx.sh`](./secV-B.cbs_shaping.tx.sh)<br> [`./secV-B.cbs_shaping.rx_stats.sh`](./secV-B.cbs_shaping.rx_stats.sh) | [docs/secV-B.cbs_shaping/](docs/secV-B.cbs_shaping/) | Verify that the ATS endpoint correctly enforces different CBS settings. |
| Section V. Evaluation, C. Priority Arbitration | [`./secV-C.priority.tx.sh`](./secV-C.priority.tx.sh)<br> [`./secV-C.priority.rx_stats.sh`](./secV-C.priority.rx_stats.sh) | [docs/secV-C.priority/](docs/secV-C.priority/) | Verify that the ATS endpoint correctly enforces priority among different traffic classes. |
| Section V. Evaluation, D. Contention Delay (Detailed~) | [`./secV-D1.contention_delay.tx.sh`](./secV-D1.contention_delay.tx.sh)<br> [`./secV-D1.contention_delay.rx_stats.sh`](./secV-D1.contention_delay.rx_stats.sh) | [docs/secV-D1.contention_delay/](docs/secV-D1.contention_delay/) | Verify that the ATS endpoint correctly bounds the contention delay of ATS flows. |
| Section V. Evaluation, D. Contention Delay (Scalability~) | [`./secV-D2.scalability.tx.sh`](./secV-D2.scalability.tx.sh)<br> [`./secV-D2.scalability.rx_stats.sh`](./secV-D2.scalability.rx_stats.sh) | [docs/secV-D2.scalability/](docs/secV-D2.scalability/) | Verify contention-delay bound while increasing the number of competing ATS flows. |
| Appendix A. Details of LaunchTime in Intel i210 NIC, B. Accuracy | [`./appxA-B.accuracy.tx.sh`](./appxA-B.accuracy.tx.sh)<br> [`./appxA-B.accuracy.rx_stats.sh`](./appxA-B.accuracy.rx_stats.sh) | [docs/appxA-B.accuracy/](docs/appxA-B.accuracy/) | Preliminary evaluation of Intel i210 transmit timing control. |

---

## Common Instructions for All Evaluations

### Table of Contents

- [Execution Model](#execution-model)
- [Environment Requirements](#environment-requirements)
	1. [Root Privileges](#1-root-privileges-checked)
	2. [IP Address Configuration](#2-ip-address-configuration-selectauto)
	3. [Clock Synchronization Methods](#3-clock-synchronization-methods-selectauto)
	4. [Qdiscs](#4-qdiscs-auto)
	5. [Kernel Patch (SP_WAIT_SR)](#5-kernel-patch-sp_wait_sr-manual)
	6. [IRQBALANCE](#6-irqbalance-checked)
	7. [CPU](#7-cpu)
		- [7.1 Isolcpus](#71-isolcpus-checked)
		- [7.2 Scaling Governor](#72-scaling-governor-checked)
	8. [Power Management](#8-power-management)
		- [8.1 EEE (Energy Efficient Ethernet)](#81-eee-energy-efficient-ethernet-auto)
		- [8.2 Temporal Sleep Mechanism](#82-temporal-sleep-mechanism-manual)
		- [8.3 ASPM (Active State Power Management)](#83-aspm-active-state-power-management-manual)
	9. [Other Requirements](#9-other-requirements-manual)
- [Prepare Config File](#prepare-config-file)
- [Steps to Run Evaluations](#steps-to-run-evaluations)
- [Dependencies and Verified Versions](#dependencies-and-verified-versions)

### Execution Model

- Each evaluation is split into sender (`*.tx.sh`) and receiver/analyzer (`*.rx_stats.sh`) scripts.
- You may be prompted to input parameters during runtime for some `*.tx.sh` scripts. Follow the prompts to set the parameters.
- Final summary is generated on the receiver side by `*.rx_stats.sh`.

The scripts support two host configurations:

- Single-host netns mode (`-N`)
	- Connect both NICs on the same machine directly by cable. The sender and the receiver processes are isolated in different network namespaces.
- Two-host mode:
	- Connect the sender and the receiver machines over the network.

Hardware assumptions:

- The sender side NIC should support LaunchTime.
- The receiver side should support hardware RX timestamps.

### Environment Requirements

Each requirement is categorized as follows:

- **[auto]** — Automatically configured by the scripts. No user action needed.
- **[select+auto]** — The user selects a mode or option; the scripts handle the rest (setup, configuration, etc.) automatically.
- **[checked]** — Checked by the scripts at startup. The user must configure it beforehand.
- **[manual]** — Not checked by the scripts. The user must configure or verify it manually.

#### 1. Root Privileges [checked]

All scripts require sudo/root privileges to run.

#### 2. IP Address Configuration [select+auto]

- Single-host netns mode (`-N`):
	The scripts automatically configure network namespaces and IP addresses based on the [config file](#prepare-config-file). 
- Two-host mode:
	The user must set up IP addresses on both hosts.

#### 3. Clock Synchronization Methods [select+auto]

We use `linuxptp` for clock synchronization. Please install `linuxptp` version 4.x beforehand.

The scripts support one or two synchronization methods depending on the environment. The user selects the method; the scripts handle starting and stopping the synchronization daemons.

In single-host mode, `ts2phc` can be used if your setup allows SDP wiring between the sender and the receiver NICs. This typically provides better synchronization accuracy.

- Single-host netns mode:
	1. `phc2sys` method (default)
		- sync sender PHC to receiver PHC and system clock (sender PHC is the source).
	2. `ts2phc` plus `phc2sys` method (`-t`)
        - sync:
            - sender PHC to receiver PHC using `ts2phc` (sender PHC is the source).
            - sender PHC to system clock using `phc2sys`(sender PHC is the source).
		- requires SDP wiring between sender and receiver NICs.
- Two-host mode:
	1. `phc2sys` method (default)
		- sync sender PHC to sender system clock (sender PHC is the source).

#### 4. Qdiscs [auto]

The sender scripts automatically configure MQPRIO and ETF qdiscs. Please check in advance whether the kernel modules are available by running:

```bash
modinfo sch_etf
modinfo sch_mqprio
```

#### 5. Kernel Patch (SP_WAIT_SR) [manual]

A patched kernel that disables the `SP_WAIT_SR` flag in the Intel i210 igb driver is required. 

See [Required Kernel Patch (SP_WAIT_SR)](../README.md#kernel-patch-sp_wait_sr) in the root `README.md` for patch details.

#### 6. IRQBALANCE [checked]

The receiver script checks that none of these IRQBALANCE settings in `/etc/default/irqbalance` are set. 

- `IRQBALANCE_ARGS`
- `IRQBALANCE_BANNED_CPUS`
- `IRQBALANCE_BANNED_CPULIST`

#### 7. CPU 

For better performance, it is required to isolate CPU cores for the sender process using isolcpus and set the scaling governor to performance.

##### 7.1 Isolcpus [checked]

Set isolcpus in `GRUB_CMDLINE_LINUX` in `/etc/default/grub` to isolate the CPU cores to which you want to assign the sending process.

Specify the cores actually configured with isolcpus in `TARGET_ISOLCPUS_LIST` in the configuration file (Please refer to [Config File](#prepare-config-file)). Each script checks at startup whether the isolated cores match `TARGET_ISOLCPUS_LIST` and verifies that the configuration is correct.

##### 7.2 Scaling Governor [checked]

The scripts also verify that the scaling governor for all CPU cores is set to performance.

Please ensure that `/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor` is set to performance.


#### 8. Power Management

##### 8.1 EEE (Energy Efficient Ethernet) [auto]

The scripts automatically disable EEE on the relevant interfaces. No user action is required.

##### 8.2 Temporal Sleep Mechanism [manual]

For reproducibility, CPU power-saving sleep states (i.e., Intel C-states) should be disabled. These sleep states can introduce unexpected latency when the CPU transitions back to an active state, which may affect performance.

##### 8.3 ASPM (Active State Power Management) [manual]

For reproducibility, ASPM (a PCIe power-saving feature) should be disabled.

#### 9. Other Requirements [manual]

- Ensure that the tools listed in [Dependencies and Verified Versions](#dependencies-and-verified-versions) are installed.
- In particular, `numpy` must be available to the root user, since the scripts run with sudo/root privileges.

### Prepare Config File

All scripts require a user config file via `-c`. Use [configs/user.conf](configs/user.conf) template as a starting point.

```bash
# User-specific configuration required for the evaluation scripts.
# This is an example configuration file. Users should create their own 
# configuration file based on this template and set the necessary variables 
# according to their environment.

# isolcpus setting 
# The value is used to check if the isolcpus setting is correctly applied.
TARGET_ISOLCPUS_LIST="0-4"

# tx configuration
TX_IF=enp1s0
TX_IF_MAC=aa:bb:cc:dd:ee:ff
TX_NETNS_NAME=txnetns
TX_IP=10.0.200.11
TX_SUBNET=24

# rx configuration
RX_IF=enp2s0
RX_IF_MAC=11:22:33:44:55:66
RX_NETNS_NAME=rxnetns
RX_IP=10.0.200.12
RX_SUBNET=24

# Paths of linuxptp tools
#PHC2SYS_BIN=
#TS2PHC_BIN=
```

- `TX_NETNS_NAME` and `RX_NETNS_NAME` are only required in single-host mode.
- Regarding `TARGET_ISOLCPUS_LIST`, please refer to [CPU Isolation](#71-isolcpus-checked).
- `PHC2SYS_BIN` and `TS2PHC_BIN` can be set if you want to use custom paths for those binaries. By default, the scripts assume they are in the system PATH.

### Steps to Run Evaluations

The following steps walk through running an evaluation script, using [CIR shaping](docs/secV-A.cir_shaping/) as an example.

1. Create user config file from [template](configs/user.conf)

```bash
cp <repo path>/evaluation/configs/user.conf ./user.conf
```

2. Edit `user.conf` according to your environment and configuration

3. Run the receiver and the sender scripts

If running in single-host mode, make sure to start the scripts in the same directory. 

The command examples below assumes that you are using the followings.

- Single-host mode with netns (`-N`)
- `ts2phc` + `phc2sys` synchronization (`-t`)


```bash
# receiver
sudo ./secV-A.cir_shaping.rx_stats.sh -N -c ./user.conf
````

```bash
# sender
sudo ./secV-A.cir_shaping.tx.sh -N -t -c ./user.conf
```

4. Wait for clock synchronization to stabilize

Inspect synchronization log files in the sender working directory. Wait until the synchronization offset stabilizes, then answer `y` to proceed with the evaluation.

```bash
>>> proceed?(y/n) :
```

5. Input evaluation parameters

Some scripts will prompt you to input parameters for the evaluation. Follow the prompts to set the parameters.

```bash
>>> Enter CIR in Mbps, or "n" to quit:
```

6. Read final summarized results on the receiver side.

Summary files and other supporting files are generated in the receiver working directory.

- `${PREFIX}interval_stats.log` or `${PREFIX}stats.log` - per-run results formatted for readability
- `${PREFIX}csv` - per-run measurement statistics and parameters (one row per run)
- Other supporting files such as packet captures and synchronization logs.

---

### Dependencies and Verified Versions

The following versions were used in our environment:

| Tool | Version |
|---|---|
| linuxptp | 4.4-00018-g85765cb |
| iperf3 | iperf 3.9 (cJSON 1.7.13) |
| tcpdump | 4.99.1 |
| ethtool | ethtool version 5.16 |
| netcat | 1.218-4ubuntu1 |
| python3 | 3.10.12 |
| numpy | 2.2.6 |

Notes:

- linuxptp 4.x is recommended. linuxptp 3.x may not work correctly.
- iperf3 is only needed for evaluations with competing SP traffic.

## Troubleshooting

In situations such as the following, PDM and delta may need to be adjusted.

- When, in a simple scenario where frames are transmitted continuously at a constant rate, the `Max-Min` of received frames intervals is unexpectedly large. Here, `Max–Min` refers to the difference between the maximum and minimum inter-arrival times of received frames.
- When frames are being dropped.

See [Tuning Notes](../README.md#tuning-notes) in the root `README.md` for guidance on diagnosing and resolving these issues.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../LICENSE).
