# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_SOURCE_DIR)
	message(FATAL_ERROR "TEST_SOURCE_DIR is required")
endif()
if(NOT DEFINED TEST_WORK_DIR)
	message(FATAL_ERROR "TEST_WORK_DIR is required")
endif()

get_filename_component(TEST_SOURCE_DIR "${TEST_SOURCE_DIR}" ABSOLUTE)
get_filename_component(TEST_WORK_DIR "${TEST_WORK_DIR}" ABSOLUTE)

function(require_file path)
	if(NOT EXISTS "${path}")
		message(FATAL_ERROR "required evidence file is missing: ${path}")
	endif()
endfunction()

function(require_contains label path needle)
	require_file("${path}")
	file(READ "${path}" content)
	string(FIND "${content}" "${needle}" found)
	if(found EQUAL -1)
		message(FATAL_ERROR "${label}: missing '${needle}' in ${path}")
	endif()
endfunction()

find_program(BASH_EXECUTABLE bash REQUIRED)

set(verify_script "${TEST_SOURCE_DIR}/scripts/verify-cuda.sh")
if(NOT EXISTS "${verify_script}")
	message(FATAL_ERROR "required verifier script is missing: ${verify_script}")
endif()

set(evidence_dir "${TEST_WORK_DIR}/evidence")
set(shim_dir "${TEST_WORK_DIR}/bin")
file(REMOVE_RECURSE "${TEST_WORK_DIR}")
file(MAKE_DIRECTORY "${evidence_dir}" "${shim_dir}")

set(fake_nvidia_smi "${shim_dir}/nvidia-smi")
file(WRITE "${fake_nvidia_smi}" [=[#!/usr/bin/env bash
if [[ "${1:-}" == "-L" ]]; then
	printf 'No devices were found\n'
else
	printf 'NVIDIA-SMI fake verifier smoke\n'
fi
]=])
file(CHMOD "${fake_nvidia_smi}"
	PERMISSIONS
		OWNER_READ OWNER_WRITE OWNER_EXECUTE
		GROUP_READ GROUP_EXECUTE
		WORLD_READ WORLD_EXECUTE
)

execute_process(
	COMMAND "${CMAKE_COMMAND}" -E env
		"OPENMVS_CUDA_EVIDENCE_DIR=${evidence_dir}"
		"PATH=${shim_dir}:$ENV{PATH}"
		"${BASH_EXECUTABLE}" "${verify_script}"
	WORKING_DIRECTORY "${TEST_SOURCE_DIR}"
	RESULT_VARIABLE result
	OUTPUT_VARIABLE output
	ERROR_VARIABLE error
)

if(result EQUAL 0)
	message(FATAL_ERROR "CUDA verifier early-failure smoke unexpectedly succeeded")
endif()
if(NOT result EQUAL 1)
	message(FATAL_ERROR "CUDA verifier early-failure smoke exited with ${result}, expected 1\nstdout:\n${output}\nstderr:\n${error}")
endif()

require_contains("verifier failure stdout" "${evidence_dir}/nvidia-smi-gpus.log" "No devices were found")
require_contains("verifier fake nvidia-smi log" "${evidence_dir}/nvidia-smi.log" "NVIDIA-SMI fake verifier smoke")
require_contains("verifier result status" "${evidence_dir}/verification-result.log" "exit_status=1")
require_contains("verifier result marker" "${evidence_dir}/verification-result.log" "result=failure")
require_contains("verifier environment build jobs" "${evidence_dir}/verification-environment.log" "build_jobs=2")
require_contains("verifier environment ctest jobs" "${evidence_dir}/verification-environment.log" "ctest_jobs=1")
require_contains("verifier manifest includes result" "${evidence_dir}/evidence-manifest.log" "verification-result.log")
require_contains("verifier manifest includes environment" "${evidence_dir}/evidence-manifest.log" "verification-environment.log")
require_contains("verifier manifest includes fake gpu list" "${evidence_dir}/evidence-manifest.log" "nvidia-smi-gpus.log")

if(EXISTS "${evidence_dir}/configure.log")
	message(FATAL_ERROR "early-failure smoke should not reach CMake configure")
endif()

message(STATUS "CUDA verifier early-failure smoke passed")
