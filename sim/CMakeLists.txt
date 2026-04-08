cmake_minimum_required(VERSION 3.20)

find_program(MAKE_EXECUTABLE NAMES make gmake REQUIRED)

set(SIM_DIR ${CMAKE_CURRENT_SOURCE_DIR})
set(VENV_BIN_DIR ${CMAKE_SOURCE_DIR}/.venv/bin)

# Ensure cocotb/pytest resolve from the project virtualenv when present.
if(EXISTS ${VENV_BIN_DIR})
    set(SIM_PATH_ENV "PATH=${VENV_BIN_DIR}:$ENV{PATH}")
else()
    set(SIM_PATH_ENV "PATH=$ENV{PATH}")
endif()

function(add_sim_target target_name sim_make_target target_comment)
    add_custom_target(${target_name}
        COMMAND ${CMAKE_COMMAND} -E env ${SIM_PATH_ENV} ${MAKE_EXECUTABLE} -C ${SIM_DIR} ${sim_make_target}
        WORKING_DIRECTORY ${SIM_DIR}
        COMMENT ${target_comment}
        VERBATIM
    )
endfunction()

add_sim_target(sim-test-python test-python "Running Python FCSP simulator tests")
add_sim_target(sim-test-hw-scripts-sim test-hw-scripts-sim "Running python/hw script simulation-compatibility tests")
add_sim_target(sim-test-cocotb test-cocotb "Running parser cocotb tests")
add_sim_target(sim-test-top-cocotb test-top-cocotb "Running top-level cocotb tests")
add_sim_target(sim-test-top-cocotb-experimental test-top-cocotb-experimental "Running experimental top-level cocotb integration tests")
add_sim_target(sim-test-teaching-examples test-teaching-examples-cocotb "Running teaching cocotb examples")
add_sim_target(sim-fit-evidence fit-evidence-snapshot "Generating fit evidence snapshot")
add_sim_target(sim-fit-evidence-live fit-evidence-snapshot-live "Generating live fit evidence snapshot")
add_sim_target(sim-test-all test-all "Running complete simulation regression suite")
add_sim_target(sim-test-all-strict test-all-strict "Running strict complete simulation regression suite")
