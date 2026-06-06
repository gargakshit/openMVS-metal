/*
* SceneRefineMetal.h
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

#ifndef _MVS_SCENEREFINEMETAL_H_
#define _MVS_SCENEREFINEMETAL_H_

#ifdef _USE_METAL


// I N C L U D E S /////////////////////////////////////////////////

#include "Metal/Camera.h"

#include <cstdint>
#include <string>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

namespace MVS {

namespace METAL {

bool LaunchProjectMesh(
	const Point3* vertices, const Point3u* faces, const uint32_t* faceIDs,
	float* depthMap, uint32_t* faceMap, uint16_t* baryMap,
	const Camera& camera, uint32_t numFacesView,
	std::string* error = nullptr);

bool LaunchProjectMeshAndCrossCheck(
	const Point3* vertices, const Point3u* faces, const uint32_t* faceIDs,
	float* depthMap, uint32_t* faceMap, uint16_t* baryMap,
	const Camera& camera, uint32_t numFacesView,
	std::string* error = nullptr);

bool LaunchComputeFaceNormal(
	const Point3* vertices, const Point3u* faces,
	Point3* normals, uint32_t numFaces,
	std::string* error = nullptr);

bool LaunchCrossCheckProjection(
	float* depthMap, uint32_t* faceMap,
	uint32_t width, uint32_t height,
	std::string* error = nullptr);

bool LaunchComputeImageMean(
	const uint8_t* mask, const float* image,
	float* imageMean, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error = nullptr);

bool LaunchComputeImageVar(
	const float* imageMean, const uint8_t* mask, const float* image,
	float* imageVar, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error = nullptr);

bool LaunchComputeImageCov(
	const float* imageMeanA, const float* imageMeanB,
	const uint8_t* mask, const float* imageA, const float* imageB,
	float* imageCov, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error = nullptr);

bool LaunchComputeImageZNCC(
	const float* imageCov, const float* imageVarA, const float* imageVarB,
	const uint8_t* mask, float* imageZNCC,
	uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error = nullptr);

bool LaunchComputeImageDZNCC(
	const float* meanA, const float* meanB,
	const float* varA, const float* varB, const float* zncc,
	const uint8_t* mask, const float* imageA, const float* imageB,
	float* dzncc, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error = nullptr);

bool LaunchPairPhotometricGradient(
	const Point3u* faces, const Point3* normals,
	const float* depthMapA, const float* depthMapB,
	const uint32_t* faceMapA, const uint16_t* baryMapA,
	const float* imageA, const float* imageB,
	Point3* photoGrad, float* photoGradNorm,
	const Camera& camA, const Camera& camB,
	uint32_t numFaces, uint32_t numVertices,
	float regScale, uint32_t halfSize,
	bool resetAccumulation = true, bool downloadAccumulation = true,
	std::string* error = nullptr);

bool LaunchImageMeshWarp(
	const float* depthMapA, const float* depthMapB,
	const float* imageA, const float* imageB,
	uint8_t* mask, float* imageProj,
	const Camera& camA, const Camera& camB,
	std::string* error = nullptr);

bool LaunchComputePhotometricGradient(
	const Point3u* faces, const Point3* normals,
	const float* depthMap, const uint32_t* faceMap, const uint16_t* baryMap,
	const float* dzncc, const uint8_t* mask, const float* imageB,
	Point3* photoGrad, float* photoGradPixels,
	const Camera& camA, const Camera& camB, uint32_t numVertices,
	float regScale, uint32_t width, uint32_t height,
	std::string* error = nullptr);

bool LaunchUpdatePhotoGradNorm(
	float* photoGradNorm, const float* photoGradPixels,
	uint32_t numVertices, std::string* error = nullptr);

bool LaunchComputeSmoothnessGradient(
	const Point3* vertices, const uint32_t* vertVertices,
	const uint32_t* vertSizes, const uint32_t* vertPointers,
	Point3* smoothGrad, uint32_t numVertices, uint8_t mode,
	std::string* error = nullptr);

bool LaunchSmoothnessAndCombineGradients(
	const Point3* vertices, const uint32_t* vertVertices,
	const uint32_t* vertSizes, const uint32_t* vertPointers,
	Point3* photoGrad, const float* photoGradNorm,
	uint32_t numVertices, float rigidity, float elasticity,
	std::string* error = nullptr);

bool LaunchCombineGradients(
	Point3* photoGrad, const float* photoGradNorm,
	const Point3* smoothGrad, uint32_t numVertices,
	float smoothWeight, std::string* error = nullptr);

bool LaunchCombineAllGradients(
	Point3* photoGrad, const float* photoGradNorm,
	const Point3* smoothGrad1, const Point3* smoothGrad2,
	uint32_t numVertices, float rigidity, float elasticity,
	std::string* error = nullptr);

bool RunComputeFaceNormalSmoke(std::string* error = nullptr);
bool RunCameraKernelsSmoke(std::string* error = nullptr);
bool RunProjectionKernelsSmoke(std::string* error = nullptr);
bool RunImageKernelsSmoke(std::string* error = nullptr);
bool RunWarpKernelsSmoke(std::string* error = nullptr);
bool RunGradientKernelsSmoke(std::string* error = nullptr);
bool RunRefineMeshPairSmoke(std::string* error = nullptr);
bool RunRefineMeshHostSmoke(std::string* error = nullptr);

} // namespace METAL

} // namespace MVS

#endif // _USE_METAL

#endif // _MVS_SCENEREFINEMETAL_H_
