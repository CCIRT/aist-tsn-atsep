/* Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology
 * (AIST). All rights reserved.
 * SPDX-License-Identifier: MIT
 */
#include <arpa/inet.h>
#include <ats.h>
#include <errno.h>
#include <linux/net_tstamp.h>
#include <net/if.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

// Nanosecond per second
#define ATS_NS_PER_SEC 1000000000

/**
 * @struct ats_flow
 * @brief The ATS flow structure.
 *
 * Parameters to control an ATS flow.
 *
 */
struct ats_flow {
    /**
     * @brief The file descriptor of the socket which the ATS flow is associated
     */
    int fd;

    /**
     * @brief The Committed Information Rate (CIR) in bits per second.
     */
    __u64 cir;

    /**
     * @brief The Committed Burst Size (CBS) in bits.
     */
    __u32 cbs;

    /**
     * @brief The link speed in bits per second.
     */
    __u64 link_speed;

    /**
     * @brief The Bucket Empty Time in nanoseconds.
     */
    __u64 bucket_empty_time;

    /**
     * @brief The earliest time at which a new frame can be transmitted, in
     * nanoseconds.
     *
     * This value represents the sum of the arrival time of the previous packet
     * and the time required to transmit that packet. It ensures that frames are
     * sent with sufficient inter-frame spacing.
     */
    __u64 next_available_transmission_time;
};

struct ats_ctx {
    struct ats_flow ats_entry;
};

static struct ats_flow ats_entry;

static _Atomic __u64 processing_delay_max = ATOMIC_VAR_INIT(ATS_PROCESSING_DELAY_MAX);
static _Atomic unsigned int network_overhead_in_byte =
    ATOMIC_VAR_INIT(ATS_NETWORK_OVERHEAD_IN_BYTE);
static _Atomic int debug_mode = ATOMIC_VAR_INIT(0);

// TODO consider using thread local counter if performance is an issue
static _Atomic __u64 counter = ATOMIC_VAR_INIT(0);

static int __ats_sendmsg(struct ats_flow* flow, int fd, void* data, size_t data_len,
                         struct sockaddr_in* dest_addr, __u64* et);
static __u64 ats_calc_next_avail_tx_time(__u64 arrival_time, __u64 phy_frame_size_bits,
                                         __u64 link_speed);
static __u64 ats_process_frame(struct ats_flow* flow, int fd, void* data, size_t data_len,
                               struct sockaddr_in* dest_addr);
static int ats_assign_and_proceed(int fd, void* data, size_t data_len,
                                  struct sockaddr_in* dest_addr, __u64 eligibility_time);
static __u64 ats_get_time_ns();
static void ats_debug_log(const char* format, ...);
static void ats_debug_perror(const char* msg);
static inline __u64 ats_max_u64(__u64 a, __u64 b) { return a > b ? a : b; }

static int __ats_set_flow(struct ats_flow* flow, int fd, __u64 cir, __u32 cbs, __u64 link_speed);

ats_ctx_t* ats_create_ctx(void)
{
    ats_ctx_t* ctx = calloc(1, sizeof(ats_ctx_t));
    if (!ctx) {
        return NULL;
    }

    return ctx;
}

void ats_destroy_ctx(ats_ctx_t* ctx)
{
    if (!ctx) {
        return;
    }

    free(ctx);
}

int ats_set_flow(int fd, __u64 cir, __u32 cbs, __u64 link_speed)
{
    return __ats_set_flow(&ats_entry, fd, cir, cbs, link_speed);
}

int ats_set_flow_ctx(ats_ctx_t* ctx, int fd, __u64 cir, __u32 cbs, __u64 link_speed)
{
    if (!ctx) {
        errno = EINVAL;
        return -1;
    }

    return __ats_set_flow(&ctx->ats_entry, fd, cir, cbs, link_speed);
}

static int __ats_set_flow(struct ats_flow* flow, int fd, __u64 cir, __u32 cbs, __u64 link_speed)
{
    if (link_speed == 0) {
        errno = EINVAL;
        return -1;
    }

    flow->fd = fd;
    flow->cir = cir;
    flow->cbs = cbs;
    flow->link_speed = link_speed;
    flow->bucket_empty_time = 0;
    flow->next_available_transmission_time = 0;

    return 0;
}

int ats_open_udp_socket(const char* ifname, int port, int enable_tx_report_errors)
{
    if (ifname == NULL || strlen(ifname) == 0) {
        errno = EINVAL;
        goto err;
    }

    if (port < 0 || port > 65535) {
        errno = EINVAL;
        goto err;
    }

    int fd;
    struct sockaddr_in addr;
    struct ifreq ifr;

    // init a socket txtime struct
    struct sock_txtime sk_txtime = {0};
    sk_txtime.clockid = ATS_DEFAULT_CLOCK;
    if (enable_tx_report_errors) {
        sk_txtime.flags = SOF_TXTIME_REPORT_ERRORS;
    }
    else {
        sk_txtime.flags = 0;
    }

    // create a socket
    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        ats_debug_perror("Failed to create socket");
        goto err;
    }

    // get the interface IP address which the socket binds to
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, ifname, IFNAMSIZ - 1);
    if (ioctl(fd, SIOCGIFADDR, &ifr) < 0) {
        ats_debug_perror("Failed to get interface address");
        goto err_close;
    }

    // set the socket txtime option
    if (setsockopt(fd, SOL_SOCKET, SO_TXTIME, &sk_txtime, sizeof(sk_txtime)) < 0) {
        ats_debug_perror("Failed to set SO_TXTIME");
        goto err_close;
    }

    // bind the socket to the interface
    if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, ifname, strlen(ifname)) < 0) {
        ats_debug_perror("Failed to set SO_BINDTODEVICE");
        goto err_close;
    }

    // bind the socket to the IP and the port
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr = ((struct sockaddr_in*)&ifr.ifr_addr)->sin_addr;

    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        ats_debug_perror("Failed to bind socket");
        goto err_close;
    }

    return fd;

err_close:
    close(fd);
err:
    return -1;
}

int ats_close_udp_socket(int fd)
{
    if (close(fd) < 0) {
        ats_debug_perror("Failed to close socket");
        return -1;
    }

    return 0;
}

int ats_sendmsg(int fd, void* data, size_t data_len, struct sockaddr_in* dest_addr)
{
    // discard the eligibility time
    __u64 discard_et;
    return __ats_sendmsg(&ats_entry, fd, data, data_len, dest_addr, &discard_et);
}

int ats_sendmsg_ctx(ats_ctx_t* ctx, void* data, size_t data_len, struct sockaddr_in* dest_addr)
{
    if (!ctx) {
        errno = EINVAL;
        return -1;
    }

    // discard the eligibility time
    __u64 discard_et;
    return __ats_sendmsg(&ctx->ats_entry, ctx->ats_entry.fd, data, data_len, dest_addr,
                         &discard_et);
}

int ats_sendmsg_ex(int fd, void* data, size_t data_len, struct sockaddr_in* dest_addr, __u64* et)
{
    return __ats_sendmsg(&ats_entry, fd, data, data_len, dest_addr, et);
}

int ats_sendmsg_ex_ctx(ats_ctx_t* ctx, void* data, size_t data_len, struct sockaddr_in* dest_addr,
                       __u64* et)
{
    if (!ctx) {
        errno = EINVAL;
        return -1;
    }

    return __ats_sendmsg(&ctx->ats_entry, ctx->ats_entry.fd, data, data_len, dest_addr, et);
}

static int __ats_sendmsg(struct ats_flow* flow, int fd, void* data, size_t data_len,
                         struct sockaddr_in* dest_addr, __u64* et)
{
    if (flow == NULL || data == NULL || data_len == 0 || dest_addr == NULL) {
        errno = EINVAL;
        return -1;
    }

    atomic_fetch_add(&counter, 1);
    __u64 eligibility_time = ats_process_frame(flow, fd, data, data_len, dest_addr);

    if (et) {
        *et = eligibility_time;
    }

    return ats_assign_and_proceed(fd, data, data_len, dest_addr, eligibility_time);
}

static __u64 ats_calc_next_avail_tx_time(__u64 arrival_time, __u64 phy_frame_size_bits,
                                         __u64 link_speed)
{
    // calculate the next available transmission time
    __u64 link_speed_transmission_duration = phy_frame_size_bits * ATS_NS_PER_SEC / link_speed;
    // return arrival_time + link_speed_transmission_duration + 6696; /* Gen2 */
    return arrival_time + ats_ceil_to_multiple_of_32(link_speed_transmission_duration); /* Gen4 */
}

static __u64 ats_process_frame(struct ats_flow* flow, int fd, void* data, size_t data_len,
                               struct sockaddr_in* dest_addr)
{
    __u64 length_recovery_duration;   /* nanosecond */
    __u64 empty_to_full_duration;     /* nanosecond */
    __u64 scheduler_eligibility_time; /* nanosecond */
    __u64 bucket_full_time;           /* nanosecond */
    __u64 eligibility_time;           /* nanosecond */

    /* Adjust arrival_time to keep safe frame intervals */
    // __u64 arrival_time = ats_get_time_ns(); /* nanosecond */
    __u64 arrival_time = ats_max_u64(ats_get_time_ns(), flow->next_available_transmission_time);

    unsigned int overhead = atomic_load_explicit(&network_overhead_in_byte, memory_order_relaxed);
    __u64 phy_frame_size_bits = ((__u64)data_len + overhead) * 8;

    length_recovery_duration = phy_frame_size_bits * ATS_NS_PER_SEC / flow->cir;
    empty_to_full_duration = (__u64)flow->cbs * ATS_NS_PER_SEC / flow->cir;
    scheduler_eligibility_time = flow->bucket_empty_time + length_recovery_duration;
    bucket_full_time = flow->bucket_empty_time + empty_to_full_duration;
    eligibility_time = ats_max_u64(arrival_time, scheduler_eligibility_time);
    eligibility_time = ats_ceil_to_multiple_of_32(eligibility_time);

/*
 * Check for the condition where the behavior required by the IEEE specification fails because the
 * blocking sendmsg call is not released in time.
 * This detection may produce false positives when transmission is resumed after a pause. This is
 * because the library has no way to determine whether the sequence is continuous.
 * The first frame is excluded from detection.
 */
#ifdef ATS_TUNE
    if (arrival_time > scheduler_eligibility_time && flow->bucket_empty_time > 0) {
        ats_debug_log(
            "Warning: The arrival time (%llu) of frame #%llu is greater than the scheduler "
            "eligibility time (%llu). The blocking sendmsg call for the previous frame may have "
            "been released too late, possibly causing the intended transmission timing to be "
            "missed. Lowering PDM or increasing SO_SNDBUF may help mitigate this issue.\n",
            arrival_time, atomic_load_explicit(&counter, memory_order_relaxed),
            scheduler_eligibility_time);
    }
#endif

    if (eligibility_time < bucket_full_time) {
        flow->bucket_empty_time = scheduler_eligibility_time;
    }
    else {
        flow->bucket_empty_time = scheduler_eligibility_time + eligibility_time - bucket_full_time;
    }

    flow->next_available_transmission_time =
        ats_calc_next_avail_tx_time(arrival_time, phy_frame_size_bits, flow->link_speed);

    return eligibility_time;
}

static int ats_assign_and_proceed(int fd, void* data, size_t data_len,
                                  struct sockaddr_in* dest_addr, __u64 eligibility_time)
{
    __u64 delay = atomic_load_explicit(&processing_delay_max, memory_order_relaxed);
    __u64 assigned_eligibility_time = eligibility_time + delay;

    struct msghdr msg;
    struct iovec iov;
    struct cmsghdr* cmsg;
    char cmsg_buf[CMSG_SPACE(sizeof(assigned_eligibility_time))];

    iov.iov_base = data;
    iov.iov_len = data_len;

    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_name = dest_addr;
    msg.msg_namelen = sizeof(*dest_addr);
    msg.msg_control = cmsg_buf;
    msg.msg_controllen = sizeof(cmsg_buf);

    cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_TXTIME;
    cmsg->cmsg_len = CMSG_LEN(sizeof(__u64));
    *((__u64*)CMSG_DATA(cmsg)) = assigned_eligibility_time;

/*
 * The LaunchTime of Intel i210 might be misinterpreted if the difference between the txtime and the
 * current time is more than 500ms. Ideally, when the Assigned Eligibility Time (AET) is far in the
 * future, the ETF qdisc should absorb the time. However, if the delta of the etf qdisc is higher
 * than or equal to 500ms, it may not be able to absorb the delay and the packet could reach the NIC
 * too early. Emit a warning when the difference between AET and the current time is greater than
 * 500ms. This warning does not apply when delta is less than 500ms, but it is kept for debugging
 * purposes.
 */
#ifdef ATS_DELTA_DEBUG
    __u64 diff_aet_and_now = assigned_eligibility_time - ats_get_time_ns();
    if (diff_aet_and_now > 500000000) {
        ats_debug_log(
            "Warning: The difference between the assigned "
            "eligibility time of frame#%llu and the current time is more than 500ms "
            "(%llu ns). The frame may be transmitted at unexpected times.\n",
            atomic_load_explicit(&counter, memory_order_relaxed), diff_aet_and_now);
    }
#endif

    return sendmsg(fd, &msg, 0);
}

// get the current time in nanoseconds
static __u64 ats_get_time_ns()
{
    struct timespec ts;
    clock_gettime(ATS_DEFAULT_CLOCK, &ts);
    return ts.tv_sec * ATS_NS_PER_SEC + ts.tv_nsec;
}

__attribute__((unused)) static void ats_debug_log(const char* format, ...)
{
    if (atomic_load_explicit(&debug_mode, memory_order_relaxed)) {
        va_list args;
        va_start(args, format);
        vfprintf(stderr, format, args);
        va_end(args);
    }
}

static void ats_debug_perror(const char* msg)
{
    if (atomic_load_explicit(&debug_mode, memory_order_relaxed)) {
        perror(msg);
    }
}

int ats_set_processing_delay_max(__u64 value)
{
    // check if value is multiple of 32
    if (!ats_is_multiple_of_32(value)) {
        errno = EINVAL;
        return -1;
    }

    atomic_store_explicit(&processing_delay_max, value, memory_order_relaxed);

    return 0;
}

__u64 ats_get_processing_delay_max()
{
    return atomic_load_explicit(&processing_delay_max, memory_order_relaxed);
}

void ats_set_network_overhead_in_byte(unsigned int value)
{
    atomic_store_explicit(&network_overhead_in_byte, value, memory_order_relaxed);
    return;
}

unsigned int ats_get_network_overhead_in_byte()
{
    return atomic_load_explicit(&network_overhead_in_byte, memory_order_relaxed);
}

void ats_set_bucket_empty_time(__u64 value)
{
    ats_entry.bucket_empty_time = value;
    return;
}

int ats_set_bucket_empty_time_ctx(ats_ctx_t* ctx, __u64 value)
{
    if (!ctx) {
        errno = EINVAL;
        return -1;
    }

    ctx->ats_entry.bucket_empty_time = value;
    return 0;
}

__u64 ats_get_bucket_empty_time() { return ats_entry.bucket_empty_time; }

__u64 ats_get_bucket_empty_time_ctx(ats_ctx_t* ctx)
{
    if (!ctx) {
        errno = EINVAL;
        return 0;
    }

    return ctx->ats_entry.bucket_empty_time;
}

int ats_is_multiple_of_32(__u64 value) { return (value & 0x1F) == 0; }

__u64 ats_ceil_to_multiple_of_32(__u64 value) { return (value + 31) & ~31; }

void ats_set_debug_mode(int flag)
{
    atomic_store_explicit(&debug_mode, flag, memory_order_relaxed);
}
