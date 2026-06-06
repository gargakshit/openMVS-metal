/*
* SceneRefineMetal.mm
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

#include "../Common/UtilMetal.h"
#include "SceneRefineMetal.h"

#ifdef _USE_METAL

#include "SceneRefineMetalLibrary.inc"
#include "SceneRefineMetalShader.inc"

@import Dispatch;
@import Foundation;
@import Metal;

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <unordered_map>
#include <vector>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

namespace MVS {

namespace METAL {

bool RunRefineMeshHostSmokeImpl(std::string* error);

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

static NSString* SceneRefineShaderSource()
{
	return [NSString stringWithUTF8String:kSceneRefineMetalShaderSource];
}

static id<MTLLibrary> CreateSceneRefineLibrary(id<MTLDevice> device, std::string* error)
{
	NSError* nsError = nil;
	dispatch_data_t libraryData = dispatch_data_create(
		kSceneRefineMetalLibraryData, kSceneRefineMetalLibrarySize,
		nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
	if (libraryData != nil) {
		id<MTLLibrary> library = [device newLibraryWithData:libraryData error:&nsError];
		if (library != nil)
			return library;
	}
	nsError = nil;
	id<MTLLibrary> library = [device newLibraryWithSource:SceneRefineShaderSource() options:nil error:&nsError];
	if (library == nil)
		SetError(error, nsError, "failed to compile SceneRefine Metal library");
	return library;
}

static id<MTLDevice> GetMetalDevice()
{
	static std::mutex mutex;
	static id<MTLDevice> device = nil;
	std::lock_guard<std::mutex> lock(mutex);
	if (device == nil)
		device = MTLCreateSystemDefaultDevice();
	return device;
}

static id<MTLCommandQueue> GetCommandQueue(id<MTLDevice> device, std::string* error)
{
	static std::mutex mutex;
	static id<MTLCommandQueue> queue = nil;
	std::lock_guard<std::mutex> lock(mutex);
	if (queue != nil)
		return queue;
	queue = [device newCommandQueue];
	if (queue == nil)
		SetError(error, @"failed to create Metal command queue");
	return queue;
}

static id<MTLComputePipelineState> CreatePipeline(id<MTLDevice> device, NSString* functionName, std::string* error)
{
	static std::mutex mutex;
	static id<MTLLibrary> library = nil;
	static std::unordered_map<std::string, id<MTLComputePipelineState>> pipelines;
	const std::string key([functionName UTF8String]);
	std::lock_guard<std::mutex> lock(mutex);
	const auto it = pipelines.find(key);
	if (it != pipelines.end())
		return it->second;

	NSError* nsError = nil;
	if (library == nil) {
		library = CreateSceneRefineLibrary(device, error);
		if (library == nil)
			return nil;
	}
	id<MTLFunction> function = [library newFunctionWithName:functionName];
	if (function == nil) {
		SetError(error, [NSString stringWithFormat:@"failed to load %@", functionName]);
		return nil;
	}
	id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&nsError];
	if (pipeline == nil)
		SetError(error, nsError, "failed to create SceneRefine Metal pipeline");
	else
		pipelines.emplace(key, pipeline);
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

static void EncodeDispatch2D(
	id<MTLComputeCommandEncoder> encoder, id<MTLComputePipelineState> pipeline,
	uint32_t width, uint32_t height,
	id<MTLBuffer> const* buffers, NSUInteger numBuffers)
{
	[encoder setComputePipelineState:pipeline];
	for (NSUInteger i = 0; i < numBuffers; ++i)
		[encoder setBuffer:buffers[i] offset:0 atIndex:i];
	const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)width, 16u);
	const NSUInteger groupHeight = std::min<NSUInteger>(
		(NSUInteger)height,
		std::max<NSUInteger>(1u, [pipeline maxTotalThreadsPerThreadgroup] / groupWidth));
	[encoder dispatchThreads:MTLSizeMake(width, height, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, groupHeight, 1)];
}

static void EncodeDispatch1D(
	id<MTLComputeCommandEncoder> encoder, id<MTLComputePipelineState> pipeline,
	uint32_t count, id<MTLBuffer> const* buffers, NSUInteger numBuffers)
{
	[encoder setComputePipelineState:pipeline];
	for (NSUInteger i = 0; i < numBuffers; ++i)
		[encoder setBuffer:buffers[i] offset:0 atIndex:i];
	const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)count, [pipeline maxTotalThreadsPerThreadgroup]);
	[encoder dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
}

struct MetalBufferSlot {
	void* buffer = nullptr;
	NSUInteger length = 0;

	MetalBufferSlot() = default;
	MetalBufferSlot(const MetalBufferSlot&) = delete;
	MetalBufferSlot& operator=(const MetalBufferSlot&) = delete;
	~MetalBufferSlot()
	{
		if (buffer != nullptr)
			CFRelease(buffer);
	}

	id<MTLBuffer> Get() const
	{
		return (__bridge id<MTLBuffer>)buffer;
	}
};

static bool EnsureBuffer(id<MTLDevice> device, MetalBufferSlot& slot, NSUInteger length, NSString* label, std::string* error)
{
	length = std::max<NSUInteger>(length, 1u);
	if (slot.buffer != nullptr && slot.length >= length)
		return true;
	if (slot.buffer != nullptr) {
		CFRelease(slot.buffer);
		slot.buffer = nullptr;
		slot.length = 0;
	}
	id<MTLBuffer> buffer = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
	if (buffer == nil) {
		SetError(error, [NSString stringWithFormat:@"failed to allocate Metal buffer %@", label]);
		return false;
	}
	slot.buffer = (__bridge_retained void*)buffer;
	slot.length = length;
	return true;
}

static bool UploadBuffer(id<MTLDevice> device, MetalBufferSlot& slot, const void* data, NSUInteger length, NSString* label, std::string* error)
{
	if (!EnsureBuffer(device, slot, length, label, error))
		return false;
	if (length > 0)
		std::memcpy([slot.Get() contents], data, length);
	return true;
}

bool LaunchComputeFaceNormal(
	const Point3* vertices, const Point3u* faces,
	Point3* normals, uint32_t numFaces,
	std::string* error)
{
	if (numFaces == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}

		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeFaceNormal", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		uint32_t numVertices(0);
		for (uint32_t i = 0; i < numFaces; ++i) {
			numVertices = std::max(numVertices, faces[i].x + 1u);
			numVertices = std::max(numVertices, faces[i].y + 1u);
			numVertices = std::max(numVertices, faces[i].z + 1u);
		}
		if (numVertices == 0) {
			SetError(error, @"face buffer does not reference any vertices");
			return false;
		}

		struct FaceNormalBufferCache {
			MetalBufferSlot vertices, faces, normals, numFaces;
		};
		static thread_local FaceNormalBufferCache cache;
		if (!UploadBuffer(device, cache.vertices, vertices, sizeof(Point3)*numVertices, @"face-normal vertices", error) ||
			!UploadBuffer(device, cache.faces, faces, sizeof(Point3u)*numFaces, @"face-normal faces", error) ||
			!EnsureBuffer(device, cache.normals, sizeof(Point3)*numFaces, @"face-normal normals", error) ||
			!UploadBuffer(device, cache.numFaces, &numFaces, sizeof(numFaces), @"face-normal face count", error))
			return false;

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:cache.vertices.Get() offset:0 atIndex:0];
		[encoder setBuffer:cache.faces.Get() offset:0 atIndex:1];
		[encoder setBuffer:cache.normals.Get() offset:0 atIndex:2];
		[encoder setBuffer:cache.numFaces.Get() offset:0 atIndex:3];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numFaces, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numFaces, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelComputeFaceNormal command buffer failed");
			return false;
		}

		std::memcpy(normals, [cache.normals.Get() contents], sizeof(Point3)*numFaces);
		return true;
	}
}

bool LaunchProjectMesh(
	const Point3* vertices, const Point3u* faces, const uint32_t* faceIDs,
	float* depthMap, uint32_t* faceMap, uint16_t* baryMap,
	const Camera& camera, uint32_t numFacesView,
	std::string* error)
{
	if (numFacesView == 0)
		return true;
	if (camera.size.x <= 0 || camera.size.y <= 0) {
		SetError(error, @"invalid camera size for kernelProjectMesh");
		return false;
	}
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}

		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelProjectMesh", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		uint32_t numFaces(0);
		uint32_t numVertices(0);
		for (uint32_t i = 0; i < numFacesView; ++i) {
			const uint32_t faceID = faceIDs[i];
			numFaces = std::max(numFaces, faceID + 1u);
			numVertices = std::max(numVertices, faces[faceID].x + 1u);
			numVertices = std::max(numVertices, faces[faceID].y + 1u);
			numVertices = std::max(numVertices, faces[faceID].z + 1u);
		}
		if (numFaces == 0 || numVertices == 0) {
			SetError(error, @"face buffer does not reference any vertices");
			return false;
		}

		const uint32_t width = (uint32_t)camera.size.x;
		const uint32_t height = (uint32_t)camera.size.y;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		struct ProjectMeshBufferCache {
			MetalBufferSlot vertices, faces, faceIDs;
			MetalBufferSlot depth, faceMap, baryMap;
			MetalBufferSlot camera, numFacesView;
		};
		static thread_local ProjectMeshBufferCache cache;
		if (!UploadBuffer(device, cache.vertices, vertices, sizeof(Point3)*numVertices, @"project vertices", error) ||
			!UploadBuffer(device, cache.faces, faces, sizeof(Point3u)*numFaces, @"project faces", error) ||
			!UploadBuffer(device, cache.faceIDs, faceIDs, sizeof(uint32_t)*numFacesView, @"project face ids", error) ||
			!UploadBuffer(device, cache.depth, depthMap, sizeof(float)*area, @"project depth map", error) ||
			!UploadBuffer(device, cache.faceMap, faceMap, sizeof(uint32_t)*area, @"project face map", error) ||
			!UploadBuffer(device, cache.baryMap, baryMap, sizeof(uint16_t)*area*3, @"project bary map", error) ||
			!UploadBuffer(device, cache.camera, &camera, sizeof(camera), @"project camera", error) ||
			!UploadBuffer(device, cache.numFacesView, &numFacesView, sizeof(numFacesView), @"project face count", error))
			return false;

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:cache.vertices.Get() offset:0 atIndex:0];
		[encoder setBuffer:cache.faces.Get() offset:0 atIndex:1];
		[encoder setBuffer:cache.faceIDs.Get() offset:0 atIndex:2];
		[encoder setBuffer:cache.depth.Get() offset:0 atIndex:3];
		[encoder setBuffer:cache.faceMap.Get() offset:0 atIndex:4];
		[encoder setBuffer:cache.baryMap.Get() offset:0 atIndex:5];
		[encoder setBuffer:cache.camera.Get() offset:0 atIndex:6];
		[encoder setBuffer:cache.numFacesView.Get() offset:0 atIndex:7];
		const NSUInteger groupWidth = std::min<NSUInteger>(
			(NSUInteger)numFacesView,
			std::max<NSUInteger>(1u, [pipeline maxTotalThreadsPerThreadgroup]));
		[encoder dispatchThreads:MTLSizeMake(numFacesView, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelProjectMesh command buffer failed");
			return false;
		}

		std::memcpy(depthMap, [cache.depth.Get() contents], sizeof(float)*area);
		std::memcpy(faceMap, [cache.faceMap.Get() contents], sizeof(uint32_t)*area);
		std::memcpy(baryMap, [cache.baryMap.Get() contents], sizeof(uint16_t)*area*3);
		return true;
	}
}

bool LaunchProjectMeshAndCrossCheck(
	const Point3* vertices, const Point3u* faces, const uint32_t* faceIDs,
	float* depthMap, uint32_t* faceMap, uint16_t* baryMap,
	const Camera& camera, uint32_t numFacesView,
	std::string* error)
{
	if (numFacesView == 0)
		return true;
	if (camera.size.x <= 0 || camera.size.y <= 0) {
		SetError(error, @"invalid camera size for fused project/cross-check");
		return false;
	}
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}

		id<MTLComputePipelineState> projectPipeline = CreatePipeline(device, @"kernelProjectMesh", error);
		id<MTLComputePipelineState> crossCheckPipeline = CreatePipeline(device, @"kernelCrossCheckProjection", error);
		if (projectPipeline == nil || crossCheckPipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		uint32_t numFaces(0);
		uint32_t numVertices(0);
		for (uint32_t i = 0; i < numFacesView; ++i) {
			const uint32_t faceID = faceIDs[i];
			numFaces = std::max(numFaces, faceID + 1u);
			numVertices = std::max(numVertices, faces[faceID].x + 1u);
			numVertices = std::max(numVertices, faces[faceID].y + 1u);
			numVertices = std::max(numVertices, faces[faceID].z + 1u);
		}
		if (numFaces == 0 || numVertices == 0) {
			SetError(error, @"face buffer does not reference any vertices");
			return false;
		}

		const uint32_t width = (uint32_t)camera.size.x;
		const uint32_t height = (uint32_t)camera.size.y;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		struct ProjectCrossCheckBufferCache {
			MetalBufferSlot vertices, faces, faceIDs;
			MetalBufferSlot depth, faceMap, baryMap;
			MetalBufferSlot camera, numFacesView, width, height;
		};
		static thread_local ProjectCrossCheckBufferCache cache;
		if (!UploadBuffer(device, cache.vertices, vertices, sizeof(Point3)*numVertices, @"project/cross vertices", error) ||
			!UploadBuffer(device, cache.faces, faces, sizeof(Point3u)*numFaces, @"project/cross faces", error) ||
			!UploadBuffer(device, cache.faceIDs, faceIDs, sizeof(uint32_t)*numFacesView, @"project/cross face ids", error) ||
			!UploadBuffer(device, cache.depth, depthMap, sizeof(float)*area, @"project/cross depth map", error) ||
			!UploadBuffer(device, cache.faceMap, faceMap, sizeof(uint32_t)*area, @"project/cross face map", error) ||
			!UploadBuffer(device, cache.baryMap, baryMap, sizeof(uint16_t)*area*3, @"project/cross bary map", error) ||
			!UploadBuffer(device, cache.camera, &camera, sizeof(camera), @"project/cross camera", error) ||
			!UploadBuffer(device, cache.numFacesView, &numFacesView, sizeof(numFacesView), @"project/cross face count", error) ||
			!UploadBuffer(device, cache.width, &width, sizeof(width), @"project/cross width", error) ||
			!UploadBuffer(device, cache.height, &height, sizeof(height), @"project/cross height", error))
			return false;

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}

		[encoder setComputePipelineState:projectPipeline];
		[encoder setBuffer:cache.vertices.Get() offset:0 atIndex:0];
		[encoder setBuffer:cache.faces.Get() offset:0 atIndex:1];
		[encoder setBuffer:cache.faceIDs.Get() offset:0 atIndex:2];
		[encoder setBuffer:cache.depth.Get() offset:0 atIndex:3];
		[encoder setBuffer:cache.faceMap.Get() offset:0 atIndex:4];
		[encoder setBuffer:cache.baryMap.Get() offset:0 atIndex:5];
		[encoder setBuffer:cache.camera.Get() offset:0 atIndex:6];
		[encoder setBuffer:cache.numFacesView.Get() offset:0 atIndex:7];
		const NSUInteger groupWidth = std::min<NSUInteger>(
			(NSUInteger)numFacesView,
			std::max<NSUInteger>(1u, [projectPipeline maxTotalThreadsPerThreadgroup]));
		[encoder dispatchThreads:MTLSizeMake(numFacesView, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];

		id<MTLBuffer> crossBuffers[] = {cache.depth.Get(), cache.faceMap.Get(), cache.width.Get(), cache.height.Get()};
		EncodeDispatch2D(encoder, crossCheckPipeline, width, height, crossBuffers, 4);

		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "fused project/cross-check command buffer failed");
			return false;
		}

		std::memcpy(depthMap, [cache.depth.Get() contents], sizeof(float)*area);
		std::memcpy(faceMap, [cache.faceMap.Get() contents], sizeof(uint32_t)*area);
		std::memcpy(baryMap, [cache.baryMap.Get() contents], sizeof(uint16_t)*area*3);
		return true;
	}
}

static bool LaunchCameraProjectSmokeKernel(
	const Camera& camera, const Point3* points,
	Point3* results, uint32_t numPoints,
	std::string* error)
{
	if (numPoints == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}

		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelCameraProjectSmoke", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		id<MTLBuffer> cameraBuffer = [device newBufferWithBytes:&camera length:sizeof(camera) options:MTLResourceStorageModeShared];
		id<MTLBuffer> pointsBuffer = [device newBufferWithBytes:points length:sizeof(Point3)*numPoints options:MTLResourceStorageModeShared];
		id<MTLBuffer> resultsBuffer = [device newBufferWithLength:sizeof(Point3)*numPoints options:MTLResourceStorageModeShared];
		id<MTLBuffer> numPointsBuffer = [device newBufferWithBytes:&numPoints length:sizeof(numPoints) options:MTLResourceStorageModeShared];
		if (cameraBuffer == nil || pointsBuffer == nil || resultsBuffer == nil || numPointsBuffer == nil) {
			SetError(error, @"failed to allocate Metal buffers for kernelCameraProjectSmoke");
			return false;
		}

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:cameraBuffer offset:0 atIndex:0];
		[encoder setBuffer:pointsBuffer offset:0 atIndex:1];
		[encoder setBuffer:resultsBuffer offset:0 atIndex:2];
		[encoder setBuffer:numPointsBuffer offset:0 atIndex:3];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numPoints, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numPoints, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelCameraProjectSmoke command buffer failed");
			return false;
		}

		std::memcpy(results, [resultsBuffer contents], sizeof(Point3)*numPoints);
		return true;
	}
}

bool LaunchCrossCheckProjection(
	float* depthMap, uint32_t* faceMap,
	uint32_t width, uint32_t height,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelCrossCheckProjection", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		struct CrossCheckBufferCache {
			MetalBufferSlot depth, faceMap, width, height;
		};
		static thread_local CrossCheckBufferCache cache;
		if (!UploadBuffer(device, cache.depth, depthMap, sizeof(float)*area, @"cross-check depth map", error) ||
			!UploadBuffer(device, cache.faceMap, faceMap, sizeof(uint32_t)*area, @"cross-check face map", error) ||
			!UploadBuffer(device, cache.width, &width, sizeof(width), @"cross-check width", error) ||
			!UploadBuffer(device, cache.height, &height, sizeof(height), @"cross-check height", error))
			return false;
		id<MTLBuffer> buffers[] = {cache.depth.Get(), cache.faceMap.Get(), cache.width.Get(), cache.height.Get()};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 4, "kernelCrossCheckProjection command buffer failed", error))
			return false;
		std::memcpy(depthMap, [cache.depth.Get() contents], sizeof(float)*area);
		std::memcpy(faceMap, [cache.faceMap.Get() contents], sizeof(uint32_t)*area);
		return true;
	}
}

bool LaunchComputeImageMean(
	const uint8_t* mask, const float* image,
	float* imageMean, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeImageMean", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBuffer = [device newBufferWithBytes:image length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> meanBuffer = [device newBufferWithLength:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> halfSizeBuffer = [device newBufferWithBytes:&halfSize length:sizeof(halfSize) options:MTLResourceStorageModeShared];
		if (maskBuffer == nil || imageBuffer == nil || meanBuffer == nil ||
			widthBuffer == nil || heightBuffer == nil || halfSizeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeImageMean");
			return false;
		}
		id<MTLBuffer> buffers[] = {maskBuffer, imageBuffer, meanBuffer, widthBuffer, heightBuffer, halfSizeBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 6, "kernelComputeImageMean command buffer failed", error))
			return false;
		std::memcpy(imageMean, [meanBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchComputeImageVar(
	const float* imageMean, const uint8_t* mask, const float* image,
	float* imageVar, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeImageVar", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		id<MTLBuffer> meanBuffer = [device newBufferWithBytes:imageMean length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBuffer = [device newBufferWithBytes:image length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> varBuffer = [device newBufferWithLength:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> halfSizeBuffer = [device newBufferWithBytes:&halfSize length:sizeof(halfSize) options:MTLResourceStorageModeShared];
		if (meanBuffer == nil || maskBuffer == nil || imageBuffer == nil || varBuffer == nil ||
			widthBuffer == nil || heightBuffer == nil || halfSizeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeImageVar");
			return false;
		}
		id<MTLBuffer> buffers[] = {meanBuffer, maskBuffer, imageBuffer, varBuffer, widthBuffer, heightBuffer, halfSizeBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 7, "kernelComputeImageVar command buffer failed", error))
			return false;
		std::memcpy(imageVar, [varBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchComputeImageCov(
	const float* imageMeanA, const float* imageMeanB,
	const uint8_t* mask, const float* imageA, const float* imageB,
	float* imageCov, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeImageCov", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		id<MTLBuffer> meanABuffer = [device newBufferWithBytes:imageMeanA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> meanBBuffer = [device newBufferWithBytes:imageMeanB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageABuffer = [device newBufferWithBytes:imageA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBBuffer = [device newBufferWithBytes:imageB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> covBuffer = [device newBufferWithLength:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> halfSizeBuffer = [device newBufferWithBytes:&halfSize length:sizeof(halfSize) options:MTLResourceStorageModeShared];
		if (meanABuffer == nil || meanBBuffer == nil || maskBuffer == nil || imageABuffer == nil ||
			imageBBuffer == nil || covBuffer == nil || widthBuffer == nil || heightBuffer == nil || halfSizeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeImageCov");
			return false;
		}
		id<MTLBuffer> buffers[] = {meanABuffer, meanBBuffer, maskBuffer, imageABuffer, imageBBuffer, covBuffer, widthBuffer, heightBuffer, halfSizeBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 9, "kernelComputeImageCov command buffer failed", error))
			return false;
		std::memcpy(imageCov, [covBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchComputeImageZNCC(
	const float* imageCov, const float* imageVarA, const float* imageVarB,
	const uint8_t* mask, float* imageZNCC,
	uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeImageZNCC", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		id<MTLBuffer> covBuffer = [device newBufferWithBytes:imageCov length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> varABuffer = [device newBufferWithBytes:imageVarA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> varBBuffer = [device newBufferWithBytes:imageVarB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> znccBuffer = [device newBufferWithLength:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> halfSizeBuffer = [device newBufferWithBytes:&halfSize length:sizeof(halfSize) options:MTLResourceStorageModeShared];
		if (covBuffer == nil || varABuffer == nil || varBBuffer == nil || maskBuffer == nil ||
			znccBuffer == nil || widthBuffer == nil || heightBuffer == nil || halfSizeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeImageZNCC");
			return false;
		}
		id<MTLBuffer> buffers[] = {covBuffer, varABuffer, varBBuffer, maskBuffer, znccBuffer, widthBuffer, heightBuffer, halfSizeBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 8, "kernelComputeImageZNCC command buffer failed", error))
			return false;
		std::memcpy(imageZNCC, [znccBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchComputeImageDZNCC(
	const float* meanA, const float* meanB,
	const float* varA, const float* varB, const float* zncc,
	const uint8_t* mask, const float* imageA, const float* imageB,
	float* dzncc, uint32_t width, uint32_t height, uint32_t halfSize,
	std::string* error)
{
	if (width == 0 || height == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeImageDZNCC", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
		id<MTLBuffer> meanABuffer = [device newBufferWithBytes:meanA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> meanBBuffer = [device newBufferWithBytes:meanB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> varABuffer = [device newBufferWithBytes:varA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> varBBuffer = [device newBufferWithBytes:varB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> znccBuffer = [device newBufferWithBytes:zncc length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageABuffer = [device newBufferWithBytes:imageA length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBBuffer = [device newBufferWithBytes:imageB length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> dznccBuffer = [device newBufferWithLength:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		id<MTLBuffer> halfSizeBuffer = [device newBufferWithBytes:&halfSize length:sizeof(halfSize) options:MTLResourceStorageModeShared];
		if (meanABuffer == nil || meanBBuffer == nil || varABuffer == nil || varBBuffer == nil ||
			znccBuffer == nil || maskBuffer == nil || imageABuffer == nil || imageBBuffer == nil ||
			dznccBuffer == nil || widthBuffer == nil || heightBuffer == nil || halfSizeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeImageDZNCC");
			return false;
		}
		id<MTLBuffer> buffers[] = {meanABuffer, meanBBuffer, varABuffer, varBBuffer, znccBuffer, maskBuffer, imageABuffer, imageBBuffer, dznccBuffer, widthBuffer, heightBuffer, halfSizeBuffer};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 12, "kernelComputeImageDZNCC command buffer failed", error))
			return false;
		std::memcpy(dzncc, [dznccBuffer contents], sizeof(float)*area);
		return true;
	}
}

bool LaunchPairPhotometricGradient(
	const Point3u* faces, const Point3* normals,
	const float* depthMapA, const float* depthMapB,
	const uint32_t* faceMapA, const uint16_t* baryMapA,
	const float* imageA, const float* imageB,
	Point3* photoGrad, float* photoGradNorm,
	const Camera& camA, const Camera& camB,
	uint32_t numFaces, uint32_t numVertices,
	float regScale, uint32_t halfSize,
	bool resetAccumulation, bool downloadAccumulation,
	std::string* error)
{
	if (numFaces == 0 || numVertices == 0)
		return true;
	if (camA.size.x <= 0 || camA.size.y <= 0 || camB.size.x <= 0 || camB.size.y <= 0) {
		SetError(error, @"invalid Metal pair photometric-gradient camera size");
		return false;
	}
	const uint32_t width = (uint32_t)camA.size.x;
	const uint32_t height = (uint32_t)camA.size.y;
	const NSUInteger areaA = (NSUInteger)width * (NSUInteger)height;
	const NSUInteger areaB = (NSUInteger)camB.size.x * (NSUInteger)camB.size.y;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> warpPipeline = CreatePipeline(device, @"kernelImageMeshWarp", error);
		id<MTLComputePipelineState> meanPipeline = CreatePipeline(device, @"kernelComputeImageMean", error);
		id<MTLComputePipelineState> varPipeline = CreatePipeline(device, @"kernelComputeImageVar", error);
		id<MTLComputePipelineState> covPipeline = CreatePipeline(device, @"kernelComputeImageCov", error);
		id<MTLComputePipelineState> znccPipeline = CreatePipeline(device, @"kernelComputeImageZNCC", error);
		id<MTLComputePipelineState> dznccPipeline = CreatePipeline(device, @"kernelComputeImageDZNCC", error);
		id<MTLComputePipelineState> photoPipeline = CreatePipeline(device, @"kernelComputePhotometricGradient", error);
		id<MTLComputePipelineState> normPipeline = CreatePipeline(device, @"kernelUpdatePhotoGradNorm", error);
		if (warpPipeline == nil || meanPipeline == nil || varPipeline == nil ||
			covPipeline == nil || znccPipeline == nil || dznccPipeline == nil ||
			photoPipeline == nil || normPipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		struct PairPhotometricBufferCache {
			MetalBufferSlot faces, normals, depthA, depthB, faceMap, baryMap;
			MetalBufferSlot imageA, imageB, mask, imageProj;
			MetalBufferSlot meanA, meanProj, varA, varProj, cov, zncc, dzncc;
			MetalBufferSlot photoGrad, photoGradNorm, photoGradPixels;
			MetalBufferSlot camA, camB, regScale, width, height, numVertices, halfSize;
		};
		static thread_local PairPhotometricBufferCache cache;
		if (!UploadBuffer(device, cache.faces, faces, sizeof(Point3u)*numFaces, @"pair faces", error) ||
			!UploadBuffer(device, cache.normals, normals, sizeof(Point3)*numFaces, @"pair normals", error) ||
			!UploadBuffer(device, cache.depthA, depthMapA, sizeof(float)*areaA, @"pair depth A", error) ||
			!UploadBuffer(device, cache.depthB, depthMapB, sizeof(float)*areaB, @"pair depth B", error) ||
			!UploadBuffer(device, cache.faceMap, faceMapA, sizeof(uint32_t)*areaA, @"pair face map", error) ||
			!UploadBuffer(device, cache.baryMap, baryMapA, sizeof(uint16_t)*areaA*3, @"pair bary map", error) ||
			!UploadBuffer(device, cache.imageA, imageA, sizeof(float)*areaA, @"pair image A", error) ||
			!UploadBuffer(device, cache.imageB, imageB, sizeof(float)*areaB, @"pair image B", error) ||
			!EnsureBuffer(device, cache.mask, sizeof(uint8_t)*areaA, @"pair mask", error) ||
			!EnsureBuffer(device, cache.imageProj, sizeof(float)*areaA, @"pair projected image", error) ||
			!EnsureBuffer(device, cache.meanA, sizeof(float)*areaA, @"pair mean A", error) ||
			!EnsureBuffer(device, cache.meanProj, sizeof(float)*areaA, @"pair projected mean", error) ||
			!EnsureBuffer(device, cache.varA, sizeof(float)*areaA, @"pair var A", error) ||
			!EnsureBuffer(device, cache.varProj, sizeof(float)*areaA, @"pair projected var", error) ||
			!EnsureBuffer(device, cache.cov, sizeof(float)*areaA, @"pair covariance", error) ||
			!EnsureBuffer(device, cache.zncc, sizeof(float)*areaA, @"pair zncc", error) ||
			!EnsureBuffer(device, cache.dzncc, sizeof(float)*areaA, @"pair dzncc", error) ||
			!(resetAccumulation ?
				UploadBuffer(device, cache.photoGrad, photoGrad, sizeof(Point3)*numVertices, @"pair photo grad", error) :
				EnsureBuffer(device, cache.photoGrad, sizeof(Point3)*numVertices, @"pair photo grad", error)) ||
			!(resetAccumulation ?
				UploadBuffer(device, cache.photoGradNorm, photoGradNorm, sizeof(float)*numVertices, @"pair photo grad norm", error) :
				EnsureBuffer(device, cache.photoGradNorm, sizeof(float)*numVertices, @"pair photo grad norm", error)) ||
			!EnsureBuffer(device, cache.photoGradPixels, sizeof(float)*numVertices, @"pair photo grad pixels", error) ||
			!UploadBuffer(device, cache.camA, &camA, sizeof(camA), @"pair camera A", error) ||
			!UploadBuffer(device, cache.camB, &camB, sizeof(camB), @"pair camera B", error) ||
			!UploadBuffer(device, cache.regScale, &regScale, sizeof(regScale), @"pair regularization scale", error) ||
			!UploadBuffer(device, cache.width, &width, sizeof(width), @"pair width", error) ||
			!UploadBuffer(device, cache.height, &height, sizeof(height), @"pair height", error) ||
			!UploadBuffer(device, cache.numVertices, &numVertices, sizeof(numVertices), @"pair vertex count", error) ||
			!UploadBuffer(device, cache.halfSize, &halfSize, sizeof(halfSize), @"pair half size", error))
			return false;
		std::memset([cache.photoGradPixels.Get() contents], 0, sizeof(float)*numVertices);

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}

		id<MTLBuffer> warpBuffers[] = {cache.depthA.Get(), cache.depthB.Get(), cache.imageA.Get(), cache.imageB.Get(), cache.mask.Get(), cache.imageProj.Get(), cache.camA.Get(), cache.camB.Get()};
		EncodeDispatch2D(encoder, warpPipeline, width, height, warpBuffers, 8);

		id<MTLBuffer> meanProjBuffers[] = {cache.mask.Get(), cache.imageProj.Get(), cache.meanProj.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, meanPipeline, width, height, meanProjBuffers, 6);

		id<MTLBuffer> varProjBuffers[] = {cache.meanProj.Get(), cache.mask.Get(), cache.imageProj.Get(), cache.varProj.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, varPipeline, width, height, varProjBuffers, 7);

		id<MTLBuffer> meanABuffers[] = {cache.mask.Get(), cache.imageA.Get(), cache.meanA.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, meanPipeline, width, height, meanABuffers, 6);

		id<MTLBuffer> varABuffers[] = {cache.meanA.Get(), cache.mask.Get(), cache.imageA.Get(), cache.varA.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, varPipeline, width, height, varABuffers, 7);

		id<MTLBuffer> covBuffers[] = {cache.meanA.Get(), cache.meanProj.Get(), cache.mask.Get(), cache.imageA.Get(), cache.imageProj.Get(), cache.cov.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, covPipeline, width, height, covBuffers, 9);

		id<MTLBuffer> znccBuffers[] = {cache.cov.Get(), cache.varA.Get(), cache.varProj.Get(), cache.mask.Get(), cache.zncc.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, znccPipeline, width, height, znccBuffers, 8);

		id<MTLBuffer> dznccBuffers[] = {cache.meanA.Get(), cache.meanProj.Get(), cache.varA.Get(), cache.varProj.Get(), cache.zncc.Get(), cache.mask.Get(), cache.imageA.Get(), cache.imageProj.Get(), cache.dzncc.Get(), cache.width.Get(), cache.height.Get(), cache.halfSize.Get()};
		EncodeDispatch2D(encoder, dznccPipeline, width, height, dznccBuffers, 12);

		id<MTLBuffer> photoBuffers[] = {
			cache.faces.Get(), cache.normals.Get(), cache.depthA.Get(), cache.faceMap.Get(), cache.baryMap.Get(),
			cache.dzncc.Get(), cache.mask.Get(), cache.photoGrad.Get(), cache.photoGradPixels.Get(),
			cache.camA.Get(), cache.camB.Get(), cache.imageB.Get(), cache.regScale.Get(), cache.width.Get(), cache.height.Get()
		};
		EncodeDispatch2D(encoder, photoPipeline, width, height, photoBuffers, 15);

		id<MTLBuffer> normBuffers[] = {cache.photoGradNorm.Get(), cache.photoGradPixels.Get(), cache.numVertices.Get()};
		EncodeDispatch1D(encoder, normPipeline, numVertices, normBuffers, 3);

		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "pair photometric-gradient command buffer failed");
			return false;
		}
		if (downloadAccumulation) {
			std::memcpy(photoGrad, [cache.photoGrad.Get() contents], sizeof(Point3)*numVertices);
			std::memcpy(photoGradNorm, [cache.photoGradNorm.Get() contents], sizeof(float)*numVertices);
		}
		return true;
	}
}

bool LaunchImageMeshWarp(
	const float* depthMapA, const float* depthMapB,
	const float* imageA, const float* imageB,
	uint8_t* mask, float* imageProj,
	const Camera& camA, const Camera& camB,
	std::string* error)
{
	if (camA.size.x <= 0 || camA.size.y <= 0 || camB.size.x <= 0 || camB.size.y <= 0) {
		SetError(error, @"invalid Metal image warp camera size");
		return false;
	}
	const uint32_t widthA = (uint32_t)camA.size.x;
	const uint32_t heightA = (uint32_t)camA.size.y;
	const NSUInteger areaA = (NSUInteger)widthA * (NSUInteger)heightA;
	const NSUInteger areaB = (NSUInteger)camB.size.x * (NSUInteger)camB.size.y;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelImageMeshWarp", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		id<MTLBuffer> depthABuffer = [device newBufferWithBytes:depthMapA length:sizeof(float)*areaA options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthBBuffer = [device newBufferWithBytes:depthMapB length:sizeof(float)*areaB options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageABuffer = [device newBufferWithBytes:imageA length:sizeof(float)*areaA options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBBuffer = [device newBufferWithBytes:imageB length:sizeof(float)*areaB options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithLength:sizeof(uint8_t)*areaA options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageProjBuffer = [device newBufferWithLength:sizeof(float)*areaA options:MTLResourceStorageModeShared];
		id<MTLBuffer> camABuffer = [device newBufferWithBytes:&camA length:sizeof(camA) options:MTLResourceStorageModeShared];
		id<MTLBuffer> camBBuffer = [device newBufferWithBytes:&camB length:sizeof(camB) options:MTLResourceStorageModeShared];
		if (depthABuffer == nil || depthBBuffer == nil || imageABuffer == nil || imageBBuffer == nil ||
			maskBuffer == nil || imageProjBuffer == nil || camABuffer == nil || camBBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelImageMeshWarp");
			return false;
		}
		id<MTLBuffer> buffers[] = {depthABuffer, depthBBuffer, imageABuffer, imageBBuffer, maskBuffer, imageProjBuffer, camABuffer, camBBuffer};
		if (!Dispatch2D(queue, pipeline, widthA, heightA, buffers, 8, "kernelImageMeshWarp command buffer failed", error))
			return false;
		std::memcpy(mask, [maskBuffer contents], sizeof(uint8_t)*areaA);
		std::memcpy(imageProj, [imageProjBuffer contents], sizeof(float)*areaA);
		return true;
	}
}

bool LaunchComputePhotometricGradient(
	const Point3u* faces, const Point3* normals,
	const float* depthMap, const uint32_t* faceMap, const uint16_t* baryMap,
	const float* dzncc, const uint8_t* mask, const float* imageB,
	Point3* photoGrad, float* photoGradPixels,
	const Camera& camA, const Camera& camB, uint32_t numVertices,
	float regScale, uint32_t width, uint32_t height,
	std::string* error)
{
	if (width == 0 || height == 0 || numVertices == 0)
		return true;
	if (camB.size.x <= 0 || camB.size.y <= 0) {
		SetError(error, @"invalid Metal photometric-gradient camera size");
		return false;
	}
	const NSUInteger area = (NSUInteger)width * (NSUInteger)height;
	uint32_t numFaces(0);
	for (NSUInteger i = 0; i < area; ++i) {
		if (mask[i] == 1 && faceMap[i] != 0xFFFFFFFFu)
			numFaces = std::max(numFaces, faceMap[i] + 1u);
	}
	if (numFaces == 0)
		return true;
	const NSUInteger areaB = (NSUInteger)camB.size.x * (NSUInteger)camB.size.y;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputePhotometricGradient", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		id<MTLBuffer> facesBuffer = [device newBufferWithBytes:faces length:sizeof(Point3u)*numFaces options:MTLResourceStorageModeShared];
		id<MTLBuffer> normalsBuffer = [device newBufferWithBytes:normals length:sizeof(Point3)*numFaces options:MTLResourceStorageModeShared];
		id<MTLBuffer> depthBuffer = [device newBufferWithBytes:depthMap length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> faceBuffer = [device newBufferWithBytes:faceMap length:sizeof(uint32_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> baryBuffer = [device newBufferWithBytes:baryMap length:sizeof(uint16_t)*area*3 options:MTLResourceStorageModeShared];
		id<MTLBuffer> dznccBuffer = [device newBufferWithBytes:dzncc length:sizeof(float)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> maskBuffer = [device newBufferWithBytes:mask length:sizeof(uint8_t)*area options:MTLResourceStorageModeShared];
		id<MTLBuffer> photoGradBuffer = [device newBufferWithBytes:photoGrad length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> photoGradPixelsBuffer = [device newBufferWithBytes:photoGradPixels length:sizeof(float)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> camABuffer = [device newBufferWithBytes:&camA length:sizeof(camA) options:MTLResourceStorageModeShared];
		id<MTLBuffer> camBBuffer = [device newBufferWithBytes:&camB length:sizeof(camB) options:MTLResourceStorageModeShared];
		id<MTLBuffer> imageBBuffer = [device newBufferWithBytes:imageB length:sizeof(float)*areaB options:MTLResourceStorageModeShared];
		id<MTLBuffer> regScaleBuffer = [device newBufferWithBytes:&regScale length:sizeof(regScale) options:MTLResourceStorageModeShared];
		id<MTLBuffer> widthBuffer = [device newBufferWithBytes:&width length:sizeof(width) options:MTLResourceStorageModeShared];
		id<MTLBuffer> heightBuffer = [device newBufferWithBytes:&height length:sizeof(height) options:MTLResourceStorageModeShared];
		if (facesBuffer == nil || normalsBuffer == nil || depthBuffer == nil || faceBuffer == nil ||
			baryBuffer == nil || dznccBuffer == nil || maskBuffer == nil || photoGradBuffer == nil ||
			photoGradPixelsBuffer == nil || camABuffer == nil || camBBuffer == nil || imageBBuffer == nil ||
			regScaleBuffer == nil || widthBuffer == nil || heightBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputePhotometricGradient");
			return false;
		}
		id<MTLBuffer> buffers[] = {
			facesBuffer, normalsBuffer, depthBuffer, faceBuffer, baryBuffer,
			dznccBuffer, maskBuffer, photoGradBuffer, photoGradPixelsBuffer,
			camABuffer, camBBuffer, imageBBuffer, regScaleBuffer, widthBuffer, heightBuffer
		};
		if (!Dispatch2D(queue, pipeline, width, height, buffers, 15, "kernelComputePhotometricGradient command buffer failed", error))
			return false;
		std::memcpy(photoGrad, [photoGradBuffer contents], sizeof(Point3)*numVertices);
		std::memcpy(photoGradPixels, [photoGradPixelsBuffer contents], sizeof(float)*numVertices);
		return true;
	}
}

bool LaunchUpdatePhotoGradNorm(
	float* photoGradNorm, const float* photoGradPixels,
	uint32_t numVertices, std::string* error)
{
	if (numVertices == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelUpdatePhotoGradNorm", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		id<MTLBuffer> normBuffer = [device newBufferWithBytes:photoGradNorm length:sizeof(float)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> pixelsBuffer = [device newBufferWithBytes:photoGradPixels length:sizeof(float)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> numVerticesBuffer = [device newBufferWithBytes:&numVertices length:sizeof(numVertices) options:MTLResourceStorageModeShared];
		if (normBuffer == nil || pixelsBuffer == nil || numVerticesBuffer == nil) {
			SetError(error, @"failed to allocate Metal buffers for kernelUpdatePhotoGradNorm");
			return false;
		}
		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:normBuffer offset:0 atIndex:0];
		[encoder setBuffer:pixelsBuffer offset:0 atIndex:1];
		[encoder setBuffer:numVerticesBuffer offset:0 atIndex:2];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numVertices, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numVertices, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelUpdatePhotoGradNorm command buffer failed");
			return false;
		}
		std::memcpy(photoGradNorm, [normBuffer contents], sizeof(float)*numVertices);
		return true;
	}
}

bool LaunchComputeSmoothnessGradient(
	const Point3* vertices, const uint32_t* vertVertices,
	const uint32_t* vertSizes, const uint32_t* vertPointers,
	Point3* smoothGrad, uint32_t numVertices, uint8_t mode,
	std::string* error)
{
	if (numVertices == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelComputeSmoothnessGradient", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		uint32_t numNeighborRefs(0);
		for (uint32_t i = 0; i < numVertices; ++i)
			numNeighborRefs = std::max(numNeighborRefs, vertPointers[i] + vertSizes[i]);
		const uint32_t dummyNeighborRef(0);
		const uint32_t* const vertVerticesData(numNeighborRefs > 0 ? vertVertices : &dummyNeighborRef);
		const uint32_t vertVerticesCount(std::max(numNeighborRefs, 1u));
		id<MTLBuffer> verticesBuffer = [device newBufferWithBytes:vertices length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> vertVerticesBuffer = [device newBufferWithBytes:vertVerticesData length:sizeof(uint32_t)*vertVerticesCount options:MTLResourceStorageModeShared];
		id<MTLBuffer> vertSizesBuffer = [device newBufferWithBytes:vertSizes length:sizeof(uint32_t)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> vertPointersBuffer = [device newBufferWithBytes:vertPointers length:sizeof(uint32_t)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> smoothGradBuffer = [device newBufferWithLength:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> numVerticesBuffer = [device newBufferWithBytes:&numVertices length:sizeof(numVertices) options:MTLResourceStorageModeShared];
		id<MTLBuffer> modeBuffer = [device newBufferWithBytes:&mode length:sizeof(mode) options:MTLResourceStorageModeShared];
		if (verticesBuffer == nil || vertVerticesBuffer == nil || vertSizesBuffer == nil || vertPointersBuffer == nil ||
			smoothGradBuffer == nil || numVerticesBuffer == nil || modeBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelComputeSmoothnessGradient");
			return false;
		}
		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:verticesBuffer offset:0 atIndex:0];
		[encoder setBuffer:vertVerticesBuffer offset:0 atIndex:1];
		[encoder setBuffer:vertSizesBuffer offset:0 atIndex:2];
		[encoder setBuffer:vertPointersBuffer offset:0 atIndex:3];
		[encoder setBuffer:smoothGradBuffer offset:0 atIndex:4];
		[encoder setBuffer:numVerticesBuffer offset:0 atIndex:5];
		[encoder setBuffer:modeBuffer offset:0 atIndex:6];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numVertices, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numVertices, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelComputeSmoothnessGradient command buffer failed");
			return false;
		}
		std::memcpy(smoothGrad, [smoothGradBuffer contents], sizeof(Point3)*numVertices);
		return true;
	}
}

bool LaunchSmoothnessAndCombineGradients(
	const Point3* vertices, const uint32_t* vertVertices,
	const uint32_t* vertSizes, const uint32_t* vertPointers,
	Point3* photoGrad, const float* photoGradNorm,
	uint32_t numVertices, float rigidity, float elasticity,
	std::string* error)
{
	if (numVertices == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> smoothPipeline = CreatePipeline(device, @"kernelComputeSmoothnessGradient", error);
		id<MTLComputePipelineState> combinePipeline = CreatePipeline(device, @"kernelCombineAllGradients", error);
		if (smoothPipeline == nil || combinePipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;

		uint32_t numNeighborRefs(0);
		for (uint32_t i = 0; i < numVertices; ++i)
			numNeighborRefs = std::max(numNeighborRefs, vertPointers[i] + vertSizes[i]);
		const uint32_t dummyNeighborRef(0);
		const uint32_t* const vertVerticesData(numNeighborRefs > 0 ? vertVertices : &dummyNeighborRef);
		const uint32_t vertVerticesCount(std::max(numNeighborRefs, 1u));
		const uint8_t mode0(0);
		const uint8_t mode1(1);
		struct SmoothnessBufferCache {
			MetalBufferSlot vertices, vertVertices, vertSizes, vertPointers;
			MetalBufferSlot smooth1, smooth2, photoGrad, norm;
			MetalBufferSlot numVertices, mode0, mode1, rigidity, elasticity;
		};
		static thread_local SmoothnessBufferCache cache;
		if (!UploadBuffer(device, cache.vertices, vertices, sizeof(Point3)*numVertices, @"smoothness vertices", error) ||
			!UploadBuffer(device, cache.vertVertices, vertVerticesData, sizeof(uint32_t)*vertVerticesCount, @"smoothness neighbor vertices", error) ||
			!UploadBuffer(device, cache.vertSizes, vertSizes, sizeof(uint32_t)*numVertices, @"smoothness neighbor sizes", error) ||
			!UploadBuffer(device, cache.vertPointers, vertPointers, sizeof(uint32_t)*numVertices, @"smoothness neighbor pointers", error) ||
			!EnsureBuffer(device, cache.smooth1, sizeof(Point3)*numVertices, @"smoothness first gradient", error) ||
			!EnsureBuffer(device, cache.smooth2, sizeof(Point3)*numVertices, @"smoothness second gradient", error) ||
			!UploadBuffer(device, cache.photoGrad, photoGrad, sizeof(Point3)*numVertices, @"smoothness photo grad", error) ||
			!UploadBuffer(device, cache.norm, photoGradNorm, sizeof(float)*numVertices, @"smoothness photo grad norm", error) ||
			!UploadBuffer(device, cache.numVertices, &numVertices, sizeof(numVertices), @"smoothness vertex count", error) ||
			!UploadBuffer(device, cache.mode0, &mode0, sizeof(mode0), @"smoothness mode 0", error) ||
			!UploadBuffer(device, cache.mode1, &mode1, sizeof(mode1), @"smoothness mode 1", error) ||
			!UploadBuffer(device, cache.rigidity, &rigidity, sizeof(rigidity), @"smoothness rigidity", error) ||
			!UploadBuffer(device, cache.elasticity, &elasticity, sizeof(elasticity), @"smoothness elasticity", error))
			return false;

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}

		id<MTLBuffer> smooth1Buffers[] = {cache.vertices.Get(), cache.vertVertices.Get(), cache.vertSizes.Get(), cache.vertPointers.Get(), cache.smooth1.Get(), cache.numVertices.Get(), cache.mode0.Get()};
		EncodeDispatch1D(encoder, smoothPipeline, numVertices, smooth1Buffers, 7);

		id<MTLBuffer> smooth2Buffers[] = {cache.smooth1.Get(), cache.vertVertices.Get(), cache.vertSizes.Get(), cache.vertPointers.Get(), cache.smooth2.Get(), cache.numVertices.Get(), cache.mode1.Get()};
		EncodeDispatch1D(encoder, smoothPipeline, numVertices, smooth2Buffers, 7);

		id<MTLBuffer> combineBuffers[] = {cache.photoGrad.Get(), cache.norm.Get(), cache.smooth1.Get(), cache.smooth2.Get(), cache.numVertices.Get(), cache.rigidity.Get(), cache.elasticity.Get()};
		EncodeDispatch1D(encoder, combinePipeline, numVertices, combineBuffers, 7);

		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "smoothness/gradient combine command buffer failed");
			return false;
		}
		std::memcpy(photoGrad, [cache.photoGrad.Get() contents], sizeof(Point3)*numVertices);
		return true;
	}
}

bool LaunchCombineGradients(
	Point3* photoGrad, const float* photoGradNorm,
	const Point3* smoothGrad, uint32_t numVertices,
	float smoothWeight, std::string* error)
{
	if (numVertices == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelCombineGradients", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		id<MTLBuffer> photoGradBuffer = [device newBufferWithBytes:photoGrad length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> normBuffer = [device newBufferWithBytes:photoGradNorm length:sizeof(float)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> smoothBuffer = [device newBufferWithBytes:smoothGrad length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> numVerticesBuffer = [device newBufferWithBytes:&numVertices length:sizeof(numVertices) options:MTLResourceStorageModeShared];
		id<MTLBuffer> smoothWeightBuffer = [device newBufferWithBytes:&smoothWeight length:sizeof(smoothWeight) options:MTLResourceStorageModeShared];
		if (photoGradBuffer == nil || normBuffer == nil || smoothBuffer == nil || numVerticesBuffer == nil || smoothWeightBuffer == nil) {
			SetError(error, @"failed to allocate Metal buffers for kernelCombineGradients");
			return false;
		}
		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:photoGradBuffer offset:0 atIndex:0];
		[encoder setBuffer:normBuffer offset:0 atIndex:1];
		[encoder setBuffer:smoothBuffer offset:0 atIndex:2];
		[encoder setBuffer:numVerticesBuffer offset:0 atIndex:3];
		[encoder setBuffer:smoothWeightBuffer offset:0 atIndex:4];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numVertices, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numVertices, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelCombineGradients command buffer failed");
			return false;
		}
		std::memcpy(photoGrad, [photoGradBuffer contents], sizeof(Point3)*numVertices);
		return true;
	}
}

bool LaunchCombineAllGradients(
	Point3* photoGrad, const float* photoGradNorm,
	const Point3* smoothGrad1, const Point3* smoothGrad2,
	uint32_t numVertices, float rigidity, float elasticity,
	std::string* error)
{
	if (numVertices == 0)
		return true;
	@autoreleasepool {
		id<MTLDevice> device = GetMetalDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLComputePipelineState> pipeline = CreatePipeline(device, @"kernelCombineAllGradients", error);
		if (pipeline == nil)
			return false;
		id<MTLCommandQueue> queue = GetCommandQueue(device, error);
		if (queue == nil)
			return false;
		id<MTLBuffer> photoGradBuffer = [device newBufferWithBytes:photoGrad length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> normBuffer = [device newBufferWithBytes:photoGradNorm length:sizeof(float)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> smooth1Buffer = [device newBufferWithBytes:smoothGrad1 length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> smooth2Buffer = [device newBufferWithBytes:smoothGrad2 length:sizeof(Point3)*numVertices options:MTLResourceStorageModeShared];
		id<MTLBuffer> numVerticesBuffer = [device newBufferWithBytes:&numVertices length:sizeof(numVertices) options:MTLResourceStorageModeShared];
		id<MTLBuffer> rigidityBuffer = [device newBufferWithBytes:&rigidity length:sizeof(rigidity) options:MTLResourceStorageModeShared];
		id<MTLBuffer> elasticityBuffer = [device newBufferWithBytes:&elasticity length:sizeof(elasticity) options:MTLResourceStorageModeShared];
		if (photoGradBuffer == nil || normBuffer == nil || smooth1Buffer == nil || smooth2Buffer == nil ||
			numVerticesBuffer == nil || rigidityBuffer == nil || elasticityBuffer == nil)
		{
			SetError(error, @"failed to allocate Metal buffers for kernelCombineAllGradients");
			return false;
		}
		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:photoGradBuffer offset:0 atIndex:0];
		[encoder setBuffer:normBuffer offset:0 atIndex:1];
		[encoder setBuffer:smooth1Buffer offset:0 atIndex:2];
		[encoder setBuffer:smooth2Buffer offset:0 atIndex:3];
		[encoder setBuffer:numVerticesBuffer offset:0 atIndex:4];
		[encoder setBuffer:rigidityBuffer offset:0 atIndex:5];
		[encoder setBuffer:elasticityBuffer offset:0 atIndex:6];
		const NSUInteger groupWidth = std::min<NSUInteger>((NSUInteger)numVertices, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numVertices, 1, 1) threadsPerThreadgroup:MTLSizeMake(groupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "kernelCombineAllGradients command buffer failed");
			return false;
		}
		std::memcpy(photoGrad, [photoGradBuffer contents], sizeof(Point3)*numVertices);
		return true;
	}
}

bool RunComputeFaceNormalSmoke(std::string* error)
{
	const Point3 vertices[] = {
		{0.f, 0.f, 0.f},
		{1.f, 0.f, 0.f},
		{0.f, 1.f, 0.f},
		{0.f, 0.f, 1.f},
	};
	const Point3u faces[] = {
		{0u, 1u, 2u},
		{0u, 3u, 1u},
	};
	Point3 normals[2] = {};
	if (!LaunchComputeFaceNormal(vertices, faces, normals, 2, error))
		return false;
	const float eps = 1e-4f;
	if (std::fabs(normals[0].x - 0.f) > eps || std::fabs(normals[0].y - 0.f) > eps || std::fabs(normals[0].z - 1.f) > eps) {
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "unexpected normal[0]: %.6f %.6f %.6f", normals[0].x, normals[0].y, normals[0].z);
			*error = message;
		}
		return false;
	}
	if (std::fabs(normals[1].x - 0.f) > eps || std::fabs(normals[1].y - 1.f) > eps || std::fabs(normals[1].z - 0.f) > eps) {
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "unexpected normal[1]: %.6f %.6f %.6f", normals[1].x, normals[1].y, normals[1].z);
			*error = message;
		}
		return false;
	}
	return true;
}

bool RunCameraKernelsSmoke(std::string* error)
{
	Camera camera = {};
	camera.model.f = {2.f, 4.f};
	camera.model.p = {10.f, 20.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {1.f, 2.f, 3.f};
	camera.size = {64, 64};

	const Point3 points[] = {
		{2.f, 5.f, 7.f},
		{3.f, 0.f, 5.f},
	};
	Point3 results[2] = {};
	if (!LaunchCameraProjectSmokeKernel(camera, points, results, 2, error))
		return false;
	const float eps = 1e-4f;
	const Point3 expected[] = {
		{10.5f, 23.f, 0.f},
		{12.f, 16.f, 0.f},
	};
	for (uint32_t i = 0; i < 2; ++i) {
		if (std::fabs(results[i].x - expected[i].x) <= eps &&
			std::fabs(results[i].y - expected[i].y) <= eps &&
			std::fabs(results[i].z - expected[i].z) <= eps)
			continue;
		if (error != nullptr) {
			char message[192];
			std::snprintf(message, sizeof(message), "unexpected camera result[%u]: %.6f %.6f %.6f, expected %.6f %.6f %.6f",
				i, results[i].x, results[i].y, results[i].z, expected[i].x, expected[i].y, expected[i].z);
			*error = message;
		}
		return false;
	}
	return true;
}

static bool IsImageStatPixelValid(
	const std::vector<uint8_t>& mask,
	uint32_t width, uint32_t height, uint32_t halfSize,
	uint32_t x, uint32_t y)
{
	const uint32_t pixIdx = y * width + x;
	return x >= halfSize && y >= halfSize && x + halfSize < width && y + halfSize < height && mask[pixIdx] == 1;
}

static void ComputeImageMeanCPU(
	const std::vector<uint8_t>& mask, const std::vector<float>& image,
	std::vector<float>& imageMean, uint32_t width, uint32_t height, uint32_t halfSize)
{
	const int h = (int)halfSize;
	const float windowArea = (float)(2*h + 1) * (float)(2*h + 1);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t pixIdx = y * width + x;
			if (!IsImageStatPixelValid(mask, width, height, halfSize, x, y)) {
				imageMean[pixIdx] = 0.f;
				continue;
			}
			float sum = 0.f;
			for (int dy = -h; dy <= h; ++dy)
				for (int dx = -h; dx <= h; ++dx)
					sum += image[(uint32_t)((int)y + dy) * width + (uint32_t)((int)x + dx)];
			imageMean[pixIdx] = sum / windowArea;
		}
	}
}

static void ComputeImageVarCPU(
	const std::vector<float>& imageMean, const std::vector<uint8_t>& mask,
	const std::vector<float>& image, std::vector<float>& imageVar,
	uint32_t width, uint32_t height, uint32_t halfSize)
{
	const int h = (int)halfSize;
	const float windowArea = (float)(2*h + 1) * (float)(2*h + 1);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t pixIdx = y * width + x;
			if (!IsImageStatPixelValid(mask, width, height, halfSize, x, y)) {
				imageVar[pixIdx] = 0.f;
				continue;
			}
			const float mean = imageMean[pixIdx];
			float sum = 0.f;
			for (int dy = -h; dy <= h; ++dy) {
				for (int dx = -h; dx <= h; ++dx) {
					const float diff = image[(uint32_t)((int)y + dy) * width + (uint32_t)((int)x + dx)] - mean;
					sum += diff * diff;
				}
			}
			imageVar[pixIdx] = std::max(sum / windowArea, 1e-4f);
		}
	}
}

static void ComputeImageCovCPU(
	const std::vector<float>& imageMeanA, const std::vector<float>& imageMeanB,
	const std::vector<uint8_t>& mask, const std::vector<float>& imageA, const std::vector<float>& imageB,
	std::vector<float>& imageCov, uint32_t width, uint32_t height, uint32_t halfSize)
{
	const int h = (int)halfSize;
	const float windowArea = (float)(2*h + 1) * (float)(2*h + 1);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t pixIdx = y * width + x;
			if (!IsImageStatPixelValid(mask, width, height, halfSize, x, y)) {
				imageCov[pixIdx] = 0.f;
				continue;
			}
			const float meanA = imageMeanA[pixIdx];
			const float meanB = imageMeanB[pixIdx];
			float sum = 0.f;
			for (int dy = -h; dy <= h; ++dy) {
				for (int dx = -h; dx <= h; ++dx) {
					const uint32_t idx = (uint32_t)((int)y + dy) * width + (uint32_t)((int)x + dx);
					sum += (imageA[idx] - meanA) * (imageB[idx] - meanB);
				}
			}
			imageCov[pixIdx] = sum / windowArea;
		}
	}
}

static void ComputeImageZNCCCPU(
	const std::vector<float>& imageCov,
	const std::vector<float>& imageVarA, const std::vector<float>& imageVarB,
	const std::vector<uint8_t>& mask, std::vector<float>& imageZNCC,
	uint32_t width, uint32_t height, uint32_t halfSize)
{
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t pixIdx = y * width + x;
			if (!IsImageStatPixelValid(mask, width, height, halfSize, x, y)) {
				imageZNCC[pixIdx] = 0.f;
				continue;
			}
			imageZNCC[pixIdx] = imageCov[pixIdx] / std::sqrt(imageVarA[pixIdx] * imageVarB[pixIdx]);
		}
	}
}

static void ComputeImageDZNCCCPU(
	const std::vector<float>& meanA, const std::vector<float>& meanB,
	const std::vector<float>& varA, const std::vector<float>& varB,
	const std::vector<float>& zncc, const std::vector<uint8_t>& mask,
	const std::vector<float>& imageA, const std::vector<float>& imageB,
	std::vector<float>& dzncc, uint32_t width, uint32_t height, uint32_t halfSize)
{
	const int h = (int)halfSize;
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t pixIdx = y * width + x;
			if (!IsImageStatPixelValid(mask, width, height, halfSize, x, y)) {
				dzncc[pixIdx] = 0.f;
				continue;
			}
			float sumInvSqrtVarProd = 0.f;
			float sumZnccOverVar = 0.f;
			float sumMeanTerm = 0.f;
			float count = 0.f;
			for (int dy = -h; dy <= h; ++dy) {
				const int ny = (int)y + dy;
				if (ny < h || (uint32_t)(ny + h) >= height)
					continue;
				for (int dx = -h; dx <= h; ++dx) {
					const int nx = (int)x + dx;
					if (nx < h || (uint32_t)(nx + h) >= width)
						continue;
					const uint32_t nIdx = (uint32_t)ny * width + (uint32_t)nx;
					if (mask[nIdx] != 1)
						continue;
					const float sqrtVarProd = std::sqrt(varA[nIdx] * varB[nIdx]);
					if (sqrtVarProd == 0.f)
						continue;
					const float invSqrtVarProd = 1.f / sqrtVarProd;
					const float znccOverVar = zncc[nIdx] / varB[nIdx];
					sumInvSqrtVarProd += invSqrtVarProd;
					sumZnccOverVar += znccOverVar;
					sumMeanTerm += meanA[nIdx] * invSqrtVarProd - meanB[nIdx] * znccOverVar;
					count += 1.f;
				}
			}
			if (count == 0.f) {
				dzncc[pixIdx] = 0.f;
				continue;
			}
			const float gradient = (-imageA[pixIdx] * sumInvSqrtVarProd + imageB[pixIdx] * sumZnccOverVar + sumMeanTerm) / count;
			const float minVar = std::min(varA[pixIdx], varB[pixIdx]);
			dzncc[pixIdx] = gradient * minVar / (minVar + 1.5e-3f);
		}
	}
}

static bool CheckArray(
	const std::vector<float>& values, const std::vector<float>& expected,
	const char* name, std::string* error)
{
	const float eps = 2e-4f;
	for (size_t i = 0; i < values.size(); ++i) {
		if (std::isfinite(values[i]) && std::fabs(values[i] - expected[i]) <= eps)
			continue;
		if (error != nullptr) {
			char message[192];
			std::snprintf(message, sizeof(message), "unexpected %s[%zu]: %.6f, expected %.6f",
				name, i, values[i], expected[i]);
			*error = message;
		}
		return false;
	}
	return true;
}

bool RunProjectionKernelsSmoke(std::string* error)
{
	static constexpr uint32_t NO_FACE = 0xFFFFFFFFu;
	const uint32_t cleanupWidth = 4;
	const uint32_t cleanupHeight = 2;
	std::vector<float> cleanupDepthMap = {
		std::numeric_limits<float>::max(), 1.f, 2.f, 3.f,
		4.f, std::numeric_limits<float>::max(), 6.f, 7.f,
	};
	std::vector<uint32_t> cleanupFaceMap = {
		0u, NO_FACE, 2u, 3u,
		NO_FACE, 5u, 6u, 7u,
	};
	const std::vector<float> expectedDepth = {
		0.f, 0.f, 2.f, 3.f,
		0.f, 0.f, 6.f, 7.f,
	};
	const std::vector<uint32_t> expectedFace = {
		NO_FACE, NO_FACE, 2u, 3u,
		NO_FACE, NO_FACE, 6u, 7u,
	};
	if (!LaunchCrossCheckProjection(cleanupDepthMap.data(), cleanupFaceMap.data(), cleanupWidth, cleanupHeight, error))
		return false;
	if (!CheckArray(cleanupDepthMap, expectedDepth, "crossCheckDepth", error))
		return false;
	for (size_t i = 0; i < cleanupFaceMap.size(); ++i) {
		if (cleanupFaceMap[i] == expectedFace[i])
			continue;
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "unexpected crossCheckFace[%zu]: %u, expected %u",
				i, cleanupFaceMap[i], expectedFace[i]);
			*error = message;
		}
		return false;
	}

	const int32_t width = 16;
	const int32_t height = 16;
	const uint32_t area = (uint32_t)width * (uint32_t)height;
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {width, height};

	const Point3 vertices[] = {
		{10.f, 10.f, 2.f},
		{20.f, 10.f, 2.f},
		{10.f, 20.f, 2.f},
		{5.f, 5.f, 1.f},
		{10.f, 5.f, 1.f},
		{5.f, 10.f, 1.f},
	};
	const Point3u faces[] = {
		{0u, 1u, 2u},
		{3u, 4u, 5u},
	};
	const uint32_t faceIDs[] = {1u};
	std::vector<float> depthMap(area, std::numeric_limits<float>::max());
	std::vector<uint32_t> faceMap(area, NO_FACE);
	std::vector<uint16_t> baryMap(area * 3, 0);
	if (!LaunchProjectMesh(vertices, faces, faceIDs, depthMap.data(), faceMap.data(), baryMap.data(), camera, 1, error))
		return false;
	const uint32_t pix = 5u * (uint32_t)width + 5u;
	if (std::fabs(depthMap[pix] - 1.f) > 1e-4f || faceMap[pix] != 1u ||
		baryMap[pix * 3 + 0] != 0x3C00u || baryMap[pix * 3 + 1] != 0u || baryMap[pix * 3 + 2] != 0u)
	{
		if (error != nullptr) {
			char message[224];
			std::snprintf(message, sizeof(message),
				"unexpected projectMesh pixel: depth %.6f face %u bary %04x %04x %04x",
				depthMap[pix], faceMap[pix], baryMap[pix * 3 + 0], baryMap[pix * 3 + 1], baryMap[pix * 3 + 2]);
			*error = message;
		}
		return false;
	}
	return true;
}

bool RunImageKernelsSmoke(std::string* error)
{
	const uint32_t width = 5;
	const uint32_t height = 5;
	const uint32_t halfSize = 1;
	const uint32_t area = width * height;

	std::vector<uint8_t> mask(area, 1);
	mask[0] = 0;
	mask[1*width + 1] = 0;

	std::vector<float> imageA(area);
	std::vector<float> imageB(area);
	for (uint32_t y = 0; y < height; ++y) {
		for (uint32_t x = 0; x < width; ++x) {
			const uint32_t idx = y * width + x;
			imageA[idx] = 0.03f + 0.11f*(float)x + 0.07f*(float)y + 0.013f*(float)(x*y);
			imageB[idx] = 0.2f + 0.05f*(float)x + 0.09f*(float)y + 0.017f*(float)(x*x) - 0.011f*(float)(x*y);
		}
	}

	std::vector<float> expectedMeanA(area), expectedMeanB(area), expectedVarA(area), expectedVarB(area);
	std::vector<float> expectedCov(area), expectedZNCC(area), expectedDZNCC(area);
	ComputeImageMeanCPU(mask, imageA, expectedMeanA, width, height, halfSize);
	ComputeImageMeanCPU(mask, imageB, expectedMeanB, width, height, halfSize);
	ComputeImageVarCPU(expectedMeanA, mask, imageA, expectedVarA, width, height, halfSize);
	ComputeImageVarCPU(expectedMeanB, mask, imageB, expectedVarB, width, height, halfSize);
	ComputeImageCovCPU(expectedMeanA, expectedMeanB, mask, imageA, imageB, expectedCov, width, height, halfSize);
	ComputeImageZNCCCPU(expectedCov, expectedVarA, expectedVarB, mask, expectedZNCC, width, height, halfSize);
	ComputeImageDZNCCCPU(expectedMeanA, expectedMeanB, expectedVarA, expectedVarB, expectedZNCC, mask, imageA, imageB, expectedDZNCC, width, height, halfSize);

	std::vector<float> meanA(area), meanB(area), varA(area), varB(area), cov(area), zncc(area), dzncc(area);
	if (!LaunchComputeImageMean(mask.data(), imageA.data(), meanA.data(), width, height, halfSize, error) ||
		!LaunchComputeImageMean(mask.data(), imageB.data(), meanB.data(), width, height, halfSize, error) ||
		!LaunchComputeImageVar(meanA.data(), mask.data(), imageA.data(), varA.data(), width, height, halfSize, error) ||
		!LaunchComputeImageVar(meanB.data(), mask.data(), imageB.data(), varB.data(), width, height, halfSize, error) ||
		!LaunchComputeImageCov(meanA.data(), meanB.data(), mask.data(), imageA.data(), imageB.data(), cov.data(), width, height, halfSize, error) ||
		!LaunchComputeImageZNCC(cov.data(), varA.data(), varB.data(), mask.data(), zncc.data(), width, height, halfSize, error) ||
		!LaunchComputeImageDZNCC(meanA.data(), meanB.data(), varA.data(), varB.data(), zncc.data(), mask.data(), imageA.data(), imageB.data(), dzncc.data(), width, height, halfSize, error))
		return false;

	return
		CheckArray(meanA, expectedMeanA, "meanA", error) &&
		CheckArray(meanB, expectedMeanB, "meanB", error) &&
		CheckArray(varA, expectedVarA, "varA", error) &&
		CheckArray(varB, expectedVarB, "varB", error) &&
		CheckArray(cov, expectedCov, "cov", error) &&
		CheckArray(zncc, expectedZNCC, "zncc", error) &&
		CheckArray(dzncc, expectedDZNCC, "dzncc", error);
}

bool RunWarpKernelsSmoke(std::string* error)
{
	const int32_t width = 24;
	const int32_t height = 24;
	const uint32_t area = (uint32_t)width * (uint32_t)height;
	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {width, height};

	std::vector<float> depthA(area, 0.f);
	std::vector<float> depthB(area, 0.f);
	std::vector<float> imageA(area, 0.25f);
	std::vector<float> imageB(area, 0.5f);
	std::vector<uint8_t> mask(area, 0);
	std::vector<float> imageProj(area, 0.f);
	std::vector<uint8_t> expectedMask(area, 0);
	std::vector<float> expectedProj(area, 0.25f);

	const uint32_t center = 12u * (uint32_t)width + 12u;
	const uint32_t inconsistent = 12u * (uint32_t)width + 13u;
	depthA[center] = 5.f;
	depthB[center] = 5.f;
	imageB[center] = 0.75f;
	expectedMask[center] = 1;
	expectedProj[center] = 0.75f;

	depthA[inconsistent] = 5.f;

	if (!LaunchImageMeshWarp(depthA.data(), depthB.data(), imageA.data(), imageB.data(), mask.data(), imageProj.data(), camera, camera, error))
		return false;
	if (!CheckArray(imageProj, expectedProj, "imageProj", error))
		return false;
	for (size_t i = 0; i < mask.size(); ++i) {
		if (mask[i] == expectedMask[i])
			continue;
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "unexpected warpMask[%zu]: %u, expected %u",
				i, mask[i], expectedMask[i]);
			*error = message;
		}
		return false;
	}
	return true;
}

static bool CheckPoint(const Point3& p, float x, float y, float z, const char* name, std::string* error)
{
	const float eps = 1e-4f;
	if (std::fabs(p.x - x) <= eps && std::fabs(p.y - y) <= eps && std::fabs(p.z - z) <= eps)
		return true;
	if (error != nullptr) {
		char message[192];
		std::snprintf(message, sizeof(message), "unexpected %s: %.6f %.6f %.6f, expected %.6f %.6f %.6f",
			name, p.x, p.y, p.z, x, y, z);
		*error = message;
	}
	return false;
}

bool RunGradientKernelsSmoke(std::string* error)
{
	float photoGradNorm[] = {0.f, 2.f, 4.f};
	const float photoGradPixels[] = {1.f, 0.f, 2.f};
	if (!LaunchUpdatePhotoGradNorm(photoGradNorm, photoGradPixels, 3, error))
		return false;
	if (std::fabs(photoGradNorm[0] - 1.f) > 1e-4f ||
		std::fabs(photoGradNorm[1] - 2.f) > 1e-4f ||
		std::fabs(photoGradNorm[2] - 5.f) > 1e-4f)
	{
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "unexpected photoGradNorm: %.6f %.6f %.6f",
				photoGradNorm[0], photoGradNorm[1], photoGradNorm[2]);
			*error = message;
		}
		return false;
	}

	{
		const int32_t width = 8;
		const int32_t height = 8;
		const uint32_t area = (uint32_t)width * (uint32_t)height;
		Camera camA = {};
		camA.model.f = {1.f, 1.f};
		camA.model.p = {0.f, 0.f};
		camA.pose.R.m[0] = 1.f;
		camA.pose.R.m[4] = 1.f;
		camA.pose.R.m[8] = 1.f;
		camA.pose.C = {0.f, 0.f, 0.f};
		camA.size = {width, height};
		Camera camB = camA;
		camB.pose.C = {1.f, 0.f, 0.f};

		const Point3u faces[] = {{0u, 1u, 2u}};
		const float viewLen = std::sqrt(51.f);
		const Point3 normals[] = {{-5.f/viewLen, -5.f/viewLen, -1.f/viewLen}};
		std::vector<float> depthMap(area, 0.f);
		std::vector<uint32_t> faceMap(area, 0xFFFFFFFFu);
		std::vector<uint16_t> baryMap(area * 3, 0);
		std::vector<float> dzncc(area, 0.f);
		std::vector<uint8_t> mask(area, 0);
		std::vector<float> imageB(area, 0.f);
		for (uint32_t y = 0; y < (uint32_t)height; ++y)
			for (uint32_t x = 0; x < (uint32_t)width; ++x)
				imageB[y * (uint32_t)width + x] = 0.1f*(float)x + 0.2f*(float)y;

		const uint32_t pix = 5u * (uint32_t)width + 5u;
		depthMap[pix] = 1.f;
		faceMap[pix] = 0u;
		baryMap[pix * 3u + 0u] = 0x3C00u;
		dzncc[pix] = 2.f;
		mask[pix] = 1u;

		Point3 photoGrad[] = {
			{0.f, 0.f, 0.f},
			{0.f, 0.f, 0.f},
			{0.f, 0.f, 0.f},
		};
		float photoGradPixels[] = {0.f, 0.f, 0.f};
		if (!LaunchComputePhotometricGradient(
				faces, normals, depthMap.data(), faceMap.data(), baryMap.data(),
				dzncc.data(), mask.data(), imageB.data(), photoGrad, photoGradPixels,
				camA, camB, 3, 3.f, (uint32_t)width, (uint32_t)height, error))
			return false;

		const float expectedScale = 0.6f / 51.f;
		if (!CheckPoint(photoGrad[0], expectedScale*5.f, expectedScale*5.f, expectedScale, "photoGrad[0]", error) ||
			!CheckPoint(photoGrad[1], 0.f, 0.f, 0.f, "photoGrad[1]", error) ||
			!CheckPoint(photoGrad[2], 0.f, 0.f, 0.f, "photoGrad[2]", error))
			return false;
		if (std::fabs(photoGradPixels[0] - 1.f) > 1e-4f ||
			std::fabs(photoGradPixels[1] - 1.f) > 1e-4f ||
			std::fabs(photoGradPixels[2] - 1.f) > 1e-4f)
		{
			if (error != nullptr) {
				char message[160];
				std::snprintf(message, sizeof(message), "unexpected photoGradPixels: %.6f %.6f %.6f",
					photoGradPixels[0], photoGradPixels[1], photoGradPixels[2]);
				*error = message;
			}
			return false;
		}
	}

	const Point3 vertices[] = {
		{0.f, 0.f, 0.f},
		{2.f, 0.f, 0.f},
		{0.f, 2.f, 0.f},
	};
	const uint32_t vertVertices[] = {1u, 2u, 0u, 0u};
	const uint32_t vertSizes[] = {2u, 1u, 1u};
	const uint32_t vertPointers[] = {0u, 2u, 3u};
	Point3 smoothGrad[3] = {};
	if (!LaunchComputeSmoothnessGradient(vertices, vertVertices, vertSizes, vertPointers, smoothGrad, 3, 0, error))
		return false;
	if (!CheckPoint(smoothGrad[0], -1.f, -1.f, 0.f, "smoothGrad[0]", error) ||
		!CheckPoint(smoothGrad[1], 2.f, 0.f, 0.f, "smoothGrad[1]", error) ||
		!CheckPoint(smoothGrad[2], 0.f, 2.f, 0.f, "smoothGrad[2]", error))
		return false;

	Point3 photoGrad[] = {
		{2.f, 4.f, 6.f},
		{1.f, 1.f, 1.f},
	};
	const float combineNorm[] = {2.f, 0.f};
	const Point3 smooth[] = {
		{1.f, 0.f, 0.f},
		{0.f, 1.f, 0.f},
	};
	if (!LaunchCombineGradients(photoGrad, combineNorm, smooth, 2, 0.5f, error))
		return false;
	if (!CheckPoint(photoGrad[0], 1.5f, 2.f, 3.f, "combined photoGrad[0]", error) ||
		!CheckPoint(photoGrad[1], 0.f, 0.5f, 0.f, "combined photoGrad[1]", error))
		return false;

	Point3 allGrad[] = {
		{2.f, 4.f, 6.f},
		{1.f, 1.f, 1.f},
	};
	const Point3 smooth1[] = {
		{1.f, 0.f, 0.f},
		{0.f, 1.f, 0.f},
	};
	const Point3 smooth2[] = {
		{0.f, 1.f, 0.f},
		{0.f, 0.f, 1.f},
	};
	if (!LaunchCombineAllGradients(allGrad, combineNorm, smooth1, smooth2, 2, 0.25f, 0.5f, error))
		return false;
	if (!CheckPoint(allGrad[0], 1.25f, 2.5f, 3.f, "combined allGrad[0]", error) ||
		!CheckPoint(allGrad[1], 0.f, 0.25f, 0.5f, "combined allGrad[1]", error))
		return false;

	return true;
}

bool RunRefineMeshPairSmoke(std::string* error)
{
	static constexpr uint32_t NO_FACE = 0xFFFFFFFFu;
	const int32_t width = 32;
	const int32_t height = 32;
	const uint32_t area = (uint32_t)width * (uint32_t)height;
	const uint32_t halfSize = 1;

	Camera camera = {};
	camera.model.f = {1.f, 1.f};
	camera.model.p = {0.f, 0.f};
	camera.pose.R.m[0] = 1.f;
	camera.pose.R.m[4] = 1.f;
	camera.pose.R.m[8] = 1.f;
	camera.pose.C = {0.f, 0.f, 0.f};
	camera.size = {width, height};

	const Point3 vertices[] = {
		{60.f, 60.f, 5.f},
		{100.f, 60.f, 5.f},
		{60.f, 100.f, 5.f},
	};
	const Point3u faces[] = {{0u, 1u, 2u}};
	const uint32_t faceIDs[] = {0u};

	std::vector<float> depthA(area, std::numeric_limits<float>::max());
	std::vector<float> depthB(area, std::numeric_limits<float>::max());
	std::vector<uint32_t> faceMapA(area, NO_FACE);
	std::vector<uint32_t> faceMapB(area, NO_FACE);
	std::vector<uint16_t> baryA(area * 3u, 0);
	std::vector<uint16_t> baryB(area * 3u, 0);
	if (!LaunchProjectMesh(vertices, faces, faceIDs, depthA.data(), faceMapA.data(), baryA.data(), camera, 1, error) ||
		!LaunchProjectMesh(vertices, faces, faceIDs, depthB.data(), faceMapB.data(), baryB.data(), camera, 1, error) ||
		!LaunchCrossCheckProjection(depthA.data(), faceMapA.data(), (uint32_t)width, (uint32_t)height, error) ||
		!LaunchCrossCheckProjection(depthB.data(), faceMapB.data(), (uint32_t)width, (uint32_t)height, error))
		return false;

	std::vector<float> imageA(area);
	std::vector<float> imageB(area);
	for (uint32_t y = 0; y < (uint32_t)height; ++y) {
		for (uint32_t x = 0; x < (uint32_t)width; ++x) {
			const uint32_t idx = y * (uint32_t)width + x;
			imageA[idx] = 0.03f + 0.07f*(float)x + 0.05f*(float)y + 0.002f*(float)(x*y);
			imageB[idx] = 0.11f + 0.10f*(float)x + 0.20f*(float)y;
		}
	}

	std::vector<uint8_t> mask(area, 0);
	std::vector<float> imageProj(area, 0.f);
	if (!LaunchImageMeshWarp(depthA.data(), depthB.data(), imageA.data(), imageB.data(), mask.data(), imageProj.data(), camera, camera, error))
		return false;
	uint32_t maskedPixels = 0;
	for (uint8_t value : mask)
		maskedPixels += value == 1 ? 1u : 0u;
	if (maskedPixels == 0) {
		if (error != nullptr)
			*error = "refine-pair smoke produced an empty warp mask";
		return false;
	}

	std::vector<float> meanA(area), meanB(area), varA(area), varB(area), cov(area), zncc(area), dzncc(area);
	if (!LaunchComputeImageMean(mask.data(), imageA.data(), meanA.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageMean(mask.data(), imageProj.data(), meanB.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageVar(meanA.data(), mask.data(), imageA.data(), varA.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageVar(meanB.data(), mask.data(), imageProj.data(), varB.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageCov(meanA.data(), meanB.data(), mask.data(), imageA.data(), imageProj.data(), cov.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageZNCC(cov.data(), varA.data(), varB.data(), mask.data(), zncc.data(), (uint32_t)width, (uint32_t)height, halfSize, error) ||
		!LaunchComputeImageDZNCC(meanA.data(), meanB.data(), varA.data(), varB.data(), zncc.data(), mask.data(), imageA.data(), imageProj.data(), dzncc.data(), (uint32_t)width, (uint32_t)height, halfSize, error))
		return false;

	const Point3 normals[] = {{-0.68f, -0.68f, -0.272f}};
	std::vector<Point3> photoGrad(3);
	std::vector<float> photoGradPixels(3, 0.f);
	if (!LaunchComputePhotometricGradient(
			faces, normals, depthA.data(), faceMapA.data(), baryA.data(),
			dzncc.data(), mask.data(), imageB.data(), photoGrad.data(), photoGradPixels.data(),
			camera, camera, 3, 1.f, (uint32_t)width, (uint32_t)height, error))
		return false;
	std::vector<float> photoGradNorm(3, 0.f);
	if (!LaunchUpdatePhotoGradNorm(photoGradNorm.data(), photoGradPixels.data(), 3, error))
		return false;
	for (uint32_t i = 0; i < 3; ++i) {
		if (photoGradPixels[i] > 0.f && photoGradNorm[i] > 0.f)
			continue;
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "refine-pair smoke vertex %u has no photometric support: pixels %.6f norm %.6f",
				i, photoGradPixels[i], photoGradNorm[i]);
			*error = message;
		}
		return false;
	}

	const uint32_t vertVertices[] = {1u, 2u, 0u, 2u, 0u, 1u};
	const uint32_t vertSizes[] = {2u, 2u, 2u};
	const uint32_t vertPointers[] = {0u, 2u, 4u};
	std::vector<Point3> smooth1(3), smooth2(3);
	if (!LaunchComputeSmoothnessGradient(vertices, vertVertices, vertSizes, vertPointers, smooth1.data(), 3, 0, error) ||
		!LaunchComputeSmoothnessGradient(smooth1.data(), vertVertices, vertSizes, vertPointers, smooth2.data(), 3, 1, error) ||
		!LaunchCombineAllGradients(photoGrad.data(), photoGradNorm.data(), smooth1.data(), smooth2.data(), 3, 0.25f, 0.5f, error))
		return false;

	for (uint32_t i = 0; i < 3; ++i) {
		if (std::isfinite(photoGrad[i].x) && std::isfinite(photoGrad[i].y) && std::isfinite(photoGrad[i].z))
			continue;
		if (error != nullptr) {
			char message[160];
			std::snprintf(message, sizeof(message), "refine-pair smoke produced non-finite gradient[%u]: %.6f %.6f %.6f",
				i, photoGrad[i].x, photoGrad[i].y, photoGrad[i].z);
			*error = message;
		}
		return false;
	}
	return true;
}
/*----------------------------------------------------------------*/

bool RunRefineMeshHostSmoke(std::string* error)
{
	return RunRefineMeshHostSmokeImpl(error);
}
/*----------------------------------------------------------------*/

} // namespace METAL

} // namespace MVS

#endif // _USE_METAL
