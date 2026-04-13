# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
import statistics
import sys
from datetime import datetime, timedelta

import click


def parse_time_str_ns(time_str: str) -> tuple[datetime, int]:
    # Assume the format is 'HH:MM:SS.sssssssss'
    dt_tmp, _, ns_tmp = time_str.partition(".")
    dt = datetime.strptime(dt_tmp, "%H:%M:%S")
    ns = int(ns_tmp)
    return dt, ns


# read from stdin
# return a list of tuple of datetime, nanosecond and source port nunber
def read_stdin() -> list[tuple[datetime, int, int]]:
    time_list: list[tuple[datetime, int, int]] = []

    # Read from stdin
    for line in sys.stdin:
        # split the line by space and get the first column
        line_split = line.split()
        time_str = line_split[0]
        dt, ns = parse_time_str_ns(time_str)

        sourceport_str = line_split[2].split(".")[4]
        sourceport = int(sourceport_str)

        time_list.append((dt, ns, sourceport))

    return time_list


def check_alternate() -> None:
    first_port: int = 0
    second_port: int = 0
    prev_port: int = 0
    count = 0

    for line in sys.stdin:
        count += 1
        line = line.strip()
        line = line.split()
        this_port = int(line[2].split(".")[4])
        if first_port == 0:
            first_port = this_port
            prev_port = this_port
            continue
        if second_port == 0:
            second_port = this_port
            if first_port == second_port:
                print("First and second port are the same.")
                return

        if count % 2 == 1:
            if not (this_port == first_port and prev_port == second_port):
                print(f"Port {this_port} is not alternating.")
                return
        else:
            if not (this_port == second_port and prev_port == first_port):
                print(f"Port {this_port} is not alternating.")
                return

        prev_port = this_port

    print("All ports are alternating.")


def calc_interval(time_list: list[tuple[datetime, int]]) -> list[int]:
    interval_list: list[int] = []

    first: bool = True
    for dt_now, ns_now in time_list:
        if first:
            dt_prev, ns_prev = dt_now, ns_now
            first = False
            continue
        dt_diff = dt_now - dt_prev
        ns_diff = ns_now - ns_prev
        # use ns_diff as a total nanosecond difference
        # if fraction part is negative, normalize it
        while ns_diff < 0:
            ns_diff += 1_000_000_000
            dt_diff -= timedelta(seconds=1)
        # if second part is more than 0, add it to ns_diff
        while dt_diff.total_seconds() > 0:
            dt_diff -= timedelta(seconds=1)
            ns_diff += 1_000_000_000
        interval_list.append(ns_diff)

        # refresh the previous time
        dt_prev, ns_prev = dt_now, ns_now

    return interval_list


def calc_print_stats(interval_list: list[int], print_intervals: bool) -> None:
    if len(interval_list) == 0:
        print("There are not enough data to calculate the interval")
        return

    mean_val = statistics.mean(interval_list)
    max_val = max(interval_list)
    min_val = min(interval_list)
    median_val = statistics.median(interval_list)
    stdev_val = statistics.stdev(interval_list) if len(interval_list) > 1 else 0

    # print them all
    print(f"NumPackets: {len(interval_list)+1}")
    # print(f"Mean\t{mean_val}")
    # print(f"Median\t{median_val}")
    # print(f"Max\t{max_val}")
    # print(f"Min\t{min_val}")
    # print(f"SD\t{stdev_val}")

    # print stats in a line delimited by tab
    print("\n### Stats : Horizontal format (nanoseconds)\n")
    print("Mean\tMedian\tMax\tMin\tMax-Min\tSD")
    print(f"{mean_val}\t{median_val}\t{max_val}\t{min_val}\t{max_val - min_val}\t{stdev_val}")

    # print each stat per line
    print("\n### Stats : Vertical format (nanoseconds)\n")
    print("Mean\tMax\tMin\tMax-Min\tSD")
    print(mean_val)
    print(max_val)
    print(min_val)
    print(max_val - min_val)
    print(stdev_val)

    if print_intervals:
        print("\n### Packet intervals (nanoseconds)\n")
        print("No.\tInterval")
        for i, interval in enumerate(interval_list):
            print(f"{i}\t{interval}")


def validate_rate(ctx, param, value):
    if value > 2:
        raise click.BadParameter("Cannot calculate rate for more than 2 flows.")
    return value


# get timedelta from two tuples of datetime and nanosecond
# Assumes that the second tuple is always greater than the first tuple
def get_timedelta(first: tuple[datetime, int], second: tuple[datetime, int]) -> tuple[timedelta, int]:
    dt_diff = second[0] - first[0]
    ns_diff = second[1] - first[1]

    while ns_diff < 0:
        ns_diff += 1_000_000_000
        dt_diff -= timedelta(seconds=1)

    return dt_diff, ns_diff


# get timedelta of the list
def get_duration(time_list: list[tuple[datetime, int]]) -> tuple[timedelta, int]:
    first = time_list[0]
    last = time_list[-1]
    return get_timedelta(first, last)


# calculate rate of the flow
# return the rate in bps and the duration in seconds
def calc_rate(time_list: list[tuple[datetime, int]], frame_size: int) -> tuple[float, float]:
    if len(time_list) <= 1:
        return 0, 0

    duration, ns_duration = get_duration(time_list)
    total_duration = duration.total_seconds() + ns_duration / 1_000_000_000

    # calculate the rate in Mbps
    rate = (len(time_list) * frame_size * 8) / total_duration
    return rate, total_duration


@click.command()
@click.option("--print-intervals", "-p", is_flag=True, help="Print the interval values")
@click.option("--is-alternate", "-a", is_flag=True, help="Only check if the input alternates line.")
@click.option(
    "-r",
    "--rate",
    count=True,
    help="Calculate the rate of the input flow. Specify twice when two contending flows exist and you want to calculate rate for each flow.",
    callback=validate_rate,
)
@click.option(
    "--frame-size",
    "-f",
    type=int,
    help="Specify the frame size on physical layer in bytes. (default=1538)",
    default=1538,
)
@click.option("--first-port", "-1", type=int, help="Specify the first port number.", default=11111)
@click.option("--second-port", "-2", type=int, help="Specify the second port number.", default=22222)
def main(
    print_intervals: bool, is_alternate: bool, rate: int, frame_size: int, first_port: int, second_port: int
) -> None:
    if is_alternate:
        check_alternate()
    else:
        time_list: list[tuple[datetime, int, int]] = read_stdin()

        if len(time_list) <= 1:
            print("There are not enough data to calculate the interval")
            return

        time_list_all: list[tuple[datetime, int]] = [(dt, ns) for dt, ns, _ in time_list]
        time_list_1: list[tuple[datetime, int]] = list()
        time_list_2: list[tuple[datetime, int]] = list()
        time_list_2_rest: list[tuple[datetime, int]] = list()
        time_list_2_all: list[tuple[datetime, int]] = (
            list()
        )  # includes all packets of the second flow, before and after the first flow

        tmp_22222: list[tuple[datetime, int]] = list()
        started_11111 = False

        for dt, ns, sourceport in time_list:
            if sourceport == first_port:
                if not started_11111:
                    started_11111 = True
                time_list_1.append((dt, ns))
                # Add tmp_22222 to time_list_2 and clear tmp_22222
                time_list_2.extend(tmp_22222)
                tmp_22222.clear()
            if sourceport == second_port:
                if started_11111:
                    tmp_22222.append((dt, ns))
                time_list_2_all.append((dt, ns))
        time_list_2_rest.extend(tmp_22222)

        #
        # print(f'timelist1 first: {time_list_1[0]}, last: {time_list_1[-1]}')
        # print(f'timelist2 first: {time_list_2[0]}, last: {time_list_2[-1]}')
        #

        if rate == 2:
            if len(time_list_1) == 0 or len(time_list_2) == 0:
                print("There are not enough data to calculate the interval")
                return

            rate_1_bps, duration_1 = calc_rate(time_list_1, frame_size)
            rate_2_bps, duration_2 = calc_rate(time_list_2, frame_size)
            rate_2_rest_bps, duration_2_rest = calc_rate(time_list_2_rest, frame_size)

            # show the rates in Mbps and the duration in seconds in tab
            print("\n### Overall rate\n")
            print("Flow\tRate(Mbps)\tDuration(s)")
            print(f"1\t{rate_1_bps / 1_000_000}\t{duration_1}")
            print(f"2\t{rate_2_bps / 1_000_000}\t{duration_2}")
            print(f"2rest\t{rate_2_rest_bps / 1_000_000}\t{duration_2_rest}")

            # all2 = time_list_2 + time_list_2_rest
            rate_all2_bps, duration_all2 = calc_rate(time_list_2_all, frame_size)
            print(f"2all:\t{rate_all2_bps / 1_000_000}\t{duration_all2}")
            print()

            print("----- Flow 1 -----")
            interval_list_1 = calc_interval(time_list_1)
            calc_print_stats(interval_list_1, print_intervals)

            print("\n----- Flow 2 -----")
            interval_list_2 = calc_interval(time_list_2)
            calc_print_stats(interval_list_2, print_intervals)

            print("\n----- Flow 2(all) -----")
            interval_list_all2 = calc_interval(time_list_2_all)
            calc_print_stats(interval_list_all2, print_intervals)
        else:

            if rate == 1:
                # calculate rate of time_list_all
                rate_all_bps, duration_all = calc_rate(time_list_all, frame_size)
                print("\n### Overall rate\n")
                print("Flow\tRate(Mbps)\tDuration(s)")
                print(f"1\t{rate_all_bps / 1_000_000}\t{duration_all}")
                print()

            print("----- Flow 1 -----")
            interval_list_all = calc_interval(time_list_all)
            calc_print_stats(interval_list_all, print_intervals)


if __name__ == "__main__":
    main()
