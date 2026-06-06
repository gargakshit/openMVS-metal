/*
* SceneRefineMetal.metal
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

// Canonical SceneRefine Metal shader source. CMake expands the local MSL
// helper includes into a generated runtime string for newLibraryWithSource().

#include <metal_stdlib>
#include "Metal/Camera.h"
#include "Metal/Maths.h"

using namespace metal;


// H E L P E R S ////////////////////////////////////////////////////

inline float SampleImageLinear(device const float* image, const int width, const int height, const float2 p)
{
	const float x = clamp(p.x, 0.f, (float)(width - 1));
	const float y = clamp(p.y, 0.f, (float)(height - 1));
	const int x0 = (int)floor(x);
	const int y0 = (int)floor(y);
	const int x1 = min(x0 + 1, width - 1);
	const int y1 = min(y0 + 1, height - 1);
	const float tx = x - (float)x0;
	const float ty = y - (float)y0;
	const float v00 = image[y0 * width + x0];
	const float v10 = image[y0 * width + x1];
	const float v01 = image[y1 * width + x0];
	const float v11 = image[y1 * width + x1];
	return mix(mix(v00, v10, tx), mix(v01, v11, tx), ty);
}

inline void AtomicAddFloat(device atomic_uint* value, const float delta)
{
	uint expected = atomic_load_explicit(value, memory_order_relaxed);
	for (;;) {
		const float current = as_type<float>(expected);
		const uint desired = as_type<uint>(current + delta);
		if (atomic_compare_exchange_weak_explicit(value, &expected, desired, memory_order_relaxed, memory_order_relaxed))
			return;
	}
}

inline void AtomicAddPoint3(device atomic_uint* values, const uint idx, const float3 delta)
{
	const uint base = idx * 3u;
	AtomicAddFloat(values + base + 0u, delta.x);
	AtomicAddFloat(values + base + 1u, delta.y);
	AtomicAddFloat(values + base + 2u, delta.z);
}


// K E R N E L S ////////////////////////////////////////////////////

kernel void kernelCameraProjectSmoke(
	constant MVS::METAL::Camera& camera [[buffer(0)]],
	device const MVS::METAL::Point3* points [[buffer(1)]],
	device MVS::METAL::Point3* results [[buffer(2)]],
	constant uint& numPoints [[buffer(3)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numPoints)
		return;

	const float3 X = MVS::METAL::Load(points[tid]);
	const float3 Xc = MVS::METAL::TransformPointW2C(camera.pose, X);
	const float2 pix = MVS::METAL::TransformPointC2I(camera.model, Xc);
	const float3 roundtrip = MVS::METAL::TransformPointI2W(camera, pix, Xc.z);
	results[tid] = MVS::METAL::StorePoint3(float3(pix.x, pix.y, length(roundtrip - X)));
}

kernel void kernelComputeFaceNormal(
	device const MVS::METAL::Point3* vertices [[buffer(0)]],
	device const MVS::METAL::Point3u* faces [[buffer(1)]],
	device MVS::METAL::Point3* normals [[buffer(2)]],
	constant uint& numFaces [[buffer(3)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numFaces)
		return;

	const uint3 face = MVS::METAL::Load(faces[tid]);
	const float3 v0 = MVS::METAL::Load(vertices[face.x]);
	const float3 v1 = MVS::METAL::Load(vertices[face.y]);
	const float3 v2 = MVS::METAL::Load(vertices[face.z]);
	const float3 e1 = v1 - v0;
	const float3 e2 = v2 - v0;
	const float3 n = cross(e1, e2);
	const float len = length(n);
	normals[tid] = MVS::METAL::StorePoint3(len > 0.f ? n / len : float3(0.f));
}

kernel void kernelProjectMesh(
	device const MVS::METAL::Point3* vertices [[buffer(0)]],
	device const MVS::METAL::Point3u* faces [[buffer(1)]],
	device const uint* faceIDs [[buffer(2)]],
	device atomic_uint* depthMap [[buffer(3)]],
	device uint* faceMap [[buffer(4)]],
	device ushort* baryMap [[buffer(5)]],
	constant MVS::METAL::Camera& camera [[buffer(6)]],
	constant uint& numFacesView [[buffer(7)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numFacesView)
		return;

	const uint faceID = faceIDs[tid];
	const uint3 face = MVS::METAL::Load(faces[faceID]);
	const float3 Xc0 = MVS::METAL::TransformPointW2C(camera.pose, MVS::METAL::Load(vertices[face.x]));
	const float3 Xc1 = MVS::METAL::TransformPointW2C(camera.pose, MVS::METAL::Load(vertices[face.y]));
	const float3 Xc2 = MVS::METAL::TransformPointW2C(camera.pose, MVS::METAL::Load(vertices[face.z]));

	const float2 p0 = MVS::METAL::TransformPointC2I(camera.model, Xc0);
	const float2 p1 = MVS::METAL::TransformPointC2I(camera.model, Xc1);
	const float2 p2 = MVS::METAL::TransformPointC2I(camera.model, Xc2);

	const float2 e10 = p1 - p0;
	const float2 e20 = p2 - p0;
	const float det = e10.x * e20.y - e20.x * e10.y;
	if (det <= 0.f)
		return;
	const float invDet = 1.f / det;

	const int2 size = MVS::METAL::Load(camera.size);
	const int border = 5;
	const int ixMin = max((int)ceil(min(min(p0.x, p1.x), p2.x) - 0.5f), border);
	const int ixMax = min((int)floor(max(max(p0.x, p1.x), p2.x) + 0.5f), size.x - border);
	const int iyMin = max((int)ceil(min(min(p0.y, p1.y), p2.y) - 0.5f), border);
	const int iyMax = min((int)floor(max(max(p0.y, p1.y), p2.y) + 0.5f), size.y - border);
	if (ixMin > ixMax || iyMin > iyMax)
		return;

	const uint width = (uint)size.x;
	for (int iy = iyMin; iy <= iyMax; ++iy) {
		for (int ix = ixMin; ix <= ixMax; ++ix) {
			const float2 d = float2((float)ix - p0.x, (float)iy - p0.y);
			const float b1 = (d.x * e20.y - e20.x * d.y) * invDet;
			const float b2 = (e10.x * d.y - d.x * e10.y) * invDet;
			const float b0 = 1.f - b1 - b2;
			if (b0 < 0.f || b1 < 0.f || b2 < 0.f)
				continue;

			const float depth = b0 * Xc0.z + b1 * Xc1.z + b2 * Xc2.z;
			const uint depthBits = as_type<uint>(depth);
			const uint pixIdx = (uint)iy * width + (uint)ix;
			const uint oldDepthBits = atomic_fetch_min_explicit(depthMap + pixIdx, depthBits, memory_order_relaxed);
			if (depthBits < oldDepthBits) {
				faceMap[pixIdx] = faceID;
				baryMap[pixIdx * 3 + 0] = as_type<ushort>(half(b0));
				baryMap[pixIdx * 3 + 1] = as_type<ushort>(half(b1));
				baryMap[pixIdx * 3 + 2] = as_type<ushort>(half(b2));
			}
		}
	}
}

kernel void kernelCrossCheckProjection(
	device float* depthMap [[buffer(0)]],
	device uint* faceMap [[buffer(1)]],
	constant uint& width [[buffer(2)]],
	constant uint& height [[buffer(3)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (as_type<uint>(depthMap[pixIdx]) == 0x7F7FFFFFu || faceMap[pixIdx] == 0xFFFFFFFFu) {
		depthMap[pixIdx] = 0.f;
		faceMap[pixIdx] = 0xFFFFFFFFu;
	}
}

kernel void kernelComputeImageMean(
	device const uchar* mask [[buffer(0)]],
	device const float* image [[buffer(1)]],
	device float* imageMean [[buffer(2)]],
	constant uint& width [[buffer(3)]],
	constant uint& height [[buffer(4)]],
	constant uint& halfSize [[buffer(5)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (x < halfSize || y < halfSize || x + halfSize >= width || y + halfSize >= height || mask[pixIdx] != 1) {
		imageMean[pixIdx] = 0.f;
		return;
	}

	const int h = (int)halfSize;
	const float windowArea = (float)(2 * h + 1) * (float)(2 * h + 1);
	float sum = 0.f;
	for (int dy = -h; dy <= h; ++dy)
		for (int dx = -h; dx <= h; ++dx)
			sum += image[(uint)((int)y + dy) * width + (uint)((int)x + dx)];
	imageMean[pixIdx] = sum / windowArea;
}

kernel void kernelComputeImageVar(
	device const float* imageMean [[buffer(0)]],
	device const uchar* mask [[buffer(1)]],
	device const float* image [[buffer(2)]],
	device float* imageVar [[buffer(3)]],
	constant uint& width [[buffer(4)]],
	constant uint& height [[buffer(5)]],
	constant uint& halfSize [[buffer(6)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (x < halfSize || y < halfSize || x + halfSize >= width || y + halfSize >= height || mask[pixIdx] != 1) {
		imageVar[pixIdx] = 0.f;
		return;
	}

	const int h = (int)halfSize;
	const float windowArea = (float)(2 * h + 1) * (float)(2 * h + 1);
	const float mean = imageMean[pixIdx];
	float sum = 0.f;
	for (int dy = -h; dy <= h; ++dy) {
		for (int dx = -h; dx <= h; ++dx) {
			const float diff = image[(uint)((int)y + dy) * width + (uint)((int)x + dx)] - mean;
			sum += diff * diff;
		}
	}
	imageVar[pixIdx] = max(sum / windowArea, 1e-4f);
}

kernel void kernelComputeImageCov(
	device const float* imageMeanA [[buffer(0)]],
	device const float* imageMeanB [[buffer(1)]],
	device const uchar* mask [[buffer(2)]],
	device const float* imageA [[buffer(3)]],
	device const float* imageB [[buffer(4)]],
	device float* imageCov [[buffer(5)]],
	constant uint& width [[buffer(6)]],
	constant uint& height [[buffer(7)]],
	constant uint& halfSize [[buffer(8)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (x < halfSize || y < halfSize || x + halfSize >= width || y + halfSize >= height || mask[pixIdx] != 1) {
		imageCov[pixIdx] = 0.f;
		return;
	}

	const int h = (int)halfSize;
	const float windowArea = (float)(2 * h + 1) * (float)(2 * h + 1);
	const float meanA = imageMeanA[pixIdx];
	const float meanB = imageMeanB[pixIdx];
	float sum = 0.f;
	for (int dy = -h; dy <= h; ++dy) {
		for (int dx = -h; dx <= h; ++dx) {
			const uint idx = (uint)((int)y + dy) * width + (uint)((int)x + dx);
			sum += (imageA[idx] - meanA) * (imageB[idx] - meanB);
		}
	}
	imageCov[pixIdx] = sum / windowArea;
}

kernel void kernelComputeImageZNCC(
	device const float* imageCov [[buffer(0)]],
	device const float* imageVarA [[buffer(1)]],
	device const float* imageVarB [[buffer(2)]],
	device const uchar* mask [[buffer(3)]],
	device float* imageZNCC [[buffer(4)]],
	constant uint& width [[buffer(5)]],
	constant uint& height [[buffer(6)]],
	constant uint& halfSize [[buffer(7)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (x < halfSize || y < halfSize || x + halfSize >= width || y + halfSize >= height || mask[pixIdx] != 1) {
		imageZNCC[pixIdx] = 0.f;
		return;
	}
	imageZNCC[pixIdx] = imageCov[pixIdx] / sqrt(imageVarA[pixIdx] * imageVarB[pixIdx]);
}

kernel void kernelComputeImageDZNCC(
	device const float* meanA [[buffer(0)]],
	device const float* meanB [[buffer(1)]],
	device const float* varA [[buffer(2)]],
	device const float* varB [[buffer(3)]],
	device const float* zncc [[buffer(4)]],
	device const uchar* mask [[buffer(5)]],
	device const float* imageA [[buffer(6)]],
	device const float* imageB [[buffer(7)]],
	device float* dzncc [[buffer(8)]],
	constant uint& width [[buffer(9)]],
	constant uint& height [[buffer(10)]],
	constant uint& halfSize [[buffer(11)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (x < halfSize || y < halfSize || x + halfSize >= width || y + halfSize >= height || mask[pixIdx] != 1) {
		dzncc[pixIdx] = 0.f;
		return;
	}

	const int h = (int)halfSize;
	float sumInvSqrtVarProd = 0.f;
	float sumZnccOverVar = 0.f;
	float sumMeanTerm = 0.f;
	float count = 0.f;
	for (int dy = -h; dy <= h; ++dy) {
		const int ny = (int)y + dy;
		if (ny < h || (uint)(ny + h) >= height)
			continue;
		for (int dx = -h; dx <= h; ++dx) {
			const int nx = (int)x + dx;
			if (nx < h || (uint)(nx + h) >= width)
				continue;
			const uint nIdx = (uint)ny * width + (uint)nx;
			if (mask[nIdx] != 1)
				continue;
			const float sqrtVarProd = sqrt(varA[nIdx] * varB[nIdx]);
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
		return;
	}

	const float gradient = (-imageA[pixIdx] * sumInvSqrtVarProd + imageB[pixIdx] * sumZnccOverVar + sumMeanTerm) / count;
	const float minVar = min(varA[pixIdx], varB[pixIdx]);
	dzncc[pixIdx] = gradient * minVar / (minVar + 1.5e-3f);
}

kernel void kernelImageMeshWarp(
	device const float* depthMapA [[buffer(0)]],
	device const float* depthMapB [[buffer(1)]],
	device const float* imageA [[buffer(2)]],
	device const float* imageB [[buffer(3)]],
	device uchar* mask [[buffer(4)]],
	device float* imageProj [[buffer(5)]],
	constant MVS::METAL::Camera& camA [[buffer(6)]],
	constant MVS::METAL::Camera& camB [[buffer(7)]],
	uint2 tid [[thread_position_in_grid]])
{
	const int2 sizeA = MVS::METAL::Load(camA.size);
	const int2 sizeB = MVS::METAL::Load(camB.size);
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= (uint)sizeA.x || y >= (uint)sizeA.y)
		return;

	const uint pixIdx = y * (uint)sizeA.x + x;
	float convergePix = imageA[pixIdx];
	uchar convergeMask = 0;

	const float depthA = depthMapA[pixIdx];
	if (depthA > 0.f) {
		const float3 Xw = MVS::METAL::TransformPointI2W(camA, float2((float)x, (float)y), depthA);
		const float3 XcB = MVS::METAL::TransformPointW2C(camB.pose, Xw);
		const float pz = XcB.z;
		if (pz > 0.f) {
			const float2 projB = MVS::METAL::TransformPointC2I(camB.model, XcB);
			const float borderMin = 10.f;
			const float borderMaxX = (float)(sizeB.x - 10);
			const float borderMaxY = (float)(sizeB.y - 10);
			if (projB.x > borderMin && projB.x < borderMaxX && projB.y > borderMin && projB.y < borderMaxY) {
				const int ixB = (int)projB.x;
				const int iyB = (int)projB.y;
				const int widthB = sizeB.x;
				const int idxB = iyB * widthB + ixB;
				const float tol = 0.01f * pz;
				bool consistent = false;
				if (fabs(depthMapB[idxB] - pz) < tol)
					consistent = true;
				else if (fabs(depthMapB[idxB + 1] - pz) < tol)
					consistent = true;
				else if (fabs(depthMapB[idxB + widthB] - pz) < tol)
					consistent = true;
				else if (fabs(depthMapB[idxB + widthB + 1] - pz) < tol)
					consistent = true;
				if (consistent) {
					convergePix = SampleImageLinear(imageB, sizeB.x, sizeB.y, projB);
					convergeMask = 1;
				}
			}
		}
	}

	imageProj[pixIdx] = convergePix;
	mask[pixIdx] = convergeMask;
}

kernel void kernelComputePhotometricGradient(
	device const MVS::METAL::Point3u* faces [[buffer(0)]],
	device const MVS::METAL::Point3* normals [[buffer(1)]],
	device const float* depthMap [[buffer(2)]],
	device const uint* faceMap [[buffer(3)]],
	device const ushort* baryMap [[buffer(4)]],
	device const float* dznccMap [[buffer(5)]],
	device const uchar* mask [[buffer(6)]],
	device atomic_uint* photoGrad [[buffer(7)]],
	device atomic_uint* photoGradPixels [[buffer(8)]],
	constant MVS::METAL::Camera& camA [[buffer(9)]],
	constant MVS::METAL::Camera& camB [[buffer(10)]],
	device const float* imageB [[buffer(11)]],
	constant float& regScale [[buffer(12)]],
	constant uint& width [[buffer(13)]],
	constant uint& height [[buffer(14)]],
	uint2 tid [[thread_position_in_grid]])
{
	const uint x = tid.x;
	const uint y = tid.y;
	if (x >= width || y >= height)
		return;

	const uint pixIdx = y * width + x;
	if (mask[pixIdx] != 1)
		return;

	const uint faceID = faceMap[pixIdx];
	if (faceID == 0xFFFFFFFFu)
		return;

	const float depth = depthMap[pixIdx];
	const float bary0 = float(as_type<half>(baryMap[pixIdx * 3u + 0u]));
	const float bary1 = float(as_type<half>(baryMap[pixIdx * 3u + 1u]));
	const float bary2 = float(as_type<half>(baryMap[pixIdx * 3u + 2u]));
	const uint3 face = MVS::METAL::Load(faces[faceID]);
	const float3 normal = MVS::METAL::Load(normals[faceID]);

	const float3 camRay = MVS::METAL::TransformPointI2C(camA.model, float2((float)x, (float)y), 1.f);
	const float3 worldDir = MVS::METAL::MulTranspose(camA.pose.R, camRay);
	const float viewLen = length(worldDir);
	if (viewLen == 0.f)
		return;
	const float3 viewDir = worldDir / viewLen;
	const float viewDotNormal = dot(viewDir, normal);
	if (viewDotNormal > -0.1f)
		return;

	const float3 Xw = MVS::METAL::TransformPointI2W(camA, float2((float)x, (float)y), depth);
	const float3 XcB = MVS::METAL::TransformPointW2C(camB.pose, Xw);
	const float pz = XcB.z;
	if (pz <= 0.f)
		return;
	const float2 projB = MVS::METAL::TransformPointC2I(camB.model, XcB);

	const float2 f = MVS::METAL::Load(camB.model.f);
	const float2 p = MVS::METAL::Load(camB.model.p);
	const MVS::METAL::Matrix3 R = camB.pose.R;
	const float3 row0 = float3(R.m[0], R.m[1], R.m[2]);
	const float3 row1 = float3(R.m[3], R.m[4], R.m[5]);
	const float3 row2 = float3(R.m[6], R.m[7], R.m[8]);
	const float3 kr0 = f.x * row0 + p.x * row2;
	const float3 kr1 = f.y * row1 + p.y * row2;
	const float3 kr2 = row2;
	const float rawPx = f.x * XcB.x + p.x * XcB.z;
	const float rawPy = f.y * XcB.y + p.y * XcB.z;
	const float pz2 = pz * pz;
	const float3 dudX = (kr0 * pz - kr2 * rawPx) / pz2;
	const float3 dvdX = (kr1 * pz - kr2 * rawPy) / pz2;

	const int2 sizeB = MVS::METAL::Load(camB.size);
	const float pixC = SampleImageLinear(imageB, sizeB.x, sizeB.y, projB);
	const float dx = SampleImageLinear(imageB, sizeB.x, sizeB.y, projB + float2(1.f, 0.f)) - pixC;
	const float dy = SampleImageLinear(imageB, sizeB.x, sizeB.y, projB + float2(0.f, 1.f)) - pixC;
	const float dz = dznccMap[pixIdx];
	const float3 grad = dz * (dx * dudX + dy * dvdX);
	const float projMag = dot(grad, viewDir) / viewDotNormal;

	AtomicAddPoint3(photoGrad, face.x, regScale * bary0 * projMag * normal);
	AtomicAddPoint3(photoGrad, face.y, regScale * bary1 * projMag * normal);
	AtomicAddPoint3(photoGrad, face.z, regScale * bary2 * projMag * normal);
	AtomicAddFloat(photoGradPixels + face.x, 1.f);
	AtomicAddFloat(photoGradPixels + face.y, 1.f);
	AtomicAddFloat(photoGradPixels + face.z, 1.f);
}

kernel void kernelUpdatePhotoGradNorm(
	device float* photoGradNorm [[buffer(0)]],
	device const float* photoGradPixels [[buffer(1)]],
	constant uint& numVertices [[buffer(2)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numVertices)
		return;
	if (photoGradPixels[tid] > 0.f)
		photoGradNorm[tid] += 1.f;
}

kernel void kernelComputeSmoothnessGradient(
	device const MVS::METAL::Point3* vertices [[buffer(0)]],
	device const uint* vertVertices [[buffer(1)]],
	device const uint* vertSizes [[buffer(2)]],
	device const uint* vertPointers [[buffer(3)]],
	device MVS::METAL::Point3* smoothGrad [[buffer(4)]],
	constant uint& numVertices [[buffer(5)]],
	constant uchar& mode [[buffer(6)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numVertices)
		return;

	const uint numNeighbors = vertSizes[tid];
	if (numNeighbors == 0) {
		smoothGrad[tid] = MVS::METAL::StorePoint3(float3(0.f));
		return;
	}

	const uint ptr = vertPointers[tid];
	const float invN = 1.f / float(numNeighbors);
	float3 result = MVS::METAL::Load(vertices[tid]);
	float totalWeight = 1.f;
	for (uint i = 0; i < numNeighbors; ++i) {
		const uint ni = vertVertices[ptr + i];
		result -= MVS::METAL::Load(vertices[ni]) * invN;
		if (mode != 0)
			totalWeight += invN / float(vertSizes[ni]);
	}
	if (mode != 0)
		result /= totalWeight;
	smoothGrad[tid] = MVS::METAL::StorePoint3(result);
}

kernel void kernelCombineGradients(
	device MVS::METAL::Point3* photoGrad [[buffer(0)]],
	device const float* photoGradNorm [[buffer(1)]],
	device const MVS::METAL::Point3* smoothGrad [[buffer(2)]],
	constant uint& numVertices [[buffer(3)]],
	constant float& smoothWeight [[buffer(4)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numVertices)
		return;
	const float norm = photoGradNorm[tid];
	const float3 smooth = MVS::METAL::Load(smoothGrad[tid]);
	if (norm > 0.f)
		photoGrad[tid] = MVS::METAL::StorePoint3(MVS::METAL::Load(photoGrad[tid]) / norm + smoothWeight * smooth);
	else
		photoGrad[tid] = MVS::METAL::StorePoint3(smoothWeight * smooth);
}

kernel void kernelCombineAllGradients(
	device MVS::METAL::Point3* photoGrad [[buffer(0)]],
	device const float* photoGradNorm [[buffer(1)]],
	device const MVS::METAL::Point3* smoothGrad1 [[buffer(2)]],
	device const MVS::METAL::Point3* smoothGrad2 [[buffer(3)]],
	constant uint& numVertices [[buffer(4)]],
	constant float& rigidity [[buffer(5)]],
	constant float& elasticity [[buffer(6)]],
	uint tid [[thread_position_in_grid]])
{
	if (tid >= numVertices)
		return;
	const float norm = photoGradNorm[tid];
	const float3 smooth1 = MVS::METAL::Load(smoothGrad1[tid]);
	const float3 smooth2 = MVS::METAL::Load(smoothGrad2[tid]);
	if (norm > 0.f)
		photoGrad[tid] = MVS::METAL::StorePoint3(MVS::METAL::Load(photoGrad[tid]) / norm + rigidity * smooth1 + elasticity * smooth2);
	else
		photoGrad[tid] = MVS::METAL::StorePoint3(rigidity * smooth1 + elasticity * smooth2);
}
/*----------------------------------------------------------------*/
