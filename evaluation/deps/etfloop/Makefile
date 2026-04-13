# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
CC := gcc
TARGET := etfloop
RM = rm
SRC := etfloop.c

CFLAGS := -Wall -Wextra -O2
LDLIBS := -lpthread -lm

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) -o $@ $< $(LDLIBS)

clean:
	$(RM) -f $(TARGET)
