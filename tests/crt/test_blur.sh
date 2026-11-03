#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/blur
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_blur \
 --Mdir build-crt/blur -j 4 tests/crt/tb_crt_blur.sv src/iosys/crt_filter.sv \
 -CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' \
 -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole' > build-crt/blur-build.log 2>&1
./build-crt/blur/Vtb_crt_blur
