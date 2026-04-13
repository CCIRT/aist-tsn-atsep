# AIST-TSN Endpoint for Asynchronous Traffic Shaping (ATS)

This repository is part of the [AIST-TSN](https://github.com/CCIRT/aist-tsn) project.
This is an implementation of a Time-Sensitive Networking (TSN) endpoint for Asynchronous Traffic Shaping (ATS). It supports network interface cards with transmit timing control, such as Intel i210 and i225 NICs. The implementation generates IEEE-compliant ATS flows based on the Committed Information Rate and Committed Burst Size. To the best of our knowledge, this is the first real-world implementation of an ATS endpoint.

This `README.md` provides a brief overview. Implementation and evaluation details are documented in subdirectory `README.md` files.

## Publication
If you use this work, please cite the following paper:

> Takahiro HIROFUCHI, Akram BEN AHMED, and Takaaki FUKAI, "Implementation and Evaluation of a Time-Sensitive Networking Endpoint for Asynchronous Traffic Shaping", IEEE Access, 2026, doi: 10.1109/ACCESS.2026.3661078, https://ieeexplore.ieee.org/document/11372664

## Quick Start

Build both the ATS library and the ATS frame generators from the repository root.

```bash
make
```

This will produce the following key artifacts.

- `lib/build/libats.so`: ATS shared library
- `example/ats_frame_generator`: Single-flow ATS frame generator using the global API.
- `example/ats_multithread_frame_generator`: Multi-flow, multithreaded ATS frame generator using the context API.

## Repository Structure

- [lib/](lib/)
    - ATS library implementation, API usage guidance and minimal examples.
- [example/](example/)
    - ATS frame generator tools with usage instructions, serving as complete and practical examples of library usage.
- [evaluation/](evaluation/)
	- Scripts and documentation for reproducing the evaluations presented in the paper.

## Entry Points

- To develop your own ATS-based application, start with [lib/README.md](lib/README.md).
- To quickly generate ATS traffic, start with [example/README.md](example/README.md).
- To reproduce the paper results, start with [evaluation/README.md](evaluation/README.md).

## Runtime Requirements

### 1. Kernel Patch (SP_WAIT_SR)

The ATS library requires a patched Linux kernel that disables the `SP_WAIT_SR` flag in the Intel i210 igb driver (`drivers/net/ethernet/intel/igb/igb_main.c`). Without this patch, the priority arbitration is not compliant with the IEEE standard, especially when multiple ATS flows are used simultaneously.

A patch file [`disable_SP_WAIT_SR.patch`](disable_SP_WAIT_SR.patch) based on Linux kernel `Ubuntu-5.15.0-130.140` is included in the repository. Apply it using the `patch` command.
It should apply to other Linux kernel versions.

For further details, see Section IV (Design and Implementation) of the paper.

### 2. MQPRIO and ETF Qdisc Setup

Set up MQPRIO qdisc and ETF qdisc for the NIC to ensure correct traffic class mapping and scheduling.

For example, the commands below map SO_PRIORITY 3 to ETF qdisc.

```bash
tc qdisc del dev enp1s0 root

tc qdisc replace dev enp1s0 parent root handle 100 mqprio  \
    num_tc 3 \
    map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2 \
    queues 1@0 1@1 2@2 hw 0

tc qdisc add dev enp1s0 parent 100:1 etf   \
    offload clockid CLOCK_TAI delta 500000

tc qdisc add dev enp1s0 parent 100:2 etf   \
    offload clockid CLOCK_TAI delta 500000
```

#### MQPRIO Notes

The Intel i210 has four hardware TX queues. The queues at index 0 and 1 support LaunchTime; the queues at index 2 and 3 do not.

The example above creates three traffic classes and maps them as follows:

| SO_PRIORITY | Traffic class (in IEEE standard) | Hardware queue(s) | LaunchTime |
|---|---|---|---|
| 3 | TC 7 | Queue 0 (`1@0`) | Yes |
| 2 | TC 6 | Queue 1 (`1@1`) | Yes |
| 0, 1, 4–15 | TC 5 | Queues 2–3 (`2@2`) | No |

ATS flows must use SO_PRIORITY values mapped to TC 7 or TC 6 (either of the queues with LaunchTime support).

#### ETF Notes

The `delta` value specifies how many nanoseconds before the frame's `txtime` the ETF qdisc begins dequeuing and handing the frame to hardware. The ETF qdisc acts as a buffer between the application and the NIC, compensating for the delay between dequeue time and actual transmission time.

When `offload` is enabled, time-based transmission scheduling is handled by the NIC hardware (e.g., LaunchTime). Without offload, the ETF qdisc handles scheduling in software only, which does not meet the requirements of ATS due to insufficient timing accuracy.

## Tuning Notes

### Processing Delay Max (PDM)

PDM is a parameter defined by the IEEE standard. It is an internal delay added to the Eligibility Time (i.e., transmission time) of each frame computed by ATS. This delay is added to ensure that frames are not transmitted later than their intended eligibility time due to processing delays. The eligibility time after adding PDM is referred to as the Assigned Eligibility Time.

When PDM is too large, frames submitted by the application are scheduled too far in the future, and remain in the send buffer until their transmission time. This can block `sendmsg` for new frames, resulting in transmission intervals longer than intended.

Lowering PDM resolves this, but setting it too low means the system cannot finish processing frames in time, which leads to unstable transmission intervals.

This is not a severe tuning challenge; starting from around 100us (the default value used by the example tools) is a good starting point.

Increasing `SO_SNDBUF` can also help. A larger send buffer allows more frames to be queued, thereby making larger PDM values tolerable by giving older frames more time to be transmitted before the buffer fills up.

Building the library with `make tune` enables diagnostic warnings that help detect PDM-related issues. See [Diagnostic Build (ATS_TUNE)](lib/README.md#diagnostic-build-ats_tune) for details.

### ETF delta

Choosing an appropriate delta is important to avoid frame drops. Delta must not be too large or too small.

ETF qdisc stats (`tc -s qdisc show dev <ifname>`) can help diagnose drop causes. Here is an example output of qdisc stats. In this setup, the ETF qdisc with handle `8113:` is attached to TC7, while the ETF qdisc with handle `8112:` is attached to TC6.

```
# tc -s qdisc show dev enp1s0
qdisc mqprio 100: root tc 3 map 2 2 1 0 2 2 2 2 2 2 2 2 2 2 2 2
             queues:(0:0) (1:1) (2:3)
 Sent 15362 bytes 13 pkt (dropped 0, overlimits 0 requeues 0)
 backlog 0b 0p requeues 0
qdisc fq_codel 0: parent 100:4 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64
 Sent 42 bytes 1 pkt (dropped 0, overlimits 0 requeues 0)
 backlog 0b 0p requeues 0
  maxpacket 0 drop_overlimit 0 new_flow_count 0 ecn_mark 0
  new_flows_len 0 old_flows_len 0
qdisc fq_codel 0: parent 100:3 limit 10240p flows 1024 quantum 1514 target 5ms interval 100ms memory_limit 32Mb ecn drop_batch 64
 Sent 180 bytes 2 pkt (dropped 0, overlimits 0 requeues 0)
 backlog 0b 0p requeues 0
  maxpacket 0 drop_overlimit 0 new_flow_count 0 ecn_mark 0
  new_flows_len 0 old_flows_len 0
qdisc etf 8114: parent 100:2 clockid TAI delta 500000 offload on deadline_mode off skip_sock_check off
 Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)
 backlog 0b 0p requeues 0
qdisc etf 8113: parent 100:1 clockid TAI delta 500000 offload on deadline_mode off skip_sock_check off
 Sent 15140 bytes 10 pkt (dropped 0, overlimits 0 requeues 0)
 backlog 0b 0p requeues 0
```

In case of frame drops, pay attention to the values of `dropped` and `overlimits` shown in parentheses.

- Only `dropped` incrementing: frames were rejected when being enqueued into the ETF qdisc. This happens when a frame's `txtime` is earlier than the `txtime` of the last dequeued frame.
- Both `dropped` and `overlimits` incrementing: frames expired inside the ETF queue before they could be dequeued (delta too small).

When running multiple ATS flows through the same ETF qdisc, avoid setting delta too large, as it can cause enqueue failures.

Regardless of the number of flows, delta must not be set to 500 ms or higher. The Intel i210 LaunchTime only considers the sub-second portion of the txtime. If the difference between the Assigned Eligibility Time and the current time exceeds 500ms, frames may be transmitted at unexpected times. If delta is higher or equal to 500ms, the ETF qdisc hands the frame to hardware too early and cannot prevent this issue.

The right delta depends on your environment and workload, and interacts with the ATS PDM value, therefore tuning both together is recommended. [cyclictest](https://wiki.linuxfoundation.org/realtime/documentation/howto/tools/cyclictest/start) can help measure the system latency needed to inform a good starting point.

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](LICENSE).

The file [`disable_SP_WAIT_SR.patch`](disable_SP_WAIT_SR.patch) is derived from the Linux kernel and is licensed under [GPL-2.0-only](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html.en).

## Acknowledgment

This program is based on results obtained from the project, "Research and
Development Project of the Enhanced infrastructures for Post 5G Information and
Communication Systems" (JPNP20017), commissioned by the New Energy and
Industrial Technology Development Organization (NEDO).
