BPF_CLANG ?= clang
BPF_CFLAGS := -O2 -g -Wall -Werror \
	-target bpf \
	-D__TARGET_ARCH_$(shell uname -m | sed 's/x86_64/x86/' | sed 's/aarch64/arm64/') \
	-I./src

CC ?= cc
CFLAGS := -O2 -g -Wall -Werror
LDFLAGS := -lbpf -lelf -lz

SRC_DIR := src
BUILD_DIR := build

VMLINUX_BTF := /sys/kernel/btf/vmlinux

BPF_OBJ := $(BUILD_DIR)/ebpf_tool.bpf.o
SKEL_H  := $(SRC_DIR)/ebpf_tool.skel.h
VMLINUX_H := $(SRC_DIR)/vmlinux.h

USER_BIN := $(BUILD_DIR)/ebpf_tool

.PHONY: all clean
all: $(USER_BIN)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# Generate vmlinux.h from the running kernel's BTF
$(VMLINUX_H): | $(BUILD_DIR)
	bpftool btf dump file $(VMLINUX_BTF) format c > $@

# Build eBPF object (CO-RE)
$(BPF_OBJ): $(SRC_DIR)/ebpf_tool.bpf.c $(SRC_DIR)/common.h $(VMLINUX_H) | $(BUILD_DIR)
	$(BPF_CLANG) $(BPF_CFLAGS) -c $< -o $@

# Generate skeleton header from BPF object
$(SKEL_H): $(BPF_OBJ)
	bpftool gen skeleton $< > $@

# Build userspace loader
$(USER_BIN): $(SRC_DIR)/ebpf_tool.c $(SRC_DIR)/common.h $(SKEL_H) | $(BUILD_DIR)
	$(CC) $(CFLAGS) -I$(SRC_DIR) $< -o $@ $(LDFLAGS)

clean:
	rm -rf $(BUILD_DIR) $(SKEL_H) $(VMLINUX_H)
