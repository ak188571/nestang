#!/usr/bin/env bash
set -euo pipefail
export PATH=/ucrt64/bin:/usr/bin:$PATH
export MSYS2_ARG_CONV_EXCL='*'
cd "$(dirname "$0")/../.."
mkdir -p build-crt/scanline build-crt/scanvideo
flags=(-CFLAGS '-BC:/msys64/ucrt64/bin/ -std=c++17' -LDFLAGS '-BC:/msys64/ucrt64/bin/ -mconsole')
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_scanline \
 --Mdir build-crt/scanline -j 4 tests/crt/tb_crt_scanline.sv src/iosys/crt_filter.sv \
 "${flags[@]}" > build-crt/scanline-build.log 2>&1
./build-crt/scanline/Vtb_crt_scanline
git show 724994b64e598edf9d11e8824e45895cc2d851a3:src/nes2hdmi.sv | \
 sed 's/module nes2hdmi (/module baseline_nes2hdmi (/' > build-crt/baseline_nes2hdmi.sv
git show a0c49be884f765c323c6ff3b7342fde995f244f4:src/nes2hdmi.sv | \
 sed -e 's/module nes2hdmi (/module baseline4a_nes2hdmi (/' \
     -e 's/crt_filter crt(/baseline4a_crt_filter crt(/' > build-crt/baseline4a_nes2hdmi.sv
git show a0c49be884f765c323c6ff3b7342fde995f244f4:src/iosys/crt_filter.sv | \
 sed 's/module crt_filter (/module baseline4a_crt_filter (/' > build-crt/baseline4a_crt_filter.sv
verilator --binary --timing --assert -Wno-fatal --top-module tb_crt_scan_video \
 --Mdir build-crt/scanvideo -j 4 tests/crt/tb_crt_scan_video.sv tests/crt/hdmi_stub.sv \
 build-crt/baseline_nes2hdmi.sv build-crt/baseline4a_nes2hdmi.sv build-crt/baseline4a_crt_filter.sv \
 src/nes2hdmi.sv src/iosys/tc_osd_layer.sv src/iosys/tc_crt_config.sv src/iosys/crt_filter.sv \
 "${flags[@]}" > build-crt/scanvideo-build.log 2>&1
./build-crt/scanvideo/Vtb_crt_scan_video
