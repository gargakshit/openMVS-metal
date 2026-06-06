/*
 * TestsMVS.cpp
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

#include "../../libs/MVS.h"
#include "../../libs/Common/UtilGPU.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <vector>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

DEFINE_LOG_NAME(lt, _T("TestMVS "));

namespace MVS {

static constexpr unsigned TEST_MAX_THREADS = 4;

// test MVS stages on a small sample dataset
bool PipelineTest(bool forceCPU, bool verbose, const char* expectedBackend)
{
	TD_TIMER_START();
	#ifdef _USE_CUDA
	// force CPU for testing even if CUDA is available
	if (forceCPU)
		SEACAVE::CUDA::desiredDeviceIDs.clear();
	#endif
	if (forceCPU)
		SEACAVE::GPU::desiredBackend = "cpu";
	else
		SEACAVE::GPU::desiredBackend = "auto";
	SEACAVE::GPU::ResetLastSelectedBackend();
	const unsigned pipelineMaxThreads(forceCPU ? 2u : TEST_MAX_THREADS);
	Scene scene(pipelineMaxThreads);
	if (!scene.Load(MAKE_PATH("scene.mvs"))) {
		VERBOSE("ERROR: TestDataset failed loading the scene!");
		return false;
	}
	OPTDENSE::init();
	OPTDENSE::bRemoveDmaps = true;
	OPTDENSE::nPatchMatchCUDAInstances = pipelineMaxThreads;
	if (!scene.DenseReconstruction() || scene.pointcloud.GetSize() < 50000u) {
		std::fprintf(stderr, "MVS pipeline dense stage: points=%zu\n", (size_t)scene.pointcloud.GetSize());
		VERBOSE("ERROR: TestDataset failed estimating dense point-cloud!");
		return false;
	}
	if (expectedBackend != nullptr && expectedBackend[0] != '\0') {
		const SEACAVE::GPU::Backend expected(SEACAVE::GPU::ParseBackend(expectedBackend));
		const SEACAVE::GPU::Backend selected(SEACAVE::GPU::LastSelectedBackend());
		if (expected == SEACAVE::GPU::Backend::UNKNOWN || expected == SEACAVE::GPU::Backend::AUTO) {
			std::fprintf(stderr, "MVS pipeline expected backend is invalid for strict check: %s\n", expectedBackend);
			return false;
		}
		if (selected != expected) {
			std::fprintf(stderr, "MVS pipeline selected backend mismatch: expected=%s selected=%s\n",
				SEACAVE::GPU::ToString(expected), SEACAVE::GPU::ToString(selected));
			return false;
		}
	}
	if (verbose)
		scene.pointcloud.Save(MAKE_PATH("scene_dense.ply"));
	const bool meshReconstructed(scene.ReconstructMesh());
	if (!meshReconstructed || !ISINSIDE(scene.mesh.faces.size(), 25000u, 38000u)) {
		std::fprintf(stderr, "MVS pipeline mesh stage: ok=%d faces=%zu vertices=%zu\n",
			meshReconstructed ? 1 : 0, (size_t)scene.mesh.faces.size(), (size_t)scene.mesh.vertices.size());
		VERBOSE("ERROR: TestDataset failed reconstructing the mesh!");
		return false;
	}
	if (verbose)
		scene.mesh.Save(MAKE_PATH("scene_dense_mesh.ply"));
	constexpr float decimate = 0.7f;
	scene.mesh.Clean(decimate);
	if (!ISINSIDE(scene.mesh.faces.size(), 17000u, 26000u)) {
		std::fprintf(stderr, "MVS pipeline clean stage: faces=%zu vertices=%zu\n",
			(size_t)scene.mesh.faces.size(), (size_t)scene.mesh.vertices.size());
		VERBOSE("ERROR: TestDataset failed cleaning the mesh!");
		return false;
	}
	if (verbose)
		scene.mesh.Save(MAKE_PATH("scene_dense_mesh_clean.ply"));
	#ifdef _USE_OPENMP
	TestMeshProjectionMT(scene.mesh, scene.images[1]);
	#endif
	if (!scene.TextureMesh(0, 0) || !scene.mesh.HasTexture()) {
		std::fprintf(stderr, "MVS pipeline texture stage: hasTexture=%d faces=%zu vertices=%zu\n",
			scene.mesh.HasTexture() ? 1 : 0, (size_t)scene.mesh.faces.size(), (size_t)scene.mesh.vertices.size());
		VERBOSE("ERROR: TestDataset failed texturing the mesh!");
		return false;
	}
	if (verbose)
		scene.mesh.Save(MAKE_PATH("scene_dense_mesh_texture.ply"));
	const float qualityScore = scene.ComputeReconstructionQuality().score();
	const float minQualityScore(forceCPU ? 44.f : 45.f);
	if (qualityScore < minQualityScore) {
		std::fprintf(stderr, "MVS pipeline quality stage: score=%.3f min=%.3f\n", qualityScore, minQualityScore);
		VERBOSE("ERROR: TestDataset reconstruction quality too low (%.1f < %.1f)!", qualityScore, minQualityScore);
		return false;
	}
	VERBOSE("All pipeline stages passed (%s)", TD_TIMER_GET_FMT().c_str());
	return true;
}
/*----------------------------------------------------------------*/

#ifdef _USE_METAL
namespace {

struct DenseSummary {
	size_t points = 0;
	Point3f center = Point3f(0, 0, 0);
	float diagonal = 0.f;
	Point3f robustCenter = Point3f(0, 0, 0);
	float robustDiagonal = 0.f;
};

struct DepthMapSnapshot {
	IIndex imageID = NO_ID;
	DepthMap depthMap;
	NormalMap normalMap;
	ConfidenceMap confMap;
};

void RemoveSampleDepthCache(const Scene& scene)
{
	FOREACH(idxImage, scene.images) {
		const IIndex imageID(scene.images[idxImage].ID);
		File::deleteFile(ComposeDepthFilePath(imageID, "dmap"));
		File::deleteFile(ComposeDepthFilePath(imageID, "geo.dmap"));
		File::deleteFile(ComposeDepthFilePath(imageID, "adjusted.fast.cmap"));
		File::deleteFile(ComposeDepthFilePath(imageID, "adjusted.cmap"));
	}
}

bool SummarizePointCloud(const PointCloud& pointcloud, DenseSummary& summary)
{
	if (pointcloud.IsEmpty())
		return false;
	Point3f minPoint(pointcloud.points[0]);
	Point3f maxPoint(pointcloud.points[0]);
	std::vector<float> xs;
	std::vector<float> ys;
	std::vector<float> zs;
	xs.reserve(pointcloud.points.GetSize());
	ys.reserve(pointcloud.points.GetSize());
	zs.reserve(pointcloud.points.GetSize());
	FOREACH(idxPoint, pointcloud.points) {
		const Point3f& point(pointcloud.points[idxPoint]);
		if (!std::isfinite(point.x) || !std::isfinite(point.y) || !std::isfinite(point.z))
			return false;
		minPoint.x = MINF(minPoint.x, point.x);
		minPoint.y = MINF(minPoint.y, point.y);
		minPoint.z = MINF(minPoint.z, point.z);
		maxPoint.x = MAXF(maxPoint.x, point.x);
		maxPoint.y = MAXF(maxPoint.y, point.y);
		maxPoint.z = MAXF(maxPoint.z, point.z);
		xs.push_back(point.x);
		ys.push_back(point.y);
		zs.push_back(point.z);
	}
	summary.points = pointcloud.GetSize();
	summary.center = (minPoint + maxPoint) * 0.5f;
	summary.diagonal = norm(maxPoint - minPoint);
	std::sort(xs.begin(), xs.end());
	std::sort(ys.begin(), ys.end());
	std::sort(zs.begin(), zs.end());
	size_t trim(summary.points / 50u);
	if (trim * 2u >= summary.points)
		trim = 0;
	const size_t maxIdx(summary.points - 1u - trim);
	const Point3f robustMin(xs[trim], ys[trim], zs[trim]);
	const Point3f robustMax(xs[maxIdx], ys[maxIdx], zs[maxIdx]);
	summary.robustCenter = (robustMin + robustMax) * 0.5f;
	summary.robustDiagonal = norm(robustMax - robustMin);
	return summary.points > 0 && summary.diagonal > 0.f && summary.robustDiagonal > 0.f;
}

bool LoadDepthMapSnapshots(const Scene& scene, const char* backend, std::vector<DepthMapSnapshot>& snapshots)
{
	snapshots.clear();
	FOREACH(idxImage, scene.images) {
		const Image& image(scene.images[idxImage]);
		if (!image.IsValid())
			continue;
		const String fileName(ComposeDepthFilePath(image.ID, "dmap"));
		if (!File::access(fileName))
			continue;
		String imageFileName;
		IIndexArr IDs;
		cv::Size imageSize;
		KMatrix K;
		RMatrix R;
		CMatrix C;
		Depth dMin(0), dMax(0);
		DepthMapSnapshot snapshot;
		ViewsMap viewsMap;
		if (!ImportDepthDataRaw(
				fileName, imageFileName, IDs, imageSize, K, R, C, dMin, dMax,
				snapshot.depthMap, snapshot.normalMap, snapshot.confMap, viewsMap,
				HeaderDepthDataRaw::HAS_DEPTH | HeaderDepthDataRaw::HAS_NORMAL | HeaderDepthDataRaw::HAS_CONF))
		{
			std::fprintf(stderr, "Dense parity backend %s failed loading %s\n", backend, fileName.c_str());
			return false;
		}
		if (IDs.empty() || IDs.front() != image.ID || snapshot.depthMap.empty()) {
			std::fprintf(stderr, "Dense parity backend %s loaded invalid depth-map metadata for %s\n", backend, fileName.c_str());
			return false;
		}
		if (!snapshot.normalMap.empty() && snapshot.normalMap.size() != snapshot.depthMap.size()) {
			std::fprintf(stderr, "Dense parity backend %s normal-map size mismatch for image %u\n", backend, image.ID);
			return false;
		}
		if (!snapshot.confMap.empty() && snapshot.confMap.size() != snapshot.depthMap.size()) {
			std::fprintf(stderr, "Dense parity backend %s confidence-map size mismatch for image %u\n", backend, image.ID);
			return false;
		}
		snapshot.imageID = image.ID;
		snapshots.push_back(std::move(snapshot));
	}
	if (snapshots.size() < 2u) {
		std::fprintf(stderr, "Dense parity backend %s produced too few depth-maps: %zu\n", backend, snapshots.size());
		return false;
	}
	return true;
}

bool RunDenseSampleBackend(const char* backend, Scene& scene, DenseSummary& summary, std::vector<DepthMapSnapshot>& snapshots)
{
	SEACAVE::GPU::desiredBackend = backend;
	scene.Release();
	if (!scene.Load(MAKE_PATH("scene.mvs"))) {
		VERBOSE("ERROR: Dense parity failed loading the scene for backend %s!", backend);
		return false;
	}
	RemoveSampleDepthCache(scene);
	OPTDENSE::init();
	OPTDENSE::bRemoveDmaps = false;
	OPTDENSE::nPatchMatchCUDAInstances = TEST_MAX_THREADS;
	if (!scene.DenseReconstruction() || !SummarizePointCloud(scene.pointcloud, summary)) {
		std::fprintf(stderr, "Dense parity backend %s failed: points=%zu\n",
			backend, (size_t)scene.pointcloud.GetSize());
		RemoveSampleDepthCache(scene);
		return false;
	}
	if (!LoadDepthMapSnapshots(scene, backend, snapshots)) {
		RemoveSampleDepthCache(scene);
		return false;
	}
	RemoveSampleDepthCache(scene);
	return true;
}

bool CompareDenseSummaries(const DenseSummary& cpu, const DenseSummary& metal)
{
	const double pointRatio((double)metal.points / (double)cpu.points);
	if (pointRatio < 0.65 || pointRatio > 1.35) {
		std::fprintf(stderr, "Metal dense point count outside CPU tolerance: cpu=%zu metal=%zu ratio=%.3f\n",
			cpu.points, metal.points, pointRatio);
		return false;
	}
	const double diagonalRatio((double)metal.diagonal / (double)cpu.diagonal);
	if (diagonalRatio < 0.5 || diagonalRatio > 2.5) {
		std::fprintf(stderr, "Metal dense AABB diagonal outside CPU tolerance: cpu=%.6f metal=%.6f ratio=%.3f\n",
			cpu.diagonal, metal.diagonal, diagonalRatio);
		return false;
	}
	const double robustDiagonalRatio((double)metal.robustDiagonal / (double)cpu.robustDiagonal);
	if (robustDiagonalRatio < 0.65 || robustDiagonalRatio > 1.35) {
		std::fprintf(stderr, "Metal dense robust AABB diagonal outside CPU tolerance: cpu=%.6f metal=%.6f ratio=%.3f\n",
			cpu.robustDiagonal, metal.robustDiagonal, robustDiagonalRatio);
		return false;
	}
	const float centerDistance(norm(metal.robustCenter - cpu.robustCenter));
	if (centerDistance > MAXF(cpu.robustDiagonal * 0.15f, 0.05f)) {
		std::fprintf(stderr, "Metal dense robust AABB center too far from CPU: distance=%.6f cpuDiagonal=%.6f\n",
			centerDistance, cpu.robustDiagonal);
		return false;
	}
	return true;
}

float Percentile(std::vector<float>& values, float percentile)
{
	ASSERT(!values.empty());
	std::sort(values.begin(), values.end());
	const float idxf((float)(values.size() - 1u) * percentile);
	const size_t idx0((size_t)std::floor(idxf));
	const size_t idx1(std::min(idx0 + 1u, values.size() - 1u));
	const float t(idxf - (float)idx0);
	return values[idx0] * (1.f - t) + values[idx1] * t;
}

bool IsFiniteNormal(const Normal& normal)
{
	return std::isfinite(normal.x) && std::isfinite(normal.y) && std::isfinite(normal.z) && norm(normal) > 0.25f;
}

bool CompareDepthMapSnapshots(const std::vector<DepthMapSnapshot>& cpu, const std::vector<DepthMapSnapshot>& metal)
{
	if (cpu.size() != metal.size()) {
		std::fprintf(stderr, "Dense parity depth-map count mismatch: cpu=%zu metal=%zu\n", cpu.size(), metal.size());
		return false;
	}
	size_t cpuValid(0), metalValid(0), overlapValid(0);
	double cpuConfSum(0), metalConfSum(0);
	size_t cpuConfCount(0), metalConfCount(0);
	std::vector<float> relativeDepthErrors;
	std::vector<float> normalAnglesDeg;
	for (size_t idxMap = 0; idxMap < cpu.size(); ++idxMap) {
		const DepthMapSnapshot& ref(cpu[idxMap]);
		const DepthMapSnapshot& candidate(metal[idxMap]);
		if (ref.imageID != candidate.imageID || ref.depthMap.size() != candidate.depthMap.size()) {
			std::fprintf(stderr, "Dense parity depth-map metadata mismatch at %zu: cpuID=%u metalID=%u cpu=%dx%d metal=%dx%d\n",
				idxMap, ref.imageID, candidate.imageID,
				ref.depthMap.cols, ref.depthMap.rows, candidate.depthMap.cols, candidate.depthMap.rows);
			return false;
		}
		for (int y = 0; y < ref.depthMap.rows; ++y) {
			for (int x = 0; x < ref.depthMap.cols; ++x) {
				const Depth depthCPU(ref.depthMap(y,x));
				const Depth depthMetal(candidate.depthMap(y,x));
				const bool validCPU(std::isfinite(depthCPU) && depthCPU > 0);
				const bool validMetal(std::isfinite(depthMetal) && depthMetal > 0);
				if (validCPU) {
					++cpuValid;
					if (!ref.confMap.empty()) {
						const float conf(ref.confMap(y,x));
						if (std::isfinite(conf)) {
							cpuConfSum += conf;
							++cpuConfCount;
						}
					}
				}
				if (validMetal) {
					++metalValid;
					if (!candidate.confMap.empty()) {
						const float conf(candidate.confMap(y,x));
						if (std::isfinite(conf)) {
							metalConfSum += conf;
							++metalConfCount;
						}
					}
				}
				if (!validCPU || !validMetal)
					continue;
				++overlapValid;
				relativeDepthErrors.push_back(ABS(depthMetal - depthCPU) / MAXF(ABS(depthCPU), 1e-3f));
				if (!ref.normalMap.empty() && !candidate.normalMap.empty()) {
					const Normal normalCPU(ref.normalMap(y,x));
					const Normal normalMetal(candidate.normalMap(y,x));
					if (IsFiniteNormal(normalCPU) && IsFiniteNormal(normalMetal)) {
						const float dot(CLAMP(normalized(normalCPU).dot(normalized(normalMetal)), -1.f, 1.f));
						normalAnglesDeg.push_back(R2D(ACOS(dot)));
					}
				}
			}
		}
	}
	if (cpuValid == 0 || metalValid == 0) {
		std::fprintf(stderr, "Dense parity depth maps have no valid support: cpu=%zu metal=%zu\n", cpuValid, metalValid);
		return false;
	}
	const double validRatio((double)metalValid / (double)cpuValid);
	if (validRatio < 0.55 || validRatio > 1.65) {
		std::fprintf(stderr, "Dense parity valid-pixel ratio outside tolerance: cpu=%zu metal=%zu ratio=%.3f\n",
			cpuValid, metalValid, validRatio);
		return false;
	}
	const double overlapRatio((double)overlapValid / (double)std::min(cpuValid, metalValid));
	if (overlapRatio < 0.25) {
		std::fprintf(stderr, "Dense parity common valid support too small: cpu=%zu metal=%zu overlap=%zu ratio=%.3f\n",
			cpuValid, metalValid, overlapValid, overlapRatio);
		return false;
	}
	if (relativeDepthErrors.empty()) {
		std::fprintf(stderr, "Dense parity has no overlapping depth samples to compare\n");
		return false;
	}
	const float medianDepthRelError(Percentile(relativeDepthErrors, 0.5f));
	const float p90DepthRelError(Percentile(relativeDepthErrors, 0.9f));
	if (medianDepthRelError > 0.45f || p90DepthRelError > 2.5f) {
		std::fprintf(stderr, "Dense parity depth drift outside tolerance: medianRel=%.6f p90Rel=%.6f\n",
			medianDepthRelError, p90DepthRelError);
		return false;
	}
	float medianNormalAngle(-1.f);
	if (!normalAnglesDeg.empty()) {
		medianNormalAngle = Percentile(normalAnglesDeg, 0.5f);
		if (medianNormalAngle > 75.f) {
			std::fprintf(stderr, "Dense parity normal drift outside tolerance: medianAngle=%.6f degrees\n", medianNormalAngle);
			return false;
		}
	}
	const double meanCpuConf(cpuConfCount > 0 ? cpuConfSum / (double)cpuConfCount : 0.0);
	const double meanMetalConf(metalConfCount > 0 ? metalConfSum / (double)metalConfCount : 0.0);
	if (cpuConfCount > 0 && metalConfCount > 0 && (!(meanCpuConf >= 0.0) || !(meanMetalConf >= 0.0))) {
		std::fprintf(stderr, "Dense parity confidence summary invalid: cpu=%.6f metal=%.6f\n", meanCpuConf, meanMetalConf);
		return false;
	}
	VERBOSE("Metal depth-map parity: maps=%zu cpuValid=%zu metalValid=%zu overlap=%zu validRatio=%.3f overlapRatio=%.3f medianDepthRel=%.6f p90DepthRel=%.6f medianNormalAngle=%.3f meanConfCPU=%.6f meanConfMetal=%.6f",
		cpu.size(), cpuValid, metalValid, overlapValid, validRatio, overlapRatio,
		medianDepthRelError, p90DepthRelError, medianNormalAngle, meanCpuConf, meanMetalConf);
	return true;
}

bool IsFiniteVertex(const Mesh::Vertex& vertex)
{
	return std::isfinite(vertex.x) && std::isfinite(vertex.y) && std::isfinite(vertex.z);
}

float MeshDiagonal(const Mesh::VertexArr& vertices)
{
	if (vertices.IsEmpty())
		return 0.f;
	Mesh::Vertex minVertex(vertices[0]);
	Mesh::Vertex maxVertex(vertices[0]);
	FOREACH(idxVertex, vertices) {
		const Mesh::Vertex& vertex(vertices[idxVertex]);
		minVertex.x = MINF(minVertex.x, vertex.x);
		minVertex.y = MINF(minVertex.y, vertex.y);
		minVertex.z = MINF(minVertex.z, vertex.z);
		maxVertex.x = MAXF(maxVertex.x, vertex.x);
		maxVertex.y = MAXF(maxVertex.y, vertex.y);
		maxVertex.z = MAXF(maxVertex.z, vertex.z);
	}
	return norm(maxVertex - minVertex);
}

bool ValidateRefinedMesh(const Scene& scene, size_t minVertices, size_t minFaces, float initialDiagonal)
{
	if (scene.mesh.vertices.GetSize() < minVertices || scene.mesh.faces.GetSize() < minFaces) {
		std::fprintf(stderr, "Metal refine sample mesh too small: vertices=%zu faces=%zu\n",
			(size_t)scene.mesh.vertices.GetSize(), (size_t)scene.mesh.faces.GetSize());
		return false;
	}
	FOREACH(idxVertex, scene.mesh.vertices) {
		if (IsFiniteVertex(scene.mesh.vertices[idxVertex]))
			continue;
		std::fprintf(stderr, "Metal refine sample produced a non-finite vertex at %zu\n", (size_t)idxVertex);
		return false;
	}
	const float refinedDiagonal(MeshDiagonal(scene.mesh.vertices));
	if (!(refinedDiagonal > 0.f) || refinedDiagonal > MAXF(initialDiagonal * 2.5f, 1.f)) {
		std::fprintf(stderr, "Metal refine sample bounding box changed unexpectedly: initial=%.6f refined=%.6f\n",
			initialDiagonal, refinedDiagonal);
		return false;
	}
	return true;
}

double MeanVertexDistance(const Mesh::VertexArr& lhs, const Mesh::VertexArr& rhs)
{
	if (lhs.GetSize() != rhs.GetSize() || lhs.IsEmpty())
		return std::numeric_limits<double>::infinity();
	double distanceSum(0);
	FOREACH(idxVertex, lhs)
		distanceSum += norm(lhs[idxVertex] - rhs[idxVertex]);
	return distanceSum / (double)lhs.GetSize();
}

} // namespace

bool DenseReconstructionMetalParityTest()
{
	TD_TIMER_START();
	Scene cpuScene(TEST_MAX_THREADS);
	Scene metalScene(TEST_MAX_THREADS);
	DenseSummary cpu;
	DenseSummary metal;
	std::vector<DepthMapSnapshot> cpuDepthMaps;
	std::vector<DepthMapSnapshot> metalDepthMaps;
	if (!RunDenseSampleBackend("cpu", cpuScene, cpu, cpuDepthMaps))
		return false;
	if (!RunDenseSampleBackend("metal", metalScene, metal, metalDepthMaps))
		return false;
	if (!CompareDenseSummaries(cpu, metal))
		return false;
	if (!CompareDepthMapSnapshots(cpuDepthMaps, metalDepthMaps))
		return false;
	const float centerDistance(norm(metal.robustCenter - cpu.robustCenter));
	VERBOSE("Metal DenseReconstruction parity passed (%s): cpuPoints=%zu metalPoints=%zu cpuDiag=%.6f metalDiag=%.6f cpuRobustDiag=%.6f metalRobustDiag=%.6f robustCenterDist=%.6f",
		TD_TIMER_GET_FMT().c_str(), cpu.points, metal.points, cpu.diagonal, metal.diagonal,
		cpu.robustDiagonal, metal.robustDiagonal, centerDistance);
	return true;
}
/*----------------------------------------------------------------*/

bool RefineMeshMetalSampleTest()
{
	TD_TIMER_START();
	SEACAVE::GPU::desiredBackend = "metal";
	Scene scene(TEST_MAX_THREADS);
	if (!scene.Load(MAKE_PATH("scene.mvs"))) {
		VERBOSE("ERROR: MetalRefineSample failed loading the scene!");
		return false;
	}
	OPTDENSE::init();
	OPTDENSE::bRemoveDmaps = true;
	OPTDENSE::nPatchMatchCUDAInstances = TEST_MAX_THREADS;
	if (!scene.DenseReconstruction() || scene.pointcloud.GetSize() < 50000u) {
		std::fprintf(stderr, "Metal refine sample dense stage: points=%zu\n", (size_t)scene.pointcloud.GetSize());
		VERBOSE("ERROR: MetalRefineSample failed estimating dense point-cloud!");
		return false;
	}
	if (!scene.ReconstructMesh() || scene.mesh.faces.GetSize() < 25000u) {
		std::fprintf(stderr, "Metal refine sample mesh stage: faces=%zu vertices=%zu\n",
			(size_t)scene.mesh.faces.GetSize(), (size_t)scene.mesh.vertices.GetSize());
		VERBOSE("ERROR: MetalRefineSample failed reconstructing the initial mesh!");
		return false;
	}

	const size_t initialVertices(scene.mesh.vertices.GetSize());
	const size_t initialFaces(scene.mesh.faces.GetSize());
	const float initialDiagonal(MeshDiagonal(scene.mesh.vertices));
	if (!ValidateRefinedMesh(scene, initialVertices / 2u, initialFaces / 2u, initialDiagonal))
		return false;

	Scene cpuScene(scene);
	Scene metalScene(scene);

	if (!cpuScene.RefineMesh(
			1, 320, 2,
			1.f, 0, 0, 0,
			1, 1.f, 2,
			0.2f, 0.9f, 1.01f,
			0.f, 1))
	{
		VERBOSE("ERROR: MetalRefineSample failed refining the CPU reference mesh!");
		return false;
	}
	if (!ValidateRefinedMesh(cpuScene, initialVertices / 2u, initialFaces / 2u, initialDiagonal))
		return false;

	if (!metalScene.RefineMeshMetal(
			1, 320, 2,
			1.f, 0, 0, 0,
			1, 1.f, 2,
			0.2f, 0.9f, 1.01f))
	{
		VERBOSE("ERROR: MetalRefineSample failed refining the mesh with Metal!");
		return false;
	}
	if (!ValidateRefinedMesh(metalScene, initialVertices / 2u, initialFaces / 2u, initialDiagonal))
		return false;

	if (metalScene.mesh.vertices.GetSize() == scene.mesh.vertices.GetSize()) {
		const double metalDisplacement(MeanVertexDistance(metalScene.mesh.vertices, scene.mesh.vertices));
		if (!(metalDisplacement > 1e-7) || metalDisplacement > (double)MAXF(initialDiagonal, 1.f)) {
			std::fprintf(stderr, "Metal refine sample displacement outside expected range: mean=%.9f diagonal=%.6f\n",
				metalDisplacement, initialDiagonal);
			return false;
		}
	}
	if (metalScene.mesh.vertices.GetSize() == cpuScene.mesh.vertices.GetSize()) {
		const double cpuMetalDistance(MeanVertexDistance(metalScene.mesh.vertices, cpuScene.mesh.vertices));
		if (!(cpuMetalDistance >= 0.0) || cpuMetalDistance > (double)MAXF(initialDiagonal * 0.35f, 0.01f)) {
			std::fprintf(stderr, "Metal refine sample diverged from CPU reference: mean=%.9f diagonal=%.6f\n",
				cpuMetalDistance, initialDiagonal);
			return false;
		}
	}

	VERBOSE("Metal RefineMesh sample passed (%s)", TD_TIMER_GET_FMT().c_str());
	return true;
}
/*----------------------------------------------------------------*/
#endif

} // namespace MVS
