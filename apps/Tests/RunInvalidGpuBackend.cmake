# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED DENSIFY_EXE)
	message(FATAL_ERROR "DENSIFY_EXE is required")
endif()
if(NOT DEFINED REFINE_EXE)
	message(FATAL_ERROR "REFINE_EXE is required")
endif()
if(NOT DEFINED TEST_WORK_DIR)
	set(TEST_WORK_DIR "${CMAKE_CURRENT_BINARY_DIR}")
endif()

set(run_dir "${TEST_WORK_DIR}")

function(remove_new_empty_logs label before_logs)
	file(GLOB after_logs "${run_dir}/${label}-*.log")
	foreach(log_file IN LISTS after_logs)
		list(FIND before_logs "${log_file}" existing_log)
		if(existing_log EQUAL -1)
			file(SIZE "${log_file}" log_size)
			if(log_size EQUAL 0)
				file(REMOVE "${log_file}")
			endif()
		endif()
	endforeach()
endfunction()

function(require_invalid_backend_rejected label exe)
	file(GLOB before_logs "${run_dir}/${label}-*.log")
	execute_process(
		COMMAND "${exe}" --input-file "/private/tmp/openmvs-invalid-backend.mvs" --gpu-backend vulkan
		RESULT_VARIABLE result
		OUTPUT_VARIABLE output
		ERROR_VARIABLE error
	)
	remove_new_empty_logs("${label}" "${before_logs}")
	if(result EQUAL 0)
		message(STATUS "${label} stdout:\n${output}")
		message(STATUS "${label} stderr:\n${error}")
		message(FATAL_ERROR "${label} accepted invalid --gpu-backend value")
	endif()
	string(FIND "${output}\n${error}" "unknown GPU backend 'vulkan'" marker_pos)
	if(marker_pos EQUAL -1)
		message(STATUS "${label} stdout:\n${output}")
		message(STATUS "${label} stderr:\n${error}")
		message(FATAL_ERROR "${label} did not report the invalid backend")
	endif()
	message(STATUS "${label} rejected invalid --gpu-backend value")
endfunction()

require_invalid_backend_rejected("DensifyPointCloud" "${DENSIFY_EXE}")
require_invalid_backend_rejected("RefineMesh" "${REFINE_EXE}")
