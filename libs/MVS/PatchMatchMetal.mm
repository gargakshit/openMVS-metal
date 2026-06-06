/*
* PatchMatchMetal.mm
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

#include "Common.h"
#include "PatchMatchMetal.h"
#include "../Common/UtilMetal.h"

#ifdef _USE_METAL

#include "PatchMatchMetalShader.inc"

@import Foundation;
@import Metal;

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>


// D E F I N E S ///////////////////////////////////////////////////


namespace MVS {

namespace METAL {

// S T R U C T S ///////////////////////////////////////////////////

static std::string ToString(NSString* str)
{
	return str != nil ? std::string([str UTF8String]) : std::string();
}

static void SetError(std::string* error, NSString* message)
{
	if (error != nullptr)
		*error = ToString(message);
}

static void SetError(std::string* error, NSError* nsError, const char* fallback)
{
	if (error == nullptr)
		return;
	if (nsError != nil && [nsError localizedDescription] != nil)
		*error = ToString([nsError localizedDescription]);
	else
		*error = fallback;
}

static uint32_t HashUintHost(uint32_t x)
{
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

static float HashFloatHost(uint32_t x)
{
	return (float)(HashUintHost(x) & 0x00ffffffu) / 16777216.f;
}

static float SampleImageLinearHost(const std::vector<float>& image, uint32_t width, uint32_t height, float x, float y)
{
	x = std::min(std::max(x, 0.f), (float)(width - 1u));
	y = std::min(std::max(y, 0.f), (float)(height - 1u));
	const uint32_t x0((uint32_t)std::floor(x));
	const uint32_t y0((uint32_t)std::floor(y));
	const uint32_t x1(std::min(x0 + 1u, width - 1u));
	const uint32_t y1(std::min(y0 + 1u, height - 1u));
	const float tx(x - (float)x0);
	const float ty(y - (float)y0);
	const float v00(image[(size_t)y0*width + x0]);
	const float v10(image[(size_t)y0*width + x1]);
	const float v01(image[(size_t)y1*width + x0]);
	const float v11(image[(size_t)y1*width + x1]);
	return (v00*(1.f - tx) + v10*tx)*(1.f - ty) + (v01*(1.f - tx) + v11*tx)*ty;
}

static NSString* PatchMatchShaderSource()
{
	return [NSString stringWithUTF8String:kPatchMatchMetalShaderSource];
}

static id<MTLComputePipelineState> CreatePipeline(id<MTLDevice> device, NSString* functionName, std::string* error)
{
	NSError* nsError = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:PatchMatchShaderSource() options:nil error:&nsError];
	if (library == nil) {
		SetError(error, nsError, "failed to compile PatchMatch Metal library");
		return nil;
	}
	id<MTLFunction> function = [library newFunctionWithName:functionName];
	if (function == nil) {
		SetError(error, [NSString stringWithFormat:@"failed to load %@", functionName]);
		return nil;
	}
	id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&nsError];
	if (pipeline == nil)
		SetError(error, nsError, "failed to create PatchMatch Metal pipeline");
	return pipeline;
}

static bool Dispatch2D(
	id<MTLCommandQueue> queue, id<MTLComputePipelineState> pipeline,
	uint32_t width, uint32_t height,
	id<MTLBuffer> const* buffers, NSUInteger numBuffers,
	const char* kernelName, std::string* error)
{
	id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
	id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
	if (commandBuffer == nil || encoder == nil) {
		SetError(error, @"failed to create Metal command encoder");
		return false;
	}
	[encoder setComputePipelineState:pipeline];
	for (NSUInteger i = 0; i < numBuffers; ++i)
		[encoder setBuffer:buffers[i] offset:0 atIndex:i];
	const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)width, 16u);
	const NSUInteger groupHeight = std::min<NSUInteger>(
		(NSUInteger)height,
		std::max<NSUInteger>(1u, [pipeline maxTotalThreadsPerThreadgroup] / groupWidth));
	[encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, groupHeight, 1)];
	[encoder endEncoding];
	[commandBuffer commit];
	[commandBuffer waitUntilCompleted];
	if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
		SetError(error, [commandBuffer error], kernelName);
		return false;
	}
	return true;
}

static const float* ResolveLowDepths(const float* lowDepths, size_t area, std::vector<float>& zeroLowDepths)
{
	if (lowDepths != nullptr)
		return lowDepths;
	zeroLowDepths.assign(area, 0.f);
	return zeroLowDepths.data();
}

static Camera MakeMetalCamera(const ::MVS::Camera& camera, const cv::Size& size)
{
	Camera metalCamera = {};
	metalCamera.model.f = {(float)camera.K(0,0), (float)camera.K(1,1)};
	metalCamera.model.p = {(float)camera.K(0,2), (float)camera.K(1,2)};
	for (int r = 0; r < 3; ++r)
		for (int c = 0; c < 3; ++c)
			metalCamera.pose.R.m[r*3 + c] = (float)camera.R(r,c);
	metalCamera.pose.C = {(float)camera.C.x, (float)camera.C.y, (float)camera.C.z};
	metalCamera.size = {size.width, size.height};
	return metalCamera;
}

static bool PackImage(const Image32F& image, std::vector<float>& packed, std::string* error)
{
	if (image.empty()) {
		if (error != nullptr)
			*error = "empty PatchMatch Metal image";
		return false;
	}
	const uint32_t width((uint32_t)image.cols);
	const uint32_t height((uint32_t)image.rows);
	packed.resize((size_t)width * height);
	for (uint32_t y = 0; y < height; ++y)
		std::memcpy(packed.data() + (size_t)y*width, image.ptr<float>((int)y), sizeof(float)*width);
	return true;
}

static bool PackDepthMap(const DepthMap& depthMap, std::vector<float>& packed, std::string* error)
{
	if (depthMap.empty()) {
		if (error != nullptr)
			*error = "empty PatchMatch Metal depth map";
		return false;
	}
	const uint32_t width((uint32_t)depthMap.cols);
	const uint32_t height((uint32_t)depthMap.rows);
	packed.resize((size_t)width * height);
	for (uint32_t y = 0; y < height; ++y)
		std::memcpy(packed.data() + (size_t)y*width, depthMap.ptr<float>((int)y), sizeof(float)*width);
	return true;
}

static bool AppendImage(const Image32F& image, std::vector<float>& packed, uint32_t& offset, std::string* error)
{
	offset = (uint32_t)packed.size();
	std::vector<float> tmp;
	if (!PackImage(image, tmp, error))
		return false;
	packed.insert(packed.end(), tmp.begin(), tmp.end());
	return true;
}

static bool AppendDepthImage(const DepthMap& depthMap, const cv::Size& size, std::vector<float>& packed, uint32_t& offset, std::string* error)
{
	if (depthMap.empty()) {
		if (error != nullptr)
			*error = "missing PatchMatch Metal geometric depth image";
		return false;
	}
	DepthMap depthResized;
	const DepthMap* depth(&depthMap);
	if (depthMap.size() != size) {
		cv::resize(depthMap, depthResized, size, 0, 0, cv::INTER_LINEAR);
		depth = &depthResized;
	}
	offset = (uint32_t)packed.size();
	const uint32_t width((uint32_t)depth->cols);
	const uint32_t height((uint32_t)depth->rows);
	packed.resize(packed.size() + (size_t)width * height);
	for (uint32_t y = 0; y < height; ++y)
		std::memcpy(packed.data() + offset + (size_t)y*width, depth->ptr<float>((int)y), sizeof(float)*width);
	return true;
}

static void PackDepthNormalPlanes(const DepthData& depthData, std::vector<Point4>& planes)
{
	const uint32_t width((uint32_t)depthData.depthMap.cols);
	const uint32_t height((uint32_t)depthData.depthMap.rows);
	planes.resize((size_t)width * height);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const Normal& normal = depthData.normalMap((int)y, (int)x);
			const Depth depth = depthData.depthMap((int)y, (int)x);
			planes[(size_t)y*width + x] = {(float)normal.x, (float)normal.y, (float)normal.z, (float)depth};
		}
	}
}

static void UnpackDepthNormalPlanes(
	DepthData& depthData,
	const std::vector<Point4>& planes,
	const std::vector<float>& costs,
	const std::vector<uint32_t>& selectedViews,
	bool finalLevel)
{
	const uint32_t width((uint32_t)depthData.depthMap.cols);
	const uint32_t height((uint32_t)depthData.depthMap.rows);
	if (finalLevel && depthData.confMap.empty())
		depthData.confMap.create(depthData.depthMap.size());
	if (depthData.viewsMap.empty())
		depthData.viewsMap.create(depthData.depthMap.size());
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const size_t idx((size_t)y*width + x);
			const Point4& plane = planes[idx];
			const Depth depth(plane.w);
			depthData.depthMap((int)y, (int)x) = depth;
			depthData.normalMap((int)y, (int)x) = Normal(plane.x, plane.y, plane.z);
			ViewsID& views = depthData.viewsMap((int)y, (int)x);
			if (!finalLevel) {
				const uint32_t bitviews(selectedViews[idx]);
				std::memcpy(views.val, &bitviews, sizeof(bitviews));
				continue;
			}
			float& conf = depthData.confMap((int)y, (int)x);
			conf = costs[idx] >= 1.f ? 0.f : 1.f - costs[idx];
			if (depth > 0) {
				const uint32_t bitviews(selectedViews[idx]);
				int j = 0;
				for (int i = 0; i < 32; ++i) {
					if ((bitviews & (1u << i)) != 0u) {
						views[j] = (uint8_t)i;
						if (++j == 4)
							break;
					}
				}
				while (j < 4)
					views[j++] = 255;
			} else {
				views = ViewsID(255, 255, 255, 255);
			}
		}
	}
}

bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height,
	std::string* error)
{
	return LaunchScorePlanePair(imageRef, imageTrg, planes, costs, refCamera, trgCamera, width, height, nullptr, error);
}

bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height, const float* lowDepths,
	std::string* error)
{
	return LaunchScorePlanePair(
		imageRef, imageTrg, planes, costs,
		refCamera, trgCamera, width, height,
		lowDepths, nullptr, false, error);
}

bool LaunchScorePlanePair(
	const float* imageRef, const float* imageTrg, const Point4* planes,
	float* costs, const Camera& refCamera, const Camera& trgCamera,
	uint32_t width, uint32_t height, const float* lowDepths,
	const float* depthImage, bool geometricConsistency,
	std::string* error)
{
	const size_t area((size_t)width * (size_t)height);
	if (area == 0)
		return true;
	std::vector<float> zeroLowDepths;
	lowDepths = ResolveLowDepths(lowDepths, area, zeroLowDepths);
	const uint32_t trgWidth((uint32_t)trgCamera.size.x);
	const uint32_t trgHeight((uint32_t)trgCamera.size.y);
	const size_t trgArea((size_t)trgWidth * (size_t)trgHeight);
	if (trgArea == 0) {
		SetError(error, @"invalid target camera size for kernelScorePlanePair");
		return false;
	}
	std::vector<float> zeroDepthImage;
	const uint32_t useGeometricConsistency(geometricConsistency ? 1u : 0u);
	if (geometricConsistency) {
		if (depthImage == nullptr) {
			SetError(error, @"missing depth image for geometric PatchMatch score");
			return false;
		}
	} else {
		zeroDepthImage.assign(trgArea, 0.f);
		depthImage = zeroDepthImage.data();
	}
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelScorePlanePair", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			SetError(error, @"failed to create Metal command queue");
			return false;
		}
		id<MTLBuffer> imageRefBuffer = [device newBufferWithBytes:imageRef length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageTrgBuffer = [device newBufferWithBytes:imageTrg length:sizeof(float)*trgArea options:MTLResourceStorageModeShared];
		id<MTLBuffer> planesBuffer = [device newBufferWithBytes:planes length:sizeof(Point4)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> costsBuffer = [device newBufferWithBytes:costs length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> refCameraBuffer = [device newBufferWithBytes:&refCamera length:sizeof(refCamera) options:MTLResourceStorageModeShared];
		id<MTLBuffer> trgCameraBuffer = [device newBufferWithBytes:&trgCamera length:sizeof(trgCamera) options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> lowDepthsBuffer = [device newBufferWithBytes:lowDepths length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthImageBuffer = [device newBufferWithBytes:depthImage length:sizeof(float)*trgArea options:MTLResourceStorageModeShared];
		id<MTLBuffer> useGeomBuffer = [device newBufferWithBytes:&useGeometricConsistency length:sizeof(useGeometricConsistency) options:MTLResourceStorageModeShared];
		if (imageRefBuffer == nil || imageTrgBuffer == nil || planesBuffer == nil || costsBuffer == nil ||
			refCameraBuffer == nil || trgCameraBuffer == nil || widthBuffer == nil || heightBuffer == nil ||
			lowDepthsBuffer == nil || depthImageBuffer == nil || useGeomBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelScorePlanePair");
			return false;
		}
		id<MTLBuffer> buffers[] = {
			imageRefBuffer, imageTrgBuffer, planesBuffer, costsBuffer,
			refCameraBuffer, trgCameraBuffer, widthBuffer, heightBuffer,
			lowDepthsBuffer, depthImageBuffer, useGeomBuffer
		};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 11, "kernelScorePlanePair command buffer failed", error))
			return false;
		std::memcpy(costs, [costsBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax,
	std::string* error)
{
	return LaunchInitializeScore(
		imageRef, targetImages, targetImageFloats, targetImageOffsets,
		planes, costs, selectedViews,
		refCamera, targetCameras,
		width, height, numTargets, initTopK,
		depthMin, depthMax, nullptr, error);
}

bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax, const float* lowDepths,
	std::string* error)
{
	return LaunchInitializeScore(
		imageRef, targetImages, targetImageFloats, targetImageOffsets,
		planes, costs, selectedViews,
		refCamera, targetCameras,
		width, height, numTargets, initTopK,
		depthMin, depthMax, lowDepths,
		nullptr, 0, nullptr, false, error);
}

bool LaunchInitializeScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t initTopK,
	float depthMin, float depthMax, const float* lowDepths,
	const float* depthImages, uint32_t depthImageFloats, const uint32_t* depthImageOffsets,
	bool geometricConsistency,
	std::string* error)
{
	const size_t area((size_t)width * (size_t)height);
	if (area == 0)
		return true;
	std::vector<float> zeroLowDepths;
	lowDepths = ResolveLowDepths(lowDepths, area, zeroLowDepths);
	if (numTargets == 0 || numTargets > 32 || initTopK == 0 || initTopK > numTargets) {
		SetError(error, @"invalid PatchMatch initialize-score view counts");
		return false;
	}
	if (targetImageFloats == 0 || depthMax <= depthMin) {
		SetError(error, @"invalid PatchMatch initialize-score inputs");
		return false;
	}
	std::vector<float> zeroDepthImages;
	const uint32_t useGeometricConsistency(geometricConsistency ? 1u : 0u);
	if (geometricConsistency) {
		if (depthImages == nullptr || depthImageOffsets == nullptr || depthImageFloats == 0) {
			SetError(error, @"missing depth images for geometric PatchMatch initialize-score");
			return false;
		}
	} else {
		zeroDepthImages.assign(targetImageFloats, 0.f);
		depthImages = zeroDepthImages.data();
		depthImageFloats = targetImageFloats;
		depthImageOffsets = targetImageOffsets;
	}
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelInitializeScore", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			SetError(error, @"failed to create Metal command queue");
			return false;
		}
		id<MTLBuffer> imageRefBuffer = [device newBufferWithBytes:imageRef length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetImagesBuffer = [device newBufferWithBytes:targetImages length:sizeof(float)*targetImageFloats options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetOffsetsBuffer = [device newBufferWithBytes:targetImageOffsets length:sizeof(uint32_t)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> planesBuffer = [device newBufferWithBytes:planes length:sizeof(Point4)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> costsBuffer = [device newBufferWithBytes:costs length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> selectedViewsBuffer = [device newBufferWithBytes:selectedViews length:sizeof(uint32_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> refCameraBuffer = [device newBufferWithBytes:&refCamera length:sizeof(refCamera) options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetCamerasBuffer = [device newBufferWithBytes:targetCameras length:sizeof(Camera)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> numTargetsBuffer = [device newBufferWithBytes:&numTargets length:sizeof(numTargets) options:MTLResourceStorageModeShared];
		id<MTLBuffer> initTopKBuffer = [device newBufferWithBytes:&initTopK length:sizeof(initTopK) options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthMinBuffer = [device newBufferWithBytes:&depthMin length:sizeof(depthMin) options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthMaxBuffer = [device newBufferWithBytes:&depthMax length:sizeof(depthMax) options:MTLResourceStorageModeShared];
		id<MTLBuffer> lowDepthsBuffer = [device newBufferWithBytes:lowDepths length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthImagesBuffer = [device newBufferWithBytes:depthImages length:sizeof(float)*depthImageFloats options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthOffsetsBuffer = [device newBufferWithBytes:depthImageOffsets length:sizeof(uint32_t)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> useGeomBuffer = [device newBufferWithBytes:&useGeometricConsistency length:sizeof(useGeometricConsistency) options:MTLResourceStorageModeShared];
		if (imageRefBuffer == nil || targetImagesBuffer == nil || targetOffsetsBuffer == nil ||
			planesBuffer == nil || costsBuffer == nil || selectedViewsBuffer == nil ||
			refCameraBuffer == nil || targetCamerasBuffer == nil || widthBuffer == nil || heightBuffer == nil ||
			numTargetsBuffer == nil || initTopKBuffer == nil || depthMinBuffer == nil || depthMaxBuffer == nil ||
			lowDepthsBuffer == nil || depthImagesBuffer == nil || depthOffsetsBuffer == nil || useGeomBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelInitializeScore");
			return false;
		}
		id<MTLBuffer> buffers[] = {
			imageRefBuffer, targetImagesBuffer, targetOffsetsBuffer,
			planesBuffer, costsBuffer, selectedViewsBuffer,
			refCameraBuffer, targetCamerasBuffer,
			widthBuffer, heightBuffer, numTargetsBuffer, initTopKBuffer,
			depthMinBuffer, depthMaxBuffer, lowDepthsBuffer,
			depthImagesBuffer, depthOffsetsBuffer, useGeomBuffer
		};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 18, "kernelInitializeScore command buffer failed", error))
			return false;
		std::memcpy(planes, [planesBuffer contents], sizeof(Point4)*area);
		std::memcpy(costs, [costsBuffer contents], sizeof(float)*area);
		std::memcpy(selectedViews, [selectedViewsBuffer contents], sizeof(uint32_t)*area);
		return true;
	}
}

bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax,
	std::string* error)
{
	return LaunchPropagateScore(
		imageRef, targetImages, targetImageFloats, targetImageOffsets,
		planes, costs, selectedViews,
		refCamera, targetCameras,
		width, height, numTargets, iteration, redPass,
		depthMin, depthMax, nullptr, error);
}

bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax, const float* lowDepths,
	std::string* error)
{
	return LaunchPropagateScore(
		imageRef, targetImages, targetImageFloats, targetImageOffsets,
		planes, costs, selectedViews,
		refCamera, targetCameras,
		width, height, numTargets, iteration, redPass,
		depthMin, depthMax, lowDepths,
		nullptr, 0, nullptr, false, error);
}

bool LaunchPropagateScore(
	const float* imageRef,
	const float* targetImages, uint32_t targetImageFloats, const uint32_t* targetImageOffsets,
	Point4* planes, float* costs, uint32_t* selectedViews,
	const Camera& refCamera, const Camera* targetCameras,
	uint32_t width, uint32_t height, uint32_t numTargets, uint32_t iteration, bool redPass,
	float depthMin, float depthMax, const float* lowDepths,
	const float* depthImages, uint32_t depthImageFloats, const uint32_t* depthImageOffsets,
	bool geometricConsistency,
	std::string* error)
{
	const size_t area((size_t)width * (size_t)height);
	if (area == 0)
		return true;
	std::vector<float> zeroLowDepths;
	lowDepths = ResolveLowDepths(lowDepths, area, zeroLowDepths);
	if (numTargets == 0 || numTargets > 32) {
		SetError(error, @"invalid PatchMatch propagate-score view count");
		return false;
	}
	if (targetImageFloats == 0 || depthMax <= depthMin) {
		SetError(error, @"invalid PatchMatch propagate-score inputs");
		return false;
	}
	std::vector<float> zeroDepthImages;
	const uint32_t useGeometricConsistency(geometricConsistency ? 1u : 0u);
	if (geometricConsistency) {
		if (depthImages == nullptr || depthImageOffsets == nullptr || depthImageFloats == 0) {
			SetError(error, @"missing depth images for geometric PatchMatch propagate-score");
			return false;
		}
	} else {
		zeroDepthImages.assign(targetImageFloats, 0.f);
		depthImages = zeroDepthImages.data();
		depthImageFloats = targetImageFloats;
		depthImageOffsets = targetImageOffsets;
	}
	const uint32_t redPassValue(redPass ? 1u : 0u);
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelPropagateScore", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			SetError(error, @"failed to create Metal command queue");
			return false;
		}
		id<MTLBuffer> imageRefBuffer = [device newBufferWithBytes:imageRef length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetImagesBuffer = [device newBufferWithBytes:targetImages length:sizeof(float)*targetImageFloats options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetOffsetsBuffer = [device newBufferWithBytes:targetImageOffsets length:sizeof(uint32_t)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> planesBuffer = [device newBufferWithBytes:planes length:sizeof(Point4)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> costsBuffer = [device newBufferWithBytes:costs length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> selectedViewsBuffer = [device newBufferWithBytes:selectedViews length:sizeof(uint32_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> refCameraBuffer = [device newBufferWithBytes:&refCamera length:sizeof(refCamera) options:MTLResourceStorageModeShared];
		id<MTLBuffer> targetCamerasBuffer = [device newBufferWithBytes:targetCameras length:sizeof(Camera)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> numTargetsBuffer = [device newBufferWithBytes:&numTargets length:sizeof(numTargets) options:MTLResourceStorageModeShared];
		id<MTLBuffer> iterationBuffer = [device newBufferWithBytes:&iteration length:sizeof(iteration) options:MTLResourceStorageModeShared];
		id<MTLBuffer> redPassBuffer = [device newBufferWithBytes:&redPassValue length:sizeof(redPassValue) options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthMinBuffer = [device newBufferWithBytes:&depthMin length:sizeof(depthMin) options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthMaxBuffer = [device newBufferWithBytes:&depthMax length:sizeof(depthMax) options:MTLResourceStorageModeShared];
		id<MTLBuffer> lowDepthsBuffer = [device newBufferWithBytes:lowDepths length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthImagesBuffer = [device newBufferWithBytes:depthImages length:sizeof(float)*depthImageFloats options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthOffsetsBuffer = [device newBufferWithBytes:depthImageOffsets length:sizeof(uint32_t)*numTargets options:MTLResourceStorageModeShared];
		id<MTLBuffer> useGeomBuffer = [device newBufferWithBytes:&useGeometricConsistency length:sizeof(useGeometricConsistency) options:MTLResourceStorageModeShared];
		if (imageRefBuffer == nil || targetImagesBuffer == nil || targetOffsetsBuffer == nil ||
			planesBuffer == nil || costsBuffer == nil || selectedViewsBuffer == nil ||
			refCameraBuffer == nil || targetCamerasBuffer == nil || widthBuffer == nil || heightBuffer == nil ||
			numTargetsBuffer == nil || iterationBuffer == nil || redPassBuffer == nil ||
			depthMinBuffer == nil || depthMaxBuffer == nil || lowDepthsBuffer == nil ||
			depthImagesBuffer == nil || depthOffsetsBuffer == nil || useGeomBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelPropagateScore");
			return false;
		}
		id<MTLBuffer> buffers[] = {
			imageRefBuffer, targetImagesBuffer, targetOffsetsBuffer,
			planesBuffer, costsBuffer, selectedViewsBuffer,
			refCameraBuffer, targetCamerasBuffer,
			widthBuffer, heightBuffer, numTargetsBuffer, iterationBuffer, redPassBuffer,
			depthMinBuffer, depthMaxBuffer, lowDepthsBuffer,
			depthImagesBuffer, depthOffsetsBuffer, useGeomBuffer
		};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 19, "kernelPropagateScore command buffer failed", error))
			return false;
		std::memcpy(planes, [planesBuffer contents], sizeof(Point4)*area);
		std::memcpy(costs, [costsBuffer contents], sizeof(float)*area);
		std::memcpy(selectedViews, [selectedViewsBuffer contents], sizeof(uint32_t)*area);
		return true;
	}
}

bool LaunchFilterPlanes(
	Point4* planes, float* costs, uint32_t* selectedViews,
	uint32_t width, uint32_t height, float thresholdKeepCost,
	std::string* error)
{
	const size_t area((size_t)width * (size_t)height);
	if (area == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelFilterPlanes", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			SetError(error, @"failed to create Metal command queue");
			return false;
		}
		id<MTLBuffer> planesBuffer = [device newBufferWithBytes:planes length:sizeof(Point4)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> costsBuffer = [device newBufferWithBytes:costs length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> viewsBuffer = [device newBufferWithBytes:selectedViews length:sizeof(uint32_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> thresholdBuffer = [device newBufferWithBytes:&thresholdKeepCost length:sizeof(thresholdKeepCost) options:MTLResourceStorageModeShared];
		if (planesBuffer == nil || costsBuffer == nil || viewsBuffer == nil ||
			widthBuffer == nil || heightBuffer == nil || thresholdBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelFilterPlanes");
			return false;
		}
		id<MTLBuffer> buffers[] = {planesBuffer, costsBuffer, viewsBuffer, widthBuffer, heightBuffer, thresholdBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 6, "kernelFilterPlanes command buffer failed", error))
			return false;
		std::memcpy(planes, [planesBuffer contents], sizeof(Point4)*area);
		std::memcpy(costs, [costsBuffer contents], sizeof(float)*area);
		std::memcpy(selectedViews, [viewsBuffer contents], sizeof(uint32_t)*area);
		return true;
	}
}

bool RunPatchMatchScorePlaneSmoke(std::string* error)
{
	constexpr uint32_t width = 16;
	constexpr uint32_t height = 16;
	std::vector<float> image(width*height);
	for (uint32_t y = 0; y < height; ++y)
		for (uint32_t x = 0; x < width; ++x)
			image[(size_t)y*width + x] = 0.01f + 0.003f*(float)x + 0.005f*(float)y + 0.0002f*(float)(x*y);
	std::vector<Point4> planes(width*height, {0.f, 0.f, 1.f, 2.f});
	std::vector<float> costs(width*height, 9.f);
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {(int32_t)width, (int32_t)height};
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costs.data(), camera, camera, width, height, error))
		return false;
	for (uint32_t idx = 0; idx < width*height; ++idx) {
		if (std::isfinite(costs[idx]) && costs[idx] <= 1e-3f)
			continue;
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "PatchMatch score-plane smoke mismatch at %u: cost %.8f", idx, costs[idx]);
			*error = message;
		}
		return false;
	}
	return true;
}

bool RunPatchMatchLowDepthPriorSmoke(std::string* error)
{
	constexpr uint32_t width = 24;
	constexpr uint32_t height = 24;
	constexpr uint32_t area = width * height;
	constexpr uint32_t correctX = 11;
	constexpr uint32_t correctY = 12;
	constexpr uint32_t wrongX = 12;
	constexpr uint32_t wrongY = 12;
	const size_t correctIdx((size_t)correctY*width + correctX);
	const size_t wrongIdx((size_t)wrongY*width + wrongX);
	std::vector<float> image(area);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			image[(size_t)y*width + x] = 0.5f +
				0.002f * std::sin(0.73f*(float)x + 0.19f*(float)y) +
				0.001f * std::cos(0.41f*(float)x - 0.37f*(float)y);
		}
	}
	std::vector<Point4> planes(area, {0.f, 0.f, 1.f, 2.f});
	planes[wrongIdx].w = 3.f;
	std::vector<float> lowDepths(area, 2.f);
	std::vector<float> costsNoPrior(area, 9.f);
	std::vector<float> costsWithPrior(area, 9.f);
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {(int32_t)width, (int32_t)height};
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costsNoPrior.data(), camera, camera, width, height, error))
		return false;
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costsWithPrior.data(), camera, camera, width, height, lowDepths.data(), error))
		return false;
	const float noPriorGap(std::fabs(costsNoPrior[wrongIdx] - costsNoPrior[correctIdx]));
	const float priorGap(costsWithPrior[wrongIdx] - costsWithPrior[correctIdx]);
	if (std::isfinite(costsNoPrior[correctIdx]) && std::isfinite(costsNoPrior[wrongIdx]) &&
		std::isfinite(costsWithPrior[correctIdx]) && std::isfinite(costsWithPrior[wrongIdx]) &&
		noPriorGap <= 1e-3f && costsWithPrior[correctIdx] <= 1e-3f && priorGap >= 0.05f)
	{
		return true;
	}
	if (error != nullptr) {
		char message[224];
		std::snprintf(message, sizeof(message),
			"PatchMatch low-depth prior smoke mismatch: no-prior %.8f/%.8f prior %.8f/%.8f",
			costsNoPrior[correctIdx], costsNoPrior[wrongIdx],
			costsWithPrior[correctIdx], costsWithPrior[wrongIdx]);
		*error = message;
	}
	return false;
}

bool RunPatchMatchGeometricConsistencySmoke(std::string* error)
{
	constexpr uint32_t width = 64;
	constexpr uint32_t height = 48;
	constexpr uint32_t area = width * height;
	constexpr uint32_t centerX = 32;
	constexpr uint32_t centerY = 24;
	constexpr float depth = 4.f;
	constexpr float badDepth = 6.f;
	const size_t centerIdx((size_t)centerY*width + centerX);
	std::vector<float> image(area);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			image[(size_t)y*width + x] = 0.5f +
				0.12f * std::sin(0.37f*(float)x + 0.13f*(float)y) +
				0.08f * std::cos(0.19f*(float)x - 0.23f*(float)y);
		}
	}
	std::vector<Point4> planes(area, {0.f, 0.f, 1.f, depth});
	std::vector<float> depthCorrect(area, depth);
	std::vector<float> depthBad(area, badDepth);
	std::vector<float> costsNoGeom(area, 9.f);
	std::vector<float> costsGeomCorrect(area, 9.f);
	std::vector<float> costsGeomBad(area, 9.f);
	Camera refCamera = {};
	refCamera.model.f = {20.f, 20.f};
	refCamera.model.p = {32.f, 24.f};
	refCamera.pose.R.m[0] = 1.f;
	refCamera.pose.R.m[4] = 1.f;
	refCamera.pose.R.m[8] = 1.f;
	refCamera.pose.C = {0.f, 0.f, 0.f};
	refCamera.size = {(int32_t)width, (int32_t)height};
	Camera targetCamera = refCamera;
	targetCamera.pose.C = {-1.f, 0.f, 0.f};
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costsNoGeom.data(),
			refCamera, targetCamera, width, height, nullptr, nullptr, false, error))
		return false;
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costsGeomCorrect.data(),
			refCamera, targetCamera, width, height, nullptr, depthCorrect.data(), true, error))
		return false;
	if (!LaunchScorePlanePair(image.data(), image.data(), planes.data(), costsGeomBad.data(),
			refCamera, targetCamera, width, height, nullptr, depthBad.data(), true, error))
		return false;
	const float correctDelta(std::fabs(costsGeomCorrect[centerIdx] - costsNoGeom[centerIdx]));
	const float badPenalty(costsGeomBad[centerIdx] - costsGeomCorrect[centerIdx]);
	if (std::isfinite(costsNoGeom[centerIdx]) &&
		std::isfinite(costsGeomCorrect[centerIdx]) &&
		std::isfinite(costsGeomBad[centerIdx]) &&
		correctDelta <= 1e-3f && badPenalty >= 0.1f)
	{
		return true;
	}
	if (error != nullptr) {
		char message[224];
		std::snprintf(message, sizeof(message),
			"PatchMatch geometric smoke mismatch: no %.8f correct %.8f bad %.8f",
			costsNoGeom[centerIdx], costsGeomCorrect[centerIdx], costsGeomBad[centerIdx]);
		*error = message;
	}
	return false;
}

bool RunPatchMatchInitializeScoreSmoke(std::string* error)
{
	constexpr uint32_t width = 16;
	constexpr uint32_t height = 16;
	constexpr uint32_t area = width * height;
	std::vector<float> image(area);
	for (uint32_t y = 0; y < height; ++y)
		for (uint32_t x = 0; x < width; ++x)
			image[(size_t)y*width + x] = 0.01f + 0.003f*(float)x + 0.005f*(float)y + 0.0002f*(float)(x*y);
	std::vector<float> targets(area*2u);
	std::memcpy(targets.data(), image.data(), sizeof(float)*area);
	for (uint32_t i = 0; i < area; ++i)
		targets[area + i] = 1.f - image[i];
	const uint32_t offsets[] = {0u, area};
	std::vector<Point4> planes(area, {0.f, 0.f, 1.f, 2.f});
	std::vector<float> costs(area, 9.f);
	std::vector<uint32_t> selectedViews(area, 0u);
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {(int32_t)width, (int32_t)height};
	const Camera targetCameras[] = {camera, camera};
	if (!LaunchInitializeScore(
			image.data(), targets.data(), (uint32_t)targets.size(), offsets,
			planes.data(), costs.data(), selectedViews.data(),
			camera, targetCameras, width, height, 2, 1, 1.f, 4.f, error))
		return false;
	for (uint32_t idx = 0; idx < area; ++idx) {
		if (std::isfinite(costs[idx]) && costs[idx] <= 1e-3f && selectedViews[idx] == 1u &&
			planes[idx].w > 0.f)
		{
			continue;
		}
		if (error != nullptr) {
			char message[192];
			std::snprintf(message, sizeof(message),
				"PatchMatch initialize-score smoke mismatch at %u: cost %.8f views %u depth %.6f",
				idx, costs[idx], selectedViews[idx], planes[idx].w);
			*error = message;
		}
		return false;
	}
	return true;
}

bool RunPatchMatchPropagateScoreSmoke(std::string* error)
{
	constexpr uint32_t width = 16;
	constexpr uint32_t height = 16;
	constexpr uint32_t area = width * height;
	std::vector<float> image(area);
	for (uint32_t y = 0; y < height; ++y)
		for (uint32_t x = 0; x < width; ++x)
			image[(size_t)y*width + x] = 0.01f + 0.003f*(float)x + 0.005f*(float)y + 0.0002f*(float)(x*y);
	std::vector<float> targets(area*2u);
	std::memcpy(targets.data(), image.data(), sizeof(float)*area);
	for (uint32_t i = 0; i < area; ++i)
		targets[area + i] = 1.f - image[i];
	const uint32_t offsets[] = {0u, area};
	std::vector<Point4> planes(area, {0.f, 0.f, 0.f, 0.f});
	std::vector<float> costs(area, 9.f);
	std::vector<uint32_t> selectedViews(area, 0u);
	constexpr uint32_t centerX = 8;
	constexpr uint32_t centerY = 8;
	constexpr uint32_t neighborX = 8;
	constexpr uint32_t neighborY = 7;
	const size_t centerIdx((size_t)centerY*width + centerX);
	const size_t neighborIdx((size_t)neighborY*width + neighborX);
	planes[neighborIdx] = {0.f, 0.f, 1.f, 2.f};
	costs[neighborIdx] = 0.01f;
	selectedViews[neighborIdx] = 1u;
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {(int32_t)width, (int32_t)height};
	const Camera targetCameras[] = {camera, camera};
	if (!LaunchPropagateScore(
			image.data(), targets.data(), (uint32_t)targets.size(), offsets,
			planes.data(), costs.data(), selectedViews.data(),
			camera, targetCameras, width, height, 2, 0, false, 1.f, 4.f, error))
		return false;
	if (std::fabs(planes[centerIdx].x) <= 1e-6f &&
		std::fabs(planes[centerIdx].y) <= 1e-6f &&
		std::fabs(planes[centerIdx].z - 1.f) <= 1e-6f &&
		std::fabs(planes[centerIdx].w - 2.f) <= 1e-6f &&
		std::isfinite(costs[centerIdx]) && costs[centerIdx] <= 0.2f &&
		(selectedViews[centerIdx] & 1u) != 0u)
	{
		return true;
	}
	if (error != nullptr) {
		char message[192];
		std::snprintf(message, sizeof(message),
			"PatchMatch propagate-score smoke mismatch: plane %.6f %.6f %.6f %.6f cost %.8f views %u",
			planes[centerIdx].x, planes[centerIdx].y, planes[centerIdx].z, planes[centerIdx].w,
			costs[centerIdx], selectedViews[centerIdx]);
		*error = message;
	}
	return false;
}

bool RunPatchMatchRefineScoreSmoke(std::string* error)
{
	constexpr uint32_t width = 96;
	constexpr uint32_t height = 32;
	constexpr uint32_t area = width * height;
	constexpr uint32_t centerX = 35;
	constexpr uint32_t centerY = 21;
	constexpr uint32_t iteration = 4;
	constexpr float currentDepth = 2.f;
	constexpr float baseline = 96.f;
	const size_t centerIdx((size_t)centerY*width + centerX);
	const uint32_t refineSeed((uint32_t)centerIdx * 67u + iteration * 131u + 19u);
	const float expectedDepth(1.99f + 0.02f * HashFloatHost(refineSeed));
	const float expectedShift(baseline / expectedDepth);
	std::vector<float> image(area);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			image[(size_t)y*width + x] = 0.5f +
				0.22f * std::sin(0.73f*(float)x + 0.19f*(float)y) +
				0.18f * std::cos(0.41f*(float)x - 0.37f*(float)y) +
				0.08f * std::sin(0.11f*(float)(x*y));
		}
	}
	std::vector<float> target(area);
	for (uint32_t y = 0; y < height; ++y)
		for (uint32_t x = 0; x < width; ++x)
			target[(size_t)y*width + x] = SampleImageLinearHost(image, width, height, (float)x - expectedShift, (float)y);
	const uint32_t offsets[] = {0u};
	std::vector<Point4> planes(area, {0.f, 0.f, 0.f, 0.f});
	std::vector<float> costs(area, 9.f);
	std::vector<uint32_t> selectedViews(area, 0u);
	planes[centerIdx] = {0.f, 0.f, 1.f, currentDepth};
	selectedViews[centerIdx] = 1u;
	Camera refCamera = {};
	refCamera.model.f = {1.f, 1.f};
	refCamera.model.p = {0.f, 0.f};
	refCamera.pose.R.m[0] = 1.f;
	refCamera.pose.R.m[4] = 1.f;
	refCamera.pose.R.m[8] = 1.f;
	refCamera.pose.C = {0.f, 0.f, 0.f};
	refCamera.size = {(int32_t)width, (int32_t)height};
	Camera targetCamera = refCamera;
	targetCamera.pose.C = {-baseline, 0.f, 0.f};
	if (!LaunchPropagateScore(
			image.data(), target.data(), (uint32_t)target.size(), offsets,
			planes.data(), costs.data(), selectedViews.data(),
			refCamera, &targetCamera, width, height, 1, iteration, false, 1.f, 4.f, error))
		return false;
	if (std::fabs(planes[centerIdx].w - expectedDepth) <= 2e-4f &&
		std::isfinite(costs[centerIdx]) && costs[centerIdx] <= 0.2f &&
		selectedViews[centerIdx] == 1u)
	{
		return true;
	}
	if (error != nullptr) {
		char message[224];
		std::snprintf(message, sizeof(message),
			"PatchMatch refine-score smoke mismatch: depth %.8f expected %.8f cost %.8f views %u",
			planes[centerIdx].w, expectedDepth, costs[centerIdx], selectedViews[centerIdx]);
		*error = message;
	}
	return false;
}

bool RunPatchMatchFilterPlanesSmoke(std::string* error)
{
	constexpr uint32_t width = 4;
	constexpr uint32_t height = 2;
	constexpr float threshold = 0.8f;
	std::vector<Point4> planes = {
		{0.f, 0.f, 1.f, 1.f},
		{0.f, 0.f, 1.f, 0.f},
		{0.f, 0.f, 1.f, 2.f},
		{0.f, 0.f, 1.f, 3.f},
		{0.f, 0.f, 1.f, 4.f},
		{0.f, 0.f, 1.f,-1.f},
		{0.f, 0.f, 1.f, 5.f},
		{0.f, 0.f, 1.f, 6.f},
	};
	std::vector<float> costs = {0.2f, 0.1f, 0.9f, threshold, 0.799f, 0.1f, 1.2f, 0.0f};
	std::vector<uint32_t> selectedViews = {1u, 2u, 4u, 8u, 16u, 32u, 64u, 128u};
	if (!LaunchFilterPlanes(planes.data(), costs.data(), selectedViews.data(), width, height, threshold, error))
		return false;
	const bool keep[] = {true, false, false, false, true, false, false, true};
	for (uint32_t i = 0; i < width*height; ++i) {
		if (keep[i]) {
			if (planes[i].w > 0.f && selectedViews[i] != 0u)
				continue;
		} else if (planes[i].x == 0.f && planes[i].y == 0.f && planes[i].z == 0.f && planes[i].w == 0.f && costs[i] == 0.f && selectedViews[i] == 0u) {
			continue;
		}
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "PatchMatch filter smoke mismatch at %u: depth %.6f cost %.6f views %u",
				i, planes[i].w, costs[i], selectedViews[i]);
			*error = message;
		}
		return false;
	}
	return true;
}

static Image32F MakePatchMatchHostSmokeImage(int width, int height, float phase)
{
	Image32F image(height, width);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			image(y, x) =
				0.45f +
				0.16f * std::sin(0.21f*(float)x + 0.17f*(float)y + phase) +
				0.12f * std::cos(0.09f*(float)(x*y) + 0.31f*(float)x - phase);
		}
	}
	return image;
}

static bool HasValidPatchMatchHostPixel(const DepthData& depthData)
{
	if (depthData.depthMap.empty() || depthData.normalMap.empty() ||
		depthData.confMap.empty() || depthData.viewsMap.empty())
	{
		return false;
	}
	for (int y = 0; y < depthData.depthMap.rows; ++y) {
		for (int x = 0; x < depthData.depthMap.cols; ++x) {
			const Depth depth(depthData.depthMap(y, x));
			const Normal& normal(depthData.normalMap(y, x));
			const float confidence(depthData.confMap(y, x));
			const ViewsID& views(depthData.viewsMap(y, x));
			if (depth > 0.f && std::isfinite(depth) &&
				normal.dot(normal) > 0.5f &&
				confidence > 0.f && confidence <= 1.f &&
				views[0] != 255)
			{
				return true;
			}
		}
	}
	return false;
}

bool RunPatchMatchHostSmoke(std::string* error)
{
	constexpr int width = 64;
	constexpr int height = 48;
	constexpr float depth = 2.f;

	Image imageRef;
	imageRef.ID = 0;
	imageRef.width = width;
	imageRef.height = height;
	imageRef.poseID = 0;
	imageRef.camera = ::MVS::Camera(
		::SEACAVE::Matrix3x3::IDENTITY * REAL(1),
		::SEACAVE::Matrix3x3::IDENTITY,
		::SEACAVE::Point3(0, 0, 0));
	imageRef.camera.K = ::MVS::Camera::ComposeK<REAL, int>(REAL(42), REAL(42), width, height);
	imageRef.camera.ComposeP();

	Image imageTrg(imageRef);
	imageTrg.ID = 1;
	imageTrg.poseID = 1;
	imageTrg.camera.C = ::SEACAVE::Point3(-0.2, 0, 0);
	imageTrg.camera.ComposeP();

	DepthData depthData;
	depthData.dMin = 1.f;
	depthData.dMax = 4.f;
	depthData.size = cv::Size(width, height);

	depthData.images.AddEmpty();
	depthData.images.AddEmpty();
	DepthData::ViewData& viewRef(depthData.images[0]);
	DepthData::ViewData& viewTrg(depthData.images[1]);
	viewRef.scale = 1.f;
	viewRef.camera = imageRef.camera;
	viewRef.image = MakePatchMatchHostSmokeImage(width, height, 0.f);
	viewRef.pImageData = &imageRef;
	viewTrg.scale = 1.f;
	viewTrg.camera = imageTrg.camera;
	viewTrg.image = viewRef.image;
	viewTrg.pImageData = &imageTrg;

	viewRef.Init(viewRef.camera);
	viewTrg.Init(viewRef.camera);

	depthData.depthMap.create(height, width);
	depthData.normalMap.create(height, width);
	for (int y = 0; y < height; ++y) {
		for (int x = 0; x < width; ++x) {
			depthData.depthMap(y, x) = depth;
			depthData.normalMap(y, x) = Normal(0.f, 0.f, 1.f);
		}
	}

	const unsigned savedSubResolutionLevels(OPTDENSE::nSubResolutionLevels);
	const unsigned savedEstimationIters(OPTDENSE::nEstimationIters);
	const unsigned savedGeometricIters(OPTDENSE::nEstimationGeometricIters);
	const float savedThresholdKeep(OPTDENSE::fNCCThresholdKeep);
	OPTDENSE::nSubResolutionLevels = 2u;
	OPTDENSE::nEstimationIters = 1u;
	OPTDENSE::nEstimationGeometricIters = 0u;
	OPTDENSE::fNCCThresholdKeep = 0.95f;

	PatchMatch patchMatch;
	patchMatch.Init(false);
	const bool ok(patchMatch.EstimateDepthMap(depthData) && HasValidPatchMatchHostPixel(depthData));

	OPTDENSE::nSubResolutionLevels = savedSubResolutionLevels;
	OPTDENSE::nEstimationIters = savedEstimationIters;
	OPTDENSE::nEstimationGeometricIters = savedGeometricIters;
	OPTDENSE::fNCCThresholdKeep = savedThresholdKeep;

	if (ok)
		return true;
	if (error != nullptr)
		*error = "PatchMatch host smoke did not produce a valid full-resolution depth/confidence/views map";
	return false;
}

static bool EstimateDepthMapLevel(
	DepthData& depthData,
	bool geometricConsistency,
	bool lowResProcessed,
	uint32_t numIterations,
	float thresholdKeepCost,
	bool finalLevel,
	std::string* error)
{
	if (depthData.images.size() < 2 || depthData.images.size() > 33) {
		if (error != nullptr) {
			char message[128];
			std::snprintf(message, sizeof(message), "unsupported PatchMatch Metal target view count %u",
				depthData.images.size() > 0 ? depthData.images.size()-1 : 0);
			*error = message;
		}
		return false;
	}
	if (depthData.depthMap.empty() || depthData.normalMap.empty() || depthData.images.front().image.empty()) {
		if (error != nullptr)
			*error = "missing initialized PatchMatch Metal depth, normal, or reference image data";
		return false;
	}
	const Image32F& imageRef(depthData.images.front().image);
	const cv::Size size(imageRef.size());
	if (depthData.depthMap.size() != size || depthData.normalMap.size() != size) {
		if (error != nullptr)
			*error = "PatchMatch Metal input map sizes do not match the reference image";
		return false;
	}
	const float depthMin(depthData.dMin);
	const float depthMax(depthData.dMax);
	if (!(depthMax > depthMin)) {
		if (error != nullptr)
			*error = "invalid PatchMatch Metal depth range";
		return false;
	}

	const uint32_t width((uint32_t)size.width);
	const uint32_t height((uint32_t)size.height);
	const uint32_t numTargets((uint32_t)depthData.images.size() - 1u);
	const uint32_t initTopK(std::min<uint32_t>(3u, numTargets));

	std::vector<float> refImage;
	if (!PackImage(imageRef, refImage, error))
		return false;
	std::vector<float> targetImages;
	std::vector<uint32_t> targetImageOffsets(numTargets);
	std::vector<Camera> targetCameras(numTargets);
	std::vector<float> depthImages;
	std::vector<uint32_t> depthImageOffsets(numTargets);
	for (uint32_t i = 0; i < numTargets; ++i) {
		const DepthData::ViewData& view(depthData.images[i + 1u]);
		if (view.image.empty()) {
			if (error != nullptr)
				*error = "missing PatchMatch Metal target image data";
			return false;
		}
		if (!AppendImage(view.image, targetImages, targetImageOffsets[i], error))
			return false;
		targetCameras[i] = MakeMetalCamera(view.camera, view.image.size());
		if (geometricConsistency &&
			!AppendDepthImage(view.depthMap, view.image.size(), depthImages, depthImageOffsets[i], error))
		{
			return false;
		}
	}

	std::vector<Point4> planes;
	PackDepthNormalPlanes(depthData, planes);
	const size_t area(planes.size());
	std::vector<float> costs(area, 9.f);
	std::vector<uint32_t> selectedViews(area, 0u);
	std::vector<float> lowDepths;
	const float* lowDepthsPtr(nullptr);
	if (lowResProcessed) {
		if (!PackDepthMap(depthData.depthMap, lowDepths, error))
			return false;
		lowDepthsPtr = lowDepths.data();
	}

	const Camera refCamera(MakeMetalCamera(depthData.images.front().camera, size));
	const float* depthImagesPtr(geometricConsistency ? depthImages.data() : nullptr);
	const uint32_t depthImageFloats(geometricConsistency ? (uint32_t)depthImages.size() : 0u);
	const uint32_t* depthImageOffsetsPtr(geometricConsistency ? depthImageOffsets.data() : nullptr);
	if (!LaunchInitializeScore(
			refImage.data(),
			targetImages.data(), (uint32_t)targetImages.size(), targetImageOffsets.data(),
			planes.data(), costs.data(), selectedViews.data(),
			refCamera, targetCameras.data(),
			width, height, numTargets, initTopK,
			depthMin, depthMax, lowDepthsPtr,
			depthImagesPtr, depthImageFloats, depthImageOffsetsPtr,
			geometricConsistency, error))
	{
		return false;
	}
	for (uint32_t iter = 0; iter < numIterations; ++iter) {
		if (!LaunchPropagateScore(
				refImage.data(),
				targetImages.data(), (uint32_t)targetImages.size(), targetImageOffsets.data(),
				planes.data(), costs.data(), selectedViews.data(),
				refCamera, targetCameras.data(),
				width, height, numTargets, iter, false,
				depthMin, depthMax, lowDepthsPtr,
				depthImagesPtr, depthImageFloats, depthImageOffsetsPtr,
				geometricConsistency, error))
		{
			return false;
		}
		if (!LaunchPropagateScore(
				refImage.data(),
				targetImages.data(), (uint32_t)targetImages.size(), targetImageOffsets.data(),
				planes.data(), costs.data(), selectedViews.data(),
				refCamera, targetCameras.data(),
				width, height, numTargets, iter, true,
				depthMin, depthMax, lowDepthsPtr,
				depthImagesPtr, depthImageFloats, depthImageOffsetsPtr,
				geometricConsistency, error))
		{
			return false;
		}
	}
	if (thresholdKeepCost > 0.f &&
		!LaunchFilterPlanes(planes.data(), costs.data(), selectedViews.data(), width, height, thresholdKeepCost, error))
	{
		return false;
	}
	UnpackDepthNormalPlanes(depthData, planes, costs, selectedViews, finalLevel);
	return true;
}

PatchMatch::PatchMatch()
	:
	bAvailable(SEACAVE::METAL::isAvailable()),
	bGeometricConsistency(false)
{
}

PatchMatch::~PatchMatch()
{
	Release();
}

void PatchMatch::Init(bool bGeomConsistency)
{
	bAvailable = SEACAVE::METAL::isAvailable();
	bGeometricConsistency = bGeomConsistency;
}

void PatchMatch::Release()
{
}

bool PatchMatch::EstimateDepthMap(DepthData& depthData)
{
	if (!bAvailable) {
		VERBOSE("Metal PatchMatch unavailable: no default Metal device");
		return false;
	}
	std::string error;
	DepthData& fullResDepthData(depthData);
	const unsigned totalScaleNumber(bGeometricConsistency ? 0u : OPTDENSE::nSubResolutionLevels);
	const uint32_t numIterations(bGeometricConsistency ? 1u : OPTDENSE::nEstimationIters);
	DepthMap lowResDepthMap;
	NormalMap lowResNormalMap;
	ViewsMap lowResViewsMap;
	for (unsigned scaleNumber = totalScaleNumber + 1u; scaleNumber-- > 0u; ) {
		const float scale(1.f / POWI(2, scaleNumber));
		DepthData currentDepthData(DepthMapsData::ScaleDepthData(fullResDepthData, scale));
		DepthData& levelDepthData(scaleNumber == 0u ? fullResDepthData : currentDepthData);
		if (levelDepthData.images.IsEmpty() || levelDepthData.images.front().image.empty()) {
			DEBUG_EXTRA("Metal PatchMatch missing level image data");
			return false;
		}
		const cv::Size size(levelDepthData.images.front().image.size());
		bool lowResProcessed(false);
		if (scaleNumber != totalScaleNumber) {
			lowResProcessed = true;
			cv::resize(lowResDepthMap, levelDepthData.depthMap, size, 0, 0, cv::INTER_NEAREST);
			cv::resize(lowResNormalMap, levelDepthData.normalMap, size, 0, 0, cv::INTER_NEAREST);
			if (!lowResViewsMap.empty())
				cv::resize(lowResViewsMap, levelDepthData.viewsMap, size, 0, 0, cv::INTER_NEAREST);
		} else {
			if (totalScaleNumber > 0u) {
				fullResDepthData.depthMap.release();
				fullResDepthData.normalMap.release();
				fullResDepthData.confMap.release();
				fullResDepthData.viewsMap.release();
			}
			if (levelDepthData.viewsMap.empty())
				levelDepthData.viewsMap.create(size);
		}
		if (scaleNumber == 0u && levelDepthData.confMap.empty())
			levelDepthData.confMap.create(size);

		float thresholdKeepCost(OPTDENSE::fNCCThresholdKeep);
		if (totalScaleNumber > 0u) {
			if (scaleNumber > 0u && scaleNumber != totalScaleNumber)
				thresholdKeepCost = 0.f;
			else if (scaleNumber == totalScaleNumber || (!bGeometricConsistency && OPTDENSE::nEstimationGeometricIters))
				thresholdKeepCost = OPTDENSE::fNCCThresholdKeep * 1.2f;
		} else if (!bGeometricConsistency && OPTDENSE::nEstimationGeometricIters) {
			thresholdKeepCost = OPTDENSE::fNCCThresholdKeep * 1.2f;
		}

		if (!EstimateDepthMapLevel(
				levelDepthData, bGeometricConsistency, lowResProcessed, numIterations,
				thresholdKeepCost, scaleNumber == 0u, &error))
		{
			DEBUG_EXTRA("Metal PatchMatch level %u failed: %s", scaleNumber, error.c_str());
			return false;
		}
		if (scaleNumber > 0u) {
			lowResDepthMap = levelDepthData.depthMap;
			lowResNormalMap = levelDepthData.normalMap;
			lowResViewsMap = levelDepthData.viewsMap;
		}
	}

	if (!depthData.depthMap.empty())
		EstimateNormalMap(depthData.images.front().camera.K, depthData.depthMap, depthData.normalMap, 4, Depth(0.03f));

	if (OPTDENSE::nIgnoreMaskLabel >= 0) {
		const DepthData::ViewData& view(depthData.GetView());
		BitMatrix mask;
		if (DepthEstimator::ImportIgnoreMask(*view.pImageData, depthData.depthMap.size(), (uint8_t)OPTDENSE::nIgnoreMaskLabel, mask))
			depthData.ApplyIgnoreMask(mask);
	}
	DEBUG_EXTRA("Depth-map for image %3u estimated using Metal PatchMatch host path: %dx%d",
		depthData.images.front().GetID(), depthData.depthMap.cols, depthData.depthMap.rows);
	return true;
}

/*----------------------------------------------------------------*/

} // namespace METAL

} // namespace MVS

#endif // _USE_METAL
