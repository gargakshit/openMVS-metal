# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_BINARY_1)
	message(FATAL_ERROR "TEST_BINARY_1 is required")
endif()

function(check_no_cuda_linkage path)
	if(NOT EXISTS "${path}")
		message(FATAL_ERROR "expected binary not found: ${path}")
	endif()
	execute_process(
		COMMAND otool -L "${path}"
		RESULT_VARIABLE result
		OUTPUT_VARIABLE output
		ERROR_VARIABLE error
	)
	if(NOT result EQUAL 0)
		message(STATUS "otool stderr:\n${error}")
		message(FATAL_ERROR "otool failed for ${path} with exit code ${result}")
	endif()
	string(REPLACE "\n" ";" output_lines "${output}")
	list(POP_FRONT output_lines)
	foreach(line IN LISTS output_lines)
		string(TOLOWER "${line}" line_lower)
		foreach(pattern "cuda" "cudart" "curand" "cublas" "cudnn" "nvrtc" "nvidia")
			if(line_lower MATCHES "${pattern}")
				message(STATUS "otool -L ${path}:\n${output}")
				message(FATAL_ERROR "${path} links CUDA/NVIDIA dependency matching '${pattern}'")
			endif()
		endforeach()
	endforeach()
	message(STATUS "${path}: no CUDA/NVIDIA dynamic linkage")
endfunction()

foreach(index RANGE 1 32)
	if(DEFINED TEST_BINARY_${index})
		check_no_cuda_linkage("${TEST_BINARY_${index}}")
	endif()
endforeach()
