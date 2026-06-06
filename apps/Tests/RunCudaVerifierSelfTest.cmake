# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_SOURCE_DIR)
	message(FATAL_ERROR "TEST_SOURCE_DIR is required")
endif()

get_filename_component(TEST_SOURCE_DIR "${TEST_SOURCE_DIR}" ABSOLUTE)

find_program(BASH_EXECUTABLE bash REQUIRED)

set(verify_script "${TEST_SOURCE_DIR}/scripts/verify-cuda.sh")
if(NOT EXISTS "${verify_script}")
	message(FATAL_ERROR "required verifier script is missing: ${verify_script}")
endif()

execute_process(
	COMMAND "${CMAKE_COMMAND}" -E env
		"OPENMVS_CUDA_SELF_TEST=1"
		"${BASH_EXECUTABLE}" "${verify_script}"
	WORKING_DIRECTORY "${TEST_SOURCE_DIR}"
	RESULT_VARIABLE result
	OUTPUT_VARIABLE output
	ERROR_VARIABLE error
)

if(NOT result EQUAL 0)
	message(FATAL_ERROR "CUDA verifier self-test failed with ${result}\nstdout:\n${output}\nstderr:\n${error}")
endif()

string(FIND "${output}" "CUDA verifier self-test passed" found)
if(found EQUAL -1)
	message(FATAL_ERROR "CUDA verifier self-test did not report success\nstdout:\n${output}\nstderr:\n${error}")
endif()

message(STATUS "CUDA verifier self-test passed")
