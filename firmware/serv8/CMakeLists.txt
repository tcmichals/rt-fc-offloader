cmake_minimum_required(VERSION 3.20)
project(serv8_firmware C CXX ASM)

# Toolchain paths
set(TOOLCHAIN_PREFIX "$ENV{HOME}/.tools/gcc-riscv-none-eabi/bin/riscv-none-elf-")
set(CMAKE_C_COMPILER "${TOOLCHAIN_PREFIX}gcc")
set(CMAKE_CXX_COMPILER "${TOOLCHAIN_PREFIX}g++")
set(CMAKE_ASM_COMPILER "${TOOLCHAIN_PREFIX}gcc")
set(CMAKE_OBJCOPY "${TOOLCHAIN_PREFIX}objcopy")

# We are cross compiling bare-metal
set(CMAKE_SYSTEM_NAME Generic)

# SERV architecture requirements: strictly RV32I / ILP32
set(ARCH_FLAGS "-march=rv32i -mabi=ilp32")

# High optimization for extreme space saving inside 4KB bounds
set(CMAKE_CXX_FLAGS "${ARCH_FLAGS} -Os -ffunction-sections -fdata-sections -fno-exceptions -fno-rtti")
set(CMAKE_C_FLAGS "${ARCH_FLAGS} -Os -ffunction-sections -fdata-sections")
set(CMAKE_ASM_FLAGS "${ARCH_FLAGS}")

# Linker flags pointing to our 4KB mem map
set(LINK_FLAGS "-nostartfiles -Wl,-gc-sections -T ${CMAKE_CURRENT_SOURCE_DIR}/link.ld")
set(CMAKE_EXE_LINKER_FLAGS "${LINK_FLAGS}")

# Define the primary firmware target
add_executable(serv8.elf start.S main.cpp)

# Generate hex target for initialization mapping during synthesis
add_custom_target(serv8.hex ALL
    COMMAND ${CMAKE_OBJCOPY} -O verilog serv8.elf serv8.hex
    DEPENDS serv8.elf
    COMMENT "Building the hardware initializer format (.hex) from compiled RISC-V ELF"
    VERBATIM
)
