/*
* PatchMatchMetal.metal
*
* Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
* Codex sign-off: OpenAI Codex assisted with this file.
*
* Canonical PatchMatch Metal shader source. CMake embeds this file into
* PatchMatchMetal.mm's runtime shader string and CTest compiles it with the
* offline Metal compiler.
*/

#include <metal_stdlib>
using namespace metal;
using Point2 = packed_float2;
using Point3 = packed_float3;
using Point4 = packed_float4;
using Point2i = packed_int2;
struct Matrix3 { float m[9]; };
struct LinearCameraModel { Point2 f; Point2 p; };
struct Pose { Matrix3 R; Point3 C; };
struct Camera { LinearCameraModel model; Pose pose; Point2i size; };
struct RefPatchCache {
    float weight[25];
    float weightRefPix[25];
    float sumRef;
    float bilateralWeightSum;
    float varRef;
};
#define kMaxViews 32u
#define kNumSamples 32u
#define kBadCost 1.2f
inline float2 LoadPoint2(const Point2 p) { return float2(p[0], p[1]); }
inline float3 LoadPoint3(const Point3 p) { return float3(p[0], p[1], p[2]); }
inline int2 LoadPoint2i(const Point2i p) { return int2(p[0], p[1]); }
inline float4 LoadPoint4(const Point4 p) { return float4(p[0], p[1], p[2], p[3]); }
inline float3 Mul(const Matrix3 M, const float3 v) {
    return float3(M.m[0]*v.x + M.m[1]*v.y + M.m[2]*v.z,
                  M.m[3]*v.x + M.m[4]*v.y + M.m[5]*v.z,
                  M.m[6]*v.x + M.m[7]*v.y + M.m[8]*v.z);
}
inline Matrix3 MatrixIdentity() { Matrix3 M; M.m[0]=1.f; M.m[1]=0.f; M.m[2]=0.f; M.m[3]=0.f; M.m[4]=1.f; M.m[5]=0.f; M.m[6]=0.f; M.m[7]=0.f; M.m[8]=1.f; return M; }
inline Matrix3 MatrixTranspose(const Matrix3 A) { Matrix3 M; M.m[0]=A.m[0]; M.m[1]=A.m[3]; M.m[2]=A.m[6]; M.m[3]=A.m[1]; M.m[4]=A.m[4]; M.m[5]=A.m[7]; M.m[6]=A.m[2]; M.m[7]=A.m[5]; M.m[8]=A.m[8]; return M; }
inline Matrix3 MatrixAdd(const Matrix3 A, const Matrix3 B) { Matrix3 M; for (uint i=0; i<9; ++i) M.m[i]=A.m[i]+B.m[i]; return M; }
inline Matrix3 MatrixScale(const Matrix3 A, const float s) { Matrix3 M; for (uint i=0; i<9; ++i) M.m[i]=A.m[i]*s; return M; }
inline Matrix3 MatrixMul(const Matrix3 A, const Matrix3 B) {
    Matrix3 M;
    for (uint r=0; r<3; ++r) for (uint c=0; c<3; ++c) M.m[r*3+c] = A.m[r*3+0]*B.m[c+0] + A.m[r*3+1]*B.m[c+3] + A.m[r*3+2]*B.m[c+6];
    return M;
}
inline Matrix3 MatrixOuter(const float3 a, const float3 b) {
    Matrix3 M;
    M.m[0]=a.x*b.x; M.m[1]=a.x*b.y; M.m[2]=a.x*b.z;
    M.m[3]=a.y*b.x; M.m[4]=a.y*b.y; M.m[5]=a.y*b.z;
    M.m[6]=a.z*b.x; M.m[7]=a.z*b.y; M.m[8]=a.z*b.z;
    return M;
}
inline float3 MatrixCol(const Matrix3 M, const uint c) { return float3(M.m[c], M.m[3+c], M.m[6+c]); }
inline Matrix3 CameraK(const LinearCameraModel model) {
    const float2 f = LoadPoint2(model.f); const float2 p = LoadPoint2(model.p);
    Matrix3 K = MatrixIdentity(); K.m[0]=f.x; K.m[2]=p.x; K.m[4]=f.y; K.m[5]=p.y; return K;
}
inline Matrix3 CameraInvK(const LinearCameraModel model) {
    const float2 f = LoadPoint2(model.f); const float2 p = LoadPoint2(model.p);
    Matrix3 K = MatrixIdentity(); K.m[0]=1.f/f.x; K.m[2]=-p.x/f.x; K.m[4]=1.f/f.y; K.m[5]=-p.y/f.y; return K;
}
inline float3 TransformPointI2C(const LinearCameraModel model, const float2 x, const float depth) {
    const float2 f = LoadPoint2(model.f); const float2 p = LoadPoint2(model.p);
    return float3(depth*(x.x-p.x)/f.x, depth*(x.y-p.y)/f.y, depth);
}
inline float2 TransformPointC2I(const LinearCameraModel model, const float3 X) {
    const float2 f = LoadPoint2(model.f); const float2 p = LoadPoint2(model.p);
    return float2(f.x * X.x / X.z + p.x, f.y * X.y / X.z + p.y);
}
inline float3 TransformPointW2C(const Pose pose, const float3 X) { return Mul(pose.R, X - LoadPoint3(pose.C)); }
inline float3 TransformPointC2W(const Pose pose, const float3 X) { return Mul(MatrixTranspose(pose.R), X) + LoadPoint3(pose.C); }
inline float2 TransformPointW2I(const Camera camera, const float3 X) { return TransformPointC2I(camera.model, TransformPointW2C(camera.pose, X)); }
inline float3 TransformPointI2W(const Camera camera, const float2 x, const float depth) { return TransformPointC2W(camera.pose, TransformPointI2C(camera.model, x, depth)); }
inline float SampleImageLinear(device const float* image, const int width, const int height, const float2 p) {
    const float x = clamp(p.x - 0.5f, 0.f, (float)(width - 1));
    const float y = clamp(p.y - 0.5f, 0.f, (float)(height - 1));
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
inline float ComputeBilateralWeight4(const uint idx, const float pix, const float centerPix) {
    constexpr float spatialLUT[25] = {
        0.169013f, 0.329193f, 0.411112f, 0.329193f, 0.169013f,
        0.329193f, 0.641180f, 0.800737f, 0.641180f, 0.329193f,
        0.411112f, 0.800737f, 1.000000f, 0.800737f, 0.411112f,
        0.329193f, 0.641180f, 0.800737f, 0.641180f, 0.329193f,
        0.169013f, 0.329193f, 0.411112f, 0.329193f, 0.169013f};
    constexpr float sigmaColor = -1.f / (2.f * 25.f/255.f*25.f/255.f);
    const float colorDistSq = (pix - centerPix) * (pix - centerPix);
    return spatialLUT[idx] * exp(colorDistSq * sigmaColor);
}
inline void ComputeRefPatchCache(device const float* refImage, const int width, const int height, const int2 p, thread RefPatchCache& cache) {
    const float refCenterPix = SampleImageLinear(refImage, width, height, float2((float)p.x + 0.5f, (float)p.y + 0.5f));
    float sumRef = 0.f, sumRefRef = 0.f, bws = 0.f;
    uint idx = 0;
    for (int i=-4; i<=4; i+=2) {
        for (int j=-4; j<=4; j+=2) {
            const float refPix = SampleImageLinear(refImage, width, height, float2((float)(p.x+j) + 0.5f, (float)(p.y+i) + 0.5f));
            const float w = ComputeBilateralWeight4(idx, refPix, refCenterPix);
            const float wRef = w * refPix;
            cache.weight[idx] = w;
            cache.weightRefPix[idx] = wRef;
            sumRef += wRef;
            sumRefRef += wRef * refPix;
            bws += w;
            ++idx;
        }
    }
    cache.sumRef = sumRef;
    cache.bilateralWeightSum = bws;
    cache.varRef = sumRefRef * bws - sumRef * sumRef;
}
inline Matrix3 ComputeHomography(const Camera refCamera, const Camera trgCamera, const float2 p, const float4 plane) {
    const float3 X = TransformPointI2C(refCamera.model, p, plane.w);
    const float3 normal = plane.xyz;
    const float denom = dot(normal, X);
    constexpr float eps = 1.192092896e-7f;
    const float safeDenom = fabs(denom) < eps ? (denom < 0.f ? -eps : eps) : denom;
    const float3 t = (LoadPoint3(refCamera.pose.C) - LoadPoint3(trgCamera.pose.C)) / safeDenom;
    const Matrix3 Rt = MatrixAdd(MatrixTranspose(refCamera.pose.R), MatrixOuter(t, normal));
    return MatrixMul(MatrixMul(CameraK(trgCamera.model), MatrixMul(trgCamera.pose.R, Rt)), CameraInvK(refCamera.model));
}
inline float ScorePlanePair(thread const RefPatchCache& cache, device const float* trgImage, const Camera refCamera, const Camera trgCamera, const int2 p, const float4 plane, const float lowDepth) {
    Matrix3 H = ComputeHomography(refCamera, trgCamera, float2((float)p.x, (float)p.y), plane);
    const int2 trgSize = LoadPoint2i(trgCamera.size);
    const float3 ptH = Mul(H, float3((float)p.x, (float)p.y, 1.f));
    const float invCenterZ = 1.f / ptH.z;
    const float ptX = ptH.x * invCenterZ;
    const float ptY = ptH.y * invCenterZ;
    if (ptX >= (float)trgSize.x || ptX < 0.f || ptY >= (float)trgSize.y || ptY < 0.f) return 1.2f;
    float3 X = Mul(H, float3((float)(p.x-4), (float)(p.y-4), 1.f));
    float3 baseX = X;
    H = MatrixScale(H, 2.f);
    float sumTrg = 0.f, sumTrgTrg = 0.f, sumRefTrg = 0.f;
    uint idx = 0;
    for (int i=-4; i<=4; i+=2) {
        for (int j=-4; j<=4; j+=2) {
            const float invZ = 1.f / X.z;
            const float trgPx = X.x * invZ + 0.5f;
            const float trgPy = X.y * invZ + 0.5f;
            const float trgPix = SampleImageLinear(trgImage, trgSize.x, trgSize.y, float2(trgPx, trgPy));
            const float w = cache.weight[idx];
            const float wTrg = w * trgPix;
            sumTrg += wTrg;
            sumTrgTrg += wTrg * trgPix;
            sumRefTrg += cache.weightRefPix[idx] * trgPix;
            ++idx;
            X += MatrixCol(H, 0);
        }
        baseX += MatrixCol(H, 1);
        X = baseX;
    }
    if (lowDepth <= 0.f && cache.varRef < 1e-8f) return 1.2f;
    const float varTrg = sumTrgTrg * cache.bilateralWeightSum - sumTrg * sumTrg;
    const float varRefTrg = cache.varRef * varTrg;
    if (varRefTrg < 1e-16f) return 1.2f;
    const float covarTrgRef = sumRefTrg * cache.bilateralWeightSum - cache.sumRef * sumTrg;
    float ncc = 1.f - covarTrgRef * rsqrt(varRefTrg);
    if (lowDepth > 0.f && cache.varRef < 0.0025f) {
        const float deltaDepth = min(fabs(lowDepth - plane.w) / lowDepth, 0.5f);
        constexpr float smoothSigmaDepth = -1.f / 0.02f;
        const float factorDeltaDepth = exp(cache.varRef * smoothSigmaDepth);
        ncc = (1.f - factorDeltaDepth) * ncc + factorDeltaDepth * deltaDepth;
    }
    return clamp(ncc, 0.f, 2.f);
}
inline float GeometricConsistencyWeight(device const float* depthImage, const Camera refCamera, const Camera trgCamera, const float4 plane, const int2 p) {
    constexpr float maxDist = 4.f;
    const float3 forwardPoint = TransformPointI2W(refCamera, float2((float)p.x, (float)p.y), plane.w);
    const float2 trgPt = TransformPointW2I(trgCamera, forwardPoint);
    const int2 trgSize = LoadPoint2i(trgCamera.size);
    if (trgPt.x >= (float)trgSize.x || trgPt.x < 0.f || trgPt.y >= (float)trgSize.y || trgPt.y < 0.f) return maxDist;
    const float trgDepth = SampleImageLinear(depthImage, trgSize.x, trgSize.y, trgPt + float2(0.5f, 0.5f));
    if (trgDepth == 0.f) return maxDist;
    const float3 trgX = TransformPointI2W(trgCamera, trgPt, trgDepth);
    const float2 backwardPoint = TransformPointW2I(refCamera, trgX);
    const float2 diff = float2((float)p.x, (float)p.y) - backwardPoint;
    const float distSq = dot(diff, diff);
    return min(maxDist, sqrt(distSq + sqrt(distSq) * 2.f));
}
constant float kGeometricConsistencyWeight = 0.1f;
inline void SetBit(thread uint& input, const uint i) { input |= (1u << i); }
inline bool IsBitSet(const uint input, const uint i) { return ((input >> i) & 1u) != 0u; }
inline float SquareF(const float x) { return x * x; }
inline uint HashUint(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}
inline float HashFloat(const uint x) { return (float)(HashUint(x) & 0x00ffffffu) / 16777216.f; }
inline float3 ViewDirection(const LinearCameraModel model, const int2 p) {
    return normalize(TransformPointI2C(model, float2((float)p.x, (float)p.y), 1.f));
}
inline float3 GenerateRandomNormal(const Camera camera, const int2 p, const uint idx) {
    constexpr float twoPi = 6.28318530717958647692f;
    const float z = 2.f * HashFloat(idx * 17u + 3u) - 1.f;
    const float a = twoPi * HashFloat(idx * 31u + 7u);
    const float r = sqrt(max(0.f, 1.f - z*z));
    float3 normal = float3(r * cos(a), r * sin(a), z);
    return dot(normal, ViewDirection(camera.model, p)) > 0.f ? -normal : normal;
}
inline void SortCosts(thread const float* values, thread float* sortedValues, const uint n) {
    for (uint i=0; i<n; ++i) sortedValues[i] = values[i];
    for (uint i=0; i<n; ++i) {
        for (uint j=1; j<n-i; ++j) {
            if (sortedValues[j-1] > sortedValues[j]) {
                const float tmp = sortedValues[j-1];
                sortedValues[j-1] = sortedValues[j];
                sortedValues[j] = tmp;
            }
        }
    }
}
inline float InterpolateDepth(const Camera camera, const int2 p, const int2 np, const float depth, const float3 normal, const float depthMin, const float depthMax) {
    float depthNew = depth;
    const float2 f = LoadPoint2(camera.model.f);
    const float2 pp = LoadPoint2(camera.model.p);
    constexpr float eps = 1.192092896e-7f;
    if (p.x == np.x) {
        const float nx1 = ((float)p.y - pp.y) / f.y;
        const float denom = normal.z + nx1 * normal.y;
        if (fabs(denom) < eps) return depth;
        const float x1 = ((float)np.y - pp.y) / f.y;
        const float nom = depth * (normal.z + x1 * normal.y);
        depthNew = nom / denom;
    } else if (p.y == np.y) {
        const float nx1 = ((float)p.x - pp.x) / f.x;
        const float denom = normal.z + nx1 * normal.x;
        if (fabs(denom) < eps) return depth;
        const float x1 = ((float)np.x - pp.x) / f.x;
        const float nom = depth * (normal.z + x1 * normal.x);
        depthNew = nom / denom;
    } else {
        const float planeD = dot(normal, TransformPointI2C(camera.model, float2((float)np.x, (float)np.y), depth));
        const float denom = dot(normal, TransformPointI2C(camera.model, float2((float)p.x, (float)p.y), 1.f));
        if (fabs(denom) < eps) return depth;
        depthNew = planeD / denom;
    }
    return (depthNew >= depthMin && depthNew <= depthMax) ? depthNew : depth;
}
inline float3 GenerateHashUnitVector(const uint seed) {
    constexpr float twoPi = 6.28318530717958647692f;
    const float z = 2.f * HashFloat(seed * 17u + 3u) - 1.f;
    const float a = twoPi * HashFloat(seed * 31u + 7u);
    const float r = sqrt(max(0.f, 1.f - z*z));
    return float3(r * cos(a), r * sin(a), z);
}
inline float GeneratePerturbedDepth(const float depth, const uint seed, const float depthMin, const float depthMax) {
    constexpr float perturbationDepth = 0.005f;
    const float lo = max((1.f - perturbationDepth) * depth, depthMin);
    const float hi = min((1.f + perturbationDepth) * depth, depthMax);
    return mix(lo, hi, HashFloat(seed));
}
inline float3 GeneratePerturbedNormal(const Camera camera, const int2 p, const float3 normal, const uint seed) {
    constexpr float perturbationNormal = 0.03141592653589793238f;
    const float theta = (HashFloat(seed) - 0.5f) * perturbationNormal;
    const float sinT = sin(theta);
    const float cosT = cos(theta);
    const float3 axis = GenerateHashUnitVector(seed * 53u + 23u);
    const float aDotN = dot(axis, normal);
    const float3 normalPerturbed = normalize(normal * cosT + cross(axis, normal) * sinT + axis * (aDotN * (1.f - cosT)));
    return dot(normalPerturbed, ViewDirection(camera.model, p)) >= 0.f ? normal : normalPerturbed;
}
inline float3 ComputeDepthGradient(const LinearCameraModel model, const float depth, const int2 pos, const float4 ndepth) {
    const float2 f = LoadPoint2(model.f);
    const float2 pp = LoadPoint2(model.p);
    const float2 dg = float2(ndepth.w - ndepth.z, ndepth.y - ndepth.x);
    const float2 d = dg * 0.5f;
    return normalize(float3(f.x * d.x, f.y * d.y, (pp.x - (float)pos.x) * d.x + (pp.y - (float)pos.y) * d.y - depth));
}
inline float ScorePlaneTargets(thread const RefPatchCache& cache,
                              device const float* targetImages,
                              device const uint* targetImageOffsets,
                              const Camera refCamera,
                              device const Camera* targetCameras,
                              const int2 p,
                              const float4 plane,
                              const float lowDepth,
                              device const float* depthImages,
                              device const uint* depthImageOffsets,
                              const uint useGeometricConsistency,
                              const uint numTargets,
                              const uint selectedMask,
                              thread uint& resolvedMask) {
    float scoreSum = 0.f;
    uint scoreCount = 0u;
    resolvedMask = 0u;
    for (uint imgId=0; imgId<numTargets; ++imgId) {
        if (selectedMask != 0u && ((selectedMask & (1u << imgId)) == 0u)) continue;
        device const float* targetImage = targetImages + targetImageOffsets[imgId];
        float score = ScorePlanePair(cache, targetImage, refCamera, targetCameras[imgId], p, plane, lowDepth);
        if (useGeometricConsistency != 0u) score += kGeometricConsistencyWeight * GeometricConsistencyWeight(depthImages + depthImageOffsets[imgId], refCamera, targetCameras[imgId], plane, p);
        scoreSum += score;
        SetBit(resolvedMask, imgId);
        ++scoreCount;
    }
    return scoreCount > 0u ? scoreSum / (float)scoreCount : 1.2f;
}
inline void ScorePlaneCostVector(thread const RefPatchCache& cache,
                                 device const float* targetImages,
                                 device const uint* targetImageOffsets,
                                 const Camera refCamera,
                                 device const Camera* targetCameras,
                                 const int2 p,
                                 const float4 plane,
                                 const float lowDepth,
                                 device const float* depthImages,
                                 device const uint* depthImageOffsets,
                                 const uint useGeometricConsistency,
                                 const uint numTargets,
                                 thread float* costVector) {
    for (uint imgId=0; imgId<numTargets; ++imgId) {
        device const float* targetImage = targetImages + targetImageOffsets[imgId];
        float score = ScorePlanePair(cache, targetImage, refCamera, targetCameras[imgId], p, plane, lowDepth);
        if (useGeometricConsistency != 0u) score += kGeometricConsistencyWeight * GeometricConsistencyWeight(depthImages + depthImageOffsets[imgId], refCamera, targetCameras[imgId], plane, p);
        costVector[imgId] = score;
    }
}
inline float ScoreNeighborPlane(thread const RefPatchCache& cache,
                                device const float* targetImages,
                                device const uint* targetImageOffsets,
                                const Camera refCamera,
                                device const Camera* targetCameras,
                                const int2 p,
                                const int2 np,
                                float4 plane,
                                const float lowDepth,
                                device const float* depthImages,
                                device const uint* depthImageOffsets,
                                const uint useGeometricConsistency,
                                const uint numTargets,
                                const float depthMin,
                                const float depthMax,
                                thread float* costVector) {
    plane.w = InterpolateDepth(refCamera, p, np, plane.w, plane.xyz, depthMin, depthMax);
    ScorePlaneCostVector(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p, plane, lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, costVector);
    return plane.w;
}
inline float AggregateMultiViewScores(thread const uint* viewWeights, thread const float* costVector, const uint numTargets) {
    float cost = 0.f;
    for (uint imgId=0; imgId<numTargets; ++imgId)
        if (viewWeights[imgId] != 0u) cost += (float)viewWeights[imgId] * costVector[imgId];
    return cost / (float)kNumSamples;
}
inline uint FindMinIndex8(thread const float* values) {
    float minValue = values[0];
    uint minIdx = 0u;
    for (uint i=1u; i<8u; ++i) {
        if (minValue > values[i]) {
            minValue = values[i];
            minIdx = i;
        }
    }
    return minIdx;
}
inline void PDF2CDF(thread float* probs, const uint numTargets) {
    float probSum = 0.f;
    for (uint i=0u; i<numTargets; ++i) probSum += probs[i];
    if (probSum <= 0.f) {
        for (uint i=0u; i+1u<numTargets; ++i) probs[i] = 0.f;
        probs[numTargets-1u] = 1.f;
        return;
    }
    const float invProbSum = 1.f / probSum;
    float sumProb = 0.f;
    for (uint i=0u; i+1u<numTargets; ++i) {
        sumProb += probs[i] * invProbSum;
        probs[i] = sumProb;
    }
    probs[numTargets-1u] = 1.f;
}
inline uint MaskFromViewWeights(thread const uint* viewWeights, const uint numTargets) {
    uint selected = 0u;
    for (uint imgId=0u; imgId<numTargets; ++imgId)
        if (viewWeights[imgId] != 0u) SetBit(selected, imgId);
    return selected;
}
inline void TryRefineCandidateWeighted(thread const RefPatchCache& cache,
                                       device const float* targetImages,
                                       device const uint* targetImageOffsets,
                                       const Camera refCamera,
                                       device const Camera* targetCameras,
                                       const int2 p,
                                       const float4 candidate,
                                       const float lowDepth,
                                       device const float* depthImages,
                                       device const uint* depthImageOffsets,
                                       const uint useGeometricConsistency,
                                       const uint numTargets,
                                       thread const uint* viewWeights,
                                       thread float4& bestPlane,
                                       thread float& bestCost) {
    float costVector[32];
    ScorePlaneCostVector(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p, candidate, lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, costVector);
    const float candidateCost = AggregateMultiViewScores(viewWeights, costVector, numTargets);
    if (candidateCost < bestCost) {
        bestCost = candidateCost;
        bestPlane = candidate;
    }
}
inline void TryRefineCandidate(thread const RefPatchCache& cache,
                               device const float* targetImages,
                               device const uint* targetImageOffsets,
                               const Camera refCamera,
                               device const Camera* targetCameras,
                               const int2 p,
                               const float4 candidate,
                               const float lowDepth,
                               device const float* depthImages,
                               device const uint* depthImageOffsets,
                               const uint useGeometricConsistency,
                               const uint numTargets,
                               const uint selectedMask,
                               thread float4& bestPlane,
                               thread float& bestCost,
                               thread uint& bestMask) {
    uint resolvedMask = 0u;
    const float candidateCost = ScorePlaneTargets(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p, candidate, lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, selectedMask, resolvedMask);
    if (candidateCost < bestCost) {
        bestCost = candidateCost;
        bestPlane = candidate;
        bestMask = resolvedMask;
    }
}
kernel void kernelScorePlanePair(device const float* imageRef [[buffer(0)]],
                                device const float* imageTrg [[buffer(1)]],
                                device const Point4* planes [[buffer(2)]],
                                device float* costs [[buffer(3)]],
                                constant Camera& refCamera [[buffer(4)]],
                                constant Camera& trgCamera [[buffer(5)]],
                                constant uint& width [[buffer(6)]],
                                constant uint& height [[buffer(7)]],
                                device const float* lowDepths [[buffer(8)]],
                                device const float* depthImage [[buffer(9)]],
                                constant uint& useGeometricConsistency [[buffer(10)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= width || gid.y >= height) return;
    const uint idx = gid.y * width + gid.x;
    RefPatchCache cache;
    const int2 p = int2((int)gid.x, (int)gid.y);
    ComputeRefPatchCache(imageRef, (int)width, (int)height, p, cache);
    float score = ScorePlanePair(cache, imageTrg, refCamera, trgCamera, p, LoadPoint4(planes[idx]), lowDepths[idx]);
    if (useGeometricConsistency != 0u) score += kGeometricConsistencyWeight * GeometricConsistencyWeight(depthImage, refCamera, trgCamera, LoadPoint4(planes[idx]), p);
    costs[idx] = score;
}
kernel void kernelInitializeScore(device const float* imageRef [[buffer(0)]],
                                device const float* targetImages [[buffer(1)]],
                                device const uint* targetImageOffsets [[buffer(2)]],
                                device Point4* planes [[buffer(3)]],
                                device float* costs [[buffer(4)]],
                                device uint* selectedViews [[buffer(5)]],
                                constant Camera& refCamera [[buffer(6)]],
                                device const Camera* targetCameras [[buffer(7)]],
                                constant uint& width [[buffer(8)]],
                                constant uint& height [[buffer(9)]],
                                constant uint& numTargets [[buffer(10)]],
                                constant uint& initTopK [[buffer(11)]],
                                constant float& depthMin [[buffer(12)]],
                                constant float& depthMax [[buffer(13)]],
                                device const float* lowDepths [[buffer(14)]],
                                device const float* depthImages [[buffer(15)]],
                                device const uint* depthImageOffsets [[buffer(16)]],
                                constant uint& useGeometricConsistency [[buffer(17)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= width || gid.y >= height || numTargets == 0u || initTopK == 0u) return;
    const uint idx = gid.y * width + gid.x;
    const int2 p = int2((int)gid.x, (int)gid.y);
    float4 plane = LoadPoint4(planes[idx]);
    if (plane.w <= 0.f) {
        plane = float4(GenerateRandomNormal(refCamera, p, idx), mix(depthMin, depthMax, HashFloat(idx * 47u + 11u)));
    } else if (dot(plane.xyz, ViewDirection(refCamera.model, p)) >= 0.f) {
        plane = float4(GenerateRandomNormal(refCamera, p, idx), plane.w);
    }
    RefPatchCache cache;
    ComputeRefPatchCache(imageRef, (int)width, (int)height, p, cache);
    float costVector[32];
    float costVectorSorted[32];
    const float lowDepth = lowDepths[idx];
    for (uint imgId=0; imgId<numTargets; ++imgId) {
        device const float* targetImage = targetImages + targetImageOffsets[imgId];
        costVector[imgId] = ScorePlanePair(cache, targetImage, refCamera, targetCameras[imgId], p, plane, lowDepth);
        if (useGeometricConsistency != 0u) costVector[imgId] += kGeometricConsistencyWeight * GeometricConsistencyWeight(depthImages + depthImageOffsets[imgId], refCamera, targetCameras[imgId], plane, p);
    }
    SortCosts(costVector, costVectorSorted, numTargets);
    float cost = 0.f;
    for (uint i=0; i<initTopK; ++i) cost += costVectorSorted[i];
    const float costThreshold = costVectorSorted[initTopK - 1u];
    uint selected = 0u;
    for (uint imgId=0; imgId<numTargets; ++imgId) if (costVector[imgId] <= costThreshold) SetBit(selected, imgId);
    planes[idx] = Point4(plane.x, plane.y, plane.z, plane.w);
    costs[idx] = cost / (float)initTopK;
    selectedViews[idx] = selected;
}
kernel void kernelPropagateScore(device const float* imageRef [[buffer(0)]],
                               device const float* targetImages [[buffer(1)]],
                               device const uint* targetImageOffsets [[buffer(2)]],
                               device Point4* planes [[buffer(3)]],
                               device float* costs [[buffer(4)]],
                               device uint* selectedViews [[buffer(5)]],
                               constant Camera& refCamera [[buffer(6)]],
                               device const Camera* targetCameras [[buffer(7)]],
                               constant uint& width [[buffer(8)]],
                               constant uint& height [[buffer(9)]],
                               constant uint& numTargets [[buffer(10)]],
                               constant uint& iteration [[buffer(11)]],
                               constant uint& redPass [[buffer(12)]],
                               constant float& depthMin [[buffer(13)]],
                               constant float& depthMax [[buffer(14)]],
                               device const float* lowDepths [[buffer(15)]],
                               device const float* depthImages [[buffer(16)]],
                               device const uint* depthImageOffsets [[buffer(17)]],
                               constant uint& useGeometricConsistency [[buffer(18)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= width || gid.y >= height || numTargets == 0u) return;
    const bool isRed = ((gid.x + gid.y) & 1u) != 0u;
    if (isRed != (redPass != 0u)) return;
    const uint idx = gid.y * width + gid.x;
    const int2 p = int2((int)gid.x, (int)gid.y);
    RefPatchCache cache;
    ComputeRefPatchCache(imageRef, (int)width, (int)height, p, cache);
    const float lowDepth = lowDepths[idx];
    const int2 dirs[8][11] = {
        { int2( 0,-1), int2(-1,-2), int2( 1,-2), int2(-2,-3), int2( 2,-3), int2(-3,-4), int2( 3,-4), int2(0,0), int2(0,0), int2(0,0), int2(0,0) },
        { int2( 0, 1), int2(-1, 2), int2( 1, 2), int2(-2, 3), int2( 2, 3), int2(-3, 4), int2( 3, 4), int2(0,0), int2(0,0), int2(0,0), int2(0,0) },
        { int2(-1, 0), int2(-2,-1), int2(-2, 1), int2(-3,-2), int2(-3, 2), int2(-4,-3), int2(-4, 3), int2(0,0), int2(0,0), int2(0,0), int2(0,0) },
        { int2( 1, 0), int2( 2,-1), int2( 2, 1), int2( 3,-2), int2( 3, 2), int2( 4,-3), int2( 4, 3), int2(0,0), int2(0,0), int2(0,0), int2(0,0) },
        { int2(0,-3), int2(0,-5), int2(0,-7), int2(0,-9), int2(0,-11), int2(0,-13), int2(0,-15), int2(0,-17), int2(0,-19), int2(0,-21), int2(0,-23) },
        { int2(0, 3), int2(0, 5), int2(0, 7), int2(0, 9), int2(0, 11), int2(0, 13), int2(0, 15), int2(0, 17), int2(0, 19), int2(0, 21), int2(0, 23) },
        { int2(-3,0), int2(-5,0), int2(-7,0), int2(-9,0), int2(-11,0), int2(-13,0), int2(-15,0), int2(-17,0), int2(-19,0), int2(-21,0), int2(-23,0) },
        { int2( 3,0), int2( 5,0), int2( 7,0), int2( 9,0), int2( 11,0), int2( 13,0), int2( 15,0), int2( 17,0), int2( 19,0), int2( 21,0), int2( 23,0) }
    };
    const uint numDirs[8] = {7u, 7u, 7u, 7u, 11u, 11u, 11u, 11u};
    bool valid[8];
    uint positions[8];
    int2 bestPositions[8];
    float neighborDepths[8];
    float costArray[256];
    for (uint i=0u; i<8u; ++i) { valid[i] = false; positions[i] = 0u; bestPositions[i] = p; neighborDepths[i] = 0.f; }
    for (uint posId=0u; posId<8u; ++posId) {
        float bestConf = 3.402823466e+38f;
        int2 bestNx = p;
        uint bestIdx = idx;
        for (uint dirId=0u; dirId<numDirs[posId]; ++dirId) {
            const int2 np = p + dirs[posId][dirId];
            if (np.x < 0 || np.y < 0 || np.x >= (int)width || np.y >= (int)height) continue;
            const uint nidx = (uint)np.y * width + (uint)np.x;
            const float nconf = costs[nidx];
            if (bestConf > nconf) { bestConf = nconf; bestNx = np; bestIdx = nidx; }
        }
        if (bestConf < 3.402823466e+38f) {
            const float4 plane = LoadPoint4(planes[bestIdx]);
            if (plane.w > 0.f) {
                valid[posId] = true;
                positions[posId] = bestIdx;
                bestPositions[posId] = bestNx;
                neighborDepths[posId] = ScoreNeighborPlane(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p, bestNx, plane, lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, depthMin, depthMax, costArray + posId*kMaxViews);
            }
        }
    }
    float viewSelectionPriors[32];
    float samplingProbs[32];
    uint viewWeights[32];
    for (uint imgId=0u; imgId<numTargets; ++imgId) { viewSelectionPriors[imgId] = 0.f; samplingProbs[imgId] = 0.f; viewWeights[imgId] = 0u; }
    const int neighborPositions[4] = { (int)idx - (int)width, (int)idx + (int)width, (int)idx - 1, (int)idx + 1 };
    for (uint posId=0u; posId<4u; ++posId) {
        if (valid[posId] && neighborPositions[posId] >= 0) {
            const uint selectedView = selectedViews[(uint)neighborPositions[posId]];
            for (uint imgId=0u; imgId<numTargets; ++imgId)
                viewSelectionPriors[imgId] += IsBitSet(selectedView, imgId) ? 0.9f : 0.1f;
        }
    }
    const float thCost = 0.8f * exp(SquareF((float)iteration) / (-2.f * 4.f * 4.f));
    for (uint imgId=0u; imgId<numTargets; ++imgId) {
        float sumW = 0.f;
        uint count = 0u;
        uint countBad = 0u;
        for (uint posId=0u; posId<8u; ++posId) {
            if (!valid[posId]) continue;
            const float score = costArray[posId*kMaxViews + imgId];
            if (score < thCost) { sumW += exp(SquareF(score) / (-2.f * 0.3f * 0.3f)); ++count; }
            else if (score >= kBadCost) { ++countBad; }
        }
        if (count > 2u && countBad < 3u) samplingProbs[imgId] = viewSelectionPriors[imgId] * sumW / (float)count;
        else if (countBad < 3u) samplingProbs[imgId] = viewSelectionPriors[imgId] * exp(SquareF(thCost) / (-2.f * 0.4f * 0.4f));
        else samplingProbs[imgId] = 0.f;
    }
    PDF2CDF(samplingProbs, numTargets);
    const uint sampleSeedBase = idx * 73856093u + iteration * 19349663u + (redPass != 0u ? 83492791u : 2654435761u);
    for (uint sample=0u; sample<kNumSamples; ++sample) {
        const float randProb = HashFloat(sampleSeedBase + sample * 104729u);
        for (uint imgId=0u; imgId<numTargets; ++imgId) {
            if (samplingProbs[imgId] > randProb) { ++viewWeights[imgId]; break; }
        }
    }
    const uint sampledMask = MaskFromViewWeights(viewWeights, numTargets);
    float finalCosts[8];
    for (uint posId=0u; posId<8u; ++posId)
        finalCosts[posId] = valid[posId] ? AggregateMultiViewScores(viewWeights, costArray + posId*kMaxViews, numTargets) : 3.402823466e+38f;
    const uint minCostIdx = FindMinIndex8(finalCosts);
    float4 bestPlane = LoadPoint4(planes[idx]);
    uint bestMask = selectedViews[idx];
    float bestCost = 3.402823466e+38f;
    float currentCostVector[32];
    if (bestPlane.w > 0.f) {
        ScorePlaneCostVector(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p, bestPlane, lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, currentCostVector);
        bestCost = AggregateMultiViewScores(viewWeights, currentCostVector, numTargets);
        if (bestMask == 0u) bestMask = sampledMask;
    }
    if (valid[minCostIdx] && finalCosts[minCostIdx] < bestCost) {
        bestPlane = LoadPoint4(planes[positions[minCostIdx]]);
        bestPlane.w = neighborDepths[minCostIdx];
        bestCost = finalCosts[minCostIdx];
        bestMask = sampledMask;
    }
    constexpr int2 offsets[4] = { int2(0,-1), int2(0,1), int2(-1,0), int2(1,0) };
    if (bestPlane.w > 0.f && bestCost < 3.402823466e+38f) {
        const uint refineSeed = idx * 67u + iteration * 131u + (redPass != 0u ? 43u : 19u);
        TryRefineCandidateWeighted(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p,
            float4(bestPlane.xyz, GeneratePerturbedDepth(bestPlane.w, refineSeed, depthMin, depthMax)),
            lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, viewWeights, bestPlane, bestCost);
        TryRefineCandidateWeighted(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p,
            float4(GeneratePerturbedNormal(refCamera, p, bestPlane.xyz, refineSeed * 97u + 5u), bestPlane.w),
            lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, viewWeights, bestPlane, bestCost);
        float3 randomNormal = GenerateRandomNormal(refCamera, p, refineSeed * 193u + 11u);
        TryRefineCandidateWeighted(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p,
            float4(randomNormal, bestPlane.w), lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, viewWeights, bestPlane, bestCost);
        float4 neighborDepths;
        bool haveSurfaceNormal = true;
        for (uint i=0; i<4; ++i) {
            const int2 np = p + offsets[i];
            if (np.x < 0 || np.y < 0 || np.x >= (int)width || np.y >= (int)height) { haveSurfaceNormal = false; break; }
            const uint nidx = (uint)np.y * width + (uint)np.x;
            const float ndepth = planes[nidx][3];
            if (ndepth <= 0.f) { haveSurfaceNormal = false; break; }
            neighborDepths[i] = ndepth;
        }
        if (haveSurfaceNormal) {
            const float3 surfaceNormal = ComputeDepthGradient(refCamera.model, bestPlane.w, p, neighborDepths);
            TryRefineCandidateWeighted(cache, targetImages, targetImageOffsets, refCamera, targetCameras, p,
                float4(surfaceNormal, bestPlane.w), lowDepth, depthImages, depthImageOffsets, useGeometricConsistency, numTargets, viewWeights, bestPlane, bestCost);
        }
    }
    if (bestPlane.w > 0.f && bestCost < 3.402823466e+38f) {
        planes[idx] = Point4(bestPlane.x, bestPlane.y, bestPlane.z, bestPlane.w);
        costs[idx] = bestCost;
        selectedViews[idx] = bestMask;
    }
}
kernel void kernelFilterPlanes(device Point4* planes [[buffer(0)]],
                              device float* costs [[buffer(1)]],
                              device uint* selectedViews [[buffer(2)]],
                              constant uint& width [[buffer(3)]],
                              constant uint& height [[buffer(4)]],
                              constant float& threshold [[buffer(5)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= width || gid.y >= height) return;
    const uint idx = gid.y * width + gid.x;
    const Point4 plane = planes[idx];
    const float cost = costs[idx];
    if (plane[3] <= 0.f || (threshold > 0.f && cost >= threshold)) {
        planes[idx] = Point4(0.f, 0.f, 0.f, 0.f);
        costs[idx] = 0.f;
        selectedViews[idx] = 0u;
    }
}
