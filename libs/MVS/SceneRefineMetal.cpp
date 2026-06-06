/*
* SceneRefineMetal.cpp
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
#include "Scene.h"
#include "SceneRefineMetal.h"
#include "../Common/UtilMetal.h"

#ifdef _USE_METAL

#include <cmath>
#include <limits>
#include <unordered_set>
#include <vector>

using namespace MVS;

namespace MVS {
namespace METAL {
bool RunRefineMeshHostSmokeImpl(std::string* error);
} // namespace METAL
} // namespace MVS


// D E F I N E S ///////////////////////////////////////////////////

// uncomment to ensure edge size and improve vertex valence
// (should enable more stable flow)
#define MESHOPT_ENSUREEDGESIZE 1 // 0 - at all resolution
// Reprojecting every gradient step dominates small Metal refinement runs.
// The gradient step is deliberately small, so reuse visibility maps within
// one short optimization batch and refresh them at the next batch boundary.
#define MESHOPT_METAL_PROJECT_INTERVAL 8u


// S T R U C T S ///////////////////////////////////////////////////

namespace {

typedef Mesh::Vertex Vertex;
typedef Mesh::VIndex VIndex;
typedef Mesh::Face Face;
typedef Mesh::FIndex FIndex;

MVS::METAL::Camera MakeMetalCamera(const Camera& camera, const Image8U::Size& size)
{
	MVS::METAL::Camera metalCamera = {};
	metalCamera.model.f = {(float)camera.K(0,0), (float)camera.K(1,1)};
	metalCamera.model.p = {(float)camera.K(0,2), (float)camera.K(1,2)};
	for (int r = 0; r < 3; ++r)
		for (int c = 0; c < 3; ++c)
			metalCamera.pose.R.m[r*3 + c] = (float)camera.R(r,c);
	metalCamera.pose.C = {(float)camera.C.x, (float)camera.C.y, (float)camera.C.z};
	metalCamera.size = {size.width, size.height};
	return metalCamera;
}

MVS::METAL::Point3 ToMetalPoint(const Vertex& p)
{
	return {(float)p.x, (float)p.y, (float)p.z};
}

class MeshRefineMetal {
public:
	typedef Mesh::FaceIdxArr CameraFaces;
	typedef CLISTDEF2(CameraFaces) CameraFacesArr;

	struct View {
		Image32F image;
		Image8U::Size size;
		MVS::METAL::Camera camera = {};
		std::vector<float> depthMap;
		std::vector<uint32_t> faceMap;
		std::vector<uint16_t> baryMap;
	};

	MeshRefineMetal(Scene& _scene, unsigned _nAlternatePair, float _weightRegularity, float _ratioRigidityElasticity, unsigned _nResolutionLevel, unsigned _nMinResolution, unsigned nMaxViews);
	~MeshRefineMetal();

	bool IsValid() const { return !pairs.IsEmpty(); }
	bool InitImages(float scale, float sigma=0);

	void ListVertexFacesPre();
	void ListVertexFacesPost();
	void ListCameraFaces();
	void ListFaceAreas(Mesh::AreaArr& maxAreas);
	void SubdivideMesh(uint32_t maxArea, float fDecimate=1.f, unsigned nCloseHoles=15, unsigned nEnsureEdgeSize=1);
	bool ScoreMesh(float* gradients);
	void RefreshMeshBuffers();

private:
	bool ComputeNormalFaces();
	bool ProjectMesh(const CameraFaces& cameraFaces, const Camera& camera, const Image8U::Size& size, uint32_t idxImage);
	bool ProcessPair(uint32_t idxImageA, uint32_t idxImageB, bool resetAccumulation, bool downloadAccumulation);
	bool ComputeSmoothnessGradient(uint32_t numVertices);
	bool CombineGradients(uint32_t numVertices);

public:
	const float weightRegularity;
	float ratioRigidityElasticity;
	const unsigned nResolutionLevel;
	const unsigned nMinResolution;
	unsigned nAlternatePair;
	unsigned iteration = 0;

	Scene& scene;
	ImageArr& images;
	std::vector<View> views;
	PairIdxArr pairs;

	std::vector<MVS::METAL::Point3> verticesMetal;
	std::vector<MVS::METAL::Point3u> facesMetal;
	std::vector<MVS::METAL::Point3> faceNormals;

	std::vector<uint32_t> vertexVerticesCont;
	std::vector<uint32_t> vertexVerticesSizes;
	std::vector<uint32_t> vertexVerticesPointers;
	std::vector<MVS::METAL::Point3> photoGrad;
	std::vector<float> photoGradNorm;
	std::vector<MVS::METAL::Point3> smoothGrad1;
	std::vector<MVS::METAL::Point3> smoothGrad2;

	enum { HalfSize = 2 };
};

MeshRefineMetal::MeshRefineMetal(Scene& _scene, unsigned _nAlternatePair, float _weightRegularity, float _ratioRigidityElasticity, unsigned _nResolutionLevel, unsigned _nMinResolution, unsigned nMaxViews)
	:
	weightRegularity(_weightRegularity),
	ratioRigidityElasticity(_ratioRigidityElasticity),
	nResolutionLevel(_nResolutionLevel),
	nMinResolution(_nMinResolution),
	nAlternatePair(_nAlternatePair),
	scene(_scene),
	images(_scene.images)
{
	std::unordered_set<uint64_t> mapPairs;
	mapPairs.reserve(images.GetSize()*nMaxViews);
	FOREACH(idxImage, images) {
		const Image& imageData = images[idxImage];
		if (!imageData.IsValid())
			continue;
		const float fMinArea(0.1f);
		const float fMinScale(0.2f), fMaxScale(3.2f);
		const float fMinAngle(FD2R(2.5f)), fMaxAngle(FD2R(45.f));
		ViewScoreArr neighbors(imageData.neighbors);
		Scene::FilterNeighborViews(neighbors, fMinArea, fMinScale, fMaxScale, fMinAngle, fMaxAngle, nMaxViews);
		for (const ViewScore& neighbor: neighbors) {
			ASSERT(images[neighbor.ID].IsValid());
			mapPairs.insert(MakePairIdx((uint32_t)idxImage, neighbor.ID));
		}
	}
	pairs.Reserve(mapPairs.size());
	for (uint64_t pair: mapPairs)
		pairs.AddConstruct(pair);
}

MeshRefineMetal::~MeshRefineMetal()
{
	scene.mesh.ReleaseExtra();
}

bool MeshRefineMetal::InitImages(float scale, float sigma)
{
	views.resize(images.GetSize());
	FOREACH(idxImage, images) {
		Image& imageData = images[idxImage];
		if (!imageData.IsValid())
			continue;
		unsigned level(nResolutionLevel);
		const unsigned imageSize(imageData.RecomputeMaxResolution(level, nMinResolution));
		if ((imageData.image.empty() || MAXF(imageData.width,imageData.height) != imageSize) && !imageData.ReloadImage(imageSize))
			return false;
		View& view = views[idxImage];
		imageData.image.toGray(view.image, cv::COLOR_BGR2GRAY, true);
		imageData.image.release();
		if (sigma > 0)
			cv::GaussianBlur(view.image, view.image, cv::Size(), sigma);
		if (scale < 1.0f) {
			cv::resize(view.image, view.image, cv::Size(), scale, scale, cv::INTER_AREA);
			imageData.width = view.image.width();
			imageData.height = view.image.height();
		}
		imageData.UpdateCamera(scene.platforms);
		view.size = view.image.size();
		view.camera = MakeMetalCamera(imageData.camera, view.size);
		const size_t area((size_t)view.size.area());
		view.depthMap.assign(area, 0.f);
		view.faceMap.assign(area, NO_ID);
		view.baryMap.assign(area*3u, 0);
	}
	iteration = 0;
	return true;
}

void MeshRefineMetal::RefreshMeshBuffers()
{
	verticesMetal.resize(scene.mesh.vertices.GetSize());
	FOREACH(i, scene.mesh.vertices)
		verticesMetal[i] = ToMetalPoint(scene.mesh.vertices[i]);
	facesMetal.resize(scene.mesh.faces.GetSize());
	FOREACH(i, scene.mesh.faces) {
		const Face& face = scene.mesh.faces[i];
		facesMetal[i] = {(uint32_t)face.x, (uint32_t)face.y, (uint32_t)face.z};
	}
}

void MeshRefineMetal::ListVertexFacesPre()
{
	scene.mesh.EmptyExtra();
	scene.mesh.ListIncidentFaces();
	RefreshMeshBuffers();
}

void MeshRefineMetal::ListVertexFacesPost()
{
	scene.mesh.ListIncidentVertices();
	scene.mesh.ListBoundaryVertices();
	ASSERT(!scene.mesh.vertices.IsEmpty() && scene.mesh.vertices.GetSize() == scene.mesh.vertexVertices.GetSize());
	const size_t numVertices(scene.mesh.vertices.GetSize());
	vertexVerticesCont.clear();
	vertexVerticesSizes.resize(numVertices);
	vertexVerticesPointers.resize(numVertices);
	vertexVerticesCont.reserve(numVertices*6);
	for (size_t idxV = 0; idxV < numVertices; ++idxV) {
		vertexVerticesPointers[idxV] = (uint32_t)vertexVerticesCont.size();
		if (scene.mesh.vertexBoundary[idxV]) {
			vertexVerticesSizes[idxV] = 0;
			continue;
		}
		const Mesh::VertexIdxArr& verts = scene.mesh.vertexVertices[idxV];
		vertexVerticesSizes[idxV] = (uint32_t)verts.GetSize();
		for (uint32_t i = 0; i < verts.GetSize(); ++i)
			vertexVerticesCont.push_back((uint32_t)verts[i]);
	}
	photoGrad.assign(numVertices, {0.f, 0.f, 0.f});
	photoGradNorm.assign(numVertices, 0.f);
	smoothGrad1.assign(numVertices, {0.f, 0.f, 0.f});
	smoothGrad2.assign(numVertices, {0.f, 0.f, 0.f});
	RefreshMeshBuffers();
}

void MeshRefineMetal::ListCameraFaces()
{
	CameraFacesArr arrCameraFaces(images.GetSize()); {
		Mesh::Octree octree;
		Mesh::FacesInserter::CreateOctree(octree, scene.mesh);
		FOREACH(ID, images) {
			const Image& imageData = images[ID];
			if (!imageData.IsValid())
				continue;
			const TFrustum<float,5> frustum(Matrix3x4f(imageData.camera.P), (float)imageData.width, (float)imageData.height);
			Mesh::FacesInserter inserter(arrCameraFaces[ID]);
			octree.Traverse(frustum, inserter);
		}
	}
	RefreshMeshBuffers();
	FOREACH(idxImage, images) {
		const Image& imageData = images[idxImage];
		if (imageData.IsValid())
			ProjectMesh(arrCameraFaces[idxImage], imageData.camera, views[idxImage].size, (uint32_t)idxImage);
	}
}

void MeshRefineMetal::ListFaceAreas(Mesh::AreaArr& maxAreas)
{
	ASSERT(maxAreas.IsEmpty());
	typedef cList<Mesh::AreaArr> ImageAreaArr;
	ImageAreaArr viewAreas(images.GetSize());
	FOREACH(idxImage, images) {
		const Image& imageData = images[idxImage];
		if (!imageData.IsValid())
			continue;
		Mesh::AreaArr& areas = viewAreas[idxImage];
		areas.Resize(scene.mesh.faces.GetSize());
		areas.Memset(0);
		const View& view = views[idxImage];
		for (uint32_t faceID : view.faceMap) {
			if (faceID != NO_ID)
				++areas[faceID];
		}
	}
	maxAreas.Resize(scene.mesh.faces.GetSize());
	maxAreas.Memset(0);
	FOREACHPTR(pPair, pairs) {
		const Mesh::AreaArr& areasA = viewAreas[pPair->i];
		const Mesh::AreaArr& areasB = viewAreas[pPair->j];
		ASSERT(areasA.GetSize() == areasB.GetSize());
		FOREACH(f, areasA) {
			const uint16_t minArea(MINF(areasA[f], areasB[f]));
			uint16_t& maxArea = maxAreas[f];
			if (maxArea < minArea)
				maxArea = minArea;
		}
	}
}

void MeshRefineMetal::SubdivideMesh(uint32_t maxArea, float fDecimate, unsigned nCloseHoles, unsigned nEnsureEdgeSize)
{
	Mesh::AreaArr maxAreas;
	const bool bNoDecimation(fDecimate >= 1.f);
	const bool bNoSimplification(maxArea == 0);
	if (!bNoDecimation) {
		if (fDecimate > 0.f) {
			scene.mesh.Clean(fDecimate, 0.f, false, nCloseHoles, 0u, 0.f);
			#ifdef MESHOPT_ENSUREEDGESIZE
			if (nEnsureEdgeSize > 0 && bNoSimplification) {
				scene.mesh.EnsureEdgeSize();
				scene.mesh.Clean(1.f, 0.f, false, nCloseHoles, 0u, 0.f);
			}
			#endif
			ListVertexFacesPre();
		} else {
			ListCameraFaces();
			ListFaceAreas(maxAreas);
			ASSERT(!maxAreas.IsEmpty());
			const float maxAreaf((float)(maxArea > 0 ? maxArea : 64));
			const float medianArea(6.f*(float)Mesh::AreaArr(maxAreas).GetMedian());
			if (medianArea < maxAreaf) {
				maxAreas.Empty();
				scene.mesh.Clean(MAXF(0.1f, medianArea/maxAreaf), 0.f, false, nCloseHoles, 0u, 0.f);
				#ifdef MESHOPT_ENSUREEDGESIZE
				if (nEnsureEdgeSize > 0 && bNoSimplification) {
					scene.mesh.EnsureEdgeSize();
					scene.mesh.Clean(1.f, 0.f, false, nCloseHoles, 0u, 0.f);
				}
				#endif
				ListVertexFacesPre();
			}
		}
	}
	if (bNoSimplification)
		return;
	if (maxAreas.IsEmpty()) {
		ListCameraFaces();
		ListFaceAreas(maxAreas);
	}
	const size_t numVertsOld(scene.mesh.vertices.GetSize());
	const size_t numFacesOld(scene.mesh.faces.GetSize());
	scene.mesh.Subdivide(maxAreas, maxArea);
	#ifdef MESHOPT_ENSUREEDGESIZE
	#if MESHOPT_ENSUREEDGESIZE==1
	if ((nEnsureEdgeSize == 1 && !bNoDecimation) || nEnsureEdgeSize > 1)
	#endif
	{
		scene.mesh.EnsureEdgeSize();
		scene.mesh.Clean(1.f, 0.f, false, nCloseHoles, 0u, 0.f);
	}
	#endif
	ListVertexFacesPre();
	DEBUG_EXTRA("Mesh subdivided: %u/%u -> %u/%u vertices/faces", numVertsOld, numFacesOld, scene.mesh.vertices.GetSize(), scene.mesh.faces.GetSize());
}

bool MeshRefineMetal::ProjectMesh(const CameraFaces& cameraFaces, const Camera& camera, const Image8U::Size& size, uint32_t idxImage)
{
	if (cameraFaces.IsEmpty())
		return true;
	View& view = views[idxImage];
	view.size = size;
	view.camera = MakeMetalCamera(camera, size);
	const size_t area((size_t)size.area());
	view.depthMap.assign(area, std::numeric_limits<float>::max());
	view.faceMap.assign(area, NO_ID);
	view.baryMap.assign(area*3u, 0);
	std::vector<uint32_t> faceIDs;
	faceIDs.reserve(cameraFaces.GetSize());
	for (FIndex idxFace : cameraFaces)
		faceIDs.push_back((uint32_t)idxFace);
	std::string error;
	if (!MVS::METAL::LaunchProjectMeshAndCrossCheck(verticesMetal.data(), facesMetal.data(), faceIDs.data(), view.depthMap.data(), view.faceMap.data(), view.baryMap.data(), view.camera, (uint32_t)faceIDs.size(), &error)) {
		VERBOSE("Metal ProjectMesh/CrossCheck failed: %s", error.c_str());
		return false;
	}
	return true;
}

bool MeshRefineMetal::ComputeNormalFaces()
{
	faceNormals.assign(scene.mesh.faces.GetSize(), {0.f, 0.f, 0.f});
	if (faceNormals.empty())
		return true;
	std::string error;
	if (!MVS::METAL::LaunchComputeFaceNormal(verticesMetal.data(), facesMetal.data(), faceNormals.data(), (uint32_t)faceNormals.size(), &error)) {
		VERBOSE("Metal ComputeFaceNormal failed: %s", error.c_str());
		return false;
	}
	return true;
}

bool MeshRefineMetal::ProcessPair(uint32_t idxImageA, uint32_t idxImageB, bool resetAccumulation, bool downloadAccumulation)
{
	const Image& imageDataA = images[idxImageA];
	const Image& imageDataB = images[idxImageB];
	ASSERT(imageDataA.IsValid() && imageDataB.IsValid());
	const View& viewA = views[idxImageA];
	const View& viewB = views[idxImageB];
	std::string error;
	const float regularizationScale((float)((REAL)(imageDataA.avgDepth*imageDataB.avgDepth)/(imageDataA.camera.GetFocalLength()*imageDataB.camera.GetFocalLength())));
	if (!MVS::METAL::LaunchPairPhotometricGradient(
			facesMetal.data(), faceNormals.data(),
			viewA.depthMap.data(), viewB.depthMap.data(), viewA.faceMap.data(), viewA.baryMap.data(),
			viewA.image.ptr<float>(), viewB.image.ptr<float>(), photoGrad.data(), photoGradNorm.data(),
			viewA.camera, viewB.camera, (uint32_t)facesMetal.size(), (uint32_t)verticesMetal.size(),
			regularizationScale, HalfSize, resetAccumulation, downloadAccumulation, &error))
	{
		VERBOSE("Metal photometric gradient failed: %s", error.c_str());
		return false;
	}
	return true;
}

bool MeshRefineMetal::ComputeSmoothnessGradient(uint32_t numVertices)
{
	if (numVertices == 0)
		return true;
	std::string error;
	if (!MVS::METAL::LaunchComputeSmoothnessGradient(verticesMetal.data(), vertexVerticesCont.data(), vertexVerticesSizes.data(), vertexVerticesPointers.data(), smoothGrad1.data(), numVertices, 0, &error) ||
		!MVS::METAL::LaunchComputeSmoothnessGradient(smoothGrad1.data(), vertexVerticesCont.data(), vertexVerticesSizes.data(), vertexVerticesPointers.data(), smoothGrad2.data(), numVertices, 1, &error))
	{
		VERBOSE("Metal smoothness gradient failed: %s", error.c_str());
		return false;
	}
	return true;
}

bool MeshRefineMetal::CombineGradients(uint32_t numVertices)
{
	std::string error;
	if (ratioRigidityElasticity >= 1.f) {
		if (!MVS::METAL::LaunchCombineGradients(photoGrad.data(), photoGradNorm.data(), smoothGrad2.data(), numVertices, weightRegularity, &error)) {
			VERBOSE("Metal gradient combine failed: %s", error.c_str());
			return false;
		}
	} else {
		const float rigidity((1.f-ratioRigidityElasticity)*weightRegularity);
		const float elasticity(ratioRigidityElasticity*weightRegularity);
		if (!MVS::METAL::LaunchCombineAllGradients(photoGrad.data(), photoGradNorm.data(), smoothGrad1.data(), smoothGrad2.data(), numVertices, rigidity, elasticity, &error)) {
			VERBOSE("Metal gradient combine failed: %s", error.c_str());
			return false;
		}
	}
	return true;
}

bool MeshRefineMetal::ScoreMesh(float* gradients)
{
	if (iteration == 0 || (iteration % MESHOPT_METAL_PROJECT_INTERVAL) == 0)
		ListCameraFaces();
	else
		RefreshMeshBuffers();
	if (!ComputeNormalFaces())
		return false;
	const uint32_t numVertices((uint32_t)verticesMetal.size());
	std::fill(photoGrad.begin(), photoGrad.end(), MVS::METAL::Point3{0.f, 0.f, 0.f});
	std::fill(photoGradNorm.begin(), photoGradNorm.end(), 0.f);
	std::vector<PairIdx> activePairs;
	activePairs.reserve(pairs.GetSize()*2u);
	FOREACHPTR(pPair, pairs) {
		ASSERT(pPair->i < pPair->j);
		switch (nAlternatePair) {
		case 1: {
			const PairIdx pair(iteration%2 ? PairIdx(pPair->j,pPair->i) : PairIdx(pPair->i,pPair->j));
			activePairs.emplace_back(pair);
			break; }
		case 2:
			activePairs.emplace_back(pPair->i, pPair->j);
			break;
		case 3:
			activePairs.emplace_back(pPair->j, pPair->i);
			break;
		default:
			activePairs.emplace_back(pPair->i, pPair->j);
			activePairs.emplace_back(pPair->j, pPair->i);
		}
	}
	FOREACH(idxPair, activePairs) {
		const bool resetAccumulation(idxPair == 0);
		const bool downloadAccumulation(idxPair + 1 == activePairs.size());
		const PairIdx& pair(activePairs[idxPair]);
		if (!ProcessPair(pair.i, pair.j, resetAccumulation, downloadAccumulation))
			return false;
	}
	const float rigidity(ratioRigidityElasticity >= 1.f ? 0.f : (1.f-ratioRigidityElasticity)*weightRegularity);
	const float elasticity(ratioRigidityElasticity >= 1.f ? weightRegularity : ratioRigidityElasticity*weightRegularity);
	std::string error;
	if (!MVS::METAL::LaunchSmoothnessAndCombineGradients(
			verticesMetal.data(), vertexVerticesCont.data(), vertexVerticesSizes.data(), vertexVerticesPointers.data(),
			photoGrad.data(), photoGradNorm.data(), numVertices, rigidity, elasticity, &error))
	{
		VERBOSE("Metal smoothness/gradient combine failed: %s", error.c_str());
		return false;
	}
	for (uint32_t i = 0; i < numVertices; ++i) {
		gradients[i*3 + 0] = photoGrad[i].x;
		gradients[i*3 + 1] = photoGrad[i].y;
		gradients[i*3 + 2] = photoGrad[i].z;
	}
	return true;
}

} // namespace

// optimize mesh using Metal photo-consistency
bool Scene::RefineMeshMetal(unsigned nResolutionLevel, unsigned nMinResolution, unsigned nMaxViews,
							float fDecimateMesh, unsigned nCloseHoles, unsigned nEnsureEdgeSize, unsigned nMaxFaceArea,
							unsigned nScales, float fScaleStep, unsigned nAlternatePair, float fRegularityWeight, float fRatioRigidityElasticity, float fGradientStep)
{
	SEACAVE::METAL::Device device;
	if (!SEACAVE::METAL::getDefaultDevice(device)) {
		VERBOSE("Metal mesh refinement unavailable: no default Metal device");
		return false;
	}
	bool bGeneratedPointcloud(false);
	if (pointcloud.IsEmpty() && !ImagesHaveNeighbors()) {
		SampleMeshWithVisibility();
		bGeneratedPointcloud = true;
	}
	MeshRefineMetal refine(*this, nAlternatePair, fRegularityWeight, fRatioRigidityElasticity, nResolutionLevel, nMinResolution, nMaxViews);
	if (bGeneratedPointcloud)
		pointcloud.Release();
	if (!refine.IsValid())
		return false;

	VERBOSE("Metal mesh refinement backend active on device %s", device.name.c_str());
	for (unsigned nScale=0; nScale<nScales; ++nScale) {
		const float scale(POWI(fScaleStep, nScales-nScale-1));
		const float step(POWI(2.f, nScales-nScale));
		DEBUG_ULTIMATE("Refine mesh at: %.2f image scale", scale);
		if (!refine.InitImages(scale, 0.12f*step+0.2f))
			return false;
		refine.ListVertexFacesPre();
		refine.SubdivideMesh(nMaxFaceArea, nScale == 0 ? fDecimateMesh : 1.f, nCloseHoles, nEnsureEdgeSize);
		refine.ListVertexFacesPost();

		int iters(25);
		float gstep(0.05f);
		if (fGradientStep > 1) {
			iters = FLOOR2INT(fGradientStep);
			gstep = (fGradientStep-(float)iters)*10;
		}
		iters = MAXF(iters/(int)(nScale+1),8);
		const int iterStop(iters*7/10);
		Eigen::Matrix<float,Eigen::Dynamic,3,Eigen::RowMajor> gradients(mesh.vertices.GetSize(),3);
		Util::Progress progress(_T("Processed iterations"), iters);
		GET_LOGCONSOLE().Pause();
		for (int iter=0; iter<iters; ++iter) {
			refine.iteration = (unsigned)iter;
			refine.nAlternatePair = (iter+1 < iters ? nAlternatePair : 0);
			refine.ratioRigidityElasticity = (iter <= iterStop ? fRatioRigidityElasticity : 1.f);
			if (!refine.ScoreMesh(gradients.data())) {
				GET_LOGCONSOLE().Play();
				progress.close();
				return false;
			}
			float gv(0);
			FOREACH(v, mesh.vertices) {
				Vertex& vert = mesh.vertices[v];
				const Point3f grad(gradients.row(v));
				if (!ISFINITE(grad))
					continue;
				vert -= Vertex(grad*gstep);
				gv += norm(grad);
			}
			refine.RefreshMeshBuffers();
			DEBUG_EXTRA("\t%2d. g: %.5f (%.3e - %.3e)\ts: %.3f", iter+1, gradients.norm(), gradients.norm()/mesh.vertices.GetSize(), gv/mesh.vertices.GetSize(), gstep);
			gstep *= 0.98f;
			progress.display(iter);
		}
		GET_LOGCONSOLE().Play();
		progress.close();
	}
	return true;
} // RefineMeshMetal
/*----------------------------------------------------------------*/

bool MVS::METAL::RunRefineMeshHostSmokeImpl(std::string* error)
{
	constexpr uint32_t width = 64;
	constexpr uint32_t height = 64;

	Scene scene;
	scene.nCalibratedImages = 2;

	Platform& platform = scene.platforms.AddEmpty();
	platform.name = _T("metal-host-smoke");
	platform.cameras.emplace_back(CameraIntern::ComposeK<REAL,REAL>(REAL(1.1), REAL(1.1)), RMatrix::IDENTITY, CMatrix::ZERO);
	platform.poses.emplace_back(Platform::Pose{RMatrix::IDENTITY, CMatrix::ZERO});
	platform.poses.emplace_back(Platform::Pose{RMatrix::IDENTITY, CMatrix(REAL(0.08), REAL(0), REAL(0))});

	for (uint32_t idxImage = 0; idxImage < 2; ++idxImage) {
		Image& image = scene.images.AddEmpty();
		image.platformID = 0;
		image.cameraID = 0;
		image.poseID = idxImage;
		image.ID = idxImage;
		image.width = width;
		image.height = height;
		image.scale = 1.f;
		image.avgDepth = 2.f;
		image.image = Image8U3(cv::Size(width, height));
		for (uint32_t y = 0; y < height; ++y) {
			for (uint32_t x = 0; x < width; ++x) {
				const uint8_t value = (uint8_t)CLAMP((int)x*3 + (int)y*2 + (int)idxImage*5, 0, 255);
				image.image((int)y, (int)x) = Pixel8U(value, value, value);
			}
		}
		image.neighbors.emplace_back(ViewScore{1u-idxImage, 12u, 1.f, FD2R(15.f), 0.6f, 10.f});
		image.UpdateCamera(scene.platforms);
	}

	scene.mesh.vertices.emplace_back(Vertex(-0.55f, -0.55f, 2.f));
	scene.mesh.vertices.emplace_back(Vertex( 0.55f, -0.55f, 2.f));
	scene.mesh.vertices.emplace_back(Vertex( 0.55f,  0.55f, 2.f));
	scene.mesh.vertices.emplace_back(Vertex(-0.55f,  0.55f, 2.f));
	scene.mesh.faces.emplace_back(Face(0, 1, 2));
	scene.mesh.faces.emplace_back(Face(0, 2, 3));

	if (!scene.RefineMeshMetal(0, width, 2, 1.f, 0, 0, 0, 1, 1.f, 0, 0.25f, 0.8f, 1.01f)) {
		if (error)
			*error = "Scene::RefineMeshMetal returned false";
		return false;
	}
	if (scene.mesh.vertices.IsEmpty() || scene.mesh.faces.IsEmpty()) {
		if (error)
			*error = "Scene::RefineMeshMetal produced an empty synthetic mesh";
		return false;
	}
	FOREACH(idxVertex, scene.mesh.vertices) {
		if (ISFINITE(scene.mesh.vertices[idxVertex]))
			continue;
		if (error)
			*error = "Scene::RefineMeshMetal produced a non-finite synthetic vertex";
		return false;
	}
	return true;
}
/*----------------------------------------------------------------*/

#endif // _USE_METAL
