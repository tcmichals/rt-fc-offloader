set(TANG9K_TOP fcsp_tangnano9k_top)
set(TANG9K_OUT_DIR ${CMAKE_SOURCE_DIR}/build/tang9k_oss)
set(TANG9K_CST ${CMAKE_SOURCE_DIR}/rtl/fcsp/boards/tangnano9k/tang9k.cst)
set(TANG9K_DEFAULT_BITSTREAM ${TANG9K_OUT_DIR}/hardware.fs)

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
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_tx_fifo.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_tx_framer.sv
    ${CMAKE_SOURCE_DIR}/rtl/fcsp/fcsp_io_engines.sv
)
string(JOIN " " TANG9K_SOURCES_STR ${TANG9K_SOURCES})
set(TANG9K_YOSYS_SCRIPT "read_verilog -sv ${TANG9K_SOURCES_STR}; synth_gowin -top ${TANG9K_TOP} -json ${TANG9K_OUT_DIR}/hardware.json")

set(TANG9K_OSS_TOOLS_BIN_DEFAULT "$ENV{HOME}/.tools/oss-cad-suite/bin")
set(TANG9K_OSS_TOOLS_BIN "$ENV{OSS_TOOLS_BIN}" CACHE PATH "Path to OSS FPGA tools bin directory")
if(NOT TANG9K_OSS_TOOLS_BIN)
    set(TANG9K_OSS_TOOLS_BIN "${TANG9K_OSS_TOOLS_BIN_DEFAULT}")
endif()

set(TANG9K_BUILD_ENV_PATH "$ENV{PATH}")
if(EXISTS "${TANG9K_OSS_TOOLS_BIN}")
    set(TANG9K_BUILD_ENV_PATH "${TANG9K_OSS_TOOLS_BIN}:$ENV{PATH}")
endif()

add_custom_target(tang9k-build
    COMMAND ${CMAKE_COMMAND} -E make_directory ${TANG9K_OUT_DIR}
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" yosys -q -p "${TANG9K_YOSYS_SCRIPT}"
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" nextpnr-himbaechel --json ${TANG9K_OUT_DIR}/hardware.json --write ${TANG9K_OUT_DIR}/hardware_pnr.json --device GW1NR-LV9QN88PC6/I5 --vopt family=GW1N-9C --vopt cst=${TANG9K_CST} --freq 27 --report ${TANG9K_OUT_DIR}/nextpnr_report.json
    COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG9K_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG9K_OSS_TOOLS_BIN}" gowin_pack -d GW1N-9C -o ${TANG9K_OUT_DIR}/hardware.fs ${TANG9K_OUT_DIR}/hardware_pnr.json
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
    COMMENT "Build Tang Nano 9K bitstream via OSS flow (no shell script)"
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
