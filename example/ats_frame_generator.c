/* Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology
 * (AIST). All rights reserved.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ats.h>
#include <errno.h>
#include <linux/errqueue.h>
#include <linux/net_tstamp.h>
#include <linux/types.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LINK_SPEED 1000000000
#define ONE_SEC_NS 1000000000ULL
#define DEFAULT_DEST_PORT 11111
#define DEFAULT_SOURCE_PORT 11111
#define DEFAULT_NUM_PACKET 100
#define DEFAULT_SO_PRIORITY 3
#define DEFAULT_CPU 0
#define DEFAULT_BURST_TIMES 1
#define DEFAULT_NW_OVERHEAD 66
#define DEFAULT_CIR 100000000ULL

__u64 get_time_ns()
{
    struct timespec ts;
    clock_gettime(CLOCK_TAI, &ts);
    return ts.tv_sec * 1000000000 + ts.tv_nsec;
}

void print_aet_csv(__u64* ets, size_t num, __u64 pdm, __u64 phy_len)
{
    printf("index,et,aet,diff\n");
    for (size_t i = 0; i < num; i++) {
        __u64 aet = ets[i] + pdm;
        if (i == 0) {
            printf("%zu,%llu,%llu,\n", i, ets[i], aet);
        }
        else {
            __u64 diff = aet - (ets[i - 1] + pdm);
            printf("%zu,%llu,%llu,%llu\n", i, ets[i], aet, diff);
        }
    }

    __u64 elapsed = ets[num - 1] - ets[0];
    double elapsed_sec = (double)elapsed / ONE_SEC_NS;
    __u64 bit_transferred = phy_len * 8 * num;
    double rate = (double)bit_transferred / elapsed_sec;

    fprintf(stderr, "elapsed_ns=%llu\n", elapsed);
    fprintf(stderr, "elapsed_sec=%f\n", elapsed_sec);
    fprintf(stderr, "bits=%llu\n", bit_transferred);
    fprintf(stderr, "rate_bps=%f\n", rate);
}

static int report_pthread_error(const char* fn, int err)
{
    fprintf(stderr, "error in %s(): %s\n", fn, strerror(err));
    return -1;
}

static int set_sched_settings(pthread_t thread, int cpu, int rt_prio)
{
    int err;
    cpu_set_t cpuset;
    struct sched_param sp = {.sched_priority = rt_prio};

    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    err = pthread_setaffinity_np(thread, sizeof(cpu_set_t), &cpuset);
    if (err) {
        return report_pthread_error("pthread_setaffinity_np", err);
    }

    err = pthread_setschedparam(thread, SCHED_FIFO, &sp);
    if (err) {
        return report_pthread_error("pthread_setschedparam", err);
    }

    return 0;
}

void usage()
{
    fprintf(
        stderr,
        "\n"
        "Usage: ats_frame_generator -I IFNAME -d DEST_IP [-D DEST_PORT] [-S SOURCE_PORT]\n"
        "                           [-n NUM_PACKET] [-r CIR] [-B CBS_BURST] [-b SO_SNDBUF] [-c "
        "CPU]\n"
        "                           [-p SO_PRIORITY] [-l LINK_SPEED] [-O NW_OVERHEAD] [-M PDM]\n"
        "                           [-PELsyvh]\n"
        "\n"
        "Options:\n"
        "  -I <IFNAME>             Network interface name\n"
        "  -d <DEST_IP>            Destination IP address\n"
        "  -D <DEST_PORT>          Destination port number (default: %d)\n"
        "  -S <SOURCE_PORT>        Source port number (default: %d)\n"
        "  -n <NUM_PACKET>         Number of packets to send (default: %d)\n"
        "  -r <CIR>                CIR in bps (default: %llu)\n"
        "  -B <CBS_BURST>          Multiplier used to calculate CBS (default: %d)\n"
        "                          CBS = wire_frame_size * CBS_BURST\n"
        "  -b <SO_SNDBUF>          Set SO_SNDBUF in bytes\n"
        "  -c <CPU>                CPU core affinity (default: %d)\n"
        "  -p <SO_PRIORITY>        SO_PRIORITY to set for ATS flow (default: %d)\n"
        "  -l <LINK_SPEED>         Link speed in bps (default: %d)\n"
        "  -O <NW_OVERHEAD>        Network overhead in bytes (default: %d (w/o VLAN))\n"
        "  -M <PDM>                Processing Delay Max (PDM) in ns (default: %d)\n"
        "  -P                      Print Assigned Eligibility Times (AET) of packets after\n"
        "                          transmission as CSV (columns: index,et,aet,diff)\n"
        "  -E                      Enable TX error reporting for SO_TXTIME\n"
        "  -L                      Lock memory pages to prevent swapping (requires PREEMPT_RT)\n"
        "  -s                      Use sleep-loop instead of busy-loop for sending.\n"
        "                          This induces jitter in packet sending intervals\n"
        "  -y                      Initialize the bucket empty time to the near future to \n"
        "                          make the multiple flows with `-y` option start at approximately "
        "the same time\n"
        "  -Y                      Delayed start mode. Sleep 10ms before sending packets\n"
        "  -v                      Enable debug mode\n"
        "  -h                      Print this help message\n"
        "\n",
        DEFAULT_DEST_PORT, DEFAULT_SOURCE_PORT, DEFAULT_NUM_PACKET, (unsigned long long)DEFAULT_CIR,
        DEFAULT_BURST_TIMES, DEFAULT_CPU, DEFAULT_SO_PRIORITY, LINK_SPEED, DEFAULT_NW_OVERHEAD,
        ATS_PROCESSING_DELAY_MAX);
}

static inline int send_busy_loop(int fd, unsigned char* tx_buf, size_t tx_buf_size,
                                 struct sockaddr_in* dest_addr, int num_packet, __u64* ets,
                                 int print_time)
{
    int err;

    for (int i = 0; i < num_packet; i++) {
        // starts[i] = get_time_ns();

        if (print_time) {
            __u64 et;
            err = ats_sendmsg_ex(fd, tx_buf, tx_buf_size, dest_addr, &et);
            // ends[i] = get_time_ns();
            ets[i] = et;
        }
        else {
            err = ats_sendmsg(fd, tx_buf, tx_buf_size, dest_addr);
        }
        if (err < 0) {
            printf("i: %d, err: %d, %s\n", i, err, strerror(errno));
            return -1;
        }
    }

    return 0;
}

static inline int send_sleep_loop(int fd, unsigned char* tx_buf, size_t tx_buf_size,
                                  struct sockaddr_in* dest_addr, int num_packet, __u64* ets,
                                  int print_time, const struct timespec* req)
{
    int err;

    for (int i = 0; i < num_packet; i++) {
        // starts[i] = get_time_ns();

        if (print_time) {
            __u64 et;
            err = ats_sendmsg_ex(fd, tx_buf, tx_buf_size, dest_addr, &et);
            // ends[i] = get_time_ns();
            ets[i] = et;
        }
        else {
            err = ats_sendmsg(fd, tx_buf, tx_buf_size, dest_addr);
        }

        if (err < 0) {
            printf("i: %d, err: %d, %s\n", i, err, strerror(errno));
            return -1;
        }

        nanosleep(req, NULL);
    }

    return 0;
}

struct timespec calc_interval_ns(long int rate, long int phy_len)
{
    struct timespec ts = {0};
    long int sleep_ns = (phy_len * 8 * ONE_SEC_NS) / rate - 2000;
    if (sleep_ns < 0) {
        sleep_ns = 1;
    }
    while (sleep_ns >= ONE_SEC_NS) {
        ts.tv_sec += 1;
        sleep_ns -= ONE_SEC_NS;
    }
    ts.tv_nsec = sleep_ns;

    return ts;
}

static int open_udp_socket(const char* ifname, int source_port, int enable_tx_report_errors,
                           int so_priority, int requested_sendbuf_size)
{
    int fd = ats_open_udp_socket(ifname, source_port, enable_tx_report_errors);
    if (fd < 0) {
        perror("Failed to open UDP socket");
        return -1;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &so_priority, sizeof(so_priority)) < 0) {
        perror("Failed to set SO_PRIORITY");
        goto err;
    }

    int sendbuf_size;
    socklen_t optlen = sizeof(sendbuf_size);
    if (getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendbuf_size, &optlen) < 0) {
        perror("getsockopt SO_SNDBUF failed");
        goto err;
    }
    fprintf(stderr, "default SO_SNDBUF is:\t%d\n", sendbuf_size);

    if (requested_sendbuf_size > 0) {
        if (setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &requested_sendbuf_size,
                       sizeof(requested_sendbuf_size)) < 0) {
            perror("setsockopt SO_SNDBUF failed");
            goto err;
        }
        optlen = sizeof(sendbuf_size);
        if (getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendbuf_size, &optlen) < 0) {
            perror("getsockopt SO_SNDBUF failed");
            goto err;
        }
        fprintf(stderr, "effective SO_SNDBUF is:\t%d\n", sendbuf_size);
    }

    return fd;

err:
    ats_close_udp_socket(fd);
    return -1;
}

int main(int argc, char* argv[])
{
    int opt, err, fd;

    int dest_port = DEFAULT_DEST_PORT;
    int source_port = DEFAULT_SOURCE_PORT;
    int num_packet = DEFAULT_NUM_PACKET;
    int so_priority = DEFAULT_SO_PRIORITY;
    int print_time = 0;
    int enable_tx_report_errors = 0;
    int cpu = DEFAULT_CPU;
    int burst_times = DEFAULT_BURST_TIMES;
    int synced_start = 0;
    int enable_mlockall = 0;
    int sleep_loop_mode = 0;
    int enable_debug_mode = 0;
    int delayed_start = 0;
    int requested_sendbuf_size = -1;
    int nw_overhead = DEFAULT_NW_OVERHEAD;

    __u64 link_speed = LINK_SPEED;
    __u64 pdm = 0;
    __u64 cir = DEFAULT_CIR;
    __u32 cbs;

    __u64* ets = NULL;

    char* ifname = NULL;
    char* dest_ip = NULL;

    struct sockaddr_in dest_addr;

    while (EOF != (opt = getopt(argc, argv, "p:d:D:S:n:I:r:PEc:yYhB:b:l:O:M:Lsv"))) {
        switch (opt) {
            case 'p':
                so_priority = atoi(optarg);
                break;
            case 'd':
                dest_ip = optarg;
                break;
            case 'D':
                dest_port = atoi(optarg);
                break;
            case 'S':
                source_port = atoi(optarg);
                break;
            case 'n':
                num_packet = atoi(optarg);
                break;
            case 'I':
                ifname = optarg;
                break;
            case 'r':
                cir = strtoull(optarg, NULL, 10);
                break;
            case 'P':
                print_time = 1;
                break;
            case 'E':
                enable_tx_report_errors = 1;
                break;
            case 'c':
                cpu = atoi(optarg);
                break;
            case 'y':
                synced_start = 1;
                break;
            case 'Y':
                delayed_start = 1;
                break;
            case 'h':
                usage();
                return 0;
            case 'B':
                burst_times = atoi(optarg);
                break;
            case 'b':
                requested_sendbuf_size = atoi(optarg);
                break;
            case 'l':
                link_speed = strtoull(optarg, NULL, 10);
                break;
            case 'O':
                nw_overhead = atoi(optarg);
                break;
            case 'M':
                pdm = strtoull(optarg, NULL, 10);
                break;
            case 'L':
                enable_mlockall = 1;
                break;
            case 's':
                sleep_loop_mode = 1;
                break;
            case 'v':
                enable_debug_mode = 1;
                break;
            case '?':
                usage();
                return -1;
        }
    }

    if (enable_mlockall) {
        if (mlockall(MCL_CURRENT | MCL_FUTURE) == -1) {
            perror("mlockall failed");
            return -1;
        }
    }

    if (cpu < 0) {
        fprintf(stderr, "Invalid CPU: %d\n", cpu);
        return -1;
    }

    if (num_packet <= 0) {
        fprintf(stderr, "Invalid NUM_PACKET: %d\n", num_packet);
        return -1;
    }

    if (!dest_ip) {
        fprintf(stderr, "Destination IP address not specified. Use -d.\n");
        return -1;
    }

    if (!ifname) {
        fprintf(stderr, "Network interface not specified. Use -I.\n");
        return -1;
    }

    if (dest_port <= 0 || dest_port > 65535) {
        fprintf(stderr, "Invalid DEST_PORT: %d\n", dest_port);
        return -1;
    }

    if (source_port <= 0 || source_port > 65535) {
        fprintf(stderr, "Invalid SOURCE_PORT: %d\n", source_port);
        return -1;
    }

    if (cir == 0) {
        fprintf(stderr, "Invalid CIR: must be greater than 0.\n");
        return -1;
    }

    if (burst_times <= 0) {
        fprintf(stderr, "Invalid CBS_BURST: %d\n", burst_times);
        return -1;
    }

    if (requested_sendbuf_size == 0 || requested_sendbuf_size < -1) {
        fprintf(stderr, "Invalid SO_SNDBUF: %d\n", requested_sendbuf_size);
        return -1;
    }

    if (nw_overhead < 0) {
        fprintf(stderr, "Invalid NW_OVERHEAD: %d\n", nw_overhead);
        return -1;
    }

    // synced start and delayed start are mutually exclusive
    if (synced_start && delayed_start) {
        fprintf(stderr, "-y and -Y cannot be enabled at the same time.\n");
        return -1;
    }

    int priority = 90;
    if (enable_mlockall) {
        priority = 49; /* 49 is for PREEMEPT_RT */
    }
    if (set_sched_settings(pthread_self(), cpu, priority)) {
        return -1;
    }

    fd = open_udp_socket(ifname, source_port, enable_tx_report_errors, so_priority,
                         requested_sendbuf_size);
    if (fd < 0) {
        return -1;
    }

    unsigned char tx_buf[1472];
    cbs = (sizeof(tx_buf) + nw_overhead) * 8 * burst_times;
    fprintf(stderr, "size of UDP payload: %zu\n", sizeof(tx_buf));

    // Prepare the data to send and the destination address
    memset(tx_buf, 0, sizeof(tx_buf));
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons((unsigned short)dest_port);
    if (inet_aton(dest_ip, &dest_addr.sin_addr) == 0) {
        fprintf(stderr, "inet_aton failed: invalid address: %s\n", dest_ip);
        return -1;
    }

    if (ats_set_flow(fd, cir, cbs, link_speed) < 0) {
        perror("ats_set_flow failed");
        goto cleanup;
    }
    ats_set_network_overhead_in_byte(nw_overhead);

    if (synced_start) {
        // set bucket empty time to near future.
        // useful when you want to make the flows start at approximately the same time when `-y`
        // option is set for multiple flows.
        __u64 now = get_time_ns();
        __u64 starttime = (now & ~0xFFFFFFF) + 450000000;

        /* make 100Mbps flow start exactly at the same time with 101Mbps flow when `-y` is set
         */
        if (cir == 100000000) {
            starttime -= 1216;
        }
        ats_set_bucket_empty_time(starttime);
        // printf("now: %llu, starttime: %llu\n", now, starttime);
    }
    else if (delayed_start) {
        // make sure that the flow starts after the other flows
        usleep(10000);
    }

    if (pdm && ats_set_processing_delay_max(pdm) < 0) {
        perror("ats_set_processing_delay_max failed");
        __u64 ceilpdm = (pdm + 31) & ~31;
        fprintf(stderr,
                "Processing Delay Max must be a multiple of 32. "
                "The smallest multiple of 32 which is greater than or equal to the given value is "
                "%llu\n",
                ceilpdm);
        goto cleanup;
    }
    pdm = ats_get_processing_delay_max();

    if (enable_debug_mode) {
        ats_set_debug_mode(1);
    }

    if (print_time) {
        ets = malloc((size_t)num_packet * sizeof(*ets));
        if (!ets) {
            fprintf(stderr, "Failed to allocate ets buffer for %d packets\n", num_packet);
            goto cleanup;
        }
    }

    fprintf(stderr, "cir: %llu, num_packets: %d, dest_port: %d, now: %llu\n", cir, num_packet,
            dest_port, get_time_ns());

    if (sleep_loop_mode) {
        fprintf(stderr, "Using sleep loop mode\n");
        const struct timespec req =
            calc_interval_ns((long int)cir, (long int)sizeof(tx_buf) + nw_overhead);
        fprintf(stderr, "Calculated sleep interval: %ld sec, %ld nsec\n", req.tv_sec, req.tv_nsec);
        err = send_sleep_loop(fd, tx_buf, sizeof(tx_buf), &dest_addr, num_packet, ets, print_time,
                              &req);
        if (err < 0) {
            goto cleanup;
        }
    }
    else {
        err = send_busy_loop(fd, tx_buf, sizeof(tx_buf), &dest_addr, num_packet, ets, print_time);
        if (err < 0) {
            goto cleanup;
        }
    }

    if (print_time) print_aet_csv(ets, num_packet, pdm, (__u64)(sizeof(tx_buf) + nw_overhead));

cleanup:
    free(ets);
    ats_close_udp_socket(fd);
    return 0;
}
