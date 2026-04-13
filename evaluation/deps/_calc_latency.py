# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
import sys

import numpy as np


# Receive a string in the format <epoch seconds>.<nanoseconds> from tcpdump -tt --nano
# and return the corresponding epoch integer in nanoseconds
def parse_epoch_timestamp(time_str: str) -> int:
    epoch_second_str, nanosecond_str = time_str.split(".", 1)
    normalized_nanosecond_str = nanosecond_str.ljust(9, "0")[:9]
    return int(epoch_second_str) * 1000000000 + int(normalized_nanosecond_str)


if len(sys.argv) != 3:
    print("Usage: python calc_latency.py <file1> <file2>")
    print("file1: tcpdump timestamp only file (epoch.nanoseconds)")
    print("file2: aet (nano epoch) file")
    print(
        "- If a drop occurs and the number of lines in both files does not match, it is assumed that the drop occurred at the beginning for calculation purposes."
    )
    sys.exit(1)

file1 = sys.argv[1]
file2 = sys.argv[2]

epoch_1: list[int] = []
epoch_2: list[int] = []

diffs: list[int] = []

with open(file2, "r") as f2:
    for line2 in f2:
        time2 = int(line2)  # Convert to integer nanoseconds
        epoch_2.append(time2)

with open(file1, "r") as f1:
    for line1 in f1:
        time1 = parse_epoch_timestamp(line1.strip())
        epoch_1.append(time1)

num_drop = len(epoch_2) - len(epoch_1)
print(f"num_epoch_1: {len(epoch_1)}")
print(f"num_epoch_2: {len(epoch_2)}")
print(f"num_drop: {num_drop}")

# epoch_1: tcpdump           0 1 2 3 4 ...  95
# epoch_2: aet     0 1 2 3 4 5 6 7 8 9 ... 100

for i in range(len(epoch_2)):
    if i < num_drop:
        continue
    time1 = epoch_1[i - num_drop]
    time2 = epoch_2[i]

    # Calculate the difference
    diff = time1 - time2
    diffs.append(diff)
    print(f"{i}: time1: {time1}, time2: {time2}, diff: {diff}")

diffs_array = np.array(diffs)
mean_val = np.mean(diffs_array)
med_val = np.median(diffs_array)
max_val = np.max(diffs_array)
min_val = np.min(diffs_array)
std_val = np.std(diffs_array)

print("### Stats : Horizontal format (nanoseconds)\n")
print("Mean\tMedian\tMax\tMin\tMax-Min\tSD")
print(f"{mean_val}\t{med_val}\t{max_val}\t{min_val}\t{max_val - min_val}\t{std_val}")


print("\n### Stats : Vertical format (nanoseconds)\n")
print("Mean\tMax\tMin\tMax-Min\tSD")
print(mean_val)
print(max_val)
print(min_val)
print(max_val - min_val)
print(std_val)

# print(np.mean(diffs))
# print(np.max(diffs))
# print(np.min(diffs))
# print(np.max(diffs) - np.min(diffs))
# print(np.std(diffs))
