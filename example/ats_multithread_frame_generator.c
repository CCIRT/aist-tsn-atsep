/* Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology
 * (AIST). All rights reserved.
 * SPDX-License-Identifier: MIT
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <ats.h>
#include <errno.h>
#include <linux/types.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LINK_SPEED 1000000000ULL
#define ONE_SEC_NS 1000000000ULL
#define DEFAULT_NW_OVERHEAD 66
#define MAX_FLOWS 64
#define MAX_PAYLOAD_SIZE 1472
#define MIN_PAYLOAD_SIZE 18
#define THREAD_START_DELAY_US 100

struct flow_config {
    int dest_port;
    int src_port;
    int num_packet;
    __u64 cir;
    int cbs_multiplier;
    int so_priority;
    int payload_size;
};

struct thread_arg {
    int id;
    const char* ifname;
    const char* dest_ip;
    __u64 link_speed;
    int nw_overhead;
    struct flow_config flow;
    int print_time;
    __u64* ets;
    int result;
};

static void* flow_thread(void* arg)
{
    struct thread_arg* ta = (struct thread_arg*)arg;
    struct flow_config* fc = &ta->flow;
    unsigned char tx_buf[MAX_PAYLOAD_SIZE];
    struct sockaddr_in dest_addr;
    int err;

    memset(tx_buf, 0, fc->payload_size);
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons((unsigned short)fc->dest_port);
    inet_pton(AF_INET, ta->dest_ip, &dest_addr.sin_addr);

    int fd = ats_open_udp_socket(ta->ifname, fc->src_port, 0);
    if (fd < 0) {
        fprintf(stderr, "flow[%d]: failed to open socket: %s\n", ta->id, strerror(errno));
        ta->result = -1;
        return NULL;
    }

    if (setsockopt(fd, SOL_SOCKET, SO_PRIORITY, &fc->so_priority, sizeof(fc->so_priority)) < 0) {
        fprintf(stderr, "flow[%d]: failed to set SO_PRIORITY: %s\n", ta->id, strerror(errno));
        ta->result = -1;
        goto cleanup;
    }

    __u32 cbs = (fc->payload_size + ta->nw_overhead) * 8 * fc->cbs_multiplier;

    ats_ctx_t* ctx = ats_create_ctx();
    if (!ctx) {
        fprintf(stderr, "flow[%d]: failed to create ctx\n", ta->id);
        ta->result = -1;
        goto cleanup;
    }

    if (ats_set_flow_ctx(ctx, fd, fc->cir, cbs, ta->link_speed) < 0) {
        fprintf(stderr, "flow[%d]: ats_set_flow_ctx failed: %s\n", ta->id, strerror(errno));
        ta->result = -1;
        goto cleanup_ctx;
    }

    fprintf(stderr, "flow[%d]: cir=%llu, src=%d, dest=%d, n=%d, payload=%d\n", ta->id,
            (unsigned long long)fc->cir, fc->src_port, fc->dest_port, fc->num_packet,
            fc->payload_size);

    for (int i = 0; i < fc->num_packet; i++) {
        if (ta->print_time) {
            __u64 et;
            err = ats_sendmsg_ex_ctx(ctx, tx_buf, fc->payload_size, &dest_addr, &et);
            ta->ets[i] = et;
        }
        else {
            err = ats_sendmsg_ctx(ctx, tx_buf, fc->payload_size, &dest_addr);
        }
        if (err < 0) {
            fprintf(stderr, "flow[%d]: sendmsg failed at i=%d: %s\n", ta->id, i, strerror(errno));
            ta->result = -1;
            goto cleanup_ctx;
        }
    }

    ta->result = 0;

cleanup_ctx:
    ats_destroy_ctx(ctx);
cleanup:
    ats_close_udp_socket(fd);
    return NULL;
}

static int parse_csv(const char* path, struct flow_config* flows, int max_flows)
{
    FILE* fp = fopen(path, "r");
    if (!fp) {
        fprintf(stderr, "failed to open csv: %s: %s\n", path, strerror(errno));
        return -1;
    }

    char line[512];
    int count = 0;

    while (fgets(line, sizeof(line), fp)) {
        if (line[0] == '#' || line[0] == '\n' || line[0] == '\r') {
            continue;
        }

        if (count >= max_flows) {
            fprintf(stderr, "too many flows (max %d)\n", max_flows);
            fclose(fp);
            return -1;
        }

        struct flow_config* fc = &flows[count];
        int parsed = sscanf(line, "%d, %d, %d, %llu, %d, %d, %d", &fc->dest_port, &fc->src_port,
                            &fc->num_packet, &fc->cir, &fc->cbs_multiplier, &fc->so_priority,
                            &fc->payload_size);
        if (parsed != 7) {
            fprintf(stderr, "csv parse error at line %d (got %d fields, expected 7)\n", count + 1,
                    parsed);
            fclose(fp);
            return -1;
        }

        if (fc->payload_size < MIN_PAYLOAD_SIZE || fc->payload_size > MAX_PAYLOAD_SIZE) {
            fprintf(stderr, "csv error at line %d: payload_size %d out of range (%d-%d)\n",
                    count + 1, fc->payload_size, MIN_PAYLOAD_SIZE, MAX_PAYLOAD_SIZE);
            fclose(fp);
            return -1;
        }

        count++;
    }

    fclose(fp);
    return count;
}

static void print_aet_csv(int flow_id, __u64* ets, int num, __u64 pdm, __u64 phy_len)
{
    for (int i = 0; i < num; i++) {
        __u64 aet = ets[i] + pdm;
        if (i == 0) {
            printf("%d,%d,%llu,%llu,\n", flow_id, i, (unsigned long long)ets[i],
                   (unsigned long long)aet);
        }
        else {
            __u64 diff = aet - (ets[i - 1] + pdm);
            printf("%d,%d,%llu,%llu,%llu\n", flow_id, i, (unsigned long long)ets[i],
                   (unsigned long long)aet, (unsigned long long)diff);
        }
    }

    if (num < 2) return;

    __u64 elapsed = ets[num - 1] - ets[0];
    double elapsed_sec = (double)elapsed / ONE_SEC_NS;
    __u64 bit_transferred = phy_len * 8 * num;
    double rate = (double)bit_transferred / elapsed_sec;

    fprintf(stderr, "flow[%d]: elapsed_ns=%llu, rate_bps=%.0f\n", flow_id,
            (unsigned long long)elapsed, rate);
}

void usage()
{
    fprintf(stderr,
            "\n"
            "Usage: ats_multithread_frame_generator -I IFNAME -d DEST_IP -f CSV_FILE\n"
            "                               [-l LINK_SPEED] [-O NW_OVERHEAD] [-M PDM]\n"
            "                               [-Pvh]\n"
            "\n"
            "Options:\n"
            "  -I <IFNAME>       Network interface name\n"
            "  -d <DEST_IP>      Destination IP address\n"
            "  -f <CSV_FILE>     CSV file with per-flow configuration\n"
            "  -l <LINK_SPEED>   Link speed in bps (default: %llu)\n"
            "  -O <NW_OVERHEAD>  Network overhead in bytes (default: %d)\n"
            "  -M <PDM>          Processing Delay Max in ns (default: %d)\n"
            "  -P                Print AET of packets as CSV\n"
            "  -v                Enable debug mode\n"
            "  -h                Print this help message\n"
            "\n"
            "CSV format (one flow per line, # for comments):\n"
            "  destport, srcport, num_packet, cir, cbs_multiplier, so_priority, payload_size\n"
            "\n"
            "  payload_size: UDP payload size in bytes (%d-%d)\n"
            "  cbs_multiplier: CBS = (payload_size + nw_overhead) * 8 * cbs_multiplier\n"
            "\n",
            (unsigned long long)LINK_SPEED, DEFAULT_NW_OVERHEAD, ATS_PROCESSING_DELAY_MAX,
            MIN_PAYLOAD_SIZE, MAX_PAYLOAD_SIZE);
}

int main(int argc, char* argv[])
{
    int opt;
    char* ifname = NULL;
    char* dest_ip = NULL;
    char* csv_path = NULL;
    __u64 link_speed = LINK_SPEED;
    __u64 pdm = 0;
    int nw_overhead = DEFAULT_NW_OVERHEAD;
    int print_time = 0;
    int enable_debug_mode = 0;

    while (EOF != (opt = getopt(argc, argv, "I:d:f:l:O:M:Pvh"))) {
        switch (opt) {
            case 'I':
                ifname = optarg;
                break;
            case 'd':
                dest_ip = optarg;
                break;
            case 'f':
                csv_path = optarg;
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
            case 'P':
                print_time = 1;
                break;
            case 'v':
                enable_debug_mode = 1;
                break;
            case 'h':
                usage();
                return 0;
            case '?':
                usage();
                return -1;
        }
    }

    if (!ifname) {
        fprintf(stderr, "Network interface not specified. Use -I.\n");
        return -1;
    }

    if (!dest_ip) {
        fprintf(stderr, "Destination IP address not specified. Use -d.\n");
        return -1;
    }

    if (!csv_path) {
        fprintf(stderr, "CSV file not specified. Use -f.\n");
        return -1;
    }

    if (nw_overhead < 0) {
        fprintf(stderr, "Invalid NW_OVERHEAD: %d\n", nw_overhead);
        return -1;
    }

    struct flow_config flows[MAX_FLOWS];
    int num_flows = parse_csv(csv_path, flows, MAX_FLOWS);
    if (num_flows <= 0) {
        fprintf(stderr, "No valid flows found in %s\n", csv_path);
        return -1;
    }

    ats_set_network_overhead_in_byte(nw_overhead);

    if (pdm && ats_set_processing_delay_max(pdm) < 0) {
        perror("ats_set_processing_delay_max failed");
        __u64 ceilpdm = (pdm + 31) & ~31;
        fprintf(stderr, "PDM must be a multiple of 32. Nearest valid value: %llu\n",
                (unsigned long long)ceilpdm);
        return -1;
    }
    pdm = ats_get_processing_delay_max();

    if (enable_debug_mode) {
        ats_set_debug_mode(1);
    }

    fprintf(stderr, "starting %d flow(s)\n", num_flows);

    pthread_t threads[MAX_FLOWS];
    struct thread_arg args[MAX_FLOWS];

    for (int i = 0; i < num_flows; i++) {
        args[i].id = i;
        args[i].ifname = ifname;
        args[i].dest_ip = dest_ip;
        args[i].link_speed = link_speed;
        args[i].nw_overhead = nw_overhead;
        args[i].flow = flows[i];
        args[i].print_time = print_time;
        args[i].ets = NULL;
        args[i].result = 0;

        if (print_time) {
            args[i].ets = malloc((size_t)flows[i].num_packet * sizeof(__u64));
            if (!args[i].ets) {
                fprintf(stderr, "flow[%d]: failed to allocate ets buffer\n", i);
                for (int j = 0; j < i; j++) {
                    pthread_join(threads[j], NULL);
                    free(args[j].ets);
                }
                return -1;
            }
        }

        int err = pthread_create(&threads[i], NULL, flow_thread, &args[i]);
        if (err) {
            fprintf(stderr, "flow[%d]: pthread_create failed: %s\n", i, strerror(err));
            for (int j = 0; j < i; j++) {
                pthread_join(threads[j], NULL);
                free(args[j].ets);
            }
            free(args[i].ets);
            return -1;
        }

        if (i < num_flows - 1) {
            usleep(THREAD_START_DELAY_US);
        }
    }

    int exit_code = 0;
    for (int i = 0; i < num_flows; i++) {
        pthread_join(threads[i], NULL);
        if (args[i].result < 0) {
            exit_code = -1;
        }
    }

    if (print_time) {
        printf("flow,index,et,aet,diff\n");
        for (int i = 0; i < num_flows; i++) {
            if (args[i].result == 0) {
                __u64 phy_len = (__u64)(flows[i].payload_size + nw_overhead);
                print_aet_csv(i, args[i].ets, flows[i].num_packet, pdm, phy_len);
            }
        }
    }

    for (int i = 0; i < num_flows; i++) {
        free(args[i].ets);
    }

    return exit_code;
}
