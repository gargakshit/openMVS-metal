# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_DATA_DIR AND NOT DEFINED TEST_SCENE_FILE)
	message(FATAL_ERROR "TEST_DATA_DIR or TEST_SCENE_FILE is required")
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
if(NOT DEFINED TEST_REFERENCE_BACKEND)
	set(TEST_REFERENCE_BACKEND cpu)
endif()
if(NOT DEFINED TEST_CANDIDATE_BACKEND)
	set(TEST_CANDIDATE_BACKEND metal)
endif()
if(NOT DEFINED TEST_MAX_THREADS)
	set(TEST_MAX_THREADS 4)
endif()
if(NOT DEFINED TEST_DENSIFY_MIN_RESOLUTION)
	set(TEST_DENSIFY_MIN_RESOLUTION 640)
endif()
if(NOT DEFINED TEST_DENSIFY_SUB_RESOLUTION_LEVELS)
	set(TEST_DENSIFY_SUB_RESOLUTION_LEVELS 2)
endif()
if(NOT DEFINED TEST_DENSIFY_NUMBER_VIEWS)
	set(TEST_DENSIFY_NUMBER_VIEWS 8)
endif()
if(NOT DEFINED TEST_DENSIFY_ITERS)
	set(TEST_DENSIFY_ITERS 4)
endif()
if(NOT DEFINED TEST_DENSIFY_GEOMETRIC_ITERS)
	set(TEST_DENSIFY_GEOMETRIC_ITERS 2)
endif()
if(NOT DEFINED TEST_REFINE_MIN_RESOLUTION)
	set(TEST_REFINE_MIN_RESOLUTION 320)
endif()
if(NOT DEFINED TEST_REFINE_MAX_VIEWS)
	set(TEST_REFINE_MAX_VIEWS 2)
endif()
if(NOT DEFINED TEST_REFINE_GRADIENT_STEP)
	set(TEST_REFINE_GRADIENT_STEP 16.10)
endif()
if(NOT DEFINED TEST_MIN_DENSE_VERTICES)
	set(TEST_MIN_DENSE_VERTICES 50000)
endif()
if(NOT DEFINED TEST_MIN_MESH_VERTICES)
	set(TEST_MIN_MESH_VERTICES 12000)
endif()
if(NOT DEFINED TEST_MIN_MESH_FACES)
	set(TEST_MIN_MESH_FACES 17000)
endif()
if(NOT DEFINED TEST_DENSE_MIN_PERCENT)
	set(TEST_DENSE_MIN_PERCENT 65)
endif()
if(NOT DEFINED TEST_DENSE_MAX_PERCENT)
	set(TEST_DENSE_MAX_PERCENT 135)
endif()
if(NOT DEFINED TEST_MESH_MIN_PERCENT)
	set(TEST_MESH_MIN_PERCENT 60)
endif()
if(NOT DEFINED TEST_MESH_MAX_PERCENT)
	set(TEST_MESH_MAX_PERCENT 160)
endif()
if(NOT DEFINED TEST_SAME_MESH_MIN_PERCENT)
	set(TEST_SAME_MESH_MIN_PERCENT 95)
endif()
if(NOT DEFINED TEST_SAME_MESH_MAX_PERCENT)
	set(TEST_SAME_MESH_MAX_PERCENT 105)
endif()
if(DEFINED TEST_SCENE_FILE)
	get_filename_component(TEST_SCENE_FILE "${TEST_SCENE_FILE}" ABSOLUTE)
	if(NOT EXISTS "${TEST_SCENE_FILE}")
		message(FATAL_ERROR "TEST_SCENE_FILE does not exist: ${TEST_SCENE_FILE}")
	endif()
	if(NOT DEFINED TEST_SCENE_COPY_ROOT)
		get_filename_component(TEST_SCENE_COPY_ROOT "${TEST_SCENE_FILE}" DIRECTORY)
	endif()
	get_filename_component(TEST_SCENE_COPY_ROOT "${TEST_SCENE_COPY_ROOT}" ABSOLUTE)
	if(NOT IS_DIRECTORY "${TEST_SCENE_COPY_ROOT}")
		message(FATAL_ERROR "TEST_SCENE_COPY_ROOT is not a directory: ${TEST_SCENE_COPY_ROOT}")
	endif()
	file(RELATIVE_PATH TEST_INPUT_SCENE_NAME "${TEST_SCENE_COPY_ROOT}" "${TEST_SCENE_FILE}")
	if(TEST_INPUT_SCENE_NAME MATCHES "^\\.\\.")
		message(FATAL_ERROR "TEST_SCENE_FILE must be under TEST_SCENE_COPY_ROOT")
	endif()
else()
	get_filename_component(TEST_SCENE_COPY_ROOT "${TEST_DATA_DIR}" ABSOLUTE)
	set(TEST_INPUT_SCENE_NAME "scene.mvs")
endif()
message(STATUS "Backend parity scene root: ${TEST_SCENE_COPY_ROOT}")
message(STATUS "Backend parity scene file: ${TEST_INPUT_SCENE_NAME}")

function(run_fixture_step name out_elapsed_ms out_output)
	string(TIMESTAMP start_us "%s%f")
	execute_process(
		COMMAND ${ARGN}
		WORKING_DIRECTORY "${TEST_WORK_DIR}"
		RESULT_VARIABLE result
		OUTPUT_VARIABLE output
		ERROR_VARIABLE error
	)
	string(TIMESTAMP end_us "%s%f")
	math(EXPR elapsed_ms "(${end_us} - ${start_us}) / 1000")
	if(NOT result EQUAL 0)
		message(STATUS "${name} stdout:\n${output}")
		message(STATUS "${name} stderr:\n${error}")
		message(FATAL_ERROR "${name} failed with exit code ${result}")
	endif()
	set(${out_elapsed_ms} "${elapsed_ms}" PARENT_SCOPE)
	set(${out_output} "${output}\n${error}" PARENT_SCOPE)
	message(STATUS "${name} completed in ${elapsed_ms} ms")
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

function(read_ply_counts path out_vertices out_faces)
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
	if(vertices LESS 0)
		message(FATAL_ERROR "${path} does not contain a PLY vertex count")
	endif()
	set(${out_vertices} "${vertices}" PARENT_SCOPE)
	set(${out_faces} "${faces}" PARENT_SCOPE)
	message(STATUS "${path}: vertices=${vertices} faces=${faces}")
endfunction()

function(require_min_counts label vertices faces min_vertices min_faces)
	if(vertices LESS min_vertices)
		message(FATAL_ERROR "${label} has too few vertices: ${vertices}, expected at least ${min_vertices}")
	endif()
	if(NOT min_faces LESS 0 AND faces LESS min_faces)
		message(FATAL_ERROR "${label} has too few faces: ${faces}, expected at least ${min_faces}")
	endif()
endfunction()

function(compare_count_ratio label reference candidate min_percent max_percent)
	if(reference LESS 1)
		message(FATAL_ERROR "${label} reference count is invalid: ${reference}")
	endif()
	math(EXPR lower "${reference} * ${min_percent} / 100")
	math(EXPR upper "${reference} * ${max_percent} / 100")
	if(candidate LESS lower OR candidate GREATER upper)
		message(FATAL_ERROR
			"${label} candidate count ${candidate} outside reference tolerance: reference=${reference}, expected ${lower}..${upper}")
	endif()
	message(STATUS "${label}: reference=${reference} candidate=${candidate}")
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

function(remove_empty_app_logs)
	file(GLOB_RECURSE app_logs LIST_DIRECTORIES false
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

function(run_backend backend prefix out_dense_vertices out_mesh_vertices out_mesh_faces out_refine_vertices out_refine_faces out_densify_ms out_reconstruct_ms out_refine_ms)
	set(work_dir "${TEST_WORK_DIR}/${prefix}")
	file(REMOVE_RECURSE "${work_dir}")
	file(MAKE_DIRECTORY "${work_dir}")
	file(COPY "${TEST_SCENE_COPY_ROOT}/" DESTINATION "${work_dir}")
	if(NOT EXISTS "${work_dir}/${TEST_INPUT_SCENE_NAME}")
		message(FATAL_ERROR "copied work dir does not contain scene file: ${work_dir}/${TEST_INPUT_SCENE_NAME}")
	endif()

	run_fixture_step(
		"${prefix} DensifyPointCloud"
		densify_ms
		densify_output
		"${DENSIFY_EXE}"
		--working-folder "${work_dir}"
		--input-file "${TEST_INPUT_SCENE_NAME}"
		--output-file "${prefix}_dense.mvs"
		--gpu-backend "${backend}"
		--resolution-level 1
		--min-resolution "${TEST_DENSIFY_MIN_RESOLUTION}"
		--sub-resolution-levels "${TEST_DENSIFY_SUB_RESOLUTION_LEVELS}"
		--number-views "${TEST_DENSIFY_NUMBER_VIEWS}"
		--iters "${TEST_DENSIFY_ITERS}"
		--geometric-iters "${TEST_DENSIFY_GEOMETRIC_ITERS}"
		--estimate-roi 0
		--crop-to-roi 0
		--tower-mode 0
		--remove-dmaps 1
		--max-threads "${TEST_MAX_THREADS}"
	)
	require_backend_marker("${prefix} DensifyPointCloud" "${densify_output}" "DensifyPointCloud" "${backend}")
	read_ply_counts("${work_dir}/${prefix}_dense.ply" dense_vertices dense_faces)
	require_min_counts("${prefix} dense" "${dense_vertices}" "${dense_faces}" "${TEST_MIN_DENSE_VERTICES}" -1)

	run_fixture_step(
		"${prefix} ReconstructMesh"
		reconstruct_ms
		reconstruct_output
		"${RECONSTRUCT_EXE}"
		--working-folder "${work_dir}"
		--input-file "${prefix}_dense.mvs"
		--output-file "${prefix}_mesh.mvs"
		--decimate 0.7
		--remove-spurious 0
		--close-holes 0
		--smooth 0
		--max-threads "${TEST_MAX_THREADS}"
	)
	read_ply_counts("${work_dir}/${prefix}_mesh.ply" mesh_vertices mesh_faces)
	require_min_counts("${prefix} mesh" "${mesh_vertices}" "${mesh_faces}" "${TEST_MIN_MESH_VERTICES}" "${TEST_MIN_MESH_FACES}")

	run_fixture_step(
		"${prefix} RefineMesh"
		refine_ms
		refine_output
		"${REFINE_EXE}"
		--working-folder "${work_dir}"
		--input-file "${prefix}_dense.mvs"
		--mesh-file "${prefix}_mesh.ply"
		--output-file "${prefix}_refine.mvs"
		--gpu-backend "${backend}"
		--resolution-level 1
		--min-resolution "${TEST_REFINE_MIN_RESOLUTION}"
		--max-views "${TEST_REFINE_MAX_VIEWS}"
		--decimate 1
		--close-holes 0
		--ensure-edge-size 0
		--max-face-area 0
		--scales 1
		--scale-step 1
		--alternate-pair 2
		--regularity-weight 0.2
		--rigidity-elasticity-ratio 0.9
		--gradient-step "${TEST_REFINE_GRADIENT_STEP}"
		--max-threads "${TEST_MAX_THREADS}"
	)
	require_backend_marker("${prefix} RefineMesh" "${refine_output}" "RefineMesh" "${backend}")
	read_ply_counts("${work_dir}/${prefix}_refine.ply" refine_vertices refine_faces)
	require_min_counts("${prefix} refine" "${refine_vertices}" "${refine_faces}" "${TEST_MIN_MESH_VERTICES}" "${TEST_MIN_MESH_FACES}")

	set(${out_dense_vertices} "${dense_vertices}" PARENT_SCOPE)
	set(${out_mesh_vertices} "${mesh_vertices}" PARENT_SCOPE)
	set(${out_mesh_faces} "${mesh_faces}" PARENT_SCOPE)
	set(${out_refine_vertices} "${refine_vertices}" PARENT_SCOPE)
	set(${out_refine_faces} "${refine_faces}" PARENT_SCOPE)
	set(${out_densify_ms} "${densify_ms}" PARENT_SCOPE)
	set(${out_reconstruct_ms} "${reconstruct_ms}" PARENT_SCOPE)
	set(${out_refine_ms} "${refine_ms}" PARENT_SCOPE)
endfunction()

function(run_same_mesh_refine backend prefix out_refine_vertices out_refine_faces out_refine_ms)
	set(work_dir "${TEST_WORK_DIR}/candidate")
	run_fixture_step(
		"${prefix} same-mesh RefineMesh"
		refine_ms
		refine_output
		"${REFINE_EXE}"
		--working-folder "${work_dir}"
		--input-file candidate_dense.mvs
		--mesh-file candidate_mesh.ply
		--output-file "${prefix}_same_mesh_refine.mvs"
		--gpu-backend "${backend}"
		--resolution-level 1
		--min-resolution "${TEST_REFINE_MIN_RESOLUTION}"
		--max-views "${TEST_REFINE_MAX_VIEWS}"
		--decimate 1
		--close-holes 0
		--ensure-edge-size 0
		--max-face-area 0
		--scales 1
		--scale-step 1
		--alternate-pair 2
		--regularity-weight 0.2
		--rigidity-elasticity-ratio 0.9
		--gradient-step "${TEST_REFINE_GRADIENT_STEP}"
		--max-threads "${TEST_MAX_THREADS}"
	)
	require_backend_marker("${prefix} same-mesh RefineMesh" "${refine_output}" "RefineMesh" "${backend}")
	read_ply_counts("${work_dir}/${prefix}_same_mesh_refine.ply" refine_vertices refine_faces)
	require_min_counts("${prefix} same-mesh refine" "${refine_vertices}" "${refine_faces}" "${TEST_MIN_MESH_VERTICES}" "${TEST_MIN_MESH_FACES}")
	set(${out_refine_vertices} "${refine_vertices}" PARENT_SCOPE)
	set(${out_refine_faces} "${refine_faces}" PARENT_SCOPE)
	set(${out_refine_ms} "${refine_ms}" PARENT_SCOPE)
endfunction()

file(REMOVE_RECURSE "${TEST_WORK_DIR}")
file(MAKE_DIRECTORY "${TEST_WORK_DIR}")

run_backend("${TEST_REFERENCE_BACKEND}" reference
	reference_dense_vertices
	reference_mesh_vertices
	reference_mesh_faces
	reference_refine_vertices
	reference_refine_faces
	reference_densify_ms
	reference_reconstruct_ms
	reference_refine_ms)
run_backend("${TEST_CANDIDATE_BACKEND}" candidate
	candidate_dense_vertices
	candidate_mesh_vertices
	candidate_mesh_faces
	candidate_refine_vertices
	candidate_refine_faces
	candidate_densify_ms
	candidate_reconstruct_ms
	candidate_refine_ms)

compare_count_ratio("dense vertices" "${reference_dense_vertices}" "${candidate_dense_vertices}" "${TEST_DENSE_MIN_PERCENT}" "${TEST_DENSE_MAX_PERCENT}")
compare_count_ratio("mesh vertices" "${reference_mesh_vertices}" "${candidate_mesh_vertices}" "${TEST_MESH_MIN_PERCENT}" "${TEST_MESH_MAX_PERCENT}")
compare_count_ratio("mesh faces" "${reference_mesh_faces}" "${candidate_mesh_faces}" "${TEST_MESH_MIN_PERCENT}" "${TEST_MESH_MAX_PERCENT}")
compare_count_ratio("refine vertices" "${reference_refine_vertices}" "${candidate_refine_vertices}" "${TEST_MESH_MIN_PERCENT}" "${TEST_MESH_MAX_PERCENT}")
compare_count_ratio("refine faces" "${reference_refine_faces}" "${candidate_refine_faces}" "${TEST_MESH_MIN_PERCENT}" "${TEST_MESH_MAX_PERCENT}")
require_candidate_faster("DensifyPointCloud elapsed" "${reference_densify_ms}" "${candidate_densify_ms}")
message(STATUS "ReconstructMesh elapsed: reference=${reference_reconstruct_ms}ms candidate=${candidate_reconstruct_ms}ms")
require_candidate_faster("RefineMesh elapsed" "${reference_refine_ms}" "${candidate_refine_ms}")

run_same_mesh_refine("${TEST_REFERENCE_BACKEND}" reference
	reference_same_mesh_refine_vertices
	reference_same_mesh_refine_faces
	reference_same_mesh_refine_ms)
run_same_mesh_refine("${TEST_CANDIDATE_BACKEND}" candidate
	candidate_same_mesh_refine_vertices
	candidate_same_mesh_refine_faces
	candidate_same_mesh_refine_ms)
compare_count_ratio("same-mesh refine vertices" "${reference_same_mesh_refine_vertices}" "${candidate_same_mesh_refine_vertices}" "${TEST_SAME_MESH_MIN_PERCENT}" "${TEST_SAME_MESH_MAX_PERCENT}")
compare_count_ratio("same-mesh refine faces" "${reference_same_mesh_refine_faces}" "${candidate_same_mesh_refine_faces}" "${TEST_SAME_MESH_MIN_PERCENT}" "${TEST_SAME_MESH_MAX_PERCENT}")
require_candidate_faster("same-mesh RefineMesh elapsed" "${reference_same_mesh_refine_ms}" "${candidate_same_mesh_refine_ms}")
remove_empty_app_logs()
