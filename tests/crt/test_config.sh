#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/config
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_config \
 --Mdir build-crt/config -j 4 tests/crt/tb_crt_config.sv src/iosys/tc_crt_config.sv \
 src/iosys/crt_filter.sv -CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' \
 -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole' > build-crt/config-build.log 2>&1
./build-crt/config/Vtb_crt_config
