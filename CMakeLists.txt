cmake_minimum_required(VERSION 3.20)

project(rt_fc_offloader NONE)

option(ENABLE_SIM "Enable simulation helper targets" ON)

option(ENABLE_TANG "Enable Tang Nano helper targets" ON)

if(ENABLE_TANG)
    include(${CMAKE_SOURCE_DIR}/cmake/tang.cmake)
endif()

if(ENABLE_SIM)
    add_subdirectory(sim)
endif()

add_custom_target(test-all
    COMMENT "Running the complete simulation regression suite"
    VERBATIM
)

if(ENABLE_SIM)
    add_dependencies(test-all sim-test-all)
endif()
