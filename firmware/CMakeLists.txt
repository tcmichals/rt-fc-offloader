cmake_minimum_required(VERSION 3.13)

# Pull in SDK
include(pico_sdk_import.cmake)

project(rt_fc_pico C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)

pico_sdk_init()

add_executable(rt_fc_pico
    # Pico platform sources
    pico/pico_main.cpp
    pico/hal_pico.cpp
    pico/dshot.cpp
    pico/debug_uart.cpp
    pico/neopixel.cpp
    pico/pwm_decode.cpp
    pico/spi_slave.cpp
    pico/esc_pio_serial.cpp

    # Common (platform-independent) sources
    common/app_main.cpp
    common/msp.cpp
    common/esc_4way.cpp
    common/esc_passthrough.cpp
)

target_include_directories(rt_fc_pico PRIVATE
    ${CMAKE_CURRENT_LIST_DIR}/pico
    ${CMAKE_CURRENT_LIST_DIR}/common
    ${CMAKE_CURRENT_LIST_DIR}/hal
)

# PIO programs
pico_generate_pio_header(rt_fc_pico ${CMAKE_CURRENT_LIST_DIR}/pico/dshot.pio)
pico_generate_pio_header(rt_fc_pico ${CMAKE_CURRENT_LIST_DIR}/pico/esc_pio_uart.pio)

# SDK libraries
target_link_libraries(rt_fc_pico
    pico_stdlib
    pico_stdio_usb
    pico_multicore
    hardware_pio
    hardware_spi
    hardware_dma
    hardware_pwm
    hardware_irq
)

# USB stdio, no UART stdio
pico_enable_stdio_usb(rt_fc_pico 1)
pico_enable_stdio_uart(rt_fc_pico 0)

# Generate UF2 output
pico_add_extra_outputs(rt_fc_pico)
