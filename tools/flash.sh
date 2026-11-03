#!/bin/sh
# Build the firmware and flash the board without the BOOT button:
# opening the CDC port at 1200 baud reboots the RP2040 into BOOTSEL (RPI-RP2).
# Works only if the board already runs our firmware (MicroPython can't do this —
# there: REPL → import machine; machine.bootloader()).
set -e
cd "$(dirname "$0")/../firmware"

TOOLCHAIN=${PICO_TOOLCHAIN_PATH:-$HOME/tools/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi}
[ -d build ] || cmake -B build -G Ninja -DPICO_SDK_PATH="$HOME/pico-sdk" -DPICO_TOOLCHAIN_PATH="$TOOLCHAIN"
cmake --build build

if [ ! -f /Volumes/RPI-RP2/INFO_UF2.TXT ]; then
    port=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
    [ -n "$port" ] || { echo "board not found"; exit 1; }
    stty -f "$port" 1200 2>/dev/null || true
    i=0
    while [ ! -f /Volumes/RPI-RP2/INFO_UF2.TXT ]; do
        i=$((i + 1)); [ $i -le 40 ] || { echo "RPI-RP2 didn't show up"; exit 1; }
        sleep 0.25
    done
fi

sleep 0.5  # the volume shows up before it's ready for writing
cp build/agentlight.uf2 /Volumes/RPI-RP2/
echo "flashed"
