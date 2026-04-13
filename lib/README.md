# ATS Library

This directory contains the ATS library implementation. 

## Build

By simply running `make` from the repository root or from this directory.

```bash
make
```

This will produce the following key artifact.

- `build/libats.so`

To build with diagnostic warnings enabled, use `make tune` instead. See [Diagnostic Build (ATS_TUNE)](#diagnostic-build-ats_tune) below for details.

## Diagnostic Build (ATS_TUNE)

`make tune` builds the library with the `-DATS_TUNE` flag. This enables the detection of potential `sendmsg` blocking delays caused by an excessively large PDM or an insufficient `SO_SNDBUF`.

This warning is output to stderr when debug mode is enabled via `ats_set_debug_mode()`. The example tools [ats_frame_generator](../example/README.md#ats_frame_generator) and [ats_multithread_frame_generator](../example/README.md#ats_multithread_frame_generator) enable this with the `-v` option.

For details on adjusting PDM, see [Tuning Notes](../README.md#tuning-notes) in the root `README.md`.

## Tested Environment

- Linux kernel (Ubuntu-5.15.0-130.140) with the provided patch to disable `SP_WAIT_SR` in the Intel i210 igb driver. See [Required Kernel Patch (SP_WAIT_SR)](../README.md#kernel-patch-sp_wait_sr) for details.
- MQPRIO and ETF qdisc setup on the NIC interface. See [MQPRIO and ETF qdisc setup](../README.md#mqprio-and-etf-qdisc-setup) for details.
- LaunchTime-capable Tx NIC (e.g., Intel i210/i225)

## API Reference

API contracts are documented in the header file below.

- [include/ats.h](include/ats.h)

Please refer to that header for function semantics, parameter constraints, and errno behavior.

The library provides two API sets:

- **Global API** (`ats_set_flow`, `ats_sendmsg`, etc.): uses global state internally. Simple to use for single-flow programs, but **not thread-safe**.
- **Context API** (`ats_create_ctx`, `ats_set_flow_ctx`, `ats_sendmsg_ctx`, etc.): uses an opaque per-flow context (`ats_ctx_t`). Each context must be owned by a single thread because `sendmsg` is blocking. Use this API for multithreaded applications.

## Minimal Usage Examples

### Global API (single-threaded)

Below is a minimal example that uses the library to create an ATS flow with 1538 byte frames at the physical layer (1472 byte payload + 66 byte overhead) and a CIR of 100 Mbps on a 1 Gbps link.

```c
#include <arpa/inet.h>
#include <ats.h>
#include <stdio.h>
#include <string.h>

#define NUM_FRAMES 100

int main(void)
{
	int fd;
	struct sockaddr_in dst;
	char payload[1472];
	memset(payload, 'A', sizeof(payload));

	/* Create a UDP socket bound to the interface with SO_TXTIME enabled */
	fd = ats_open_udp_socket("enp3s0", 7788, 0);
	if (fd < 0) {
		perror("ats_open_udp_socket");
		return 1;
	}

	/* Configure the ATS flow: CIR=100Mbps, CBS=12304bits (1538 bytes), link_speed=1Gbps */
	if (ats_set_flow(fd, 100000000, 12304, 1000000000ULL) < 0) {
		perror("ats_set_flow");
		ats_close_udp_socket(fd);
		return 1;
	}

	memset(&dst, 0, sizeof(dst));
	dst.sin_family = AF_INET;
	dst.sin_port = htons(7788);
	inet_pton(AF_INET, "10.0.0.2", &dst.sin_addr);

	/* Send frames repeatedly; ats_sendmsg calculates the EligibilityTime for
	 * each frame based on the ATS scheduler (IEEE 802.1Q-2022) and paces
	 * transmissions to conform to the configured CIR */
	for (int i = 0; i < NUM_FRAMES; i++) {
		if (ats_sendmsg(fd, payload, sizeof(payload), &dst) < 0) {
			perror("ats_sendmsg");
			ats_close_udp_socket(fd);
			return 1;
		}
	}

	/* Optionally, use ats_sendmsg_ex to send a frame and retrieve the
	 * Eligibility Time assigned to that frame.
	 *
	 * __u64 et;
	 * if (ats_sendmsg_ex(fd, payload, sizeof(payload), &dst, &et) < 0) {
	 * 	perror("ats_sendmsg_ex");
	 * 	ats_close_udp_socket(fd);
	 * 	return 1;
	 * }
	 */

	/* Close the socket and release resources */
	ats_close_udp_socket(fd);
	return 0;
}
```

### Context API (thread-safe)

Below shows only the ATS library calls for the context API. Error handling, includes, and `main` are omitted.

```c
/* Create a UDP socket bound to the interface */
int fd = ats_open_udp_socket("enp3s0", 7788, 0);

/* Create a per-flow context */
ats_ctx_t* ctx = ats_create_ctx();

/* Configure the ATS flow: CIR=100Mbps, CBS=12304bits, link_speed=1Gbps */
ats_set_flow_ctx(ctx, fd, 100000000, 12304, 1000000000ULL);

/* Send frames; the context tracks per-flow state internally */
for (int i = 0; i < NUM_FRAMES; i++) {
	ats_sendmsg_ctx(ctx, payload, sizeof(payload), &dst);
}

/* Destroy the context and close the socket */
ats_destroy_ctx(ctx);
ats_close_udp_socket(fd);
```

Each `ats_ctx_t` must be owned by a single thread because `sendmsg` is blocking. Managing multiple flows in one thread would disrupt the timing of other flows.

## Full Examples

For complete and practical implementations, see:

- [../example/ats_frame_generator.c](../example/ats_frame_generator.c)
	- Single-threaded example using the global API.
- [../example/ats_multithread_frame_generator.c](../example/ats_multithread_frame_generator.c)
	- Multithreaded example using the context API with per-flow configuration defined in a CSV file

## Licensing

Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.

This software is released under the [MIT License](../LICENSE).
