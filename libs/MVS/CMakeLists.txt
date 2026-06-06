# Find required packages
FIND_PACKAGE(CGAL REQUIRED)
if(CGAL_FOUND)
	include_directories(${CGAL_INCLUDE_DIRS})
	add_definitions(${CGAL_DEFINITIONS})
	link_directories(${CGAL_LIBRARY_DIRS})
endif()

set(CERES_LIBS "")
if(OpenMVS_USE_CERES)
	FIND_PACKAGE(Ceres)
	if(CERES_FOUND)
		include_directories(${CERES_INCLUDE_DIRS})
		add_definitions(${CERES_DEFINITIONS})
	else()
		set(OpenMVS_USE_CERES OFF)
		message("-- Can't find CERES. Continuing without it.")
	endif()
endif()

# List sources files
FILE(GLOB LIBRARY_FILES_C "*.cpp")
FILE(GLOB LIBRARY_FILES_H "*.h" "*.inl")
if(_USE_CUDA)
	FILE(GLOB LIBRARY_FILES_CUDA "*.cu")
	LIST(APPEND LIBRARY_FILES_C ${LIBRARY_FILES_CUDA})
	FILE(GLOB CUDA_LIBRARY_FILES_C "CUDA/*.cpp")
	FILE(GLOB CUDA_LIBRARY_FILES_H "CUDA/*.h" "CUDA/*.inl")
	FILE(GLOB CUDA_LIBRARY_FILES_CUDA "CUDA/*.cu")
	LIST(APPEND CUDA_LIBRARY_FILES_C ${CUDA_LIBRARY_FILES_CUDA})
	SOURCE_GROUP("CUDA" FILES ${CUDA_LIBRARY_FILES_C} ${CUDA_LIBRARY_FILES_H})
endif()
if(_USE_METAL)
	SET(PATCHMATCH_METAL_SHADER "${CMAKE_CURRENT_SOURCE_DIR}/PatchMatchMetal.metal")
	SET(PATCHMATCH_METAL_SHADER_INC "${CMAKE_CURRENT_BINARY_DIR}/PatchMatchMetalShader.inc")
	# Keep checked-in MSL as the source of truth while still using runtime
	# newLibraryWithSource() compilation from Objective-C++.
	FILE(READ "${PATCHMATCH_METAL_SHADER}" PATCHMATCH_METAL_SHADER_SOURCE)
	FILE(WRITE "${PATCHMATCH_METAL_SHADER_INC}"
		"/* Generated from PatchMatchMetal.metal by CMake; do not edit. */\n"
		"#pragma once\n"
		"static constexpr const char kPatchMatchMetalShaderSource[] = R\"OMVS_PM_METAL("
		"${PATCHMATCH_METAL_SHADER_SOURCE}"
		")OMVS_PM_METAL\";\n")
	SET(SCENEREFINE_METAL_SHADER "${CMAKE_CURRENT_SOURCE_DIR}/SceneRefineMetal.metal")
	SET(SCENEREFINE_METAL_SHADER_INC "${CMAKE_CURRENT_BINARY_DIR}/SceneRefineMetalShader.inc")
	SET(SCENEREFINE_METAL_LIBRARY "${CMAKE_CURRENT_BINARY_DIR}/SceneRefineMetal.metallib")
	SET(SCENEREFINE_METAL_LIBRARY_INC "${CMAKE_CURRENT_BINARY_DIR}/SceneRefineMetalLibrary.inc")
	SET(SCENEREFINE_METAL_CAMERA_H "${CMAKE_CURRENT_SOURCE_DIR}/Metal/Camera.h")
	SET(SCENEREFINE_METAL_MATHS_H "${CMAKE_CURRENT_SOURCE_DIR}/Metal/Maths.h")
	SET_PROPERTY(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
		"${PATCHMATCH_METAL_SHADER}"
		"${SCENEREFINE_METAL_SHADER}"
		"${SCENEREFINE_METAL_CAMERA_H}"
		"${SCENEREFINE_METAL_MATHS_H}")
	FILE(READ "${SCENEREFINE_METAL_SHADER}" SCENEREFINE_METAL_SHADER_SOURCE)
	FILE(READ "${SCENEREFINE_METAL_CAMERA_H}" SCENEREFINE_METAL_CAMERA_SOURCE)
	FILE(READ "${SCENEREFINE_METAL_MATHS_H}" SCENEREFINE_METAL_MATHS_SOURCE)
	# Runtime Metal compilation has no local include search path, so expand the
	# shared MSL headers into the generated SceneRefine shader string.
	STRING(REPLACE "#include \"Maths.h\"\n" "" SCENEREFINE_METAL_CAMERA_SOURCE "${SCENEREFINE_METAL_CAMERA_SOURCE}")
	STRING(REPLACE "#include \"Metal/Camera.h\"\n#include \"Metal/Maths.h\""
		"${SCENEREFINE_METAL_MATHS_SOURCE}\n${SCENEREFINE_METAL_CAMERA_SOURCE}"
		SCENEREFINE_METAL_RUNTIME_SOURCE
		"${SCENEREFINE_METAL_SHADER_SOURCE}")
	FILE(WRITE "${SCENEREFINE_METAL_SHADER_INC}"
		"/* Generated from SceneRefineMetal.metal by CMake; do not edit. */\n"
		"#pragma once\n"
		"static constexpr const char kSceneRefineMetalShaderSource[] = R\"OMVS_SR_METAL("
		"${SCENEREFINE_METAL_RUNTIME_SOURCE}"
		")OMVS_SR_METAL\";\n")
	ADD_CUSTOM_COMMAND(
		OUTPUT "${SCENEREFINE_METAL_LIBRARY}"
		COMMAND xcrun -sdk macosx metal
			"${SCENEREFINE_METAL_SHADER}"
			-I "${CMAKE_CURRENT_SOURCE_DIR}"
			-o "${SCENEREFINE_METAL_LIBRARY}"
		DEPENDS
			"${SCENEREFINE_METAL_SHADER}"
			"${SCENEREFINE_METAL_CAMERA_H}"
			"${SCENEREFINE_METAL_MATHS_H}"
		VERBATIM)
	ADD_CUSTOM_COMMAND(
		OUTPUT "${SCENEREFINE_METAL_LIBRARY_INC}"
		COMMAND ${CMAKE_COMMAND}
			-DINPUT=${SCENEREFINE_METAL_LIBRARY}
			-DOUTPUT=${SCENEREFINE_METAL_LIBRARY_INC}
			-DSYMBOL_PREFIX=kSceneRefineMetalLibrary
			-P "${CMAKE_SOURCE_DIR}/build/GenerateBinaryHeader.cmake"
		DEPENDS
			"${SCENEREFINE_METAL_LIBRARY}"
			"${CMAKE_SOURCE_DIR}/build/GenerateBinaryHeader.cmake"
		VERBATIM)
	SET(METAL_LIBRARY_FILES_CPP
		"${CMAKE_CURRENT_SOURCE_DIR}/SceneRefineMetal.cpp")
	SET(METAL_LIBRARY_FILES_C
		"${CMAKE_CURRENT_SOURCE_DIR}/PatchMatchMetal.mm"
		"${CMAKE_CURRENT_SOURCE_DIR}/SceneRefineMetal.mm")
	SET(METAL_LIBRARY_FILES_H
		"${PATCHMATCH_METAL_SHADER_INC}"
		"${SCENEREFINE_METAL_SHADER_INC}"
		"${SCENEREFINE_METAL_LIBRARY_INC}"
		"${CMAKE_CURRENT_SOURCE_DIR}/SceneRefineMetal.h"
		"${CMAKE_CURRENT_SOURCE_DIR}/Metal/Camera.h"
		"${CMAKE_CURRENT_SOURCE_DIR}/Metal/Maths.h")
	SET(METAL_LIBRARY_FILES_SHADER
		"${PATCHMATCH_METAL_SHADER}"
		"${SCENEREFINE_METAL_SHADER}")
	LIST(APPEND LIBRARY_FILES_C ${METAL_LIBRARY_FILES_C})
	SET_SOURCE_FILES_PROPERTIES(${METAL_LIBRARY_FILES_C} PROPERTIES
		COMPILE_OPTIONS "-fobjc-arc;-fmodules;-fcxx-modules;-fmodules-cache-path=${CMAKE_BINARY_DIR}/clang-module-cache"
		SKIP_PRECOMPILE_HEADERS ON)
	SET_SOURCE_FILES_PROPERTIES("${CMAKE_CURRENT_SOURCE_DIR}/SceneRefineMetal.mm" PROPERTIES
		OBJECT_DEPENDS "${SCENEREFINE_METAL_LIBRARY_INC}")
	SOURCE_GROUP("Metal" FILES ${METAL_LIBRARY_FILES_CPP} ${METAL_LIBRARY_FILES_C} ${METAL_LIBRARY_FILES_H} ${METAL_LIBRARY_FILES_SHADER})
endif()

GET_FILENAME_COMPONENT(PATH_PythonWrapper_cpp ${CMAKE_CURRENT_SOURCE_DIR}/PythonWrapper.cpp ABSOLUTE)
LIST(REMOVE_ITEM LIBRARY_FILES_C "${PATH_PythonWrapper_cpp}")

cxx_library_with_type(MVS "Libs" "" "${cxx_default}"
	${LIBRARY_FILES_C} ${LIBRARY_FILES_H}
	${CUDA_LIBRARY_FILES_C} ${CUDA_LIBRARY_FILES_H}
	${METAL_LIBRARY_FILES_H} ${METAL_LIBRARY_FILES_SHADER}
)
if(_USE_METAL)
	TARGET_INCLUDE_DIRECTORIES(MVS PRIVATE "${CMAKE_CURRENT_BINARY_DIR}")
endif()

# MSVC scalpel: Camera.cpp and Scene.cpp drag in a template graph (CGAL/Eigen/OpenCV)
# that lands MSVC's optimizer in a pathological codegen path. Camera.cpp takes ~3 min
# and Scene.cpp ~10 min under /O2 at this template depth.
#
# Policy:
#   * Release       — full /O2 (no override). Long compile accepted; see warning below.
#   * RelWithDebInfo/Debug — /Od for just these two files, keeping dev builds under 30 min.
#
# Implementation notes:
#   * PCH for MVS is built with /O2, so /Od on a TU reusing that PCH triggers warning
#     C4653 and cl.exe silently snaps the TU back to /O2 — the /Od becomes a no-op.
#     To actually apply /Od we must also skip the PCH on these files.
#   * SKIP_PRECOMPILE_HEADERS is set unconditionally (no genex): in Release it means
#     Camera/Scene re-parse Common.h instead of reusing the PCH (2-3s overhead, dwarfed
#     by the 10+ min optimizer cost), and in non-Release it enables the /Od override.
if(MSVC)
	set_source_files_properties(
		"${CMAKE_CURRENT_SOURCE_DIR}/Camera.cpp"
		"${CMAKE_CURRENT_SOURCE_DIR}/Scene.cpp"
		PROPERTIES
			COMPILE_OPTIONS "$<$<NOT:$<CONFIG:Release>>:/Od>"
			SKIP_PRECOMPILE_HEADERS ON
	)
	message(WARNING "MVS build speed notice:\n"
	        "  * Release builds compile Camera.cpp and Scene.cpp at full /O2. These two\n"
	        "    files alone can add 10-20 min to Release wall time due to heavy\n"
	        "    CGAL/Eigen/OpenCV template instantiation.\n"
	        "  * RelWithDebInfo (and Debug) use /Od for just these two files to keep\n"
	        "    dev-iteration builds under ~30 min; the rest of the project stays at /O2.\n"
	        "  * To speed up Release at the cost of slightly-less-optimized Camera/Scene,\n"
	        "    edit libs/MVS/CMakeLists.txt and change the COMPILE_OPTIONS line to:\n"
	        "        COMPILE_OPTIONS \"/Od\"\n"
	        "    (remove the $<NOT:$<CONFIG:Release>> generator expression).")
endif()

# Manually set Common.h as the precompiled header
IF(CMAKE_VERSION VERSION_GREATER_EQUAL 3.16.0)
	TARGET_PRECOMPILE_HEADERS(MVS PRIVATE "Common.h")
endif()

# Link its dependencies
TARGET_LINK_LIBRARIES(MVS PUBLIC Common Math IO CGAL::CGAL ${CERES_LIBRARIES})

if(OpenMVS_USE_PYTHON)
	# SFM-side wrapper lives in libs/SFM/PythonWrapper.cpp; compile it into the
	# same pyOpenMVS module so a single .pyd exposes both Scene (MVS) and
	# SfMScene (SFM) without juggling two extension modules.
	GET_FILENAME_COMPONENT(PATH_SFMPythonWrapper_cpp
		${CMAKE_CURRENT_SOURCE_DIR}/../SFM/PythonWrapper.cpp ABSOLUTE)
	# Create the Python wrapper
	cxx_library_with_type(pyOpenMVS "Libs" "SHARED" "${cxx_default}"
		${PATH_PythonWrapper_cpp}
		${PATH_SFMPythonWrapper_cpp}
	)
	# Link its dependencies; CUDA_ARCHITECTURES intentionally not set here so
	# pyOpenMVS inherits the global CMAKE_CUDA_ARCHITECTURES (defaulted to
	# "native" by the root CMakeLists when undefined) and respects any
	# -DCMAKE_CUDA_ARCHITECTURES=... the user or toolchain provides.
	TARGET_LINK_LIBRARIES(pyOpenMVS PRIVATE MVS SFM)
	# Output as a Python extension module: no "lib" prefix, ".pyd" suffix on
	# Windows so the standard `import pyOpenMVS` machinery loads it directly.
	SET_TARGET_PROPERTIES(pyOpenMVS PROPERTIES PREFIX "")
	IF(WIN32)
		SET_TARGET_PROPERTIES(pyOpenMVS PROPERTIES SUFFIX ".pyd")
	ENDIF()
	# Install pyOpenMVS.pyd alongside the openmvs/__init__.py loader so users
	# get a self-contained package: import openmvs (which adds CUDA + co-located
	# DLL search paths, then re-exports pyOpenMVS).
	INSTALL(TARGETS pyOpenMVS DESTINATION "${PYTHON_INSTALL_PATH}/openmvs")
	INSTALL(FILES ${CMAKE_SOURCE_DIR}/build/python/__init__.py
		DESTINATION "${PYTHON_INSTALL_PATH}/openmvs")
endif()

# Install
SET_TARGET_PROPERTIES(MVS PROPERTIES
	PUBLIC_HEADER "${LIBRARY_FILES_H}")
INSTALL(TARGETS MVS
	EXPORT OpenMVSTargets
	LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
	ARCHIVE DESTINATION "${INSTALL_LIB_DIR}"
	RUNTIME DESTINATION "${INSTALL_BIN_DIR}"
	PUBLIC_HEADER DESTINATION "${INSTALL_INCLUDE_DIR}/MVS")
