#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/uart build-crt/video
# Upstream's empty ASSERTION_ERROR module is instantiated with a string port.
# Replace only those compile-time guards with equivalent simulation assertions.
sed 's/ASSERTION_ERROR PARAMETER_OUT_OF_RANGE("[^"]*");/initial $fatal(1,"UART parameter range");/' \
 src/iosys/uart_fixed.v > build-crt/uart_fixed_test.v
flags=(-CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole')
verilator --binary --timing --assert -Wno-fatal -DSIM --top-module tb_crt_uart \
 --Mdir build-crt/uart -j 4 tests/crt/tb_crt_uart.sv src/iosys/iosys_bl616.v \
 build-crt/uart_fixed_test.v src/iosys/tc_crt_config.sv "${flags[@]}" > build-crt/uart-build.log 2>&1
./build-crt/uart/Vtb_crt_uart
# Compare against the actual pinned source, not a second copy of the new algorithm.
git show 724994b64e598edf9d11e8824e45895cc2d851a3:src/nes2hdmi.sv | \
 sed 's/module nes2hdmi (/module baseline_nes2hdmi (/' > build-crt/baseline_nes2hdmi.sv
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_video \
 --Mdir build-crt/video -j 4 tests/crt/tb_crt_video.sv tests/crt/hdmi_stub.sv \
 build-crt/baseline_nes2hdmi.sv src/nes2hdmi.sv src/iosys/tc_osd_layer.sv \
 src/iosys/tc_crt_config.sv src/iosys/crt_filter.sv "${flags[@]}" > build-crt/video-build.log 2>&1
./build-crt/video/Vtb_crt_video
