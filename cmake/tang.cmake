option(ENABLE_TANG "Enable Tang Nano helper targets" ON)

set(TANG_SUPPORTED_BOARDS
    tangnano9k
    tangnano20k
)

set(TANG_TOP_tangnano9k fcsp_tangnano9k_top)
set(TANG_CST_NAME_tangnano9k tang9k.cst)
set(TANG_SDC_NAME_tangnano9k tang9k.sdc)
set(TANG_DEVICE_tangnano9k GW1NR-LV9QN88PC6/I5)
set(TANG_FAMILY_tangnano9k GW1N-9C)
set(TANG_OPENFPGALOADER_BOARD_tangnano9k tangnano9k)

set(TANG_TOP_tangnano20k fcsp_tangnano20k_top)
set(TANG_CST_NAME_tangnano20k tang20k.cst)
set(TANG_SDC_NAME_tangnano20k tang20k.sdc)
set(TANG_DEVICE_tangnano20k GW2AR-LV18QN88C8/I7)
set(TANG_FAMILY_tangnano20k GW2A-18C)
set(TANG_OPENFPGALOADER_BOARD_tangnano20k tangnano20k)

set(TANG_BUILD_TIMEOUT_SEC "0" CACHE STRING "Timeout in seconds for full Tang board build target (0 disables timeout)")
set(TANG_TIMEOUT_CMD "")

set(TANG_OSS_TOOLS_BIN_DEFAULT "$ENV{HOME}/.tools/oss-cad-suite/bin")
set(TANG_OSS_TOOLS_BIN "$ENV{OSS_TOOLS_BIN}" CACHE PATH "Path to OSS FPGA tools bin directory")
if(NOT TANG_OSS_TOOLS_BIN)
    set(TANG_OSS_TOOLS_BIN "${TANG_OSS_TOOLS_BIN_DEFAULT}")
endif()

set(TANG_BUILD_ENV_PATH "$ENV{PATH}")
if(EXISTS "${TANG_OSS_TOOLS_BIN}")
    set(TANG_BUILD_ENV_PATH "${TANG_OSS_TOOLS_BIN}:$ENV{PATH}")
endif()

macro(add_tang_board_targets BOARD_NAME)
    set(BOARD_DIR "${CMAKE_SOURCE_DIR}/rtl/fcsp/boards/${BOARD_NAME}")
    set(TOP_VAR "TANG_TOP_${BOARD_NAME}")
    set(CST_NAME_VAR "TANG_CST_NAME_${BOARD_NAME}")
    set(SDC_NAME_VAR "TANG_SDC_NAME_${BOARD_NAME}")
    set(DEVICE_VAR "TANG_DEVICE_${BOARD_NAME}")
    set(FAMILY_VAR "TANG_FAMILY_${BOARD_NAME}")
    set(OPENFPGALOADER_VAR "TANG_OPENFPGALOADER_BOARD_${BOARD_NAME}")

    set(TOP ${${TOP_VAR}})
    set(CST ${BOARD_DIR}/${${CST_NAME_VAR}})
    set(SDC ${BOARD_DIR}/${${SDC_NAME_VAR}})
    set(DEVICE ${${DEVICE_VAR}})
    set(FAMILY ${${FAMILY_VAR}})
    set(OPENFPGALOADER_BOARD ${${OPENFPGALOADER_VAR}})
    set(OUT_DIR ${CMAKE_SOURCE_DIR}/build/${BOARD_NAME}_oss)
    set(DEFAULT_BITSTREAM ${OUT_DIR}/hardware.fs)

    if(NOT EXISTS ${CST})
        message(FATAL_ERROR "Tang board constraint file missing for ${BOARD_NAME}: ${CST}")
    endif()
    if(NOT EXISTS ${SDC})
        message(FATAL_ERROR "Tang board timing constraints missing for ${BOARD_NAME}: ${SDC}")
    endif()

    add_custom_target(${BOARD_NAME}-build
        COMMAND ${CMAKE_COMMAND} -E make_directory ${OUT_DIR}
        COMMAND ${CMAKE_COMMAND} -E echo "[${BOARD_NAME}-build] Running full build with single timeout (log files in ${OUT_DIR})"
        COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG_OSS_TOOLS_BIN}" "TANG_BOARD=${BOARD_NAME}" "TANG_BUILD_TIMEOUT_SEC=${TANG_BUILD_TIMEOUT_SEC}" ${TANG_TIMEOUT_CMD} bash ${CMAKE_SOURCE_DIR}/scripts/build_tang_oss.sh
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Build ${BOARD_NAME} bitstream via OSS flow (single global timeout)"
        VERBATIM
    )

    add_custom_target(${BOARD_NAME}-stop
        COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/stop_tang_build.sh
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Stop active ${BOARD_NAME} build/synthesis/place-and-route processes"
        VERBATIM
    )

    add_custom_target(${BOARD_NAME}-program-sram
        COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG_OSS_TOOLS_BIN}" openFPGALoader -b ${OPENFPGALOADER_BOARD} ${DEFAULT_BITSTREAM}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Program ${BOARD_NAME} SRAM (no shell script)"
        VERBATIM
    )

    add_custom_target(${BOARD_NAME}-program-flash
        COMMAND ${CMAKE_COMMAND} -E env "PATH=${TANG_BUILD_ENV_PATH}" "OSS_TOOLS_BIN=${TANG_OSS_TOOLS_BIN}" openFPGALoader -b ${OPENFPGALOADER_BOARD} -f ${DEFAULT_BITSTREAM}
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Program ${BOARD_NAME} FLASH (no shell script)"
        VERBATIM
    )
endmacro()

if(ENABLE_TANG)
    foreach(board ${TANG_SUPPORTED_BOARDS})
        add_tang_board_targets(${board})
    endforeach()
endif()
