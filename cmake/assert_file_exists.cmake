if(NOT DEFINED ASSERT_FILE OR ASSERT_FILE STREQUAL "")
  message(FATAL_ERROR "ASSERT_FILE is not set")
endif()

if(NOT EXISTS "${ASSERT_FILE}")
  message(FATAL_ERROR "Expected file not found: ${ASSERT_FILE}")
endif()
