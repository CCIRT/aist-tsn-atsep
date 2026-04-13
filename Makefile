# Copyright (c) 2024-2026 The National Institute of Advanced Industrial Science and Technology (AIST). All rights reserved.
# SPDX-License-Identifier: MIT
.PHONY = all clean tune

all: 
	$(MAKE) -C lib
	$(MAKE) -C example

clean:
	$(MAKE) -C lib clean
	$(MAKE) -C example clean

tune:
	$(MAKE) -C lib tune
	$(MAKE) -C example

debug:
	$(MAKE) -C lib debug
	$(MAKE) -C example