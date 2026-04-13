/* Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology
 * (AIST). All rights reserved.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <linux/errqueue.h>
#include <linux/net_tstamp.h>
#include <linux/sockios.h>
#include <math.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_INTERVAL 1000000
#define DEFAULT_SOPRIO 3
#define DEFAULT_PORT 11111
#define DEFAULT_NUMPACKETS 500000
#define DEFAULT_PAYLOAD_SIZE 1472
#define BUFFER_BEFORE_START 100000000ULL
#define DEFAULT_RT_PRIORITY 90
#define DEFAULT_CPU 0
#define ONE_SEC_NS 1000000000ULL
#define CLOCKID CLOCK_TAI

// configurable parameters
static long num_packets = DEFAULT_NUMPACKETS;
static int interval_ns = DEFAULT_INTERVAL;
static int so_priority = DEFAULT_SOPRIO;
static int udp_port = DEFAULT_PORT;
static int enable_deadline_mode = 0;
static int enable_report_errors = 0;
static int alternate_mode = 0;

static struct sock_txtime sk_txtime;
static char* udp_dest_ip = NULL;
static struct in_addr dest_addr;
static int max_record_size = 400000;
static uint64_t buffer_before_start = BUFFER_BEFORE_START;

// ethernet payload:  46 100 300 500 700 900 1100 1300 1500
// udp payload     :  18  72 272 472 672 872 1072 1272 1472
static unsigned char* tx_buffer = NULL;
static size_t tx_buffer_size = DEFAULT_PAYLOAD_SIZE;

static uint64_t get_nanosecond()
{
    struct timespec ts;
    clock_gettime(CLOCK_TAI, &ts);
    return ts.tv_sec * ONE_SEC_NS + ts.tv_nsec;
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

static int open_udp_socket(const char* name)
{
    int fd;

    int yes = 1;
    struct sockaddr_in addr;
    struct ifreq ifr;

    struct sock_txtime sk_txtime = {0};
    sk_txtime.clockid = CLOCKID;
    sk_txtime.flags = (enable_deadline_mode | enable_report_errors);

    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(udp_port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    // create a socket
    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        perror("Failed to create socket");
        goto err;
    }

    // get the interface IP address which the socket binds to
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) < 0) {
        perror("Failed to get interface address");
        goto err_close;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &so_priority, sizeof(so_priority))) {
        perror("Failed to set SO_PRIORITY");
        goto err_close;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes))) {
        perror("Failed to set SO_REUSEADDR");
        goto err_close;
    }

    // set the socket txtime option
    if (setsockopt(fd, SOL_SOCKET, SO_TXTIME, &sk_txtime, sizeof(sk_txtime))) {
        perror("Failed to set SO_TXTIME");
        goto err_close;
    }

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("Failed to bind socket");
        goto err_close;
    }

    // bind the socket to the interface
    if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, name, strlen(name)) < 0) {
        perror("Failed to set SO_BINDTODEVICE");
        goto err_close;
    }

    int sendbuf_size;
    socklen_t optlen = sizeof(sendbuf_size);
    if (getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &sendbuf_size, &optlen) < 0) {
        perror("Failed to get SO_SNDBUF");
        goto err_close;
    }
    // fprintf(stderr, "SO_SNDBUF:\t%d\n", sendbuf_size);

    return fd;

err_close:
    close(fd);
err:
    return -1;
}

static int recv_errqueue(int fd, int* origin)
{
    int ret;

    uint8_t ctrl[CMSG_SPACE(sizeof(struct sock_extended_err))];
    unsigned char* err_buffer = malloc(tx_buffer_size);
    if (!err_buffer) {
        perror("Failed to allocate error buffer.");
        return -1;
    }
    struct sock_extended_err* serr;
    struct cmsghdr* cm;

    struct iovec iov = {.iov_base = err_buffer, .iov_len = tx_buffer_size};
    struct msghdr msg = {
        .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ctrl, .msg_controllen = sizeof(ctrl)};

    ret = recvmsg(fd, &msg, MSG_ERRQUEUE);
    if (ret < 0) {
        perror("Failed to recvmsg");
        free(err_buffer);
        return -1;
    }

    for (cm = CMSG_FIRSTHDR(&msg); cm != NULL; cm = CMSG_NXTHDR(&msg, cm)) {
        serr = (void*)CMSG_DATA(cm);
        *origin = serr->ee_origin;
    }

    free(err_buffer);
    return 1;
}

static int process_errqueue(int origin)
{
    switch (origin) {
        case SO_EE_ORIGIN_TXTIME:
            return 1;
        case SO_EE_ORIGIN_LOCAL:
            fprintf(stderr, "local error: \n");
            return 0;
        case SO_EE_ORIGIN_ZEROCOPY:
            fprintf(stderr, "zerocopy: \n");
            return 0;
        case SO_EE_ORIGIN_ICMP:
            fprintf(stderr, "ICMP: \n");
            return 0;
        case SO_EE_ORIGIN_NONE:
            fprintf(stderr, "none: \n");
            return 0;
        case SO_EE_ORIGIN_TXSTATUS:
            fprintf(stderr, "txstatus/timestamping: \n");
            return 0;
        default:
            fprintf(stderr, "default: \n");
            return 0;
    }
}

static int udp_sendmsg(int fd, void* buf, int len, __u64 txtime)
{
    struct sockaddr_in sin;
    struct msghdr msg;
    struct iovec iov;
    struct cmsghdr* cmsg;
    char control[CMSG_SPACE(sizeof(txtime))] = {};

    ssize_t count;

    memset(&sin, 0, sizeof(sin));
    sin.sin_family = AF_INET;
    sin.sin_addr = dest_addr;
    sin.sin_port = htons(udp_port);
    iov.iov_base = buf;
    iov.iov_len = len;

    memset(&msg, 0, sizeof(msg));
    msg.msg_name = &sin;
    msg.msg_namelen = sizeof(sin);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_TXTIME;
    cmsg->cmsg_len = CMSG_LEN(sizeof(__u64));
    *((__u64*)CMSG_DATA(cmsg)) = txtime;

    count = sendmsg(fd, &msg, 0);

    if (count == -1) {
        perror("Failed to send message");
        return -errno;
    }

    return count;
}

static void fprintf_packets(long sent_packets, long err_queue_packets, long err_send_packets)
{
    fprintf(stderr, "- num of sent packets:\t%ld\n", sent_packets);
    fprintf(stderr, "- num of SO_TXTIME err:\t%ld\n", err_queue_packets);
    fprintf(stderr, "- num of sendmsg err:\t%ld\n", err_send_packets);
}

static void fprintf_times(uint64_t* elapsetimes, uint64_t* txtimes, int* errnos, long sent_packets)
{
    uint64_t sum = 0;
    uint64_t max_time = 0;
    uint64_t min_time = UINT64_MAX;
    printf("\n");
    for (int i = 0; i < sent_packets; i++) {
        // printf("elapsetime of %d packet is:\t%lu", i, elapsetimes[i]);
        // print data in csv
        printf("%d\t%lu\t%lu\t%d\n", i, elapsetimes[i], txtimes[i], errnos[i]);
        uint64_t elapsetime = elapsetimes[i];
        sum += elapsetime;
        if (elapsetime > max_time) {
            max_time = elapsetime;
        }
        if (elapsetime < min_time) {
            min_time = elapsetime;
        }
    }
    fprintf(stderr, "\nsum of elapsetimes is:\t%lu\n", sum);
    fprintf(stderr, "max of elapsetimes is:\t%lu\n", max_time);
    fprintf(stderr, "min of elapsetimes is:\t%lu\n", min_time);

    // calculate mean
    double mean = (double)sum / sent_packets;
    fprintf(stderr, "mean of elapsetimes is:\t%f\n", mean);

    // calculate standard deviation
    double sum_of_square = 0;
    for (int i = 0; i < sent_packets; i++) {
        sum_of_square += pow(elapsetimes[i] - mean, 2);
    }
    double standard_deviation = sqrt(sum_of_square / sent_packets);
    fprintf(stderr, "standard deviation of elapsetimes is:\t%f\n", standard_deviation);

    return;
}

// check whether the variable is a multiple of 32
static int is_multiple_of_32(__u64 num) { return (num & 0x1F) == 0; }

static __u64 floor_to_multiple_of_32(__u64 num) { return num & ~0x1F; }

static int fprint_start_txtime_end(uint64_t* starts, uint64_t* txtimes, uint64_t* ends, int size)
{
    printf("start,txtime,end\n");
    for (int i = 0; i < size; i++) {
        printf("%lu,%lu,%lu\n", starts[i], txtimes[i], ends[i]);
    }
    return 0;
}

static int etfloop_busy(int fd)
{
    int count;
    int err;
    __u64 txtime;
    __u64 origtime;
    struct timespec ts;
    struct pollfd p_fd = {
        .fd = fd,
    };

    long err_queue_packets = 0;
    long err_send_packets = 0;

    int priority_odd = 2;
    int priority_even = 3;

    /*
    int rec_size;
    if (num_packets > max_record_size) {
        rec_size = max_record_size;
    }
    else {
        rec_size = num_packets;
    }

    uint64_t starts[100000];
    uint64_t ends[100000];
    uint64_t elapsetimes[rec_size];
    uint64_t txtimes[rec_size];
    int errnos[rec_size];
    */

    memset(tx_buffer, 0, tx_buffer_size);

    clock_gettime(CLOCKID, &ts);
    origtime = ts.tv_sec * ONE_SEC_NS + ts.tv_nsec;
    txtime = ts.tv_sec * ONE_SEC_NS + ts.tv_nsec + buffer_before_start + interval_ns;
    txtime = floor_to_multiple_of_32(txtime);

    uint64_t uneven_detected = 0;

    for (long sent_packets = 0; sent_packets < num_packets; sent_packets++) {
        // uint64_t start = get_nanosecond();
        // starts[sent_packets] = start;

        if (alternate_mode) {
            if (sent_packets % 2 == 0) {
                if (setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &priority_even,
                               sizeof(priority_even))) {
                    perror("Failed to set SO_PRIORITY");
                    close(fd);
                    return -1;
                }
            }
            else {
                if (setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &priority_odd, sizeof(priority_odd))) {
                    perror("Failed to set SO_PRIORITY");
                    close(fd);
                    return -1;
                }
            }
        }

        count = udp_sendmsg(fd, tx_buffer, tx_buffer_size, txtime);

        // fprintf(stderr, "\ncount: %d, sent_packets: %ld, tx_time:
        // %lld", count, sent_packets, txtime);
        if (count < 0) {
            // send error
            err_send_packets++;
        }
        else if (count != tx_buffer_size) {
            // unexpected packet size sent
            fprintf(stderr, "Unexpected happened (udp_sendmsg)\n");
        }

        // if (sent_packets < max_record_size) {
        //     txtimes[sent_packets] = txtime;
        // }
        txtime += interval_ns;

        uint64_t after_send = get_nanosecond();
        if (after_send >= txtime) {
            uneven_detected++;
            // fprintf(stderr, "INTERVAL BECOME UNEVEN\n");
        }
        // ends[sent_packets] = after_send;

        // if (sent_packets < max_record_size) {
        //     uint64_t end = get_nanosecond();
        //     uint64_t elapsetime = end - start;
        //     elapsetimes[sent_packets] = elapsetime;
        // }
    }

    sleep(1);

    fprintf(stderr, "Finished sending packets...\n");

    while (1) {
        // Check error queue
        err = poll(&p_fd, 1, 0);
        // fprintf(stderr, "\nerr is:\t\t\t%d", err);
        if (err != 1) {
            break;
        }
        if (!(p_fd.revents & POLLERR)) {
            break;
        }

        int origin;
        int ret = recv_errqueue(fd, &origin);
        if (ret > 0) {
            if (process_errqueue(origin) == 1) {
                err_queue_packets++;
            }
        }
    }

    // fprint_start_txtime_end(starts, txtimes, ends, num_packets);
    // fprintf_times(elapsetimes, txtimes, errnos, num_packets);
    fprintf_packets(num_packets, err_queue_packets, err_send_packets);
    fprintf(stderr, "- num of times socket unblocking delay detected:\t%lu\n", uneven_detected);

    return 0;
}

static void usage()
{
    fprintf(stderr,
            "\n"
            "Usage: etfloop -i IFACE -U DEST_IP [options]\n"
            "\n"
            "Options:\n"
            " -i IFACE      network interface\n"
            " -U DEST_IP    unicast destination IP address\n"
            " -c CPU        CPU core affinity (default: %d)\n"
            " -p NUM        RT priority (default: %d)\n"
            " -u PORT       source and destination UDP port (default: %d)\n"
            " -I NUM        send interval in nanoseconds (default: %d)\n"
            " -n NUM        number of packets to send (default: %d)\n"
            " -L NUM        UDP payload size in bytes (default: %d)\n"
            " -B NUM        nanoseconds to wait before sending (default: %llu)\n"
            " -P NUM        SO_PRIORITY of main flow (default: %d)\n"
            " -D            set deadline mode on for SO_TXTIME\n"
            " -E            enable reporting of tx errors via the socket error queue when using "
            "SO_TXTIME\n"
            " -A            Alternate SO_PRIORITY between 2 and 3 for each packet\n"
            " -h            show this message and exits\n"
            "\n",
            DEFAULT_CPU, DEFAULT_RT_PRIORITY, DEFAULT_PORT, DEFAULT_INTERVAL, DEFAULT_NUMPACKETS,
            DEFAULT_PAYLOAD_SIZE, (unsigned long long)BUFFER_BEFORE_START, DEFAULT_SOPRIO);
}

int main(int argc, char* argv[])
{
    int opt, err, fd;
    int rt_prio = DEFAULT_RT_PRIORITY;
    int cpu = DEFAULT_CPU;
    char* iface = NULL;

    while (EOF != (opt = getopt(argc, argv, "i:u:U:I:n:L:B:c:p:P:DEAh"))) {
        switch (opt) {
            case 'i':
                iface = optarg;
                break;
            case 'u':
                udp_port = atoi(optarg);
                break;
            case 'U':
                udp_dest_ip = optarg;
                break;
            case 'I':
                interval_ns = atoi(optarg);
                break;
            case 'n':
                num_packets = atol(optarg);
                break;
            case 'L':
                tx_buffer_size = (size_t)atoi(optarg);
                break;
            case 'B':
                buffer_before_start = atol(optarg);
                break;
            case 'c':
                cpu = atoi(optarg);
                break;
            case 'p':
                rt_prio = atoi(optarg);
                break;
            case 'P':
                so_priority = atoi(optarg);
                break;
            case 'D':
                enable_deadline_mode = SOF_TXTIME_DEADLINE_MODE;
                break;
            case 'E':
                enable_report_errors = SOF_TXTIME_REPORT_ERRORS;
                break;
            case 'A':
                alternate_mode = 1;
                break;
            case 'h':
                usage();
                return 0;
            case '?':
                usage();
                return -1;
        }
    }

    if (!udp_dest_ip) {
        fprintf(stderr, "No unicast destination IP address specified.\n");
        usage();
        return -1;
    }
    if (!inet_aton(udp_dest_ip, &dest_addr)) {
        fprintf(stderr, "Bad unicast destination.\n");
        usage();
        return -1;
    }
    fprintf(stderr, "Unicast destination is:\t%s:%d\n", udp_dest_ip, udp_port);

    if (interval_ns < 0) {
        fprintf(stderr, "Interval must be non-negative.\n");
        usage();
        return -1;
    }

    if (!is_multiple_of_32(interval_ns)) {
        fprintf(stderr, "Interval must be a multiple of 32.\n");
        fprintf(stderr, "Closest multiple of 32 is:\t%llu\n", floor_to_multiple_of_32(interval_ns));
        usage();
        return -1;
    }

    if (!iface) {
        fprintf(stderr, "No network interface specified.\n");
        usage();
        return -1;
    }

    if (num_packets < 1) {
        fprintf(stderr, "Number of packets must be positive value.\n");
        usage();
        return -1;
    }

    err = set_sched_settings(pthread_self(), cpu, rt_prio);
    if (err) {
        return -1;
    }

    fd = open_udp_socket(iface);
    if (fd < 0) {
        fprintf(stderr, "Failed to open UDP socket.\n");
        return -1;
    }

    if (tx_buffer_size < 18 || tx_buffer_size > 1472) {
        fprintf(stderr, "Bad tx buffer size. Must be between 18 and 1472 bytes.\n");
        usage();
        err = -1;
        goto cleanup;
    }
    tx_buffer = malloc(tx_buffer_size);
    if (!tx_buffer) {
        fprintf(stderr, "Failed to allocate tx buffer.\n");
        err = -1;
        goto cleanup;
    }

    err = etfloop_busy(fd);

free_malloc:
    free(tx_buffer);
cleanup:
    close(fd);
    return err;
}
