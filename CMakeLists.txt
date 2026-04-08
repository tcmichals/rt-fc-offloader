cmake_minimum_required(VERSION 3.20)

project(rt_fc_offloader NONE)

option(ENABLE_SIM "Enable simulation helper targets" ON)

option(ENABLE_TANG9K "Enable Tang Nano 9K helper targets" ON)

if(ENABLE_TANG9K)
    include(${CMAKE_SOURCE_DIR}/cmake/tang9k.cmake)
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
