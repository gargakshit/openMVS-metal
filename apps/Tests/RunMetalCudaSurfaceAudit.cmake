# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.

if(NOT DEFINED TEST_SOURCE_DIR)
	message(FATAL_ERROR "TEST_SOURCE_DIR is required")
endif()

get_filename_component(TEST_SOURCE_DIR "${TEST_SOURCE_DIR}" ABSOLUTE)

function(read_required path out_var)
	if(NOT EXISTS "${path}")
		message(FATAL_ERROR "required source file not found: ${path}")
	endif()
	file(READ "${path}" content)
	set(${out_var} "${content}" PARENT_SCOPE)
endfunction()

function(require_contains label haystack needle)
	string(FIND "${haystack}" "${needle}" found)
	if(found EQUAL -1)
		message(FATAL_ERROR "${label}: missing '${needle}'")
	endif()
endfunction()

function(require_absent label haystack needle)
	string(FIND "${haystack}" "${needle}" found)
	if(NOT found EQUAL -1)
		message(FATAL_ERROR "${label}: unexpected '${needle}'")
	endif()
endfunction()

function(require_list_contains label items expected)
	list(FIND items "${expected}" found)
	if(found EQUAL -1)
		message(FATAL_ERROR "${label}: missing '${expected}'")
	endif()
endfunction()

function(require_match_count label haystack pattern expected)
	string(REGEX MATCHALL "${pattern}" matches "${haystack}")
	list(LENGTH matches actual)
	if(NOT actual EQUAL expected)
		message(FATAL_ERROR "${label}: expected ${expected} matches for '${pattern}', found ${actual}")
	endif()
endfunction()

function(require_declared_smokes_invoked label header_content tests_content)
	string(REGEX MATCHALL "bool Run[A-Za-z0-9_]+Smoke\\(" smoke_decls "${header_content}")
	foreach(smoke_decl IN LISTS smoke_decls)
		string(REGEX REPLACE "^bool (Run[A-Za-z0-9_]+Smoke)\\($" "\\1" smoke_name "${smoke_decl}")
		require_contains("${label} invocation" "${tests_content}" "MVS::METAL::${smoke_name}(&error)")
	endforeach()
endfunction()

file(GLOB mvs_cuda_files RELATIVE "${TEST_SOURCE_DIR}/libs/MVS" "${TEST_SOURCE_DIR}/libs/MVS/*.cu")
list(SORT mvs_cuda_files)
set(expected_mvs_cuda_files
	"PatchMatchCUDA.cu"
	"SceneRefineCUDA.cu"
)
foreach(cuda_file IN LISTS mvs_cuda_files)
	list(FIND expected_mvs_cuda_files "${cuda_file}" found)
	if(found EQUAL -1)
		message(FATAL_ERROR "unexpected MVS CUDA translation unit without Metal audit coverage: ${cuda_file}")
	endif()
endforeach()
foreach(cuda_file IN LISTS expected_mvs_cuda_files)
	require_list_contains("MVS CUDA translation units" "${mvs_cuda_files}" "${cuda_file}")
endforeach()

read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineCUDA.cu" scene_refine_cuda)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineCUDA.cpp" scene_refine_cuda_host)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineCUDA.inl" scene_refine_cuda_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineMetal.metal" scene_refine_metal)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineMetal.h" scene_refine_metal_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineMetal.mm" scene_refine_metal_host)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneRefineMetal.cpp" scene_refine_metal_bridge)
read_required("${TEST_SOURCE_DIR}/libs/MVS/CUDA/Camera.h" cuda_camera_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/CUDA/Maths.h" cuda_maths_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/Metal/Camera.h" metal_camera_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/Metal/Maths.h" metal_maths_header)
read_required("${TEST_SOURCE_DIR}/apps/Tests/Tests.cpp" tests_cpp)
read_required("${TEST_SOURCE_DIR}/CMakeLists.txt" root_cmake)

require_contains("Metal runtime smoke CTest registration" "${root_cmake}" "ADD_TEST(NAME MetalRuntimeSmoke COMMAND $<TARGET_FILE:Tests> \"3\")")
require_declared_smokes_invoked("SceneRefine Metal smoke" "${scene_refine_metal_header}" "${tests_cpp}")

require_contains("SceneRefine CUDA helper include" "${scene_refine_cuda_header}" "#include \"CUDA/Camera.h\"")
require_contains("SceneRefine Metal helper include" "${scene_refine_metal}" "#include \"Metal/Camera.h\"")
require_contains("SceneRefine Metal helper include" "${scene_refine_metal}" "#include \"Metal/Maths.h\"")

set(camera_helper_structs
	"LinearCameraModel"
	"Pose"
	"Camera"
)
foreach(helper_name IN LISTS camera_helper_structs)
	require_contains("CUDA camera helper surface" "${cuda_camera_header}" "struct ${helper_name}")
	require_contains("Metal camera helper surface" "${metal_camera_header}" "struct ${helper_name}")
endforeach()

set(camera_transform_helpers
	"TransformPointC2I"
	"TransformPointI2C"
	"TransformPointW2C"
	"TransformPointC2W"
	"TransformPointW2I"
	"TransformPointI2W"
)
foreach(helper_name IN LISTS camera_transform_helpers)
	require_contains("CUDA camera transform helper" "${cuda_camera_header}" "${helper_name}")
	require_contains("Metal camera transform helper" "${metal_camera_header}" "${helper_name}")
endforeach()
require_contains("Metal camera host layout check" "${metal_camera_header}" "static_assert(sizeof(LinearCameraModel)")
require_contains("Metal camera host layout check" "${metal_camera_header}" "static_assert(sizeof(Pose)")
require_contains("Metal camera host layout check" "${metal_camera_header}" "static_assert(sizeof(Camera)")

set(maths_helper_types
	"Point2"
	"Point3"
	"Point4"
	"Point2i"
	"Point3u"
	"Matrix3"
)
foreach(helper_name IN LISTS maths_helper_types)
	require_contains("CUDA maths helper surface" "${cuda_maths_header}" "${helper_name}")
	require_contains("Metal maths helper surface" "${metal_maths_header}" "${helper_name}")
endforeach()
require_contains("Metal maths load helper" "${metal_maths_header}" "Load(const Point2")
require_contains("Metal maths load helper" "${metal_maths_header}" "Load(const Point3")
require_contains("Metal maths load helper" "${metal_maths_header}" "Load(const Point4")
require_contains("Metal maths load helper" "${metal_maths_header}" "Load(const Point2i")
require_contains("Metal maths load helper" "${metal_maths_header}" "Load(const Point3u")
require_contains("Metal maths store helper" "${metal_maths_header}" "StorePoint2")
require_contains("Metal maths store helper" "${metal_maths_header}" "StorePoint3")
require_contains("Metal maths store helper" "${metal_maths_header}" "StorePoint4")
require_contains("Metal maths matrix multiply helper" "${metal_maths_header}" "Mul(const Matrix3")
require_contains("Metal maths matrix transpose multiply helper" "${metal_maths_header}" "MulTranspose(const Matrix3")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Point2)")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Point3)")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Point4)")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Point2i)")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Point3u)")
require_contains("Metal maths host layout check" "${metal_maths_header}" "static_assert(sizeof(Matrix3)")

set(scene_refine_kernels
	"kernelProjectMesh"
	"kernelCrossCheckProjection"
	"kernelImageMeshWarp"
	"kernelComputeImageMean"
	"kernelComputeImageVar"
	"kernelComputeImageCov"
	"kernelComputeImageZNCC"
	"kernelComputeImageDZNCC"
	"kernelComputePhotometricGradient"
	"kernelUpdatePhotoGradNorm"
	"kernelComputeSmoothnessGradient"
	"kernelCombineGradients"
	"kernelCombineAllGradients"
	"kernelComputeFaceNormal"
)
list(LENGTH scene_refine_kernels scene_refine_kernel_count)
require_match_count("SceneRefine CUDA kernel declaration count" "${scene_refine_cuda}" "__global__ void kernel[A-Za-z0-9_]+" "${scene_refine_kernel_count}")
foreach(kernel_name IN LISTS scene_refine_kernels)
	require_contains("SceneRefine CUDA kernel surface" "${scene_refine_cuda}" "__global__ void ${kernel_name}")
	require_contains("SceneRefine Metal kernel surface" "${scene_refine_metal}" "kernel void ${kernel_name}")
	string(REGEX REPLACE "^kernel" "Launch" launcher_name "${kernel_name}")
	require_contains("SceneRefine CUDA host launch surface" "${scene_refine_cuda_host}" "MVS::CUDA::${launcher_name}")
	require_contains("SceneRefine Metal launcher declaration" "${scene_refine_metal_header}" "${launcher_name}")
	require_contains("SceneRefine Metal launcher implementation" "${scene_refine_metal_host}" "bool ${launcher_name}")
endforeach()
require_contains("SceneRefine Metal bridge" "${scene_refine_metal_bridge}" "Scene::RefineMeshMetal")

read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchCUDA.cu" patch_match_cuda)
read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchCUDA.cpp" patch_match_cuda_host)
read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchCUDA.inl" patch_match_cuda_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchMetal.metal" patch_match_metal)
read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchMetal.h" patch_match_metal_header)
read_required("${TEST_SOURCE_DIR}/libs/MVS/PatchMatchMetal.mm" patch_match_metal_host)
read_required("${TEST_SOURCE_DIR}/libs/MVS/SceneDensify.cpp" scene_densify)

set(patch_match_cuda_kernels
	"InitializeScore"
	"BlackPixelProcess"
	"RedPixelProcess"
)
foreach(kernel_name IN LISTS patch_match_cuda_kernels)
	require_contains("PatchMatch CUDA kernel surface" "${patch_match_cuda}" "__global__ PATCHMATCHCUDA_LAUNCH_BOUNDS void ${kernel_name}")
endforeach()
require_contains("PatchMatch CUDA kernel surface" "${patch_match_cuda}" "__global__ void FilterPlanes")
require_match_count("PatchMatch CUDA kernel declaration count" "${patch_match_cuda}" "__global__[^\\n]*void [A-Za-z0-9_]+" 4)
require_contains("PatchMatch CUDA host path" "${patch_match_cuda_host}" "void PatchMatch::EstimateDepthMap")
require_contains("PatchMatch CUDA host path" "${patch_match_cuda}" "__host__ void PatchMatch::RunCUDA")
require_contains("PatchMatch CUDA host API" "${patch_match_cuda_header}" "class PatchMatch")
require_contains("PatchMatch CUDA host API" "${patch_match_cuda_header}" "void Init(bool bGeomConsistency)")
require_contains("PatchMatch CUDA host API" "${patch_match_cuda_header}" "void Release()")
require_contains("PatchMatch CUDA host API" "${patch_match_cuda_header}" "void EstimateDepthMap(DepthData&)")

require_contains("PatchMatch Metal score kernel" "${patch_match_metal}" "kernel void kernelScorePlanePair")
require_contains("PatchMatch Metal initialize kernel" "${patch_match_metal}" "kernel void kernelInitializeScore")
require_contains("PatchMatch Metal propagation kernel" "${patch_match_metal}" "kernel void kernelPropagateScore")
require_contains("PatchMatch Metal filter kernel" "${patch_match_metal}" "kernel void kernelFilterPlanes")
require_contains("PatchMatch Metal host API" "${patch_match_metal_header}" "class PatchMatch")
require_contains("PatchMatch Metal host API" "${patch_match_metal_header}" "void Init(bool bGeometricConsistency)")
require_contains("PatchMatch Metal host API" "${patch_match_metal_header}" "void Release()")
require_contains("PatchMatch Metal host API" "${patch_match_metal_header}" "bool EstimateDepthMap(DepthData& depthData)")
require_contains("PatchMatch Metal launcher declaration" "${patch_match_metal_header}" "LaunchInitializeScore")
require_contains("PatchMatch Metal launcher declaration" "${patch_match_metal_header}" "LaunchPropagateScore")
require_contains("PatchMatch Metal launcher declaration" "${patch_match_metal_header}" "LaunchFilterPlanes")
require_declared_smokes_invoked("PatchMatch Metal smoke" "${patch_match_metal_header}" "${tests_cpp}")
require_contains("PatchMatch Metal host path" "${patch_match_metal_host}" "bool PatchMatch::EstimateDepthMap")
require_contains("PatchMatch Metal resident level launcher" "${patch_match_metal_host}" "LaunchPatchMatchLevelResident")
require_contains("PatchMatch Metal resident mutable plane buffer" "${patch_match_metal_host}" "id<MTLBuffer> planesBuffer = [device newBufferWithBytes:planes")
require_contains("PatchMatch Metal resident mutable cost buffer" "${patch_match_metal_host}" "id<MTLBuffer> costsBuffer = [device newBufferWithBytes:costs")
require_contains("PatchMatch Metal resident mutable view buffer" "${patch_match_metal_host}" "id<MTLBuffer> selectedViewsBuffer = [device newBufferWithBytes:selectedViews")
require_contains("PatchMatch Metal resident initialize dispatch" "${patch_match_metal_host}" "EncodeDispatch2D(encoder, initializePipeline")
require_contains("PatchMatch Metal resident propagate dispatch" "${patch_match_metal_host}" "DispatchThreads2D(encoder, propagatePipeline")
require_contains("PatchMatch Metal resident filter dispatch" "${patch_match_metal_host}" "EncodeDispatch2D(encoder, filterPipeline")
require_contains("PatchMatch Metal resident final plane download" "${patch_match_metal_host}" "std::memcpy(planes, [planesBuffer contents]")
require_contains("PatchMatch Metal resident production path" "${patch_match_metal_host}" "if (!LaunchPatchMatchLevelResident(")
require_contains("PatchMatch Metal host path" "${patch_match_metal_host}" "LaunchInitializeScore")
require_contains("PatchMatch Metal host path" "${patch_match_metal_host}" "LaunchPropagateScore")
require_contains("PatchMatch Metal host path" "${patch_match_metal_host}" "LaunchFilterPlanes")
require_absent("PatchMatch Metal selected path must not advertise CPU fallback" "${patch_match_metal_host}" "using CPU depth-map estimation")

require_contains("Densify CUDA dispatch" "${scene_densify}" "MVS::CUDA::PatchMatch")
require_contains("Densify CUDA dispatch" "${scene_densify}" "pmCUDAPool[s_slot]->EstimateDepthMap")
require_contains("Densify Metal dispatch" "${scene_densify}" "MVS::METAL::PatchMatch")
require_contains("Densify Metal dispatch" "${scene_densify}" "pmMetalPool[s_slot]->EstimateDepthMap")

message(STATUS "MVS CUDA-to-Metal source surface audit passed")
