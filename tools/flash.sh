#!/bin/sh
# Собрать прошивку и залить на плату без кнопки BOOT:
# открытие CDC-порта на 1200 бод перезагружает RP2040 в BOOTSEL (RPI-RP2).
# Работает, только если на плате уже наша прошивка (MicroPython так не умеет —
# там: REPL → import machine; machine.bootloader()).
set -e
cd "$(dirname "$0")/../firmware"

TOOLCHAIN=${PICO_TOOLCHAIN_PATH:-$HOME/tools/arm-gnu-toolchain-14.2.rel1-darwin-x86_64-arm-none-eabi}
[ -d build ] || cmake -B build -G Ninja -DPICO_SDK_PATH="$HOME/pico-sdk" -DPICO_TOOLCHAIN_PATH="$TOOLCHAIN"
cmake --build build

if [ ! -f /Volumes/RPI-RP2/INFO_UF2.TXT ]; then
    port=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
    [ -n "$port" ] || { echo "плата не найдена"; exit 1; }
    stty -f "$port" 1200 2>/dev/null || true
    i=0
    while [ ! -f /Volumes/RPI-RP2/INFO_UF2.TXT ]; do
        i=$((i + 1)); [ $i -le 40 ] || { echo "RPI-RP2 не появился"; exit 1; }
        sleep 0.25
    done
fi

sleep 0.5  # том виден раньше, чем готов к записи
cp build/agentlight.uf2 /Volumes/RPI-RP2/
echo "прошито"
