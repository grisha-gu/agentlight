cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD waveshare_rp2040_zero CACHE STRING "Board type")
include(pico_sdk_import.cmake)

project(agentlight C CXX ASM)
set(CMAKE_C_STANDARD 11)
pico_sdk_init()

add_executable(agentlight
    src/main.c
    src/anim.c
    src/proto.c
    src/transport_hid.c
    src/usb_descriptors.c
    src/leds.c
    src/buttons.c
    src/status_led.c
    src/power.c
)

pico_generate_pio_header(agentlight ${CMAKE_CURRENT_LIST_DIR}/src/ws2812.pio)

target_include_directories(agentlight PRIVATE src)
target_compile_options(agentlight PRIVATE -Wall -Wextra)

target_link_libraries(agentlight
    pico_stdlib
    pico_unique_id
    hardware_pio
    hardware_pwm
    tinyusb_device
)

# Our own USB stack (composite HID + CDC, src/usb_descriptors.c). printf over CDC and the 1200-baud
# reboot into BOOTSEL stay with pico_stdio_usb; with a custom TinyUSB the latter has to be enabled explicitly.
pico_enable_stdio_usb(agentlight 1)
target_compile_definitions(agentlight PRIVATE PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=1)
pico_enable_stdio_uart(agentlight 0)

pico_add_extra_outputs(agentlight)
