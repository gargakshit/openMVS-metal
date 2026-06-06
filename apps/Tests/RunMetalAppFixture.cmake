# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_DATA_DIR)
	message(FATAL_ERROR "TEST_DATA_DIR is required")
endif()
if(NOT DEFINED TEST_WORK_DIR)
	message(FATAL_ERROR "TEST_WORK_DIR is required")
endif()
if(NOT DEFINED DENSIFY_EXE)
	message(FATAL_ERROR "DENSIFY_EXE is required")
endif()
if(NOT DEFINED RECONSTRUCT_EXE)
	message(FATAL_ERROR "RECONSTRUCT_EXE is required")
endif()
if(NOT DEFINED REFINE_EXE)
	message(FATAL_ERROR "REFINE_EXE is required")
endif()
if(NOT DEFINED TEST_GPU_BACKEND)
	set(TEST_GPU_BACKEND metal)
endif()
if(NOT DEFINED TEST_EXPECTED_DENSIFY_BACKEND)
	set(TEST_EXPECTED_DENSIFY_BACKEND "${TEST_GPU_BACKEND}")
endif()
if(NOT DEFINED TEST_EXPECTED_REFINE_BACKEND)
	set(TEST_EXPECTED_REFINE_BACKEND "${TEST_GPU_BACKEND}")
endif()

function(run_fixture_step name out_output)
	execute_process(
		COMMAND ${ARGN}
		WORKING_DIRECTORY "${TEST_WORK_DIR}"
		RESULT_VARIABLE result
		OUTPUT_VARIABLE output
		ERROR_VARIABLE error
	)
	if(NOT result EQUAL 0)
		message(STATUS "${name} stdout:\n${output}")
		message(STATUS "${name} stderr:\n${error}")
		message(FATAL_ERROR "${name} failed with exit code ${result}")
	endif()
	message(STATUS "${name} completed")
	set(${out_output} "${output}\n${error}" PARENT_SCOPE)
endfunction()

function(require_backend_marker label output app backend)
	if(NOT backend STREQUAL "cpu" AND NOT backend STREQUAL "cuda" AND NOT backend STREQUAL "metal")
		return()
	endif()
	set(marker "OpenMVS backend selected: ${app} ${backend}")
	string(FIND "${output}" "${marker}" marker_pos)
	if(marker_pos EQUAL -1)
		message(STATUS "${label} output:\n${output}")
		message(FATAL_ERROR "${label} did not report expected backend marker '${marker}'")
	endif()
	message(STATUS "${label} backend marker: ${backend}")
endfunction()

function(check_ply_counts path min_vertices min_faces)
	if(NOT EXISTS "${path}")
		message(FATAL_ERROR "expected PLY output not found: ${path}")
	endif()
	file(STRINGS "${path}" header LIMIT_COUNT 80)
	set(vertices -1)
	set(faces -1)
	foreach(line IN LISTS header)
		if(line MATCHES "^element vertex ([0-9]+)")
			set(vertices "${CMAKE_MATCH_1}")
		elseif(line MATCHES "^element face ([0-9]+)")
			set(faces "${CMAKE_MATCH_1}")
		elseif(line STREQUAL "end_header")
			break()
		endif()
	endforeach()
	if(vertices LESS min_vertices)
		message(FATAL_ERROR "${path} has too few vertices: ${vertices}, expected at least ${min_vertices}")
	endif()
	if(NOT min_faces LESS 0 AND faces LESS min_faces)
		message(FATAL_ERROR "${path} has too few faces: ${faces}, expected at least ${min_faces}")
	endif()
	message(STATUS "${path}: vertices=${vertices} faces=${faces}")
endfunction()

function(remove_empty_app_logs)
	file(GLOB app_logs LIST_DIRECTORIES false
		"${TEST_WORK_DIR}/*DensifyPointCloud*.log"
		"${TEST_WORK_DIR}/*ReconstructMesh*.log"
		"${TEST_WORK_DIR}/*RefineMesh*.log"
	)
	foreach(app_log IN LISTS app_logs)
		file(SIZE "${app_log}" app_log_size)
		if(app_log_size EQUAL 0)
			file(REMOVE "${app_log}")
		endif()
	endforeach()
endfunction()

file(REMOVE_RECURSE "${TEST_WORK_DIR}")
file(MAKE_DIRECTORY "${TEST_WORK_DIR}")
file(COPY "${TEST_DATA_DIR}/" DESTINATION "${TEST_WORK_DIR}")

run_fixture_step(
	DensifyPointCloud
	densify_output
	"${DENSIFY_EXE}"
	--working-folder "${TEST_WORK_DIR}"
	--input-file scene.mvs
	--output-file metal_dense.mvs
	--gpu-backend "${TEST_GPU_BACKEND}"
	--resolution-level 1
	--min-resolution 640
	--sub-resolution-levels 2
	--number-views 8
	--iters 4
	--geometric-iters 2
	--estimate-roi 0
	--crop-to-roi 0
	--tower-mode 0
	--remove-dmaps 1
	--max-threads 4
)
require_backend_marker(DensifyPointCloud "${densify_output}" DensifyPointCloud "${TEST_EXPECTED_DENSIFY_BACKEND}")
check_ply_counts("${TEST_WORK_DIR}/metal_dense.ply" 50000 -1)

run_fixture_step(
	ReconstructMesh
	reconstruct_output
	"${RECONSTRUCT_EXE}"
	--working-folder "${TEST_WORK_DIR}"
	--input-file metal_dense.mvs
	--output-file metal_mesh.mvs
	--decimate 0.7
	--remove-spurious 0
	--close-holes 0
	--smooth 0
	--max-threads 4
)
check_ply_counts("${TEST_WORK_DIR}/metal_mesh.ply" 12000 17000)

run_fixture_step(
	RefineMesh
	refine_output
	"${REFINE_EXE}"
	--working-folder "${TEST_WORK_DIR}"
	--input-file metal_dense.mvs
	--mesh-file metal_mesh.ply
	--output-file metal_refine.mvs
	--gpu-backend "${TEST_GPU_BACKEND}"
	--resolution-level 1
	--min-resolution 320
	--max-views 2
	--decimate 1
	--close-holes 0
	--ensure-edge-size 0
	--max-face-area 0
	--scales 1
	--scale-step 1
	--alternate-pair 2
	--regularity-weight 0.2
	--rigidity-elasticity-ratio 0.9
	--gradient-step 1.01
	--max-threads 4
)
require_backend_marker(RefineMesh "${refine_output}" RefineMesh "${TEST_EXPECTED_REFINE_BACKEND}")
check_ply_counts("${TEST_WORK_DIR}/metal_refine.ply" 12000 17000)
remove_empty_app_logs()
