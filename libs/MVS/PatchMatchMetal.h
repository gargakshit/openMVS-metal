/*
* PatchMatchMetal.h
*
* Copyright (c) 2014-2026 SEACAVE
* Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
* Codex sign-off: OpenAI Codex assisted with this file.
*
* Author(s):
*
*      cDc <cdc.seacave@gmail.com>
*      Akshit Garg <git+openmvs-metal@akshit.network>
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

#ifndef _MVS_PATCHMATCHMETAL_H_
#define _MVS_PATCHMATCHMETAL_H_

#ifdef _USE_METAL


// I N C L U D E S /////////////////////////////////////////////////

#include "SceneDensify.h"
#include "Metal/Camera.h"

#include <cstdint>
#include <string>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

namespace MVS {

namespace METAL {

bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height,
	std::string* error = nullptr);
bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height, const float* lowDepths,
	std::string* error = nullptr);
bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height, const float* lowDepths,
	const float* depthImage, bool geometricConsistency,
	std::string* error = nullptr);
bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax,
	std::string* error = nullptr);
bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax, const float* lowDepths,
	std::string* error = nullptr);
bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax, const float* lowDepths,
	const float* depthImages, uint32_t depthImageFloats, const uint32_t* depthImageOffsets,
	bool geometricConsistency,
	std::string* error = nullptr);
bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax,
	std::string* error = nullptr);
bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax, const float* lowDepths,
	std::string* error = nullptr);
bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax, const float* lowDepths,
	const float* depthImages, uint32_t depthImageFloats, const uint32_t* depthImageOffsets,
	bool geometricConsistency,
	std::string* error = nullptr);
bool LaunchFilterPlanes(
	Point4* planes, float* costs, uint32_t* selectedViews,
	uint32_t width, uint32_t height, float thresholdKeepCost,
	std::string* error = nullptr);
bool RunPatchMatchScorePlaneSmoke(std::string* error = nullptr);
bool RunPatchMatchLowDepthPriorSmoke(std::string* error = nullptr);
bool RunPatchMatchGeometricConsistencySmoke(std::string* error = nullptr);
bool RunPatchMatchInitializeScoreSmoke(std::string* error = nullptr);
bool RunPatchMatchPropagateScoreSmoke(std::string* error = nullptr);
bool RunPatchMatchRefineScoreSmoke(std::string* error = nullptr);
bool RunPatchMatchFilterPlanesSmoke(std::string* error = nullptr);
bool RunPatchMatchHostSmoke(std::string* error = nullptr);

class PatchMatch {
public:
	PatchMatch();
	~PatchMatch();

	bool IsAvailable() const { return bAvailable; }
	void Init(bool bGeometricConsistency);
	void Release();
	bool EstimateDepthMap(DepthData& depthData);

protected:
	bool bAvailable;
	bool bGeometricConsistency;
};

} // namespace METAL

} // namespace MVS

#endif // _USE_METAL

#endif // _MVS_PATCHMATCHMETAL_H_
