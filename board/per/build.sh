#!/bin/sh
# Cross-compile the board-side PER programs (static, armv7l, Buildroot target).
# The compiler ships with Vitis 2021.1; any arm-linux-gnueabihf-gcc works.
set -e
CC=${CC:-/g/Xilinx/Vitis/2021.1/gnu/aarch32/nt/gcc-arm-linux-gnueabi/bin/arm-linux-gnueabihf-gcc.exe}
cd "$(dirname "$0")"
for p in lora_trace_stream lora_tx_noise; do
  "$CC" -O2 -static -Wall -Wextra -o "$p" "$p.c" -lm
done
