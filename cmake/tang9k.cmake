set(TANG9K_TOP fcsp_tangnano9k_top)
set(TANG9K_OUT_DIR ${CMAKE_SOURCE_DIR}/build/tang9k_oss)
set(TANG9K_CST ${CMAKE_SOURCE_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.cst)
set(TANG9K_SDC ${CMAKE_SOURCE_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.sdc)
set(TANG9K_DEFAULT_BITSTREAM ${TANG9K_OUT_DIR}/hardware.fs)

if(NOT EXISTS ${TANG9K_CST})
    message(FATAL_ERROR "Tang9K CST file missing: ${TANG9K_CST}")
endif()

if(NOT EXISTS ${TANG9K_SDC})
    message(FATAL_ERROR "Tang9K SDC file missing: ${TANG9K_SDC}")
endif()

set(TANG9K_SOURCES
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/boards/tangnano9k/fcsp_tangnano9k_top.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_offloader_top.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_spi_frontend.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_parser.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_crc16_core_xmodem.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_crc16.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_crc_gate.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_router.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_rx_fifo.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_serv_bridge.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_serv_stub.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_tx_fifo.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_tx_arbiter.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_tx_framer.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_uart_byte_stream.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_io_engines.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_wishbone_master.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/drivers/wb_led_controller.sv
)
string(JOIN " " TANG9K_SOURCES_STR ${TANG9K_SOURCES})
set(TANG9K_YOSYS_SCRIPT "read_verilog -sv ${TANG9K_SOURCES_STR}; synth_gowin -top ${TANG9K_TOP} -json ${TANG9K_OUT_DIR}/hardware.json")

set(TANG9K_OSS_TOOLS_BIN_DEFAULT "$ENV{HOME}/.tools/oss-cad-suite/bin")
set(TANG9K_OSS_TOOLS_BIN "$ENV{OSS_TOOLS_BIN}" CACHE PATH "Path to OSS FPGA tools bin directory")
if(NOT TANG9K_OSS_TOOLS_BIN)
    set(TANG9K_OSS_TOOLS_BIN "${TANG9K_OSS_TOOLS_BIN_DEFAULT}")
endif()

set(TANG9K_BUILD_TIMEOUT_SEC "900" CACHE STRING "Timeout in seconds for full Tang9K build target (0 disables timeout)")
find_program(TANG9K_TIMEOUT_EXE timeout)
set(TANG9K_TIMEOUT_CMD)
if(TANG9K_BUILD_TIMEOUT_SEC AND NOT TANG9K_BUILD_TIMEOUT_SEC STREQUAL "0")
    if(TANG9K_TIMEOUT_EXE)
        set(TANG9K_TIMEOUT_CMD ${TANG9K_TIMEOUT_EXE} --signal=TERM --kill-after=30 "${TANG9K_BUILD_TIMEOUT_SEC}")
    else()
        message(WARNING "timeout tool not found; Tang9K build step timeouts are disabled")
    endif()
endif()

set(TANG9K_BUILD_ENV_PATH "$ENV{PATH}")
if(EXISTS "${TANG9K_OSS_TOOLS_BIN}")
    set(TANG9K_BUILD_ENV_PATH "${TANG9K_OSS_TOOLS_BIN}:$ENV{PATH}")
endif()

add_custom_target(tang9k-build
    COMMAND ${CMAKE_COMMAND} -E make_directory ${TANG9K_OUT_DIR}
    COMMAND ${CMAKE_COMMAND} -E echo "[tang9k-build] Running full build with single timeout (log files in ${TANG9K_OUT_DIR})"
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" "OUT_DIR=${TANG9K_OUT_DIR}" "TANG9K_BUILD_TIMEOUT_SEC=0" ${TANG9K_TIMEOUT_CMD} bash ${CMAKE_SOURCE_DIR}/scripts/build_tang9k_oss.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Build Tang Nano 9K bitstream via OSS flow (single global timeout)"
    VERBATIM
)

add_custom_target(tang9k-stop
    COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/stop_tang9k_build.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Stop active Tang9K build/synthesis/place-and-route processes"
    VERBATIM
)

add_custom_target(tang9k-program-sram
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" openFPGALoader -b tangnano9k ${TANG9K_DEFAULT_BITSTREAM}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Program Tang Nano 9K SRAM (no shell script)"
    VERBATIM
)

add_custom_target(tang9k-program-flash
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" openFPGALoader -b tangnano9k -f ${TANG9K_DEFAULT_BITSTREAM}
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Program Tang Nano 9K FLASH (no shell script)"
    VERBATIM
)
