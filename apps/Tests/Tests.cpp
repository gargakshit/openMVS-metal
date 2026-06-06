/*
 * Tests.cpp
 *
 * Copyright (c) 2014-2025 SEACAVE
 *
 * Author(s):
 *
 *      cDc <cdc.seacave@gmail.com>
 *
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 *
 * Additional Terms:
 *
 *      You are required to preserve legal notices and author attributions in
 *      that material or in the Appropriate Legal Notices displayed by works
 *      containing it.
 */

#include "../../libs/SFM.h"
#include "../../libs/MVS.h"
#include "../../libs/Common/UtilGPU.h"
#include "../../libs/Math/LeastAbsoluteDeviationSolver.h"
#include "../../libs/Math/ConfidenceInterval.h"
#ifdef _USE_METAL
#include "../../libs/Common/UtilMetal.h"
#include "../../libs/MVS/PatchMatchMetal.h"
#include "../../libs/MVS/SceneRefineMetal.h"
#endif
#include "TestsSFM.h"
#include "TestsMVS.h"

#ifdef _USE_METAL
#include <cstdio>
#endif


// D E F I N E S ///////////////////////////////////////////////////

#define APPNAME _T("Tests")


// S T R U C T S ///////////////////////////////////////////////////

DEFINE_LOG_NAME(lt, _T("Test    "));

bool ExpectBackend(const char* label, SEACAVE::GPU::Backend got, SEACAVE::GPU::Backend expected)
{
	if (got == expected)
		return true;
	VERBOSE("ERROR: GPU backend selector %s returned %s, expected %s",
		label, SEACAVE::GPU::ToString(got), SEACAVE::GPU::ToString(expected));
	return false;
}

bool GPUBackendSelectorTest()
{
	using SEACAVE::GPU::Backend;

	if (!ExpectBackend("parse auto", SEACAVE::GPU::ParseBackend("auto"), Backend::AUTO) ||
		!ExpectBackend("parse empty", SEACAVE::GPU::ParseBackend(""), Backend::AUTO) ||
		!ExpectBackend("parse cpu", SEACAVE::GPU::ParseBackend("cpu"), Backend::CPU) ||
		!ExpectBackend("parse none", SEACAVE::GPU::ParseBackend("none"), Backend::CPU) ||
		!ExpectBackend("parse off", SEACAVE::GPU::ParseBackend("off"), Backend::CPU) ||
		!ExpectBackend("parse cuda", SEACAVE::GPU::ParseBackend("cuda"), Backend::CUDA) ||
		!ExpectBackend("parse metal", SEACAVE::GPU::ParseBackend("metal"), Backend::METAL) ||
		!ExpectBackend("parse unknown", SEACAVE::GPU::ParseBackend("vulkan"), Backend::UNKNOWN))
		return false;

	if (!ExpectBackend("auto none/non-Apple", SEACAVE::GPU::SelectAutoBackend(false, false, false), Backend::CPU) ||
		!ExpectBackend("auto CUDA/non-Apple", SEACAVE::GPU::SelectAutoBackend(true, false, false), Backend::CUDA) ||
		!ExpectBackend("auto Metal/non-Apple", SEACAVE::GPU::SelectAutoBackend(false, true, false), Backend::METAL) ||
		!ExpectBackend("auto CUDA+Metal/non-Apple", SEACAVE::GPU::SelectAutoBackend(true, true, false), Backend::CUDA) ||
		!ExpectBackend("auto none/Apple", SEACAVE::GPU::SelectAutoBackend(false, false, true), Backend::CPU) ||
		!ExpectBackend("auto CUDA/Apple", SEACAVE::GPU::SelectAutoBackend(true, false, true), Backend::CUDA) ||
		!ExpectBackend("auto Metal/Apple", SEACAVE::GPU::SelectAutoBackend(false, true, true), Backend::METAL) ||
		!ExpectBackend("auto CUDA+Metal/Apple", SEACAVE::GPU::SelectAutoBackend(true, true, true), Backend::METAL))
		return false;

	if (!ExpectBackend("resolve auto", SEACAVE::GPU::ResolveBackend(Backend::AUTO), SEACAVE::GPU::AutoBackend()) ||
		!ExpectBackend("resolve explicit CUDA", SEACAVE::GPU::ResolveBackend(Backend::CUDA), Backend::CUDA) ||
		!ExpectBackend("resolve explicit Metal", SEACAVE::GPU::ResolveBackend(Backend::METAL), Backend::METAL) ||
		!ExpectBackend("resolve explicit CPU", SEACAVE::GPU::ResolveBackend(Backend::CPU), Backend::CPU))
		return false;

	#ifdef _USE_CUDA
	const bool cudaCompiled(true);
	#else
	const bool cudaCompiled(false);
	#endif
	#ifdef _USE_METAL
	const bool metalCompiled(true);
	#else
	const bool metalCompiled(false);
	#endif
	if (SEACAVE::GPU::IsCompiled(Backend::CPU) != true ||
		SEACAVE::GPU::IsCompiled(Backend::CUDA) != cudaCompiled ||
		SEACAVE::GPU::IsCompiled(Backend::METAL) != metalCompiled) {
		VERBOSE("ERROR: GPU backend compiled-state helper mismatch");
		return false;
	}
	return true;
}

// test various algorithms independently
bool UnitTests()
{
	TD_TIMER_START();

	if (!SEACAVE::cListTest<true>(100)) {
		VERBOSE("ERROR: cListTest failed!");
		return false;
	}
	if (!SEACAVE::OctreeTest<double, 2>(100)) {
		VERBOSE("ERROR: OctreeTest<double,2> failed!");
		return false;
	}
	if (!SEACAVE::OctreeTest<float, 3>(100)) {
		VERBOSE("ERROR: OctreeTest<float,3> failed!");
		return false;
	}
	if (!SEACAVE::OctreeLODTest<double, 2>(100)) {
		VERBOSE("ERROR: OctreeLODTest<double,2> failed!");
		return false;
	}
	if (!SEACAVE::OctreeLODTest<float, 3>(100)) {
		VERBOSE("ERROR: OctreeLODTest<float,3> failed!");
		return false;
	}
	if (!SEACAVE::TestRayTriangleIntersection<float>(1000)) {
		VERBOSE("ERROR: TestRayTriangleIntersection<float> failed!");
		return false;
	}
	if (!SEACAVE::TestRayTriangleIntersection<double>(1000)) {
		VERBOSE("ERROR: TestRayTriangleIntersection<double> failed!");
		return false;
	}
	if (!SEACAVE::TestLeastAbsoluteDeviationSolver()) {
		VERBOSE("ERROR: TestLeastAbsoluteDeviationSolver failed!");
		return false;
	}
	if (!SEACAVE::TestConfidenceInterval()) {
		VERBOSE("ERROR: TestConfidenceInterval failed!");
		return false;
	}
	if (!GPUBackendSelectorTest()) {
		VERBOSE("ERROR: GPUBackendSelectorTest failed!");
		return false;
	}
	VERBOSE("All unit tests passed (%s)", TD_TIMER_GET_FMT().c_str());
	return true;
}
/*----------------------------------------------------------------*/

#ifdef _USE_METAL
bool MetalRuntimeSmokeTest()
{
	SEACAVE::METAL::Device device;
	if (!SEACAVE::METAL::getDefaultDevice(device)) {
		VERBOSE("ERROR: no default Metal device!");
		return false;
	}
	VERBOSE("Metal device initialized: %s", device.name.c_str());
	std::string error;
	if (!SEACAVE::METAL::RunSmokeTest(&error)) {
		VERBOSE("ERROR: Metal runtime smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunCameraKernelsSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine camera smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunComputeFaceNormalSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine face-normal smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunProjectionKernelsSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine projection-kernel smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunImageKernelsSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine image-kernel smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunWarpKernelsSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine warp-kernel smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunGradientKernelsSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine gradient smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunRefineMeshPairSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine chained pair smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunRefineMeshHostSmoke(&error)) {
		VERBOSE("ERROR: Metal SceneRefine host smoke test failed: %s", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchScorePlaneSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch score-plane smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch score-plane smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchLowDepthPriorSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch low-depth prior smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch low-depth prior smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchGeometricConsistencySmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch geometric-consistency smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch geometric-consistency smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchInitializeScoreSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch initialize-score smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch initialize-score smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchPropagateScoreSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch propagate-score smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch propagate-score smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchRefineScoreSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch refine-score smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch refine-score smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchFilterPlanesSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch filter smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch filter smoke test failed: %s\n", error.c_str());
		return false;
	}
	if (!MVS::METAL::RunPatchMatchHostSmoke(&error)) {
		VERBOSE("ERROR: Metal PatchMatch host smoke test failed: %s", error.c_str());
		std::fprintf(stderr, "ERROR: Metal PatchMatch host smoke test failed: %s\n", error.c_str());
		return false;
	}
	VERBOSE("Metal runtime smoke test passed");
	return true;
}
/*----------------------------------------------------------------*/
#endif


// test OpenMVS functionality
int main(int argc, LPCTSTR* argv)
{
	// Flush stdout/stderr per write so CI logs aren't lost on SIGKILL.
	// MSVC's ucrtbase rejects (buf=NULL, size=0) with mode!=_IONBF as an invalid
	// parameter (fatal), and treats _IOLBF as _IOFBF anyway — so use _IONBF there.
	#ifdef _MSC_VER
	std::setvbuf(stdout, NULL, _IONBF, 0);
	std::setvbuf(stderr, NULL, _IONBF, 0);
	#else
	std::setvbuf(stdout, NULL, _IOLBF, 0);
	std::setvbuf(stderr, NULL, _IOLBF, 0);
	#endif
	OPEN_LOG();
	OPEN_LOGCONSOLE();
	Initialize(APPNAME, 4);
	WORKING_FOLDER = _DATA_PATH;
	INIT_WORKING_FOLDER;
	const bool verbose = (argc > 2 && std::atoi(argv[2]) != 0);
	const bool forceCPU = (argc > 3 && std::atoi(argv[3]) != 0);
	const char* expectedMVSBackend = (argc > 4 ? argv[4] : nullptr);
	if (argc < 2 || std::atoi(argv[1]) == 0) {
		if (!UnitTests())
			return EXIT_FAILURE;
	} else if (std::atoi(argv[1]) == 1) {
		// Run SFM smoke tests
		if (!SFM::TestSimilarityTransform())
			return EXIT_FAILURE;
		if (!SFM::PairsWeightingTest())
			return EXIT_FAILURE;
		if (!SFM::ViewGraphCalibratorTest())
			return EXIT_FAILURE;
		if (!SFM::BAPinholeReprojectionJacobianTest())
			return EXIT_FAILURE;
		if (!SFM::RotationEstimatorTest())
			return EXIT_FAILURE;
		if (!SFM::ScaleEstimatorTest())
			return EXIT_FAILURE;
		if (!SFM::TranslationEstimatorTest())
			return EXIT_FAILURE;
		if (!SFM::TripletStarInitTest())
			return EXIT_FAILURE;
		if (!SFM::PreMatchTest())
			return EXIT_FAILURE;
		if (!SFM::PairMatcherTest())
			return EXIT_FAILURE;
		if (!SFM::TwoViewTest())
			return EXIT_FAILURE;
		if (!SFM::VocabularyTreeTest())
			return EXIT_FAILURE;
		if (!SFM::PipelineTest())
			return EXIT_FAILURE;
		if (!SFM::ReconstructSphericalSyntheticTest())
			return EXIT_FAILURE;
		if (!SFM::PairsMatcherSphericalTest())
			return EXIT_FAILURE;
		if (!SFM::MatchGeometricSphericalTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapFaceRenderTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapBridgeGeometryTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapBridgeEndToEndTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapBridgeMVSLoadTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapBridgeMixedSceneTest())
			return EXIT_FAILURE;
		if (!SFM::CubeMapBridgeDropTopBottomTest())
			return EXIT_FAILURE;
		if (!SFM::ReconstructTest(verbose))
			return EXIT_FAILURE;
		// Hierarchical SFM tests - Phase 1: Scene Clustering
		if (!SFM::SceneClusterSingleClusterTest())
			return EXIT_FAILURE;
		if (!SFM::SceneClusterSizeConstraintsTest())
			return EXIT_FAILURE;
		if (!SFM::SceneClusterDisconnectedComponentsTest())
			return EXIT_FAILURE;
		if (!SFM::SceneClusterMemoryProtocolTest())
			return EXIT_FAILURE;
		if (!SFM::SceneClusterIDRemappingTest())
			return EXIT_FAILURE;
		if (!SFM::SceneClusterSmallClusterRescueTest())
			return EXIT_FAILURE;
		// Hierarchical SFM tests - Phase 3: Global Alignment
		if (!SFM::GlobalAlignmentBuildGlobalToLocalMapTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentRotationAveragingExtendedTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentScaleAveragingExtendedTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentScaleAveragingFallbackTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentTranslationAveragingExtendedTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentMergeSingleSceneTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentTrackMergeDuplicateImageGuardTest())
			return EXIT_FAILURE;
		if (!SFM::GlobalAlignmentTrackMerge3DProximityGuardTest())
			return EXIT_FAILURE;
		// Hierarchical SFM tests - End-to-End
		if (!SFM::HierarchicalSFMSplitMergeRoundtripTest())
			return EXIT_FAILURE;
		if (!SFM::HierarchicalSFMWithRandomTransformTest())
			return EXIT_FAILURE;
	} else if (std::atoi(argv[1]) == 3) {
		#ifdef _USE_METAL
		if (!MetalRuntimeSmokeTest())
			return EXIT_FAILURE;
		#else
		VERBOSE("ERROR: Metal runtime smoke test requested but OpenMVS was built without Metal!");
		return EXIT_FAILURE;
		#endif
	} else if (std::atoi(argv[1]) == 4) {
		#ifdef _USE_METAL
		if (!MVS::RefineMeshMetalSampleTest())
			return EXIT_FAILURE;
		#else
		VERBOSE("ERROR: Metal RefineMesh sample test requested but OpenMVS was built without Metal!");
		return EXIT_FAILURE;
		#endif
	} else if (std::atoi(argv[1]) == 5) {
		#ifdef _USE_METAL
		if (!MVS::DenseReconstructionMetalParityTest())
			return EXIT_FAILURE;
		#else
		VERBOSE("ERROR: Metal dense reconstruction parity test requested but OpenMVS was built without Metal!");
		return EXIT_FAILURE;
		#endif
	} else {
		// Run MVS pipeline test
		if (!MVS::PipelineTest(forceCPU, verbose, expectedMVSBackend))
			return EXIT_FAILURE;
	}
	Finalize();
	CLOSE_LOGCONSOLE();
	CLOSE_LOG();
	return EXIT_SUCCESS;
}
/*----------------------------------------------------------------*/
