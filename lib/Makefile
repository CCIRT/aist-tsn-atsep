# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
CC = gcc
RM = rm
CP = cp
MD = mkdir

SRC_DIR = src
OBJ_DIR = build/obj
TARGET = build/libats.so

SRCS = ats.c
OBJS = $(patsubst %.c, $(OBJ_DIR)/%.o, $(SRCS))

CFLAGS = -Wall -fPIC
INCLUDE_PATH = include

INCLUDE = -I$(INCLUDE_PATH)
LDFLAGS = -shared
LIBS = 

# echo:
# 	@echo $(SRCS)
# 	@echo $(OBJS)

$(TARGET): $(OBJS)
	$(MD) -p $(dir $@)
	$(CC) -o $@ $^ $(LDFLAGS) $(INCLUDE)

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.c
	$(MD) -p $(dir $@)
	$(CC) -c $< -o $@ $(CFLAGS) $(INCLUDE)

.PHONY: clean
clean:
	$(RM) -r $(OBJ_DIR) $(TARGET)

.PHONY: all
all: clean $(TARGET)


.PHONY: tune
tune: CFLAGS += -DATS_TUNE
tune: $(TARGET)

.PHONY: debug
debug: CFLAGS += -DATS_TUNE -DATS_DELTA_DEBUG
debug: $(TARGET)

