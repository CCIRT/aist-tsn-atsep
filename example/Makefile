# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
CC = gcc
RM = rm
CP = cp
MD = mkdir

OBJ_DIR = obj
TARGET = ats_frame_generator
TARGET_MT = ats_multithread_frame_generator

SRCS = ats_frame_generator.c
SRCS_MT = ats_multithread_frame_generator.c
OBJS = $(patsubst %.c, $(OBJ_DIR)/%.o, $(SRCS))
OBJS_MT = $(patsubst %.c, $(OBJ_DIR)/%.o, $(SRCS_MT))

CFLAGS = -Wall
INCLUDE_PATH = ../lib/include
LIB_PATH = ../lib/build
LIB_NAME = ats

INCLUDE = -I$(INCLUDE_PATH)
LDFLAGS = -L$(LIB_PATH) 
LIBS = -l$(LIB_NAME) -l pthread

.PHONY: default
default: $(TARGET) $(TARGET_MT)

$(TARGET): $(OBJS)
	@pwd
	$(CC) -o $@ $^ $(CFLAGS) $(INCLUDE) $(LDFLAGS) $(LIBS)

$(TARGET_MT): $(OBJS_MT)
	@pwd
	$(CC) -o $@ $^ $(CFLAGS) $(INCLUDE) $(LDFLAGS) $(LIBS)

$(OBJ_DIR)/%.o: %.c
	$(MD) -p $(dir $@)
	$(CC) -c $< -o $@ $(CFLAGS) $(INCLUDE)

.PHONY: clean
clean:
	$(RM) $(TARGET) $(TARGET_MT)
	$(RM) -r $(OBJ_DIR)

.PHONY: all
all: clean $(TARGET) $(TARGET_MT)
