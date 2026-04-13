/* Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology
 * (AIST). All rights reserved.
 * SPDX-License-Identifier: MIT
 */
/**
 * @file ats.h
 * @brief The header file of the ATS library.
 */
#ifndef ATS_H
#define ATS_H

#include <linux/types.h>

/**
 * @def ATS_PROCESSING_DELAY_MAX
 * @brief The Processing Delay Max (PDM) value in nanoseconds which is added to
 * the EligibilityTime.
 *
 * The PDM value must be a multiple of 32 because the LaunchTime of Intel i210
 * is defined in 32-nanosecond units. Use `ats_set_processing_delay_max` to
 * change the PDM. The default value is 100us.
 */
#define ATS_PROCESSING_DELAY_MAX 100000 /* 100us */

/**
 * @def ATS_NETWORK_OVERHEAD_IN_BYTE
 * @brief The overhead of packet encapsulation in bytes.
 *
 * The default value comprises the UDP header (8), the IP header (20), the
 * Ethernet header of the VLAN support (18), Frame Check Sequence (4),
 * Inter-Frame Gap (12), and the preamble (8). Use
 * `ats_set_network_overhead_in_byte` to change the value.
 */
#define ATS_NETWORK_OVERHEAD_IN_BYTE 70

/**
 * @def ATS_DEFAULT_CLOCK
 * @brief The default clock to use for ATS.
 */
#define ATS_DEFAULT_CLOCK CLOCK_TAI

/**
 * @defgroup ats_ctx Thread-safe ATS context API
 * @brief Thread-safe versions of ATS functions using per-flow context.
 *
 * These functions provide the same functionality as their non-ctx counterparts,
 * but use an opaque context object (`ats_ctx_t`) instead of global state,
 * enabling safe use in multithreaded programs.
 *
 * @note The non-ctx (global) API is NOT thread-safe. Use the ctx API for
 * multithreaded applications.
 * @note Each `ats_ctx_t` must be owned by a single thread. Do not share a
 * context across multiple threads.
 * @{
 */

/**
 * @brief Opaque ATS flow context for thread-safe operation.
 */
typedef struct ats_ctx ats_ctx_t;

/**
 * @brief Create a new ATS flow context.
 *
 * The returned context is zero-initialized. The caller must destroy it with
 * `ats_destroy_ctx` when no longer needed.
 *
 * @return ats_ctx_t* A pointer to the new context, or NULL if allocation
 * failed.
 */
ats_ctx_t* ats_create_ctx(void);

/**
 * @brief Destroy an ATS flow context.
 *
 * Passing NULL is a no-op.
 *
 * @param ctx The context to destroy.
 */
void ats_destroy_ctx(ats_ctx_t* ctx);

/**
 * @brief Set the control parameters for an ATS flow context.
 *
 * The `fd` is stored in the context and used by subsequent ats_sendmsg_ctx() /
 * ats_sendmsg_ex_ctx() calls. For reference, see ats_set_flow().
 *
 * @param ctx The ATS flow context.
 * @param fd The file descriptor of the socket which the ATS flow is associated
 * with.
 * @param cir The Committed Information Rate (CIR) in bits per second.
 * @param cbs The Committed Burst Size (CBS) in bits.
 * @param link_speed The link speed in bits per second. Must be greater than 0.
 * @return int 0 on success, -1 if an error occurred and `errno` is set.
 *
 * @note In addition to ats_set_flow() errno values, this function may also set:
 *
 * - `EINVAL`: If `ctx` is NULL.
 */
int ats_set_flow_ctx(ats_ctx_t* ctx, int fd, __u64 cir, __u32 cbs, __u64 link_speed);

/**
 * @brief Send a frame in the ATS flow context.
 *
 * Unlike ats_sendmsg(), the socket file descriptor is taken from the context
 * set by ats_set_flow_ctx(). For reference, see ats_sendmsg().
 *
 * @param ctx The ATS flow context.
 * @param data A pointer to the data to be sent.
 * @param data_len The length of the data to be sent.
 * @param dest_addr A pointer to the destination address structure.
 * @return int The number of bytes sent on success. Otherwise, -1 is returned
 * and `errno` is set.
 *
 * @note In addition to ats_sendmsg() errno values, this function may also set:
 *
 * - `EINVAL`: If `ctx` is NULL.
 */
int ats_sendmsg_ctx(ats_ctx_t* ctx, void* data, size_t data_len, struct sockaddr_in* dest_addr);

/**
 * @brief Send a frame in the ATS flow context and retrieve the eligibility
 * time.
 *
 * For reference, see ats_sendmsg_ctx().
 *
 * @param ctx The ATS flow context.
 * @param data A pointer to the data to be sent.
 * @param data_len The length of the data to be sent.
 * @param dest_addr A pointer to the destination address structure.
 * @param et A pointer to store the eligibility time set to the sent frame.
 * @return int The number of bytes sent on success. Otherwise, -1 is returned
 * and `errno` is set.
 */
int ats_sendmsg_ex_ctx(ats_ctx_t* ctx, void* data, size_t data_len, struct sockaddr_in* dest_addr,
                       __u64* et);

/**
 * @brief Set the bucket empty time of the context.
 *
 * For reference, see ats_set_bucket_empty_time().
 *
 * @param ctx The ATS flow context.
 * @param value The new bucket empty time in nanoseconds.
 * @return int 0 on success, -1 if `ctx` is NULL (`errno` set to `EINVAL`).
 */
int ats_set_bucket_empty_time_ctx(ats_ctx_t* ctx, __u64 value);

/**
 * @brief Get the bucket empty time of the context.
 *
 * For reference, see ats_get_bucket_empty_time().
 *
 * @param ctx The ATS flow context.
 * @return __u64 The bucket empty time in nanoseconds, or 0 if `ctx` is NULL
 * (`errno` set to `EINVAL`).
 */
__u64 ats_get_bucket_empty_time_ctx(ats_ctx_t* ctx);

/** @} */

/**
 * @defgroup ats_socket Socket management
 * @brief Create and destroy UDP sockets for ATS.
 *
 * These functions manage the socket lifecycle and are used by both the
 * @ref ats_global "global API" and @ref ats_ctx "context API".
 * @{
 */

/**
 * @brief Create a UDP socket for ATS and bind it to the specified interface.
 *
 * This function creates a UDP socket, binds it to the specified network
 * interface, and sets the necessary socket options for ATS. Specifically, it
 * enables the SO_TXTIME option to allow configuring the transmission time.
 *
 * @param ifname The name of the network interface to bind the socket to.
 * @param port The port number to bind the socket to. If 0, the OS will
 * automatically assign a port.
 * @param enable_tx_report_errors Flag to enable or disable transmission error
 * reporting for SO_TXTIME.
 * @return int The file descriptor of the created socket. If an error occurs, -1
 * is returned and errno is set appropriately.
 *
 * @note This function may set the following `errno` values:
 *
 * - `EINVAL`: If `ifname` is NULL or empty or `port` is less than 0 or greater
 * than 65535.
 * - `errno` values set by the `socket()`, `ioctl()`, `setsockopt()`, or
 * `bind()` system calls.
 */
int ats_open_udp_socket(const char* ifname, int port, int enable_tx_report_errors);

/**
 * @brief Close the specified socket.
 *
 * @param fd The file descriptor of the socket to close.
 * @return int 0 on success, -1 if an error occurred and `errno` is set.
 *
 * @note This function may set the following `errno` values:
 *
 * - `errno` values set by the `close()` system call.
 */
int ats_close_udp_socket(int fd);

/** @} */

/**
 * @defgroup ats_global Global ATS flow API
 * @brief ATS flow functions using global state.
 *
 * These functions use global state internally. They are simple to use for
 * single-flow programs, but are **not thread-safe**. For multithreaded
 * applications, use the @ref ats_ctx "context API" instead.
 * @{
 */

/**
 * @brief Set the control parameters for an ATS flow.
 *
 * @param fd The file descriptor of the socket which the ATS flow is associated
 * with.
 * @param cir The Committed Information Rate (CIR) in bits per second.
 * @param cbs The Committed Burst Size (CBS) in bits.
 * @param link_speed The link speed in bits per second. Must be greater than 0.
 *
 * @return int 0 on success, -1 if an error occurred and `errno` is set.
 *
 * @note This function may set the following `errno` values:
 *
 * - `EINVAL`: If `link_speed` is 0.
 */
int ats_set_flow(int fd, __u64 cir, __u32 cbs, __u64 link_speed);

/**
 * @brief Send a frame in the ATS flow.
 *
 * This function sends a frame at the transmission time configured by the ATS
 * scheduler based on IEEE802.1Q-2022. The transmission time is
 * calculated based on the ATS scheduler and then the frame is sent using the
 * `sendmsg` system call.
 *
 * @param fd The file descriptor of the socket.
 * @param data A pointer to the data to be sent.
 * @param data_len The length of the data to be sent.
 * @param dest_addr A pointer to the destination address structure.
 * @return int The number of bytes sent is returned on success. Otherwise, -1 is
 * returned and `errno` is set.
 *
 * @note This function may set the following `errno` values:
 *
 * - `EINVAL`: If `data` is NULL or `data_len` is 0 or `dest_addr` is NULL.
 * - `errno` values set by the `sendmsg()` system call.
 */
int ats_sendmsg(int fd, void* data, size_t data_len, struct sockaddr_in* dest_addr);

/**
 * @brief Send a frame in the ATS flow and also retrieve the eligibility time.
 *
 * See `ats_sendmsg` for details and the other parameters.
 *
 * @param fd The file descriptor of the socket.
 * @param data A pointer to the data to be sent.
 * @param data_len The length of the data to be sent.
 * @param dest_addr A pointer to the destination address structure.
 * @param et A pointer to store the eligibility time set to the sent frame.
 * @return int The number of bytes sent on success. Otherwise, -1 is returned
 * and `errno` is set.
 */
int ats_sendmsg_ex(int fd, void* data, size_t data_len, struct sockaddr_in* dest_addr, __u64* et);

/**
 * @brief Set the bucket empty time.
 *
 * This function changes the bucket empty time, primarily for debugging
 * purposes.
 *
 * @param value The new bucket empty time in nanoseconds.
 */
void ats_set_bucket_empty_time(__u64 value);
__u64 ats_get_bucket_empty_time();

/** @} */

/**
 * @defgroup ats_util Utility and configuration
 * @brief Global configuration and utility functions.
 *
 * These functions configure global parameters shared by both the
 * @ref ats_global "global API" and @ref ats_ctx "context API".
 * @{
 */

/**
 * @brief Set the Processing Delay Max (PDM) value.
 *
 * This function sets the PDM value, which must be a multiple of 32.
 *
 * @param value The PDM value to set.
 * @return int 0 is returned if the value is successfully set. Otherwise, -1 is
 * returned and `errno` is set.
 *
 * @note This function may set the following `errno` values:
 *
 * - `EINVAL`: If the value is not a multiple of 32.
 */
int ats_set_processing_delay_max(__u64 value);
__u64 ats_get_processing_delay_max();

/**
 * @brief Set the transmission overhead on the network that encapsulates data in
 * bytes.
 *
 * See `ATS_NETWORK_OVERHEAD_IN_BYTE` for details.
 */
void ats_set_network_overhead_in_byte(unsigned int value);
unsigned int ats_get_network_overhead_in_byte();

/**
 * @brief Check if the given value is a multiple of 32.
 */
int ats_is_multiple_of_32(__u64 value);

/**
 * @brief Map the given value to the nearest multiple of 32 that is greater than or
 * equal to the value.
 */
__u64 ats_ceil_to_multiple_of_32(__u64 value);

/**
 * @brief Enable or disable debug mode.
 *
 * When debug mode is enabled, the library outputs debug information to
 * stderr.
 */
void ats_set_debug_mode(int flag);

/** @} */

#endif