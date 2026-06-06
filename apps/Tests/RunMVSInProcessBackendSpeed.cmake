# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TESTS_EXE)
	message(FATAL_ERROR "TESTS_EXE is required")
endif()
if(NOT DEFINED TEST_WORK_DIR)
	message(FATAL_ERROR "TEST_WORK_DIR is required")
endif()
if(NOT DEFINED TEST_REFERENCE_BACKEND)
	set(TEST_REFERENCE_BACKEND cpu)
endif()
if(NOT DEFINED TEST_CANDIDATE_BACKEND)
	set(TEST_CANDIDATE_BACKEND metal)
endif()
if(NOT TEST_REFERENCE_BACKEND STREQUAL "cpu")
	message(FATAL_ERROR "in-process MVS speed reference must be cpu")
endif()

function(run_pipeline label force_cpu expected_backend out_elapsed_ms out_output)
	string(TIMESTAMP start_us "%s%f")
	execute_process(
		COMMAND "${TESTS_EXE}" "2" "0" "${force_cpu}" "${expected_backend}"
		WORKING_DIRECTORY "${TEST_WORK_DIR}"
		RESULT_VARIABLE result
		OUTPUT_VARIABLE output
		ERROR_VARIABLE error
	)
	string(TIMESTAMP end_us "%s%f")
	math(EXPR elapsed_ms "(${end_us} - ${start_us}) / 1000")
	if(NOT result EQUAL 0)
		message(STATUS "${label} stdout:\n${output}")
		message(STATUS "${label} stderr:\n${error}")
		message(FATAL_ERROR "${label} failed with exit code ${result}")
	endif()
	set(${out_elapsed_ms} "${elapsed_ms}" PARENT_SCOPE)
	set(${out_output} "${output}\n${error}" PARENT_SCOPE)
	message(STATUS "${label} completed in ${elapsed_ms} ms")
endfunction()

function(require_backend_marker label output backend)
	set(marker "OpenMVS backend selected: DensifyPointCloud ${backend}")
	string(FIND "${output}" "${marker}" marker_pos)
	if(marker_pos EQUAL -1)
		message(STATUS "${label} output:\n${output}")
		message(FATAL_ERROR "${label} did not report expected backend marker '${marker}'")
	endif()
	message(STATUS "${label} backend marker: ${backend}")
endfunction()

function(require_candidate_faster label reference_ms candidate_ms)
	if(reference_ms LESS 1 OR candidate_ms LESS 1)
		message(FATAL_ERROR "${label} runtime is invalid: reference=${reference_ms}ms candidate=${candidate_ms}ms")
	endif()
	if(NOT candidate_ms LESS reference_ms)
		message(FATAL_ERROR
			"${label} ${TEST_CANDIDATE_BACKEND} candidate must be faster than ${TEST_REFERENCE_BACKEND} reference: reference=${reference_ms}ms candidate=${candidate_ms}ms")
	endif()
	message(STATUS "${label}: reference=${reference_ms}ms candidate=${candidate_ms}ms")
endfunction()

run_pipeline("reference MVSPipelineTest" 1 "${TEST_REFERENCE_BACKEND}" reference_ms reference_output)
require_backend_marker("reference MVSPipelineTest" "${reference_output}" "${TEST_REFERENCE_BACKEND}")

run_pipeline("candidate MVSPipelineTest" 0 "${TEST_CANDIDATE_BACKEND}" candidate_ms candidate_output)
require_backend_marker("candidate MVSPipelineTest" "${candidate_output}" "${TEST_CANDIDATE_BACKEND}")

require_candidate_faster("MVSPipelineTest elapsed" "${reference_ms}" "${candidate_ms}")
