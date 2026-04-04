cmake_minimum_required(VERSION 3.20)

project(rt_fc_offloader NONE)

option(ENABLE_TANG9K "Enable Tang Nano 9K helper targets" ON)

if(ENABLE_TANG9K)
    include(${CMAKE_SOURCE_DIR}/cmake/tang9k.cmake)
endif()

add_custom_target(test-all
    COMMAND make -C ${CMAKE_SOURCE_DIR}/sim test-all
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/sim
    COMMENT "Running the Verilator/Cocotb testbench suite"
    VERBATIM
)
