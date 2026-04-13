# ATS Frame Generator

This directory provides a practical ATS traffic generation tool built on the library in [`lib/`](../lib/).

It serves two purposes:

- Generate ATS flows for experiments.
- Provide concrete implementation examples for ATS library users.
	- [`ats_frame_generator.c`](ats_frame_generator.c): single-threaded tool using the global API.
	- [`ats_multithread_frame_generator.c`](ats_multithread_frame_generator.c): multithreaded tool using the thread-safe context API with per-flow configuration defined in a CSV file.

## Build

By simply running `make` from the repository root or from this directory.

```bash
make
```

This will produce the following key artifacts.

- `ats_frame_generator`
- `ats_multithread_frame_generator`

## Runtime Requirements

- Run with sudo/root privileges.
- See [Runtime Requirements](../README.md#runtime-requirements) in the root `README.md` for kernel patch and qdisc setup.
- LaunchTime-capable Tx NIC (e.g., Intel i210/i225)

## ats_frame_generator

### Usage

This tool sends an ATS flow using the CIR and CBS parameters specified via options. The frame size is fixed at 1538 bytes at the physical layer, including Preamble, Start Frame Delimiter and Interframe Gap.

Here is the usage message of the tool. See [Important Options](#important-options) below for explanations of key options.

```bash
$ ./ats_frame_generator -h

Usage: ats_frame_generator -I IFNAME -d DEST_IP [-D DEST_PORT] [-S SOURCE_PORT]
                           [-n NUM_PACKET] [-r CIR] [-B CBS_BURST] [-b SO_SNDBUF] [-c CPU]
                           [-p SO_PRIORITY] [-l LINK_SPEED] [-O NW_OVERHEAD] [-M PDM]
                           [-PELsyvh]

Options:
  -I <IFNAME>             Network interface name
  -d <DEST_IP>            Destination IP address
  -D <DEST_PORT>          Destination port number (default: 11111)
  -S <SOURCE_PORT>        Source port number (default: 11111)
  -n <NUM_PACKET>         Number of packets to send (default: 100)
  -r <CIR>                CIR in bps (default: 100000000)
  -B <CBS_BURST>          Multiplier used to calculate CBS (default: 1)
                          CBS = wire_frame_size * CBS_BURST
  -b <SO_SNDBUF>          Set SO_SNDBUF in bytes
  -c <CPU>                CPU core affinity (default: 0)
  -p <SO_PRIORITY>        SO_PRIORITY to set for ATS flow (default: 3)
  -l <LINK_SPEED>         Link speed in bps (default: 1000000000)
  -O <NW_OVERHEAD>        Network overhead in bytes (default: 66 (w/o VLAN))
  -M <PDM>                Processing Delay Max (PDM) in ns (default: 100000)
  -P                      Print Assigned Eligibility Times (AET) of packets after
                          transmission as CSV (columns: index,et,aet,diff)
  -E                      Enable TX error reporting for SO_TXTIME
  -L                      Lock memory pages to prevent swapping (requires PREEMPT_RT)
  -s                      Use sleep-loop instead of busy-loop for sending.
                          This induces jitter in packet sending intervals
  -y                      Initialize the bucket empty time to the near future to 
                          make the multiple flows with `-y` option start at approximately the same time
  -Y                      Delayed start mode. Sleep 10ms before sending packets
  -v                      Enable debug mode
  -h                      Print this help message
```

When built with `make tune`, the `-v` option also enables ATS diagnostic warnings for a PDM issue. See [Diagnostic Build (ATS_TUNE)](../lib/README.md#diagnostic-build-ats_tune) for details.

### Example

This example sends 100000 frames at CIR 100Mbps, using CBS 6152 bytes (1538 x 4), with SO_PRIORITY 3, to destination IP `10.0.0.2`.

```bash
sudo ./ats_frame_generator \
	-I enp1s0 \
	-d 10.0.0.2 \
	-D 7788 \
	-S 7788 \
	-r 100000000 \
	-B 4 \
	-n 100000 \
  -p 3
```

### Important Options

- Interface and destination:
	- `-I <ifname>`, `-d <dest_ip>`, `-D <dest_port>`, `-S <source_port>`
- ATS flow shaping:
	- `-r <CIR bps>`, `-B <CBS multiplier>`, `-M <pdm>`
- Execution behavior:
	- `-n <number of packets>`, `-c <cpu>`, `-p <SO_PRIORITY>`, `-b <SO_SNDBUF>`
- Timing control:
	- `-y` (synchronized start for multiple flows), `-Y` (delayed start, sleep 10ms before sending)
- Debug and analysis:
	- `-P` (print assigned eligibility times), `-v` (debug mode)

## ats_multithread_frame_generator

This tool sends multiple ATS flows simultaneously using one thread per flow. Each flow is configured via a CSV file, and uses the thread-safe context API (`ats_ctx_t`).

### Usage

```bash
$ ./ats_multithread_frame_generator -h

Usage: ats_multithread_frame_generator -I IFNAME -d DEST_IP -f CSV_FILE
                               [-l LINK_SPEED] [-O NW_OVERHEAD] [-M PDM]
                               [-Pvh]

Options:
  -I <IFNAME>       Network interface name
  -d <DEST_IP>      Destination IP address
  -f <CSV_FILE>     CSV file with per-flow configuration
  -l <LINK_SPEED>   Link speed in bps (default: 1000000000)
  -O <NW_OVERHEAD>  Network overhead in bytes (default: 66)
  -M <PDM>          Processing Delay Max in ns (default: 100000)
  -P                Print AET of packets as CSV
  -v                Enable debug mode
  -h                Print this help message

When built with `make tune`, the `-v` option also enables ATS diagnostic warnings for a PDM issue. See [Diagnostic Build (ATS_TUNE)](../lib/README.md#diagnostic-build-ats_tune) for details.

CSV format (one flow per line, # for comments):
  destport, srcport, num_packet, cir, cbs_multiplier, so_priority, payload_size

  payload_size: UDP payload size in bytes (18-1472)
  cbs_multiplier: CBS = (payload_size + nw_overhead) * 8 * cbs_multiplier
```

### CSV File

Each line defines one flow. Lines starting with `#` are comments.

| Field | Description |
|---|---|
| destport | Destination port number |
| srcport | Source port number |
| num_packet | Number of packets to send |
| cir | Committed Information Rate in bps |
| cbs_multiplier | CBS = (payload_size + nw_overhead) * 8 * cbs_multiplier |
| so_priority | SO_PRIORITY value |
| payload_size | UDP payload size in bytes (18-1472) |

Example ([`mt_flows.csv`](mt_flows.csv)):

```csv
# destport, srcport, num_packet, cir, cbs_multiplier, so_priority, payload_size
11111, 11111, 100, 100000000, 1, 3, 1472
22222, 22222, 200, 200000000, 1, 2, 972
```

### Example

This example sends two flows defined in `mt_flows.csv` on interface `enp1s0` to destination `10.0.0.2`, printing AET as CSV.

```bash
sudo ./ats_multithread_frame_generator \
	-I enp1s0 \
	-d 10.0.0.2 \
	-f mt_flows.csv \
	-P
```

## Related Documentation

- Library APIs: [../lib/README.md](../lib/README.md)
- Evaluation scripts using this tool: [../evaluation/README.md](../evaluation/README.md)

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../LICENSE).
